#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # check strings are eval'd (and read rc, probe there)
# Tests for infra/coder-acp (hand-over), infra/coder-acp-sandbox (the systemd sandbox it starts) and
# how they agree with the probe, install.sh and the sudo rules, with fake systemd-run, sudo and id.
# The sandbox itself only exists on the host: claw-smoke's coder-sandbox check runs the probe there.
# Usage: bash infra/tests/coder-acp-sandbox.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T=$(realpath "$T")
BIN=$T/bin W=$T/work S=$T/coder-acp-sandbox
mkdir -p "$BIN" "$W/repo" "$T/elsewhere"
ln -s "$T/elsewhere" "$W/link-out"
sed -e "s|^export PATH=.*|export PATH=$BIN:/usr/bin:/bin|" -e "s|^WORK=.*|WORK=$W|" "$INFRA/coder-acp-sandbox" > "$S"
[ "$(grep -c "$T" "$S")" = 2 ] || { echo "FAIL could not point coder-acp-sandbox at the test dir"; exit 1; }
printf '#!/bin/bash\n[ "$1" = -u ] && { [ -e %s/not_root ] && echo 1000 || echo 0; }\n' "$T" > "$BIN/id"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > %s/args\n' "$T" > "$BIN/systemd-run"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > %s/sudo-args\n' "$T" > "$BIN/sudo"
chmod +x "$BIN"/* "$S"

fails=0
run() { rm -f "$T/args"; (cd "$1" && shift && bash "$S" "$@") > "$T/out" 2>&1; rc=$?; }
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out:  /' "$T/out"; [ -e "$T/args" ] && sed 's/^/     args: /' "$T/args"; fails=$((fails + 1)); fi
}
arg() { grep -qxF -- "$1" "$T/args"; }
# list <array>: an array of coder-acp-sandbox (its constants are plain assignments), one element per line
list() { bash -c '. <(sed -n "/^H=/,/^cmd=/p" "$2" | sed "\$d"); printf "%s\n" "${'"$1"'[@]}"' _ "$1" "$INFRA/coder-acp-sandbox"; }

run "$W/repo"
check "runs coder-acp-run as coder through systemd-run, with the caller's stdio, waiting for it" \
  eval '[ $rc = 0 ] && arg User=coder && arg Group=coder && arg --pipe && arg --wait && [ "$(tail -n1 "$T/args")" = /usr/local/lib/claw/coder-acp-run ]'
check "read-only system and home, private /tmp" eval 'arg ProtectSystem=strict && arg ProtectHome=read-only && arg PrivateTmp=yes'
check "the session works in the caller's repo" eval 'arg "WorkingDirectory=$W/repo"'
check "no option that implies NoNewPrivileges (agent-git needs sudo)" \
  eval '! grep -qE "^(NoNewPrivileges|PrivateDevices|RestrictSUIDSGID|LockPersonality|ProtectClock|ProtectHostname|ProtectKernelModules|ProtectKernelLogs|RestrictNamespaces|SystemCallFilter|MemoryDenyWriteExecute|RestrictAddressFamilies|RestrictRealtime|SystemCallArchitectures)=" "$T/args"'
for p in $(list PROTECTED); do
  check "read-only on top: ${p#/home/coder/}" arg "ReadOnlyPaths=$p"
done
check "writable: /srv/work, Claude Code's session data" \
  eval 'arg "ReadWritePaths=$W" && arg ReadWritePaths=/home/coder/.claude && arg ReadWritePaths=/home/coder/.claude.json'
for conf in "$INFRA"/brokers/*/broker.conf; do
  callers=$(sed -n 's/^CALLERS="\(.*\)"/\1/p' "$conf"); u=$(sed -n 's/^USER=//p' "$conf")
  case " $callers " in *" coder "*) check "broker $u (coder may call it, so it runs in the sandbox): its home is writable" arg "ReadWritePaths=/home/$u" ;; esac
done

run "$T/elsewhere"
check "called from outside /srv/work: works in /srv/work" eval '[ $rc = 0 ] && arg "WorkingDirectory=$W"'
run "$W/link-out"
check "a symlink in /srv/work pointing outside: resolved, so /srv/work" eval '[ $rc = 0 ] && arg "WorkingDirectory=$W"'
run "$W/repo" --check
check "--check runs the probe in the same sandbox" \
  eval '[ $rc = 0 ] && [ "$(tail -n1 "$T/args")" = /usr/local/lib/claw/coder-sandbox-probe ] && arg ProtectHome=read-only'
run "$W/repo" /bin/sh
check "any other argument: refused, nothing started" eval '[ $rc = 2 ] && [ ! -e "$T/args" ]'
touch "$T/not_root"; run "$W/repo"
check "not root: refused, nothing started" eval '[ $rc = 1 ] && [ ! -e "$T/args" ]'
rm "$T/not_root"

# coder-acp: nothing but the hand-over
sed "s|^export PATH=.*|export PATH=$BIN:/usr/bin:/bin|" "$INFRA/coder-acp" > "$T/coder-acp"
bash "$T/coder-acp" > "$T/out" 2>&1
check "coder-acp hands over to the sandbox: sudo -n, no arguments" eval '[ "$(cat "$T/sudo-args")" = "$(printf -- "-n\n/usr/local/sbin/coder-acp-sandbox")" ]'

# they agree with each other
probe=$(sed -n 's/^for p in \(.*\); do$/\1/p' "$INFRA/coder-sandbox-probe" | tr ' ' '\n' | sed 's|^|/home/coder/.claude/|')
check "the probe checks every read-only path" eval '[ "$(list PROTECTED | sort)" = "$(sort <<< "$probe")" ]'
made=$(grep -oE '\$C/[A-Za-z.-]+|\$R/home/coder/\.claude\.json' "$INFRA/lib/service-home.sh" | sed 's|^\$C/|/home/coder/.claude/|; s|^\$R||' | sort -u)
for p in $(list PROTECTED) /home/coder/.claude.json; do
  check "install.sh creates ${p#/home/coder/} (the sandbox won't start without it)" grep -qxF -- "$p" <<< "$made"
done
check "sudoers: coder may run only the sandbox as root, with no arguments" \
  grep -qxF 'coder ALL=(root) NOPASSWD: /usr/local/sbin/coder-acp-sandbox ""' "$INFRA/coder.sudoers"
VISUDO=$(command -v visudo || { [ -x /usr/sbin/visudo ] && echo /usr/sbin/visudo; } || true)
if [ -n "$VISUDO" ]; then check "coder.sudoers passes visudo" "$VISUDO" -cf "$INFRA/coder.sudoers"; else echo "skip visudo (not installed)"; fi

echo; [ $fails = 0 ] && echo "all coder-acp-sandbox tests passed" || { echo "$fails failed"; exit 1; }
