#!/bin/bash
# Fail if any word from $PERSONAL_DENYLIST (a newline-separated repo secret) appears in the tree, in a
# tracked path, or in what the given commit range adds (diff lines and commit messages). Case-insensitive,
# whole-word, fixed strings. Never prints a matched word: only file:line (a path that itself contains a
# listed word is withheld), a count of matching paths, or commit ids.
# An empty or missing list (fork PRs get no secrets) skips with a note.
# usage: PERSONAL_DENYLIST=... personal-denylist.sh [<from>..<to>]
set -euo pipefail
range=${1:-}

list=$(mktemp)
trap 'rm -f "$list"' EXIT
chmod 600 "$list"
# one word or phrase per line; trim spaces and CRs, drop blank lines and # comments
printf '%s\n' "${PERSONAL_DENYLIST:-}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v -e '^$' -e '^#' > "$list" || true
if [ ! -s "$list" ]; then
  echo "PERSONAL_DENYLIST is empty or unavailable (fork PR, or the secret isn't set): skipping"
  exit 0
fi
echo "checking against $(wc -l < "$list") listed words"
fail=0

# 1. file contents at this commit: print file:line, never the line itself, and withhold a path
#    that contains a listed word too. -z gives path NUL line NUL content, so odd paths parse safely.
hits=$(git grep -z -I -n -i -w -F -f "$list" -- . 2>/dev/null | while IFS= read -r -d '' path && IFS= read -r -d '' ln && IFS= read -r _; do
  if printf '%s\n' "$path" | grep -q -i -w -F -f "$list"; then echo "(path withheld):$ln"; else echo "$path:$ln"; fi
done || true)
if [ -n "$hits" ]; then
  echo "::error::listed words found in these files (word not shown):"
  printf '%s\n' "$hits"
  fail=1
fi

# 2. tracked paths: the path itself would give the word away, so only count them
n=$(git ls-files | grep -c -i -w -F -f "$list" || true)
if [ "$n" -gt 0 ]; then
  echo "::error::$n tracked path(s) contain a listed word (paths not shown). Find them locally with: git ls-files | grep -niwF -f <your list>"
  fail=1
fi

# 3. what the range adds: catches a word added then removed again, which a merge still carries into history.
#    Diffs of non-merge commits (a merge's own diff is combined), and every commit message, merges included:
#    "Merge pull request #N from <owner>/<branch>" carries the PR title and branch name into history.
if [ -n "$range" ] && ! git rev-list --quiet "$range" 2>/dev/null; then
  echo "::warning::can't read commit range $range (e.g. after a force push): checked the tree only"
  range=
fi
if [ -n "$range" ]; then
  for c in $(git rev-list "$range"); do
    if [ -z "$(git rev-list --no-walk --merges "$c")" ] \
       && git show --format= --no-color --no-ext-diff "$c" | grep '^+' | grep -q -i -w -F -f "$list"; then
      echo "::error::commit $c adds a listed word in its diff"; fail=1
    fi
    if git show -s --format=%B "$c" | grep -q -i -w -F -f "$list"; then
      echo "::error::commit $c has a listed word in its message"; fail=1
    fi
  done
fi

[ "$fail" = 0 ] && echo "ok: no listed words"
exit "$fail"
