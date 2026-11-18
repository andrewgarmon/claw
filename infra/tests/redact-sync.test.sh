#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc is read inside eval'd check strings
# Tests for infra/redact-sync (redact.txt -> the PERSONAL_DENYLIST secret) and infra/fail-ping,
# with fake id/gh/curl in a temp dir. No entry may ever appear in output or logs.
# Usage: bash infra/tests/redact-sync.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
[ -d "$T" ] || { echo "FAIL no temp dir"; exit 1; }
BIN=$T/bin
H=$T/gitbot
RS=$T/redact-sync
FP=$T/fail-ping
mkdir -p "$BIN" "$H/.config"
sed -e "s|^export HOME=.*|export HOME=$H|" -e "s|^export PATH=.*|export PATH=$BIN:/usr/bin:/bin LC_ALL=C|" "$INFRA/redact-sync" > "$RS"
[ "$(grep -c "$T" "$RS")" = 2 ] || { echo "FAIL could not point redact-sync at the test dir"; exit 1; }
sed -e "s|^export PATH=.*|export PATH=$BIN:/usr/bin:/bin LC_ALL=C|" -e "s|^ENV_FILE=.*|ENV_FILE=$T/env|" "$INFRA/fail-ping" > "$FP"
[ "$(grep -c "$T" "$FP")" = 2 ] || { echo "FAIL could not point fail-ping at the test dir"; exit 1; }
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
echo openclaw > "$T/whoami"
run
check "not running as gitbot: refused, nothing read or sent" eval '[ $rc = 1 ] && grep -q "run as gitbot" "$T/out" && [ ! -e "$T/gh.args" ]'
rm "$T/whoami"

# fail-ping (OnFailure): pings /fail with the unit name; no URL configured is not an error
bash "$FP" "claw-redact-sync.service" > "$T/out" 2>&1; rc=$?
check "fail-ping without a URL: exit 0, says so, nothing pinged" eval '[ $rc = 0 ] && grep -q "no HEALTHCHECKS_PING_URL" "$T/out" && [ ! -e "$T/pings" ]'
echo 'HEALTHCHECKS_PING_URL="https://hc.example/u"' > "$T/env"
bash "$FP" 'claw-redact-sync.service;rm -rf /' > "$T/out" 2>&1; rc=$?
check "fail-ping: /fail with the unit name (sanitised)" \
  eval '[ $rc = 0 ] && grep -q "^https://hc.example/u/fail | claw-redact-sync.servicerm-rf failed on" "$T/pings"'

echo; [ $fails = 0 ] && echo "all redact-sync tests passed" || { echo "$fails failed"; exit 1; }
