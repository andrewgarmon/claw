#!/usr/bin/env bash
# Static checks on openclaw.json's agents: the main agent and the read-only reader that untrusted
# content (web, calendar locations and notes, issues) goes through. Needs jq.
# Usage: bash infra/tests/agents-config.test.sh
set -uo pipefail
CFG=$(cd "$(dirname "$0")/../.." && pwd)/openclaw.json
fails=0
check() { if jq -e "$2" "$CFG" >/dev/null; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
R='.agents.entries.reader'
M='.agents.entries.main'

check "two agents, explicit ownership, main is the system agent and heartbeat owner" \
  '(.agents.entries | keys) == ["main","reader"] and .agents.ownership == "explicit" and .agents.defaults.systemAgent.agentId == "main" and .agents.defaults.heartbeat.agentId == "main"'
check "Telegram routes to main (all accounts), and nothing routes to the reader" \
  '.bindings == [{"agentId":"main","match":{"channel":"telegram","accountId":"*"}}]'
check "agentToAgent.allow is exactly main and reader (send lists: .github/scripts/config-invariants.py)" \
  '.tools.agentToAgent.enabled == true and (.tools.agentToAgent.allow | sort) == ["main","reader"]'
check "session visibility narrowed to the agent (the reader can't read main's history)" '.tools.sessions.visibility == "agent"'
check "reader: minimal profile, its own workspace, no skills, can't spawn" \
  "$R"'.tools.profile == "minimal" and '"$R"'.workspace != .agents.defaults.workspace and '"$R"'.skills == [] and '"$R"'.subagents.allowAgents == []'
check "reader: only read tools are added" \
  '('"$R"'.tools.alsoAllow | sort) == (["web_search","web_fetch","calendar_list_calendars","calendar_events","calendar_event_details","github_issue_list","github_issue_view"] | sort)'
check "reader: a cheaper model, low thinking, no fallback" \
  '(.agents.entries.reader.model.primary | test("flash")) and .agents.entries.reader.thinkingDefault == "low" and .agents.entries.reader.model.fallbacks == []'
check "main keeps the global profile (no per-agent profile to widen it)" "($M.tools.profile // null) == null"
check "plugin approvals are for main only" '.approvals.plugin.agentFilter == ["main"]'
check "no automatic creation of bootstrap files (none for the reader to follow)" '.agents.defaults.skipBootstrap == true'

echo; [ $fails = 0 ] && echo "all agents-config tests passed" || { echo "$fails failed"; exit 1; }
