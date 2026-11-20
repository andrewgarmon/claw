# shellcheck shell=bash
# Sourced by install.sh (as root). Installs claw-backup's age public key.
#
# backup_key_install <file>: copy the config repo's backup.age.pub (a recipients file: age1... keys,
# one per line, with optional blank and # comment lines) to /etc/claw/backup.age.pub, root-owned.
# The public key isn't secret, so it can live in the config repo and be added from the GitHub web UI;
# the secret key never does. No file in the repo: what's installed stays (a key placed by hand, or
# none, which prints a TODO). A file that isn't a plain recipients file (a symlink, anything else
# in it, no key at all) is refused and the installed key is left alone.
# CLAW_ROOT (tests only) prefixes the target.
backup_key_install() {
  local src=$1 dir=${CLAW_ROOT:-}/etc/claw dst line keys=0
  dst=$dir/backup.age.pub
  install -d -m 755 -o root -g root "$dir"
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    grep -qE '^age1[0-9a-z]{58}$' "$dst" 2>/dev/null \
      || echo "TODO: age public key for state backups: add backup.age.pub to the config repo (or put it in /etc/claw/backup.age.pub); claw-backup fails until it's there (infra/README.md: state backup)"
    return 0
  fi
  if [ -L "$src" ] || [ ! -f "$src" ]; then
    echo "backup.age.pub in the repo isn't a regular file: not installed" >&2; return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      ''|'#'*) ;;
      *) [[ $line =~ ^age1[0-9a-z]{58}$ ]] || { echo "backup.age.pub in the repo has a line that isn't an age1 public key or a comment: not installed" >&2; return 1; }
         keys=$((keys + 1)) ;;
    esac
  done < "$src"
  [ "$keys" -gt 0 ] || { echo "backup.age.pub in the repo has no age1 public key: not installed" >&2; return 1; }
  cmp -s "$src" "$dst" && return 0
  install -m 644 -o root -g root "$src" "$dst"
  echo "backup key: installed /etc/claw/backup.age.pub from the repo ($keys key(s))"
}
