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
    -e "s|^OC_HOME=.*|OC_HOME=$T/oc|" "$INFRA/claw-install" > "$CI"
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
# fake sudo -u openclaw: runs the command here, keeping the fakes on PATH
cat > "$BIN/sudo" <<EOF
#!/bin/bash
while [ "\${1:0:1}" = - ]; do [ "\$1" = -u ] && shift; shift; done
a=(); for x in "\$@"; do case \$x in PATH=*) a+=("PATH=$BIN:/usr/bin:/bin") ;; *) a+=("\$x") ;; esac; done
exec "\${a[@]}"
EOF
# fake systemctl: logs each call. Starting claw-sync plays one claw-sync run: it fetches origin/main and
# deploys it (or its good commit while main is marked bad), holds back a commit whose infra/ isn't
# installed, rejects main with $T/sync_rejects, and fails outright with $T/sync_stuck.
cat > "$BIN/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$T/systemctl.log"
[ "\$*" = "start claw-sync.service" ] || exit 0
[ ! -e "$T/sync_stuck" ] || exit 1
g=$T/oc/.openclaw s=$T/oc/.cache/claw-sync
git -C \$g fetch -q origin main 2>/dev/null; m=\$(git -C \$g rev-parse FETCH_HEAD); want=\$m
[ "\$m" != "\$(cat \$s/bad 2>/dev/null)" ] || want=\$(cat \$s/good)
inst=\$(cat "$T/state/last" 2>/dev/null)
[ -z "\$inst" ] || git -C \$g diff --quiet "\$inst" "\$want" -- infra/ || exit 0
if [ -e "$T/sync_rejects" ] && [ "\$want" = "\$m" ]; then echo "\$m" > \$s/bad; exit 1; fi
git -C \$g checkout -q "\$want"; echo "\$want" > \$s/good; echo "\$want" >> "$T/deploys"
EOF
# fake openclaw: --version from $T/ocver; update --tag V (logged) sets the version, fails with $T/update_fails
cat > "$BIN/openclaw" <<EOF
#!/bin/bash
case "\$1" in
  --version) [ -e "$T/ocver" ] && echo "OpenClaw \$(cat "$T/ocver") (abc1234)" ;;
  update) echo "\$*" >> "$T/update.log"; echo "openclaw update" >> "$T/systemctl.log"; [ ! -e "$T/update_fails" ] || exit 1
          echo "\$3" > "$T/ocver" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN"/*

# origin with infra/install.sh (records where it ran from and which version it is). It fails for the
# commit named in $T/install_fails, and with $T/merge_during pushes a commit prepared in $T/dev first.
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/dev" 2>/dev/null
mkdir -p "$T/dev/infra"
fake_installer() {  # fake_installer <version>
  cat > "$T/dev/infra/install.sh" <<EOF
#!/bin/bash
echo install.sh >> "$T/systemctl.log"
[ ! -e "$T/merge_during" ] || { rm "$T/merge_during"; git -C "$T/dev" push -q origin main 2>/dev/null; }
[ "\$(cat "$T/install_fails" 2>/dev/null)" != "\${CLAW_INSTALL_SHA:-}" ] || exit 1
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

# openclaw's checkout, deployed by the fake claw-sync, and claw-sync's state
git clone -q "$T/origin.git" "$T/oc/.openclaw"; mkdir -p "$T/oc/.cache/claw-sync"

smoke_passes() { printf '#!/bin/bash\necho "PASS fake-check"\n' > "$T/claw-smoke"; chmod +x "$T/claw-smoke"; }
smoke_fails() { printf '#!/bin/bash\necho "FAIL fake-check: broken"\nexit 1\n' > "$T/claw-smoke"; chmod +x "$T/claw-smoke"; }
fails=0
run() { : > "$T/git.log"; : > "$T/systemctl.log"; : > "$T/deploys"; bash "$CI" "$@" < /dev/null > "$T/out" 2>&1; rc=$?; }
check() {  # check <name> <condition...>
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out: /' "$T/out"; fails=$((fails + 1)); fi
}
says() { grep -qF -- "$1" "$T/out"; }
last() { cat "$T/state/last" 2>/dev/null; }
work_empty() { [ -z "$(ls -A "$T/work")" ]; }
deployed() { grep -qx "$1" "$T/deploys"; }
sync_bad() { [ "$(cat "$T/oc/.cache/claw-sync/bad" 2>/dev/null)" = "$1" ]; }
failed() { [ "$(cat "$T/state/failed" 2>/dev/null)" = "$1" ]; }
installed_last() { [ "$(tail -n1 "$T/installed" | cut -d' ' -f4)" = "$1" ]; }
push() { git -C "$T/dev" add -A && git -C "$T/dev" commit -qm "$1" && git -C "$T/dev" push -q origin main 2>/dev/null; git -C "$T/dev" rev-parse HEAD; }

# ---------- installs from origin/main only ----------
run -y
check "installs origin/main from a fresh clone, never the tampered checkout" \
  eval '[ $rc = 0 ] && [ "$(wc -l < "$T/installed")" = 1 ] && grep -q "^v1 $T/work/claw-install\.[A-Za-z0-9]*/repo/infra " "$T/installed" && ! grep -q EVIL "$T/installed"'
check "install.sh runs with umask 022 and gets the commit" eval 'grep -q " 0022 $sha1$" "$T/installed"'
check "records the installed commit, readable by claw-sync (644)" eval '[ "$(last)" = "$sha1" ] && [ "$(stat -c %a "$T/state/last")" = 644 ]'
check "deletes the clone afterwards" work_empty
check "installs itself from the clone" eval 'cmp -s "$T/sbin/claw-install" "$INFRA/claw-install" && says "updated $T/sbin/claw-install"'
check "first install lists infra/" eval 'says "no previous install recorded" && says "infra/install.sh"'
check "after recording the install, has claw-sync deploy it" eval 'deployed "$sha1" && says "claw-sync deployed ${sha1:0:7}"'
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
fake_installer v3; sha3=$(push "v3"); smoke_fails; : > "$T/installed"
run -y
check "smoke test fails: rolled back to the previous commit, claw-sync sent back, exit 1" \
  eval '[ $rc = 1 ] && says "FAIL fake-check" && says "rolled back to ${sha2:0:7}" && [ "$(last)" = "$sha2" ] && installed_last "$sha2" && failed "$sha3" && sync_bad "$sha3" && deployed "$sha2"'
smoke_passes
run -y
check "a manual re-run retries the rolled-back commit: clears claw-sync's bad marker, deploys, passes" \
  eval '[ $rc = 0 ] && [ "$(last)" = "$sha3" ] && deployed "$sha3" && ! sync_bad "$sha3" && [ ! -e "$T/state/failed" ]'
sha2=$sha3
rm "$T/claw-smoke"

# ---------- refusals ----------
fake_installer v4
git -C "$T/dev" commit -qam "v4" && git -C "$T/dev" push -q origin main 2>/dev/null
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
    eval '[ -n "$diff_at" ] && [ -n "$ask_at" ] && [ "$diff_at" -lt "$ask_at" ] && says "echo \"v4 " && says "not installed" && [ ! -s "$T/installed" ] && [ "$(last)" = "$sha2" ]'
  rm "$BIN/less"
else
  echo "skip interactive claw-install test (no script(1))"
fi

git -C "$T/dev" rev-parse HEAD > "$T/install_fails"
run -y
check "install.sh failure: the previous commit reinstalled and recorded, exit 1" \
  eval '[ $rc = 1 ] && says "failed" && says "rolled back to ${sha2:0:7}" && [ "$(last)" = "$sha2" ] && installed_last "$sha2" && work_empty'
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
smoke_passes
run -y; : > "$T/installed"
run --auto
check "auto, main unchanged: only asks GitHub for main's commit, no clone, no output" \
  eval '[ $rc = 0 ] && grep -q "\[ls-remote\]" "$T/git.log" && ! grep -q "\[clone\]" "$T/git.log" && [ ! -s "$T/out" ]'
echo docs > "$T/dev/README.md"; a1=$(push "docs only")
run --auto
check "auto, nothing in infra/ changed: marker moved, nothing installed" eval '[ $rc = 0 ] && [ "$(last)" = "$a1" ] && [ ! -s "$T/installed" ]'
mkdir -p "$T/dev/infra/openclaw-plugins/p"; echo 1 > "$T/dev/infra/openclaw-plugins/p/index.js"; a2=$(push "plugin p")
run --auto
check "auto, infra/ changed: installed without asking, deployed by claw-sync, smoke passes" \
  eval '[ $rc = 0 ] && [ "$(last)" = "$a2" ] && installed_last "$a2" && deployed "$a2" && says "smoke test passed"'
check "claw-install itself never restarts the gateway" eval '! grep -q restart "$T/systemctl.log"'
echo 2 > "$T/dev/infra/openclaw-plugins/p/index.js"; a3=$(push "config claw-sync rejects"); touch "$T/sync_rejects"
run --auto
check "auto, claw-sync rejects it: rolled back to the previous commit, marked failed" \
  eval '[ $rc = 1 ] && says "claw-sync rejected ${a3:0:7}" && says "rolled back to ${a2:0:7}" && [ "$(last)" = "$a2" ] && installed_last "$a2" && failed "$a3"'
run --auto
check "auto, same failed commit: fails again at once (check stays down), no clone" \
  eval '[ $rc = 1 ] && says "failed and was rolled back" && ! grep -q "\[clone\]" "$T/git.log"'
rm "$T/sync_rejects"
echo 3 > "$T/dev/infra/openclaw-plugins/p/index.js"; a4=$(push "fixed")
run --auto
check "auto, a new merge after a failure is tried" eval '[ $rc = 0 ] && [ "$(last)" = "$a4" ] && deployed "$a4" && [ ! -e "$T/state/failed" ]'
echo 4 > "$T/dev/infra/openclaw-plugins/p/index.js"; a5=$(push "smoke breaks"); smoke_fails
run --auto
check "auto, smoke test fails: rolled back, claw-sync back on the previous commit" \
  eval '[ $rc = 1 ] && says "smoke test FAILED" && [ "$(last)" = "$a4" ] && failed "$a5" && sync_bad "$a5" && deployed "$a4"'
smoke_passes
echo 5 > "$T/dev/infra/openclaw-plugins/p/index.js"; b1=$(push "plugin")
echo 6 > "$T/dev/infra/openclaw-plugins/p/index.js"; git -C "$T/dev" commit -qam "plugin, merged during b1's install"; b2=$(git -C "$T/dev" rev-parse HEAD); touch "$T/merge_during"
run --auto
check "auto, an infra/ merge lands during the install: not a failure, no rollback, no smoke yet" \
  eval '[ $rc = 0 ] && says "moved on to ${b2:0:7}" && [ "$(last)" = "$b1" ] && [ ! -e "$T/state/failed" ] && ! says "smoke test"'
run --auto
check "... the next run installs the new merge in full" eval '[ $rc = 0 ] && [ "$(last)" = "$b2" ] && deployed "$b2" && says "smoke test passed"'
echo 7 > "$T/dev/infra/openclaw-plugins/p/index.js"; push "while locked" >/dev/null
flock "$T/state/lock" sleep 3 & sleep 0.5
run --auto
check "auto while another claw-install runs: exits quietly, nothing done" eval '[ $rc = 0 ] && [ ! -s "$T/git.log" ] && [ "$(last)" = "$b2" ]'
wait
mv "$T/origin.git" "$T/origin.away"
run --auto
check "auto, GitHub unreachable: exit 0 (claw-sync reports fetch failures), next run tries again" eval '[ $rc = 0 ] && says "offline"'
mv "$T/origin.away" "$T/origin.git"
rm "$T/state/last"; touch "$T/sync_stuck"
run -y
check "first install (nothing recorded) that claw-sync can't deploy: fails, nothing to roll back to" \
  eval '[ $rc = 1 ] && says "didn" && ! says "rolling back"'
rm "$T/sync_stuck"


# ---------- the pinned OpenClaw version ----------
pin() { mkdir -p "$T/dev/infra/openclaw"; printf '{\n  "dependencies": {\n    "openclaw": "%s"\n  }\n}\n' "$1" > "$T/dev/infra/openclaw/package.json"; }
run -y; echo 2026.1.0 > "$T/ocver"; : > "$T/update.log"
pin 2026.1.1; p1=$(push "OpenClaw 2026.1.1")
run --auto
# updated after install.sh, before the install is recorded (so before claw-sync deploys it)
update_order() { [ "$(grep -E "^install.sh$|^openclaw update$|^start claw-sync.service$" "$T/systemctl.log" | head -n3 | tr '\n' ,)" = "install.sh,openclaw update,start claw-sync.service," ]; }
check "pin differs from the host: openclaw update --tag as openclaw, before claw-sync deploys" \
  eval '[ $rc = 0 ] && grep -q "^update --tag 2026.1.1 --yes" "$T/update.log" && [ "$(cat "$T/ocver")" = 2026.1.1 ] && update_order && deployed "$p1" && says "updating OpenClaw 2026.1.0 -> 2026.1.1"'
: > "$T/update.log"; echo 21 > "$T/dev/infra/openclaw-plugins/p/index.js"; push "plugin only" >/dev/null
run --auto
check "pin matches: no update" eval '[ $rc = 0 ] && [ ! -s "$T/update.log" ]'
pin 2026.1.3-1; push "OpenClaw hotfix" >/dev/null; run --auto
: > "$T/update.log"; echo 22 > "$T/dev/infra/openclaw-plugins/p/index.js"; p2=$(push "plugin, hotfix pin unchanged")
run --auto
check "a -N hotfix version that's installed matches: no update again" eval '[ $rc = 0 ] && [ ! -s "$T/update.log" ] && [ "$(last)" = "$p2" ]'
pin "^2026.1.2"; p3=$(push "a range, not a version")
run --auto
check "a range instead of an exact version: refused, rolled back" eval '[ $rc = 1 ] && says "an exact OpenClaw version" && [ ! -s "$T/update.log" ] && failed "$p3" && [ "$(last)" = "$p2" ]'
pin 2026.1.2; touch "$T/update_fails"; p4=$(push "update fails")
run --auto
check "openclaw update fails: rolled back to the previous commit, marked failed" \
  eval '[ $rc = 1 ] && says "openclaw update to 2026.1.2 failed" && failed "$p4" && [ "$(last)" = "$p2" ]'
rm "$T/update_fails"
pin 2026.1.4; p5=$(push "OpenClaw 2026.1.4, smoke breaks"); smoke_fails; : > "$T/update.log"
run --auto
check "smoke fails after an OpenClaw update: the rollback puts the previous version back" \
  eval '[ $rc = 1 ] && grep -q "^update --tag 2026.1.4 " "$T/update.log" && grep -q "^update --tag 2026.1.3-1 " "$T/update.log" && [ "$(cat "$T/ocver")" = 2026.1.3-1 ] && [ "$(last)" = "$p2" ]'
smoke_passes

# ---------- install.sh's own guard ----------
# copy the real install.sh into an other-writable dir; with id faking root it must refuse
# before doing anything (and fake `id openclaw` fails, so even a broken guard stops early)
mkdir -p "$T/untrusted/infra" && cp "$INFRA/install.sh" "$T/untrusted/infra/" && chmod 777 "$T/untrusted/infra"
PATH=$BIN:$PATH bash "$T/untrusted/infra/install.sh" > "$T/out" 2>&1; rc=$?
check "install.sh refuses to run from a tree others can write" eval '[ $rc = 1 ] && says "refusing to run from a tree root doesn" && says "sudo claw-install"'

echo; [ $fails = 0 ] && echo "all claw-install tests passed" || { echo "$fails failed"; exit 1; }
