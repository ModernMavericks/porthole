#!/usr/bin/env bats
# The shared viewer watcher: WATCH_ONCE runs a single iteration so we can drive it.
load test_helper
W="${BATS_TEST_DIRNAME}/../bin/porthole-recover-watch"

setup_watch() {
  mkdir -p "$STUB_DIR"
  : > "$STUB_DIR/pgrep.gone"        # pgrep stub: report the viewer ABSENT
  export RW_BIN="/some/Porthole" RW_MARKER="$WORK/lost" \
         RW_PIDFILE="$WORK/watch.pid" RW_RELAUNCH="touch $WORK/relaunched" \
         WATCH_ONCE=1
}

@test "recover-watch relaunches when the disconnect marker is present" {
  setup_watch
  : > "$RW_MARKER"                  # viewer died from a lost backend
  run "$W"
  [ "$status" -eq 0 ] || return 1
  [ -f "$WORK/relaunched" ] || return 1     # re-invoked the launcher
  [ ! -f "$RW_MARKER" ] || return 1         # consumed the marker
}

@test "recover-watch does NOT relaunch on a clean quit (no marker)" {
  setup_watch
  run "$W"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "$WORK/relaunched" ] || return 1
}

@test "recover-watch stops the container on an on-demand quit" {
  setup_watch
  export RW_ONDEMAND=1 RW_CONTAINER="viewer-gui" RW_STOP_PIDS=""
  run "$W"
  [ "$status" -eq 0 ] || return 1
  [[ "$(cat "$STUB_LOG")" == *"docker stop viewer-gui"* ]] || return 1
}
