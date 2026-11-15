# claw infra

**How changes reach claw:** agents (Navi as `openclaw`, Claude Code as `coder`) push `navi/*` or `claude/*` branches through `agent-git`, which runs as `gitbot`, the only holder of a write token. Drew merges on GitHub. `claw-sync` resets `~/.openclaw` to `origin/main` every 5 minutes and restarts the gateway only when `openclaw.json` changes (see Safe deploys).

**Claude Code:** OpenClaw's acpx starts it with `sudo -n -u coder /usr/local/bin/coder-acp`. sudo strips the gateway's environment, so coder only sees its own read-only token. It works in `/srv/work/<repo>` and follows `coder-CLAUDE.md`.

**State backup:** `USER.md`, `MEMORY.md`, `DREAMS.md` and `memory/` are agent-owned and gitignored in claw-config. `claw-backup` (nightly ~03:30, as openclaw) copies them into a local repo at `~/.openclaw/state-backup` (one commit per day with changes) and pushes it through `agent-git` to the private `claw-state` repo on branch `navi/state/<hostname>`. agent-git only pushes `navi/*`/`claude/*` and opens PRs, so the first run opens one PR on claw-state that then just gets updated each night. **The branch is the backup; don't merge or delete it.** Activate with `sudo claw-install` (see Applying infra). Test right away: `sudo systemctl start claw-backup && sudo journalctl -u claw-backup -n 20`. **Keep `state-backup` intact:** agent-git always force-pushes, so if `~/.openclaw/state-backup` is ever missing (rebuilt host, partial copy, `rm -rf`), the next run starts a fresh repo and overwrites `navi/state/<hostname>` with a single commit, erasing all earlier snapshots. Never delete it to "fix" it. Restore steps are below. Restore the repo, not just the files, or the next nightly run wipes the branch history. **The agent can wipe it too:** Navi runs as openclaw and can call `agent-git pr claw-state navi/state/<hostname>` itself, so a confused or prompt-injected agent can force-push over the branch. GitHub only blocks that with a ruleset (`navi/state/**`: Block force pushes, Restrict deletions), and rulesets need GitHub Pro for a private repo (the API returns 403 on the free plan). Until then, the history survives only in `state-backup` and in any clones, so pull a copy now and then (step 2 below works anywhere coder's token does). When moving hosts, the `rsync` of `~/.openclaw` brings `state-backup` along so history continues (check it arrived before the first nightly run); a host with a different name moves that history onto its own branch `navi/state/<newname>` and leaves the old branch alone.

**Restoring state** (as drew on claw; drew has no GitHub credentials, so the clone uses coder's read-only token, which covers claw-state):
1. `sudo systemctl stop claw-backup.timer` so a nightly run can't recreate `state-backup` mid-restore.
2. `sudo -H -u coder git clone -q -b navi/state/<hostname> https://github.com/andrewgarmon/claw-state.git /tmp/claw-state`
3. Move any existing repo aside first, or `cp -a` nests into it: `S=/home/openclaw/.openclaw/state-backup; [ -e "$S" ] && sudo mv "$S" "$S.bad.$(date +%s)"; sudo cp -a /tmp/claw-state "$S" && sudo chown -R openclaw: "$S" && sudo rm -rf /tmp/claw-state`
4. Copy the files into the workspace as openclaw (drew can't write there): `sudo -H -u openclaw bash -c 'cd ~/.openclaw/state-backup && cp -a USER.md MEMORY.md DREAMS.md memory ~/.openclaw/workspace/'` (leave out any that aren't in the backup).
5. `sudo systemctl start claw-backup.timer`, then `sudo systemctl start claw-backup && sudo journalctl -u claw-backup -n 20` should show either "nothing new to push" or a push of the restored head (a fast-forward, so no history is lost).

**Safe deploys:** `claw-sync` runs `openclaw config validate` before restarting. Invalid config is never deployed. After a restart it waits up to 3 min for `openclaw gateway health` to pass; if it doesn't, it resets to the last commit the gateway was healthy on and restarts again. Either way that `origin/main` commit is marked bad and skipped until main moves, so fix it with a new PR. Exceptions: a commit already known good (e.g. reverting local drift) is never marked bad, and if the rollback doesn't recover the gateway either, nothing is marked bad and the commit is retried next run. A `pending` marker is written before a config change touches the tree; if a run is killed mid-deploy (reboot, OOM, timeout), the next run re-validates, restarts, re-checks health and rolls back if needed. While main is marked bad, local drift is still reverted (to the last good commit). The state dir is writable by `openclaw` (the agent's user), so `good`/`pending` are only trusted if they're on `origin/main`; a forged `bad` can still freeze deploys, but that keeps sending `/fail` until cleared. A `git fetch` failure only sends `/fail` after 3 runs in a row. State lives in `/home/openclaw/.cache/claw-sync/{good,bad,pending,fetch-fails}`. If a commit was marked bad by a transient failure, clear it and re-run: `sudo -u openclaw rm /home/openclaw/.cache/claw-sync/bad && sudo systemctl start claw-sync`. PRs also run `.github/workflows/ci.yml`: the same config validation, every `infra/tests/*.test.sh` (claw-sync, agent-git, claw-install) and `infra/brokers/*/test.sh`, a secret scan, a state-file guard and shellcheck. A new test file is picked up without a workflow edit. Agents can't write `.github/workflows/`, so changes to CI come from drew (or Claude in the app).

**Dead-man alerts:** every claw-sync run (every 5 min) checks gateway health and pings `HEALTHCHECKS_PING_URL` from `~/.openclaw/.env`: success when synced and healthy, `/fail` (with the reason as the body) on a bad deploy, a rollback, an unhealthy gateway or a claw-sync crash. If the host, the timer or claw-sync stops, the pings stop. In healthchecks.io set the check to period 5 min, grace 10 min. Test: `sudo systemctl start claw-sync && sudo journalctl -u claw-sync -n 5`, then look at the check's event log.

## Applying infra
**This folder is NOT auto-applied.** After merging a change here, run on claw as drew:
`sudo claw-install`

It clones `origin/main` fresh into a root-only temp dir (using coder's read-only token, read but never sourced), shows the `infra/` commits and diffstat since the last install (`d` shows the full diff), asks, runs `install.sh` from that clone, records the commit in `/var/lib/claw-install/last`, deletes the clone and updates itself. `-y` skips the question. Root never runs anything from `/home/openclaw/.openclaw`: Navi's user can write that tree between claw-sync resets, so a prompt-injected Navi could otherwise edit `install.sh` (or a sudoers file it installs) and get root the next time it ran. `install.sh` itself refuses to run from any tree that isn't entirely root-owned, so the old `sudo bash /home/openclaw/.openclaw/infra/install.sh` now stops with a pointer here.

**First time on a host** (installs `claw-install` from a fresh clone, never from the openclaw checkout; asks for a token if coder's isn't set up yet):
```bash
sudo bash -c '
  set -e; umask 077; d=$(mktemp -d); trap "rm -rf $d" EXIT
  T=$(sed -n "s/^GH_TOKEN=//p" /home/coder/.config/coder.env 2>/dev/null | head -1)
  [ -n "$T" ] || { read -rsp "Read-only GitHub token for claw-config: " T; echo; }
  GH_TOKEN=$T git -c credential.helper= -c "credential.helper=!f() { echo username=x-access-token; echo password=\$GH_TOKEN; }; f" \
    clone -q --depth 1 https://github.com/andrewgarmon/claw-config.git "$d/r"
  install -m 755 -o root -g root "$d/r/infra/claw-install" /usr/local/sbin/claw-install
  echo "installed /usr/local/sbin/claw-install"'
sudo claw-install
```

**Changing live config by hand** (e.g. `openclaw plugins install`): run `sudo systemctl stop claw-sync.timer` first, make the change, PR the resulting `openclaw.json`, merge, then `sudo systemctl start claw-sync.timer`.

## Adding a broker
A broker is a dedicated user that holds one secret and lets Navi (or coder) run a fixed set of verbs with it through sudo, so the agent never sees the secret. `gitbot`/`agent-git` is one. To add another, create `infra/brokers/<name>/` and change nothing else (not `install.sh`, not CI):
- `broker.conf`: data, parsed with a strict `KEY=value` regex and never sourced (`infra/lib/broker-install.sh` documents the keys). `USER` (its own user: no two brokers may share one, root, drew, openclaw and coder are refused, and an existing account is only reused if it looks like one claw-install made, i.e. system UID, nologin, home `/home/USER`, no group but its own), `CALLERS` (from `openclaw coder`), `SECRET` (a file name under `/home/USER/.config/`, mode 700 dir), optional `DEPS` (apt packages) and `PYREQS` (one `name==version --hash=sha256:…` line per package, covering every transitive dependency and every wheel pip may pick on the host, installed into a venv with `--no-deps --require-hashes`, wheels only).
- `agent-<name>`: the wrapper, installed root:root 755 to `/usr/local/bin/`. It sets `PATH` and `HOME` itself, sets `BROKER`, `BROKER_USER` and `LOG`, sources `/usr/local/lib/claw/broker.sh` by that absolute path, calls `broker_require_user` first, reads its secret with `broker_secret_raw` or `broker_secret_env` (never `source`), validates every argument and logs the caller and verb (never the secret or bodies).
- `test.sh`: CI runs it automatically. `brokers/git/test.sh` shows how to point a copy of the wrapper at the repo's `broker.sh`, a temp `HOME` and fake tools.
- optional `lib/`: support files, installed root:root to `/usr/local/lib/claw/brokers/<name>/` (its venv lives there too).

`claw-install` then creates the user and config dir, installs deps, the wrapper, `lib/` and the venv, generates `/etc/sudoers.d/agent-<name>` (`Defaults!… env_reset, !setenv` plus one `CALLER ALL=(USER) NOPASSWD: /usr/local/bin/agent-<name>` line per caller), checks it with `visudo -cf`, and prints a TODO while the secret file is missing. Every `broker.conf` is validated before anything changes. Then write the secret as the broker user with the `read -rsp` pattern under Secrets.

**Removing a broker:** delete its dir and run `sudo claw-install`. It removes the generated `/etc/sudoers.d/agent-<name>`, `/usr/local/bin/agent-<name>` and `/usr/local/lib/claw/brokers/<name>/` (only files carrying the generated header), so the sudo grant never outlives its config. The user and its secret stay until you delete them (`sudo deluser --remove-home <user>`).

**When not to use one:** a low-value key, or one that's only good for what Navi does anyway, can stay in `~/.openclaw/.env`. A plain HTTPS API key may be better served by OpenClaw's secret egress proxy (check its docs). Use a broker when the secret opens more than the task needs (an Apple app-specific password also opens iCloud Mail), when you want the agent limited to a few verbs, or when a prompt-injected Navi holding the secret would be a real problem.

## Public repos (agent-git)
agent-git treats a repo as public if GitHub says so (it asks on every write, so a repo flipped to public is covered right away) or if it's listed in `/home/gitbot/.config/public-repos` (one name per line, `#` comments; for a repo you're about to flip). For public repos:
- **Writes are coder-only.** `pr`, `issue`, `issue-comment`, `issue-label`, `issue-close` and `issue-reopen` are refused for anyone but coder. Navi hands public work to Claude Code, which can't read Navi's memory. Reads (`issue-list`, `issue-view`) stay open.
- **Everything that would go public is checked first.** For `pr`: every commit not already on the default branch (message, author and committer, and every line it adds, including new file paths), the branch name, title and body. Removed lines aren't checked, since they're already public, so a PR that deletes a leaked string still goes through. Branches with merge commits are refused; rebase instead. For issues: the title, body or comment. The checks are `/home/gitbot/.config/redact.txt` (one string per line, matched case-insensitively; `#` comments and blank lines are ignored) and gitleaks (Ubuntu's package, installed by claw-install; `gitleaks:allow` markers are neutralized so an agent can't opt out). On a hit nothing is written. The caller and the log get which part and which check (e.g. `DENY refused: … the body contain a redact.txt entry`), never the matched text.
- **It fails closed.** If `redact.txt` is missing or has no entries, gitleaks fails to run, or GitHub can't say whether the repo is public, nothing is written. Private repos behave exactly as before, apart from that one visibility lookup.
- `new-repo` still only creates private repos. Making a repo public is your manual step.
- **The leak check is the real control; coder-only is a speed bump.** Navi starts Claude Code and writes its prompt, so a prompt-injected Navi could still pass private details through it. Keep `redact.txt` complete rather than relying on who the caller is.
- **Commit identity matters.** Author and committer are checked, so coder must commit as `Claude Code <claude@claw.invalid>` (claw-install sets that). Commits made under your own name can't go through agent-git to a public repo; push those yourself.
- Limits: entries are exact strings apart from case, so `Jane Q Example` doesn't catch `jane-q-example` or `janeqexample` (add the variants you care about). Compressed or binary content is checked as raw bytes, so a string inside an image or archive gets through (keep binaries out of public repos). Entries match inside longer words, so prefer full names and handles over short words.

Set up after `sudo claw-install` (it creates gitbot's config dir), before any repo goes public:
```bash
sudo -u gitbot bash -c 'umask 077; touch ~/.config/redact.txt ~/.config/public-repos'
sudoedit -u gitbot /home/gitbot/.config/redact.txt    # your Telegram user ID, bot username, email addresses, full name, family names, street, phone
sudoedit -u gitbot /home/gitbot/.config/public-repos  # optional
```
Check it once the public repo exists: ask Claude Code to file an issue on it with one of your redact entries in the title. It should be refused with "contain a redact.txt entry", and `sudo tail -2 /home/gitbot/agent-git.log` should show the DENY without the string.

## Secrets (not in git, set up per host)
- gitbot: fine-grained PAT, All repositories, Administration + Contents + Issues + Pull requests read/write (Issues is for the `agent-git issue*` commands), everything else (esp. Workflows, Secrets) no access.
  `sudo -H -u gitbot bash -c 'umask 077; read -rsp "Token: " T && printf "%s\n" "$T" > ~/.config/gh-token'`
- calbot (`agent-cal`, Navi's calendar access over CalDAV): an Apple app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords. It isn't scoped (it also opens iCloud Mail, where password resets land), which is why only calbot holds it.
  `sudo -H -u calbot bash -c 'umask 077; read -rp "Apple ID: " U && read -rsp "App-specific password: " P && printf "APPLE_ID=%s\nAPPLE_APP_PASSWORD=%s\n" "$U" "$P" > ~/.config/caldav.env'`
  Test: `sudo -u calbot agent-cal calendars` and `sudo -u calbot agent-cal events --days 2`; log in `/home/calbot/agent-cal.log`. Every create/update/delete is kept with a copy of the event as it was in `/home/calbot/state/history.json` (last 200): `sudo -u calbot agent-cal changes` lists them and `sudo -u calbot agent-cal undo [--change cN]` reverses one. Then remove the old webcal URL (the file is openclaw's, so as drew): `sudo -u openclaw sed -i '/^APPLE_CALENDAR_URL=/d' /home/openclaw/.openclaw/.env`. Optional extra layer: give Navi its own Apple ID, share your calendars to it with "Can edit", and use that ID's password, so a leak only exposes an empty inbox.
- coder: fine-grained PAT, All repositories, Contents + Issues + Pull requests read-only.
  `sudo -H -u coder bash -c 'umask 077; read -rsp "Token: " T && printf "GH_TOKEN=%s\n" "$T" > ~/.config/coder.env'`
  plus git setup: a credential helper that reads `GH_TOKEN` from that file. claw-install sets the commit identity `Claude Code <claude@claw.invalid>` (needed for public repos, see Public repos).
- coder's Claude login: as coder, `curl -fsSL https://claude.ai/install.sh | bash && ~/.local/bin/claude` (log in with the Claude subscription).
- openclaw: read-only deploy key on claw-config (`~/.ssh`), git identity `Navi <navi@claw.invalid>`. Gateway, Telegram and Gemini credentials live inside `~/.openclaw` (`.env`, auth profiles).
- openclaw `.env` per-person values: `TELEGRAM_ALLOW_FROM` is your numeric Telegram user ID. `openclaw.json` uses it for `channels.telegram.allowFrom` and `commands.ownerAllowFrom`. Not a secret, but it differs per install, so it stays out of git. **If it's missing, Telegram ignores everyone** (OpenClaw leaves `${TELEGRAM_ALLOW_FROM}` unresolved with a warning, which matches no one) and config validation still passes, so claw-sync deploys anyway. Fix: add it, then `sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) systemctl --user restart openclaw-gateway`.
  `sudo -H -u openclaw bash -c 'F=~/.openclaw/.env; read -rp "Telegram user ID: " I && [[ $I =~ ^[0-9]+$ ]] || { echo "not numeric"; exit 1; }; [ -s "$F" ] && [ -n "$(tail -c1 "$F")" ] && echo >> "$F"; printf "TELEGRAM_ALLOW_FROM=%s\n" "$I" >> "$F"'`

## Moving to a new host (e.g. the Pi)
1. Base OS (arm64 is fine): user drew (sudo), SSH keys only, Tailscale, ufw allowing only tailscale0. Add swap if RAM is under 8 GB. On a Pi, boot from a USB SSD, not the SD card.
2. System-wide Node 24, user `openclaw`, OpenClaw installed as openclaw (npm prefix `~/.npm-global`), `openclaw onboard --install-daemon` (local, loopback, port 18789), `sudo loginctl enable-linger openclaw`.
3. **Stop the gateway on the OLD host first.** Two gateways polling one Telegram bot will conflict.
4. Copy state as openclaw: `rsync -a old:/home/openclaw/.openclaw/ ~/.openclaw/` and `old:/home/openclaw/.ssh/` (deploy key). This brings config, `.env`, memory, sessions and installed plugins.
5. Install `claw-install` and run it (First time on a host, above), then do the TODOs it prints (Secrets above).
6. Restart the gateway, check `openclaw logs --follow`, DM the bot, then make sure `systemctl list-timers claw-sync.timer claw-backup.timer` shows both.

Logs: `journalctl -u claw-sync`, `journalctl -u claw-backup`, `/home/gitbot/agent-git.log`, `/home/calbot/agent-cal.log` (all need sudo).
Quick health check (timer, gateway, recent logs, memory): `claw-status` (as drew; prompts for sudo; installed by claw-install).
