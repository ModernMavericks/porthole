#!/bin/sh
# Print the xpra version the NATIVE VIEWER speaks -- the one it advertises in its hello, which is
# what the server actually negotiates against. That is a property of the client source, NOT of the
# base image's XPRA_VERSION pin, and keeping the two apart is deliberate: see the comment in
# bin/generate-viewer. Exactly one match, or this fails rather than guess.
#   usage: xpra-client-version.sh [PATH-TO-PortholeClient.m]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${1:-$ROOT/viewer/src/PortholeClient.m}"
[ -f "$SRC" ] || { echo "$0: no $SRC" >&2; exit 1; }
n=$(grep -cE '^[[:space:]]*@"version":[[:space:]]*@"[0-9][0-9.]*",?$' "$SRC" || true)
[ "$n" -eq 1 ] || { echo "$0: expected exactly one hello @\"version\" in $SRC, found $n" >&2; exit 1; }
sed -n 's/^[[:space:]]*@"version":[[:space:]]*@"\([0-9][0-9.]*\)",\{0,1\}$/\1/p' "$SRC"
