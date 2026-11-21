#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc is read inside eval'd check strings
# Tests for the install steps that touch service users' homes (infra/lib/service-home.sh: coder's
# dirs and CLAUDE.md, the gateway drop-ins) with fake install/sudo under a scratch root (CLAW_ROOT),
# plus static checks that nothing in infra/ run as root writes under /home/ itself.
# The fake sudo runs the command for real, but only if every path it names resolves inside that
# user's home, which is all a real service user could change; root-owned paths are the rest.
# Touches nothing outside a temp dir. Usage: bash infra/tests/install.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T=$(realpath "$T")
BIN=$T/bin R=$T/root TGT=$T/target
mkdir -p "$BIN"
export CLAW_ROOT=$R
# shellcheck source=../lib/service-home.sh
. "$INFRA/lib/service-home.sh"

fake() { printf '#!/bin/bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
LOGCALL='printf "%s" "$(basename "$0")" >> '"$T/calls"'; printf "[%s]" "$@" >> '"$T/calls"'; echo >> '"$T/calls"
# install (as root): log the call, then do it without -o/-g
fake install "$LOGCALL"'
a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done
exec /usr/bin/install "${a[@]}"'
# sudo -n -u <user> -- <cmd>...: log, refuse any absolute path outside $R/home/<user> once symlinks
# are resolved (rm resolves only the parent: removing a symlink removes the link), then run <cmd>
# with the real tools, as a real service user would
fake sudo "$LOGCALL"'
[ "$1" = -n ] && shift; [ "$1" = -u ] || exit 2; u=$2; shift 2; [ "$1" = -- ] && shift
for a in "${@:2}"; do
  case $a in /dev/stdin|/dev/null) continue ;; /*) ;; *) continue ;; esac   # sources anyone can read
  if [ "$1" = rm ]; then p=$(realpath -m -- "$(dirname -- "$a")")/${a##*/}; else p=$(realpath -m -- "$a"); fi
  case $p in '"$R"'/home/"$u"|'"$R"'/home/"$u"/*) ;; *) echo "sudo: $u: permission denied: $a" >&2; exit 1 ;; esac
done
PATH=/usr/bin:/bin exec "$@"'
# pkill/pgrep: logged; no coder processes here
fake pkill "$LOGCALL"'
true'
fake pgrep "$LOGCALL"'
exit 1'
PATH=$BIN:$PATH
cd "$INFRA" || exit 1   # the steps take repo files relative to infra/, as install.sh does

DD=/etc/systemd/user/openclaw-gateway.service.d                     # drop-ins now
OLD=/home/openclaw/.config/systemd/user/openclaw-gateway.service.d  # drop-ins before
fails=0
run() { : > "$T/calls"; { coder_home_install && coder_sandbox_migrate; r1=$?; gateway_dropins_install; rc=$((r1 + $?)); } > "$T/out" 2>&1; }
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out:   /' "$T/out"; sed 's/^/     calls: /' "$T/calls"; fails=$((fails + 1)); fi
}
called() { grep -qxF -- "$1" "$T/calls"; }
says() { grep -qF -- "$1" "$T/out"; }
# every call made as root (not through sudo -u) that names a path under a home
root_in_home() { grep -v '^sudo\[' "$T/calls" | grep -F "$R/home/"; }
fresh() {
  rm -rf "$R" "$TGT"
  mkdir -p "$R/home/coder" "$R/home/openclaw/.config/systemd/user" "$R/etc" "$TGT"
  echo root-file > "$TGT/heap.conf"; echo root-file > "$TGT/CLAUDE.md"; echo root-file > "$TGT/x"
  chmod 755 "$TGT"; chmod 644 "$TGT"/*
}
snapshot() { (cd "$TGT" && stat -c '%a %u %g %n' . ./* && sha256sum ./*); }

# ---------- upgrade from an install that wrote into the homes ----------
fresh
mkdir -p "$R/home/coder/.claude" "$R$OLD" "$R$DD"
echo old > "$R/home/coder/.claude/CLAUDE.md"; echo mine > "$R/home/coder/.claude/settings.local.json"
echo '{"state":1}' > "$R/home/coder/.claude.json"; mkdir "$R/home/coder/.claude/skills"; echo s > "$R/home/coder/.claude/skills/x"
ln -s "$R/home/coder/.config" "$R/home/coder/.claude/agents"; echo f > "$R/home/coder/.claude/rules"   # left by a session
for f in gateway-dropins/*.conf; do echo old > "$R$OLD/${f##*/}"; done
echo mine > "$R$OLD/mine.conf"; echo gone > "$R$DD/renamed.conf"
run
B=$(ls -d "$R"/home/coder/.claude/pre-sandbox-* 2>/dev/null)
check "upgrade: no errors or warnings, says where the old paths went" eval '[ $rc = 0 ] && [ "$(cat "$T/out")" = "install.sh: moved coder'"'"'s ~/.claude/{settings.local.json CLAUDE.md skills} to ${B#"$R"}/ (sessions could write them until now)" ]'
check "coder's dirs created as coder, mode 700" \
  eval 'called "sudo[-n][-u][coder][--][install][-d][-m][700][$R/home/coder/.config][$R/home/coder/.claude][$R/home/coder/.cache][$R/home/coder/.npm]" && [ "$(stat -c %a "$R/home/coder/.config")" = 700 ]'
check "first install with the sandbox: what sessions could write is moved aside, as coder" \
  eval '[ -n "$B" ] && [ "$(cat "$B/settings.local.json")" = mine ] && [ "$(cat "$B/skills/x")" = s ] && [ "$(cat "$B/CLAUDE.md")" = old ] && grep -q "^sudo\[-n\]\[-u\]\[coder\]\[--\]\[mv\]\[-T\]" "$T/calls"'
check "... after stopping every coder process (sessions started before the sandbox)" \
  eval 'called "pkill[-TERM][-u][coder]" && called "pkill[-KILL][-u][coder]" && [ "$(grep -n "^pkill\[-TERM" "$T/calls" | cut -d: -f1)" -lt "$(grep -n "\[mv\]" "$T/calls" | head -n1 | cut -d: -f1)" ]'
check "the dirs the sandbox binds: created empty as coder, mode 700" \
  eval 'for d in rules commands agents skills output-styles plugins; do called "sudo[-n][-u][coder][--][install][-d][-m][700][$R/home/coder/.claude/$d]" && [ -d "$R/home/coder/.claude/$d" ] && [ ! -L "$R/home/coder/.claude/$d" ] || exit 1; done && [ -z "$(ls -A "$R/home/coder/.claude/skills")" ]'
check "the move happens once: root-owned marker in /var/lib/claw-install" eval '[ -e "$R/var/lib/claw-install/coder-claude-moved" ]'
check "CLAUDE.md installed root:root 644 as Claude Code's managed memory, /etc/claude-code/CLAUDE.md" \
  eval 'called "install[-m][644][-o][root][-g][root][coder-CLAUDE.md][$R/etc/claude-code/CLAUDE.md]" && cmp -s coder-CLAUDE.md "$R/etc/claude-code/CLAUDE.md" && called "install[-d][-m][755][-o][root][-g][root][$R/etc/claude-code]"'
check "managed settings installed root:root 644: hooks, MCP servers, marketplaces and auto-memory off" \
  eval 'called "install[-m][644][-o][root][-g][root][coder-managed-settings.json][$R/etc/claude-code/managed-settings.json]" && python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"allowManagedHooksOnly\"] is True and d[\"allowedMcpServers\"] == [] and d[\"disableAllHooks\"] is True and d[\"autoMemoryEnabled\"] is False and d[\"strictKnownMarketplaces\"] == [] else 1)" "$R/etc/claude-code/managed-settings.json"'
check "settings files the sandbox binds: created as coder with {}" \
  eval '[ "$(cat "$R/home/coder/.claude/settings.json")" = "{}" ] && [ "$(cat "$R/home/coder/.claude/settings.local.json")" = "{}" ]'
check "coder's .claude.json copied into its .claude as coder (Claude Code's state file moves there)" \
  eval 'called "sudo[-n][-u][coder][--][cp][$R/home/coder/.claude.json][$R/home/coder/.claude/.claude.json]" && [ "$(cat "$R/home/coder/.claude/.claude.json")" = "{\"state\":1}" ]'
check "coder's CLAUDE.md is a new empty file, as coder" \
  eval 'called "sudo[-n][-u][coder][--][install][-m][600][/dev/null][$R/home/coder/.claude/CLAUDE.md]" && [ -f "$R/home/coder/.claude/CLAUDE.md" ] && [ ! -s "$R/home/coder/.claude/CLAUDE.md" ]'
check "drop-ins installed root:root 644 in /etc/systemd/user/openclaw-gateway.service.d/" \
  eval 'called "install[-d][-m][755][-o][root][-g][root][$R$DD]" && grep -q "^install\[-m\]\[644\]\[-o\]\[root\]\[-g\]\[root\]\[gateway-dropins/.*\]\[$R$DD/\]$" "$T/calls" && for f in gateway-dropins/*.conf; do cmp -s "$f" "$R$DD/${f##*/}" || exit 1; done'
check "a drop-in no longer in the repo is removed from /etc" eval '[ ! -e "$R$DD/renamed.conf" ]'
check "the old drop-ins in openclaw's home are removed, as openclaw; its own drop-ins are kept" \
  eval 'grep -q "^sudo\[-n\]\[-u\]\[openclaw\]\[--\]\[rm\]\[-f\]\[$R$OLD/" "$T/calls" && for f in gateway-dropins/*.conf; do [ ! -e "$R$OLD/${f##*/}" ] || exit 1; done && [ -e "$R$OLD/mine.conf" ]'
check "root never names a path under a home" eval '! root_in_home'

# ---------- later installs: contents kept, symlinks, hard links and wrong types replaced ----------
C=$R/home/coder/.claude
echo mine > "$C/settings.local.json"; echo s > "$C/skills/x"; echo mine > "$C/CLAUDE.md"
rm -rf "$C/agents" "$C/rules"; ln -s "$R/home/coder/.config" "$C/agents"; echo f > "$C/rules"
echo '{"a":1}' > "$C/settings.json"; ln "$C/settings.json" "$C/linked"
run
check "later install: no errors, nothing moved, no process stopped" eval '[ $rc = 0 ] && [ ! -s "$T/out" ] && [ "$(ls -d "$C"/pre-sandbox-* | wc -l)" = 1 ] && ! grep -q "^pkill" "$T/calls"'
check "later install: contents kept" \
  eval '[ "$(cat "$C/settings.local.json")" = mine ] && [ "$(cat "$C/skills/x")" = s ] && [ "$(cat "$C/CLAUDE.md")" = mine ]'
check "later install: a symlink or a file where a dir is bound: removed as coder, a dir made" \
  eval 'called "sudo[-n][-u][coder][--][rm][-rf][$C/agents]" && called "sudo[-n][-u][coder][--][rm][-rf][$C/rules]" && [ -d "$C/agents" ] && [ ! -L "$C/agents" ] && [ -d "$C/rules" ] && [ -d "$R/home/coder/.config" ]'
check "later install: a hard-linked protected file is replaced by a new one" \
  eval '[ "$(stat -c %h "$C/settings.json")" = 1 ] && [ "$(cat "$C/settings.json")" = "{}" ] && [ "$(cat "$C/linked")" = "{\"a\":1}" ]'
check "later install: root never names a path under a home" eval '! root_in_home'

# ---------- the drop-ins themselves ----------
check "heap.conf sets the heap through NODE_OPTIONS" \
  grep -qxF 'Environment=NODE_OPTIONS=--max-old-space-size=2048' gateway-dropins/heap.conf
check "python.conf: the gateway doesn't write Python bytecode next to skill code (claw-sync would remove it)" \
  grep -qxF 'Environment=PYTHONDONTWRITEBYTECODE=1' gateway-dropins/python.conf
check "no drop-in overrides OpenClaw's ExecStart" eval '! grep -q "^ExecStart" gateway-dropins/*.conf'

# ---------- fresh host: nothing old to remove ----------
fresh
run
check "fresh host: installs cleanly" eval '[ $rc = 0 ] && [ ! -s "$T/out" ] && [ -s "$R/etc/claude-code/CLAUDE.md" ] && [ -s "$R$DD/heap.conf" ]'

# ---------- a symlink at every path in a home the installer used to write ----------
# The target stands for a root-owned directory: owner, mode and contents must not change.
for p in "$OLD" "$OLD/heap.conf" /home/openclaw/.config/systemd/user /home/openclaw/.config \
         /home/coder/.claude /home/coder/.claude/CLAUDE.md /home/coder/.config \
         /home/coder/.claude/settings.json /home/coder/.claude.json /home/coder/.claude/.claude.json \
         /home/coder/.claude/skills; do
  fresh
  case $p in
    */heap.conf) mkdir -p "$R${p%/*}"; ln -s "$TGT/heap.conf" "$R$p" ;;
    */CLAUDE.md) mkdir -p "$R${p%/*}"; ln -s "$TGT/CLAUDE.md" "$R$p" ;;
    *.json) mkdir -p "$R${p%/*}"; ln -s "$TGT/x" "$R$p" ;;
    *) rm -rf "${R:?}$p"; mkdir -p "$R${p%/*}"; ln -s "$TGT" "$R$p" ;;
  esac
  before=$(snapshot)
  run
  check "symlink at ~${p#/home/}: target's owner, mode and contents unchanged" eval '[ "$(snapshot)" = "$before" ]'
  check "symlink at ~${p#/home/}: root never names a path under a home" eval '! root_in_home'
done
fresh; ln -s "$TGT" "$R/home/coder/.claude"
run
check "a home dir coder can't create: the coder step fails and says so" \
  eval '[ $r1 = 1 ] && says "couldn'"'"'t create ~coder/.config, .claude, .cache or .npm as coder"'
# the harness catches the old behaviour: root's install -d through the same symlink changes the target
before=$(snapshot); install -d -m 700 "$R/home/coder/.claude"
check "harness check: a root write through the symlink is detected" eval '[ "$(snapshot)" != "$before" ]'

# ---------- static: nothing run as root writes under /home/ itself ----------
cd "$INFRA/.." || exit 1
ROOT_RUN=(infra/install.sh infra/lib/broker-install.sh infra/lib/service-home.sh infra/lib/openclaw-plugins.sh infra/claw-install)
# root only installs files and dirs owned by root (/srv/work is coder's, but outside any home)
bad=$(grep -nE '(^|[[:space:];&|(])install [^#]*-o +' "${ROOT_RUN[@]}" | grep -vE -- '-o +root ' | grep -v ' /srv/work$')
check "no install -o <service user> in root-run scripts" eval '[ -z "$bad" ] || { echo "$bad" > "$T/out"; false; }'
# no command run as root writes, creates or removes a path under a home unless it goes through
# as_user / sudo -u
bad=$(grep -nE '/home/|\$home|\$\{?R\}?/home' "${ROOT_RUN[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE 'as_user|sudo ' \
      | grep -E '(^|[^[:alnum:]_-])(install|cp|mv|mkdir|ln|chown|chmod|tee|touch|rm|rsync|sed -i)( |$)|[^2&]>[^&]')
check "no root write under /home/ in root-run scripts" eval '[ -z "$bad" ] || { echo "$bad" > "$T/out"; false; }'

echo; [ $fails = 0 ] && echo "all install tests passed" || { echo "$fails failed"; exit 1; }
