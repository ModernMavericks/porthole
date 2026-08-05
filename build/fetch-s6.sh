#!/bin/sh
# Fetch + verify (SHA512) + cross-build skalibs then s6 (static, no execline) as x86_64/min-10.9
# Mach-O, then copy the s6-ipcserver component binaries into $1 (an output bin dir).
# Pins match the maintainer's pkgsrc: skalibs 2.14.4.0 (5bc6d77b...), s6 2.13.2.0 (9310225247...).
# NOTE: needs network (GitHub) + the shared-cmake 10.9 SDK; run in CI or on a networked box.
set -eu
OUTDIR="${1:?usage: fetch-s6.sh <out-bin-dir>}"
REPO=$(cd "$(dirname "$0")/.." && pwd)
SH="$(cat "$HOME/.cmake/packages/MavericksSharedCMake/"* 2>/dev/null | head -1)/scripts"
SDK="$(sh "$SH/fetch_sdk.sh" 2>/dev/null || true)"
[ -d "$SDK" ] || { echo "fetch-s6: no 10.9 SDK from shared-cmake (SH=$SH)" >&2; exit 1; }

CC="clang -arch x86_64 -isysroot $SDK -mmacosx-version-min=10.9"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/s6-build.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"; mkdir -p "$STAGE"

fetch() {  # $1=project  $2=commit  $3=sha512
  cd "$WORK"
  curl -fsSL -o "$1.tar.gz" "https://github.com/skarnet/$1/archive/$2.tar.gz"
  echo "$3  $1.tar.gz" | shasum -a 512 -c - || { echo "fetch-s6: $1 SHA512 mismatch" >&2; exit 1; }
  tar xzf "$1.tar.gz"   # -> $1-$2/
}

SKR=$(tr -d '[:space:]' < "$REPO/SKALIBS_REF"); SKS=$(tr -d '[:space:]' < "$REPO/SKALIBS_SHA512")
S6R=$(tr -d '[:space:]' < "$REPO/S6_REF");       S6S=$(tr -d '[:space:]' < "$REPO/S6_SHA512")

fetch skalibs "$SKR" "$SKS"
cd "$WORK/skalibs-$SKR"
CC="$CC" ./configure --disable-shared --enable-static --prefix="$STAGE"
make -j"$(sysctl -n hw.ncpu)"; make install

fetch s6 "$S6R" "$S6S"
cd "$WORK/s6-$S6R"
# --enable-allstatic: statically embed libskarnet so the shipped binaries are self-contained.
# --disable-execline: we invoke s6-ipcserver with a plain argv (docker exec ...), not an execline
#   block, so the execline library is unnecessary (pkgsrc keeps it only for script-spawning bins).
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
