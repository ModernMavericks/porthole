#!/usr/bin/env bats
# Guard: porthole builds as its OWN top-level project. `cmake -S <root> -B <tmp>` must
# configure with no product repo and no container -- the regression guard against
# re-coupling this root to a parent's project()/find_package(MavericksSharedCMake).
load test_helper

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # BSD mktemp (macOS 10.9) requires an explicit template.
  BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/porthole-standalone.XXXXXX")"
}

teardown() {
  [ -n "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"
}

@test "porthole configures as a standalone top-level project" {
  run cmake -S "$REPO_ROOT" -B "$BUILD_DIR"
  [ "$status" -eq 0 ]
}
