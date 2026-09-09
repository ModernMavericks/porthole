#!/bin/sh
# Fetch (git, by pinned commit) + cross-build skalibs then s6 (static, no execline) as
# x86_64/min-10.9 Mach-O, then copy the s6-ipcserver component binaries into $1 (an out bin dir).
# Pins: skalibs 2.14.4.0, s6 2.13.2.0 -- the commit is read from SKALIBS_REF/S6_REF (first field;
# a "# vX.Y.Z" comment on the same line lets Renovate track the tag). Integrity: git guarantees the
# checked-out tree hashes to the pinned commit, so no separate content checksum is kept.
# NOTE: needs network (GitHub) + the shipyard 10.9 SDK; run in CI or on a networked box.
set -eu
OUTDIR="${1:?usage: fetch-s6.sh <out-bin-dir>}"
REPO=$(cd "$(dirname "$0")/.." && pwd)
SH="$(cat "$HOME/.cmake/packages/MavericksShipyard/"* 2>/dev/null | head -1)/scripts"
SDK="$(sh "$SH/fetch_sdk.sh" 2>/dev/null || true)"
[ -d "$SDK" ] || { echo "fetch-s6: no 10.9 SDK from shipyard (SH=$SH)" >&2; exit 1; }

CC="clang -arch x86_64 -isysroot $SDK -mmacosx-version-min=10.9"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/s6-build.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"; mkdir -p "$STAGE"

# Fetch a single pinned commit and check it out. GitHub allows fetching a reachable commit SHA
# directly (allowReachableSHA1InWant); git verifies the received objects hash to $2 -- that IS the
# integrity check (an immutable commit, unlike a mutable tag), so no separate checksum is needed.
fetch() {  # $1=project  $2=commit
  git init -q "$WORK/$1"
  ( cd "$WORK/$1" \
    && git -c protocol.version=2 fetch -q --depth 1 "https://github.com/skarnet/$1.git" "$2" \
    && git -c advice.detachedHead=false checkout -q "$2" )
}

# First field of the REF file is the 40-hex commit (the rest is a "# vX.Y.Z" Renovate marker).
SKR=$(awk 'NR==1{print $1}' "$REPO/SKALIBS_REF")
S6R=$(awk 'NR==1{print $1}' "$REPO/S6_REF")

fetch skalibs "$SKR"
cd "$WORK/skalibs"
CC="$CC" ./configure --disable-shared --enable-static --prefix="$STAGE"
make -j"$(sysctl -n hw.ncpu)"; make install

fetch s6 "$S6R"
cd "$WORK/s6"
# --enable-allstatic: statically embed libskarnet so the shipped binaries are self-contained.
# --disable-execline: we invoke s6-ipcserver with a plain argv (docker exec ...), not an execline
#   block, so the execline library is unnecessary (it is only needed for binaries that spawn
#   execline scripts, not for s6-ipcserver).
# The --with-sysdeps path is where skalibs installed its sysdeps; adjust if skalibs 2.14 differs.
CC="$CC" ./configure --enable-static --disable-shared --enable-allstatic --disable-execline \
  --with-include="$STAGE/include" --with-lib="$STAGE/lib" \
  --with-sysdeps="$STAGE/lib/skalibs/sysdeps" --prefix="$STAGE"
make -j"$(sysctl -n hw.ncpu)"; make install

mkdir -p "$OUTDIR"
for b in s6-ipcserver-socketbinder s6-ipcserverd s6-ipcserver; do
  cp "$STAGE/bin/$b" "$OUTDIR/$b"; chmod 0755 "$OUTDIR/$b"
  file "$OUTDIR/$b" | grep -q x86_64 || { echo "fetch-s6: $b not x86_64" >&2; exit 1; }
done
echo "fetch-s6: staged s6-ipcserver into $OUTDIR"
