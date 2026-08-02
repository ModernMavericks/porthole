# Build ingredients

Everything baked into the shipped `porthole-*.pkg`, and how a change to it reaches a release.
Porthole is versioned like `mavericks-shared-cmake`: plain `vX.Y.Z` from the committed `VERSION`
file (it ports nothing, so there is no `-mavericks.N` repackage counter). Bump `VERSION` to cut a
release.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Porthole itself | `VERSION` | n/a — our own version; we bump it | `release.yml` on push to main publishes `vX.Y.Z` + moves `@vMAJOR` |
| MacOSX10.9 SDK + Sparkle framework | `ModernMavericks/shared-cmake@v1` (install action + `mavericks_fetch_sparkle`) | github-actions manager tracks the `@v1` tag | `@v1` is a moving tag; cut a repackage by hand when it matters |

The `viewer/` sources, `templates/`, `bin/porthole`/`generate-viewer`, and packaging scripts are this
repo's own recipe. The EdDSA public key (`updater/ed25519_key.pub`) is baked into the updater; the
private half is the `SPARKLE_PRIVATE_KEY` CI secret.
