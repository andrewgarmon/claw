#!/usr/bin/env python3
"""Security settings openclaw.json must keep. CI runs the base branch's copy on PRs, so a PR can't
loosen a setting and this check at once: change it here first, merge, then change the config.
usage: python3 -I .github/scripts/config-invariants.py [openclaw.json]   (prints setting names only)
"""
import json
import sys

OWNER = "${TELEGRAM_ALLOW_FROM}"
WRITES = ["calendar_create", "calendar_update", "calendar_delete", "calendar_undo", "github_issue_create",
          "github_issue_comment", "github_issue_label", "github_issue_close", "github_issue_reopen"]
EQUAL = {
    "tools.fs.workspaceOnly": True,
    "channels.telegram.dmPolicy": "allowlist",
    "channels.telegram.groupPolicy": "allowlist",
    "channels.telegram.allowFrom": [OWNER],
    "skills.workshop.autonomous.mode": "off",
    "skills.allowBundled": [],
    "agents.defaults.heartbeat.every": "0m",
    "update.checkOnStart": False,   # the OpenClaw version comes from infra/openclaw/package.json
    "update.auto.enabled": False,
    "acp.allowedAgents": ["claude"],
    "acp.defaultAgent": "claude",
    "plugins.entries.acpx.config.agents": {"claude": {"command": "sudo", "args": ["-n", "-u", "coder", "/usr/local/bin/coder-acp"]}},
    "agents.entries.main.tools.agentToAgent.send": ["reader"],
    "agents.entries.reader.tools.agentToAgent.send": [],
}
CONTAINS = {
    "tools.deny": ["group:runtime", "gateway", "cron", "skill_workshop", "plugins", "secrets",
                   "conversations_list", "conversations_send", "conversations_turn"],
    "agents.entries.main.tools.deny": ["web_search", "web_fetch", "calendar_event_details", "github_issue_view"],
    "agents.entries.reader.tools.deny": ["group:fs", "group:runtime", "group:memory", "group:sessions", "message",
                                         "cron", "gateway", "skill_workshop", "sessions_spawn", "sessions_send",
                                         "claude_usage"] + WRITES,
}
MISSING = object()


def get(d, path):
    for k in path.split("."):
        if not isinstance(d, dict) or k not in d:
            return MISSING
        d = d[k]
    return d


def check(cfg):
    bad = [p for p, want in EQUAL.items() if get(cfg, p) != want]
    for p, items in CONTAINS.items():
        have = get(cfg, p)
        bad += [f"{p} is missing {t}" for t in items if not isinstance(have, list) or t not in have]
    entries = get(cfg, "plugins.entries")
    for name in entries if isinstance(entries, dict) else ["*"]:
        if get(cfg, f"plugins.entries.{name}.hooks.allowPromptInjection") not in (False, MISSING):
            bad.append(f"plugins.entries.{name}.hooks.allowPromptInjection")
    for name in ["claw-tools", "duckduckgo", "acpx"]:   # the plugins with hooks say so explicitly
        if get(cfg, f"plugins.entries.{name}.hooks.allowPromptInjection") is not False:
            bad.append(f"plugins.entries.{name}.hooks.allowPromptInjection")
    return sorted(set(bad))


if __name__ == "__main__":
    try:
        cfg = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "openclaw.json"))
    except (OSError, ValueError):
        sys.exit("FAIL openclaw.json is missing or isn't valid JSON")
    bad = check(cfg) if isinstance(cfg, dict) else ["openclaw.json isn't an object"]
    for b in bad:
        print("FAIL", b)
    print("ok" if not bad else f"{len(bad)} security setting(s) changed")
    sys.exit(1 if bad else 0)
