# claw

Config, rules and host plumbing for a personal AI assistant on [OpenClaw](https://www.npmjs.com/package/openclaw). It runs on a small Linux host, talks over Telegram, and changes itself only through pull requests its owner approves.

> A personal setup shared as-is, not a supported product. Borrow from it or fork it; don't expect support.

**Set up your own:** [`SETUP.md`](SETUP.md), written so a person or an AI agent can follow it step by step.

## How it works
- You message the assistant on Telegram. The assistant (OpenClaw, Linux user `openclaw`) answers, keeps memory and to-dos, reads your calendar. It has no shell: typed tools for the calendar, GitHub issues and Claude usage, and file tools limited to its workspace.
- To change code or its own config, the assistant hands the work to **Claude Code** (user `coder`), which opens a PR.
- PRs go through **`agent-git`** (user `gitbot`), the only holder of a GitHub write token. It pushes only `agent/*` and `claude/*` branches and never merges.
- You review and merge on your phone. **`claw-sync`** deploys `main` within about a minute, validating first and rolling back if the gateway doesn't come up healthy.
- Host plumbing (`infra/`) is never auto-deployed. The admin user applies it with `sudo claw-install`, which shows the diff first.

## Layout
- `openclaw.json`: OpenClaw config. Personal values come from `~/.openclaw/.env` via `${VAR}`.
- `workspace/AGENTS.md`: the agent's operating rules. `workspace/local/AGENTS.md.example` is the template for the private, per-install rules file.
- `skills/`: shared skills. Private ones live in `workspace/skills/` in the private repo.
- `infra/`: host scripts, systemd units and brokers. See [`infra/README.md`](infra/README.md).

This repo is the shared half. The owner's private `claw-config` pulls it through daily sync PRs and adds the personal files (persona, install-specific rules, private skills).

## Security model
- **One job per Linux user:** the admin user (sudo), `openclaw` (the agent, no sudo), `coder` (Claude Code, read-only GitHub token), `gitbot` (GitHub writes), `calbot` (calendar password).
- **Brokers hold the secrets.** The assistant calls typed tools that run fixed, argument-checked commands as `gitbot` or `calbot` through sudo, and never sees a token or password.
- **Read-only deploys.** `openclaw`'s deploy key can't push, and `claw-sync` resets edits made in place and removes files added outside git (ignored state such as `.env` and memory stays). Skill Workshop and the `cron` tool are off, so the agent can't add learned skills or scheduled jobs outside a PR.
- **Plugins are allowlisted.** Only plugin ids listed in `openclaw.json` load. Plugins this repo ships are installed root-owned and loaded from that path, so a plugin dropped into an extensions folder can't load or replace them.
- **Root plumbing is human-applied** from a root-owned clone (`claw-install`), never from the agent-writable checkout.
- **Public repos are guarded.** `agent-git` takes writes to them from Claude Code only, after a redaction-list check and gitleaks.
- **Agent state stays out of git.** `USER.md`, `MEMORY.md`, `memory/` and `DREAMS.md` live on the host and are backed up nightly to a private repo. CI fails if they're ever tracked.
