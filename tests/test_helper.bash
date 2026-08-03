# Shared BATS setup for the op suite. `load test_helper` from each .bats file.
# Each @test gets a fresh temp workspace with stub docker/pbcopy/etc. on PATH.


setup() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/op-bats.XXXXXX")"
  export STUB_DIR="$WORK/stub"
  export STUB_LOG="$STUB_DIR/log"
  export CLIPBOARD_FILE="$WORK/clipboard"
  export ONEP_CONFIG_DIR="$WORK/config"
  export ONEP_SSH_AUTH_SOCK="$WORK/agent.sock"
  export ONEP_CLIP_CLEAR_SECS=1
  export DOCKER_HOST="tcp://192.0.2.1:2376"   # preset so op skips docker-machine
  # Generated launchers delegate container bring-up to the installed `porthole up`. Pin it to the
  # logging stub (absolute path, so it wins over any real Porthole installed on this box and works
  # even under a minimal PATH). Tests that assert the call set PORTHOLE_LOG.
  export PORTHOLE_BIN="${BATS_TEST_DIRNAME}/stubs/porthole"
  export PATH="${BATS_TEST_DIRNAME}/stubs:$PATH"
  mkdir -p "$STUB_DIR"
  : > "$STUB_LOG"
}

teardown() {
  rm -rf "$WORK"
}
