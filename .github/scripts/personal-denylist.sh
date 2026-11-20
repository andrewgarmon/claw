#!/bin/bash
# Fail if any word from $PERSONAL_DENYLIST (a newline-separated repo secret) appears in the tree, in a
# tracked path, or in what the given commit range adds (diff lines and commit messages). Case-insensitive,
# whole-word, fixed strings. Never prints a matched word or where it is: only counts (matching lines,
# paths, commits) and which PR field matched.
# An empty or missing list (fork PRs get no secrets) skips with a note.
# On PRs, also checks PR_TITLE, PR_BRANCH and PR_BODY (env) before merge, since they go public
# immediately and end up in the merge or squash commit.
# usage: PERSONAL_DENYLIST=... [PR_TITLE=... PR_BRANCH=... PR_BODY=...] personal-denylist.sh [<from>..<to>]
set -euo pipefail
range=${1:-}
# - paths verbatim: git octal-escapes non-ASCII ones by default, which a word like "zürich" never matches
# - ignore gitattributes (the scanned tree's, and any global file): otherwise a PR adding "* -diff"
#   makes every file look binary, so git grep -I and the diffs skip them. Attributes come from the
#   empty tree instead (git >= 2.40); real binaries are still detected by content.
# - a UTF-8 locale so -i folds non-ASCII letters too
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.quotePath GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=core.attributesFile GIT_CONFIG_VALUE_1=/dev/null
export GIT_ATTR_SOURCE=4b825dc642cb6eb9a060e54bf8d69288fbee4904  # the empty tree
export LC_ALL=C.UTF-8
# matches <file>: count, never grep -q. -q quits at the first hit, the writer dies of SIGPIPE, and with
# pipefail that turns a hit in a big diff into "no match". Counting reads everything.
matches() { [ "$(grep -c -i -w -F -f "$list" || true)" -gt 0 ]; }

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

# Only counts are printed, never a location: locations would let anyone who can push a branch
# confirm guesses about the list one file or commit at a time. Find hits locally with the commands
# in the messages.
# 1. file contents at this commit. git grep exits 0 on hits, 1 on none; anything else is an
#    error, and an error must not pass.
raw=$(mktemp); trap 'rm -f "$list" "$raw"' EXIT
rc=0; git grep -z -I -n -i -w -F -f "$list" -- . > "$raw" 2>/dev/null || rc=$?
if [ "$rc" -gt 1 ]; then echo "::error::git grep failed (exit $rc), so the file check couldn't run"; exit 1; fi
hits=$(tr -cd '\0' < "$raw" | wc -c); hits=$((hits / 2))   # -z: path NUL line NUL content per hit
if [ "$hits" -gt 0 ]; then
  echo "::error::$hits line(s) in tracked files contain a listed word (locations not shown). Find them locally with: git grep -niwF -f <your list>"
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
  nd=0 nm=0
  for c in $(git rev-list "$range"); do
    if [ -z "$(git rev-list --no-walk --merges "$c")" ] \
       && git show --format= --no-color --no-ext-diff --no-textconv --no-renames "$c" | { grep '^+' || true; } | matches; then
      nd=$((nd + 1))
    fi
    if git show -s --format=%B "$c" | matches; then nm=$((nm + 1)); fi
  done
  if [ "$nd" -gt 0 ]; then
    echo "::error::$nd commit(s) in $range add a listed word in their diff (commits not shown). Find them locally with: git log -p $range | grep -niwF -f <your list>"; fail=1
  fi
  if [ "$nm" -gt 0 ]; then
    echo "::error::$nm commit message(s) in $range contain a listed word (commits not shown)"; fail=1
  fi
fi

# 4. PR title, branch name and body: public already, and carried into the merge or squash commit
for what in PR_TITLE PR_BRANCH PR_BODY; do
  if [ -n "${!what:-}" ] && printf '%s\n' "${!what}" | matches; then
    name=${what#PR_}; echo "::error::the PR's ${name,,} contains a listed word"; fail=1
  fi
done

[ "$fail" = 0 ] && echo "ok: no listed words"
exit "$fail"
