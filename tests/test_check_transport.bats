#!/usr/bin/env bats
# build/check-transport.sh is the gate a skalibs/s6 bump must pass before its binaries are staged:
# the 10.9 compat guard, then the real s6-ipcserver run the way the launchers run it. Here the
# guard is a stub and s6-ipcserver is a small Python stand-in whose failure modes we choose, so
# the gate's own logic is tested without a cross-build.

setup() {
  ENGINE="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # Normalized as the script normalizes its arg: macOS's TMPDIR ends in '/', which leaves a '//'.
  WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-transport-test.XXXXXX")" && pwd)"
  BIN="$WORK/bin"; mkdir -p "$BIN"
  # The stand-in: `s6-ipcserver [-a perms] <sock> prog...`, one forked child per connection with
  # the connection on stdin/stdout. STUB_MODE picks how it misbehaves.
  # (sys.executable, not `command -v python3`: that can be a wrapper script, which a shebang can't name.)
  cat > "$BIN/s6-ipcserver" <<EOF
#!$(python3 -c 'import sys; print(sys.executable)')
import os, socket, sys
mode = os.environ.get('STUB_MODE', 'ok')
args = sys.argv[1:]
perms = 0o777
if args[:1] == ['-a']:
    perms, args = int(args[1], 8), args[2:]
path, prog = args[0], args[1:]
if mode == 'exit':
    sys.exit(1)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
os.chmod(path, 0o666 if mode == 'perms' else perms)
s.listen(5)
while True:
    c, _ = s.accept()
    if os.fork() == 0:
        if mode == 'noecho':
            os._exit(0)
        os.dup2(c.fileno(), 0); os.dup2(c.fileno(), 1)
        os.execvp(prog[0], prog)
    c.close()
EOF
  printf '#!/bin/sh\nexit 0\n' > "$BIN/s6-ipcserver-socketbinder"
  printf '#!/bin/sh\nexit 0\n' > "$BIN/s6-ipcserverd"
  chmod 755 "$BIN"/*
  export GUARD_LOG="$WORK/guard.log"
  printf '#!/bin/sh\necho "$@" >> "%s"\nexit "${GUARD_EXIT:-0}"\n' "$GUARD_LOG" > "$WORK/guard.sh"
  export PORTHOLE_COMPAT_GUARD="$WORK/guard.sh"
  export CHECK_TRANSPORT_TIMEOUT=3
}
teardown() { [ -n "$WORK" ] && rm -rf "$WORK"; }

@test "check-transport passes a transport that serves the socket owner-only and relays bytes" {
  run sh "$ENGINE/build/check-transport.sh" "$BIN"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "check-transport runs the compat guard on all three binaries" {
  run sh "$ENGINE/build/check-transport.sh" "$BIN"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for b in s6-ipcserver s6-ipcserver-socketbinder s6-ipcserverd; do
    grep -q "$BIN/$b" "$GUARD_LOG" || { echo "guard not run on $b: $(cat "$GUARD_LOG")"; return 1; }
  done
}

@test "check-transport fails when the compat guard fails" {
  GUARD_EXIT=1 run sh "$ENGINE/build/check-transport.sh" "$BIN"
  [ "$status" -ne 0 ]
}

@test "check-transport fails closed when there is no compat guard to run" {
  PORTHOLE_COMPAT_GUARD="$WORK/nonexistent.sh" run sh "$ENGINE/build/check-transport.sh" "$BIN"
  [ "$status" -ne 0 ]
}

@test "check-transport fails, promptly, when the server exits instead of listening" {
  start=$(date +%s)
  STUB_MODE=exit run sh "$ENGINE/build/check-transport.sh" "$BIN"
  [ "$status" -ne 0 ]
  [ $(( $(date +%s) - start )) -lt 20 ] || { echo "took too long"; return 1; }
}

@test "check-transport fails when the socket is not owner-only" {
  STUB_MODE=perms run sh "$ENGINE/build/check-transport.sh" "$BIN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode"* ]] || { echo "$output"; return 1; }
}

@test "check-transport fails when bytes do not round-trip through the child" {
  STUB_MODE=noecho run sh "$ENGINE/build/check-transport.sh" "$BIN"
  [ "$status" -ne 0 ]
}

@test "check-transport leaves no server running after it finishes" {
  run sh "$ENGINE/build/check-transport.sh" "$BIN"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! pgrep -f "$BIN/s6-ipcserver" >/dev/null || { echo "server still running"; pkill -f "$BIN/s6-ipcserver"; return 1; }
}
