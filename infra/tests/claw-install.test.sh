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
    -e "s|^SMOKE=.*|SMOKE=$T/claw-smoke|" "$INFRA/claw-install" > "$CI"
[ "$(grep -c "$T" "$CI")" = 8 ] || { echo "FAIL could not point claw-install at the test dir (did its constants change?)"; exit 1; }

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
chmod +x "$BIN"/*

# origin with infra/install.sh (records where it ran from and which version it is)
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/dev" 2>/dev/null
mkdir -p "$T/dev/infra"
fake_installer() {  # fake_installer <version>
  cat > "$T/dev/infra/install.sh" <<EOF
#!/bin/bash
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

fails=0
run() { : > "$T/git.log"; bash "$CI" "$@" < /dev/null > "$T/out" 2>&1; rc=$?; }
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
printf '#!/bin/bash\necho "PASS fake-check"\n' > "$T/claw-smoke"; chmod +x "$T/claw-smoke"
run -y
check "smoke test passes: says so last, exit 0" \
  eval '[ $rc = 0 ] && says "PASS fake-check" && [ "$(tail -n1 "$T/out")" = "installed ${sha2:0:7}; smoke test passed" ]'
printf '#!/bin/bash\necho "FAIL fake-check: broken"\nexit 1\n' > "$T/claw-smoke"
run -y
check "smoke test fails: exit 1, says so last, install still recorded" \
  eval '[ $rc = 1 ] && says "FAIL fake-check" && tail -n1 "$T/out" | grep -q "smoke test FAILED" && [ "$(last)" = "$sha2" ]'
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
run -y
check "token file that is a symlink is ignored (no terminal: refused)" eval '[ $rc = 1 ] && says "no token in" && [ ! -s "$T/git.log" ]'
rm "$T/coder.env"
run -y
check "missing token and no terminal: refused" eval '[ $rc = 1 ] && says "no token in" && [ ! -s "$T/git.log" ]'
printf 'GH_TOKEN=%s\n' "$TOKEN" > "$T/coder.env"

run --force
check "unknown option: usage" eval '[ $rc = 1 ] && says "usage:"'

# ---------- install.sh's own guard ----------
# copy the real install.sh into an other-writable dir; with id faking root it must refuse
# before doing anything (and fake `id openclaw` fails, so even a broken guard stops early)
mkdir -p "$T/untrusted/infra" && cp "$INFRA/install.sh" "$T/untrusted/infra/" && chmod 777 "$T/untrusted/infra"
PATH=$BIN:$PATH bash "$T/untrusted/infra/install.sh" > "$T/out" 2>&1; rc=$?
check "install.sh refuses to run from a tree others can write" eval '[ $rc = 1 ] && says "refusing to run from a tree root doesn" && says "sudo claw-install"'

echo; [ $fails = 0 ] && echo "all claw-install tests passed" || { echo "$fails failed"; exit 1; }
