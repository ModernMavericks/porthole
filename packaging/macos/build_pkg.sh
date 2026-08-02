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

# Locate the built Porthole.app (arg wins; else a conventional build dir).
if [ -z "$APP_IN" ]; then
  for d in "$REPO/build/viewer/Porthole.app" "$REPO/build-native/viewer/Porthole.app"; do
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

COMPONENT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/porthole-pkg.XXXXXX")
pkgbuild --root "$ROOT" \
    --identifier dev.modernmavericks.porthole \
    --version "$VERSION" \
    --install-location / \
    "$COMPONENT_DIR/porthole-component.pkg"

productbuild --distribution "$HERE/distribution.xml" \
    --package-path "$COMPONENT_DIR" \
    "$OUT"

echo "Built $OUT"
