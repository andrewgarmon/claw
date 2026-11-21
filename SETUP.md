# Setting up your own

A fresh install from nothing to a working assistant you can text, which changes itself only through PRs you approve. Written so a person, or an AI agent with a shell on the host, can follow it top to bottom.

**For an AI agent following this:** do the steps in order and run each **Check** before moving on. Steps marked **(human)** need the owner: signing up for accounts, pasting secrets, approving keys on GitHub. Stop and ask at those. Never print or log a secret; read them with `read -rs`. Replace `YOU` with the owner's GitHub username and `ADMIN` with their admin Linux user wherever they appear.

Time: about two hours. Cost: a host (a 4 GB VPS is about $24/month, or $0 on hardware you own) plus model API usage.

## 0. What you need (human)
- A **GitHub** account (the free plan is fine).
- **Telegram** on your phone.
- A **Google AI Studio API key** for Gemini (the config uses Gemini models; another provider works but means editing the models in `openclaw.json`).
- A **Claude** subscription, for Claude Code to do coding work (optional, but the PR loop is half the point).
- Optional: a [healthchecks.io](https://healthchecks.io) account (dead-man alerts), an iCloud calendar (`agent-cal`).

## 1. Make your two repos (human or agent, on a laptop)
Your **fork** of this repo is public and is what the host deploys. Your personal files (persona, this install's rules, private skills) go in a separate **private repo**, mounted in the fork as a pinned submodule at `workspace/private`. `private.example/` shows what goes in it.

**(human)** Fork this repo on GitHub, and create an empty **private** repo, e.g. `claw-private`. Then:
```bash
git clone https://github.com/YOU/claw && cd claw
grep -rlI andrewgarmon . | xargs sed -i 's/andrewgarmon/YOU/g'          # GitHub owner in scripts and docs
infra/tests/run-all.sh | tail -3                                         # ends with "all passed"
cp -r private.example /tmp/private && git -C /tmp/private init -q -b main # fill in AGENTS.md now or later
git -C /tmp/private add -A && git -C /tmp/private commit -qm "Initial private files"
git -C /tmp/private remote add origin git@github.com:YOU/claw-private.git && git -C /tmp/private push -u origin main
git submodule set-url workspace/private https://github.com/YOU/claw-private.git
git submodule update --init --remote workspace/private
git add -A && git commit -qm "My private repo" && git push
```
Optional: the issue-label allowlist (`ISSUE_LABELS` in `infra/brokers/git/agent-git`). The assistant's name and emoji come from `IDENTITY.md` in your private repo.

**Check:** `git submodule status` shows your private repo's commit, and `grep -rI andrewgarmon .` finds nothing.

## 2. Get a host
Any of these, running **Ubuntu 24.04** with **at least 4 GB of RAM** (with 2 GB the gateway runs out of memory and replies take 30+ seconds):
- **VPS:** e.g. a DigitalOcean droplet, Basic 4 GB. Add your SSH key when creating it.
- **Your own box:** a mini PC, an old laptop, or a Raspberry Pi 4/5 with 8 GB (arm64 is fine). On a Pi, boot from a USB SSD, not the SD card.
- **A VM** (Proxmox, VirtualBox, UTM) with 4 GB+ and bridged or NAT networking.

It needs outbound internet only. Telegram is polled, so no inbound ports are opened.

**Check:** you can `ssh` in as root (or the default user) with your key.

## 3. Base OS: users, SSH, Tailscale, firewall
```bash
adduser ADMIN && usermod -aG sudo ADMIN                     # your login (sudo)
adduser --disabled-password --gecos "" openclaw             # the assistant (no sudo)
rsync -a ~/.ssh /home/ADMIN/ && chown -R ADMIN: /home/ADMIN/.ssh
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/; s/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && systemctl restart ssh
apt-get update && apt-get install -y git jq curl ufw
```
Install **Tailscale** (`curl -fsSL https://tailscale.com/install.sh | sh && tailscale up`) and log in **(human)**. Install it on your laptop and phone too, and disable key expiry for this machine in the Tailscale admin console. Then lock the firewall to Tailscale only:
```bash
ufw default deny incoming && ufw default allow outgoing && ufw allow in on tailscale0 && ufw --force enable
```
On a VPS, also add a cloud firewall with no inbound rules if your provider has one. Add swap if RAM is under 8 GB:
```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab
```
From here on, work as `ADMIN` over Tailscale: `ssh ADMIN@<tailscale-name>`.

**Check:** `ssh ADMIN@<tailscale-name>` works, root login is refused, and `sudo ufw status` shows only `tailscale0`.

## 4. Node and OpenClaw (as `openclaw`)
System-wide Node 24 (Claude Code's ACP adapter also needs it):
```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - && sudo apt-get install -y nodejs && node --version
```
OpenClaw, installed for `openclaw` at the version the config was written with (`meta.lastTouchedVersion` in `openclaw.json`, e.g. `2026.11.3`):
```bash
sudo -iu openclaw bash -c 'mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global && echo "export PATH=\$HOME/.npm-global/bin:\$PATH" >> ~/.profile'
sudo -iu openclaw npm install -g openclaw@2026.11.3
sudo loginctl enable-linger openclaw
sudo -iu openclaw openclaw onboard --install-daemon
```
Onboarding answers **(human, for the API key)**: local gateway, bind **loopback**, port **18789**, Tailscale **off**, agent id **main**, model provider **Google** with your API key, web search **DuckDuckGo**, no channels yet (Telegram comes from the repo's config), skip memory embeddings.

Then the two plugins the config uses:
```bash
sudo -iu openclaw openclaw plugins install @openclaw/duckduckgo-plugin
sudo -iu openclaw openclaw plugins install @openclaw/acpx
```

**Check:** `sudo -iu openclaw openclaw gateway health` reports healthy.

## 5. Save the values onboarding generated
Step 6 replaces `~/.openclaw/openclaw.json` with your repo's, so first copy out the two install-specific values:
```bash
sudo -iu openclaw bash -c 'umask 077; printf "OPENCLAW_GATEWAY_TOKEN=%s\n" "$(jq -r .gateway.auth.token ~/.openclaw/openclaw.json)" >> ~/.openclaw/.env'
sudo -iu openclaw jq -r '.auth.profiles | keys[]' /home/openclaw/.openclaw/openclaw.json
```
The second command prints your auth profile ids, e.g. `google:setup-1a2b…`. In your repo (on the laptop), replace every `google:setup-101632ab-39a7-4fb0-b049-a2a4b78cb644` in `openclaw.json` with yours, under `agents.defaults.model`, `agents.entries.reader.model` and `auth.profiles`, then commit and push to main.

**Check:** `.env` has an `OPENCLAW_GATEWAY_TOKEN=` line that isn't `null`, and your repo's `openclaw.json` names your profile id.

## 6. Make `~/.openclaw` a checkout of your repo
`openclaw` fetches your fork over HTTPS, and your private repo with a **read-only** deploy key, so the assistant can pull but never push:
```bash
sudo -iu openclaw bash -c 'ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/claw_private -C "openclaw@claw (read-only deploy key)" && cat ~/.ssh/claw_private.pub'
```
**(human)** In your private repo → Settings → Deploy keys → Add deploy key, paste the key, and leave **Allow write access unticked**. Then:
```bash
sudo -iu openclaw bash -c 'printf "Host github-claw-private\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/claw_private\n  IdentitiesOnly yes\n" >> ~/.ssh/config && ssh-keyscan -q github.com >> ~/.ssh/known_hosts'
sudo -iu openclaw git config --global url.git@github-claw-private:YOU/claw-private.git.insteadOf https://github.com/YOU/claw-private.git
sudo -iu openclaw bash -c 'cd ~/.openclaw && git init -q -b main && git remote add origin https://github.com/YOU/claw.git && git fetch -q origin main && git checkout -f -B main origin/main && git submodule update --init && git status --short'
```
Tracked files now come from your repos. Everything else (`.env`, credentials, sessions, the starter `USER.md`) stays on disk, untracked. OpenClaw's starter `SOUL.md`, `IDENTITY.md` and `BOOTSTRAP.md` aren't used: yours come from the private repo. From now on `claw-sync` removes untracked files in the checkout every run (ignored state like `.env` and `USER.md` stays). `openclaw.json` sets `agents.defaults.skipBootstrap: true`, so once your config is deployed OpenClaw stops re-creating starter files.

**Check:** `sudo -iu openclaw git -C ~/.openclaw log --oneline -1` shows your latest commit, and `sudo -iu openclaw ls ~/.openclaw/workspace/private` shows your private files.

## 7. Telegram
**(human)** In Telegram, message **@BotFather**, send `/newbot` and copy the token. Message **@userinfobot** to get your numeric user ID. Then:
```bash
sudo -iu openclaw bash -c 'umask 077; read -rsp "Bot token: " T; echo; read -rp "Your Telegram user ID: " I; [[ $I =~ ^[0-9]+$ ]] || { echo "not numeric"; exit 1; }; printf "TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOW_FROM=%s\n" "$T" "$I" >> ~/.openclaw/.env'
sudo -iu openclaw openclaw config validate
sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) systemctl --user restart openclaw-gateway
```
`TELEGRAM_ALLOW_FROM` is the allowlist: messages from anyone else are ignored. Optional: turn on BotFather's Threaded mode so each Telegram thread gets its own session. Each session's context is capped at 200k tokens (`contextTokens` on the Google models; older turns are compacted, after a memory flush), and a session nobody has written in for 4 days resets on its next message (`session.reset` idle mode). The session-memory hook saves its last 50 messages to `memory/` first. Snapshot filenames use `agents.defaults.userTimezone` if you set it (else the host's timezone, often UTC).

**Check:** DM your bot "hi" and get a reply (the first reply can take a minute after a restart).

## 8. Host plumbing: `claw-install`
**(human)** Create a **fine-grained token** for Claude Code on GitHub → Settings → Developer settings → Fine-grained tokens: All repositories, **read-only** Contents, Issues and Pull requests. It's stored for coder below (claw-install uses it too if it's there).

Install `claw-install` from a fresh clone, then run it. Your repo's [`infra/README.md`](infra/README.md) has this snippet with your username filled in, under "Applying infra" → "First time on a host":
```bash
sudo bash -c '
  set -e; umask 077; d=$(mktemp -d); trap "rm -rf $d" EXIT
  git clone -q --depth 1 https://github.com/YOU/claw.git "$d/r"
  install -m 755 -o root -g root "$d/r/infra/claw-install" /usr/local/sbin/claw-install'
sudo claw-install
```
It creates the `coder`, `gitbot` and `calbot` users, installs the brokers, the deploy, backup and auto-install timers and the gateway drop-ins, then prints a **TODO** for each missing secret. Work through them (exact commands are in `infra/README.md` → Secrets):
- **coder's token** (the read-only one above): `sudo -H -u coder bash -c 'umask 077; read -rsp "Token: " T && printf "GH_TOKEN=%s\n" "$T" > ~/.config/coder.env'`, then let git use it: `sudo -H -u coder git -C /home/coder config --global credential.helper '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'`
- **Claude Code** as coder **(human, to log in)**: `sudo -iu coder bash -c 'curl -fsSL https://claude.ai/install.sh | bash && CLAUDE_CONFIG_DIR=~/.claude ~/.local/bin/claude'` (`CLAUDE_CONFIG_DIR` as sessions use it)
- **gitbot's token (human)**: a second fine-grained token, All repositories, read/write for **Contents, Issues, Pull requests**, nothing else (not Administration, Workflows, Actions or Secrets). New repos are yours to create on github.com; "All repositories" covers them. Store it with: `sudo -H -u gitbot bash -c 'umask 077; read -rsp "Token: " T && printf "%s\n" "$T" > ~/.config/gh-token'`
- **redact-sync (human, optional)**: mirrors `redact.txt` into the CI check's `PERSONAL_DENYLIST` secret. It needs a third token and its own healthchecks.io check. It stays off until gitbot has `redact.txt` and the token is in `/etc/claw/redact-sync-token`. Check your list against the repo first: see infra/README.md, "CI secret from redact.txt".
- **calbot** (optional, iCloud calendar): see Secrets → calbot.

Run `sudo claw-install` again after the secrets are in. It's safe to re-run.

From now on, merged `infra/` changes install themselves within a few minutes (`claw-install-auto.timer`; infra/README.md → Applying infra, including its optional healthchecks.io check).

**Check:** `claw-status` shows the timer and a healthy gateway, and `systemctl list-timers claw-sync.timer claw-backup.timer claw-install-auto.timer` lists all three.

## 9. State backup (recommended)
`claw-backup` snapshots the assistant's memory nightly to a private repo. **(human)** Create a private repo **`claw-state`**, ticking "Add a README" so it has a first commit. Then, on the laptop in your `claw` checkout:
```bash
git clone -q https://github.com/YOU/claw-state /tmp/claw-state
git -C /tmp/claw-state bundle create "$PWD/workspace/private/claw-state-root.bundle" refs/remotes/origin/main
sed -i "s/^ROOT_SHA=.*/ROOT_SHA=$(git -C /tmp/claw-state rev-parse origin/main)/" infra/claw-backup
git -C workspace/private add -A && git -C workspace/private commit -qm "Root of my claw-state repo" && git -C workspace/private push
git add infra workspace/private && git commit -qm "claw-backup: root of my claw-state repo" && git push
```
The auto-install picks it up within a few minutes. Until this is done, the nightly backup fails (visible in `journalctl -u claw-backup`).

**Check:** `sudo systemctl start claw-backup && sudo journalctl -u claw-backup -n 20` shows a push and a PR link on `claw-state`. That PR is the backup: leave it open, never merge it.

## 10. Optional extras
- **Dead-man alerts:** create a healthchecks.io check (period 5 min, grace 10 min) and add `HEALTHCHECKS_PING_URL=…` to `~/.openclaw/.env`.
- **Claude reviews of PRs:** install the Claude GitHub App on both repos (`.github/workflows/claude-review.yml` is here; copy it into the private repo too).
- **Redaction list (needed: your fork is public):** `agent-git` refuses writes to public repos until it has one (`infra/README.md` → Public repos).

## 11. The end-to-end test
1. DM the bot: "file a test issue on claw-private, then close it". An issue appears through `gitbot`.
2. DM the bot: "have Claude Code add a line to the README saying hello, and open a PR". A `claude/*` PR appears.
3. Merge it on your phone. Within about a minute `claw-sync` deploys it (`journalctl -u claw-sync --since -10min`).
4. Ask the bot something only your private `AGENTS.md` says, e.g. "when does your briefing run?"

If all four work, the loop is complete. From here, change the assistant by asking it (or Claude Code) for a PR and merging it.
