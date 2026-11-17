#!/usr/bin/env bash
# claw-smoke: check that the live host is wired up the way infra/ says. CI tests the logic with
# fakes; this checks the real users, sudo rules, tokens, the installed ACP adapter and the timers.
# Installed root-owned as /usr/local/bin/claw-smoke; claw-install runs it after each install.
# Usage (as the admin user): sudo claw-smoke
#
# Prints PASS/FAIL/SKIP <check> per check and exits 1 if any check fails.
# Read-only, or refused before any network access: never pushes, never messages Telegram, never
# creates calendar events, never calls a model. Never prints command output (it could carry a
# secret); a failure gives claw-smoke's own reason and where to look.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ACP_LOCK=/usr/local/lib/claw/acp/package-lock.json
CODER_ACP=/usr/local/bin/coder-acp
AGENT_GIT=/usr/local/bin/agent-git
AGENT_CAL=/usr/local/bin/agent-cal
CAL_SECRET=/home/calbot/.config/caldav.env
OC_HOME=/home/openclaw
CONFIG_REPO=claw-config   # the repo claw-install deploys (see its REPO)
STATE_REPO=claw-state     # agent-git's STATE_REPO
WAIT=${CLAW_SMOKE_WAIT:-20}   # seconds per command; override only for tests

[ "$(id -u)" = 0 ] || { echo "claw-smoke: run with sudo" >&2; exit 1; }
cd / || exit 1   # sudo -u keeps the cwd, and the other users can't read root's
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

pass=0 fail=0 skip=0
PASS() { echo "PASS $1"; pass=$((pass + 1)); }
FAIL() { echo "FAIL $1: $2"; fail=$((fail + 1)); }
SKIP() { echo "SKIP $1: $2"; skip=$((skip + 1)); }
# via <caller> <target user> <cmd>...: run cmd the way agents do, through the caller's own sudo rule
via() { local caller=$1 target=$2; shift 2; timeout "$WAIT" sudo -n -u "$caller" sudo -n -u "$target" "$@"; }
is_list() { python3 -I -c 'import json,sys; sys.exit(0 if isinstance(json.load(sys.stdin), list) else 1)' 2>/dev/null; }
exited() { [ "$1" = 124 ] && echo "timed out after ${WAIT}s" || echo "exit $1"; }

# 1. ACP adapter: starts through openclaw's sudo rule as coder, answers initialize, and is the
#    version the lockfile pins. No network, no Claude usage.
check_acp() {
  local want got rc
  want=$(python3 -I -c 'import json,sys
print(json.load(open(sys.argv[1]))["packages"]["node_modules/@agentclientprotocol/claude-agent-acp"]["version"])' \
    "$ACP_LOCK" 2>/dev/null) || { FAIL acp-adapter "can't read the pinned version from $ACP_LOCK"; return; }
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
    | via openclaw coder "$CODER_ACP" > "$OUT/acp" 2>/dev/null; rc=$?
  got=$(python3 -I -c 'import json,sys
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    if isinstance(m, dict) and m.get("id") == 1:
        r = m.get("result") or {}
        print((r.get("agentInfo") or {}).get("version", "") if isinstance(r, dict) else "")
        sys.exit(0)
sys.exit(1)' < "$OUT/acp" 2>/dev/null) \
    || { FAIL acp-adapter "no initialize reply ($(exited $rc)); try: sudo -u openclaw sudo -n -u coder $CODER_ACP"; return; }
  [[ "$got" =~ ^[0-9A-Za-z.+-]{1,40}$ ]] || { FAIL acp-adapter "initialize reply has no usable agent version"; return; }
  [ "$got" = "$want" ] || { FAIL acp-adapter "adapter is $got but the lockfile pins $want (re-run: sudo claw-install)"; return; }
  PASS acp-adapter
}

# 2. agent-git works for openclaw and gitbot's token is valid: one read-only GitHub API call.
check_git_token() {
  local rc
  via openclaw gitbot "$AGENT_GIT" issue-list "$CONFIG_REPO" > "$OUT/issues" 2>/dev/null; rc=$?
  if [ $rc = 0 ] && is_list < "$OUT/issues"; then PASS agent-git-token; return; fi
  FAIL agent-git-token "issue-list on $CONFIG_REPO failed ($(exited $rc)): gitbot's token may be expired or revoked, or the sudo rule is broken; see /home/gitbot/agent-git.log"
}

# 3. agent-git refuses what it should. Both are refused before any fetch; each adds a DENY line
#    to agent-git.log (the branch names say claw-smoke).
# refused <caller> <expected message> <agent-git args...>: agent-git exits non-zero with that message
refused() {
  local caller=$1 want=$2 rc; shift 2
  via "$caller" gitbot "$AGENT_GIT" "$@" < /dev/null > /dev/null 2> "$OUT/err"; rc=$?
  [ $rc != 0 ] && [ $rc != 124 ] && grep -qF "$want" "$OUT/err"
}
check_git_refusals() {
  local bad=
  refused coder "only claw-backup" pr "$STATE_REPO" agent/state/claw-smoke claw-smoke \
    || bad="coder's state-backup push wasn't refused as expected"
  refused openclaw "takes nothing else" pr "$STATE_REPO" claude/claw-smoke claw-smoke \
    || bad="${bad:+$bad; }a claude/* push to $STATE_REPO wasn't refused as expected"
  if [ -z "$bad" ]; then PASS agent-git-refusals; else FAIL agent-git-refusals "$bad (see /home/gitbot/agent-git.log)"; fi
}

# 4. Timers are enabled, active and have a next run.
check_timers() {
  local t next bad=
  for t in claw-sync.timer claw-backup.timer; do
    if ! systemctl is-enabled -q "$t" 2>/dev/null || ! systemctl is-active -q "$t" 2>/dev/null; then
      bad="${bad:+$bad; }$t isn't enabled and active"; continue
    fi
    next=$(systemctl list-timers --all --no-legend "$t" 2>/dev/null | awk 'NR == 1 { print $1 }')
    case "$next" in ''|-|n/a) bad="${bad:+$bad; }$t has no next run" ;; esac
  done
  if [ -z "$bad" ]; then PASS timers; else FAIL timers "$bad"; fi
}

# 5. The gateway runs what's on main (as of claw-sync's last fetch) and answers health RPCs.
check_gateway() {
  local head main uid
  head=$(sudo -n -u openclaw git -C "$OC_HOME/.openclaw" rev-parse HEAD 2>/dev/null)
  main=$(sudo -n -u openclaw git -C "$OC_HOME/.openclaw" rev-parse origin/main 2>/dev/null)
  if [ -z "$head" ] || [ "$head" != "$main" ]; then
    FAIL gateway "$OC_HOME/.openclaw is at ${head:0:7}, origin/main at ${main:0:7}: a deploy is pending or main is marked bad (journalctl -u claw-sync)"
    return
  fi
  uid=$(id -u openclaw 2>/dev/null) || { FAIL gateway "no openclaw user"; return; }
  if ! timeout "$WAIT" sudo -n -u openclaw env HOME="$OC_HOME" PATH="$OC_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
       XDG_RUNTIME_DIR="/run/user/$uid" openclaw gateway health --timeout 10000 > /dev/null 2>&1; then
    FAIL gateway "openclaw gateway health didn't answer (journalctl --user -u openclaw-gateway as openclaw)"
    return
  fi
  PASS gateway
}

# 6. Calendar broker, if it's installed and configured: one read-only CalDAV request.
check_cal() {
  local rc
  [ -x "$AGENT_CAL" ] || { SKIP agent-cal "broker not installed"; return; }
  [ -s "$CAL_SECRET" ] || { SKIP agent-cal "no CalDAV secret yet"; return; }
  via openclaw calbot "$AGENT_CAL" calendars > "$OUT/cals" 2>/dev/null; rc=$?
  if [ $rc = 0 ] && is_list < "$OUT/cals"; then PASS agent-cal; return; fi
  FAIL agent-cal "listing calendars failed ($(exited $rc)): check the app-specific password; see /home/calbot/agent-cal.log"
}

check_acp
check_git_token
check_git_refusals
check_timers
check_gateway
check_cal

if [ "$fail" = 0 ]; then
  s=; [ "$skip" = 0 ] || s=" ($skip skipped)"
  echo "claw-smoke: all $pass checks passed$s"
else
  echo "claw-smoke: $fail of $((pass + fail)) checks FAILED"
  exit 1
fi
