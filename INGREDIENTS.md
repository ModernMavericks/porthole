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

The `viewer/` sources, `templates/`, `bin/porthole`/`generate-viewer`, and packaging scripts are this
repo's own recipe. The EdDSA public key (`updater/ed25519_key.pub`) is baked into the updater; the
private half is the `SPARKLE_PRIVATE_KEY` CI secret.
