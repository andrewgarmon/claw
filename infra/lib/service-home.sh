# shellcheck shell=bash
# Root and the service users' homes. Sourced by install.sh (as root, from infra/) and used by
# lib/broker-install.sh.
#
# Root never writes, creates or removes anything under a service user's home (openclaw, coder, the
# broker users). Each of those users controls every path in its own home, including which ones are
# symlinks, and tools like install, cp and mkdir follow symlinks. So:
#   - files a service needs from this repo go root-owned under /etc, where the service reads them
#     (systemd user drop-ins in /etc/systemd/user/, coder's CLAUDE.md and Claude Code settings in
#     /etc/claude-code/);
#   - directories in a home are created by that user: as_user <user> install -d -m 700 <dir>;
#   - a file that has to live in a home is written by that user from stdin:
#       as_user <user> install -m 600 /dev/stdin <dest> < <src>
#     so root only ever opens <src>.
# infra/tests/install.test.sh checks this, with a symlink planted at every path below.

# Tests point this at a scratch dir; install.sh unsets it, so on the host every path is absolute.
CLAW_ROOT=${CLAW_ROOT:-}

# as_user <user> <command>...: run a command as <user>, from / (the user can't stat root's cwd)
as_user() { local u=$1; shift; (cd / && sudo -n -u "$u" -- "$@"); }

# coder_home_install: coder's config dirs and caches (created as coder); its CLAUDE.md, installed
# root-owned as Claude Code's managed memory file, and the managed settings that turn hooks, MCP
# servers, plugin marketplaces and auto-memory off for every session (coder can read them, not change
# them). Plus, as coder, the paths in ~/.claude that coder-acp-sandbox binds read-only (a session
# doesn't start without them): a symlink, hard-linked file or the wrong type there is removed
# (systemd binds a symlink's target; a hard link is another, writable name), then empty ones created
# where missing; contents are kept. Claude Code's state file moves into ~/.claude (CLAUDE_CONFIG_DIR,
# coder-acp-run): ~/.claude.json is copied there once.
CODER_PROTECTED=(settings.json settings.local.json CLAUDE.md rules commands agents skills output-styles plugins)
coder_home_install() {
  local R=$CLAW_ROOT C=$CLAW_ROOT/home/coder/.claude f
  as_user coder install -d -m 700 "$R/home/coder/.config" "$C" "$R/home/coder/.cache" "$R/home/coder/.npm" \
    || { echo "install.sh: couldn't create ~coder/.config, .claude, .cache or .npm as coder" >&2; return 1; }
  install -d -m 755 -o root -g root "$R/etc/claude-code"
  install -m 644 -o root -g root coder-CLAUDE.md "$R/etc/claude-code/CLAUDE.md"
  install -m 644 -o root -g root coder-managed-settings.json "$R/etc/claude-code/managed-settings.json"
  coder_protected_all || return 1
  if ! as_user coder test -e "$C/.claude.json" && as_user coder test -f "$R/home/coder/.claude.json" \
     && ! as_user coder test -L "$R/home/coder/.claude.json"; then
    as_user coder cp "$R/home/coder/.claude.json" "$C/.claude.json" \
      || echo "install.sh: couldn't copy ~coder/.claude.json into ~coder/.claude as coder" >&2
  fi
}

# coder_sandbox_migrate: once, after the sandboxed coder-acp is in place (marker in
# /var/lib/claw-install): until then sessions could write the protected paths, and anything they left
# would be locked in and loaded by every session. So stop every coder process (sessions started
# before the sandbox, and whatever they left running), move what's in those paths (if not empty) to
# ~/.claude/pre-sandbox-<time>/, and create them empty. The marker is written last, so a failure
# retries on the next install.
coder_sandbox_migrate() {
  local C=$CLAW_ROOT/home/coder/.claude MARK=$CLAW_ROOT/var/lib/claw-install/coder-claude-moved B f moved
  [ ! -e "$MARK" ] || return 0
  pkill -TERM -u coder || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -u coder >/dev/null || break; sleep 1; done
  pkill -KILL -u coder || true
  coder_protected_all || return 1   # so each is a plain file or dir; empty ones (as on a fresh host) stay
  B=$C/pre-sandbox-$(date +%Y%m%d-%H%M%S) moved=()
  for f in "${CODER_PROTECTED[@]}"; do
    [ -n "$(as_user coder find "$C/$f" -maxdepth 0 -empty)" ] && continue
    case $f in *.json) [ "$(as_user coder cat "$C/$f")" != "{}" ] || continue ;; esac
    [ ${#moved[@]} -gt 0 ] || as_user coder install -d -m 700 "$B" \
      || { echo "install.sh: couldn't create $B as coder" >&2; return 1; }
    as_user coder mv -T "$C/$f" "$B/$f" \
      || { echo "install.sh: couldn't move ~coder/.claude/$f aside as coder" >&2; return 1; }
    moved+=("$f")
  done
  coder_protected_all || return 1
  install -d -m 755 -o root -g root "${MARK%/*}" && install -m 644 -o root -g root /dev/null "$MARK"
  [ ${#moved[@]} = 0 ] || echo "install.sh: moved coder's ~/.claude/{${moved[*]}} to ${B#"$CLAW_ROOT"}/ (sessions could write them until now)"
}

coder_protected_all() {
  local f C=$CLAW_ROOT/home/coder/.claude
  for f in "${CODER_PROTECTED[@]}"; do
    coder_protected "$C/$f" || { echo "install.sh: couldn't set up ~coder/.claude/$f as coder" >&2; return 1; }
  done
}

# coder_protected <path>: as coder, make <path> a real file (*.json, CLAUDE.md) with one link, or a
# directory, not a symlink; an empty one if missing. Existing contents are kept.
coder_protected() {
  local p=$1 t=-d
  case $p in *.json|*.md) t=-f ;; esac
  if as_user coder test -L "$p" || { as_user coder test -e "$p" && ! as_user coder test "$t" "$p"; } \
     || { [ $t = -f ] && as_user coder test -e "$p" && [ "$(as_user coder stat -c %h "$p")" != 1 ]; }; then
    as_user coder rm -rf "$p" || return 1
  fi
  case $p in
    */CLAUDE.md) as_user coder test -e "$p" || as_user coder install -m 600 /dev/null "$p" ;;
    *.json) as_user coder test -e "$p" || printf '{}\n' | as_user coder install -m 600 /dev/stdin "$p" ;;
    *) as_user coder install -d -m 700 "$p" ;;
  esac
}

# gateway_dropins_install: the gateway's systemd drop-ins (gateway-dropins/*.conf), root-owned in
# /etc/systemd/user/. systemd reads a unit's drop-ins from every user unit path, so openclaw's own
# unit in ~/.config/systemd/user/ picks them up. Drop-ins no longer in the repo are removed.
gateway_dropins_install() {
  local R=$CLAW_ROOT f old=()
  local D=/etc/systemd/user/openclaw-gateway.service.d
  local O=/home/openclaw/.config/systemd/user/openclaw-gateway.service.d
  install -d -m 755 -o root -g root "$R$D"
  install -m 644 -o root -g root gateway-dropins/*.conf "$R$D/"
  for f in "$R$D"/*.conf; do
    [ -e "gateway-dropins/${f##*/}" ] || rm -f "$f"
  done
  # the copies older installs put in openclaw's home (a same-named drop-in there would win)
  for f in gateway-dropins/*.conf; do old+=("$R$O/${f##*/}"); done
  as_user openclaw rm -f "${old[@]}" \
    || echo "install.sh: couldn't remove the old drop-ins in ~openclaw/.config/systemd/user/ as openclaw; remove them by hand" >&2
}
