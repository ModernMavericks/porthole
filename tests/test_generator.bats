#!/usr/bin/env bats
# The generator must reproduce the committed generated files with no diff.
@test "generate-viewer thunderbird is idempotent (no git diff)" {
  cd "${BATS_TEST_DIRNAME}/.."          # porthole/ (the engine root)
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  ./bin/generate-viewer examples/thunderbird.conf >/dev/null
  run git diff --exit-code -- examples/thunderbird/ examples/bin/thunderbird
  [ "$status" -eq 0 ]
}

@test "generate-viewer defaults NAME to 'Linux <APP>' and emits the slug" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  out="$(./bin/generate-viewer examples/thunderbird.conf)"
  [[ "$out" == *'-DPORTHOLE_APP_NAME="Linux Thunderbird"'* ]] || return 1
  [[ "$out" == *'-DPORTHOLE_APP_SLUG="thunderbird"'* ]] || return 1
  grep -q 'Linux Thunderbird' examples/bin/thunderbird || return 1
}

@test "generate-viewer rejects UPDATE=pin when a package is unpinned" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  d="$(mktemp -d -t porthole)"; printf 'APP=Demo\nAPT_PKGS=demo-pkg\nUPDATE=pin\n' > "$d/demo.conf"
  run ./bin/generate-viewer "$d/demo.conf" --out "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"UPDATE=pin"* ]] || return 1
}

@test "generate-viewer rejects UPDATE=float when a package pins a =version" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  d="$(mktemp -d -t porthole)"; printf 'APP=Demo\nAPT_PKGS=demo-pkg=1.2.3\nUPDATE=float\n' > "$d/demo.conf"
  run ./bin/generate-viewer "$d/demo.conf" --out "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"UPDATE=float"* ]] || return 1
}

@test "generate-viewer accepts UPDATE=pin when every package is pinned" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  d="$(mktemp -d -t porthole)"; printf 'APP=Demo\nAPT_PKGS=%s\nUPDATE=pin\nLIFECYCLE=ondemand\n' 'a=1 b=2' > "$d/demo.conf"
  run ./bin/generate-viewer "$d/demo.conf" --out "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "generate-viewer rejects an unsupported PACKAGING backend" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  d="$(mktemp -d -t porthole)"; printf 'APP=Demo\nAPT_PKGS=demo-pkg\nPACKAGING=nix\n' > "$d/demo.conf"
  run ./bin/generate-viewer "$d/demo.conf" --out "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"PACKAGING"* ]] || return 1
}

@test "generated launchers detach the recovery watcher (closes stdin+fd3)" {
  cd "${BATS_TEST_DIRNAME}/.."
  grep -q 'nohup "$_root/bin/porthole-recover-watch" </dev/null >/dev/null 2>&1 3>&-' examples/bin/thunderbird || return 1
}

@test "generate-viewer requires an explicit UPDATE (no default)" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  d="$(mktemp -d -t upd)"; printf 'APP=Demo\nAPT_PKGS=demo-pkg\nLIFECYCLE=ondemand\n' > "$d/demo.conf"
  run ./bin/generate-viewer "$d/demo.conf" --out "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"UPDATE must be declared"* ]] || return 1
}

@test "generate-viewer requires an explicit LIFECYCLE (no default)" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  d="$(mktemp -d -t lc)"; printf 'APP=Demo\nAPT_PKGS=demo-pkg\nUPDATE=float\n' > "$d/demo.conf"
  run ./bin/generate-viewer "$d/demo.conf" --out "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"LIFECYCLE must be declared"* ]] || return 1
}

@test "generate-viewer rejects an invalid LIFECYCLE" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  d="$(mktemp -d -t lci)"; printf 'APP=Demo\nAPT_PKGS=demo-pkg\nUPDATE=float\nLIFECYCLE=forever\n' > "$d/demo.conf"
  run ./bin/generate-viewer "$d/demo.conf" --out "$d"
  rm -rf "$d"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"LIFECYCLE='forever' invalid"* ]] || return 1
}

@test "generate-viewer accepts a conf that declares both UPDATE and LIFECYCLE" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  d="$(mktemp -d -t okc)"; printf 'APP=Demo\nAPT_PKGS=demo-pkg\nUPDATE=float\nLIFECYCLE=ondemand\n' > "$d/demo.conf"
  run ./bin/generate-viewer "$d/demo.conf" --out "$d"
  rm -rf "$d"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "generate-viewer sanitizes an ENVPREFIX that would start with a digit (valid shell)" {
  cd "${BATS_TEST_DIRNAME}/.."
  [ -x bin/generate-viewer ] || skip "generator not built yet"
  # slug "1password" -> ENVPREFIX "1PASSWORD" -> ${1PASSWORD_*} is a shell "bad substitution" that
  # kills the launcher at line 1. It must be guarded to a valid name (_1PASSWORD).
  d="$(mktemp -d -t onep)"; printf 'APP=1Test\nAPT_PKGS=x\nUPDATE=float\nLIFECYCLE=ondemand\n' > "$d/1test.conf"
  ./bin/generate-viewer "$d/1test.conf" --out "$d" >/dev/null
  sh -n "$d/bin/1test" || { echo "launcher is not valid sh"; rm -rf "$d"; return 1; }
  grep -q '${_1TEST_IMAGE' "$d/bin/1test" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}
