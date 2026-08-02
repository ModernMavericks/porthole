# Build ingredients

Everything baked into the shipped `porthole-*.pkg`, and how a change to it reaches a release.
Porthole is self-owned: it *ports nothing*, so its "own upstream" is its own version, which we
bump deliberately. An own-version bump cuts `<version>-mavericks.1`; an ingredient bump cuts a
`-mavericks.(N+1)` repackage of the same version.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Porthole source (own version) | `UPSTREAM_VERSION` | n/a — self-owned; we bump it (Porthole ports nothing to track) | `release.yml` on push to main cuts `<version>-mavericks.1` |
| MacOSX10.9 SDK + Sparkle framework | `ModernMavericks/shared-cmake@v1` (install action + `mavericks_fetch_sparkle`) | ✅ github-actions manager tracks the `@v1` tag | `@v1` is a *moving* tag, so content moves without the pin string changing — cut a repackage by hand when it matters |

Not ingredients: the `viewer/` engine sources, `templates/`, `bin/porthole`/`generate-viewer`, and the
packaging scripts are this repo's own recipe — a change there is a release we cut deliberately (push to
main, or `workflow_dispatch` with `local_release=true`), not something Renovate drives. The EdDSA
signing keypair's public half (`updater/ed25519_key.pub`) is baked into the updater; the private half
is the `SPARKLE_PRIVATE_KEY` CI secret.
