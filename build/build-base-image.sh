#!/bin/sh
# Build the shared Porthole BASE image (ghcr.io/modernmavericks/porthole-base).
#
# The ONE place the base build context is assembled and the xpra pin is read, so the CI job that
# PROVES a pin bump (.github/workflows/base-image.yml, on any PR touching base/**) and the release
# job that also PUSHES it cannot drift apart. Pushing stays with the caller: this script only builds.
#
#   usage: build-base-image.sh TAG [TAG...]     e.g. build-base-image.sh ghcr.io/…/porthole-base:latest
#
# Linux + a working `docker build` (CI runs it on ubuntu-latest for the amd64 image). Never runs on
# a 10.9 box, but stays POSIX sh like the rest of build/.
set -eu
[ $# -ge 1 ] || { echo "usage: $0 TAG [TAG...]" >&2; exit 64; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# The xpra pin. base/Dockerfile has no default for it and fails closed on an empty one, so a typo
# here cannot quietly produce an image with whatever xpra happened to be newest.
PIN="$ROOT/XPRA_VERSION"
[ -f "$PIN" ] || { echo "$0: no $PIN" >&2; exit 1; }
XPRA_VERSION=$(tr -d '[:space:]' < "$PIN")
[ -n "$XPRA_VERSION" ] || { echo "$0: $PIN is empty" >&2; exit 1; }

# A clean context of exactly what the image needs -- the Dockerfile plus the two assets it COPYs.
CTX=$(mktemp -d "${TMPDIR:-/tmp}/porthole-basectx.XXXXXX")
trap 'rm -rf "$CTX"' EXIT
cp "$ROOT/base/Dockerfile"          "$CTX/Dockerfile"
cp "$ROOT/menu-daemon.py"           "$CTX/porthole-menu-daemon.py"
cp "$ROOT/templates/mac-fonts.conf" "$CTX/mac-fonts.conf"

TAGS=""
for t in "$@"; do TAGS="$TAGS -t $t"; done
echo "base image: xpra $XPRA_VERSION, tags:$TAGS"
# Word-splitting $TAGS is deliberate (one -t per tag); image refs contain no spaces.
# shellcheck disable=SC2086
docker build --build-arg "XPRA_VERSION=$XPRA_VERSION" $TAGS "$CTX"

# Prove the pin took. `docker build` succeeds as long as apt resolved SOMETHING, and the failure this
# guards against is precisely an install that silently resolved to a different version.
got=$(docker run --rm "$1" dpkg-query -W -f '${Version}' xpra)
[ "$got" = "$XPRA_VERSION" ] \
  || { echo "$0: built image has xpra $got, expected $XPRA_VERSION" >&2; exit 1; }
echo "base image OK: xpra $got"
