# shellcheck shell=bash
# Shared helpers for claw brokers (infra/brokers/<name>/agent-<name>). install.sh puts this
# root-owned at /usr/local/lib/claw/broker.sh; wrappers source it by that absolute path only.
# Before sourcing, a wrapper sets PATH and HOME itself (sudo callers mustn't choose them) and:
#   BROKER       its command name, e.g. agent-git (prefix for messages)
#   BROKER_USER  the user it must run as, e.g. gitbot
#   LOG          its log file. Log the caller, the verb and validated arguments: never secrets,
#                never bodies.

# Patterns and lengths mean the same whatever locale the caller's sudo passes through (LC_* survive
# env_reset): [a-z] and [0-9] are ASCII only, and ${#x} counts bytes.
export LC_ALL=C

# broker_log: one line per entry. A refused argument lands here unvalidated, so control characters
# (newlines, escapes) are stripped and the entry is capped at 300 bytes: no forged lines, nothing
# that drives a terminal tailing the log.
broker_log() {
  local entry
  entry=$(printf '%s' "$*" | LC_ALL=C tr -d '\000-\037\177' | head -c 300)
  printf '%s caller=%s %s\n' "$(date -Is)" "${SUDO_USER:-?}" "$entry" >> "$LOG"
}
log() { broker_log "$@"; }
die() { echo "$BROKER: $*" >&2; broker_log "DENY $*"; exit 1; }

# broker_require_user: refuse unless running as $BROKER_USER, i.e. via sudo -u. Checked before
# anything is logged or read, so a direct call can't write the log or touch the secret.
broker_require_user() {
  [ "$(id -un)" = "$BROKER_USER" ] \
    || { echo "$BROKER: must run as $BROKER_USER (sudo -u $BROKER_USER $BROKER ...)" >&2; exit 1; }
}

# broker_secret_raw <file> <VAR>: a one-line secret file (e.g. a token) into exported VAR.
# Read into a variable, never passed as an argument, so it never shows in ps.
broker_secret_raw() {
  [ -r "$1" ] && [ -s "$1" ] || die "secret file missing or empty: $1 (infra/README.md: secrets)"
  local v; v=$(head -n1 "$1")
  printf -v "$2" '%s' "$v"; export "${2?}"
}

# broker_secret_env <file> <KEY>...: KEY=value lines into exported variables. The file is parsed,
# never sourced. Every listed KEY is required unless written KEY? (optional, may be absent).
broker_secret_env() {
  local f=$1 k opt line; shift
  [ -r "$f" ] || die "secret file missing: $f (infra/README.md: secrets)"
  for k in "$@"; do
    opt=; [[ $k == *\? ]] && { opt=1; k=${k%\?}; }
    line=$(grep -m1 "^$k=" "$f") || { [ -n "$opt" ] && continue; die "$k missing from $f"; }
    printf -v "$k" '%s' "${line#*=}"; export "${k?}"
  done
}

# broker_read_stdin <max_chars> <what>: stdin into $body, trailing newlines dropped. A terminal
# on stdin counts as no input. Reads at most 4 bytes per allowed char (UTF-8), so overlong input
# is still caught without reading unbounded data.
broker_read_stdin() {
  body=
  if [ ! -t 0 ]; then body=$(head -c $(( $1 * 4 + 1 ))); fi
  [ ${#body} -le "$1" ] || die "$2 too long (max $1)"
}

# broker_valid_line <max_chars> <value>: non-empty, at most max chars, no control characters
# (so no newlines). For names and titles that end up in logs or other tools' arguments.
broker_valid_line() { [ -n "$2" ] && [ ${#2} -le "$1" ] && [[ "$2" != *[[:cntrl:]]* ]]; }
