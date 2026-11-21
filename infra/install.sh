#!/usr/bin/env bash
# Rebuild claw's CD + Claude Code plumbing from this repo. Safe to re-run.
# Prereqs: the admin user and openclaw exist, OpenClaw installed for openclaw (see README).
# Don't run this directly. Run (as the admin user): sudo claw-install
# claw-install clones origin/main into a root-only dir and runs this from there.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
cd "$(dirname "$0")"

# Refuse to run from a tree anyone but root could have changed (e.g. ~openclaw/.openclaw/infra,
# which the assistant's user can write between claw-sync resets): every directory from here up to /
# and every file under here must be root-owned and not group/other-writable.
untrusted() {
  local d uid mode
  d=$(pwd -P)
  while :; do
    read -r uid mode < <(stat -c '%u %a' "$d")
    { [ "$uid" = 0 ] && (( (8#$mode & 8#022) == 0 )); } || { echo "$d"; return 0; }
    [ "$d" = / ] && break
    d=$(dirname "$d")
  done
  find . \( ! -user root -o -perm /022 \) -print -quit | grep . && return 0
  return 1
}
if bad=$(untrusted); then
  echo "install.sh: refusing to run from a tree root doesn't own ($bad)." >&2
  echo "Run: sudo claw-install   (first time: see infra/README.md, \"Applying infra\")" >&2
  exit 1
fi
echo "installing ${CLAW_INSTALL_SHA:-from $(pwd -P)}"
id openclaw >/dev/null 2>&1 || { echo "create the openclaw user and install OpenClaw first" >&2; exit 1; }

# --- brokers (infra/brokers/<name>/: a user holding one secret, a fixed set of verbs via sudo).
# agent-git (gitbot) is one. Parse and check every broker.conf before changing anything.
# Root never writes under a service user's home: see lib/service-home.sh.
unset BROKER_ROOT CLAW_ROOT
# shellcheck source=lib/service-home.sh
. lib/service-home.sh
# shellcheck source=lib/broker-install.sh
. lib/broker-install.sh
# shellcheck source=lib/openclaw-plugins.sh
. lib/openclaw-plugins.sh
brokers_check brokers/*/ || { echo "install.sh: $B_ERR" >&2; exit 1; }
install -d -m 755 -o root -g root /usr/local/lib/claw /usr/local/lib/claw/brokers
install -m 644 -o root -g root lib/broker.sh /usr/local/lib/claw/broker.sh
for b in brokers/*/; do broker_install "$b"; done
broker_prune brokers
# broker refusals: claw-denywatch (root, every 15 min) alerts on DENY lines; the logs rotate weekly
command -v logrotate >/dev/null || apt-get install -y logrotate
broker_logs_install brokers || exit 1
install -m 755 -o root -g root claw-denywatch /usr/local/bin/
install -m 644 -o root -g root claw-denywatch.service claw-denywatch.timer /etc/systemd/system/
install -d -m 755 -o root -g root /etc/claw
# redact.txt -> the CI secret PERSONAL_DENYLIST, hourly as root with a root-only token (so nothing
# running as gitbot can rewrite the secret); each run pings its own check from /etc/claw/redact-sync.url
install -m 755 -o root -g root redact-sync unit-ping /usr/local/lib/claw/
install -m 644 -o root -g root claw-redact-sync.service claw-redact-sync.timer /etc/systemd/system/

# --- deploy timer (claw-sync) + nightly state backup (claw-backup)
command -v curl >/dev/null || apt-get install -y curl   # claw-sync healthchecks pings
command -v age >/dev/null || apt-get install -y age     # claw-backup encrypts state with it
# the backup's public key, from the config repo's backup.age.pub when there is one (a bad file
# fails the install before anything else changes below)
. lib/backup-key.sh
backup_key_install ../backup.age.pub || exit 1
install -m 755 -o root -g root claw-sync claw-backup /usr/local/bin/
install -m 755 -o root -g root status.sh /usr/local/bin/claw-status
install -m 755 -o root -g root smoke.sh /usr/local/bin/claw-smoke
# claw-sync alerts when claw-backup's last-ok is over 26h old; a new host gets 26h before the first
# nightly run. Created as openclaw: root never writes under a service user's home.
(cd / && sudo -u openclaw sh -c '[ -e "$1/last-ok" ] || { mkdir -p "$1" && touch "$1/last-ok"; }' _ /home/openclaw/.cache/claw-backup)
install -m 644 -o root -g root claw-sync.service claw-sync.timer claw-backup.service claw-backup.timer /etc/systemd/system/
# auto-install: claw-install --auto every 2 min (claw-install updates /usr/local/sbin/claw-install itself)
install -m 644 -o root -g root claw-install-auto.service claw-install-auto.timer /etc/systemd/system/
# claw-sync (as openclaw) reads the installed commit to say when an install is pending. claw-install
# writes it 644, but a copy from before that wrote it 600, and the first install after the change
# still runs that old copy: this fixes the mode on the run after.
[ ! -f /var/lib/claw-install/last ] || chmod 644 /var/lib/claw-install/last

# --- Claude Code as coder (ACP target)
id coder >/dev/null 2>&1 || adduser --disabled-password --gecos "" coder
install -d -m 755 -o coder -g coder /srv/work
install -m 755 -o root -g root coder-acp claude-usage /usr/local/bin/
install -m 644 -o root -g root claude-usage.mjs /usr/local/lib/claw/
# the ACP adapter coder-acp runs: exact versions from acp/package-lock.json, installed root-owned
# (coder can run it, not change it), no install scripts. Reinstalled only when the lockfile changes;
# built in a .new dir and swapped in, so a failed install leaves the old one working.
ACP=/usr/local/lib/claw/acp
if ! cmp -s acp/package-lock.json "$ACP/package-lock.json" || [ ! -x "$ACP/node_modules/.bin/claude-agent-acp" ]; then
  if command -v npm >/dev/null; then
    rm -rf "$ACP.new"
    install -d -m 755 -o root -g root "$ACP.new"
    install -m 644 -o root -g root acp/package.json acp/package-lock.json "$ACP.new/"
    if (cd "$ACP.new" && HOME=/root npm ci --ignore-scripts --omit=dev --no-audit --no-fund --loglevel=error); then
      rm -rf "$ACP" && mv "$ACP.new" "$ACP"
      echo "ACP adapter $(node -p 'require(process.argv[1]).version' "$ACP/node_modules/@agentclientprotocol/claude-agent-acp/package.json") installed"
    else
      rm -rf "$ACP.new"; echo "install.sh: npm ci for the ACP adapter failed; kept the previous install" >&2
    fi
  fi
fi
# --- OpenClaw plugins loaded from root-owned paths (plugins.load.paths): infra/openclaw-plugins/<id>/
oc_plugins_install openclaw-plugins

visudo -cf coder.sudoers
install -m 440 -o root -g root coder.sudoers /etc/sudoers.d/coder
coder_home_install   # ~coder/.config and ~/.claude (as coder), /etc/claude-code/CLAUDE.md
# coder's commit identity: agent-git checks author/committer against redact.txt for public repos
sudo -H -u coder git -C /home/coder config --global user.name 'Claude Code'  # -C: coder can't stat root's cwd
sudo -H -u coder git -C /home/coder config --global user.email claude@claw.invalid

# --- gateway systemd drop-ins (heap size, compile cache), root-owned in /etc/systemd/user/
gateway_dropins_install

systemctl daemon-reload
systemctl enable --now claw-sync.timer claw-backup.timer claw-denywatch.timer
# installs by hand only (sudo claw-install) while /etc/claw/manual-install exists
if [ -e /etc/claw/manual-install ]; then
  systemctl disable --now claw-install-auto.timer 2>/dev/null || true
else
  systemctl enable --now claw-install-auto.timer
  [ -s /etc/claw/install.url ] || echo "TODO: healthchecks.io ping URL for auto-install in /etc/claw/install.url, root 600 (infra/README.md: Applying infra)"
fi
# redact-sync only once gitbot has a list and the root-only token exists (without them every run
# fails); disabled otherwise, so a re-run of claw-install never turns it on early
if as_user gitbot test -s /home/gitbot/.config/redact.txt && [ -s /etc/claw/redact-sync-token ]; then
  systemctl enable --now claw-redact-sync.timer
  [ -s /etc/claw/redact-sync.url ] || echo "TODO: healthchecks.io ping URL for redact-sync in /etc/claw/redact-sync.url, root 600 (infra/README.md: CI secret from redact.txt)"
else
  systemctl disable --now claw-redact-sync.timer 2>/dev/null || true
  echo "note: claw-redact-sync is off until gitbot has redact.txt and /etc/claw/redact-sync-token exists (optional; infra/README.md: CI secret from redact.txt)"
fi

# (checked as each user, like everything else in their homes)
as_user coder test -s /home/coder/.config/coder.env || echo "TODO: coder read-only GitHub token (README: secrets)"
as_user openclaw grep -q '^HEALTHCHECKS_PING_URL=' /home/openclaw/.openclaw/.env 2>/dev/null || echo "TODO: HEALTHCHECKS_PING_URL in ~/.openclaw/.env (README: dead-man alerts)"
as_user openclaw grep -q '^TELEGRAM_ALLOW_FROM=' /home/openclaw/.openclaw/.env 2>/dev/null || echo "TODO: TELEGRAM_ALLOW_FROM in ~/.openclaw/.env, or Telegram ignores everyone (README: secrets)"
as_user coder test -x /home/coder/.local/bin/claude || echo "TODO: install + log in Claude Code as coder (README)"
[ -s /etc/claw/denywatch.url ] || echo "TODO: healthchecks.io ping URL for broker refusal alerts in /etc/claw/denywatch.url, root 600 (infra/README.md: broker refusal alerts)"
cmp -s acp/package-lock.json "$ACP/package-lock.json" && [ -x "$ACP/node_modules/.bin/claude-agent-acp" ] \
  || echo "TODO: the pinned ACP adapter isn't installed (needs Node/npm; README: Claude Code). Re-run: sudo claw-install"
echo "installed"
