// Tests that infra/openclaw-plugins/claw-tools/index.js wires approvals.js and tools.js up, run by
// infra/tests/claw-tools.test.sh. index.js is loaded from a temp copy of the plugin against a fake
// openclaw/plugin-sdk and typebox, and its node:child_process is pointed at the fake sudo, so each
// registered tool really runs (through callTool) without a broker. A fake `api` records every hook and
// tool; hooks are dispatched the way the gateway does it, by matcher and priority, so a tool missing
// from a matcher counts as ungated.
import { test, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { register } from "node:module";
import { pathToFileURL } from "node:url";
import { GATED, APPROVAL_TIMEOUT_MS } from "../../openclaw-plugins/claw-tools/approvals.js";
import { TOOLS } from "../../openclaw-plugins/claw-tools/tools.js";

const REPO = process.env.REPO;
const SRC = path.join(REPO, "infra/openclaw-plugins/claw-tools");
// own scratch dir: node runs test files in parallel and tools.test.mjs uses $T's out/argv files
const T = path.join(process.env.T, "index");
const P = path.join(T, "plugin");
const WRAP = "<<EXTERNAL>>";
const OWNER = "123456789";

const write = (rel, content) => { fs.mkdirSync(path.dirname(path.join(P, rel)), { recursive: true }); fs.writeFileSync(path.join(P, rel), content); };

function setup() {
  fs.mkdirSync(P, { recursive: true });
  for (const f of ["index.js", "tools.js", "approvals.js", "package.json", "openclaw.plugin.json"]) fs.copyFileSync(path.join(SRC, f), path.join(P, f));
  write("node_modules/openclaw/package.json", JSON.stringify({ name: "openclaw", type: "module",
    exports: { "./plugin-sdk/plugin-entry": "./plugin-entry.js", "./plugin-sdk/security-runtime": "./security-runtime.js" } }));
  write("node_modules/openclaw/plugin-entry.js", "export const definePluginEntry = (e) => e;\n");
  write("node_modules/openclaw/security-runtime.js",
    `export const wrapExternalContent = (t, o) => ${JSON.stringify(WRAP)} + JSON.stringify(o) + "\\n" + t;\n`);
  write("node_modules/typebox/package.json", JSON.stringify({ name: "typebox", type: "module", exports: "./index.js" }));
  write("node_modules/typebox/index.js", "export const Type = { Unsafe: (s) => s };\n");
  // index.js's spawn runs the fake sudo (scratch dir T); every other importer gets the real module
  write("fake-child.mjs", `import { spawn as real } from "node:child_process";
export const spawn = (cmd, args, opts) => real(${JSON.stringify(process.env.FAKE_SUDO)}, args, { ...opts, env: { ...opts.env, T: ${JSON.stringify(T)} } });
`);
  write("hooks.mjs", `const INDEX = ${JSON.stringify(pathToFileURL(path.join(P, "index.js")).href)};
const FAKE = ${JSON.stringify(pathToFileURL(path.join(P, "fake-child.mjs")).href)};
export async function resolve(spec, ctx, next) {
  if (spec === "node:child_process" && ctx.parentURL === INDEX) return { url: FAKE, shortCircuit: true };
  return next(spec, ctx);
}
`);
  register(pathToFileURL(path.join(P, "hooks.mjs")).href);
}

async function load(pluginConfig) {
  const hooks = [], tools = [], logs = [];
  const api = {
    pluginConfig,
    logger: { info: (m) => logs.push(m) },
    on: (name, handler, opts) => hooks.push({ name, handler, opts: opts ?? {} }),
    registerTool: (t) => tools.push(t),
  };
  const mod = await import(pathToFileURL(path.join(P, "index.js")).href);
  mod.default.register(api);
  // every before_tool_call hook whose matcher names the tool, highest priority first, until one blocks
  const dispatch = async (toolName, params) => {
    const results = [];
    const hit = hooks.filter((h) => h.name === "before_tool_call" && (!h.opts.matcher || h.opts.matcher.includes(toolName)))
      .sort((a, b) => (b.opts.priority ?? 0) - (a.opts.priority ?? 0));
    for (const h of hit) {
      const r = await h.handler({ toolName, params });
      if (r !== undefined) results.push(r);
      if (r?.block) break;
    }
    return results;
  };
  const approval = async (name, params) => (await dispatch(name, params)).find((r) => r.requireApproval)?.requireApproval;
  return { hooks, tools, logs, dispatch, approval, mod };
}

// valid arguments per tool (each must pass validation so execute really runs)
const sample = {
  calendar_list_calendars: {},
  calendar_events: { days: 2 },
  calendar_event_details: { days: 2 },
  calendar_create: { calendar: "Home", title: "Dentist", start: "2026-11-18T15:00", end: "2026-11-18T16:00" },
  calendar_update: { id: "0123456789", location: "" },
  calendar_delete: { id: "0123456789" },
  calendar_undo: {},
  calendar_changes: {},
  github_issue_list: { repo: "claw" },
  github_issue_view: { repo: "claw", number: 7 },
  github_issue_create: { repo: "claw", title: "Fix x", body: "Done when: y" },
  github_issue_comment: { repo: "claw", number: 7, body: "Looks good" },
  github_issue_label: { repo: "claw", number: 7, action: "add", label: "bug" },
  github_issue_close: { repo: "claw", number: 7, comment: "Fixed in #8" },
  github_issue_reopen: { repo: "claw", number: 7 },
  claude_usage: {},
  sessions_spawn: { runtime: "acp", agentId: "claude", cwd: "/srv/work/claw", task: "Fix the flaky test" },
  sessions_send: { sessionKey: "agent:main:acp:abc", message: "Also change install.sh" },
};

before(setup);

test("every gated tool asks for approval through the hook: allow-once and deny only, 10 minutes", async () => {
  const { approval } = await load({ ownerTelegramId: OWNER });
  for (const name of GATED) {
    const req = await approval(name, sample[name]);
    assert.ok(req, `${name}: no approval (missing from the matcher, or the hook returned nothing)`);
    assert.deepEqual(req.allowedDecisions, ["allow-once", "deny"], name);
    assert.equal(req.timeoutMs, APPROVAL_TIMEOUT_MS, name);
    assert.equal(APPROVAL_TIMEOUT_MS, 600_000);
    assert.equal(typeof req.onResolution, "function", name);
  }
});

test("no non-gated tool asks for approval", async () => {
  const { approval } = await load({ ownerTelegramId: OWNER });
  for (const t of TOOLS.filter((x) => !GATED.includes(x.name))) assert.equal(await approval(t.name, sample[t.name]), undefined, t.name);
  for (const name of ["web_fetch", "web_search", "read", "write", "memory_search", "message"]) assert.equal(await approval(name, {}), undefined, name);
});

test("a decision is logged with the tool and a hash of the parameters", async () => {
  const { approval, logs } = await load({ ownerTelegramId: OWNER });
  (await approval("calendar_delete", { id: "0123456789" })).onResolution("allow-once");
  assert.match(logs.at(-1), /^claw-tools approval allow-once: calendar_delete [0-9a-f]{12}$/);
});

test("sessions_spawn passes only as an explicit OpenClaw subagent; every other spawn is gated", async () => {
  const { approval } = await load({ ownerTelegramId: OWNER });
  assert.equal(await approval("sessions_spawn", { runtime: "subagent", task: "summarise" }), undefined);
  for (const p of [{ runtime: "acp", task: "x" }, { task: "x" }, { runtime: "Subagent ", task: "x" }, { runtime: "other", agentId: "claude", task: "x" }]) {
    assert.ok(await approval("sessions_spawn", p), JSON.stringify(p));
  }
});

test("message: blocked to anyone but the owner; replies in the current chat pass", async () => {
  const { dispatch } = await load({ ownerTelegramId: OWNER });
  const blocked = async (p) => (await dispatch("message", p)).some((r) => r.block === true && typeof r.blockReason === "string");
  assert.equal(await blocked({ text: "hi" }), false);
  assert.equal(await blocked({ text: "hi", target: OWNER }), false);
  assert.equal(await blocked({ text: "hi", target: "987654321" }), true);
  assert.equal(await blocked({ text: "hi", channel: "discord" }), true);
  assert.equal(await blocked({ action: "broadcast", text: "hi" }), true);
});

test("message: with no ownerTelegramId configured, every explicit target is blocked", async () => {
  for (const cfg of [undefined, {}, { ownerTelegramId: "" }]) {
    const { dispatch } = await load(cfg);
    const r = await dispatch("message", { text: "hi", target: OWNER });
    assert.ok(r.some((x) => x.block === true), JSON.stringify(cfg));
    assert.deepEqual(await dispatch("message", { text: "hi" }), [], JSON.stringify(cfg));
  }
});

test("web_fetch is only logged, host only", async () => {
  const { dispatch, logs } = await load({ ownerTelegramId: OWNER });
  assert.deepEqual(await dispatch("web_fetch", { url: "https://example.com/secret?q=1" }), []);
  assert.equal(logs.at(-1), "claw-tools web_fetch host=example.com");
});

test("every tool in TOOLS is registered once, and the manifest lists exactly those", async () => {
  const { tools } = await load({ ownerTelegramId: OWNER });
  const names = tools.map((t) => t.name);
  assert.deepEqual([...names].sort(), TOOLS.map((t) => t.name).sort());
  assert.equal(new Set(names).size, names.length, "a tool registered twice");
  const manifest = JSON.parse(fs.readFileSync(path.join(SRC, "openclaw.plugin.json"), "utf8"));
  assert.deepEqual([...manifest.contracts.tools].sort(), [...names].sort());
  for (const t of tools) assert.deepEqual(t.parameters, TOOLS.find((x) => x.name === t.name).parameters, t.name);
});

test("every untrusted tool's result is wrapped as external content; the rest aren't", async () => {
  const { tools } = await load({ ownerTelegramId: OWNER });
  fs.writeFileSync(path.join(T, "out"), '"broker says hi"');
  for (const t of tools) {
    const def = TOOLS.find((x) => x.name === t.name);
    const r = await t.execute("call-1", sample[t.name], undefined);
    assert.equal(r.details.ok, true, `${t.name}: ${r.details.error}`);
    const out = r.content[0].text;
    if (def.untrusted) {
      assert.ok(out.startsWith(WRAP), `${t.name} isn't wrapped`);
      assert.ok(out.includes(`"taskName":"${t.name}"`), t.name);
    } else {
      assert.ok(!out.includes(WRAP), `${t.name} is wrapped but isn't untrusted`);
    }
  }
});

test("a failed broker call reports the error and isn't wrapped", async () => {
  const { tools } = await load({ ownerTelegramId: OWNER });
  fs.writeFileSync(path.join(T, "rc"), "3");
  fs.writeFileSync(path.join(T, "err"), "calendar unreachable\n");
  try {
    const r = await tools.find((t) => t.name === "calendar_events").execute("call-2", {}, undefined);
    assert.equal(r.details.ok, false);
    assert.equal(r.content[0].text, "calendar_events failed: calendar unreachable");
  } finally {
    for (const f of ["rc", "err"]) fs.rmSync(path.join(T, f), { force: true });
  }
});
