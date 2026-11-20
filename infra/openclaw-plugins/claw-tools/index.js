// claw-tools: the main agent's typed tools for the brokers (calendar, GitHub issues, Claude usage).
// Installed root-owned to /usr/local/lib/claw/openclaw-plugins/claw-tools by claw-install and loaded
// through plugins.load.paths. The logic and schemas are in tools.js; this file registers them.
import { spawn } from "node:child_process";
import { Type } from "typebox";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { wrapExternalContent } from "openclaw/plugin-sdk/security-runtime";
import { TOOLS, callTool } from "./tools.js";

const text = (t) => [{ type: "text", text: t }];

export default definePluginEntry({
  id: "claw-tools",
  name: "claw tools",
  description: "Typed tools for the calendar and GitHub brokers and Claude usage.",
  register(api) {
    for (const tool of TOOLS) {
      api.registerTool({
        name: tool.name,
        label: tool.label,
        description: tool.description,
        parameters: Type.Unsafe(tool.parameters),
        async execute(_toolCallId, params, signal) {
          const r = await callTool(tool, params, { spawn, signal });
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
