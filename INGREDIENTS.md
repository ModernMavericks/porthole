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
| xpra (the display server the native viewer speaks to) | `XPRA_VERSION` — one bare deb version, e.g. `6.5.2-r0-1` | regex manager on the **deb** datasource against xpra.org's own trixie index; ship-if-green like everything else | `base-image.yml` builds + asserts the image really carries that xpra; a protocol regression is fixed forward in the next dated release |

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

**xpra ships-if-green, like every other bump in the org.** It was briefly an automerge exception,
on the theory that a newer xpra builds fine and silently changes the wire protocol the hand-rolled
Cocoa client is written against. That risk is real — xpra 5→6 renamed the hello capability `sound` →
`audio`, and the server then *silently ignored* our audio request until the client advertised the new
key (`viewer/src/PortholeClient.m`) — but it is the ordinary org trade: build it on the PR, fix
forward in a dated release. The one contrary data point we have is mild: a live container drifted
6.5.1 → 6.5.2 and kept working, which is a patch step inside the same minor and not evidence about
6.5 → 6.6.

**What makes fixing forward possible is the runtime canary, so keep the two versions apart.** The
launcher's `check_xpra_compat` compares a container's running xpra against what the **viewer speaks**
— `PortholeClient.m`'s advertised hello version, read by `build/xpra-client-version.sh` and stamped
into the engine as `XPRA_CLIENT_VERSION` at package time. It is deliberately **not** derived from
`XPRA_VERSION`: if it were, an xpra bump would move the container and the expectation together, the
check would agree with itself, and a protocol break would surface only as "the app doesn't work".
`tests/xpra_pin_test.sh` asserts the two stay independent.

The client currently advertises `6.5.1` while the image pins `6.5.2`. That is known and left alone:
it demonstrably works, and changing what the client claims to be is a live handshake change with no
test to catch a regression.
