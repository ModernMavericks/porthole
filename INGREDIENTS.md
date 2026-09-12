# Build ingredients

Everything baked into the shipped `porthole-*.pkg`, and how a change to it reaches a release.
Porthole is a Mavericks app that **is its own upstream**, so it is versioned by DATE with no
`-mavericks` suffix (that suffix marks our repackage of *someone else's* upstream, which Porthole
is not). `UPSTREAM_VERSION` is the date `YYYYMMDD`; a release is `YYYYMMDD.N`, N counting the
releases cut that day starting at `.1`. Bump `UPSTREAM_VERSION` (the date) when you cut a new day's
version.

| Ingredient | Pinned in | Renovate | On a change |
|---|---|---|---|
| Porthole itself (its own upstream) | `UPSTREAM_VERSION` (a date) | n/a — we bump the date by hand | dispatch `release.yml` → publishes `YYYYMMDD.N` |
| MacOSX10.9 SDK + Sparkle framework | `ModernMavericks/shipyard@v1` (install action + `mavericks_fetch_sparkle`) | github-actions manager tracks the `@v1` tag | `@v1` is a moving tag; cut a new dated release when it matters |
| skalibs (static, into the transport) | `SKALIBS_REF` — commit + `# vA.B.C.D` tag | regex manager, grouped with s6 as `skarnet`; ship-if-green | one PR bumps both; the build cross-compiles them and `build/check-transport.sh` must pass (10.9 compat guard + the real `s6-ipcserver -a 0600` relaying a connection) |
| s6 (`s6-ipcserver{,-socketbinder,d}` in `engine/bin`) | `S6_REF` — commit + `# vA.B.C.D` tag | same group as skalibs | as above; the transport is what every materialized app's launcher and the `op` ssh-agent bridge run |
| Debian base of the shared container image | `base/Dockerfile` — `FROM debian:<N>-slim@sha256:…` | built-in dockerfile manager (digest **and** the numeric tag, so the next Debian major is proposed, not only a digest refresh); ship-if-green | `base-image.yml` rebuilds the image on the PR; merging it means the next release's base is built on that Debian |
| xpra (the display server the native viewer speaks to) | `XPRA_VERSION` — one bare deb version, e.g. `6.5.2-r0-1` | regex manager on the **deb** datasource against xpra.org's own trixie index; **automerge off** (see below) | `base-image.yml` builds + asserts the image really carries that xpra; merge it together with a viewer change |

The `viewer/` sources, `templates/`, `bin/porthole`/`generate-viewer`, and packaging scripts are this
repo's own recipe. The EdDSA public key (`updater/ed25519_key.pub`) is baked into the updater; the
private half is the `SPARKLE_PRIVATE_KEY` CI secret.

## Upstream release notes

No upstream release notes: porthole is its own upstream -- original ModernMavericks code, versioned
`YYYYMMDD.N` with no `-mavericks` axis -- so there are no someone-else's notes for a release to link.

## The xpra pin

`XPRA_VERSION` is the **one** place the version lives. `base/Dockerfile` takes it as a build arg and
writes `/etc/apt/preferences.d/xpra` from it, pinning the whole `xpra*` package set; `bin/generate-viewer`
derives the launcher's compat `major.minor` from the same file (and `build_pkg.sh` stages it into the
engine so that still works on the user's Mac). `build/build-base-image.sh` is the only place the image
is built, and it fails if the built image does not carry exactly that xpra.

**Pinning only the `xpra` meta-package is not pinning xpra.** `apt-get install -y xpra=6.5.2-r0-1`
leaves `xpra-common`/`-client`/`-server`/`-codecs` to apt's candidate, so when xpra.org published
6.5.3 apt chose 6.5.3 for those, collided with the meta-package's strict `Depends: … (= 6.5.2-r0-1)`,
and the release-time base-image job died in "held broken packages". The repo retains old versions;
that is not the same as pinning them.

**xpra is the family's one ship-if-green exception here**, and `renovate.json` says why: the native
viewer is written against a specific xpra wire protocol, so a newer xpra installs cleanly and
silently changes it. A green build cannot catch that — `check_xpra_compat` in the launcher only
*nudges* the user to rebuild. Renovate still opens the PR, which is the point: nothing was watching
xpra at all before, which is how the pin rotted unseen.
