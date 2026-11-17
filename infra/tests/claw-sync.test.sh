#!/usr/bin/env bash
# shellcheck disable=SC2034  # c1..c17 and rc are read inside eval’d check strings
# Tests for infra/claw-sync against a scratch git origin and fake openclaw/systemctl/curl.
# Touches nothing outside a temp dir. Usage: bash infra/tests/claw-sync.test.sh
set -uo pipefail
SYNC=$(cd "$(dirname "$0")/.." && pwd)/claw-sync
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CLAW_SYNC_HOME=$T/home CLAW_SYNC_HEALTH_WAIT=0 CLAW_SYNC_IDLE_WAIT=0
export CLAW_SYNC_FULL_EVERY=0   # every run is a full run, except in the idle fast-path tests at the end
export CLAW_SYNC_FETCH_FAIL_RUNS=3   # the default (15) is checked separately at the end
unset HEALTHCHECKS_PING_URL
H=$CLAW_SYNC_HOME BIN=$H/.npm-global/bin
mkdir -p "$BIN"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Fake gateway: "running" config is the openclaw.json copied at restart time.
# A running config containing CRASH never becomes healthy; $H/gw_down simulates an outage.
# $H/restart_rc makes restart exit non-zero; $H/kill_on_restart kills claw-sync mid-deploy (reboot/OOM)
# on the Nth restart of the run (N = its content, default 1); $H/kill_on_validate kills it during validate.
cat > "$BIN/systemctl" <<EOF
#!/bin/bash
case "\$*" in
  "--user restart openclaw-gateway")
    cp "$H/.openclaw/openclaw.json" "$H/gw_cfg"; echo restart >> "$H/restarts"
    [ -e "$H/kill_on_restart" ] && [ "\$(wc -l < "$H/restarts")" -ge "\$(cat "$H/kill_on_restart" 2>/dev/null || echo 1)" ] && kill -9 \$PPID
    [ -e "$H/restart_rc" ] && exit 1
    exit 0 ;;
  "--user is-active -q openclaw-gateway") [ ! -e "$H/gw_down" ] && ! grep -q CRASH "$H/gw_cfg" ;;
  *) echo "unexpected systemctl \$*" >&2; exit 2 ;;
esac
EOF
cat > "$BIN/openclaw" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "config validate") [ -e "$H/kill_on_validate" ] && kill -9 "\$(ps -o ppid= -p \$PPID)"   # claw-sync, not the \$( ) subshell
    grep -q INVALID "$H/.openclaw/openclaw.json" && { echo "Config needs correction: bad key"; exit 1; }; echo "Config valid" ;;
  "gateway health") echo health >> "$H/health"; [ ! -e "$H/gw_down" ] && ! grep -q CRASH "$H/gw_cfg" ;;
  *) exit 2 ;;
esac
EOF
cat > "$BIN/curl" <<EOF
#!/bin/bash
while [ \$# -gt 1 ]; do [ "\$1" = --data-raw ] && { msg=\$2; shift; }; shift; done
echo "\$1 | \$msg" >> "$H/pings"
EOF
chmod +x "$BIN"/*

git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/dev" 2>/dev/null
git -C "$T/dev" checkout -q -b main
commit() {  # commit <openclaw.json content> [other file]
  echo "$1" > "$T/dev/openclaw.json"; [ -n "${2:-}" ] && echo "$RANDOM" > "$T/dev/$2"
  git -C "$T/dev" add -A && git -C "$T/dev" commit -qm "$1" && git -C "$T/dev" push -q origin main
  git -C "$T/dev" rev-parse HEAD
}
c1=$(commit '{"v":1}')
git clone -q "$T/origin.git" "$H/.openclaw"
echo 'HEALTHCHECKS_PING_URL="https://hc.example/uuid"' > "$H/.openclaw/.env"   # untracked, like prod
cp "$H/.openclaw/openclaw.json" "$H/gw_cfg"

fails=0
run() { : > "$H/pings"; : > "$H/restarts"; : > "$H/health"; (bash "$SYNC" > "$T/out" 2>&1; exit $?) 2>/dev/null; rc=$?; }  # subshell keeps "Killed" notices quiet
check() {  # check <name> <condition...>
  local name=$1; shift
  # the ERR trap must only fire on real crashes, not on handled failures
  if "$@" && ! grep -q crashed "$H/pings"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" "$H/pings"; fails=$((fails + 1)); fi
}
head_is() { [ "$(git -C "$H/.openclaw" rev-parse HEAD)" = "$1" ]; }
pinged() { grep -q "^https://hc.example/uuid$1 | .*$2" "$H/pings"; }
restarts() { [ "$(wc -l < "$H/restarts")" -eq "$1" ]; }
S=$H/.cache/claw-sync
not_bad() { ! grep -qx "$1" "$S/bad" 2>/dev/null; }

run; check "idle + healthy: success ping, no restart" \
  eval '[ $rc = 0 ] && head_is $c1 && pinged "" "up to date" && restarts 0'

c2=$(commit '{"v":1}' workspace.md)
run; check "non-config change: synced, no restart, success ping" \
  eval '[ $rc = 0 ] && head_is $c2 && restarts 0 && pinged "" "synced"'

c3=$(commit '{"v":3}')
run; check "config change: validated, restarted, success ping" \
  eval '[ $rc = 0 ] && head_is $c3 && restarts 1 && pinged "" "deployed"'

c4=$(commit '{"v":4,"INVALID":1}')
run; check "invalid config: rolled back, no restart, fail ping" \
  eval '[ $rc = 1 ] && head_is $c3 && restarts 0 && pinged /fail "INVALID" && grep -q "bad key" "$T/out"'
run; check "known-bad main: skipped, keeps failing ping" \
  eval '[ $rc = 1 ] && head_is $c3 && restarts 0 && pinged /fail "marked bad"'

c5=$(commit '{"v":5,"CRASH":1}')
run; check "gateway won't come up: rolled back to last good + restarted, fail ping" \
  eval '[ $rc = 1 ] && head_is $c3 && restarts 2 && pinged /fail "rolled back to ${c3:0:7}" && ! grep -q CRASH "$H/gw_cfg"'
run; check "after rollback: main still bad, no further restarts" \
  eval '[ $rc = 1 ] && head_is $c3 && restarts 0 && pinged /fail "marked bad"'

c6=$(commit '{"v":6}')
run; check "fix merged: deploys again" \
  eval '[ $rc = 0 ] && head_is $c6 && restarts 1 && pinged "" "deployed"'

echo '{"drift":1}' > "$H/.openclaw/openclaw.json"
run; check "local drift in openclaw.json: reverted + restarted" \
  eval '[ $rc = 0 ] && head_is $c6 && git -C "$H/.openclaw" diff --quiet && restarts 1'

echo '{"drift":2}' > "$H/.openclaw/openclaw.json"; touch "$H/gw_down"
run; check "drift revert fails health: fail ping, no rollback, main not marked bad" \
  eval '[ $rc = 1 ] && head_is $c6 && restarts 1 && pinged /fail "known-good" && not_bad $c6 && [ ! -e "$S/pending" ]'
rm "$H/gw_down"
run; check "after transient drift failure: healthy again, success ping" \
  eval '[ $rc = 0 ] && head_is $c6 && restarts 0 && pinged "" "up to date"'

touch "$H/gw_down"
run; check "gateway down while idle: fail ping, no rollback" \
  eval '[ $rc = 1 ] && head_is $c6 && restarts 0 && pinged /fail "not healthy"'
c7=$(commit '{"v":7}')
run; check "rollback can't recover: says so loudly, commit not marked bad" \
  eval '[ $rc = 1 ] && head_is $c6 && restarts 2 && pinged /fail "did NOT recover" && not_bad $c7'
rm "$H/gw_down"
run; check "outage over: deploys pending commit" \
  eval '[ $rc = 0 ] && head_is $c7 && pinged "" "deployed"'

touch "$H/restart_rc"
c9=$(commit '{"v":9,"CRASH":1}')
run; check "restart exits non-zero on a broken config: still rolls back, no crash ping" \
  eval '[ $rc = 1 ] && head_is $c7 && restarts 2 && pinged /fail "rolled back to ${c7:0:7}" && ! grep -q CRASH "$H/gw_cfg"'
c10=$(commit '{"v":10}')
run; check "restart exits non-zero but gateway healthy: deployed" \
  eval '[ $rc = 0 ] && head_is $c10 && restarts 1 && pinged "" "deployed"'
rm "$H/restart_rc"

echo 1 > "$H/kill_on_restart"
c11=$(commit '{"v":11,"CRASH":1}')
run; check "killed mid-deploy: pending marker left, no ping" \
  eval '[ $rc = 137 ] && head_is $c11 && [ "$(cat "$S/pending")" = $c11 ] && [ ! -s "$H/pings" ]'
rm "$H/kill_on_restart"
run; check "next run after kill: re-validates, restarts, rolls back" \
  eval '[ $rc = 1 ] && head_is $c10 && restarts 2 && pinged /fail "rolled back to ${c10:0:7}" && [ ! -e "$S/pending" ] && grep -q interrupted "$T/out"'
echo 1 > "$H/kill_on_restart"
c12=$(commit '{"v":12}')
run; rm "$H/kill_on_restart"
run; check "killed mid-deploy of a good commit: next run restarts + confirms it healthy" \
  eval '[ $rc = 0 ] && head_is $c12 && restarts 1 && pinged "" "deployed ${c12:0:7}" && [ ! -e "$S/pending" ]'

echo 2 > "$H/kill_on_restart"
c13=$(commit '{"v":13,"CRASH":1}')
run; check "killed mid-rollback: bad marked, pending kept" \
  eval '[ $rc = 137 ] && head_is $c12 && [ "$(cat "$S/bad")" = $c13 ] && [ "$(cat "$S/pending")" = $c13 ]'
rm "$H/kill_on_restart"
run; check "next run after killed rollback: redoes rollback" \
  eval '[ $rc = 1 ] && head_is $c12 && restarts 1 && pinged /fail "rolled back to ${c12:0:7}" && ! grep -q CRASH "$H/gw_cfg" && [ ! -e "$S/pending" ]'
c14=$(commit '{"v":14}')
run; check "fix after killed rollback: deploys" \
  eval '[ $rc = 0 ] && head_is $c14 && pinged "" "deployed"'

touch "$H/kill_on_validate"
c15=$(commit '{"v":15,"INVALID":1}')
run; check "killed during validate: pending marker already written, no restart" \
  eval '[ $rc = 137 ] && head_is $c15 && [ "$(cat "$S/pending")" = $c15 ] && restarts 0'
rm "$H/kill_on_validate"
run; check "next run after kill in validate: re-validates, rolls back unvalidated config" \
  eval '[ $rc = 1 ] && head_is $c14 && [ "$(cat "$S/bad")" = $c15 ] && [ ! -e "$S/pending" ] && ! grep -q INVALID "$H/gw_cfg"'

echo '{"drift":3}' > "$H/.openclaw/openclaw.json"
run; check "drift while main is marked bad: still reverted + restarted, keeps failing ping" \
  eval '[ $rc = 1 ] && head_is $c14 && git -C "$H/.openclaw" diff --quiet && restarts 1 && pinged /fail "marked bad"'

# The agent (openclaw) can write the state dir: forged commits that aren't on main must be ignored.
git -C "$H/.openclaw" checkout -q -b evil && echo '{"evil":1}' > "$H/.openclaw/openclaw.json"
git -C "$H/.openclaw" commit -qam evil; evil=$(git -C "$H/.openclaw" rev-parse HEAD)
git -C "$H/.openclaw" checkout -q main
echo "$evil" > "$S/good"
c16=$(commit '{"v":16,"CRASH":1}')
run; check "forged good not on main: rollback goes to real last commit, not the forged one" \
  eval '[ $rc = 1 ] && head_is $c14 && pinged /fail "rolled back to ${c14:0:7}" && ! grep -q evil "$H/gw_cfg"'
echo "$evil" > "$S/pending"
run; check "forged pending not on main: ignored" \
  eval '[ $rc = 1 ] && head_is $c14 && [ ! -e "$S/pending" ] && grep -q "ignoring pending" "$T/out" && restarts 0'
c17=$(commit '{"v":17}')
run; check "fix after forged state: deploys" \
  eval '[ $rc = 0 ] && head_is $c17 && pinged "" "deployed"'

rm "$H/.openclaw/.env"
c8=$(commit '{"v":8}')
run; check "no .env / no ping URL: still deploys, no pings" \
  eval '[ $rc = 0 ] && head_is $c8 && [ ! -s "$H/pings" ]'

echo 'HEALTHCHECKS_PING_URL=https://hc.example/uuid' > "$H/.openclaw/.env"
mv "$T/origin.git" "$T/gone.git"
run; check "one fetch failure: no fail ping, still reports healthy" \
  eval '[ $rc = 0 ] && head_is $c8 && pinged "" "up to date" && ! pinged /fail ""'
run; run; check "3 fetch failures in a row: fail ping" \
  eval '[ $rc = 1 ] && pinged /fail "git fetch failed 3 runs in a row"'
mv "$T/gone.git" "$T/origin.git"
run; check "fetch recovers: counter reset" \
  eval '[ $rc = 0 ] && pinged "" "up to date" && [ ! -e "$S/fetch-fails" ]'
mv "$T/origin.git" "$T/gone.git"
run; check "fetch failure after recovery: counts from 1 again" \
  eval '[ $rc = 0 ] && [ "$(cat "$S/fetch-fails")" = 1 ] && ! pinged /fail ""'
mv "$T/gone.git" "$T/origin.git"

# Idle fast path: with the timer every minute, idle runs within FULL_EVERY of the last good full run
# skip the health check and ping. Anything that needs deploying always gets a full run.
export CLAW_SYNC_FULL_EVERY=300
quiet() { [ $rc = 0 ] && [ ! -s "$H/pings" ] && [ ! -s "$H/health" ] && [ ! -s "$T/out" ]; }
rm -f "$S/last-full"
run; check "full run records last-full" eval '[ $rc = 0 ] && pinged "" "up to date" && [ -s "$S/last-full" ]'
run; check "idle within 5 min: no health check, no ping, no output" eval 'quiet'
echo $(( $(date +%s) - 301 )) > "$S/last-full"
run; check "idle after 5 min: full run with health check + ping" \
  eval '[ $rc = 0 ] && [ -s "$H/health" ] && pinged "" "up to date"'
c18=$(commit '{"v":8}' workspace.md)
run; check "main moved within 5 min: synced + pinged" eval '[ $rc = 0 ] && head_is $c18 && pinged "" "synced"'
c19=$(commit '{"v":19}')
run; check "config change within 5 min: deployed" eval '[ $rc = 0 ] && head_is $c19 && restarts 1 && pinged "" "deployed"'
echo '{"drift":4}' > "$H/.openclaw/openclaw.json"
run; check "drift within 5 min: reverted + restarted" \
  eval '[ $rc = 0 ] && head_is $c19 && git -C "$H/.openclaw" diff --quiet && restarts 1'
echo "$c19" > "$S/pending"
run; check "pending marker within 5 min: resumed" eval '[ $rc = 0 ] && restarts 1 && pinged "" "deployed ${c19:0:7}" && [ ! -e "$S/pending" ]'
echo "$c19" > "$S/bad"; echo "$c19" > "$S/good"; date +%s > "$S/last-full"
run; check "main marked bad within 5 min: keeps failing ping" eval '[ $rc = 1 ] && pinged /fail "marked bad"'
rm "$S/bad"
echo $(( $(date +%s) + 86400 )) > "$S/last-full"
run; check "forged future last-full while idle: full run" eval '[ $rc = 0 ] && pinged "" "up to date"'
echo $(( $(date +%s) + 86400 )) > "$S/last-full"
c20=$(commit '{"v":20}')
run; check "forged future last-full: doesn't suppress a deploy" eval '[ $rc = 0 ] && head_is $c20 && pinged "" "deployed"'
echo 'not-a-number' > "$S/last-full"
run; check "garbage last-full: full run" eval '[ $rc = 0 ] && pinged "" "up to date"'
echo 08 > "$S/last-full"
run; check "leading-zero last-full (octal trap): full run, no arithmetic error" eval '[ $rc = 0 ] && pinged "" "up to date" && ! grep -q "too great" "$T/out"'
echo 0000000001 > "$S/last-full"
run; check "zero-padded old last-full: full run" eval '[ $rc = 0 ] && pinged "" "up to date"'
echo $(( $(date +%s) - 301 )) > "$S/last-full"; touch "$H/gw_down"
run; check "unhealthy full run: fail ping" eval '[ $rc = 1 ] && pinged /fail "not healthy"'
rm "$H/gw_down"
run; check "after a failed full run: next run is full again" eval '[ $rc = 0 ] && pinged "" "up to date"'
run; check "then quiet again" eval 'quiet'
mv "$T/origin.git" "$T/gone.git"
run; check "fetch failure while idle: still counted" eval '[ "$(cat "$S/fetch-fails")" = 1 ]'
run; run; check "3 fetch failures while idle: fail ping" eval '[ $rc = 1 ] && pinged /fail "git fetch failed 3 runs in a row"'
rm "$S/fetch-fails"; unset CLAW_SYNC_FETCH_FAIL_RUNS
for _ in $(seq 14); do run; done
check "default threshold: 14 fetch failures (~14 min) don't fail-ping" eval '[ "$(cat "$S/fetch-fails")" = 14 ] && ! pinged /fail ""'
run; check "default threshold: the 15th does" eval '[ $rc = 1 ] && pinged /fail "git fetch failed 15 runs in a row"'
mv "$T/gone.git" "$T/origin.git"

echo; [ $fails = 0 ] && echo "all claw-sync tests passed" || { echo "$fails failed"; exit 1; }
