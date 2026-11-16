#!/usr/bin/env bash
# Tests for infra/brokers/git/agent-git against fake gh/git/id. Touches nothing outside a temp dir.
# Runs a copy of agent-git with HOME, PATH and the broker.sh path pointed into the repo/temp dir
# (the real script hardcodes them so sudo callers can't redirect it).
# Usage: bash infra/brokers/git/test.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
SRC=$D/agent-git LIB=$(cd "$D/../../lib" && pwd)/broker.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=$T/home BIN=$T/bin AG=$T/agent-git
mkdir -p "$H/.config" "$BIN"
echo s3cret-token > "$H/.config/gh-token"

sed -e "s|^export PATH=/usr/local/bin:/usr/bin:/bin$|export PATH=$BIN:/usr/bin:/bin|" \
    -e "s|^export HOME=/home/gitbot$|export HOME=$H|" \
    -e "s|^\. /usr/local/lib/claw/broker\.sh$|. $LIB|" "$SRC" > "$AG"
[ "$(grep -c "^export PATH=$BIN:\|^export HOME=$H$\|^\. $LIB$" "$AG")" = 3 ] \
  || { echo "FAIL could not point agent-git's PATH/HOME/broker.sh at the test dir (did those lines change?)"; exit 1; }

# fake id: gitbot unless $H/not_gitbot exists
cat > "$BIN/id" <<EOF
#!/bin/bash
[ -e "$H/not_gitbot" ] && echo openclaw || echo gitbot
EOF
# fake gh: logs each call as [arg][arg]..., answers like GitHub would.
# Issue 99 is a pull request, 404 doesn't exist. Repos named pub* are public, broken* can't be
# looked up, everything else is private (default branch main).
cat > "$BIN/gh" <<EOF
#!/bin/bash
printf '[%s]' "\$@" >> "$H/gh.log"; echo >> "$H/gh.log"
echo "\$GH_TOKEN" >> "$H/gh.env"
case "\$1 \$2" in
  "api repos/andrewgarmon/"*)
    case "\$2" in
      */issues/404) echo "HTTP 404: Not Found" >&2; exit 1 ;;
      */issues/99) echo true ;;
      */issues/*) echo false ;;
      repos/andrewgarmon/pub*) echo "false main" ;;
      repos/andrewgarmon/broken*) echo "HTTP 502" >&2; exit 1 ;;
      *) echo "true main" ;;
    esac ;;
  "issue create") echo "https://github.com/andrewgarmon/\${4#andrewgarmon/}/issues/42" ;;
  "issue list") echo '[{"number":23,"title":"t","labels":["claude-ready"],"url":"u"}]' ;;
  "issue view") echo '{"number":23,"title":"t","body":"b","labels":[],"comments":[]}' ;;
  "issue comment") echo "https://github.com/andrewgarmon/x/issues/\$3#issuecomment-1" ;;
  "issue edit"|"issue close"|"issue reopen") ;;
  "label create") [ "\$3" = bug ] && { echo "label already exists" >&2; exit 1; } ;;
  "repo create") ;;
  "pr list") ;;
  "pr create") echo "https://github.com/andrewgarmon/x/pull/7" ;;
  *) echo "fake gh: unexpected \$*" >&2; exit 2 ;;
esac
EOF
# fake git: logs calls, everything succeeds. log -p prints \$H/diffs, log --name-only \$H/paths,
# cat-file \$H/commits (raw commit objects), rev-list --merges \$H/merges (what the branch would push).
cat > "$BIN/git" <<EOF
#!/bin/bash
printf '[%s]' "\$@" >> "$H/git.log"; echo >> "$H/git.log"
case " \$* " in *" rev-parse "*) echo deadbeef ;; *" init "*) mkdir -p "\${!#}" ;; *" bundle verify "*) cp "\${!#}" "$H/bundle" ;; *" rev-list --merges "*) cat "$H/merges" 2>/dev/null ;; *" rev-list "*) echo deadbeef ;; *" cat-file "*) cat "$H/commits" ;; *" log -p "*) cat "$H/diffs" ;; *" --name-only "*) cat "$H/paths" ;; esac
exit 0
EOF
# fake gitleaks: flags ghp_ tokens like the real rule, skips lines marked gitleaks:allow like the
# real tool, writes a report naming the file, exits 1 on a finding. Logs each run.
cat > "$BIN/gitleaks" <<EOF
#!/bin/bash
echo run >> "$H/gitleaks.log"
while [ \$# -gt 0 ]; do case "\$1" in --source) src=\$2; shift ;; --report-path) rep=\$2; shift ;; esac; shift; done
hit=0; : > "\$rep"
for f in "\$src"/*; do
  if grep -v 'gitleaks:allow' "\$f" | grep -qE 'ghp_[A-Za-z0-9]{36}'; then echo "{\"File\": \"\$f\"}" >> "\$rep"; hit=1; fi
done
exit \$hit
EOF
chmod +x "$BIN"/*

fails=0
run() {  # run <agent-git args...>; stdin from $T/stdin, emptied afterwards
  : > "$H/gh.log"; : > "$H/git.log"; : > "$H/gh.env"; : > "$H/agent-git.log"; : > "$H/gitleaks.log"; rm -f "$H/bundle"
  bash "$AG" "$@" < "$T/stdin" > "$T/out" 2>&1; rc=$?
  : > "$T/stdin"
}
stdin() { printf '%s' "$1" > "$T/stdin"; }  # stdin <text>: stdin for the next run
FAKE_BUNDLE=$(printf '# v2 git bundle\ndeadbeef refs/heads/claude/x\n\n\001\002PACK')
check() {  # check <name> <condition...>
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out: /' "$T/out"; sed 's/^/     gh:  /' "$H/gh.log"; fails=$((fails + 1)); fi
}
called()    { grep -qF -- "$1" "$H/gh.log"; }
no_gh()     { [ ! -s "$H/gh.log" ]; }
calls()     { [ "$(wc -l < "$H/gh.log")" -eq "$1" ]; }
logged()    { grep -qE "caller=.* $1" "$H/agent-git.log"; }
denied()    { [ "$rc" = 1 ] && logged "DENY" && grep -q "${1:-agent-git:}" "$T/out"; }
says()      { grep -qF -- "$1" "$T/out"; }
: > "$T/stdin"

# ---------- allowed ----------
stdin "Done when: it works"
run issue claw-config "Add a thing" "claude-ready,human-effort:low"
check "issue: creates with title, body and each allowlisted label" \
  eval '[ $rc = 0 ] && called "[issue][create][-R][andrewgarmon/claw-config][--title=Add a thing][--body=Done when: it works][--label=claude-ready][--label=human-effort:low]" && says /issues/42 && logged "ISSUE-NEW claw-config"'

stdin ""
run issue new-repo "t" "human-effort:low,bug"
check "issue: missing labels created on the target repo first, without --force; existing ones don't fail it" \
  eval '[ $rc = 0 ] && called "[label][create][human-effort:low][-R][andrewgarmon/new-repo][--color][d93f0b]" && called "[label][create][bug][-R][andrewgarmon/new-repo]" && ! called "--force" && called "[issue][create][-R][andrewgarmon/new-repo]" && [ "$(grep -n "^\[label\]" "$H/gh.log" | tail -1 | cut -d: -f1)" -lt "$(grep -n "^\[issue\]" "$H/gh.log" | cut -d: -f1)" ]'

run issue claw-config "No body"
check "issue: no body or labels gets a default body, no --label" \
  eval '[ $rc = 0 ] && called "[--body=Filed by" && ! called "--label" && ! called "[label]"'

stdin "--label wontfix"
run issue claw-config "--repo evil/x"
check "issue: dash-leading title/body stay values, not flags" \
  eval '[ $rc = 0 ] && called "[--title=--repo evil/x][--body=--label wontfix]"'

printf 'line1\nline2\n\n' > "$T/stdin"
run issue claw-config "t"
check "issue: multi-line body allowed, trailing newlines dropped" eval '[ $rc = 0 ] && called "[--body=line1" && grep -qx "line2\]" "$H/gh.log"'

# shellcheck disable=SC2016  # literal backticks and $ on purpose
stdin 'Fails in `gh issue create --label=X` and $(id) and ${HOME} and "quotes"'
run issue claw-config "t"
check "issue: backticks, \$() and quotes in stdin body kept verbatim" \
  eval '[ $rc = 0 ] && called "[--body=Fails in \`gh issue create --label=X\` and \$(id) and \${HOME} and \"quotes\"]"'

run issue-list claw-config
check "issue-list: open by default, JSON fields, no label filter" \
  eval '[ $rc = 0 ] && called "[issue][list][-R][andrewgarmon/claw-config][--state][open]" && called "[--json][number,title,labels,url]" && ! called "--label" && says "\"number\":23"'

run issue-list claw-config claude-ready closed
check "issue-list: label + state" \
  eval '[ $rc = 0 ] && called "[--state][closed]" && called "[--label=claude-ready]"'

run issue-list claw-config "" all
check "issue-list: empty label, state all" eval '[ $rc = 0 ] && called "[--state][all]" && ! called "--label"'

run issue-view claw-config 23
check "issue-view: title, body, labels, comments" \
  eval '[ $rc = 0 ] && called "[issue][view][23][-R][andrewgarmon/claw-config][--json][number,title,state,url,body,labels,comments]" && says "\"body\":\"b\""'

stdin "Working on it"
run issue-comment claw-config 23
check "issue-comment: checks it is an issue, then comments" \
  eval '[ $rc = 0 ] && called "[api][repos/andrewgarmon/claw-config/issues/23]" && called "[issue][comment][23][-R][andrewgarmon/claw-config][--body=Working on it]" && logged "ISSUE-COMMENT claw-config#23"'

run issue-label claw-config 23 add value:high
check "issue-label add: ensures the label exists, then adds it" eval '[ $rc = 0 ] && called "[label][create][value:high][-R][andrewgarmon/claw-config]" && called "[issue][edit][23][-R][andrewgarmon/claw-config][--add-label=value:high]"'
run issue-label claw-config 23 remove agent
check "issue-label remove: creates no label" eval '[ $rc = 0 ] && called "[--remove-label=agent]" && ! called "[label]" && logged "ISSUE-LABEL claw-config#23 remove agent"'

run new-repo fresh "A repo"
check "new-repo: creates the repo, then seeds every allowlisted label" \
  eval '[ $rc = 0 ] && called "[repo][create][andrewgarmon/fresh][--private]" && [ "$(grep -c "^\[label\]\[create\].*\[andrewgarmon/fresh\]" "$H/gh.log")" = 11 ] && called "[label][create][self-improvement][-R][andrewgarmon/fresh]" && says https://github.com/andrewgarmon/fresh && logged "REPO-NEW fresh"'

stdin "Done in https://github.com/andrewgarmon/claw-config/pull/24"
run issue-close claw-config 23
check "issue-close: with comment" \
  eval '[ $rc = 0 ] && called "[issue][close][23][-R][andrewgarmon/claw-config][--comment=Done in https://github.com/andrewgarmon/claw-config/pull/24]" && logged "ISSUE-CLOSE claw-config#23"'

run issue-reopen claw-config 23
check "issue-reopen" eval '[ $rc = 0 ] && called "[issue][reopen][23][-R][andrewgarmon/claw-config]" && logged "ISSUE-REOPEN"'

check "token reaches gh via env, never argv" \
  eval 'grep -qx s3cret-token "$H/gh.env" && ! grep -rq s3cret "$H/gh.log" "$H/agent-git.log"'

# shellcheck disable=SC2016
stdin "$(printf 'Body with `ticks`\nline 2\n\n%s' "$FAKE_BUNDLE")"
run pr claw-config claude/x "Title"
check "pr: body from stdin before the bundle, bundle passed on intact" \
  eval '[ $rc = 0 ] && grep -qF "[+refs/agent/claude/x:refs/heads/claude/x]" "$H/git.log" && grep -qxF "[pr][create][-R][andrewgarmon/claw-config][--head][claude/x][--title][Title][--body][Body with \`ticks\`" "$H/gh.log" && grep -qx "line 2\]" "$H/gh.log" && cmp -s "$H/bundle" <(printf "%s" "$FAKE_BUNDLE") && says /pull/7'

stdin "$FAKE_BUNDLE"
run pr claw-config claude/x "Title"
check "pr: bundle alone gets the default body" \
  eval '[ $rc = 0 ] && called "[--body][Opened by" && cmp -s "$H/bundle" <(printf "%s" "$FAKE_BUNDLE")'

stdin "$(printf 'x\n# v3 git bundle\n@filter\n')"
run pr claw-config claude/x "Title"
check "pr: v3 bundle header also splits" eval '[ $rc = 0 ] && called "[--body][x]" && head -1 "$H/bundle" | grep -qx "# v3 git bundle"'

stdin "$(printf 'a # v2 git bundle\n%s' "$FAKE_BUNDLE")"
run pr claw-config claude/x "Title"
check "pr: header text mid-line does not split" eval '[ $rc = 0 ] && called "[--body][a # v2 git bundle]"'

# ---------- denied ----------
run issue claw-config "t" "bug,wontfix"
check "issue: label outside allowlist denied, nothing created" eval 'denied "label not allowed: wontfix" && no_gh'
run issue claw-config "t" "bug,,agent"
check "issue: empty label in list denied" eval 'denied "label not allowed" && no_gh'
run issue claw-config "t" "Bug"
check "issue: labels are case-sensitive" eval 'denied && no_gh'

run issue claw-config ""
check "issue: empty title denied" eval 'denied "title empty" && no_gh'
run issue claw-config "$(printf 'x%.0s' {1..201})"
check "issue: 201-char title denied" eval 'denied "too long" && no_gh'
run issue claw-config "$(printf 'x%.0s' {1..200})"
check "issue: 200-char title allowed" eval '[ $rc = 0 ]'
run issue claw-config "$(printf 'a\nb')"
check "issue: newline in title denied" eval 'denied && no_gh'
stdin "$(printf 'x%.0s' {1..20001})"
run issue claw-config "t"
check "issue: 20001-char body denied" eval 'denied "body too long" && no_gh'
stdin "$(printf 'x%.0s' {1..20000})"
run issue claw-config "t"
check "issue: 20000-char body allowed" eval '[ $rc = 0 ]'
stdin "$(printf 'x%.0s' {1..100000})"
run issue claw-config "t"
check "issue: huge body denied" eval 'denied "body too long" && no_gh'
run issue claw-config "t" "Body as an argument" "bug"
check "issue: old body argument form denied" eval 'denied "bodies go on stdin" && no_gh'
run issue claw-config "t" "Body as an argument"
check "issue: body passed where labels go is denied with a hint" eval 'denied "bodies go on stdin" && no_gh'
run issue claw-config
check "issue: missing title denied" eval 'denied usage && no_gh'

for r in ../x .hidden a/b "" "x y" "$(printf 'r%.0s' {1..101})"; do
  run issue "$r" "t"
  check "bad repo denied: '${r:0:20}'" eval 'denied && no_gh'
done
run issue-list ../etc
check "issue-list: bad repo denied" eval 'denied "bad repo" && no_gh'

for n in 0 abc "1;id" -1 1234567890 "23 " "" 0x10; do
  run issue-view claw-config "$n"
  check "bad number denied: '$n'" eval 'denied && no_gh'
done

run issue-list claw-config "" deleted
check "issue-list: bad state denied" eval 'denied "state must be" && no_gh'
run issue-list claw-config "a b"
check "issue-list: bad label filter denied" eval 'denied "bad label" && no_gh'

run issue-label claw-config 23 add wontfix
check "issue-label: label outside allowlist denied" eval 'denied "label not allowed" && no_gh'
run issue-label claw-config 23 set bug
check "issue-label: op other than add/remove denied" eval 'denied "op must be" && no_gh'
run issue-label claw-config 23 add
check "issue-label: missing label denied" eval 'denied usage && no_gh'

run issue-close claw-config
check "issue-close: missing number denied" eval 'denied usage && no_gh'
run issue-close claw-config 23
check "issue-close: empty stdin denied" eval 'denied "closing comment empty" && no_gh'
stdin $'\n\n'
run issue-close claw-config 23
check "issue-close: blank-lines-only comment denied" eval 'denied "closing comment empty" && no_gh'
run issue-close claw-config 23 "Done"
check "issue-close: comment as argument denied" eval 'denied "bodies go on stdin" && no_gh'
run issue-comment claw-config 23
check "issue-comment: empty stdin denied" eval 'denied "comment empty" && no_gh'
run issue-comment claw-config 23 "hi"
check "issue-comment: comment as argument denied" eval 'denied "bodies go on stdin" && no_gh'
stdin "$(printf 'x%.0s' {1..20001})"
run issue-comment claw-config 23
check "issue-comment: too long denied" eval 'denied "too long" && no_gh'

for c in "issue-close claw-config 99" "issue-reopen claw-config 99" "issue-comment claw-config 99" "issue-label claw-config 99 add bug"; do
  read -ra a <<< "$c"
  stdin "bye"
  run "${a[@]}"
  check "${a[0]} on a pull request number denied" eval 'denied "is a pull request" && calls 1 && called "[api]"'
done
stdin "bye"
run issue-close claw-config 404
check "issue-close on missing issue denied" eval 'denied "no issue" && calls 1'

for c in issue-delete issue-lock issue-transfer issue-edit issue-pin delete; do
  run "$c" claw-config 23 x
  check "no such subcommand: $c" eval '[ $rc = 1 ] && says usage: && no_gh'
done

stdin "$FAKE_BUNDLE"
run pr claw-config main "t"
check "pr: main branch still denied" eval 'denied "branch must be" && no_gh && [ ! -s "$H/git.log" ]'
stdin "$FAKE_BUNDLE"
run pr claw-config claude/x "t" "Body as an argument"
check "pr: body as argument denied" eval 'denied "bodies go on stdin" && no_gh && [ ! -s "$H/git.log" ]'
stdin "just a body, no bundle"
run pr claw-config claude/x "t"
check "pr: no bundle on stdin denied" eval 'denied "no git bundle on stdin" && no_gh && [ ! -s "$H/git.log" ]'
stdin "$(printf 'x%.0s' {1..20001}; printf '\n%s' "$FAKE_BUNDLE")"
run pr claw-config claude/x "t"
check "pr: body too long denied before pushing" eval 'denied "body too long" && no_gh && [ ! -s "$H/git.log" ]'

: > "$H/.config/gh-token"
run issue claw-config "t"
check "empty token file: refused before calling gh" eval 'denied "secret file missing or empty" && no_gh'
echo s3cret-token > "$H/.config/gh-token"

# ---------- public repos ----------
# fixture values are made up; the real list lives only on the host
printf '# personal strings\n\n  Jane Q Example  \n9007000001\nexample_claw_bot\nJosé Ejemplo\n' > "$H/.config/redact.txt"
: > "$H/commits"; : > "$H/diffs"; : > "$H/paths"
TOKEN="ghp_$(printf 'a1B2c3D4e5%.0s' 1 2 3 4 | head -c 36)"
pushed()   { grep -qF "refs/heads/claude/x]" "$H/git.log" && grep -q "\[push\]" "$H/git.log"; }
not_shown() { ! grep -qiE "jane q example|9007000001|example_claw_bot|$TOKEN" "$T/out" "$H/agent-git.log"; }
created()  { called "[issue][create]"; }

for c in "issue pub-repo t" "issue-comment pub-repo 23" "issue-close pub-repo 23" "issue-label pub-repo 23 add bug" "issue-reopen pub-repo 23"; do
  read -ra a <<< "$c"
  stdin "hello"
  SUDO_USER=openclaw run "${a[@]}"
  check "public repo: ${a[0]} from openclaw refused, nothing written" \
    eval 'denied "only Claude Code can write" && ! called "[issue][create]" && ! called "[issue][comment]" && ! called "[issue][close]" && ! called "[issue][edit]" && ! called "[issue][reopen]" && ! called "[label]"'
done
stdin "$FAKE_BUNDLE"
SUDO_USER=openclaw run pr pub-repo claude/x "t"
check "public repo: pr from openclaw refused before anything is pushed" eval 'denied "only Claude Code" && [ ! -s "$H/git.log" ] && ! called "[pr]"'
SUDO_USER=openclaw run issue-list pub-repo
check "public repo: reads stay open to openclaw" eval '[ $rc = 0 ] && called "[issue][list]"'

stdin "Done when: it builds"
SUDO_USER=coder run issue pub-repo "Add a README"
check "public repo: clean issue from coder allowed after both checks" eval '[ $rc = 0 ] && created && [ -s "$H/gitleaks.log" ] && logged "LEAK-CHECK-OK pub-repo"'
stdin "x"
SUDO_USER=coder run issue pub-repo "Thanks jane q EXAMPLE"
check "public repo: redact entry in title refused (case-insensitive), match not shown" eval 'denied "title contain a redact.txt entry" && ! created && not_shown'
stdin "thanks JOSÉ EJEMPLO"
LC_ALL=C SUDO_USER=coder run issue pub-repo "t"
check "public repo: case-insensitive match covers non-ASCII letters, even from a C locale" eval 'denied "body contain a redact.txt entry" && ! created'
stdin "ping 9007000001 later"
SUDO_USER=coder run issue pub-repo "t"
check "public repo: redact entry in body refused" eval 'denied "body contain a redact.txt entry" && ! created && not_shown'
stdin "token: $TOKEN"
SUDO_USER=coder run issue pub-repo "t"
check "public repo: token in body refused by gitleaks, token not shown" eval 'denied "gitleaks flagged body" && ! created && not_shown'
stdin "token: $TOKEN # gitleaks:allow"
SUDO_USER=coder run issue pub-repo "t"
check "public repo: gitleaks:allow marker doesn't get a token through" eval 'denied "gitleaks flagged body" && ! created'
stdin "see example_claw_bot"
SUDO_USER=coder run issue-comment pub-repo 23
check "public repo: redact entry in a comment refused" eval 'denied "comment contain" && ! called "[issue][comment]" && not_shown'
stdin "fixed, token was $TOKEN"
SUDO_USER=coder run issue-close pub-repo 23
check "public repo: token in a closing comment refused" eval 'denied "gitleaks flagged comment" && ! called "[issue][close]"'
SUDO_USER=coder run issue-label pub-repo 23 add bug
check "public repo: coder can label (no text to check)" eval '[ $rc = 0 ] && called "[issue][edit]"'

printf 'commit deadbeef\nAuthor: Claude Code <claude@claw.invalid>\n\nAdd docs\n' > "$H/commits"
printf 'diff --git a/README b/README\n+++ b/README\n@@ -0,0 +1 @@\n+hello world\n' > "$H/diffs"
stdin "$(printf 'Body\n%s' "$FAKE_BUNDLE")"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: clean pr from coder pushed; only commits not on main are checked" \
  eval '[ $rc = 0 ] && pushed && grep -qF "[^refs/base/main]" "$H/git.log" && grep -qF "[+refs/heads/main:refs/base/main]" "$H/git.log" && grep -qF "[--no-renames]" "$H/git.log" && called "[pr][create]"'
printf 'diff --git a/README b/README\n+++ b/README\n@@ -0,0 +1 @@\n+owner: Jane Q Example\n' > "$H/diffs"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: redact entry in an added line refused before pushing" eval 'denied "added-lines contain a redact.txt entry" && ! pushed && ! called "[pr]" && not_shown'
printf 'diff --git a/x b/x\n+++ b/notes/Jane Q Example.md\n@@ -0,0 +1 @@\n+hi\n' > "$H/diffs"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Edit"
check "public repo: editing a file whose already-public path has a redact entry is allowed (headers aren't checked)" eval '[ $rc = 0 ] && pushed'
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n--- old\n+++ Jane Q Example\n' > "$H/diffs"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: an added line that looks like a header is still checked" eval 'denied "added-lines contain" && ! pushed'
printf 'notes/Jane Q Example.md\n' > "$H/paths"; : > "$H/diffs"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: redact entry in an added path refused even with no diff lines (empty file)" eval 'denied "added-paths contain" && ! pushed && grep -qF "[--diff-filter=A]" "$H/git.log" && grep -qF "[core.quotePath=false]" "$H/git.log"'
: > "$H/paths"
printf -- 'diff --git a/CREDITS b/CREDITS\n--- a/CREDITS\n+++ b/CREDITS\n@@ -1 +1 @@ owner: Jane Q Example\n-owner: Jane Q Example\n+owner: the maintainers\n' > "$H/diffs"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Remove a name"
check "public repo: removing already-public text is allowed (removed lines and hunk headers aren't checked)" eval '[ $rc = 0 ] && pushed'
: > "$H/diffs"
printf 'commit deadbeef\nAuthor: Claude Code <claude@claw.invalid>\n\ndiff --git a/x b/x\nthanks Jane Q Example\n' > "$H/commits"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: diff-looking text in a commit message doesn't hide the rest of it" eval 'denied "commit-messages contain" && ! pushed'
echo cafef00d > "$H/merges"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: branch with merge commits refused (rebase instead)" eval 'denied "has merge commits. Rebase onto main" && ! pushed && grep -qF "[rev-list][--merges]" "$H/git.log"'
rm "$H/merges"
stdin "$FAKE_BUNDLE"
SUDO_USER=openclaw run pr claw-config claude/x "t"
check "private repo: no merge check" eval '[ $rc = 0 ] && ! grep -qF "[rev-list]" "$H/git.log"'
printf 'commit deadbeef\nAuthor: Jane Q Example <x@example.invalid>\n\nDocs\n' > "$H/commits"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: a personal author identity is refused" eval 'denied "commit-messages contain" && ! pushed'
printf 'deadbeef commit 99\ntree 1111\nauthor Claude Code <claude@claw.invalid> 1 +0000\nx-note Jane Q Example\n\nDocs\n' > "$H/commits"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: extra headers in the raw commit object are checked" eval 'denied "commit-messages contain" && ! pushed && grep -qF "[cat-file][--batch]" "$H/git.log"'
printf 'commit deadbeef\nAuthor: Claude Code <claude@claw.invalid>\n\nuse %s for now\n' "$TOKEN" > "$H/commits"
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: token in a commit message refused before pushing" eval 'denied "gitleaks flagged commit-messages" && ! pushed && not_shown'
: > "$H/commits"
stdin "$(printf 'Pings 9007000001\n%s' "$FAKE_BUNDLE")"
SUDO_USER=coder run pr pub-repo claude/x "Docs"
check "public repo: redact entry in the pr body refused before pushing" eval 'denied "body contain" && ! pushed && not_shown'
stdin "$FAKE_BUNDLE"
SUDO_USER=coder run pr pub-repo claude/example_claw_bot-fix "Docs"
check "public repo: redact entry in the branch name refused" eval 'denied "branch-name contain" && ! pushed'

mv "$H/.config/redact.txt" "$H/redact.bak"
stdin "x"
SUDO_USER=coder run issue pub-repo "t"
check "public repo: missing redact.txt refuses every write" eval 'denied "redact.txt is missing" && ! created'
printf '# only a comment\n\n   \n' > "$H/.config/redact.txt"
stdin "x"
SUDO_USER=coder run issue pub-repo "t"
check "public repo: redact.txt with no entries refuses (blank lines never match everything)" eval 'denied "has no entries" && ! created'
mv "$H/redact.bak" "$H/.config/redact.txt"

printf '# flipping soon\nsoon-public\n' > "$H/.config/public-repos"
stdin "x"
SUDO_USER=openclaw run issue soon-public "t"
check "listed in public-repos: treated as public even while GitHub says private" eval 'denied "only Claude Code" && ! created'
rm "$H/.config/public-repos"
stdin "x"
SUDO_USER=coder run issue broken-repo "t"
check "visibility lookup fails: nothing written" eval 'denied "could not check whether broken-repo is public" && ! created'

stdin "Jane Q Example says hi, $TOKEN"
SUDO_USER=openclaw run issue claw-config "t"
check "private repo: openclaw allowed, no checks run (unchanged)" eval '[ $rc = 0 ] && created && [ ! -s "$H/gitleaks.log" ]'
stdin "$FAKE_BUNDLE"
SUDO_USER=openclaw run pr claw-config claude/x "t"
check "private repo: openclaw pr pushed without checks (unchanged)" eval '[ $rc = 0 ] && pushed && ! grep -qF "refs/base" "$H/git.log" && [ ! -s "$H/gitleaks.log" ]'
run new-repo another
check "new-repo: still private only" eval '[ $rc = 0 ] && called "[repo][create][andrewgarmon/another][--private]"'

touch "$H/not_gitbot"
run issue claw-config "t"
check "not running as gitbot: refused" eval '[ $rc = 1 ] && says "must run as gitbot" && no_gh'
rm "$H/not_gitbot"

echo; [ $fails = 0 ] && echo "all agent-git tests passed" || { echo "$fails failed"; exit 1; }
