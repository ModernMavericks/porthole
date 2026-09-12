#!/bin/sh
# The base image's two third-party inputs -- Debian and xpra -- are pinned where Renovate can see
# them, and pinned COMPLETELY.
#
# This exists because the old pin was `apt-get install -y xpra=6.5.2-r0-1`, which versions only the
# META-package. Its dependencies (xpra-common, xpra-client, xpra-server, xpra-codecs, ...) were left
# to apt's candidate, so the moment xpra.org published 6.5.3 apt picked 6.5.3 for those, collided
# with xpra 6.5.2's strict `Depends: xpra-client (= 6.5.2-r0-1)`, and the base-image job went red:
#   xpra-client : Depends: xpra-common (= 6.5.2-r0-1) but 6.5.3-r0-1 is to be installed
# A pin that only holds while it names the newest version is not a pin.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V="$ROOT/XPRA_VERSION"
DF="$ROOT/base/Dockerfile"
fail() { echo "$@" >&2; exit 1; }
# The Dockerfile's INSTRUCTIONS, comments stripped. Prose about why this shape exists may name a
# version or quote the old broken command; neither can drift a build, so the "must not appear"
# checks below read this rather than the raw file.
DFI=$(mktemp "${TMPDIR:-/tmp}/xpra-pin-dfi.XXXXXX"); trap 'rm -f "$DFI"' EXIT
sed 's/#.*//' "$DF" > "$DFI"

[ -f "$V" ] || fail "no XPRA_VERSION (the single source for the xpra pin)"
# A Debian package version: xpra.org ships <upstream>-r<revision>-<packaging>.
grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?-r[0-9]+-[0-9]+$' "$V" \
  || fail "XPRA_VERSION: expected a bare deb version like 6.5.2-r0-1, got: $(cat "$V")"
[ "$(wc -l < "$V")" -eq 1 ] || fail "XPRA_VERSION: expected exactly one line"

# Debian base: digest-pinned, numeric tag. A bare moving tag rots silently -- and an aged-out Debian
# fails apt-get update outright (container-tools' iso build died exactly that way when bullseye left
# LTS). The numeric tag is what lets Renovate propose the next Debian major, not just a digest refresh.
grep -qE '^FROM debian:[0-9]+-slim@sha256:[0-9a-f]{64}$' "$DF" \
  || fail "base/Dockerfile: FROM must be debian:<N>-slim@sha256:<64 hex> (Renovate-trackable, digest-pinned)"

# The version itself must NOT be repeated in the Dockerfile's INSTRUCTIONS: it arrives as a build
# arg from XPRA_VERSION. A second literal is a second thing to bump, and the one left behind wins
# silently. Comments may name a version -- prose about why this shape exists cannot drift a build.
if grep -qE '[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+-[0-9]+' "$DFI"; then
  fail "base/Dockerfile: carries a literal xpra version; it must come from XPRA_VERSION via ARG"
fi

# The pin must cover the WHOLE xpra package set, not the meta-package alone.
grep -q 'preferences.d/xpra' "$DF" \
  || fail "base/Dockerfile: no apt preferences pin (the meta-package alone does not pin the set)"
grep -qF 'Package: xpra* python3-xpra' "$DF" \
  || fail "base/Dockerfile: the apt pin must glob the whole xpra set (Package: xpra* python3-xpra)"
grep -q 'Pin-Priority: 1001' "$DF" \
  || fail "base/Dockerfile: the apt pin needs priority 1001 (it must beat, and be able to downgrade to, the candidate)"
# Fail closed: an empty build arg would write `Pin: version ` (matching nothing) and silently float.
grep -q 'XPRA_VERSION:?' "$DF" \
  || fail "base/Dockerfile: must fail closed when XPRA_VERSION is empty (\${XPRA_VERSION:?...})"
# ...and the install line must NOT re-pin the meta-package: that is the bug this replaces.
if grep -qE 'apt-get install[^&]*xpra=' "$DFI"; then
  fail "base/Dockerfile: still pins the xpra meta-package on the install line (pin the set instead)"
fi

# The launcher's compat nudge speaks major.minor and must DERIVE it, not carry a fourth literal.
if grep -qE 'XPRA_VERSION:-[0-9]' "$ROOT/templates/launcher.tmpl"; then
  fail "templates/launcher.tmpl: hardcodes the xpra major.minor; render it from XPRA_VERSION"
fi
grep -q '@XPRA_MM@' "$ROOT/templates/launcher.tmpl" \
  || fail "templates/launcher.tmpl: expected @XPRA_MM@ (rendered from XPRA_VERSION)"

# The packaged engine must carry the pin: generate-viewer runs on the user's Mac at materialize time
# and reads it from there. Without it, a materialized launcher nudges against nothing.
grep -q 'XPRA_VERSION' "$ROOT/packaging/macos/build_pkg.sh" \
  || fail "packaging/macos/build_pkg.sh: does not stage XPRA_VERSION into the engine"

echo "xpra_pin_test: OK"
