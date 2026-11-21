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
CLAUDE_USAGE=/usr/local/bin/claude-usage
AGENT_GIT=/usr/local/bin/agent-git
AGENT_CAL=/usr/local/bin/agent-cal
CAL_SECRET=/home/calbot/.config/caldav.env
OC_HOME=/home/openclaw
OC_PLUGINS=/usr/local/lib/claw/openclaw-plugins   # root-owned plugins (install.sh, lib/openclaw-plugins.sh)
GLOBAL_PLUGINS="acpx duckduckgo"   # the only plugins expected from ~/.openclaw/extensions (claw-sync has the same list)
CONFIG_REPO=claw   # the repo claw-install deploys (see its REPO)
STATE_REPO=claw-state     # agent-git's STATE_REPO
SMOKE_WINDOWS=/var/lib/claw-smoke/refusal-windows   # claw-denywatch skips its expected refusals in these
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

# 1b. Plan usage is readable (claude-usage, as openclaw -> coder). One call to the usage endpoint, no
#     model call. Skipped when Claude Code isn't logged in with plan limits (exit 3).
check_usage() {
  local rc WAIT=$(( WAIT * 3 ))   # a fresh read starts Claude Code (~10s)
  via openclaw coder "$CLAUDE_USAGE" --fresh > "$OUT/usage" 2>/dev/null; rc=$?
  if [ $rc = 3 ]; then SKIP claude-usage "plan limits unavailable (Claude Code not logged in as coder, or no profile scope)"; return; fi
  if [ $rc = 0 ] && python3 -I -c 'import json,sys
d = json.load(sys.stdin); w = d.get("seven_day") or {}
sys.exit(0 if isinstance(w.get("utilization"), (int, float)) else 1)' < "$OUT/usage" 2>/dev/null; then
    PASS claude-usage; return
  fi
  FAIL claude-usage "no usable answer ($(exited $rc)); try: sudo -u coder claude-usage --fresh"
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

# 4. Timers are enabled, active and have a next run. While a timer's service is running, systemd shows
#    no next run until it finishes (e.g. claw-sync deploying the merge that prompted this install);
#    that means the timer just fired, so it counts as scheduled.
check_timers() {
  local t next state bad=
  for t in claw-sync.timer claw-backup.timer claw-denywatch.timer; do
    if ! systemctl is-enabled -q "$t" 2>/dev/null || ! systemctl is-active -q "$t" 2>/dev/null; then
      bad="${bad:+$bad; }$t isn't enabled and active"; continue
    fi
    next=$(systemctl list-timers --all --no-legend "$t" 2>/dev/null | awk 'NR == 1 { print $1 }')
    case "$next" in ''|-|n/a) ;; *) continue ;; esac
    state=$(systemctl show -p ActiveState --value "${t%.timer}.service" 2>/dev/null)
    case "$state" in activating|active|reloading) continue ;; esac
    bad="${bad:+$bad; }$t has no next run"
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

# 7. Plugins: everything OpenClaw has enabled is in plugins.allow, none comes from the workspace
#    extensions dir, none from ~/.openclaw/extensions but $GLOBAL_PLUGINS, and each root-owned plugin
#    is enabled from its root-owned dir. Reads OpenClaw's
#    plugin registry (`plugins list --json`), not the running gateway. Prints plugin ids only.
check_plugins() {
  local uid rc bad
  uid=$(id -u openclaw 2>/dev/null) || { FAIL plugins "no openclaw user"; return; }
  timeout "$WAIT" sudo -n -u openclaw env HOME="$OC_HOME" PATH="$OC_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="/run/user/$uid" openclaw plugins list --json --enabled > "$OUT/plugins" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] || { FAIL plugins "openclaw plugins list failed ($(exited $rc)); try: sudo -iu openclaw openclaw plugins list"; return; }
  # shellcheck disable=SC2024  # on purpose: openclaw reads its file, root writes its own temp copy
  sudo -n -u openclaw cat "$OC_HOME/.openclaw/openclaw.json" > "$OUT/cfg" 2>/dev/null || { FAIL plugins "can't read openclaw.json"; return; }
  bad=$(python3 -I - "$OUT/plugins" "$OUT/cfg" "$OC_PLUGINS" "$GLOBAL_PLUGINS" <<'PY'
import json, os, re, sys
def name(s):  # never echo odd text from the registry
    return s if isinstance(s, str) and re.fullmatch(r"[a-z0-9@._/-]{1,64}", s) else "<odd id>"
try:
    plugins = [p for p in json.load(open(sys.argv[1]))["plugins"] if p.get("enabled")]
    cfg = json.load(open(sys.argv[2])).get("plugins", {})
    allow = set(cfg.get("allow") or [])
    paths = [x for x in ((cfg.get("load") or {}).get("paths") or []) if isinstance(x, str)]
except Exception:
    print("unreadable plugins list or openclaw.json"); sys.exit()
out = []
if not allow:
    out.append("openclaw.json has no plugins.allow")
out += ["%s isn't in plugins.allow" % name(p.get("id")) for p in plugins if allow and p.get("id") not in allow]
# PluginOrigin in 2026.11.3 is "bundled" | "global" | "workspace" | "config"; anything else (a rename
# in a later version) fails rather than letting the two checks below pass without looking
out += ["%s has an unknown origin" % name(p.get("id")) for p in plugins if p.get("origin") not in ("bundled", "global", "workspace", "config")]
out += ["%s loads from the workspace" % name(p.get("id")) for p in plugins if p.get("origin") == "workspace"]
expected_global = set(sys.argv[4].split())
out += ["%s loads from ~/.openclaw/extensions" % name(p.get("id")) for p in plugins if p.get("origin") == "global" and p.get("id") not in expected_global]
root = sys.argv[3]
# every root-owned plugin: what's installed, plus what openclaw.json loads from under the root dir (so
# one claw-install never managed to install, e.g. no npm or a failed npm ci, is reported, not
# silently replaced by an older copy elsewhere)
installed = {d for d in os.listdir(root) if not d.endswith(".new")} if os.path.isdir(root) else set()
wanted = {x[len(root) + 1:].split("/")[0] for x in paths if x.startswith(root + "/")} - {""}
for d in sorted(wanted - installed):
    out.append("%s isn't installed in %s (sudo claw-install; check its output for npm errors)" % (name(d), root))
for d in sorted(installed):
    mine = [p for p in plugins if p.get("id") == d]
    if not any(str(p.get("rootDir") or "").startswith(os.path.join(root, d) + "/") or p.get("rootDir") == os.path.join(root, d) for p in mine):
        out.append("%s isn't enabled from %s" % (name(d), os.path.join(root, name(d))))
print("; ".join(out))
PY
)
  [ -z "$bad" ] || { FAIL plugins "$bad"; return; }
  PASS plugins
}

# 8. Tools: the deployed openclaw.json keeps the main agent off the shell (group:runtime and the
#    gateway tool denied, file tools limited to the workspace, no skill_workshop) and allows
#    every tool the installed claw-tools plugin declares (globally or for one agent). Reads config and manifest only.
check_tools() {
  local bad
  [ -f "$OC_PLUGINS/claw-tools/openclaw.plugin.json" ] || { SKIP tools "claw-tools isn't installed (sudo claw-install)"; return; }
  # shellcheck disable=SC2024  # on purpose: openclaw reads its file, root writes its own temp copy
  sudo -n -u openclaw cat "$OC_HOME/.openclaw/openclaw.json" > "$OUT/cfg" 2>/dev/null || { FAIL tools "can't read openclaw.json"; return; }
  bad=$(python3 -I - "$OUT/cfg" "$OC_PLUGINS/claw-tools/openclaw.plugin.json" <<'PY'
import json, re, sys
try:
    cfg = json.load(open(sys.argv[1]))
    tools = cfg.get("tools", {})
    agents = ((cfg.get("agents") or {}).get("entries") or {}).values()
    declared = json.load(open(sys.argv[2]))["contracts"]["tools"]
except Exception:
    print("unreadable openclaw.json or claw-tools manifest"); sys.exit()
out = []
deny = set(tools.get("deny") or [])
missing = [d for d in ("group:runtime", "gateway", "skill_workshop") if d not in deny]
if missing: out.append("not denied: " + ", ".join(missing))
if (tools.get("fs") or {}).get("workspaceOnly") is not True: out.append("tools.fs.workspaceOnly isn't true")
allowed = set(tools.get("alsoAllow") or []) | set(tools.get("allow") or [])
for a in agents:  # a tool only one agent needs (the reader's calendar_event_details) counts too
    t = (a or {}).get("tools") or {}
    allowed |= set(t.get("alsoAllow") or []) | set(t.get("allow") or [])
gone = [t for t in declared if isinstance(t, str) and re.fullmatch(r"[a-z0-9_]{1,64}", t) and t not in allowed]
if gone: out.append("claw-tools tools not allowed: " + ", ".join(gone))
print("; ".join(out))
PY
)
  [ -z "$bad" ] || { FAIL tools "$bad"; return; }
  PASS tools
}

check_acp
check_usage
check_git_token
# the refusal checks write DENY lines on purpose: record the window before they run (so a
# claw-denywatch run in the middle already sees it), ending when they must have finished (two calls
# of at most WAIT seconds each, plus slack)
smoke_start=$(date +%s)
mkdir -p "$(dirname "$SMOKE_WINDOWS")" && echo "$smoke_start $((smoke_start + 2 * WAIT + 30))" >> "$SMOKE_WINDOWS" \
  && tail -n 50 "$SMOKE_WINDOWS" > "$SMOKE_WINDOWS.new" && mv -f "$SMOKE_WINDOWS.new" "$SMOKE_WINDOWS"
check_git_refusals
check_timers
check_gateway
check_plugins
check_tools
check_cal

if [ "$fail" = 0 ]; then
  s=; [ "$skip" = 0 ] || s=" ($skip skipped)"
  echo "claw-smoke: all $pass checks passed$s"
else
  echo "claw-smoke: $fail of $((pass + fail)) checks FAILED"
  exit 1
fi
