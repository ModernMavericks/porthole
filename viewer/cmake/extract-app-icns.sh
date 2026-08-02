#!/bin/sh
# Extract the 1Password app icon from the running op-gui container and convert it
# to a Mac .icns for the Porthole bundle. The icon belongs to AgileBits and is NOT
# committed to the repo -- it's pulled at build time from your own installed copy
# (same approach as viewer/Makefile). Best-effort: if the container/icon isn't
# available, exit non-zero WITHOUT touching the output so the build can proceed
# iconless.
#
# Usage: extract-app-icns.sh <output.icns>
set -u
OUT="${1:?usage: extract-app-icns.sh <output.icns>}"
CONTAINER="${ONEP_CONTAINER:-op-gui}"
# Which app's icon to pull from the container. Parameterized so this generator can
# stamp out a viewer for any app; defaults to 1Password (this repo's instance).
ICON_GLOB="${PORTHOLE_ICON_GLOB:-/opt/1Password/resources/icons/hicolor/512x512/apps/*.png}"
WORK="$(dirname "$OUT")/porthole-icon.tmp"

command -v sips >/dev/null 2>&1 || { echo "icon: sips not found (not macOS?) -- skipping" >&2; exit 1; }
command -v iconutil >/dev/null 2>&1 || { echo "icon: iconutil not found -- skipping" >&2; exit 1; }

eval "$(docker-machine env 2>/dev/null)" || true
png=$(docker exec "$CONTAINER" sh -c "ls -S $ICON_GLOB 2>/dev/null | head -1" 2>/dev/null) || true
[ -n "$png" ] || { echo "icon: no 1Password icon in '$CONTAINER' (is it running? op setup) -- building iconless" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK/icon.iconset" || exit 1
docker exec "$CONTAINER" cat "$png" > "$WORK/icon.png" 2>/dev/null || { echo "icon: failed to read PNG -- building iconless" >&2; exit 1; }
[ -s "$WORK/icon.png" ] || { echo "icon: empty PNG -- building iconless" >&2; exit 1; }

for s in 16 32 128 256 512; do
  sips -z "$s" "$s"             "$WORK/icon.png" --out "$WORK/icon.iconset/icon_${s}x${s}.png"    >/dev/null 2>&1 || exit 1
  sips -z "$((s*2))" "$((s*2))" "$WORK/icon.png" --out "$WORK/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || exit 1
done
iconutil -c icns "$WORK/icon.iconset" -o "$OUT" || { echo "icon: iconutil failed" >&2; exit 1; }
rm -rf "$WORK"
echo "icon: wrote $OUT"
