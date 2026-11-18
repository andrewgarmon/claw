#!/usr/bin/env bash
# Tests for infra/lib/backup-key.sh: the config repo's backup.age.pub is installed to
# /etc/claw/backup.age.pub (under a scratch CLAW_ROOT, with a fake install that drops -o/-g) only
# when it's a plain recipients file; anything else is refused and the installed key is kept.
# Touches nothing outside a temp dir. Usage: bash infra/tests/backup-key.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BIN=$T/bin R=$T/root SRC=$T/repo/backup.age.pub DST=$T/root/etc/claw/backup.age.pub
mkdir -p "$BIN" "$T/repo"
export CLAW_ROOT=$R
cat > "$BIN/install" <<'EOF'
#!/bin/bash
a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done
exec /usr/bin/install "${a[@]}"
EOF
chmod +x "$BIN/install"; PATH=$BIN:$PATH
# shellcheck source=../lib/backup-key.sh
. "$INFRA/lib/backup-key.sh"

K1=age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
K2=age1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
fails=0
run() { backup_key_install "$SRC" > "$T/out" 2>&1; rc=$?; }
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out: /' "$T/out"; fails=$((fails + 1)); fi
}
says() { grep -qF -- "$1" "$T/out"; }

run
check "no key anywhere: a TODO, exit 0, nothing installed" eval '[ $rc = 0 ] && says "TODO: age public key" && [ ! -e "$DST" ] && [ -d "$R/etc/claw" ]'
printf '# laptop key, 2026-11\n%s\n\n' "$K1" > "$SRC"
run
check "a recipients file with a comment: installed, mode 644" eval '[ $rc = 0 ] && cmp -s "$SRC" "$DST" && [ "$(stat -c %a "$DST")" = 644 ] && says "installed /etc/claw/backup.age.pub from the repo (1 key(s))"'
run
check "unchanged: quiet" eval '[ $rc = 0 ] && [ ! -s "$T/out" ]'
printf '%s\n%s' "$K1" "$K2" > "$SRC"
run
check "two keys, no final newline: both count, installed" eval '[ $rc = 0 ] && cmp -s "$SRC" "$DST" && says "(2 key(s))"'
good=$(cat "$DST")
for bad in "AGE-SECRET-KEY-1QQQQ" "$K1 extra" "age1short" "ssh-ed25519 AAAA x" "-R /etc/shadow"; do
  printf '%s\n%s\n' "$K1" "$bad" > "$SRC"
  run
  check "refused, installed key kept: ${bad:0:20}" eval '[ $rc = 1 ] && says "not installed" && [ "$(cat "$DST")" = "$good" ]'
done
printf '# only a comment\n\n' > "$SRC"
run
check "no key at all: refused" eval '[ $rc = 1 ] && says "no age1 public key" && [ "$(cat "$DST")" = "$good" ]'
rm "$SRC"; echo "secret" > "$T/elsewhere"; ln -s "$T/elsewhere" "$SRC"
run
check "a symlink (the clone could point it at a root-only file): refused, never copied" eval '[ $rc = 1 ] && says "a regular file: not installed" && [ "$(cat "$DST")" = "$good" ]'
rm "$SRC"; ln -s "$T/missing" "$SRC"
run
check "a dangling symlink: refused too" eval '[ $rc = 1 ] && says "a regular file: not installed"'
rm "$SRC"
run
check "file removed from the repo: the installed key stays, no TODO" eval '[ $rc = 0 ] && [ "$(cat "$DST")" = "$good" ] && ! says TODO'

echo; [ $fails = 0 ] && echo "all backup-key tests passed" || { echo "$fails failed"; exit 1; }
