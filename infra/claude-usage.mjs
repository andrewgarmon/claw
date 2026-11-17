// claude-usage.mjs: print the Claude plan's usage windows as one line of JSON. Run by infra/claude-usage
// (as coder); installed root-owned to /usr/local/lib/claw/claude-usage.mjs.
//
// Uses the Agent SDK's structured get_usage request (the data behind Claude Code's /usage) from the
// root-owned, lockfile-pinned ACP install. The query gets streaming input that never sends a prompt,
// so no model call is made. The API is marked experimental: it only changes when the ACP lockfile is
// bumped, and claw-smoke's claude-usage check fails if a bump breaks it.
//
// Exit codes: 0 JSON printed; 3 plan limits unavailable (not logged in, API key, or a login without
// the profile scope); 1 anything else. Errors are one line on stderr. Only the selected fields are
// printed, never the raw response.
const SDK = "/usr/local/lib/claw/acp/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs";
const METHOD = "usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET";

let q = null;
let release = () => {};
class Done extends Error {}
// done: report, then close the query (which stops the Claude Code child) and let Node exit on its own
// once the child is gone. process.exit() here would return before the child has finished exiting.
function done(code, line, stream = process.stderr) {
  stream.write(line + "\n");
  process.exitCode = code;
  release();
  try { q?.close(); } catch { /* already closed */ }
  throw new Done();
}
const short = (e) => String(e?.message ?? e).split("\n")[0].slice(0, 200);
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v, n = 40) => (typeof v === "string" ? v.slice(0, n) : null);
const win = (w) => (w && typeof w === "object" ? { utilization: num(w.utilization), resets_at: str(w.resets_at) } : null);

try {
  let sdk;
  try { sdk = await import(SDK); } catch (e) { done(1, `claude-usage: can't load the Agent SDK from the ACP install (${short(e)}); run: sudo claw-install`); }

  const idle = new Promise((r) => { release = r; });
  async function* noPrompt() { await idle; }   // keeps the session open without ever sending a message
  try { q = sdk.query({ prompt: noPrompt(), options: { settingSources: [] } }); }
  catch (e) { done(1, `claude-usage: couldn't start Claude Code (${short(e)})`); }
  if (typeof q[METHOD] !== "function") done(1, "claude-usage: this Agent SDK has no usage request (renamed after an ACP bump?)");

  let u;
  try { u = await q[METHOD]({ skipBehaviors: true }); }
  catch (e) { done(1, `claude-usage: usage request failed (${short(e)})`); }

  const rl = u?.rate_limits;
  if (!u?.rate_limits_available || !rl || typeof rl !== "object") {
    done(3, "claude-usage: plan limits unavailable (not logged in, an API key, or a login without the profile scope)");
  }
  const out = {
    subscription_type: str(u.subscription_type, 20),
    five_hour: win(rl.five_hour),
    seven_day: win(rl.seven_day),
  };
  for (const k of ["seven_day_opus", "seven_day_sonnet"]) if (rl[k]) out[k] = win(rl[k]);
  if (Array.isArray(rl.model_scoped)) out.model_scoped = rl.model_scoped.slice(0, 10).map((m) => ({ name: str(m?.display_name), ...win(m) }));
  out.fetched_at = new Date().toISOString();
  if (!out.five_hour && !out.seven_day) done(1, "claude-usage: the response had no usage windows");
  done(0, JSON.stringify(out), process.stdout);
} catch (e) {
  if (!(e instanceof Done)) { process.stderr.write(`claude-usage: ${short(e)}\n`); process.exitCode = 1; release(); try { q?.close(); } catch { /* closed */ } }
}
