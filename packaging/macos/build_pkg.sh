#!/bin/sh
# Build the Porthole .pkg: the shared viewer ENGINE, shipped as /Applications/Porthole.app.
# The engine CLI (bin/porthole, generate-viewer, the recovery watcher), the templates/, the
# menu daemon, and the icon extractor are staged INSIDE the app bundle
# (Contents/Resources/engine/) so `porthole materialize` resolves them relative to itself.
# A /usr/local/bin/porthole convenience wrapper is also installed.
# Usage: build_pkg.sh <version> <out.pkg> [<built-Porthole.app>]
set -eu
VERSION=$1; OUT=$2
APP_IN="${3:-}"
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

# Locate the shared-cmake scripts dir (only needed when staging the Sparkle updater):
# $MSC_SCRIPTS (CI) -> the CMake user package registry -> a sibling checkout.
resolve_msc() {
  _m="${MSC_SCRIPTS:-}"
  [ -d "$_m" ] || _m="$(cat "$HOME/.cmake/packages/MavericksSharedCMake/"* 2>/dev/null | head -1)/scripts"
  [ -d "$_m" ] || _m="$REPO/../mavericks-shared-cmake/scripts"
  [ -d "$_m" ] && printf '%s' "$_m"
}

# Locate the built Porthole.app (arg wins; else a conventional build dir).
if [ -z "$APP_IN" ]; then
  for d in "$REPO/_build/viewer/Porthole.app" "$REPO/build-native/viewer/Porthole.app"; do
    [ -d "$d" ] && { APP_IN="$d"; break; }
  done
fi
[ -n "$APP_IN" ] && [ -d "$APP_IN" ] \
  || { echo "build_pkg: no built Porthole.app (pass it as arg 3, or build it first)" >&2; exit 1; }

# Stage the payload exactly as it should land on disk.
# BSD mktemp (all macOS, incl. 10.9) requires an explicit template.
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/porthole-root.XXXXXX")
install -d "$ROOT/Applications" "$ROOT/usr/local/bin"
cp -R "$APP_IN" "$ROOT/Applications/Porthole.app"

# Engine CLI + assets inside the bundle. materialize's ENGINE=$(dirname $0)/.. resolves to
# this engine/ dir, so generate-viewer, templates/, menu-daemon.py and the icon extractor
# all sit where it (and generate-viewer) look for them.
ENGDIR="$ROOT/Applications/Porthole.app/Contents/Resources/engine"
install -d "$ENGDIR/bin" "$ENGDIR/templates" "$ENGDIR/viewer/cmake"
install -m 0755 "$REPO/bin/porthole"                     "$ENGDIR/bin/porthole"
install -m 0755 "$REPO/bin/generate-viewer"              "$ENGDIR/bin/generate-viewer"
install -m 0755 "$REPO/bin/porthole-recover-watch"       "$ENGDIR/bin/porthole-recover-watch"
install -m 0644 "$REPO/menu-daemon.py"                   "$ENGDIR/menu-daemon.py"
install -m 0755 "$REPO/viewer/cmake/extract-app-icns.sh" "$ENGDIR/viewer/cmake/extract-app-icns.sh"
cp -R "$REPO/templates/." "$ENGDIR/templates/"

# Convenience CLI wrapper. Deliberately a tiny exec shim, NOT a symlink: the real porthole
# resolves its engine root from $0, and a symlink would make $0 the /usr/local/bin path.
cat > "$ROOT/usr/local/bin/porthole" <<'EOF'
#!/bin/sh
exec "/Applications/Porthole.app/Contents/Resources/engine/bin/porthole" "$@"
EOF
chmod 755 "$ROOT/usr/local/bin/porthole"

# Optional Sparkle updater: when UPD_APP names a built PortholeUpdater.app, stage it + its
# daily-check LaunchAgent + the load-on-install postinstall via the shared helper (release-time;
# the release workflow sets UPD_APP). Absent -> the pkg ships without auto-update.
SCRIPTS_ARG=""
if [ -n "${UPD_APP:-}" ]; then
  [ -d "$UPD_APP" ] || { echo "build_pkg: UPD_APP set but no updater .app at $UPD_APP" >&2; exit 1; }
  MSC="$(resolve_msc || true)"
  [ -n "$MSC" ] && [ -f "$MSC/stage_updater.sh" ] \
    || { echo "build_pkg: UPD_APP set but shared-cmake stage_updater.sh not found (set MSC_SCRIPTS)" >&2; exit 1; }
  SCRIPTSDIR=$(mktemp -d "${TMPDIR:-/tmp}/porthole-scripts.XXXXXX")
  sh "$MSC/stage_updater.sh" \
    --stage "$ROOT" \
    --app "$UPD_APP" \
    --app-dir "/Library/Application Support/ModernMavericks" \
    --agent-label "dev.modernmavericks.porthole-updatecheck" \
    --scripts-out "$SCRIPTSDIR"
  SCRIPTS_ARG="--scripts $SCRIPTSDIR"
fi

COMPONENT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/porthole-pkg.XXXXXX")
# shellcheck disable=SC2086  # SCRIPTS_ARG is a deliberate optional --scripts <dir> pair
pkgbuild --root "$ROOT" \
    --identifier dev.modernmavericks.porthole \
    --version "$VERSION" \
    $SCRIPTS_ARG \
    --install-location / \
    "$COMPONENT_DIR/porthole-component.pkg"

productbuild --distribution "$HERE/distribution.xml" \
    --package-path "$COMPONENT_DIR" \
    "$OUT"

echo "Built $OUT"
