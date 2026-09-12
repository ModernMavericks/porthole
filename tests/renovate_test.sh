#!/bin/sh
# .github/renovate.json is valid JSON and every third-party input of the base image is tracked.
# CI-only (python3): 10.9 ships Python 2, and nothing on a Mavericks box needs to read this.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CFG="$ROOT/.github/renovate.json"
fail() { echo "$@" >&2; exit 1; }

python3 -c "import json; json.load(open('$CFG'))" || fail "renovate.json invalid JSON"

# xpra: run the manager's OWN regex over the real pin file and check what it extracts. A regex that
# matches nothing is indistinguishable from no manager at all -- Renovate just stays quiet.
python3 - "$CFG" "$ROOT/XPRA_VERSION" <<'EOF' || fail "renovate.json does not track XPRA_VERSION on the deb datasource"
import json, re, sys
cfg = json.load(open(sys.argv[1])); pin = open(sys.argv[2]).read()
for m in cfg.get("customManagers", []):
    if m.get("datasourceTemplate") != "deb":
        continue
    if not any(re.search(p.strip("/"), "XPRA_VERSION") for p in m.get("managerFilePatterns", [])):
        continue
    url = m.get("registryUrlTemplate", "")
    # The deb datasource needs all three params or it cannot locate a Packages index.
    if not all(k in url for k in ("suite=", "components=", "binaryArch=")):
        continue
    if m.get("depNameTemplate") != "xpra":
        continue
    for s in m.get("matchStrings", []):
        g = re.search(s.replace("(?<", "(?P<"), pin, re.M)
        if g and re.fullmatch(r"[0-9.]+-r[0-9]+-[0-9]+", g.groupdict().get("currentValue") or ""):
            sys.exit(0)
sys.exit(1)
EOF

# xpra ships-if-green -- there must be NO local automerge exception for it. The concern that
# justified one (a newer xpra silently changing the wire protocol the viewer speaks) is real but is
# handled the way the org handles everything else: build it on the PR, fix forward in the next dated
# release, and let check_xpra_compat nudge at runtime. A rule reappearing here without that argument
# being revisited is drift, so assert its absence.
python3 - "$CFG" <<'EOF' || fail "renovate.json: xpra has an automerge exception; it is meant to ship-if-green"
import json, sys
cfg = json.load(open(sys.argv[1]))
for r in cfg.get("packageRules", []):
    if "xpra" in (r.get("matchDepNames") or []) and r.get("automerge") is False:
        sys.exit(1)
sys.exit(0)
EOF

# The Debian base is tracked by Renovate's BUILT-IN dockerfile manager (no custom config needed), so
# there is nothing to assert here beyond the digest pin -- xpra_pin_test.sh covers that.
[ -s "$ROOT/UPSTREAM_VERSION" ] || fail "UPSTREAM_VERSION missing/empty"
echo "renovate_test: OK"
