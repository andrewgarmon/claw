#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc is read inside eval'd check strings
# Tests for infra/claw-denywatch: new DENY lines in the broker logs fail the ping (sanitised,
# capped), claw-smoke's own expected refusals inside a recorded run window don't, the first run
# doesn't replay history, and a log rotated with copytruncate is read without losing lines.
# Runs a copy pointed at a temp dir; id and curl are faked. Usage: bash infra/tests/claw-denywatch.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
[ -d "$T" ] || { echo "FAIL no temp dir"; exit 1; }
BIN=$T/bin
DW=$T/claw-denywatch
L=$T/gitbot/agent-git.log
C=$T/calbot/agent-cal.log
W=$T/smoke-windows
mkdir -p "$BIN" "$T/gitbot" "$T/calbot"
sed -e "s|^export LC_ALL=C PATH=.*|export LC_ALL=C PATH=$BIN:/usr/bin:/bin|" \
    -e "s|^LOGS=.*|LOGS=$T/broker-logs|" -e "s|^STATE=.*|STATE=$T/state|" \
    -e "s|^URL_FILE=.*|URL_FILE=$T/url|" -e "s|^SMOKE_WINDOWS=.*|SMOKE_WINDOWS=$W|" "$INFRA/claw-denywatch" > "$DW"
[ "$(grep -c "$T" "$DW")" = 5 ] || { echo "FAIL could not point claw-denywatch at the test dir (did its constants change?)"; exit 1; }
printf '#!/bin/bash\n[ "$1" = -u ] && echo 0 || /usr/bin/id "$@"\n' > "$BIN/id"
printf '#!/bin/bash\nwhile [ $# -gt 1 ]; do [ "$1" = --data-raw ] && { msg=$2; shift; }; shift; done\nprintf "%%s | %%s\\n" "$1" "$msg" >> "%s/pings"\n' "$T" > "$BIN/curl"
chmod +x "$BIN/id" "$BIN/curl"
printf 'git %s\ncal %s\n' "$L" "$C" > "$T/broker-logs"

fails=0
run() { : > "$T/pings"; bash "$DW" > "$T/out" 2>&1; rc=$?; }
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out:   /' "$T/out"; sed 's/^/     pings: /' "$T/pings"; fails=$((fails + 1)); fi
}
pinged() { grep -q "^https://hc.example/dw$1 | " "$T/pings" && grep -q -- "$2" "$T/pings"; }   # a ping body spans lines
fail_ping() { grep -q "^https://hc.example/dw/fail | " "$T/pings"; }
now() { date -Is; }
deny() { echo "$(now) caller=$1 DENY $2" >> "${3:-$L}"; }

echo "$(now) caller=openclaw ISSUE claw x" > "$L"; deny openclaw "old refusal from before the watch"
run
check "no ping URL: says so, exit 1 (nothing pinged)" eval '[ $rc = 1 ] && grep -q "no ping URL" "$T/out" && [ ! -s "$T/pings" ]'
echo "https://hc.example/dw" > "$T/url"
rm -rf "${T:?}/state"
run
check "first run: history isn't replayed, success ping" eval '[ $rc = 0 ] && pinged "" "no broker refusals" && ! fail_ping'
run
check "no new lines: success again" eval '[ $rc = 0 ] && pinged "" "no broker refusals"'
echo "$(now) caller=openclaw ISSUE claw ok" >> "$L"
run
check "new lines without DENY: success" eval '[ $rc = 0 ] && ! fail_ping'
deny openclaw $'bad repo name: x\e[31m\x07 evil'
run
check "a new DENY: /fail with the count and the line, control characters stripped" \
  eval '[ $rc = 1 ] && pinged /fail "1 broker refusal" && pinged /fail "git: .*caller=openclaw DENY bad repo name: x\[31m evil" && ! grep -q $'"'"'\e'"'"' "$T/pings"'
run
check "reported once: the next run is clear" eval '[ $rc = 0 ] && ! fail_ping'
deny openclaw "calendar thing" "$C"
run
check "every listed broker is read (cal too)" eval '[ $rc = 1 ] && pinged /fail "cal: .*DENY calendar thing"'

# claw-smoke's own refusals: skipped only inside a recorded window, from the expected caller
S1="only claw-backup (openclaw) pushes state backups (claw-state refused for coder)"
S2="state backups go to claw-state on agent/state/<host>, and claw-state takes nothing else (claw-state claude/claw-smoke refused)"
t0=$(date +%s); deny coder "$S1"; deny openclaw "$S2"; echo "$t0 $(date +%s)" >> "$W"
run
check "claw-smoke's two refusals inside its run window: not an alert" eval '[ $rc = 0 ] && ! fail_ping'
echo "$(date -Is -d '-1 hour') caller=coder DENY $S1" >> "$L"
run
check "the same refusal outside any window: alert" eval '[ $rc = 1 ] && pinged /fail "1 broker refusal"'
deny openclaw "$S1"
run
check "the smoke message from another caller: alert" eval '[ $rc = 1 ] && pinged /fail "caller=openclaw DENY only claw-backup"'
deny coder "$S1 extra"
run
check "a near-copy of the smoke message: alert" eval '[ $rc = 1 ]'

for i in 1 2 3 4 5 6 7; do deny openclaw "probe $i"; done
run
check "many refusals: all counted, five shown" eval '[ $rc = 1 ] && pinged /fail "7 broker refusal" && [ "$(grep -o "probe [0-9]" "$T/pings" | wc -l)" = 5 ]'
deny openclaw "$(printf 'x%.0s' $(seq 400))"
run
check "a long line is capped" eval '[ $rc = 1 ] && [ "$(grep -o "xxxx*" "$T/pings" | awk "{ print length }" | sort -n | tail -1)" -lt 250 ]'

# rotation with copytruncate: the rest of the rotated copy, then the new log from the top
deny openclaw "before rotation"
cp "$L" "$L.1"; : > "$L"; deny openclaw "after rotation"
run
check "copytruncate rotation: the unread end of .1 and the new log are both read" \
  eval '[ $rc = 1 ] && pinged /fail "2 broker refusal" && pinged /fail "before rotation" && pinged /fail "after rotation"'
run
check "after rotation: clear" eval '[ $rc = 0 ]'
# a rotation the log has already grown back past (an agent flooding it with allowed calls): the new
# .1 gives it away
deny openclaw "probe before a quiet rotation"
cp "$L" "$L.new1"; mv -f "$L.new1" "$L.1"; : > "$L"
for i in $(seq 200); do echo "$(now) caller=openclaw ISSUE-LIST claw padding padding padding $i" >> "$L"; done
deny openclaw "probe after a quiet rotation"
run
check "rotation hidden by regrowth (new .1, log past the old offset): nothing missed" \
  eval '[ $rc = 1 ] && pinged /fail "2 broker refusal" && pinged /fail "probe before a quiet rotation" && pinged /fail "probe after a quiet rotation"'
mv "$L" "$T/real.log"; ln -s "$T/real.log" "$L"; deny openclaw "via symlink" "$T/real.log"
run
check "a log that's a symlink is ignored" eval '[ $rc = 0 ]'
rm -f "$L"; mv "$T/real.log" "$L"
echo "garbage" > "$T/state/git.pos"; deny openclaw "after bad state"
run
check "unreadable position file: reads from the top, no crash" eval '[ $rc = 1 ] && pinged /fail "after bad state"'

echo; [ $fails = 0 ] && echo "all claw-denywatch tests passed" || { echo "$fails failed"; exit 1; }
