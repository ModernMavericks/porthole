#!/usr/bin/env bats
# When `porthole up` fails, the fatal dialog must include the tail of up's stderr.
load test_helper

@test "launcher: up failure includes stderr tail in the dialog" {
  d="$(mktemp -d -t plu)"
  cat > "$d/docker-machine-ctl" <<'EOF'
#!/bin/sh
[ "$1" = status ] && echo running
EOF
  printf '#!/bin/sh\nexit 0\n' > "$d/docker-machine"
  printf '#!/bin/sh\nprintf "s6-ipcserver %s\\n" "$*" >> "%s"\nsleep 2\n' '$*' "$STUB_LOG" > "$d/s6-ipcserver"
  printf '#!/bin/sh\necho "viewer-exec $*"\n' > "$d/viewer"
  # A porthole whose `up` prints a distinctive error to stderr and fails.
  cat > "$d/porthole" <<'EOF'
#!/bin/sh
[ "$1" = up ] && { echo "porthole up: image build failed: DISTINCT-BUILD-ERR" >&2; exit 1; }
exit 0
EOF
  chmod +x "$d"/*
  run env DOCKER_HOST= DOCKER_CONTEXT= PATH="$d:$PATH" \
      PORTHOLE_BIN="$d/porthole" THUNDERBIRD_VIEWER_BIN="$d/viewer" \
      "${BATS_TEST_DIRNAME}/../examples/bin/thunderbird"
  rm -rf "$d"
  [ "$status" -ne 0 ] || return 1
  grep -q 'display dialog' "$STUB_LOG" || return 1
  grep -q 'DISTINCT-BUILD-ERR' "$STUB_LOG" || { echo "$(cat "$STUB_LOG")"; return 1; }
}
