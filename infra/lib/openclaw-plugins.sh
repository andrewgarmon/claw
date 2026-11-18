# shellcheck shell=bash
# Root-owned OpenClaw plugins. Sourced by install.sh (as root, from infra/).
#
# infra/openclaw-plugins/<id>/ is one plugin the gateway loads through plugins.load.paths in
# openclaw.json: either its source, or a package.json + package-lock.json that pins an npm package
# (installed with npm ci --ignore-scripts; the plugin root is then node_modules/<package>). <id> is
# the plugin id. Each is installed root-owned to /usr/local/lib/claw/openclaw-plugins/<id>, so the
# agent's user can run the code but not change it. A configured load path has the highest discovery
# precedence, so a copy with the same id in an extensions dir can't take its place.
# Reinstalled only when the source changes; built in <id>.new and swapped in, so a failed install
# leaves the previous one working. A plugin dir removed from the repo is removed here too.
# infra/tests/openclaw-plugins.test.sh covers this.

# Tests point this at a scratch dir; install.sh unsets it, so on the host every path is absolute.
CLAW_ROOT=${CLAW_ROOT:-}
OC_PLUGINS=/usr/local/lib/claw/openclaw-plugins

# oc_plugin_src_hash <dir>: one hash over the names and contents of every file in a plugin's source
oc_plugin_src_hash() {
  (cd "$1" && find . -type f -not -path './node_modules/*' -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)
}

# oc_plugins_install <dir>: install every <dir>/<id>/ and remove installed plugins no longer there
oc_plugins_install() {
  local src=${1%/} R=$CLAW_ROOT d id dst new h
  install -d -m 755 -o root -g root "$R/usr/local/lib/claw" "$R$OC_PLUGINS"
  for d in "$src"/*/; do
    [ -d "$d" ] || continue
    id=$(basename "$d")
    [[ $id =~ ^[a-z][a-z0-9-]{0,63}$ ]] || { echo "install.sh: bad OpenClaw plugin dir name: $id" >&2; return 1; }
    dst=$R$OC_PLUGINS/$id new=$R$OC_PLUGINS/$id.new
    h=$(oc_plugin_src_hash "$d")
    [ -f "$dst/.claw-source-sha256" ] && [ "$(cat "$dst/.claw-source-sha256")" = "$h" ] && continue
    rm -rf "$new"
    install -d -m 755 -o root -g root "$new"
    (cd "$d" && find . -mindepth 1 -type d -not -path './node_modules' -not -path './node_modules/*' -exec install -d -m 755 -o root -g root "$new/{}" \; \
             && find . -type f -not -path './node_modules/*' -exec install -m 644 -o root -g root {} "$new/{}" \;)
    if [ -f "$new/package-lock.json" ]; then
      if ! command -v npm >/dev/null; then
        rm -rf "$new"; echo "TODO: OpenClaw plugin $id needs Node/npm to install; kept the previous install"; continue
      fi
      if ! (cd "$new" && HOME=/root npm ci --ignore-scripts --omit=dev --omit=peer --no-audit --no-fund --loglevel=error); then
        rm -rf "$new"; echo "install.sh: npm ci for OpenClaw plugin $id failed; kept the previous install" >&2; continue
      fi
    fi
    echo "$h" > "$new/.claw-source-sha256"
    rm -rf "$dst" && mv "$new" "$dst"
    echo "OpenClaw plugin $id installed"
  done
  for d in "$R$OC_PLUGINS"/*/; do
    [ -d "$d" ] || continue
    id=$(basename "$d")
    case $id in
      *.new) rm -rf "${d%/}" ;;   # left by an interrupted install
      *) [ -d "$src/$id" ] || { rm -rf "${d%/}"; echo "removed OpenClaw plugin $id (no longer in infra/openclaw-plugins/)"; } ;;
    esac
  done
}
