// claw-tools: the main agent's typed tools for the brokers (calendar, GitHub issues, Claude usage),
// and the approval gate in front of the ones that write (see approvals.js).
// Installed root-owned to /usr/local/lib/claw/openclaw-plugins/claw-tools by claw-install and loaded
// through plugins.load.paths. The logic and schemas are in tools.js and approvals.js; this file
// registers them.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { Type } from "typebox";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { wrapExternalContent } from "openclaw/plugin-sdk/security-runtime";
import { TOOLS, callTool } from "./tools.js";
import { GATED, EventCache, approvalFor, messageBlock, fetchHost } from "./approvals.js";

const text = (t) => [{ type: "text", text: t }];

export default definePluginEntry({
  id: "claw-tools",
  name: "claw tools",
  description: "Typed tools for the calendar and GitHub brokers and Claude usage.",
  register(api) {
    const events = new EventCache();
    const log = (m) => { try { api.logger?.info?.(m); } catch { /* logging never breaks a call */ } };
    const digest = (v) => createHash("sha256").update(JSON.stringify(v ?? {})).digest("hex").slice(0, 12);

    // Writes and Claude Code hand-offs wait for the owner's Approve tap. The card is built from the
    // call's parameters; OpenClaw freezes those parameters for the approved call.
    api.on("before_tool_call", (event) => {
      const req = approvalFor(event.toolName, event.params, events);
      if (!req) return undefined;
      const tag = `${event.toolName} ${digest(event.params)}`;
      return { requireApproval: { ...req, onResolution: (decision) => log(`claw-tools approval ${decision}: ${tag}`) } };
    }, { matcher: GATED, priority: 50 });

    // Sends to anyone but the owner's DM have no legitimate use here: blocked, no approval path.
    api.on("before_tool_call", (event) => {
      const why = messageBlock(event.params, process.env.TELEGRAM_ALLOW_FROM);
      if (!why) return undefined;
      log(`claw-tools blocked message ${digest(event.params)}: ${why}`);
      return { block: true, blockReason: why };
    }, { matcher: ["message"], priority: 60 });

    // web_fetch is logged (host only) to see what it's used for before deciding whether to gate it.
    api.on("before_tool_call", (event) => { log(`claw-tools web_fetch host=${fetchHost(event.params)}`); return undefined; },
      { matcher: ["web_fetch"], priority: 10 });

    for (const tool of TOOLS) {
      api.registerTool({
        name: tool.name,
        label: tool.label,
        description: tool.description,
        parameters: Type.Unsafe(tool.parameters),
        async execute(_toolCallId, params, signal) {
          const r = await callTool(tool, params, { spawn, signal });
          if (r.ok && tool.name === "calendar_events") events.remember(r.data);
          if (!r.ok) return { content: text(`${tool.name} failed: ${r.error}`), details: { ok: false, error: r.error } };
          let out = typeof r.data === "string" ? r.data : JSON.stringify(r.data, null, 2);
          if (r.truncated) out += "\n[output cut at the size limit]";
          // calendar and issue text can come from anyone: label it as untrusted, like web_fetch does
          if (tool.untrusted) out = wrapExternalContent(out, { source: "api", taskName: tool.name });
          return { content: text(out), details: { ok: true, result: r.data, truncated: r.truncated } };
        },
      });
    }
  },
});
