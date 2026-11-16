#!/usr/bin/env bash
# Quick health check for claw. Read-only.
# Usage (as the admin user): claw-status   (installed to /usr/local/bin by claw-install)
# Re-runs itself under sudo, since the journal, gitbot's log and openclaw's user service need it.
set -uo pipefail
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

section() { printf '\n== %s ==\n' "$1"; }

section "services"
printf '%-24s %s\n' "claw-sync.timer" "$(systemctl is-active claw-sync.timer 2>&1)"
oc_uid=$(id -u openclaw 2>/dev/null)
if [ -n "$oc_uid" ]; then
  gw=$(sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$oc_uid systemctl --user is-active openclaw-gateway 2>&1)
else
  gw="no openclaw user"
fi
printf '%-24s %s\n' "openclaw-gateway" "$gw"

section "claw-sync (last 3 log lines)"
journalctl -u claw-sync -n 3 --no-pager -o short-iso 2>&1

section "agent-git.log (last 5 lines)"
tail -n 5 /home/gitbot/agent-git.log 2>&1

section "memory"
free -h
