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

section "infra install"
inst=$(head -c 40 /var/lib/claw-install/last 2>/dev/null)
printf '%-24s %s\n' "installed (claw-install)" "${inst:-unknown}"
# agent-writable (openclaw owns it): read as openclaw, so root never follows a planted symlink, and
# strip control characters, so it can't send escape sequences to this terminal
pend=/home/openclaw/.cache/claw-sync/infra-pending
p=$(cd / && sudo -u openclaw sed -n '3,$p' "$pend" 2>/dev/null | LC_ALL=C tr -d '\000-\010\013-\037\177')
if [ -n "$p" ]; then
  echo "merged but not installed (as of the last full claw-sync run; run sudo claw-install):"
  printf '%s\n' "$p" | sed 's/^/  /'
else
  echo "nothing pending (as of the last full claw-sync run)"
fi

section "claw-sync (last 3 log lines)"
journalctl -u claw-sync -n 3 --no-pager -o short-iso 2>&1

section "broker refusals (DENY lines, last 24h; claw-smoke's included)"
since=$(date -Is -d '-24 hours')
while read -r name log; do
  [ -f "$log" ] || continue
  printf '%-24s %s\n' "$name" "$(awk -v s="$since" '$1 >= s && / DENY /' "$log" "$log.1" 2>/dev/null | wc -l)"
done < /usr/local/lib/claw/broker-logs 2>/dev/null
printf '%-24s %s\n' "claw-denywatch.timer" "$(systemctl is-active claw-denywatch.timer 2>&1)"

section "agent-git.log (last 5 lines)"
tail -n 5 /home/gitbot/agent-git.log 2>&1

section "memory"
free -h
