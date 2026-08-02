#!/bin/sh
# Thin wrapper: the logic lives in shared-cmake (scripts/version.sh) so it cannot drift between repos.
# Porthole is self-owned (it ports nothing) -- UPSTREAM_VERSION is Porthole's own version, which we
# bump; version.sh turns it into <version>-mavericks.N and decides whether to release.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
. "$SELF/msc.sh"
exec sh "$MSC/version.sh" "$@"
