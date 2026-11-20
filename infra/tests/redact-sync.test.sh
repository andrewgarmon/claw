#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc is read inside eval'd check strings
# Tests for infra/redact-sync (redact.txt -> the PERSONAL_DENYLIST secret) and infra/unit-ping,
# with fake id/gh/curl in a temp dir. No entry may ever appear in output or logs.
# Usage: bash infra/tests/redact-sync.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
[ -d "$T" ] || { echo "FAIL no temp dir"; exit 1; }
BIN=$T/bin
H=$T/gitbot
RS=$T/redact-sync
UP=$T/unit-ping
mkdir -p "$BIN" "$H/.config"
sed -e "s|^export HOME=.*|export HOME=$H|" -e "s|^export PATH=.*|export PATH=$BIN:/usr/bin:/bin LC_ALL=C|" "$INFRA/redact-sync" > "$RS"
[ "$(grep -c "$T" "$RS")" = 2 ] || { echo "FAIL could not point redact-sync at the test dir"; exit 1; }
sed -e "s|^export PATH=.*|export PATH=$BIN:/usr/bin:/bin LC_ALL=C|" "$INFRA/unit-ping" > "$UP"
[ "$(grep -c "$T" "$UP")" = 1 ] || { echo "FAIL could not point unit-ping at the test dir"; exit 1; }
printf '#!/bin/bash\n[ "$1" = -un ] && { cat "%s/whoami" 2>/dev/null || echo gitbot; } || /usr/bin/id "$@"\n' "$T" > "$BIN/id"
# fake gh: records argv, the token it got and stdin; fails if $T/gh_fail exists
printf '#!/bin/bash\nprintf "[%%s]" "$@" >> "%s/gh.args"; echo >> "%s/gh.args"\necho "$GH_TOKEN" > "%s/gh.token"\ncat > "%s/gh.stdin"\n[ ! -e "%s/gh_fail" ]\n' "$T" "$T" "$T" "$T" "$T" > "$BIN/gh"
printf '#!/bin/bash\nwhile [ $# -gt 1 ]; do [ "$1" = --data-raw ] && { msg=$2; shift; }; shift; done\nprintf "%%s | %%s\\n" "$1" "$msg" >> "%s/pings"\n' "$T" > "$BIN/curl"
chmod +x "$BIN"/*
echo "ghp_testtoken" > "$H/.config/redact-sync-token"; echo "ghp_agentgit" > "$H/.config/gh-token"

fails=0
run() { rm -f "$T/gh.args" "$T/gh.stdin"; bash "$RS" > "$T/out" 2>&1; rc=$?; }
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out: /' "$T/out"; fails=$((fails + 1)); fi
}
no_entries() { ! grep -qi -e "Alexandra" -e "Springfield" -e "555-0100" "$T/out" "$H/agent-git.log" 2>/dev/null; }

printf '# names\r\n  Alexandra  \r\n\nSpringfield\n   \n# phone\n555-0100\n' > "$H/.config/redact.txt"
run
check "changed list: gh secret set with exactly the normalised list on stdin, its own token (not agent-git's)" \
  eval '[ $rc = 0 ] && grep -qx "\[secret\]\[set\]\[PERSONAL_DENYLIST\]\[-R\]\[andrewgarmon/claw\]" "$T/gh.args" && [ "$(cat "$T/gh.stdin")" = "$(printf "Alexandra\nSpringfield\n555-0100")" ] && [ "$(cat "$T/gh.token")" = ghp_testtoken ]'
check "hash written, one log line with the count, no entries anywhere" \
  eval '[ -s "$H/.cache/redact-sync/hash" ] && grep -q "REDACT-SYNC updated 3 entries" "$H/agent-git.log" && no_entries'
run
check "unchanged list: no gh call" eval '[ $rc = 0 ] && [ ! -e "$T/gh.args" ] && grep -q "unchanged (3 entries)" "$T/out"'
printf '  Alexandra\nSpringfield  \n555-0100\n# a new comment\n' > "$H/.config/redact.txt"
run
check "only whitespace and comments changed: still unchanged" eval '[ $rc = 0 ] && [ ! -e "$T/gh.args" ]'
h=$(cat "$H/.cache/redact-sync/hash")
printf '# only comments\n\n   \n' > "$H/.config/redact.txt"
run
check "empty list (comments and blanks only): no gh call, exit 1, hash kept" \
  eval '[ $rc = 1 ] && [ ! -e "$T/gh.args" ] && grep -q "redact.txt is empty" "$T/out" && [ "$(cat "$H/.cache/redact-sync/hash")" = "$h" ] && grep -q "REDACT-SYNC failed" "$H/agent-git.log"'
rm "$H/.config/redact.txt"
run
check "missing list: same" eval '[ $rc = 1 ] && [ ! -e "$T/gh.args" ]'
printf 'Alexandra\nSpringfield\n555-0100\nNewword\n' > "$H/.config/redact.txt"; touch "$T/gh_fail"
run
check "gh fails: exit 1, hash not updated (retried next run), no entries shown" \
  eval '[ $rc = 1 ] && [ "$(cat "$H/.cache/redact-sync/hash")" = "$h" ] && grep -q "Secrets: read and write" "$T/out" && no_entries && ! grep -qi newword "$T/out" "$H/agent-git.log"'
rm "$T/gh_fail"; mv "$H/.config/redact-sync-token" "$T/tok"
run
check "no token of its own: fails, never falls back to agent-git's" eval '[ $rc = 1 ] && grep -q "no token in" "$T/out" && [ ! -e "$T/gh.args" ]'
mv "$T/tok" "$H/.config/redact-sync-token"
run
check "next run retries and succeeds" eval '[ $rc = 0 ] && [ -e "$T/gh.args" ] && [ "$(cat "$H/.cache/redact-sync/hash")" != "$h" ] && grep -q "updated 4 entries" "$H/agent-git.log"'
run
check "unchanged, last upload under a day ago: no gh call" eval '[ $rc = 0 ] && [ ! -e "$T/gh.args" ]'
touch -d '25 hours ago' "$H/.cache/redact-sync/hash"
run
check "unchanged but last upload over a day ago: uploaded again (a deleted secret comes back)" \
  eval '[ $rc = 0 ] && [ -e "$T/gh.args" ] && [ -n "$(find "$H/.cache/redact-sync/hash" -mmin -5)" ]'
echo openclaw > "$T/whoami"
run
check "not running as gitbot: refused, nothing read or sent" eval '[ $rc = 1 ] && grep -q "run as gitbot" "$T/out" && [ ! -e "$T/gh.args" ]'
rm "$T/whoami"

# unit-ping (ExecStopPost=+): success or /fail to the check in a root-only URL file; no URL is not an error
up() { rm -f "$T/pings"; SERVICE_RESULT=$1 EXIT_STATUS=$2 bash "$UP" "$3" "$4" > "$T/out" 2>&1; rc=$?; }
up exit-code 1 claw-redact-sync.service "$T/none.url"
check "unit-ping without a URL file: exit 0, says so, nothing pinged" eval '[ $rc = 0 ] && grep -q "no ping URL" "$T/out" && [ ! -e "$T/pings" ]'
echo 'https://hc.example/rs' > "$T/rs.url"
up success 0 claw-redact-sync.service "$T/rs.url"
check "unit-ping after a good run: success ping" eval '[ $rc = 0 ] && grep -q "^https://hc.example/rs | claw-redact-sync.service ok on" "$T/pings"'
up exit-code 1 'claw-redact-sync.service;rm -rf /' "$T/rs.url"
check "unit-ping after a failed run: /fail with the result and the unit name (sanitised)" \
  eval '[ $rc = 0 ] && grep -q "^https://hc.example/rs/fail | claw-redact-sync.servicerm-rf failed (exit-code, exit 1) on" "$T/pings"'
echo 'not a url; touch /tmp/x' > "$T/rs.url"
up exit-code 1 claw-redact-sync.service "$T/rs.url"
check "unit-ping with a malformed URL: nothing pinged" eval '[ $rc = 0 ] && [ ! -e "$T/pings" ]'
grep -q '^ExecStopPost=+/usr/local/lib/claw/unit-ping %n /etc/claw/redact-sync.url$' "$INFRA/claw-redact-sync.service"
check "the service pings through unit-ping as root, with a URL under /etc/claw" eval '[ $? = 0 ]'

echo; [ $fails = 0 ] && echo "all redact-sync tests passed" || { echo "$fails failed"; exit 1; }
