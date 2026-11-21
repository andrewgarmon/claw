#!/usr/bin/env bash
# Tests for .github/scripts/config-invariants.py: the real openclaw.json passes, and breaking any one
# security setting fails with a line naming it. Needs jq and python3. Touches nothing outside a temp dir.
# Usage: bash infra/tests/config-invariants.test.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S="$REPO/.github/scripts/config-invariants.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

out=$(python3 -I "$S" "$REPO/openclaw.json"); rc=$?
[ $rc = 0 ] && ok "the real openclaw.json passes" || { bad "the real openclaw.json fails:"; echo "$out"; }

# breaks <jq filter> <text the failure line must contain>
breaks() {
  jq "$1" "$REPO/openclaw.json" > "$T/cfg.json" || { bad "jq filter didn't apply: $1"; return; }
  out=$(python3 -I "$S" "$T/cfg.json"); rc=$?
  if [ $rc = 1 ] && grep -qF -- "$2" <<<"$out"; then ok "fails: $2"; else bad "didn't fail with '$2' for: $1 (rc=$rc: $out)"; fi
}

for t in group:runtime gateway cron skill_workshop plugins secrets conversations_send conversations_turn conversations_list; do
  breaks ".tools.deny -= [\"$t\"]" "tools.deny is missing $t"
done
breaks '.tools.fs.workspaceOnly = false' "tools.fs.workspaceOnly isn't true"
breaks 'del(.tools.fs)' "tools.fs.workspaceOnly isn't true"
breaks '.channels.telegram.dmPolicy = "open"' "dmPolicy isn't allowlist"
breaks '.channels.telegram.groupPolicy = "open"' "groupPolicy isn't allowlist"
breaks '.channels.telegram.allowFrom += ["*"]' "allowFrom isn't only the owner"
breaks '.commands.ownerAllowFrom += ["telegram:42"]' "ownerAllowFrom isn't only the owner"
breaks '.gateway.bind = "lan"' "gateway.bind isn't loopback"
breaks '.gateway.auth.mode = "none"' "gateway.auth.mode isn't token"
breaks '.skills.workshop.autonomous.mode = "auto"' "autonomous.mode isn't off"
breaks '.skills.allowBundled = ["canvas"]' "allowBundled isn't empty"
breaks 'del(.skills.allowBundled)' "allowBundled isn't empty"
breaks '.agents.defaults.heartbeat.every = "30m"' "heartbeat.every isn't 0m"
breaks '.plugins.load.paths += ["/home/openclaw/.openclaw/extensions/x"]' "plugins.load.paths has a path outside"
breaks '.plugins.load.paths += ["/usr/local/lib/claw/openclaw-plugins/../../../../home/x"]' "plugins.load.paths has a path outside"
breaks '.plugins.load.paths -= ["/usr/local/lib/claw/openclaw-plugins/claw-tools"]' "doesn't load claw-tools"
breaks '.plugins.allow -= ["claw-tools"]' "plugins.allow is missing claw-tools"
breaks '.plugins.entries.google.hooks.allowPromptInjection = true' "plugins.entries.google.hooks.allowPromptInjection isn't false"
for p in claw-tools duckduckgo acpx; do
  breaks ".plugins.entries[\"$p\"].hooks.allowPromptInjection = true" "plugins.entries.$p.hooks.allowPromptInjection isn't false"
  breaks "del(.plugins.entries[\"$p\"].hooks)" "plugins.entries.$p.hooks.allowPromptInjection isn't set to false"
done
breaks '.plugins.entries["claw-tools"].enabled = false' "claw-tools isn't enabled"
breaks '.plugins.entries["claw-tools"].config.ownerTelegramId = "42"' "ownerTelegramId isn't the owner"
breaks '.approvals.plugin.enabled = false' "approvals.plugin isn't enabled"
breaks '.approvals.plugin.mode = "session"' "approvals.plugin.mode isn't targets"
breaks '.approvals.plugin.targets += [{"channel":"telegram","to":"42"}]' "targets isn't only the owner's DM"
breaks '.acp.allowedAgents += ["codex"]' "acp.allowedAgents isn't only claude"
breaks '.acp.defaultAgent = "codex"' "acp.defaultAgent isn't claude"
breaks '.plugins.entries.acpx.config.agents.claude.args = ["-n","-u","openclaw","/bin/bash"]' "acpx's agents aren't only claude via coder-acp"
breaks '.plugins.entries.acpx.config.agents.codex = {"command":"codex"}' "acpx's agents aren't only claude via coder-acp"
for t in web_search web_fetch calendar_event_details github_issue_view; do
  breaks ".agents.entries.main.tools.deny -= [\"$t\"]" "agents.entries.main.tools.deny is missing $t"
done
breaks '.agents.entries.main.tools.profile = "full"' "main.tools.profile is set"
breaks '.agents.entries.helper = {"name":"helper"}' "agents.entries.helper isn't a known agent"
for t in group:runtime group:fs message sessions_send calendar_create github_issue_comment claude_usage; do
  breaks ".agents.entries.reader.tools.deny -= [\"$t\"]" "agents.entries.reader.tools.deny is missing $t"
done
breaks '.agents.entries.reader.tools.profile = "coding"' "reader.tools.profile isn't minimal"
breaks '.agents.entries.reader.tools.agentToAgent.send = ["main"]' "reader can send to other agents"
breaks '.agents.entries.main.tools.agentToAgent.send += ["helper"]' "main can send to agents other than the reader"

echo '[1,2]' > "$T/arr.json"
out=$(python3 -I "$S" "$T/arr.json"); rc=$?
[ $rc = 1 ] && grep -q "isn't a JSON object" <<<"$out" && ok "a non-object config fails" || bad "a non-object config: rc=$rc $out"
out=$(python3 -I "$S" "$T/missing.json"); rc=$?
[ $rc = 1 ] && grep -q "missing or isn't valid JSON" <<<"$out" && ok "a missing config fails" || bad "a missing config: rc=$rc $out"

# never prints values: the owner placeholder and the gateway token reference stay out of the output
jq '.channels.telegram.allowFrom = ["555123"] | .gateway.auth.mode = "password"' "$REPO/openclaw.json" > "$T/cfg.json"
out=$(python3 -I "$S" "$T/cfg.json")
grep -q 555123 <<<"$out" && bad "a value was printed" || ok "prints setting names only"

echo; [ $fails = 0 ] && echo "all config-invariants tests passed" || { echo "$fails failed"; exit 1; }
