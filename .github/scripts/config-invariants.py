#!/usr/bin/env python3
"""Security settings openclaw.json must keep. CI runs the base branch's copy of this script on PRs, so
a PR can't loosen a setting and the check that guards it at once: change an invariant here first, merge,
then change the config.

usage: python3 -I .github/scripts/config-invariants.py [openclaw.json]
Prints one line per broken setting (names only, never values) and exits 1 if any; else prints "ok".
"""
import json
import sys

ALLOW_FROM = "${TELEGRAM_ALLOW_FROM}"
CORE_DENY = ["group:runtime", "gateway", "cron", "skill_workshop", "plugins", "secrets",
             "conversations_list", "conversations_send", "conversations_turn"]
# claw-tools writes: the reader must never get one (a new write tool is added here first)
WRITES = ["calendar_create", "calendar_update", "calendar_delete", "calendar_undo",
          "github_issue_create", "github_issue_comment", "github_issue_label", "github_issue_close",
          "github_issue_reopen"]
READER_DENY = ["group:runtime", "group:fs", "group:sessions", "gateway", "message", "cron",
               "skill_workshop", "sessions_spawn", "sessions_send"] + WRITES + ["claude_usage"]
MAIN_DENY = ["web_search", "web_fetch", "calendar_event_details", "github_issue_view"]
PLUGIN_ROOT = "/usr/local/lib/claw/openclaw-plugins/"
HOOKED_PLUGINS = ["claw-tools", "duckduckgo", "acpx"]
CODER_ACP = {"command": "sudo", "args": ["-n", "-u", "coder", "/usr/local/bin/coder-acp"]}


def get(d, path, default=None):
    for k in path.split("."):
        if not isinstance(d, dict) or k not in d:
            return default
        d = d[k]
    return d


def check(cfg):
    out = []

    def need(ok, name):
        if not ok:
            out.append(name)

    def as_list(v):
        return v if isinstance(v, list) else []

    # main agent's tools (global)
    deny = as_list(get(cfg, "tools.deny"))
    for t in CORE_DENY:
        need(t in deny, f"tools.deny is missing {t}")
    need(get(cfg, "tools.fs.workspaceOnly") is True, "tools.fs.workspaceOnly isn't true")

    # who can talk to it
    tg = get(cfg, "channels.telegram", {})
    need(get(tg, "dmPolicy") == "allowlist", "channels.telegram.dmPolicy isn't allowlist")
    need(get(tg, "groupPolicy") == "allowlist", "channels.telegram.groupPolicy isn't allowlist")
    need(get(tg, "allowFrom") == [ALLOW_FROM], "channels.telegram.allowFrom isn't only the owner")
    need(get(cfg, "commands.ownerAllowFrom") == ["telegram:" + ALLOW_FROM], "commands.ownerAllowFrom isn't only the owner")
    need(get(cfg, "gateway.bind") == "loopback", "gateway.bind isn't loopback")
    need(get(cfg, "gateway.auth.mode") == "token", "gateway.auth.mode isn't token")

    # no self-made skills or jobs
    need(get(cfg, "skills.workshop.autonomous.mode") == "off", "skills.workshop.autonomous.mode isn't off")
    need(get(cfg, "skills.allowBundled") == [], "skills.allowBundled isn't empty")
    need(get(cfg, "agents.defaults.heartbeat.every") == "0m", "agents.defaults.heartbeat.every isn't 0m")

    # plugins: loaded only from the root-owned dir; no plugin may inject prompts
    paths = as_list(get(cfg, "plugins.load.paths"))
    need(all(isinstance(p, str) and p.startswith(PLUGIN_ROOT) and ".." not in p for p in paths),
         "plugins.load.paths has a path outside " + PLUGIN_ROOT)
    need(PLUGIN_ROOT + "claw-tools" in paths, "plugins.load.paths doesn't load claw-tools")
    need("claw-tools" in as_list(get(cfg, "plugins.allow")), "plugins.allow is missing claw-tools")
    entries = get(cfg, "plugins.entries", {})
    entries = entries if isinstance(entries, dict) else {}
    for name, e in entries.items():
        v = get(e, "hooks.allowPromptInjection", False)
        need(v is False, f"plugins.entries.{name}.hooks.allowPromptInjection isn't false")
    for name in HOOKED_PLUGINS:
        need(get(entries, f"{name}.hooks.allowPromptInjection", None) is False,
             f"plugins.entries.{name}.hooks.allowPromptInjection isn't set to false")
    need(get(entries, "claw-tools.enabled") is True, "plugins.entries.claw-tools isn't enabled")
    need(get(entries, "claw-tools.config.ownerTelegramId") == ALLOW_FROM,
         "plugins.entries.claw-tools.config.ownerTelegramId isn't the owner")

    # approvals reach the owner only
    ap = get(cfg, "approvals.plugin", {})
    need(get(ap, "enabled") is True, "approvals.plugin isn't enabled")
    need(get(ap, "mode") == "targets", "approvals.plugin.mode isn't targets")
    need(get(ap, "targets") == [{"channel": "telegram", "to": ALLOW_FROM}], "approvals.plugin.targets isn't only the owner's DM")

    # Claude Code hand-offs only to claude, run as coder through coder-acp
    need(get(cfg, "acp.allowedAgents") == ["claude"], "acp.allowedAgents isn't only claude")
    need(get(cfg, "acp.defaultAgent") == "claude", "acp.defaultAgent isn't claude")
    need(get(entries, "acpx.config.agents") == {"claude": CODER_ACP}, "acpx's agents aren't only claude via coder-acp")

    # agents: main delegates untrusted reading to the reader, which can't write or act
    agents = get(cfg, "agents.entries", {})
    agents = agents if isinstance(agents, dict) else {}
    main, reader = agents.get("main", {}), agents.get("reader")
    mdeny = as_list(get(main, "tools.deny"))
    for t in MAIN_DENY:
        need(t in mdeny, f"agents.entries.main.tools.deny is missing {t}")
    need(get(main, "tools.profile") is None, "agents.entries.main.tools.profile is set (it would replace the global one)")
    for name, a in agents.items():
        if name not in ("main", "reader"):
            out.append(f"agents.entries.{name} isn't a known agent")
    if reader is not None:
        rdeny = as_list(get(reader, "tools.deny"))
        for t in READER_DENY:
            need(t in rdeny, f"agents.entries.reader.tools.deny is missing {t}")
        need(get(reader, "tools.profile") == "minimal", "agents.entries.reader.tools.profile isn't minimal")
        need(get(reader, "tools.agentToAgent.send") == [], "agents.entries.reader can send to other agents")
        need(get(main, "tools.agentToAgent.send") == ["reader"], "agents.entries.main can send to agents other than the reader")
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openclaw.json"
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        print(f"FAIL {path} is missing or isn't valid JSON")
        return 1
    if not isinstance(cfg, dict):
        print(f"FAIL {path} isn't a JSON object")
        return 1
    bad = check(cfg)
    for b in bad:
        print(f"FAIL {b}")
    if not bad:
        print("ok: openclaw.json keeps its security settings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
