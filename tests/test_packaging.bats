#!/usr/bin/env bats
# build_pkg.sh stages the Porthole.app engine + the engine CLI/templates + the CLI wrapper
# into a productbuild .pkg with a 10.9 floor. Uses a fake minimal Porthole.app so the test
# needs no compiled viewer (real pkgbuild/productbuild, which macOS provides).

setup() {
  ENGINE="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/porthole-pkg-test.XXXXXX")"
  FAKEAPP="$WORK/Porthole.app"
  mkdir -p "$FAKEAPP/Contents/MacOS" "$FAKEAPP/Contents/Resources"
  printf '#!/bin/sh\n' > "$FAKEAPP/Contents/MacOS/Porthole"; chmod 755 "$FAKEAPP/Contents/MacOS/Porthole"
  printf '<plist></plist>\n' > "$FAKEAPP/Contents/Info.plist"
}
teardown() { [ -n "$WORK" ] && rm -rf "$WORK"; }

@test "build_pkg stages the app, the engine CLI, and the wrapper into the payload" {
  run sh "$ENGINE/packaging/macos/build_pkg.sh" 9.9.9 "$WORK/out.pkg" "$FAKEAPP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$WORK/out.pkg" ]
  files="$(pkgutil --payload-files "$WORK/out.pkg")"
  echo "$files" | grep -q 'Applications/Porthole.app/Contents/MacOS/Porthole'
  echo "$files" | grep -q 'Applications/Porthole.app/Contents/Resources/engine/bin/porthole'
  echo "$files" | grep -q 'Applications/Porthole.app/Contents/Resources/engine/bin/generate-viewer'
  echo "$files" | grep -q 'Applications/Porthole.app/Contents/Resources/engine/templates/launcher.tmpl'
  echo "$files" | grep -q 'usr/local/bin/porthole'
}

@test "the pkg declares a 10.9 minimum" {
  sh "$ENGINE/packaging/macos/build_pkg.sh" 9.9.9 "$WORK/out.pkg" "$FAKEAPP" >/dev/null
  d="$WORK/expand"; pkgutil --expand "$WORK/out.pkg" "$d"
  grep -q 'os-version min="10.9"' "$d/Distribution"
}
