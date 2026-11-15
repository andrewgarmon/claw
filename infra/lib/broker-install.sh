# shellcheck shell=bash
# Installs brokers from infra/brokers/<name>/. Sourced by install.sh (which runs as root, only from
# claw-install's root-owned clone). See infra/README.md, "Adding a broker".
#
# infra/brokers/<name>/
#   broker.conf       KEY=value data, parsed (never sourced):
#                       USER=calbot                 the user that holds the secret (created, nologin)
#                       CALLERS="openclaw"          who may run the wrapper as USER (openclaw, coder)
#                       SECRET=caldav.env           file name under /home/USER/.config/ (TODO if missing)
#                       DEPS="gh"                   optional apt packages
#                       PYREQS=requirements.txt     optional: one `name==version --hash=sha256:...` line per
#                                                   package (every transitive dep; a --hash per wheel pip may
#                                                   pick), installed into a venv with --no-deps
#                                                   --require-hashes, wheels only
#   agent-<name>      the wrapper, installed root:root 755 to /usr/local/bin/agent-<name>
#   test.sh           its tests, run by CI
#   lib/              optional support files, installed root:root to /usr/local/lib/claw/brokers/<name>/
# Results: /etc/sudoers.d/agent-<name> (generated, visudo-checked), venv at
# /usr/local/lib/claw/brokers/<name>/venv. Each broker needs its own USER (brokers_check), and an
# existing user is only reused if it looks like one this script made (system UID, nologin,
# home /home/USER, no other groups). When a broker dir is removed, broker_prune drops its sudoers grant and wrapper.

# Tests point this at a scratch dir; install.sh unsets it, so on the host every path is absolute.
BROKER_ROOT=${BROKER_ROOT:-}
BROKER_CALLERS_ALLOWED="openclaw coder"
BROKER_USERS_RESERVED="root drew openclaw coder"

# broker_conf <dir>: parse and validate <dir>/broker.conf into B_NAME B_USER B_CALLERS B_SECRET
# B_DEPS B_PYREQS. On any problem sets B_ERR to the reason and returns 1. (Call it directly,
# not in $( ): the values must land in the caller's shell.)
broker_conf() {
  local dir=${1%/} line key val seen=" " c u p
  B_ERR=
  B_NAME=$(basename "$dir") B_USER='' B_CALLERS='' B_SECRET='' B_DEPS='' B_PYREQS=
  [[ $B_NAME =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { B_ERR="bad broker name: $B_NAME"; return 1; }
  [ -f "$dir/broker.conf" ] || { B_ERR="$B_NAME: no broker.conf"; return 1; }
  [ -f "$dir/agent-$B_NAME" ] || { B_ERR="$B_NAME: no wrapper agent-$B_NAME"; return 1; }
  [ -f "$dir/test.sh" ] || { B_ERR="$B_NAME: no test.sh"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ $line =~ ^([A-Z]+)=\"([A-Za-z0-9._+\ -]*)\"$ ]] || [[ $line =~ ^([A-Z]+)=([A-Za-z0-9._+-]*)$ ]]; then
      key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    else
      B_ERR="$B_NAME: bad line in broker.conf: ${line:0:80}"; return 1
    fi
    [[ $seen == *" $key "* ]] && { B_ERR="$B_NAME: $key set twice"; return 1; }
    seen+="$key "
    case $key in
      USER)    B_USER=$val ;;
      CALLERS) B_CALLERS=$val ;;
      SECRET)  B_SECRET=$val ;;
      DEPS)    B_DEPS=$val ;;
      PYREQS)  B_PYREQS=$val ;;
      *) B_ERR="$B_NAME: unknown key $key"; return 1 ;;
    esac
  done < "$dir/broker.conf"

  [[ $B_USER =~ ^[a-z][a-z0-9-]{0,31}$ ]] || { B_ERR="$B_NAME: bad or missing USER: $B_USER"; return 1; }
  for u in $BROKER_USERS_RESERVED; do
    [ "$B_USER" = "$u" ] && { B_ERR="$B_NAME: USER can't be $u"; return 1; }
  done
  [ -n "$B_CALLERS" ] || { B_ERR="$B_NAME: CALLERS missing"; return 1; }
  seen=" "
  for c in $B_CALLERS; do
    [[ " $BROKER_CALLERS_ALLOWED " == *" $c "* ]] || { B_ERR="$B_NAME: caller not allowed: $c (allowed: $BROKER_CALLERS_ALLOWED)"; return 1; }
    [[ $seen == *" $c "* ]] && { B_ERR="$B_NAME: caller listed twice: $c"; return 1; }
    seen+="$c "
  done
  [[ $B_SECRET =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { B_ERR="$B_NAME: bad or missing SECRET (a file name): $B_SECRET"; return 1; }
  for p in $B_DEPS; do
    [[ $p =~ ^[a-z0-9][a-z0-9.+-]{1,62}$ ]] || { B_ERR="$B_NAME: bad apt package in DEPS: $p"; return 1; }
  done
  if [ -n "$B_PYREQS" ]; then
    [[ $B_PYREQS =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && [ -f "$dir/$B_PYREQS" ] \
      || { B_ERR="$B_NAME: PYREQS must name a file in the broker dir: $B_PYREQS"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
      [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
      [[ $line =~ ^[A-Za-z0-9][A-Za-z0-9._-]*==[A-Za-z0-9][A-Za-z0-9.!+_-]*(\ --hash=sha256:[0-9a-f]{64})+$ ]] \
        || { B_ERR="$B_NAME: $B_PYREQS lines must be name==version --hash=sha256:... only: ${line:0:80}"; return 1; }
    done < "$dir/$B_PYREQS"
  fi
  return 0
}

# brokers_check <dir>...: broker_conf on every broker, plus checks across them (each USER used by
# one broker only, so no broker can run as another's user and read its secret). Sets B_ERR.
brokers_check() {
  local b users=" "
  for b in "$@"; do
    broker_conf "$b" || return 1
    [[ $users == *" $B_USER "* ]] && { B_ERR="$B_NAME: USER $B_USER is already used by another broker"; return 1; }
    users+="$B_USER "
  done
  return 0
}

# broker_sudoers: the sudoers file for the broker last parsed by broker_conf
broker_sudoers() {
  local c cmd=/usr/local/bin/agent-$B_NAME
  echo "# generated by claw install.sh from infra/brokers/$B_NAME/broker.conf; edit that, not this"
  echo "Defaults!$cmd env_reset, !setenv"
  for c in $B_CALLERS; do echo "$c ALL=($B_USER) NOPASSWD: $cmd"; done
}

# broker_install <dir>: create the user and config dir, install deps, wrapper, support files,
# venv and sudoers for one broker. Run as root from install.sh's directory.
broker_install() {
  local dir=${1%/} shell uid uhome groups tmp p lib venv R=$BROKER_ROOT home
  broker_conf "$dir" || { echo "install.sh: $B_ERR" >&2; return 1; }
  home=$R/home/$B_USER

  if id "$B_USER" >/dev/null 2>&1; then
    # only reuse a user that looks like one this script made: system UID, nologin, home /home/USER,
    # and no group but its own. Anything else (a human, nobody, www-data, systemd-*, syslog in adm)
    # is someone else's account.
    IFS=: read -r _ _ uid _ _ uhome shell <<< "$(getent passwd "$B_USER")"
    case "$shell" in /usr/sbin/nologin|/sbin/nologin|/bin/false) ;;
      *) echo "install.sh: $B_NAME: user $B_USER exists with a login shell ($shell); not using it" >&2; return 1 ;;
    esac
    if [ "$uhome" != "/home/$B_USER" ] || ! [[ $uid =~ ^[0-9]+$ ]] || [ "$uid" -ge 1000 ] || [ "$uid" -eq 0 ]; then
      echo "install.sh: $B_NAME: user $B_USER already exists and isn't a broker account (uid $uid, home $uhome); pick a new USER" >&2
      return 1
    fi
    groups=$(id -Gn "$B_USER")
    if [ "$groups" != "$B_USER" ]; then
      echo "install.sh: $B_NAME: user $B_USER already exists and is in other groups ($groups); pick a new USER" >&2
      return 1
    fi
  else
    adduser --system --group --home "/home/$B_USER" --shell /usr/sbin/nologin "$B_USER"
  fi
  install -d -m 700 -o "$B_USER" -g "$B_USER" "$home/.config"

  for p in $B_DEPS ${B_PYREQS:+python3-venv}; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || apt-get install -y "$p"
  done

  lib=$R/usr/local/lib/claw/brokers/$B_NAME
  install -d -m 755 -o root -g root "$lib"
  if [ -d "$dir/lib" ]; then
    (cd "$dir/lib" && find . -mindepth 1 -type d -exec install -d -m 755 -o root -g root "$lib/{}" \; \
                   && find . -type f -exec install -m 644 -o root -g root {} "$lib/{}" \;)
  fi
  if [ -n "$B_PYREQS" ]; then
    venv=$lib/venv
    if ! cmp -s "$dir/$B_PYREQS" "$venv/requirements.txt"; then
      rm -rf "$venv"
      python3 -m venv "$venv"
      "$venv/bin/pip" install -q --disable-pip-version-check --require-virtualenv --no-deps \
        --only-binary=:all: --require-hashes -r "$dir/$B_PYREQS"
      install -m 644 -o root -g root "$dir/$B_PYREQS" "$venv/requirements.txt"
    fi
  fi
  install -m 755 -o root -g root "$dir/agent-$B_NAME" "$R/usr/local/bin/"

  tmp=$(mktemp)
  broker_sudoers > "$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; echo "install.sh: $B_NAME: generated sudoers failed visudo" >&2; return 1; }
  install -m 440 -o root -g root "$tmp" "$R/etc/sudoers.d/agent-$B_NAME"
  rm -f "$tmp"

  [ -s "$home/.config/$B_SECRET" ] \
    || echo "TODO: $B_USER secret /home/$B_USER/.config/$B_SECRET (infra/README.md: secrets)"
}

# broker_prune <brokers dir>: for each generated /etc/sudoers.d/agent-<name> whose broker dir is
# gone (removed or renamed in git), remove that grant, its wrapper and its lib dir, so a sudo grant
# never outlives its config. Only touches files carrying the generated header. The user and its
# secret are left alone (deleting a secret is drew's call).
broker_prune() {
  local brokers=${1%/} R=$BROKER_ROOT f name
  for f in "$R"/etc/sudoers.d/agent-*; do
    [ -f "$f" ] || continue
    name=${f##*/agent-}
    [[ $name =~ ^[a-z][a-z0-9-]{0,30}$ ]] || continue
    [ -d "$brokers/$name" ] && continue
    [ "$(head -n1 "$f")" = "# generated by claw install.sh from infra/brokers/$name/broker.conf; edit that, not this" ] || continue
    rm -f "$f" "$R/usr/local/bin/agent-$name"
    # shellcheck disable=SC2115  # R is empty on the host by design; $name is validated above
    rm -rf "$R/usr/local/lib/claw/brokers/$name"
    echo "removed broker $name (sudoers grant, agent-$name, its lib dir); its user and secret are still there, delete by hand if unused"
  done
}
