#!/bin/bash
# Tests for infra/claw-backup: a failed or refused push pings /fail; a good one doesn't.
# Runs a copy with HOME and PATH pointed into a temp dir; agent-git (via sudo) and curl are faked.
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=$T/home BIN=$T/bin CB=$T/claw-backup
mkdir -p "$H/.openclaw/workspace" "$BIN"
sed -e "s|^export HOME=/home/openclaw$|export HOME=$H|" \
    -e "s|^export PATH=/usr/local/bin:/usr/bin:/bin$|export PATH=$BIN:/usr/bin:/bin|" "$D/claw-backup" > "$CB"
[ "$(grep -c "^export HOME=$H$\|^export PATH=$BIN:" "$CB")" = 2 ] || { echo "FAIL could not point claw-backup at the test dir"; exit 1; }

# fake sudo -> agent-git: reads the body+bundle, refuses like a non-fast-forward while $T/reject exists
cat > "$BIN/sudo" <<EOF
#!/bin/bash
cat > /dev/null
[ -e "$T/reject" ] && { echo "agent-git: refused: this would replace the history (non-fast-forward)" >&2; exit 1; }
echo "https://github.com/x/claw-state/pull/1"
EOF
cat > "$BIN/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/curl.log"
EOF
chmod +x "$BIN"/*

host=$(hostname -s | tr -c 'A-Za-z0-9._\n-' '-')
git init -q -b "agent/state/$host" "$H/.openclaw/state-backup"
echo "HEALTHCHECKS_PING_URL=https://hc.example/check" > "$H/.openclaw/.env"

pass=0 fail=0
check() { if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; sed 's/^/     /' "$T/out" "$T/curl.log" 2>/dev/null; fail=$((fail+1)); fi; }
# shellcheck disable=SC2034  # rc is read inside check's eval strings
run() { : > "$T/curl.log"; bash "$CB" > "$T/out" 2>&1; rc=$?; }

echo "v1" > "$H/.openclaw/workspace/MEMORY.md"
run
check "good push: exit 0, no fail ping" '[ $rc = 0 ] && grep -q "pushed" "$T/out" && [ ! -s "$T/curl.log" ]'

echo "v2" > "$H/.openclaw/workspace/MEMORY.md"; touch "$T/reject"
run
check "refused push: non-zero exit and a /fail ping with the reason" \
  '[ $rc != 0 ] && grep -q "hc.example/check/fail" "$T/curl.log" && grep -q "claw-backup failed on" "$T/curl.log"'
check "refused push: not recorded as pushed, so the next run retries" '! grep -q "$(git -C "$H/.openclaw/state-backup" rev-parse HEAD)" "$H/.cache/claw-backup/pushed"'

: > "$H/.openclaw/.env"
run
check "no ping URL: still fails, says the failure wasn't reported" '[ $rc != 0 ] && [ ! -s "$T/curl.log" ] && grep -q "failure not reported" "$T/out"'
rm "$T/reject"

run
check "nothing new after a good retry: exit 0, no ping" '[ $rc = 0 ] && [ ! -s "$T/curl.log" ]'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
