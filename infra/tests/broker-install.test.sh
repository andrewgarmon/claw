#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc and L are read inside eval'd check strings
# Tests for broker_install (infra/lib/broker-install.sh) with fake adduser/id/getent/install/
# dpkg-query/apt-get/python3, writing under a scratch root (BROKER_ROOT). Checks that the git
# broker installs gitbot exactly as the old hand-written install.sh lines did.
# Touches nothing outside a temp dir. Usage: bash infra/tests/broker-install.test.sh
set -uo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BIN=$T/bin R=$T/root
mkdir -p "$BIN" "$T/users" "$T/pkgs"
export BROKER_ROOT=$R
# shellcheck source=../lib/broker-install.sh
. "$INFRA/lib/broker-install.sh"

fake() { printf '#!/bin/bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
LOGCALL='printf "%s" "$(basename "$0")" >> '"$T/calls"'; printf "[%s]" "$@" >> '"$T/calls"'; echo >> '"$T/calls"
# id <user>: exists?  id -Gn <user>: its groups (4th field of users/<user>, default just its own)
fake id       "if [ \"\$1\" = -Gn ]; then IFS=: read -r _ _ _ g < $T/users/\$2; echo \"\${g:-\$2}\"; else [ -e $T/users/\$1 ]; fi"
# users/<name> holds "uid:home:shell[:groups]"
fake getent   "[ -e $T/users/\$2 ] && IFS=: read -r u h s _ < $T/users/\$2 && echo \"\$2:x:\$u:\$u::\$h:\$s\""
fake adduser  "$LOGCALL; echo 999:/home/\${!#}:/usr/sbin/nologin > $T/users/\${!#}"
fake dpkg-query "[ -e $T/pkgs/\${!#} ] && echo 'install ok installed'"
fake apt-get  "$LOGCALL"
fake visudo   "$LOGCALL; [ -x /usr/sbin/visudo ] && exec /usr/sbin/visudo \"\$@\"; exit 0"
fake python3  "$LOGCALL; [ \"\$1 \$2\" = '-m venv' ] && mkdir -p \"\$3/bin\" && printf '#!/bin/bash\n%s\n' '$LOGCALL' > \"\$3/bin/pip\" && chmod +x \"\$3/bin/pip\""
# install: log the call, then do it without -o/-g
fake install  "$LOGCALL"'
a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done
exec /usr/bin/install "${a[@]}"'
PATH=$BIN:$PATH

fails=0
run() { : > "$T/calls"; broker_install "$@" > "$T/out" 2>&1; rc=$?; }
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out:   /' "$T/out"; sed 's/^/     calls: /' "$T/calls"; fails=$((fails + 1)); fi
}
called() { grep -qxF -- "$1" "$T/calls"; }
calls_to() { grep -c "^$1\[" "$T/calls"; }
says() { grep -qF -- "$1" "$T/out"; }
fresh() { rm -rf "$R" "$T/users"/* "$T/pkgs"/*; mkdir -p "$R/usr/local/bin" "$R/etc/sudoers.d"; }

# ---------- the git broker, on a fresh host ----------
fresh
run "$INFRA/brokers/git"
check "gitbot created as before: system user, own group, /home/gitbot, nologin" \
  eval '[ $rc = 0 ] && called "adduser[--system][--group][--home][/home/gitbot][--shell][/usr/sbin/nologin][gitbot]"'
check "gitbot config dir 700 as before" called "install[-d][-m][700][-o][gitbot][-g][gitbot][$R/home/gitbot/.config]"
check "gh installed when missing" called "apt-get[install][-y][gh]"
check "gitleaks installed when missing" called "apt-get[install][-y][gitleaks]"
check "agent-git installed root:root 755 to /usr/local/bin" \
  eval 'called "install[-m][755][-o][root][-g][root][$INFRA/brokers/git/agent-git][$R/usr/local/bin/]" && cmp -s "$R/usr/local/bin/agent-git" "$INFRA/brokers/git/agent-git"'
check "sudoers generated, visudo-checked, installed 440 as /etc/sudoers.d/agent-git" \
  eval 'grep -q "^visudo\[-cf\]" "$T/calls" && grep -q "^install\[-m\]\[440\]\[-o\]\[root\]\[-g\]\[root\].*\[$R/etc/sudoers.d/agent-git\]$" "$T/calls" && [ "$(sed 1d "$R/etc/sudoers.d/agent-git")" = "$(printf "%s\n" "Defaults!/usr/local/bin/agent-git env_reset, !setenv" "openclaw ALL=(gitbot) NOPASSWD: /usr/local/bin/agent-git" "coder ALL=(gitbot) NOPASSWD: /usr/local/bin/agent-git")" ]'
check "TODO when the secret is missing" says "TODO: gitbot secret /home/gitbot/.config/gh-token"
check "no venv or python for a broker without PYREQS" eval '[ "$(calls_to python3)" = 0 ] && ! called "apt-get[install][-y][python3-venv]"'

# ---------- re-run: user exists, gh and gitleaks installed, secret present ----------
touch "$T/pkgs/gh" "$T/pkgs/gitleaks"; echo tok > "$R/home/gitbot/.config/gh-token"
run "$INFRA/brokers/git"
check "re-run: existing nologin user reused, nothing apt-installed, no TODO" \
  eval '[ $rc = 0 ] && [ "$(calls_to adduser)" = 0 ] && [ "$(calls_to apt-get)" = 0 ] && ! says TODO'

# ---------- refusals ----------
fresh; echo 999:/home/gitbot:/bin/bash > "$T/users/gitbot"
run "$INFRA/brokers/git"
check "existing user with a login shell: refused, nothing installed" \
  eval '[ $rc = 1 ] && says "exists with a login shell (/bin/bash)" && [ "$(calls_to install)" = 0 ] && [ ! -e "$R/etc/sudoers.d/agent-git" ]'
for acct in "65534:/nonexistent:/usr/sbin/nologin" "33:/var/www:/usr/sbin/nologin" "1000:/home/gitbot:/usr/sbin/nologin" "0:/home/gitbot:/usr/sbin/nologin"; do
  fresh; echo "$acct" > "$T/users/gitbot"
  run "$INFRA/brokers/git"
  check "existing non-broker account ($acct): refused, nothing installed" \
    eval '[ $rc = 1 ] && says "isn'"'"'t a broker account" && [ "$(calls_to install)" = 0 ] && [ "$(calls_to adduser)" = 0 ]'
done
fresh; echo "104:/home/gitbot:/usr/sbin/nologin:gitbot adm" > "$T/users/gitbot"
run "$INFRA/brokers/git"
check "existing account in other groups (syslog-style, in adm): refused" \
  eval '[ $rc = 1 ] && says "is in other groups (gitbot adm)" && [ "$(calls_to install)" = 0 ]'

mkdir -p "$T/b/bad"; touch "$T/b/bad/agent-bad" "$T/b/bad/test.sh"
printf 'USER=root\nCALLERS=openclaw\nSECRET=s\n' > "$T/b/bad/broker.conf"
fresh; run "$T/b/bad"
check "invalid broker.conf: refused before any change" eval '[ $rc = 1 ] && says "USER can'"'"'t be root" && [ ! -s "$T/calls" ]'

# ---------- a broker with support files and a venv ----------
B=$T/b/cal; mkdir -p "$B/lib/sub"
printf 'USER=calbot\nCALLERS=openclaw\nSECRET=caldav.env\nPYREQS=requirements.txt\n' > "$B/broker.conf"
printf '#!/bin/bash\n' > "$B/agent-cal"; touch "$B/test.sh"
echo 'print(1)' > "$B/lib/agent_cal.py"; echo x > "$B/lib/sub/data.txt"
printf 'caldav==2.0.1 --hash=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$B/requirements.txt"
fresh; run "$B"
L=$R/usr/local/lib/claw/brokers/cal
check "lib/ files installed root:root 644 under /usr/local/lib/claw/brokers/<name>/" \
  eval '[ $rc = 0 ] && cmp -s "$L/agent_cal.py" "$B/lib/agent_cal.py" && cmp -s "$L/sub/data.txt" "$B/lib/sub/data.txt" && called "install[-m][644][-o][root][-g][root][./agent_cal.py][$L/./agent_cal.py]"'
check "python3-venv apt-installed for PYREQS" called "apt-get[install][-y][python3-venv]"
check "venv built; pip pinned, --no-deps, wheels only, hashes required" \
  eval 'called "python3[-m][venv][$L/venv]" && called "pip[install][-q][--disable-pip-version-check][--require-virtualenv][--no-deps][--only-binary=:all:][--require-hashes][-r][$B/requirements.txt]" && cmp -s "$L/venv/requirements.txt" "$B/requirements.txt"'
run "$B"
check "same requirements: venv left alone" eval '[ $rc = 0 ] && [ "$(calls_to python3)" = 0 ] && [ "$(calls_to pip)" = 0 ]'
printf 'caldav==2.0.2 --hash=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$B/requirements.txt"
run "$B"
check "changed requirements: venv rebuilt" eval '[ $rc = 0 ] && [ "$(calls_to python3)" = 1 ] && [ "$(calls_to pip)" = 1 ]'

# ---------- pruning removed brokers ----------
fresh
hdr() { echo "# generated by claw install.sh from infra/brokers/$1/broker.conf; edit that, not this"; }
{ hdr old; echo "openclaw ALL=(oldbot) NOPASSWD: /usr/local/bin/agent-old"; } > "$R/etc/sudoers.d/agent-old"
touch "$R/usr/local/bin/agent-old"; mkdir -p "$R/usr/local/lib/claw/brokers/old/venv"
echo "openclaw ALL=(x) NOPASSWD: /usr/local/bin/agent-handmade" > "$R/etc/sudoers.d/agent-handmade"
{ hdr git; echo "openclaw ALL=(gitbot) NOPASSWD: /usr/local/bin/agent-git"; } > "$R/etc/sudoers.d/agent-git"
{ hdr other; echo x; } > "$R/etc/sudoers.d/agent-mismatch"
: > "$T/calls"; broker_prune "$INFRA/brokers" > "$T/out" 2>&1; rc=$?
check "prune: a removed broker loses its sudoers grant, wrapper and lib dir" \
  eval '[ $rc = 0 ] && [ ! -e "$R/etc/sudoers.d/agent-old" ] && [ ! -e "$R/usr/local/bin/agent-old" ] && [ ! -e "$R/usr/local/lib/claw/brokers/old" ] && says "removed broker old"'
check "prune: brokers still in git are kept" eval '[ -e "$R/etc/sudoers.d/agent-git" ]'
check "prune: files without the generated header (or for another name) are never touched" \
  eval '[ -e "$R/etc/sudoers.d/agent-handmade" ] && [ -e "$R/etc/sudoers.d/agent-mismatch" ]'

echo; [ $fails = 0 ] && echo "all broker-install tests passed" || { echo "$fails failed"; exit 1; }
