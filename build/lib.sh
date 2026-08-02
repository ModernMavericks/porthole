# build/lib.sh -- sourced helpers. The shared implementations (upstream_version, msc_scripts) live in
# shared-cmake; this only locates them. Add repo-specific helpers below, not copies of shared ones.
: "${MAVERICKS_ROOT:=$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." 2>/dev/null && pwd || pwd)}"
export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/msc.sh"
. "$MSC/lib.sh"
