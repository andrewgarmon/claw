#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc is read inside eval'd check strings
# Tests for oc_plugins_install (infra/lib/openclaw-plugins.sh) with fake install/npm under a scratch
# root (CLAW_ROOT), plus static checks that openclaw.json and infra/openclaw-plugins/ agree: every
# root-owned plugin is allowlisted, loaded from its root-owned path and denied prompt injection.
# Touches nothing outside a temp dir. Usage: bash infra/tests/openclaw-plugins.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$INFRA/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BIN=$T/bin R=$T/root SRC=$T/src
mkdir -p "$BIN" "$SRC"
export CLAW_ROOT=$R
# shellcheck source=../lib/openclaw-plugins.sh
. "$INFRA/lib/openclaw-plugins.sh"

fake() { printf '#!/bin/bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
LOGCALL='printf "%s" "$(basename "$0")" >> '"$T/calls"'; printf "[%s]" "$@" >> '"$T/calls"'; echo >> '"$T/calls"
fake install "$LOGCALL"'
a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done
exec /usr/bin/install "${a[@]}"'
# npm ci: log (with the cwd), fail if $T/npm_fails, else create each locked package with a manifest
fake npm "$LOGCALL"'; echo "cwd=$PWD" >> '"$T/calls"'
[ -e '"$T/npm_fails"' ] && exit 1
for p in $(jq -r ".packages | keys[] | select(startswith(\"node_modules/\"))" package-lock.json); do
  mkdir -p "$p" && echo "{\"id\":\"x\"}" > "$p/openclaw.plugin.json"
done'
PATH=$BIN:$PATH

fails=0
run() { : > "$T/calls"; oc_plugins_install "$SRC" > "$T/out" 2>&1; rc=$?; }
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out:   /' "$T/out"; sed 's/^/     calls: /' "$T/calls"; fails=$((fails + 1)); fi
}
called() { grep -qF -- "$1" "$T/calls"; }
calls_to() { grep -c "^$1\[" "$T/calls"; }
says() { grep -qF -- "$1" "$T/out"; }
D=$R/usr/local/lib/claw/openclaw-plugins

# ---------- an npm-pinned plugin (the real duckduckgo dir) and a source plugin ----------
cp -r "$INFRA/openclaw-plugins/duckduckgo" "$SRC/"
mkdir -p "$SRC/hello/src"; echo '{"id":"hello"}' > "$SRC/hello/openclaw.plugin.json"; echo 'export {}' > "$SRC/hello/src/index.ts"
run
check "npm plugin: copied root:root and npm ci'd in the .new dir, scripts off, no dev or peer deps" \
  eval '[ $rc = 0 ] && called "npm[ci][--ignore-scripts][--omit=dev][--omit=peer][--no-audit][--no-fund][--loglevel=error]" && called "cwd=$D/duckduckgo.new" && [ -e "$D/duckduckgo/node_modules/@openclaw/duckduckgo-plugin/openclaw.plugin.json" ]'
check "files installed root:root 644, dirs 755" \
  eval 'called "install[-m][644][-o][root][-g][root][./package-lock.json][$D/duckduckgo.new/./package-lock.json]" && called "install[-d][-m][755][-o][root][-g][root][$R/usr/local/lib/claw][$D]"'
check "source plugin: copied as is (subdirs too), no npm" \
  eval 'cmp -s "$SRC/hello/src/index.ts" "$D/hello/src/index.ts" && [ "$(grep -c "cwd=$D/hello" "$T/calls")" = 0 ]'
check "source hash recorded, no .new dir left" eval '[ -s "$D/duckduckgo/.claw-source-sha256" ] && [ ! -e "$D/duckduckgo.new" ] && says "OpenClaw plugin duckduckgo installed"'

run
check "unchanged source: nothing reinstalled" eval '[ $rc = 0 ] && [ "$(calls_to npm)" = 0 ] && [ ! -s "$T/out" ]'

echo 'export const x = 1' > "$SRC/hello/src/index.ts"
run
check "changed source: only that plugin reinstalled" eval '[ $rc = 0 ] && grep -q "export const x" "$D/hello/src/index.ts" && [ "$(calls_to npm)" = 0 ] && says "hello installed" && ! says "duckduckgo installed"'

echo '{"tampered":1}' > "$D/duckduckgo/package.json"; sed -i 's/2026.11.3"/2026.11.5"/' "$SRC/duckduckgo/package.json"
touch "$T/npm_fails"
run
check "npm ci fails: the previous install is kept, .new removed" \
  eval '[ $rc = 0 ] && says "npm ci for OpenClaw plugin duckduckgo failed; kept the previous install" && [ -e "$D/duckduckgo/node_modules" ] && [ ! -e "$D/duckduckgo.new" ]'
rm "$T/npm_fails"
run
check "npm works again: reinstalled" eval '[ $rc = 0 ] && grep -q 2026.11.5 "$D/duckduckgo/package.json"'

rm -rf "$SRC/hello"; mkdir -p "$D/stale.new"
run
check "plugin removed from the repo: removed here; leftover .new dirs cleaned" \
  eval '[ $rc = 0 ] && [ ! -e "$D/hello" ] && [ ! -e "$D/stale.new" ] && says "removed OpenClaw plugin hello" && [ -d "$D/duckduckgo" ]'

mkdir -p "$SRC/Bad_Name"
run
check "bad plugin dir name: refused" eval '[ $rc = 1 ] && says "bad OpenClaw plugin dir name: Bad_Name"'
rmdir "$SRC/Bad_Name"

# ---------- static: openclaw.json agrees with infra/openclaw-plugins/ ----------
cd "$REPO" || exit 1
CFG=openclaw.json
mapfile -t ids < <(find infra/openclaw-plugins -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
check "there is at least one root-owned plugin" eval '[ ${#ids[@]} -gt 0 ]'
for id in "${ids[@]}"; do
  check "$id: in plugins.allow" eval 'jq -e --arg i "$id" ".plugins.allow | index(\$i)" "$CFG" >/dev/null'
  check "$id: hooks.allowPromptInjection is false" eval 'jq -e --arg i "$id" ".plugins.entries[\$i].hooks.allowPromptInjection == false" "$CFG" >/dev/null'
  check "$id: exactly one load path, under /usr/local/lib/claw/openclaw-plugins/$id/" \
    eval '[ "$(jq -r --arg p "/usr/local/lib/claw/openclaw-plugins/$id" ".plugins.load.paths[] | select(. == \$p or startswith(\$p + \"/\"))" "$CFG" | wc -l)" = 1 ]'
  if jq -e '.openclaw' "infra/openclaw-plugins/$id/package.json" >/dev/null 2>&1; then
    check "$id: a source plugin is loaded from its own dir, with exact dependency versions" \
      eval 'jq -e --arg p "/usr/local/lib/claw/openclaw-plugins/$id" ".plugins.load.paths | index(\$p)" "$CFG" >/dev/null &&
            jq -e "[.dependencies // {} | .[] | test(\"^[0-9]+(\\\\.[0-9]+)*$\")] | all" "infra/openclaw-plugins/$id/package.json" >/dev/null &&
            { [ -z "$(jq -r ".dependencies // {} | keys[]" "infra/openclaw-plugins/$id/package.json")" ] || [ -f "infra/openclaw-plugins/$id/package-lock.json" ]; }'
  elif [ -f "infra/openclaw-plugins/$id/package-lock.json" ]; then
    check "$id: the load path is node_modules/<the pinned package>, at an exact version" \
      eval 'pkg=$(jq -r ".dependencies | keys[0]" "infra/openclaw-plugins/$id/package.json"); ver=$(jq -r ".dependencies[\"$pkg\"]" "infra/openclaw-plugins/$id/package.json");
            [[ $ver =~ ^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?$ ]] && jq -e --arg p "/usr/local/lib/claw/openclaw-plugins/$id/node_modules/$pkg" ".plugins.load.paths | index(\$p)" "$CFG" >/dev/null'
  fi
done
check "every load path is a root-owned plugin from infra/openclaw-plugins/" \
  eval 'jq -r ".plugins.load.paths[]" "$CFG" | while read -r p; do [[ $p =~ ^/usr/local/lib/claw/openclaw-plugins/([a-z][a-z0-9-]*)(/|$) ]] && [ -d "infra/openclaw-plugins/${BASH_REMATCH[1]}" ] || exit 1; done'
check "plugins.allow has no duplicates" eval '[ "$(jq ".plugins.allow | length" "$CFG")" = "$(jq ".plugins.allow | unique | length" "$CFG")" ]'

echo; [ $fails = 0 ] && echo "all openclaw-plugins tests passed" || { echo "$fails failed"; exit 1; }
