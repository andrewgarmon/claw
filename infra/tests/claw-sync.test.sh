#!/usr/bin/env bash
# shellcheck disable=SC2034  # c1..c17 and rc are read inside eval’d check strings
# Tests for infra/claw-sync against a scratch git origin and fake openclaw/systemctl/curl.
# Touches nothing outside a temp dir. Usage: bash infra/tests/claw-sync.test.sh
set -uo pipefail
SYNC=$(cd "$(dirname "$0")/.." && pwd)/claw-sync
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CLAW_SYNC_HOME=$T/home CLAW_SYNC_HEALTH_WAIT=0 CLAW_SYNC_IDLE_WAIT=0
export CLAW_SYNC_FULL_EVERY=0   # every run is a full run, except in the idle fast-path tests at the end
export CLAW_SYNC_FETCH_FAIL_RUNS=3   # the default (15) is checked separately at the end
export CLAW_SYNC_INSTALLED=$T/installed   # claw-install's last installed commit (absent until the infra-pending tests)
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
  "message send") printf '%s\n' "\$*" >> "$H/messages"; [ ! -e "$H/msg_fail" ] ;;
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
cp "$REPO/.gitignore" "$T/dev/.gitignore"   # the real one: what counts as untracked vs ignored state
commit() {  # commit <openclaw.json content> [other file]
  echo "$1" > "$T/dev/openclaw.json"; [ -n "${2:-}" ] && echo "$RANDOM" > "$T/dev/$2"
  git -C "$T/dev" add -A && git -C "$T/dev" commit -qm "$1" && git -C "$T/dev" push -q origin main
  git -C "$T/dev" rev-parse HEAD
}
c1=$(commit '{"v":1}')
git clone -q "$T/origin.git" "$H/.openclaw"
echo 'HEALTHCHECKS_PING_URL="https://hc.example/uuid"' > "$H/.openclaw/.env"   # untracked, like prod
cp "$H/.openclaw/openclaw.json" "$H/gw_cfg"
mkdir -p "$H/.cache/claw-backup" && touch "$H/.cache/claw-backup/last-ok"   # a fresh backup, as on a healthy host

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

c2=$(commit '{"v":1}' README.md)
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
c18=$(commit '{"v":8}' README.md)
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
touch "$H/gw_down"; c21=$(commit '{"v":20}' README.md)
run; check "failure within 5 min of a full run: fail ping" eval '[ $rc = 1 ] && head_is $c21 && pinged /fail "not healthy"'
rm "$H/gw_down"
run; check "next run after that failure is full, not quiet" eval '[ $rc = 0 ] && pinged "" "up to date"'
mv "$T/origin.git" "$T/gone.git"
run; check "fetch failure while idle: still counted" eval '[ "$(cat "$S/fetch-fails")" = 1 ]'
run; run; check "3 fetch failures while idle: fail ping" eval '[ $rc = 1 ] && pinged /fail "git fetch failed 3 runs in a row"'
rm "$S/fetch-fails"; unset CLAW_SYNC_FETCH_FAIL_RUNS
for _ in $(seq 14); do run; done
check "default threshold: 14 fetch failures (~14 min) don't fail-ping" eval '[ "$(cat "$S/fetch-fails")" = 14 ] && ! pinged /fail ""'
run; check "default threshold: the 15th does" eval '[ $rc = 1 ] && pinged /fail "git fetch failed 15 runs in a row"'
mv "$T/gone.git" "$T/origin.git"

# Stale-backup alert: claw-backup touches last-ok on every success; a full run fails the ping when
# it's older than 26h, without clearing last-full (so it rechecks every ~5 min, not every minute).
B=$H/.cache/claw-backup/last-ok
touch -d '27 hours ago' "$B"; rm -f "$S/last-full"
run; check "backup older than 26h: fail ping with the reason" \
  eval '[ $rc = 1 ] && pinged /fail "claw-backup hasn.t succeeded in 27h" && ! pinged "" "up to date"'
check "stale backup keeps last-full, so the next minute stays quiet" eval '[ -s "$S/last-full" ]'
run; check "stale backup: quiet in between" eval 'quiet'
rm -f "$S/last-full"
run; check "stale backup: still failing on the next full run" eval '[ $rc = 1 ] && pinged /fail "27h"'
rm "$B"; rm -f "$S/last-full"
run; check "no last-ok at all: fail ping" eval '[ $rc = 1 ] && pinged /fail "no recorded success"'
touch -d '25 hours ago' "$B"; rm -f "$S/last-full"
run; check "backup 25h old: healthy" eval '[ $rc = 0 ] && pinged "" "up to date"'
touch -d '27 hours ago' "$B"; c22=$(commit '{"v":22}')
run; check "stale backup doesn't block a deploy" eval '[ $rc = 1 ] && head_is $c22 && restarts 1 && pinged /fail "27h"'
touch "$B"; rm -f "$S/last-full"
run; check "backup succeeds again: healthy" eval '[ $rc = 0 ] && pinged "" "up to date"'

# Untracked files (neither tracked nor ignored) are removed and reported; ignored state is kept.
O=$H/.openclaw; rm -f "$S/last-full"
mkdir -p "$O/workspace/skills/new" "$O/skills/extra" "$O/workspace/memory" "$O/state-backup" "$O/workspace/.openclaw/extensions/x" "$O/agents"
for f in workspace/BOOTSTRAP.md workspace/TOOLS.md workspace/skills/new/SKILL.md skills/extra/SKILL.md; do echo planted > "$O/$f"; done
for f in workspace/USER.md workspace/MEMORY.md workspace/memory/x.md state-backup/x workspace/.openclaw/extensions/x/index.ts agents/s.json; do echo state > "$O/$f"; done
run; check "untracked files: removed, named in a fail ping, no restart" \
  eval '[ $rc = 1 ] && restarts 0 && pinged /fail "untracked files removed: .*workspace/BOOTSTRAP.md" && pinged /fail "skills/extra/SKILL.md" && pinged /fail "workspace/skills/new/SKILL.md" && grep -q "removing untracked files" "$T/out"'
check "untracked files are gone" eval '! ls "$O/workspace/BOOTSTRAP.md" "$O/workspace/TOOLS.md" "$O/workspace/skills/new" "$O/skills/extra" 2>/dev/null'
check "... moved, not deleted: under removed/<time>/ with their paths, named in the ping" \
  eval 'q=$(ls -d "$S"/removed/*/ | tail -n1) && [ "$(cat "$q/workspace/BOOTSTRAP.md")" = planted ] && [ -e "$q/workspace/skills/new/SKILL.md" ] && [ -e "$q/skills/extra/SKILL.md" ] && pinged /fail "moved to $S/removed/"'
check "ignored state is kept (.env, USER.md, MEMORY.md, memory/, state-backup/, workspace/.openclaw/, agents/)" \
  eval 'for f in .env workspace/USER.md workspace/MEMORY.md workspace/memory/x.md state-backup/x workspace/.openclaw/extensions/x/index.ts agents/s.json; do [ -e "$O/$f" ] || exit 1; done'
run; check "after the cleanup: healthy again" eval '[ $rc = 0 ] && pinged "" "up to date"'
echo planted > "$O/workspace/HEARTBEAT.md"
run; check "untracked file within 5 min of a full run: not skipped as idle" \
  eval '[ $rc = 1 ] && pinged /fail "untracked files removed: workspace/HEARTBEAT.md" && [ ! -e "$O/workspace/HEARTBEAT.md" ]'
c23=$(commit '{"v":23}' README.md); echo planted > "$O/workspace/NEW.md"
run; check "untracked file during a deploy: deployed, then the ping fails naming it" \
  eval '[ $rc = 1 ] && head_is $c23 && restarts 1 && [ "$(cat "$S/good")" = $c23 ] && pinged /fail "untracked files removed: workspace/NEW.md"'
mkdir -p "$T/dev/workspace" && echo new > "$T/dev/workspace/LATER.md" && git -C "$T/dev" add -A && git -C "$T/dev" commit -qm later && git -C "$T/dev" push -q origin main
echo local > "$O/workspace/LATER.md"
run; check "a local file the new commit tracks: overwritten by the sync, not reported as removed" \
  eval '[ $rc = 0 ] && [ "$(cat "$O/workspace/LATER.md")" = new ] && ! pinged /fail ""'
# excludes the agent's user can write don't hide anything: a nested .gitignore, .git/info/exclude,
# core.excludesFile. Only the committed root .gitignore counts.
mkdir -p "$O/workspace/skills/evil" "$O/.git/info"
echo planted > "$O/workspace/skills/evil/SKILL.md"; echo '*' > "$O/workspace/skills/evil/.gitignore"
echo planted > "$O/workspace/HIDDEN.md"; echo 'workspace/HIDDEN.md' >> "$O/.git/info/exclude"
echo planted > "$O/workspace/ALSO.md"; echo 'workspace/ALSO.md' > "$T/excludes"; git -C "$O" config core.excludesFile "$T/excludes"
rm -f "$S/last-full"
run; check "a planted nested .gitignore, info/exclude or core.excludesFile hides nothing: all removed and named" \
  eval '[ $rc = 1 ] && pinged /fail "workspace/skills/evil/SKILL.md" && pinged /fail "workspace/HIDDEN.md" && pinged /fail "workspace/ALSO.md" && [ ! -e "$O/workspace/skills/evil" ] && [ ! -e "$O/workspace/HIDDEN.md" ] && [ ! -e "$O/workspace/ALSO.md" ]'
check "the emptied directory is gone, its tracked parent stays" eval '[ ! -e "$O/workspace/skills/evil" ] && [ -d "$O/workspace" ]'
git -C "$O" config --unset core.excludesFile; : > "$O/.git/info/exclude"
mkdir -p "$S/removed/20000101T000000/workspace" && touch -d '40 days ago' "$S/removed/20000101T000000"
for i in $(seq 1 25); do echo x > "$O/workspace/n$i.md"; done
run; check "many untracked files: the ping lists 20 and counts the rest" eval '[ $rc = 1 ] && pinged /fail "(and 5 more)"'
check "moved files older than 30 days are pruned on the next removal" eval '[ ! -e "$S/removed/20000101T000000" ]'
echo x > "$O/workspace/big.md"
CLAW_SYNC_REMOVED_MAX_MB=0 run
check "removed/ over its size cap: deleted instead of moved, and the ping says so" \
  eval '[ $rc = 1 ] && [ ! -e "$O/workspace/big.md" ] && ! ls "$S"/removed/*/workspace/big.md 2>/dev/null && pinged /fail "big.md.*over 0 MB, so these were deleted"'
mv "$S/removed" "$T/removed.bak"; touch "$S/removed"; echo x > "$O/workspace/blocked.md"
run; check "removed/ planted as a file: no crash, files deleted instead, the ping says so" \
  eval '[ $rc = 1 ] && [ ! -e "$O/workspace/blocked.md" ] && pinged /fail "blocked.md.*isn.t a usable directory, so these were deleted" && ! pinged /fail "crashed"'
rm -f "$S/removed"; mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$S/removed"; echo x > "$O/workspace/linked.md"
run; check "removed/ planted as a symlink: not followed, files deleted instead" \
  eval '[ $rc = 1 ] && [ ! -e "$O/workspace/linked.md" ] && [ -z "$(ls -A "$T/elsewhere")" ] && pinged /fail "isn.t a usable directory" && ! pinged /fail "crashed"'
rm -f "$S/removed"; mv "$T/removed.bak" "$S/removed"

# Python bytecode is only ignored under infra/: a .pyc in a skill folder could run in place of its .py
mkdir -p "$O/skills/extra/__pycache__" "$O/infra/x/__pycache__"
echo planted > "$O/skills/extra/__pycache__/run.cpython-312.pyc"; echo planted > "$O/skills/extra/run.pyc"
echo junk > "$O/infra/x/__pycache__/t.cpython-312.pyc"
run; check "a .pyc outside infra/: removed and named; infra/ bytecode is ignored" \
  eval '[ $rc = 1 ] && pinged /fail "skills/extra/__pycache__/run.cpython-312.pyc" && pinged /fail "skills/extra/run.pyc" && [ ! -e "$O/skills/extra" ] && [ -e "$O/infra/x/__pycache__/t.cpython-312.pyc" ] && ! pinged /fail "infra/x"'

# assume-unchanged / skip-worktree hide an in-place edit from git diff: still reverted, and the ping says so
git -C "$O" update-index --assume-unchanged openclaw.json; echo '{"v":"edited"}' > "$O/openclaw.json"
git -C "$O" update-index --skip-worktree README.md; echo edited > "$O/README.md"
rm -f "$S/last-full"
run; check "edits hidden with assume-unchanged/skip-worktree: reverted, flags cleared, fail ping names them" \
  eval '[ $rc = 1 ] && pinged /fail "hidden from git.*openclaw.json" && pinged /fail "README.md" && [ "$(cat "$O/openclaw.json")" != "{\"v\":\"edited\"}" ] && [ "$(cat "$O/README.md")" != edited ] && ! git -C "$O" ls-files -v | grep -q "^[a-zS] "'
run; check "after that: healthy again" eval '[ $rc = 0 ] && pinged "" "up to date"'
git -C "$O" update-index --assume-unchanged README.md
run; check "a flag alone (no edit) still counts: not skipped as idle, cleared" \
  eval '[ $rc = 1 ] && pinged /fail "hidden from git" && ! git -C "$O" ls-files -v | grep -q "^[a-z] "'

# Broken ignore rules fail closed: nothing is synced or removed, so state is never deleted
echo planted > "$O/workspace/PLANTED.md"; good_head=$(git -C "$O" rev-parse HEAD)
git -C "$T/dev" rm -q .gitignore && git -C "$T/dev" commit -qm "no gitignore" && git -C "$T/dev" push -q origin main
run; check "main without a .gitignore: not synced, nothing removed, fail ping" \
  eval '[ $rc = 1 ] && head_is $good_head && pinged /fail "has no .gitignore" && [ -e "$O/workspace/PLANTED.md" ] && [ -e "$O/.env" ] && [ -e "$O/workspace/memory/x.md" ] && [ -e "$O/agents/s.json" ]'
cp "$REPO/.gitignore" "$T/dev/.gitignore"; sed -i '/^workspace\/USER.md$/d' "$T/dev/.gitignore"
git -C "$T/dev" add .gitignore && git -C "$T/dev" commit -qm "gitignore drops state" && git -C "$T/dev" push -q origin main
run; check "main whose .gitignore stops covering state: not synced, nothing removed, fail ping names it" \
  eval '[ $rc = 1 ] && head_is $good_head && pinged /fail "never be removed (workspace/USER.md )" && [ -e "$O/workspace/memory/x.md" ] && [ -e "$O/workspace/USER.md" ] && [ -e "$O/workspace/PLANTED.md" ]'
cp "$REPO/.gitignore" "$T/dev/.gitignore"; git -C "$T/dev" add .gitignore && git -C "$T/dev" commit -qm "gitignore back" && git -C "$T/dev" push -q origin main
run; check "ignore rules fixed: synced, the planted file removed, state kept" \
  eval '[ $rc = 1 ] && head_is "$(git -C "$T/dev" rev-parse HEAD)" && pinged /fail "untracked files removed: workspace/PLANTED.md" && [ -e "$O/workspace/memory/x.md" ] && [ -e "$O/.env" ]'

# Infra installed vs merged: a healthy full run writes infra-pending and tells the owner once per
# new infra/ commit; never a fail ping, and a failed message is retried.
P=$S/infra-pending
export CLAW_SYNC_FULL_EVERY=0   # every run full again
msgs() { grep -c "^message send " "$H/messages" 2>/dev/null || true; }   # one per send; a message spans lines
echo 'TELEGRAM_ALLOW_FROM=12345' >> "$H/.openclaw/.env"
rm -f "$S/infra-notified" "$H/messages"
run; check "installed commit unknown: noted as unknown, one message, healthy ping" \
  eval '[ $rc = 0 ] && grep -q "^installed unknown$" "$P" && [ "$(msgs)" = 1 ] && grep -q -- "--target 12345 .*can.t tell which infra/ commit is installed" "$H/messages" && pinged "" "up to date"'
c30=$(commit '{"v":30}')
run; check "still unknown at a new commit: no second message" eval '[ $rc = 0 ] && [ "$(msgs)" = 1 ]'
git -C "$T/dev" rev-parse HEAD > "$T/installed"; mkdir -p "$T/dev/infra"
c31=$(commit '{"v":31}' infra/thing)
run; check "infra/ commit after the installed one: infra-pending names it, one message, healthy ping" \
  eval '[ $rc = 0 ] && head_is $c31 && grep -q "^installed $(cat "$T/installed")$" "$P" && grep -q "^origin/main $c31$" "$P" && grep -q "{\"v\":31}" "$P" && [ "$(msgs)" = 2 ] && grep -q "merged but not installed" "$H/messages" && grep -q "sudo claw-install" "$H/messages" && pinged "" ""'
run; check "same origin/main: no repeat" eval '[ $rc = 0 ] && [ "$(msgs)" = 2 ] && [ -s "$P" ]'
c31b=$(commit '{"v":31.5}')
run; check "a later merge that doesn't touch infra/: still pending, no second message" \
  eval '[ $rc = 0 ] && [ "$(msgs)" = 2 ] && grep -q "^origin/main $c31b$" "$P" && [ "$(cat "$S/infra-notified")" = "$c31" ]'
touch "$H/msg_fail"; c32=$(commit '{"v":32}' infra/thing)
run; check "message fails: run still healthy, not recorded as told" eval '[ $rc = 0 ] && pinged "" "" && [ "$(cat "$S/infra-notified")" = "$c31" ] && grep -q "Telegram message failed" "$T/out"'
rm "$H/msg_fail"
run; check "next full run retries the message" eval '[ $rc = 0 ] && [ "$(cat "$S/infra-notified")" = "$c32" ] && grep -q "{\"v\":32}" "$P"'
echo "$c32" > "$T/installed"; c33=$(commit '{"v":33}')
run; check "installed up to date, newer commits don't touch infra/: infra-pending removed, no message" \
  eval '[ $rc = 0 ] && [ ! -e "$P" ] && [ "$(cat "$S/infra-notified")" = "$c32" ]'
echo 0123456789012345678901234567890123456789 > "$T/installed"
run; check "installed commit not on origin/main: unknown" eval '[ $rc = 0 ] && grep -q "^installed unknown$" "$P"'
chmod 000 "$T/installed"
run; check "unreadable installed file (an old claw-install wrote it 600): unknown, no crash" eval '[ $rc = 0 ] && grep -q "^installed unknown$" "$P" && pinged "" ""'
chmod 644 "$T/installed"; echo "$c33" > "$T/installed"; sed -i '/^TELEGRAM_ALLOW_FROM=/d' "$H/.openclaw/.env"; rm -f "$S/infra-notified"
c34=$(commit '{"v":34}' infra/thing)
run; check "no TELEGRAM_ALLOW_FROM: infra-pending still written, no message, healthy" eval '[ $rc = 0 ] && [ -s "$P" ] && [ ! -e "$S/infra-notified" ] && pinged "" ""'

# a run that resumes an interrupted deploy reaches ok() before the fetch (no origin/main yet): no check,
# so no false "unknown" message and infra-pending isn't rewritten without a target
echo 'TELEGRAM_ALLOW_FROM=12345' >> "$H/.openclaw/.env"; echo "$c34" > "$S/infra-notified"; : > "$H/messages"
cp "$P" "$T/pending-before"; echo 1 > "$H/kill_on_restart"; c35=$(commit '{"v":35}')
run; rm "$H/kill_on_restart"
run; check "resumed deploy: no infra check, no message, infra-pending untouched" \
  eval '[ $rc = 0 ] && pinged "" "deployed ${c35:0:7}" && [ "$(msgs)" = 0 ] && [ "$(cat "$S/infra-notified")" = "$c34" ] && cmp -s "$P" "$T/pending-before"'
run; check "next full run: checks again, still no repeat" eval '[ $rc = 0 ] && [ "$(msgs)" = 0 ] && grep -q "^origin/main $c35$" "$P"'

echo; [ $fails = 0 ] && echo "all claw-sync tests passed" || { echo "$fails failed"; exit 1; }
