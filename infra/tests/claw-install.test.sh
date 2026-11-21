#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc and sha vars are read inside eval'd check strings
# Tests for infra/claw-install (and install.sh's untrusted-tree guard) against a scratch git
# origin, with fake id/install and a logging git wrapper. Touches nothing outside a temp dir.
# Usage: bash infra/tests/claw-install.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BIN=$T/bin CI=$T/claw-install TOKEN=ghp_t3stT0kenAAAAAAAAAAAAAAAAAAAAAAAAAAAA
mkdir -p "$BIN" "$T/home" "$T/work" "$T/sbin"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
printf 'GH_TOKEN=%s\n' "$TOKEN" > "$T/coder.env"

sed -e "s|^export PATH=.*|export PATH=$BIN:/usr/bin:/bin|" \
    -e "s|^export HOME=/root$|export HOME=$T/home|" \
    -e "s|^REPO=.*|REPO=$T/origin.git|" \
    -e "s|^TOKEN_FILE=.*|TOKEN_FILE=$T/coder.env|" \
    -e "s|^STATE=.*|STATE=$T/state|" \
    -e "s|^WORK_BASE=.*|WORK_BASE=$T/work|" \
    -e "s|^SELF=.*|SELF=$T/sbin/claw-install|" \
    -e "s|^SMOKE=.*|SMOKE=$T/claw-smoke|" \
    -e "s|^OC_HOME=.*|OC_HOME=$T/oc|" -e "s|^POLL=.*|POLL=0|" -e "s|^HEALTH_WAIT=.*|HEALTH_WAIT=0|" \
    -e "s|^DEPLOY_WAIT=.*|DEPLOY_WAIT=0|" "$INFRA/claw-install" > "$CI"
[ "$(grep -c "$T" "$CI")" = 9 ] || { echo "FAIL could not point claw-install at the test dir (did its constants change?)"; exit 1; }

# fake id: root unless $T/not_root; any other query (e.g. `id openclaw`) fails
cat > "$BIN/id" <<EOF
#!/bin/bash
[ "\$1" = -u ] || exit 1
[ -e "$T/not_root" ] && echo 1000 || echo 0
EOF
# fake install: drop -o/-g so it works unprivileged
cat > "$BIN/install" <<'EOF'
#!/bin/bash
a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done
exec /usr/bin/install "${a[@]}"
EOF
# git wrapper: log argv, then run the real git
cat > "$BIN/git" <<EOF
#!/bin/bash
printf '[%s]' "\$@" >> "$T/git.log"; echo >> "$T/git.log"
exec /usr/bin/git "\$@"
EOF
# fake sudo -u openclaw: runs the command here, keeping the fakes on PATH. Reading claw-sync's good
# file plays claw-sync: unless its timer is stopped or $T/sync_stuck exists, it has deployed origin/main
# (and restarted the gateway, if $T/sync_restarts exists).
cat > "$BIN/sudo" <<EOF
#!/bin/bash
while [ "\${1:0:1}" = - ]; do [ "\$1" = -u ] && shift; shift; done
a=(); for x in "\$@"; do case \$x in PATH=*) a+=("PATH=$BIN:/usr/bin:/bin") ;; *) a+=("\$x") ;; esac; done
if [ "\${a[-2]:-}" = cat ] && [ "\${a[-1]##*/}" = good ] && [ ! -e "$T/sync_stopped" ] && [ ! -e "$T/sync_stuck" ]; then
  git -C "$T/oc/.openclaw" fetch -q origin main 2>/dev/null && git -C "$T/oc/.openclaw" rev-parse FETCH_HEAD > "$T/oc/.cache/claw-sync/good"
  [ -e "$T/sync_restarts" ] && echo \$((\$(cat "$T/gwpid") + 1)) > "$T/gwpid"
fi
exec "\${a[@]}"
EOF
# fake systemctl: logs each call; the gateway's MainPID changes on restart (and can't be read while
# $T/no_bus exists); $T/sync_stopped while claw-sync's timer is stopped
cat > "$BIN/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$T/systemctl.log"
case "\$*" in
  "--user show -p MainPID --value openclaw-gateway") [ ! -e "$T/no_bus" ] || exit 1; cat "$T/gwpid" ;;
  "--user restart openclaw-gateway") echo \$((\$(cat "$T/gwpid") + 1)) > "$T/gwpid" ;;
  "show -p ActiveState --value claw-sync.service") echo inactive ;;
  "stop claw-sync.timer") touch "$T/sync_stopped" ;;
  "start claw-sync.timer") rm -f "$T/sync_stopped" ;;
esac
exit 0
EOF
# fake openclaw: gateway health, --version from $T/ocver, update --tag V (logged; sets the version and
# restarts the gateway, like the real updater)
cat > "$BIN/openclaw" <<EOF
#!/bin/bash
case "\$1" in
  gateway) [ ! -e "$T/unhealthy" ] ;;
  --version) [ -e "$T/ocver" ] && echo "OpenClaw \$(cat "$T/ocver") (abc1234)" ;;
  update) echo "\$*" >> "$T/update.log"; echo "openclaw update" >> "$T/systemctl.log"; [ ! -e "$T/update_fails" ] || exit 1
          echo "\$3" > "$T/ocver"; echo \$((\$(cat "$T/gwpid") + 1)) > "$T/gwpid" ;;
  *) exit 2 ;;
esac
EOF
echo 100 > "$T/gwpid"
chmod +x "$BIN"/*

# origin with infra/install.sh (records where it ran from and which version it is)
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/dev" 2>/dev/null
mkdir -p "$T/dev/infra"
fake_installer() {  # fake_installer <version>
  cat > "$T/dev/infra/install.sh" <<EOF
#!/bin/bash
echo install.sh >> "$T/systemctl.log"
[ -e "$T/install_fails" ] && exit 1
echo "$1 \$(cd "\$(dirname "\$0")" && pwd) \$(umask) \${CLAW_INSTALL_SHA:-}" >> "$T/installed"
EOF
}
fake_installer v1
cp "$INFRA/claw-install" "$T/dev/infra/claw-install"
git -C "$T/dev" add -A && git -C "$T/dev" commit -qm "infra v1" && git -C "$T/dev" push -q origin main 2>/dev/null
sha1=$(git -C "$T/dev" rev-parse HEAD)

# the agent-writable checkout (what the admin used to run install.sh from), tampered with locally
git clone -q "$T/origin.git" "$T/openclaw-checkout"
echo 'echo EVIL >> '"$T/installed" >> "$T/openclaw-checkout/infra/install.sh"

# openclaw's checkout (only for "is this deployed commit past that one") and claw-sync's state
git clone -q "$T/origin.git" "$T/oc/.openclaw"; mkdir -p "$T/oc/.cache/claw-sync"

smoke_passes() { printf '#!/bin/bash\n[ ! -e "%s/sync_stopped" ] || { echo "FAIL timers: claw-sync.timer stopped"; exit 1; }\necho "PASS fake-check"\n' "$T" > "$T/claw-smoke"; chmod +x "$T/claw-smoke"; }
fails=0
run() { : > "$T/git.log"; : > "$T/systemctl.log"; bash "$CI" "$@" < /dev/null > "$T/out" 2>&1; rc=$?; }
restarts() { [ "$(grep -c "^--user restart openclaw-gateway$" "$T/systemctl.log")" = "$1" ]; }
paused_around_install() { local s i; s=$(grep -n -m1 "^stop claw-sync.timer$" "$T/systemctl.log" | cut -d: -f1); i=$(grep -n -m1 "^install.sh$" "$T/systemctl.log" | cut -d: -f1); [ -n "$s" ] && [ -n "$i" ] && [ "$s" -lt "$i" ] && [ "$(sed -n "$i,\$p" "$T/systemctl.log" | grep -m1 "claw-sync.timer")" = "start claw-sync.timer" ]; }
paused_around_restart() { [ "$(grep -n -m1 "^stop claw-sync.timer$" "$T/systemctl.log" | cut -d: -f1)" -lt "$(grep -n -m1 "restart openclaw-gateway" "$T/systemctl.log" | cut -d: -f1)" ] && [ "$(tail -n1 "$T/systemctl.log")" = "start claw-sync.timer" ]; }
check() {  # check <name> <condition...>
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out: /' "$T/out"; fails=$((fails + 1)); fi
}
says() { grep -qF -- "$1" "$T/out"; }
last() { cat "$T/state/last" 2>/dev/null; }
work_empty() { [ -z "$(ls -A "$T/work")" ]; }

# ---------- installs from origin/main only ----------
run -y
check "installs origin/main from a fresh clone, never the tampered checkout" \
  eval '[ $rc = 0 ] && [ "$(wc -l < "$T/installed")" = 1 ] && grep -q "^v1 $T/work/claw-install\.[A-Za-z0-9]*/repo/infra " "$T/installed" && ! grep -q EVIL "$T/installed"'
check "install.sh runs with umask 022 and gets the commit" eval 'grep -q " 0022 $sha1$" "$T/installed"'
check "records the installed commit, readable by claw-sync (644)" eval '[ "$(last)" = "$sha1" ] && [ "$(stat -c %a "$T/state/last")" = 644 ]'
check "deletes the clone afterwards" work_empty
check "installs itself from the clone" eval 'cmp -s "$T/sbin/claw-install" "$INFRA/claw-install" && says "updated $T/sbin/claw-install"'
check "first install lists infra/" eval 'says "no previous install recorded" && says "infra/install.sh"'
check "first install restarts the gateway once, claw-sync paused around the install and the restart" eval 'restarts 1 && paused_around_install && paused_around_restart && says "gateway healthy"'
check "no claw-smoke installed: skipped quietly" eval '! says "claw-smoke"'
check "token reaches git only through the env, never argv or output" \
  eval 'grep -q "\[clone\]" "$T/git.log" && ! grep -q "$TOKEN" "$T/git.log" "$T/out"'

run -y
check "re-run at the same commit is allowed and says so" eval '[ $rc = 0 ] && says "already installed at this commit" && ! says "updated $T/sbin"'

fake_installer v2
git -C "$T/dev" commit -qam "installer: v2" && git -C "$T/dev" push -q origin main 2>/dev/null
sha2=$(git -C "$T/dev" rev-parse HEAD)
: > "$T/installed"
run -y
check "shows infra/ commits and diffstat since the last install" \
  eval '[ $rc = 0 ] && says "infra/ (and backup.age.pub) changes since the last install (${sha1:0:7})" && says "installer: v2" && says "install.sh |" && [ "$(last)" = "$sha2" ] && grep -q "^v2 " "$T/installed"'
echo "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" > "$T/dev/backup.age.pub"
git -C "$T/dev" add -A && git -C "$T/dev" commit -qm "backup key" && git -C "$T/dev" push -q origin main 2>/dev/null
run -y
check "a backup.age.pub change (outside infra/, but install.sh installs it) is in the review too" \
  eval '[ $rc = 0 ] && says "backup key" && says "backup.age.pub |"'
sha2=$(git -C "$T/dev" rev-parse HEAD)

# ---------- smoke test after the install ----------
smoke_passes
run -y
check "smoke test passes: says so last, exit 0" \
  eval '[ $rc = 0 ] && says "PASS fake-check" && [ "$(tail -n1 "$T/out")" = "installed ${sha2:0:7}; smoke test passed" ]'
printf '#!/bin/bash\necho "FAIL fake-check: broken"\nexit 1\n' > "$T/claw-smoke"
run -y
check "smoke test fails: exit 1, says so last, install still recorded, commit marked failed" \
  eval '[ $rc = 1 ] && says "FAIL fake-check" && tail -n1 "$T/out" | grep -q "smoke test FAILED" && [ "$(last)" = "$sha2" ] && [ "$(cat "$T/state/failed")" = "$sha2" ]'
rm "$T/claw-smoke"

# ---------- refusals ----------
fake_installer v3
git -C "$T/dev" commit -qam "v3" && git -C "$T/dev" push -q origin main 2>/dev/null
: > "$T/installed"
run
check "no terminal and no -y: refuses, installs nothing" \
  eval '[ $rc = 1 ] && says "re-run with -y" && [ ! -s "$T/installed" ] && [ "$(last)" = "$sha2" ] && work_empty'

# interactive (a pty from script(1); less replaced by cat): the full infra/ diff comes before the question
if command -v script >/dev/null; then
  printf '#!/bin/bash\ncat\n' > "$BIN/less"; chmod +x "$BIN/less"
  : > "$T/installed"
  { sleep 2; echo n; } | script -qec "bash $CI" /dev/null > "$T/out" 2>&1; rc=$?
  diff_at=$(grep -n -m1 "diff --git a/infra/install.sh" "$T/out" | cut -d: -f1)
  ask_at=$(grep -n -m1 "Install [0-9a-f]*? \[y\]es" "$T/out" | cut -d: -f1)
  check "interactive: the full infra/ diff is shown before the question; answering n installs nothing" \
    eval '[ -n "$diff_at" ] && [ -n "$ask_at" ] && [ "$diff_at" -lt "$ask_at" ] && says "echo \"v3 " && says "not installed" && [ ! -s "$T/installed" ] && [ "$(last)" = "$sha2" ]'
  rm "$BIN/less"
else
  echo "skip interactive claw-install test (no script(1))"
fi

touch "$T/install_fails"
run -y
check "install.sh failure: nothing recorded, bootstrap not replaced" \
  eval '[ $rc = 1 ] && says "install.sh failed" && [ "$(last)" = "$sha2" ] && work_empty'
rm "$T/install_fails"

touch "$T/not_root"
run -y
check "not root: refused before cloning" eval '[ $rc = 1 ] && says "run with sudo" && [ ! -s "$T/git.log" ]'
rm "$T/not_root"

printf 'GH_TOKEN=x y\n' > "$T/coder.env"
run -y
check "malformed token: refused before cloning" eval '[ $rc = 1 ] && says "look like a GitHub token" && [ ! -s "$T/git.log" ]'

rm "$T/coder.env"; printf 'GH_TOKEN=%s\n' "$TOKEN" > "$T/elsewhere"; ln -s "$T/elsewhere" "$T/coder.env"
GH_TOKEN=leaked run -y
check "token file that is a symlink is ignored: clones without a token" eval '[ $rc = 0 ] && grep -q "\[clone\]" "$T/git.log"'
rm "$T/coder.env"
run -y
check "no token file: clones without one (the repo is public)" eval '[ $rc = 0 ] && grep -q "\[clone\]" "$T/git.log"'
printf 'GH_TOKEN=%s\n' "$TOKEN" > "$T/coder.env"

run --force
check "unknown option: usage" eval '[ $rc = 1 ] && says "usage:"'

# ---------- --auto (the timer) ----------
push() { git -C "$T/dev" add -A && git -C "$T/dev" commit -qm "$1" && git -C "$T/dev" push -q origin main 2>/dev/null; git -C "$T/dev" rev-parse HEAD; }
failed() { [ "$(cat "$T/state/failed" 2>/dev/null)" = "$1" ]; }
smoke_passes
run -y; : > "$T/installed"; base=$(last)
run --auto
check "auto, main unchanged: only asks GitHub for main's commit, no clone, no output" \
  eval '[ $rc = 0 ] && grep -q "\[ls-remote\]" "$T/git.log" && ! grep -q "\[clone\]" "$T/git.log" && [ ! -s "$T/out" ]'
echo docs > "$T/dev/README.md"; a1=$(push "docs only")
run --auto
check "auto, nothing in infra/ changed: marker moved, nothing installed or restarted" \
  eval '[ $rc = 0 ] && [ "$(last)" = "$a1" ] && [ ! -s "$T/installed" ] && restarts 0'
mkdir -p "$T/dev/infra/openclaw-plugins/p"; echo 1 > "$T/dev/infra/openclaw-plugins/p/index.js"; a2=$(push "plugin p")
run --auto
check "auto, plugin code changed: installed without asking, one restart (claw-sync paused), smoke passes" \
  eval '[ $rc = 0 ] && [ "$(last)" = "$a2" ] && grep -q " $a2$" "$T/installed" && restarts 1 && paused_around_restart && says "smoke test passed"'
echo 2 > "$T/dev/infra/openclaw-plugins/p/index.js"; echo '{"v":2}' > "$T/dev/openclaw.json"; a3=$(push "plugin p + config")
touch "$T/sync_restarts"
run --auto
check "auto, plugin + config: claw-sync's deploy restarts the gateway, so no second restart" \
  eval '[ $rc = 0 ] && says "claw-sync deployed ${a3:0:7}" && restarts 0 && says "smoke test passed"'
rm "$T/sync_restarts"
echo 3 > "$T/dev/infra/openclaw-plugins/p/index.js"; echo '{"v":3}' > "$T/dev/openclaw.json"; a4=$(push "plugin p + same-as-running config")
run --auto
check "auto, plugin + config but claw-sync didn't restart (config unchanged on the host): restarts once" \
  eval '[ $rc = 0 ] && says "claw-sync deployed" && restarts 1'
mkdir -p "$T/dev/infra/gateway-dropins"; echo x > "$T/dev/infra/gateway-dropins/heap.conf"; a5=$(push "drop-in")
run --auto
check "auto, drop-in changed: daemon-reload as openclaw, then one restart" \
  eval '[ $rc = 0 ] && grep -q "^--user daemon-reload$" "$T/systemctl.log" && restarts 1'
echo 4 > "$T/dev/infra/openclaw-plugins/p/index.js"; echo '{"v":4}' > "$T/dev/openclaw.json"; a6=$(push "config claw-sync rejects")
echo "$a6" > "$T/oc/.cache/claw-sync/bad"; touch "$T/sync_stuck"
run --auto
check "auto, claw-sync rejects the config: fails, says so, commit marked failed (install itself recorded)" \
  eval '[ $rc = 1 ] && says "claw-sync rejected ${a6:0:7}" && failed "$a6" && [ "$(last)" = "$a6" ] && restarts 0'
run --auto
check "auto, same failed commit: fails again at once (check stays down), no clone" \
  eval '[ $rc = 1 ] && says "failed to install or check" && ! grep -q "\[clone\]" "$T/git.log"'
rm "$T/oc/.cache/claw-sync/bad" "$T/sync_stuck"
run -y
check "a manual install that succeeds clears it" eval '[ $rc = 0 ] && [ ! -e "$T/state/failed" ]'
run --auto
check "... and the auto-install is quiet again" eval '[ $rc = 0 ] && [ ! -s "$T/out" ]'
echo 5 > "$T/dev/infra/openclaw-plugins/p/index.js"; a7=$(push "plugin that breaks the gateway"); touch "$T/unhealthy"
run --auto
check "auto, gateway unhealthy after the restart: fails, claw-sync's timer started again, marked failed" \
  eval '[ $rc = 1 ] && says "gateway not healthy" && [ "$(tail -n1 "$T/systemctl.log")" = "start claw-sync.timer" ] && failed "$a7"'
rm "$T/unhealthy"
echo 6 > "$T/dev/infra/openclaw-plugins/p/index.js"; a8=$(push "smoke breaks")
printf '#!/bin/bash\necho "FAIL fake-check"\nexit 1\n' > "$T/claw-smoke"
run --auto
check "auto, smoke test fails: fails, marked failed" eval '[ $rc = 1 ] && says "smoke test FAILED" && failed "$a8"'
smoke_passes
echo more > "$T/dev/README.md"; a8b=$(push "docs after a late failure"); : > "$T/installed"
run --auto
check "auto, docs-only merge after a commit that failed past install.sh: installs, restarts and checks again in full" \
  eval '[ $rc = 0 ] && grep -q " $a8b$" "$T/installed" && restarts 1 && says "smoke test passed" && [ ! -e "$T/state/failed" ]'
touch "$T/install_fails"; echo 7 > "$T/dev/infra/openclaw-plugins/p/index.js"; a9=$(push "install fails")
run --auto
check "auto, install.sh fails: nothing recorded, marked failed, no restart" eval '[ $rc = 1 ] && [ "$(last)" = "$a8b" ] && failed "$a9" && restarts 0'
rm "$T/install_fails"
echo 8 > "$T/dev/infra/openclaw-plugins/p/index.js"; a10=$(push "fixed")
run --auto
check "auto, a new merge after a failure is tried" eval '[ $rc = 0 ] && [ "$(last)" = "$a10" ] && [ ! -e "$T/state/failed" ]'
echo 81 > "$T/dev/infra/openclaw-plugins/p/index.js"; a10b=$(push "plugin, user bus down"); touch "$T/no_bus"
run --auto
check "auto, the gateway's user manager can't be reached for its pid: still installs" eval '[ $rc = 0 ] && [ "$(last)" = "$a10b" ]'
rm "$T/no_bus"
echo 9 > "$T/dev/infra/openclaw-plugins/p/index.js"; a11=$(push "while locked")
flock "$T/state/lock" sleep 3 & sleep 0.5
run --auto
check "auto while another claw-install runs: exits quietly, nothing done" eval '[ $rc = 0 ] && [ ! -s "$T/git.log" ] && [ "$(last)" = "$a10b" ]'
wait
mv "$T/origin.git" "$T/origin.away"
run --auto
check "auto, GitHub unreachable: exit 0 (claw-sync reports fetch failures), next run tries again" eval '[ $rc = 0 ] && says "offline"'
mv "$T/origin.away" "$T/origin.git"
wait; run --auto   # install what was pushed while locked

# ---------- the pinned OpenClaw version ----------
pin() { mkdir -p "$T/dev/infra/openclaw"; printf '{\n  "dependencies": {\n    "openclaw": "%s"\n  }\n}\n' "$1" > "$T/dev/infra/openclaw/package.json"; }
echo 2026.1.0 > "$T/ocver"; : > "$T/update.log"
pin 2026.1.1; echo 10 > "$T/dev/infra/openclaw-plugins/p/index.js"; push "OpenClaw 2026.1.1 + plugin" >/dev/null
run --auto
# claw-sync stays paused from before install.sh (before the install is recorded) until after the update
sync_order() { [ "$(grep -E "^(stop|start) claw-sync.timer$|^install.sh$|^openclaw update$" "$T/systemctl.log" | tr '\n' ,)" = "stop claw-sync.timer,install.sh,openclaw update,start claw-sync.timer," ]; }
check "pin differs from the host: openclaw update --tag as openclaw, claw-sync paused throughout, counts as the restart" \
  eval '[ $rc = 0 ] && grep -q "^update --tag 2026.1.1 --yes" "$T/update.log" && [ "$(cat "$T/ocver")" = 2026.1.1 ] && restarts 0 && sync_order && says "updating OpenClaw 2026.1.0 -> 2026.1.1"'
: > "$T/update.log"; echo 11 > "$T/dev/infra/openclaw-plugins/p/index.js"; push "plugin only" >/dev/null
run --auto
check "pin matches: no update, the plugin change restarts as usual" eval '[ $rc = 0 ] && [ ! -s "$T/update.log" ] && restarts 1'
: > "$T/update.log"; pin 2026.1.3-1; echo '{"v":20}' > "$T/dev/openclaw.json"; push "OpenClaw hotfix + config" >/dev/null
run --auto
check "pin bump + config change: updated, then claw-sync (running again) deploys it, smoke passes" \
  eval '[ $rc = 0 ] && grep -q "^update --tag 2026.1.3-1 --yes" "$T/update.log" && sync_order && says "claw-sync deployed" && says "smoke test passed"'
: > "$T/update.log"; echo 12 > "$T/dev/infra/openclaw-plugins/p/index.js"; push "plugin, hotfix pin unchanged" >/dev/null
run --auto
check "a -N hotfix version that's installed matches: no update again" eval '[ $rc = 0 ] && [ ! -s "$T/update.log" ]'
pin "^2026.1.2"; b1=$(push "a range, not a version")
run --auto
check "a range instead of an exact version: refused" eval '[ $rc = 1 ] && says "an exact OpenClaw version" && [ ! -s "$T/update.log" ] && failed "$b1"'
pin 2026.1.2; touch "$T/update_fails"; b2=$(push "update fails")
run --auto
check "openclaw update fails: fails, marked failed, timer started again" \
  eval '[ $rc = 1 ] && says "openclaw update to 2026.1.2 failed" && failed "$b2" && [ "$(tail -n1 "$T/systemctl.log")" = "start claw-sync.timer" ]'
rm "$T/update_fails"

# ---------- install.sh's own guard ----------
# copy the real install.sh into an other-writable dir; with id faking root it must refuse
# before doing anything (and fake `id openclaw` fails, so even a broken guard stops early)
mkdir -p "$T/untrusted/infra" && cp "$INFRA/install.sh" "$T/untrusted/infra/" && chmod 777 "$T/untrusted/infra"
PATH=$BIN:$PATH bash "$T/untrusted/infra/install.sh" > "$T/out" 2>&1; rc=$?
check "install.sh refuses to run from a tree others can write" eval '[ $rc = 1 ] && says "refusing to run from a tree root doesn" && says "sudo claw-install"'

echo; [ $fails = 0 ] && echo "all claw-install tests passed" || { echo "$fails failed"; exit 1; }
