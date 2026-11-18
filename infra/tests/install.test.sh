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
  case $a in /*) ;; *) continue ;; esac
  if [ "$1" = rm ]; then p=$(realpath -m -- "$(dirname -- "$a")")/${a##*/}; else p=$(realpath -m -- "$a"); fi
  case $p in '"$R"'/home/"$u"|'"$R"'/home/"$u"/*) ;; *) echo "sudo: $u: permission denied: $a" >&2; exit 1 ;; esac
done
PATH=/usr/bin:/bin exec "$@"'
PATH=$BIN:$PATH
cd "$INFRA" || exit 1   # the steps take repo files relative to infra/, as install.sh does

DD=/etc/systemd/user/openclaw-gateway.service.d                     # drop-ins now
OLD=/home/openclaw/.config/systemd/user/openclaw-gateway.service.d  # drop-ins before
fails=0
run() { : > "$T/calls"; { coder_home_install; r1=$?; gateway_dropins_install; rc=$((r1 + $?)); } > "$T/out" 2>&1; }
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
echo old > "$R/home/coder/.claude/CLAUDE.md"
for f in gateway-dropins/*.conf; do echo old > "$R$OLD/${f##*/}"; done
echo mine > "$R$OLD/mine.conf"; echo gone > "$R$DD/renamed.conf"
run
check "upgrade: no errors or warnings" eval '[ $rc = 0 ] && [ ! -s "$T/out" ]'
check "coder's .config and .claude created as coder, mode 700" \
  eval 'called "sudo[-n][-u][coder][--][install][-d][-m][700][$R/home/coder/.config][$R/home/coder/.claude]" && [ "$(stat -c %a "$R/home/coder/.config" "$R/home/coder/.claude")" = "$(printf "700\n700")" ]'
check "CLAUDE.md installed root:root 644 as Claude Code's managed memory, /etc/claude-code/CLAUDE.md" \
  eval 'called "install[-m][644][-o][root][-g][root][coder-CLAUDE.md][$R/etc/claude-code/CLAUDE.md]" && cmp -s coder-CLAUDE.md "$R/etc/claude-code/CLAUDE.md" && called "install[-d][-m][755][-o][root][-g][root][$R/etc/claude-code]"'
check "the old CLAUDE.md in coder's home is removed, as coder" \
  eval 'called "sudo[-n][-u][coder][--][rm][-f][$R/home/coder/.claude/CLAUDE.md]" && [ ! -e "$R/home/coder/.claude/CLAUDE.md" ]'
check "drop-ins installed root:root 644 in /etc/systemd/user/openclaw-gateway.service.d/" \
  eval 'called "install[-d][-m][755][-o][root][-g][root][$R$DD]" && grep -q "^install\[-m\]\[644\]\[-o\]\[root\]\[-g\]\[root\]\[gateway-dropins/.*\]\[$R$DD/\]$" "$T/calls" && for f in gateway-dropins/*.conf; do cmp -s "$f" "$R$DD/${f##*/}" || exit 1; done'
check "a drop-in no longer in the repo is removed from /etc" eval '[ ! -e "$R$DD/renamed.conf" ]'
check "the old drop-ins in openclaw's home are removed, as openclaw; its own drop-ins are kept" \
  eval 'grep -q "^sudo\[-n\]\[-u\]\[openclaw\]\[--\]\[rm\]\[-f\]\[$R$OLD/" "$T/calls" && for f in gateway-dropins/*.conf; do [ ! -e "$R$OLD/${f##*/}" ] || exit 1; done && [ -e "$R$OLD/mine.conf" ]'
check "root never names a path under a home" eval '! root_in_home'

# ---------- the drop-ins themselves ----------
check "heap.conf sets the heap through NODE_OPTIONS" \
  grep -qxF 'Environment=NODE_OPTIONS=--max-old-space-size=2048' gateway-dropins/heap.conf
check "no drop-in overrides OpenClaw's ExecStart" eval '! grep -q "^ExecStart" gateway-dropins/*.conf'

# ---------- fresh host: nothing old to remove ----------
fresh
run
check "fresh host: installs cleanly" eval '[ $rc = 0 ] && [ ! -s "$T/out" ] && [ -s "$R/etc/claude-code/CLAUDE.md" ] && [ -s "$R$DD/heap.conf" ]'

# ---------- a symlink at every path in a home the installer used to write ----------
# The target stands for a root-owned directory: owner, mode and contents must not change.
for p in "$OLD" "$OLD/heap.conf" /home/openclaw/.config/systemd/user /home/openclaw/.config \
         /home/coder/.claude /home/coder/.claude/CLAUDE.md /home/coder/.config; do
  fresh
  case $p in
    */heap.conf) mkdir -p "$R${p%/*}"; ln -s "$TGT/heap.conf" "$R$p" ;;
    */CLAUDE.md) mkdir -p "$R${p%/*}"; ln -s "$TGT/CLAUDE.md" "$R$p" ;;
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
  eval '[ $r1 = 1 ] && says "couldn'"'"'t create ~coder/.config and ~coder/.claude as coder"'
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
