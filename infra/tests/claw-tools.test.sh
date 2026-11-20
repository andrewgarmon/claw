#!/usr/bin/env bash
# Tests for the claw-tools OpenClaw plugin (infra/openclaw-plugins/claw-tools/tools.js) with node's
# test runner and a fake sudo that records argv and stdin. Needs node 20+.
# Touches nothing outside a temp dir. Usage: bash infra/tests/claw-tools.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$INFRA/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v node >/dev/null || { echo "node not found"; exit 1; }
# fake sudo: argv NUL-separated to $T/argv, stdin to $T/stdin, its env to $T/env; then sleeps
# $T/sleep seconds, prints $T/out and $T/err, exits $T/rc (default 0)
cat > "$T/sudo" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" > "$T/argv"
cat > "$T/stdin"
echo "PATH=$PATH LANG=$LANG HOME=${HOME:-unset}" > "$T/env"
# $T/term: record SIGTERM in $T/signals and exit; $T/ignoreterm: ignore it (only SIGKILL stops it)
[ -e "$T/term" ] && trap 'echo TERM >> "$T/signals"; exit 143' TERM
[ -e "$T/ignoreterm" ] && trap '' TERM
[ -e "$T/sleep" ] && { sleep "$(cat "$T/sleep")" & wait $!; }
[ -e "$T/out" ] && cat "$T/out"
[ -e "$T/err" ] && cat "$T/err" >&2
exit "$(cat "$T/rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/sudo"
node --check "$INFRA/openclaw-plugins/claw-tools/index.js" || { echo "FAIL index.js doesn't parse"; exit 1; }
export T REPO FAKE_SUDO=$T/sudo
node --test --test-reporter=spec "$INFRA/tests/claw-tools/tools.test.mjs"
