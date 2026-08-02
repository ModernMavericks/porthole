#!/usr/bin/env bats
# porthole materialize: render a preset conf into a standalone "Linux <App>.app" that
# wraps the SHARED installed Porthole engine. Structural test -- no live container
# (icon extraction skipped via PORTHOLE_MATERIALIZE_NO_ICON).

setup() {
  ENGINE="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  APPS="$(mktemp -d "${TMPDIR:-/tmp}/porthole-apps.XXXXXX")"
  export PORTHOLE_MATERIALIZE_NO_ICON=1
}
teardown() {
  [ -n "$APPS" ] && rm -rf "$APPS"
}

@test "materialize builds a standalone Linux <App>.app from a preset conf" {
  run "$ENGINE/bin/porthole" materialize "$ENGINE/examples/thunderbird.conf" --apps-dir "$APPS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$APPS/Linux Thunderbird.app" ]
}

@test "the bundle has an executable stub that execs the Resources launcher" {
  "$ENGINE/bin/porthole" materialize "$ENGINE/examples/thunderbird.conf" --apps-dir "$APPS" >/dev/null
  B="$APPS/Linux Thunderbird.app/Contents"
  [ -x "$B/MacOS/thunderbird" ]
  grep -q 'Resources/bin' "$B/MacOS/thunderbird"
  [ -x "$B/Resources/bin/thunderbird" ]
}

@test "the bundle carries the rendered container recipe" {
  "$ENGINE/bin/porthole" materialize "$ENGINE/examples/thunderbird.conf" --apps-dir "$APPS" >/dev/null
  [ -f "$APPS/Linux Thunderbird.app/Contents/Resources/thunderbird/Dockerfile" ]
}

@test "Info.plist names the app and the per-app bundle id" {
  "$ENGINE/bin/porthole" materialize "$ENGINE/examples/thunderbird.conf" --apps-dir "$APPS" >/dev/null
  P="$APPS/Linux Thunderbird.app/Contents/Info.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$P")" = "Linux Thunderbird" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$P")" = "dev.modernmavericks.porthole.thunderbird" ]
}

@test "the materialized launcher points at the shared installed engine" {
  "$ENGINE/bin/porthole" materialize "$ENGINE/examples/thunderbird.conf" --apps-dir "$APPS" >/dev/null
  grep -q '/Applications/Porthole.app' "$APPS/Linux Thunderbird.app/Contents/Resources/bin/thunderbird"
}
