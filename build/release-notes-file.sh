#!/bin/sh
# Thin wrapper: the logic lives in shared-cmake (scripts/release-notes-file.sh). Only the product
# name is ours.
#   usage: release-notes-file.sh <TAG> <FULL_VERSION>
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
. "$SELF/msc.sh"
exec sh "$MSC/release-notes-file.sh" "${1:?TAG required}" "${2:?FULL version required}" "Porthole"
