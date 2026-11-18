#!/bin/bash
# shellcheck disable=SC2034  # rc, c1 and c2 are read inside check's eval strings
# Tests for infra/claw-backup: a failed or refused push pings /fail; a good one doesn't; only
# ciphertext is committed, and it decrypts to the workspace state.
# Runs a copy with HOME, PATH and the age key file pointed into a temp dir; agent-git (via sudo) and
# curl are faked. Uses the real age when installed (a full encrypt/decrypt round trip), otherwise a
# reversible stand-in.
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=$T/home BIN=$T/bin CB=$T/claw-backup
mkdir -p "$H/.openclaw/workspace" "$BIN"
sed -e "s|^export HOME=/home/openclaw$|export HOME=$H|" \
    -e "s|^export PATH=/usr/local/bin:/usr/bin:/bin$|export PATH=$BIN:/usr/bin:/bin|" \
    -e "s|^AGE_RECIPIENTS=.*|AGE_RECIPIENTS=$T/backup.age.pub|" "$D/claw-backup" > "$CB"
[ "$(grep -c "^export HOME=$H$\|^export PATH=$BIN:\|^AGE_RECIPIENTS=$T/" "$CB")" = 3 ] || { echo "FAIL could not point claw-backup at the test dir"; exit 1; }

# the key pair: real age-keygen if there is one, else a fixed fake key and a reversible fake age
if [ "${FAKE_AGE:-}" != 1 ] && command -v age >/dev/null && command -v age-keygen >/dev/null; then
  REAL_AGE=1; age-keygen -o "$T/key.txt" 2>/dev/null; age-keygen -y "$T/key.txt" > "$T/backup.age.pub"
  decrypt() { age -d -i "$T/key.txt" "$1"; }
else
  REAL_AGE=0; echo "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" > "$T/backup.age.pub"
  cat > "$BIN/age" <<'EOF'
#!/bin/bash
# fake age -R <file> -o <out> <in>: a header and base64, so plaintext never shows as-is
while [ $# -gt 1 ]; do case "$1" in -R) shift 2 ;; -o) out=$2; shift 2 ;; *) shift ;; esac; done
{ echo "age-encryption.org/v1 (fake)"; base64 -w0 "$1"; echo; } > "$out"
EOF
  chmod +x "$BIN/age"
  decrypt() { tail -n +2 "$1" | base64 -d; }
fi

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
ENV_LINE="HEALTHCHECKS_PING_URL=https://hc.example/check"

pass=0 fail=0
check() { if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; sed 's/^/     /' "$T/out" "$T/curl.log" 2>/dev/null; fail=$((fail+1)); fi; }
# shellcheck disable=SC2034  # rc, c1, c2 are read inside check's eval strings
run() { : > "$T/curl.log"; bash "$CB" > "$T/out" 2>&1; rc=$?; }

echo "v1" > "$H/.openclaw/workspace/MEMORY.md"
run
check "good push: exit 0, no fail ping" '[ $rc = 0 ] && grep -q "pushed" "$T/out" && [ ! -s "$T/curl.log" ]'
check "good push: last-ok touched" '[ -e "$H/.cache/claw-backup/last-ok" ]'
touch -d '2 days ago' "$H/.cache/claw-backup/last-ok"

echo "v2" > "$H/.openclaw/workspace/MEMORY.md"; touch "$T/reject"
run
check "refused push: non-zero exit and a /fail ping with the reason" \
  '[ $rc != 0 ] && grep -q "hc.example/check/fail" "$T/curl.log" && grep -q "claw-backup failed on" "$T/curl.log"'
check "refused push: last-ok not touched" '[ -z "$(find "$H/.cache/claw-backup/last-ok" -newermt "1 day ago")" ]'
check "refused push: not recorded as pushed, so the next run retries" '! grep -q "$(git -C "$H/.openclaw/state-backup" rev-parse HEAD)" "$H/.cache/claw-backup/pushed"'

: > "$H/.openclaw/.env"
run
check "no ping URL: still fails, says the failure wasn't reported" '[ $rc != 0 ] && [ ! -s "$T/curl.log" ] && grep -q "failure not reported" "$T/out"'
rm "$T/reject"

run
check "nothing new after a good retry: exit 0, no ping" '[ $rc = 0 ] && [ ! -s "$T/curl.log" ]'
touch -d '2 days ago' "$H/.cache/claw-backup/last-ok"
run
check "nothing new: still touches last-ok" '[ $rc = 0 ] && grep -q "nothing new" "$T/out" && [ -n "$(find "$H/.cache/claw-backup/last-ok" -newermt "1 minute ago")" ]'

# ---------- encryption ----------
echo "$ENV_LINE" > "$H/.openclaw/.env"
S=$H/.openclaw/state-backup W=$H/.openclaw/workspace
mkdir -p "$W/memory/people"; echo "secret-marker-memory" > "$W/MEMORY.md"; echo "secret-marker-person" > "$W/memory/people/alex.md"
echo "secret-marker-user" > "$W/USER.md"; mkdir -p "$W/memory/.git"; echo x > "$W/memory/.git/HEAD"
mkdir -p "$S/memory"; echo "old plaintext" > "$S/memory/old.md"; git -C "$S" add -A; git -C "$S" -c user.name=t -c user.email=t@t commit -qm old
run
check "commits only ciphertext (plus README): no plaintext files in the tree" \
  '[ $rc = 0 ] && [ "$(git -C "$S" ls-tree -r --name-only HEAD | grep -v "^README.md$" | paste -sd " " -)" = "state.tar.gz.age" ]'
check "no plaintext anywhere in the new commit" '! git -C "$S" show HEAD | grep -q "secret-marker"'
check "the ciphertext holds a gzip stream (compressed before encryption)" 'decrypt "$S/state.tar.gz.age" | head -c 2 | od -An -tx1 | grep -q "1f 8b"'
mkdir -p "$T/restore" && decrypt "$S/state.tar.gz.age" | tar -xz -C "$T/restore"
check "decrypting reproduces the workspace state (memory/.git left out)" \
  'cmp -s "$T/restore/MEMORY.md" "$W/MEMORY.md" && cmp -s "$T/restore/USER.md" "$W/USER.md" && cmp -s "$T/restore/memory/people/alex.md" "$W/memory/people/alex.md" && [ ! -e "$T/restore/memory/.git" ] && [ ! -e "$T/restore/DREAMS.md" ]'
[ "$REAL_AGE" = 1 ] && echo "     (real age round trip)" || echo "     (age not installed: fake age stand-in)"
c1=$(git -C "$S" rev-parse HEAD)
run
check "unchanged state: no new commit even though age output would differ" '[ $rc = 0 ] && [ "$(git -C "$S" rev-parse HEAD)" = "$c1" ] && grep -q "nothing new" "$T/out"'
echo "changed" >> "$W/memory/people/alex.md"
run
check "changed state: a new encrypted commit" '[ $rc = 0 ] && [ "$(git -C "$S" rev-parse HEAD)" != "$c1" ] && grep -q "committed" "$T/out"'
c2=$(git -C "$S" rev-parse HEAD); mv "$T/backup.age.pub" "$T/pub.off"
run
check "no public key: fails with a /fail ping, nothing committed" \
  '[ $rc != 0 ] && grep -q "no age public key" "$T/out" && grep -q "hc.example/check/fail" "$T/curl.log" && [ "$(git -C "$S" rev-parse HEAD)" = "$c2" ]'
echo "not a key" > "$T/backup.age.pub"
run
check "malformed public key: same" '[ $rc != 0 ] && grep -q "no age public key" "$T/out" && [ "$(git -C "$S" rev-parse HEAD)" = "$c2" ]'
mv "$T/pub.off" "$T/backup.age.pub"
# GNU tar exits 1 when a file changes while it's read; that's not a failed backup
cat > "$BIN/tar" <<'EOF'
#!/bin/bash
/usr/bin/tar "$@" || exit $?
[ -e "$TAR_RC_FILE" ] && exit "$(cat "$TAR_RC_FILE")"
exit 0
EOF
chmod +x "$BIN/tar"; export TAR_RC_FILE=$T/tar_rc; echo 1 > "$T/tar_rc"; echo "more" >> "$W/MEMORY.md"
run
check "tar exit 1 (a file changed while read): still backs up" '[ $rc = 0 ] && grep -q "committed" "$T/out" && [ ! -s "$T/curl.log" ]'
echo 2 > "$T/tar_rc"; echo "more" >> "$W/MEMORY.md"
run
check "tar exit 2: a failed backup, fail-pinged" '[ $rc != 0 ] && grep -q "tar failed (exit 2)" "$T/out" && grep -q "hc.example/check/fail" "$T/curl.log"'
rm "$T/tar_rc" "$BIN/tar"
rm -f "$W/USER.md" "$W/MEMORY.md"; rm -rf "$W/memory"
run
check "empty workspace: still backs up (an empty archive)" '[ $rc = 0 ] && grep -q "committed" "$T/out"'
c3=$(git -C "$S" rev-parse HEAD); echo "grew" > "$W/MEMORY.md"
sed "s|^MAX_BYTES=.*|MAX_BYTES=10|" "$CB" > "$T/cb-small"; grep -q "^MAX_BYTES=10$" "$T/cb-small" || echo "FAIL could not shrink MAX_BYTES"
CB_REAL=$CB; CB=$T/cb-small; run; CB=$CB_REAL
check "backup over the size cap: refused with a /fail ping, nothing committed or left behind" \
  '[ $rc != 0 ] && grep -q "near GitHub.s 100 MB file limit" "$T/out" && grep -q "hc.example/check/fail" "$T/curl.log" && [ "$(git -C "$S" rev-parse HEAD)" = "$c3" ] && [ ! -e "$S/state.tar.gz.age.new" ]'
run
check "same state under the normal cap: committed (the refused run didn't record it as done)" '[ $rc = 0 ] && grep -q "committed" "$T/out"'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
