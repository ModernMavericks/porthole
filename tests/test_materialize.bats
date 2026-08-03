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

@test "the app carries its OWN engine binary + recovery watcher and execs it in place" {
  # A copied binary makes each materialized app a distinct LaunchServices app (own icon/name/instance),
  # so several viewers can run at once -- rather than all reactivating one shared Porthole.app.
  fake="$APPS/fake-engine"; printf '#!/bin/sh\nexit 0\n' > "$fake"; chmod +x "$fake"
  PORTHOLE_ENGINE_BIN="$fake" "$ENGINE/bin/porthole" \
    materialize "$ENGINE/examples/thunderbird.conf" --apps-dir "$APPS" >/dev/null
  B="$APPS/Linux Thunderbird.app/Contents"
  [ -x "$B/MacOS/Porthole" ]                                 # its own copy of the viewer engine binary
  [ -x "$B/Resources/bin/porthole-recover-watch" ]          # the recovery watcher, bundled
  grep -q 'exec "$_bin" "$XPRA_SOCK"' "$B/Resources/bin/thunderbird"   # runs it IN PLACE
  ! grep -q 'open "$APP"' "$B/Resources/bin/thunderbird"              # not `open` of a shared app
}

@test "the app wears the penguin default icon (the real icon is extracted on first launch, never shipped)" {
  "$ENGINE/bin/porthole" materialize "$ENGINE/examples/thunderbird.conf" --apps-dir "$APPS" >/dev/null
  A="$APPS/Linux Thunderbird.app/Contents"
  [ -f "$A/Resources/AppIcon.icns" ]
  cmp -s "$A/Resources/AppIcon.icns" "$ENGINE/packaging/macos/penguin.icns"   # ours, redistributable
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$A/Info.plist")" = AppIcon ]
}
