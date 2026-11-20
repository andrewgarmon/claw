// claw-tools approvals: what the before_tool_call hook in index.js decides for each tool call.
//   - calendar writes, GitHub issue writes, hand-offs to Claude Code (sessions_spawn unless it's
//     explicitly an OpenClaw subagent) and messages into other sessions (sessions_send: an approved
//     Claude Code session could otherwise be handed new tasks) need an Approve tap: requireApproval with a prompt built from the call's own parameters, never from
//     model prose, offering allow-once and deny only, waiting up to 10 minutes;
//   - message sends to an explicit target other than the owner's Telegram DM are blocked;
//   - web_fetch is logged (host only), not gated, for now;
//   - everything else (reads) passes untouched.
// No OpenClaw imports, so this is unit-tested with plain node (infra/tests/claw-tools.test.sh).

export const APPROVAL_TIMEOUT_MS = 600_000;
export const DECISIONS = Object.freeze(["allow-once", "deny"]);
export const GATED = [
  "calendar_create", "calendar_update", "calendar_delete", "calendar_undo",
  "github_issue_create", "github_issue_comment", "github_issue_label", "github_issue_close", "github_issue_reopen",
  "sessions_spawn", "sessions_send",
];

// clean(text, max): one line for an approval card. Control characters and newlines become spaces,
// characters chat markdown would act on are dropped (underscores stay: time zones and names use them),
// an approval command (/approve, /deny) is defused,
// and the result is capped. The card should show what will happen, and nothing it could be made
// to do.
export function clean(text, max) {
  let t = String(text ?? "")
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u200b-\u200f\u202a-\u202e\u2066-\u2069]/g, " ")
    .replace(/[*`~|<>[\]\\]/g, "")
    .replace(/(^|\s)\/(?=(approve|deny)\b)/gi, "$1∕")   // "/approve x" → "∕approve x": not a command
    .replace(/\s+/g, " ").trim();
  if (t.length > max) t = `${t.slice(0, max - 1)}…`;
  return t;
}
const q = (text, max) => `“${clean(text, max)}”`;
// sized(text, max): free text (a body, comment, task or message) for the card, after its length:
// "(17 chars): “…”". When it doesn't fit, that says so before the text ("(5000 chars, only the first
// 360 shown): “…”", so the card's own 512-char cap can't cut the warning off), and long() puts it in
// the card's title too. The owner never mistakes the start for the whole thing: Approve covers it all.
const tooLong = (text, max) => clean(text, Infinity).length > max;
const sized = (text, max) => (tooLong(text, max)
  ? `(${chars(text)}, only the first ${max} shown): “${clean(text, Infinity).slice(0, max)}…”`
  : `(${chars(text)}): ${q(text, max)}`);
const long = (text, max) => (tooLong(text, max) ? ` (long text: ${chars(text)}, start shown)` : "");
// room(prefix, cap): how much free text fits after the card's fixed fields (repo, labels, agent, cwd,
// ...) within its 512 characters, leaving space for the "(N chars, only the first M shown): “…”"
// wrapping. Sizing the excerpt to that, rather than to a fixed cap, means the final 512 cut never
// silently drops text the notice didn't announce.
const DESC_MAX = 512, WRAP = 56;
const room = (prefix, cap) => Math.max(40, Math.min(cap, DESC_MAX - clean(prefix, Infinity).length - WRAP));

// Events seen in recent calendar_events results (and the agent's own creates and updates), so a
// delete or update card can name the event, not just its id. Filled by index.js through learn(); the
// broker still decides which id means which event.
export class EventCache {
  constructor(limit = 500) { this.limit = limit; this.map = new Map(); }
  remember(events) {
    if (!Array.isArray(events)) return;
    for (const e of events) {
      if (!e || typeof e.id !== "string") continue;
      this.map.delete(e.id);
      this.map.set(e.id, { title: String(e.title ?? ""), start: String(e.start ?? ""), calendar: String(e.calendar ?? "") });
      if (this.map.size > this.limit) this.map.delete(this.map.keys().next().value);
    }
  }
  // learn(toolName, params, result): keep the cache current after a successful call. A create or
  // update returns the event as it now is (so a renamed or just-created event shows its current
  // title); a delete forgets its id (a later card for it says "not in a recent listing").
  learn(toolName, params, data) {
    const ok = data && typeof data === "object" && !Array.isArray(data);
    if (toolName === "calendar_events") this.remember(data);
    else if (toolName === "calendar_create" && ok && data.created === true) this.remember([data]);
    else if (toolName === "calendar_update" && ok && data.updated === true) this.remember([data]);
    else if (toolName === "calendar_delete" && ok && data.deleted === true) this.map.delete(String(params?.id ?? ""));
  }
  describe(id) {
    const e = this.map.get(id);
    return e ? `${q(e.title, 120)} on ${clean(e.calendar, 60)} at ${clean(e.start, 30)} (id ${clean(id, 12)})` : `id ${clean(id, 12)} (not in a recent listing)`;
  }
}

// the only parameters a card-free question to the reader may carry (see sessions_send below)
const READER_KEYS = new Set(["agentId", "message", "timeoutSeconds"]);
const span = (p) => `${clean(p.start, 30)} → ${clean(p.end, 30)}${p.tz ? ` (${clean(p.tz, 40)})` : ""}`;
const chars = (t) => `${String(t).length} chars`;

// approvalFor(toolName, params, cache): the requireApproval payload for a gated call, else null.
export function approvalFor(toolName, params, cache = new EventCache()) {
  const p = params && typeof params === "object" ? params : {};
  let title, description;
  switch (toolName) {
    case "calendar_create":
      title = "Create calendar event";
      description = `Create ${q(p.title, 120)} on ${clean(p.calendar, 60)} · ${span(p)}`
        + (p.location ? ` · location: ${q(p.location, 120)}` : "") + (p.notes ? ` · notes: ${q(p.notes, 120)}` : "");
      break;
    case "calendar_update": {
      const changes = [];
      if (p.title !== undefined) changes.push(`title → ${q(p.title, 120)}`);
      if (p.start !== undefined) changes.push(`start → ${clean(p.start, 30)}`);
      if (p.end !== undefined) changes.push(`end → ${clean(p.end, 30)}`);
      if (p.location !== undefined) changes.push(p.location === "" ? "location cleared" : `location → ${q(p.location, 100)}`);
      if (p.notes !== undefined) changes.push(p.notes === "" ? "notes cleared" : `notes → ${q(p.notes, 100)}`);
      title = "Change calendar event";
      description = `Change ${cache.describe(String(p.id ?? ""))}: ${changes.join(", ") || "nothing"}${p.tz ? ` (${clean(p.tz, 40)})` : ""}`;
      break;
    }
    case "calendar_delete":
      title = "Delete calendar event";
      description = `Delete ${cache.describe(String(p.id ?? ""))}`;
      break;
    case "calendar_undo":
      title = "Undo calendar change";
      description = p.change ? `Undo calendar change ${clean(p.change, 10)} (see calendar_changes)` : "Undo the last calendar change";
      break;
    case "github_issue_create": {
      const head = `File an issue on ${clean(p.repo, 100)}: ${q(p.title, 120)}`
        + (Array.isArray(p.labels) && p.labels.length ? ` · labels: ${clean(p.labels.join(", "), 120)}` : "") + " · body ";
      const n = room(head, 200);
      title = `File GitHub issue${long(p.body ?? "", n)}`;
      description = p.body ? head + sized(p.body, n) : `${head.slice(0, -" · body ".length)} · no body`;
      break;
    }
    case "github_issue_comment": {
      const head = `Comment on ${clean(p.repo, 100)}#${clean(p.number, 10)} `;
      const n = room(head, 300);
      title = `Comment on GitHub issue${long(p.body ?? "", n)}`;
      description = head + sized(p.body ?? "", n);
      break;
    }
    case "github_issue_label":
      title = "Change GitHub issue label";
      description = `${p.action === "remove" ? "Remove" : "Add"} label ${clean(p.label, 40)} ${p.action === "remove" ? "from" : "on"} ${clean(p.repo, 100)}#${clean(p.number, 10)}`;
      break;
    case "github_issue_close": {
      const head = `Close ${clean(p.repo, 100)}#${clean(p.number, 10)} with comment `;
      const n = room(head, 300);
      title = `Close GitHub issue${long(p.comment ?? "", n)}`;
      description = head + sized(p.comment ?? "", n);
      break;
    }
    case "github_issue_reopen":
      title = "Reopen GitHub issue";
      description = `Reopen ${clean(p.repo, 100)}#${clean(p.number, 10)}`;
      break;
    case "sessions_spawn":
      // fail closed: everything is treated as a hand-off to an external harness (Claude Code over
      // ACP, which acp.defaultAgent may pick even without runtime "acp") unless it's explicitly an
      // OpenClaw subagent
      if (p.runtime === "subagent") return null;
      {
        const head = `Start ${clean(p.agentId || "the default ACP agent", 40)}${p.cwd ? ` in ${clean(p.cwd, 80)}` : ""}${p.resumeSessionId ? " (resuming a session)" : ""} · task `;
        const n = room(head, 360);
        title = `Hand a task to Claude Code${long(p.task ?? "", n)}`;
        description = head + sized(p.task ?? "", n);
      }
      break;
    case "sessions_send": {
      // the read-only reader agent is how the main agent researches; a question to it is not a
      // hand-off (it can't write, message or spawn), so it needs no card. Exactly agentId "reader"
      // with a message (and optionally timeoutSeconds), nothing else: a session key, a label or any
      // selector a later OpenClaw adds (an ACP session above all) is gated.
      if (p.agentId === "reader" && typeof p.message === "string" && Object.keys(p).every((k) => READER_KEYS.has(k))) return null;
      const head = `Send to ${clean(p.sessionKey || p.label || (p.agentId ? `agent ${p.agentId}` : "a session"), 80)} `;
      const n = room(head, 360);
      title = `Send to another session${long(p.message ?? "", n)}`;
      description = head + sized(p.message ?? "", n);
      break;
    }
    default:
      return null;
  }
  return { title: clean(title, 80), description: clean(description, DESC_MAX), severity: "warning", timeoutMs: APPROVAL_TIMEOUT_MS, allowedDecisions: [...DECISIONS] };
}

// Fields that pick who a message goes to. A call that sets none of them (and no channel, group,
// guild or account) is a reply in the current chat and passes; any target it sets must be the owner.
const TARGET_KEYS = ["target", "to", "targets", "recipients", "recipient", "chatId", "chat_id", "peer", "peerId", "userId"];

// messageBlock(params, ownerId): a reason to block a message call that would reach anyone but the owner
// (replies in the current chat name no destination and pass), else null. Fails closed: broadcasts,
// another channel, another account, a group or guild, and any target that isn't the owner's id are
// blocked; with no owner id configured, every explicit target is blocked.
export function messageBlock(params, ownerId) {
  const p = params && typeof params === "object" ? params : {};
  if (typeof p.action === "string" && /broadcast/i.test(p.action)) return "broadcasts aren't allowed";
  const set = (v) => v !== undefined && v !== null && !(typeof v === "string" && v.trim() === "") && !(Array.isArray(v) && v.length === 0);
  const channel = set(p.channel) ? String(p.channel).trim().toLowerCase() : null;
  if (channel && channel !== "telegram") return `messages go only to the owner on Telegram, not to ${clean(channel, 30)}`;
  for (const k of ["groupId", "guildId", "channelId", "accountId"]) if (set(p[k])) return `messages go only to the owner's Telegram DM (${k} not allowed)`;
  const targets = TARGET_KEYS.filter((k) => set(p[k])).flatMap((k) => (Array.isArray(p[k]) ? p[k] : [p[k]]));
  if (targets.length === 0) return null;
  const owner = typeof ownerId === "string" && /^[0-9]{1,20}$/.test(ownerId) ? ownerId : null;
  const isOwner = (t) => (typeof t === "string" || typeof t === "number") && owner && String(t).trim().replace(/^telegram:/i, "") === owner;
  return targets.every(isOwner) ? null : "messages go only to the owner's Telegram DM";
}

// fetchHost(params): the host part of a web_fetch URL, for the log (never the path or query)
export function fetchHost(params) {
  try { return new URL(String(params?.url ?? "")).host.slice(0, 120) || "?"; } catch { return "?"; }
}
