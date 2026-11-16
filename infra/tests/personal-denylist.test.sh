#!/bin/bash
# Tests for .github/scripts/personal-denylist.sh against scratch git repos.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../../.github/scripts/personal-denylist.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

WORD=Zorblax   # the "personal" word under test
LIST=$'zorblax\n\n# a comment\n  Quuxville Heights  \r'

repo() {  # fresh repo with one clean commit; prints nothing
  rm -rf "$T/r" && git init -q -b main "$T/r" && cd "$T/r" || exit 1
  git config user.name t && git config user.email t@example.com
  echo "nothing to see" > a.txt && git add a.txt && git commit -qm init
}
run() {  # run [range] -> sets rc and out
  out=$(PERSONAL_DENYLIST=${DL-$LIST} bash "$SCRIPT" "$@" 2>&1); rc=$?
}
expect() {  # expect <name> <rc> [grep pattern that must appear]
  local name=$1 want=$2 pat=${3:-}
  if [ "$rc" != "$want" ]; then bad "$name (rc=$rc, want $want): $out"; return; fi
  if printf '%s' "$out" | grep -qiF "$WORD" || printf '%s' "$out" | grep -qi "quuxville"; then
    bad "$name: output leaks a listed word: $out"; return; fi
  if [ -n "$pat" ] && ! printf '%s' "$out" | grep -qE "$pat"; then bad "$name: missing /$pat/: $out"; return; fi
  ok "$name"
}

repo; DL='' run; expect "empty list skips" 0 "skipping"
repo; unset DL; run; expect "clean tree passes" 0 "ok: no listed words"

repo; printf 'line one\nmet %s today\n' "$WORD" > b.txt; git add b.txt; git commit -qm b
run; expect "word in a file fails with file:line only" 1 "^b.txt:2$"

repo; echo "we went to QUUXVILLE heights" > c.txt; git add c.txt; git commit -qm c
run; expect "phrase, case-insensitive" 1 "^c.txt:1$"

repo; echo "zorblaxian and xzorblax" > d.txt; git add d.txt; git commit -qm d
run; expect "whole words only" 0 "ok: no listed words"

repo; mkdir -p people && echo hi > "people/$WORD.md"; git add people; git commit -qm p
run; expect "word in a path fails without printing the path" 1 "1 tracked path"

repo; base=$(git rev-parse HEAD)
echo "hi $WORD" > e.txt; git add e.txt; git commit -qm add; git rm -q e.txt; git commit -qm remove
run; expect "added-then-removed passes on the tree alone" 0
run "$base..HEAD"; expect "added-then-removed fails with the range" 1 "adds a listed word in its diff"

repo; base=$(git rev-parse HEAD)
echo ok > f.txt; git add f.txt; git commit -qm "fix for $WORD"
run "$base..HEAD"; expect "word in a commit message fails" 1 "listed word in its message"

repo; base=$(git rev-parse HEAD); echo fine > g.txt; git add g.txt; git commit -qm fine
run "$base..HEAD"; expect "clean range passes" 0 "ok: no listed words"

repo; mkdir -p notes && echo "lunch with $WORD" > "notes/$WORD.md"; git add notes; git commit -qm n
run; expect "word in both path and content: path withheld from file:line" 1 "^\(path withheld\):1$"

repo; mkdir -p 'odd:dir' && echo "$WORD" > 'odd:dir/x.txt'; git add .; git commit -qm o
run; expect "path with a colon still prints file:line" 1 "^odd:dir/x.txt:1$"

repo; base=$(git rev-parse HEAD); git checkout -qb feature; echo ok > h.txt; git add h.txt; git commit -qm h
git checkout -q main; git merge -q --no-ff -m "Merge pull request #9 from someone/$WORD-branch" feature
run "$base..HEAD"; expect "word in a merge commit message fails" 1 "listed word in its message"

repo; base=$(git rev-parse HEAD); git checkout -qb feature2; echo ok > i.txt; git add i.txt; git commit -qm i
git checkout -q main; git merge -q --no-ff -m "Merge pull request #10 from someone/clean" feature2
run "$base..HEAD"; expect "clean merge passes" 0 "ok: no listed words"

repo; mkdir -p notes && echo hi > "notes/Zürich.md"; git add notes; git commit -qm z
out=$(PERSONAL_DENYLIST=zürich bash "$SCRIPT" 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "1 tracked path" && ! printf '%s' "$out" | grep -qi "rich"; then ok "non-ASCII word in a path, case-insensitive"; else bad "non-ASCII path: rc=$rc $out"; fi

repo; base=$(git rev-parse HEAD); echo hi > "Zürich.txt"; git add .; git commit -qm add; git rm -q "Zürich.txt"; git commit -qm rm
out=$(PERSONAL_DENYLIST=zürich bash "$SCRIPT" "$base..HEAD" 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "adds a listed word in its diff"; then ok "non-ASCII path in a range's diff header"; else bad "non-ASCII diff path: rc=$rc $out"; fi

repo; run "deadbeef..HEAD"; expect "unreadable range warns and checks the tree" 0 "checked the tree only"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
