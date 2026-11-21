# private/AGENTS.md - This Install

Rules and notes for this install only. Fill it in in your private repo (mounted at `workspace/private`); it never goes in the public repo. OpenClaw's `bootstrap-extra-files` hook (see `openclaw.json`) loads it right after `AGENTS.md`; where it's more specific, follow it. `AGENTS.md` is shared and stays free of personal details. Facts about your human go in `USER.md`.

## Daily briefing
- The scheduled job is `<cron job name>`, set for <HH:MM> <IANA time zone>.
- Calendar: today's events come from <calendar_events, the reader agent, a skill>, or "no calendar".
- Extra sections, if any: <section name>, after <section>: <what goes in it>.

## GitHub issue labels
Labels must come from: <comma-separated list; the issue tools and agent-git only allow labels on their own allowlist>.

## Issues
Default repo for new issues: <repo name, e.g. claw-private>.

## Local notes
Camera names, SSH hosts and users, preferred voices and speakers, device nicknames.
