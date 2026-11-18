# shellcheck shell=bash
# Root and the service users' homes. Sourced by install.sh (as root, from infra/) and used by
# lib/broker-install.sh.
#
# Root never writes, creates or removes anything under a service user's home (openclaw, coder, the
# broker users). Each of those users controls every path in its own home, including which ones are
# symlinks, and tools like install, cp and mkdir follow symlinks. So:
#   - files a service needs from this repo go root-owned under /etc, where the service reads them
#     (systemd user drop-ins in /etc/systemd/user/, coder's CLAUDE.md in /etc/claude-code/);
#   - directories in a home are created by that user: as_user <user> install -d -m 700 <dir>;
#   - a file that has to live in a home is written by that user from stdin:
#       as_user <user> install -m 600 /dev/stdin <dest> < <src>
#     so root only ever opens <src>.
# infra/tests/install.test.sh checks this, with a symlink planted at every path below.

# Tests point this at a scratch dir; install.sh unsets it, so on the host every path is absolute.
CLAW_ROOT=${CLAW_ROOT:-}

# as_user <user> <command>...: run a command as <user>, from / (the user can't stat root's cwd)
as_user() { local u=$1; shift; (cd / && sudo -n -u "$u" -- "$@"); }

# coder_home_install: coder's config dirs (created as coder) and its CLAUDE.md, installed root-owned
# as Claude Code's managed memory file. Every coder session loads it; coder can read it, not change it.
coder_home_install() {
  local R=$CLAW_ROOT
  as_user coder install -d -m 700 "$R/home/coder/.config" "$R/home/coder/.claude" \
    || { echo "install.sh: couldn't create ~coder/.config and ~coder/.claude as coder" >&2; return 1; }
  install -d -m 755 -o root -g root "$R/etc/claude-code"
  install -m 644 -o root -g root coder-CLAUDE.md "$R/etc/claude-code/CLAUDE.md"
  # the copy older installs put in coder's home
  as_user coder rm -f "$R/home/coder/.claude/CLAUDE.md" \
    || echo "install.sh: couldn't remove ~coder/.claude/CLAUDE.md as coder; remove it by hand" >&2
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
