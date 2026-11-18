#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc is read inside eval'd check strings
# Tests for infra/smoke.sh (claw-smoke) with fake sudo, systemctl, id, coder-acp, agent-git,
# agent-cal and openclaw. Touches nothing outside a temp dir. Usage: bash infra/tests/smoke.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BIN=$T/bin OC=$T/openclaw SM=$T/claw-smoke
SECRET=ghp_SmokeTestSecretAAAAAAAAAAAAAAAAAAAAAA   # fakes print this on stderr; claw-smoke must never show it
mkdir -p "$BIN" "$OC/.npm-global/bin" "$T/lib" "$T/calbot"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export CLAW_SMOKE_WAIT=3

sed -e "s|^export PATH=.*|export PATH=$BIN:/usr/local/bin:/usr/bin:/bin|" \
    -e "s|^ACP_LOCK=.*|ACP_LOCK=$T/lib/package-lock.json|" \
    -e "s|^CODER_ACP=.*|CODER_ACP=$BIN/coder-acp|" \
    -e "s|^CLAUDE_USAGE=.*|CLAUDE_USAGE=$BIN/claude-usage|" \
    -e "s|^AGENT_GIT=.*|AGENT_GIT=$BIN/agent-git|" \
    -e "s|^AGENT_CAL=.*|AGENT_CAL=$BIN/agent-cal|" \
    -e "s|^CAL_SECRET=.*|CAL_SECRET=$T/calbot/caldav.env|" \
    -e "s|^OC_HOME=.*|OC_HOME=$OC|" \
    -e "s|^OC_PLUGINS=.*|OC_PLUGINS=$T/ocp|" "$INFRA/smoke.sh" > "$SM"
[ "$(grep -c "$T" "$SM")" = 9 ] || { echo "FAIL could not point claw-smoke at the test dir (did its constants change?)"; exit 1; }

cat > "$T/lib/package-lock.json" <<'EOF'
{"name": "claw-acp-adapter", "lockfileVersion": 3,
 "packages": {"node_modules/@agentclientprotocol/claude-agent-acp": {"version": "0.107.3"}}}
EOF

# fake sudo: sudo [-n] [-H] -u USER cmd...; records the chain so brokers can see their caller
cat > "$BIN/sudo" <<EOF
#!/bin/bash
u=
while [ \$# -gt 0 ]; do case "\$1" in -n|-H) shift ;; -u) u=\$2; shift 2 ;; *) break ;; esac; done
echo "\${FAKE_AS:-root} -> \$u: \$1" >> "$T/sudo.log"
export FAKE_CALLER=\${FAKE_AS:-root} FAKE_AS=\$u
exec "\$@"
EOF
cat > "$BIN/id" <<'EOF'
#!/bin/bash
case "$*" in "-u") echo 0 ;; "-u openclaw") echo 1001 ;; *) exit 1 ;; esac
EOF
# fake ACP adapter: answers initialize with $T/acp_version (default 0.107.3)
cat > "$BIN/coder-acp" <<EOF
#!/bin/bash
echo "token=$SECRET" >&2
[ "\$FAKE_CALLER" = openclaw ] && [ "\$FAKE_AS" = coder ] || { echo "sudo: not allowed" >&2; exit 1; }
[ -e "$T/acp_fail" ] && exit 1
read -r line
[ -e "$T/acp_hang" ] && sleep 30
echo "\$line" | grep -q '"method":"initialize"' || exit 1
v=\$(cat "$T/acp_version" 2>/dev/null || echo 0.107.3)
[ -e "$T/acp_noinfo" ] && { echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'; exit 0; }
echo '{"jsonrpc":"2.0","method":"noise"}'
echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"name\":\"x\",\"version\":\"\$v\"}}}"
EOF
# fake claude-usage: JSON like the real one; $T/usage_unavailable -> exit 3, $T/usage_bad -> exit 1
cat > "$BIN/claude-usage" <<EOF
#!/bin/bash
[ "\$FAKE_CALLER" = openclaw ] && [ "\$FAKE_AS" = coder ] && [ "\$1" = --fresh ] || exit 1
echo "token=$SECRET" >&2
[ -e "$T/usage_unavailable" ] && exit 3
[ -e "$T/usage_bad" ] && { echo '{"seven_day":null}'; exit 0; }
echo '{"subscription_type":"pro","five_hour":{"utilization":36,"resets_at":"x"},"seven_day":{"utilization":43,"resets_at":"y"}}'
EOF
# fake agent-git: issue-list (fails while $T/token_bad), pr refusals like the real one (unless $T/no_refuse)
cat > "$BIN/agent-git" <<EOF
#!/bin/bash
echo "using $SECRET" >&2
[ "\$FAKE_AS" = gitbot ] || exit 1
echo "\$FAKE_CALLER \$*" >> "$T/agent-git.log"
case "\$1" in
  issue-list) [ -e "$T/token_bad" ] && { echo "HTTP 401 $SECRET" >&2; exit 1; }; echo '[{"number":1,"title":"x"}]' ;;
  pr) [ -t 0 ] && exit 1; [ -e "$T/no_refuse" ] && exit 0
      if [ "\$2" = claw-state ] && [[ "\$3" != agent/state/* ]]; then echo "agent-git: state backups go to claw-state on agent/state/<host>, and claw-state takes nothing else" >&2; exit 1; fi
      if [ "\$2" = claw-state ] && [ "\$FAKE_CALLER" != openclaw ]; then echo "agent-git: only claw-backup (openclaw) pushes state backups" >&2; exit 1; fi
      exit 0 ;;
  *) exit 2 ;;
esac
EOF
cat > "$BIN/agent-cal" <<EOF
#!/bin/bash
[ "\$FAKE_CALLER" = openclaw ] && [ "\$FAKE_AS" = calbot ] || exit 1
[ "\$1" = calendars ] || { echo "only calendars is read-only" >&2; echo "\$*" >> "$T/cal-writes"; exit 1; }
[ -e "$T/cal_bad" ] && { echo "401 $SECRET" >&2; exit 1; }
echo '[{"name":"Home"}]'
EOF
cat > "$BIN/systemctl" <<EOF
#!/bin/bash
t=\${*: -1}
case "\$1" in
  is-enabled|is-active) [ ! -e "$T/off_\$t" ] ;;
  show) [ -e "$T/running_\$t" ] && echo activating || echo inactive ;;
  list-timers) if [ -e "$T/nonext_\$t" ]; then echo "- - Mon 2026-11-16 03:30:00 UTC 1h ago \$t x.service"
               else echo "Tue 2026-11-17 02:16:03 UTC 42s Tue 2026-11-17 02:15:03 UTC 18s ago \$t x.service"; fi ;;
  *) exit 2 ;;
esac
EOF
# fake openclaw: gateway health ($T/gw_down: no answer); plugins list --json --enabled prints $T/plugins.json
cat > "$OC/.npm-global/bin/openclaw" <<EOF
#!/bin/bash
[ "\$FAKE_AS" = openclaw ] && [ "\$XDG_RUNTIME_DIR" = /run/user/1001 ] || exit 1
echo "token=$SECRET" >&2
case "\$*" in
  "gateway health --timeout 10000") [ ! -e "$T/gw_down" ] ;;
  "plugins list --json --enabled") [ ! -e "$T/plugins_fail" ] && cat "$T/plugins.json" ;;
  *) exit 2 ;;
esac
EOF
# root-owned plugin dir with duckduckgo; the registry reports it enabled from there
mkdir -p "$T/ocp/duckduckgo/node_modules/@openclaw/duckduckgo-plugin" "$T/ocp/leftover.new"
plugins_json() {  # plugins_json <duckduckgo rootDir> [extra plugin JSON objects, comma-led]
  printf '{"workspaceDir":"/x","plugins":[{"id":"telegram","enabled":true,"origin":"bundled","rootDir":"/b/telegram"},{"id":"duckduckgo","enabled":true,"origin":"config","rootDir":"%s"}%s]}\n' "$1" "${2:-}" > "$T/plugins.json"
}
plugins_json "$T/ocp/duckduckgo/node_modules/@openclaw/duckduckgo-plugin"
chmod +x "$BIN"/* "$OC/.npm-global/bin/openclaw"

# ~/.openclaw: a clone of a scratch origin, so HEAD vs origin/main can be checked
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/dev" 2>/dev/null
echo '{"plugins":{"allow":["duckduckgo","telegram"]}}' > "$T/dev/openclaw.json"
git -C "$T/dev" checkout -q -b main && git -C "$T/dev" add -A && git -C "$T/dev" commit -q -m one && git -C "$T/dev" push -q origin main 2>/dev/null
git clone -q "$T/origin.git" "$OC/.openclaw"
echo "APPLE_ID=x" > "$T/calbot/caldav.env"

fails=0
run() { : > "$T/sudo.log"; bash "$SM" > "$T/out" 2>&1; rc=$?; }
check() {  # check <name> <condition...>; every run must keep secrets out of the output
  local name=$1; shift
  if "$@" && ! grep -q "$SECRET" "$T/out"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails + 1)); fi
}
says() { grep -q -- "$1" "$T/out"; }   # basic regex: "." stands in for apostrophes

run
check "all good: every check passes, exit 0" \
  eval '[ $rc = 0 ] && says "PASS acp-adapter" && says "PASS agent-git-token" && says "PASS agent-git-refusals" && says "PASS timers" && says "PASS gateway" && says "PASS agent-cal" && says "PASS claude-usage" && says "PASS plugins" && says "all 8 checks passed"'
check "ACP adapter runs as openclaw -> coder, the way acpx does" eval 'grep -q "^openclaw -> coder: $BIN/coder-acp" "$T/sudo.log"'
check "claude-usage runs as openclaw -> coder, fresh" eval 'grep -q "^openclaw -> coder: $BIN/claude-usage" "$T/sudo.log"'
check "refusals are tried as coder and as openclaw, never as root" \
  eval 'grep -q "^coder pr claw-state agent/state/claw-smoke" "$T/agent-git.log" && grep -q "^openclaw pr claw-state claude/claw-smoke" "$T/agent-git.log" && ! grep -q "^root " "$T/agent-git.log"'
check "agent-cal: only the read-only verb" eval '[ ! -e "$T/cal-writes" ]'

echo 0.106.0 > "$T/acp_version"
run; check "wrong adapter version: FAIL with both versions, exit 1" \
  eval '[ $rc = 1 ] && says "FAIL acp-adapter: adapter is 0.106.0 but the lockfile pins 0.107.3" && says "1 of 8 checks FAILED"'
echo '1.0; rm -rf /' > "$T/acp_version"
run; check "odd version string isn't echoed" eval '[ $rc = 1 ] && says "no usable agent version" && ! says "rm -rf"'
rm "$T/acp_version"
touch "$T/acp_fail"
run; check "adapter won't start: FAIL, no reply" eval '[ $rc = 1 ] && says "FAIL acp-adapter: no initialize reply (exit 1)"'
rm "$T/acp_fail"; touch "$T/acp_hang"
run; check "adapter hangs: FAIL after the timeout" eval '[ $rc = 1 ] && says "FAIL acp-adapter: no initialize reply (timed out after 3s)"'
rm "$T/acp_hang"; touch "$T/acp_noinfo"
run; check "reply without agentInfo: FAIL" eval '[ $rc = 1 ] && says "FAIL acp-adapter: initialize reply has no usable agent version"'
rm "$T/acp_noinfo"
mv "$T/lib/package-lock.json" "$T/lib/lock.bak"
run; check "ACP not installed (no lockfile): FAIL" eval '[ $rc = 1 ] && says "FAIL acp-adapter: can.t read the pinned version"'
mv "$T/lib/lock.bak" "$T/lib/package-lock.json"

touch "$T/usage_unavailable"
run; check "claude-usage without plan limits (exit 3): SKIP, still passes" \
  eval '[ $rc = 0 ] && says "SKIP claude-usage: plan limits unavailable" && says "all 7 checks passed (1 skipped)"'
rm "$T/usage_unavailable"; touch "$T/usage_bad"
run; check "claude-usage without a weekly number: FAIL" eval '[ $rc = 1 ] && says "FAIL claude-usage: no usable answer (exit 0)"'
rm "$T/usage_bad"; chmod -x "$BIN/claude-usage"
run; check "claude-usage not runnable: FAIL" eval '[ $rc = 1 ] && says "FAIL claude-usage: no usable answer"'
chmod +x "$BIN/claude-usage"

touch "$T/token_bad"
run; check "gitbot token revoked: FAIL, points at the log, no secret" \
  eval '[ $rc = 1 ] && says "FAIL agent-git-token: issue-list on claw-config failed (exit 1)" && says "agent-git.log"'
rm "$T/token_bad"

touch "$T/no_refuse"
run; check "agent-git stops refusing: FAIL names both" \
  eval '[ $rc = 1 ] && says "FAIL agent-git-refusals: coder.s state-backup push wasn.t refused as expected; a claude/. push to claw-state"'
rm "$T/no_refuse"

touch "$T/off_claw-backup.timer"
run; check "timer disabled: FAIL" eval '[ $rc = 1 ] && says "FAIL timers: claw-backup.timer isn.t enabled and active"'
rm "$T/off_claw-backup.timer"; touch "$T/nonext_claw-sync.timer"
run; check "timer with no next run: FAIL" eval '[ $rc = 1 ] && says "FAIL timers: claw-sync.timer has no next run"'
touch "$T/running_claw-sync.service"
run; check "no next run while its service is running (just fired): PASS" eval '[ $rc = 0 ] && says "PASS timers"'
rm "$T/running_claw-sync.service" "$T/nonext_claw-sync.timer"

git -C "$T/dev" commit -q --allow-empty -m two && git -C "$T/dev" push -q origin main 2>/dev/null && git -C "$OC/.openclaw" fetch -q
run; check "deploy pending (HEAD behind origin/main): FAIL" eval '[ $rc = 1 ] && says "FAIL gateway:" && says "a deploy is pending"'
git -C "$OC/.openclaw" merge -q --ff-only origin/main
touch "$T/gw_down"
run; check "gateway not answering: FAIL" eval '[ $rc = 1 ] && says "FAIL gateway: openclaw gateway health didn.t answer"'
rm "$T/gw_down"

touch "$T/cal_bad"
run; check "calendar password broken: FAIL" eval '[ $rc = 1 ] && says "FAIL agent-cal: listing calendars failed"'
rm "$T/cal_bad" "$T/calbot/caldav.env"
run; check "no CalDAV secret: SKIP, still passes" eval '[ $rc = 0 ] && says "SKIP agent-cal: no CalDAV secret yet" && says "all 7 checks passed (1 skipped)"'
mv "$BIN/agent-cal" "$T/agent-cal.off"
run; check "cal broker not installed: SKIP" eval '[ $rc = 0 ] && says "SKIP agent-cal: broker not installed"'
mv "$T/agent-cal.off" "$BIN/agent-cal"

touch "$T/token_bad" "$T/gw_down"
run; check "several failures: each listed, count in the last line" \
  eval '[ $rc = 1 ] && says "FAIL agent-git-token" && says "FAIL gateway" && [ "$(tail -n1 "$T/out")" = "claw-smoke: 2 of 7 checks FAILED" ]'
rm "$T/token_bad" "$T/gw_down"

# plugins
plugins_json "$T/ocp/duckduckgo/node_modules/@openclaw/duckduckgo-plugin" ',{"id":"evil","enabled":true,"origin":"global","rootDir":"/x/evil"},{"id":"off","enabled":false,"origin":"global"}'
run; check "an enabled plugin not in plugins.allow: FAIL naming it (disabled ones don't count)" \
  eval '[ $rc = 1 ] && says "FAIL plugins: evil isn.t in plugins.allow" && ! says "off isn"'
plugins_json "$T/ocp/duckduckgo/node_modules/@openclaw/duckduckgo-plugin" ',{"id":"telegram","enabled":true,"origin":"workspace","rootDir":"/w/telegram"}'
run; check "a plugin loaded from the workspace: FAIL" eval '[ $rc = 1 ] && says "FAIL plugins: telegram loads from the workspace"'
plugins_json "$OC/.openclaw/extensions/duckduckgo"
run; check "root-owned plugin enabled from somewhere else: FAIL" eval '[ $rc = 1 ] && says "FAIL plugins: duckduckgo isn.t enabled from $T/ocp/duckduckgo"'
plugins_json "$T/ocp/duckduckgo/node_modules/@openclaw/duckduckgo-plugin" ',{"id":"x;rm -rf $(id)","enabled":true,"origin":"global"}'
run; check "an odd plugin id is never echoed" eval '[ $rc = 1 ] && says "<odd id> isn.t in plugins.allow" && ! says "rm -rf"'
plugins_json "$T/ocp/duckduckgo/node_modules/@openclaw/duckduckgo-plugin"; touch "$T/plugins_fail"
run; check "plugins list fails: FAIL" eval '[ $rc = 1 ] && says "FAIL plugins: openclaw plugins list failed"'
rm "$T/plugins_fail"
run; check "plugins back to normal: PASS (a leftover .new dir is ignored)" eval '[ $rc = 0 ] && says "PASS plugins"'

printf '#!/bin/bash\necho 1000\n' > "$BIN/id"
run; check "not root: refused" eval '[ $rc = 1 ] && says "run with sudo" && [ ! -s "$T/sudo.log" ]'

echo; [ $fails = 0 ] && echo "all claw-smoke tests passed" || { echo "$fails failed"; exit 1; }
