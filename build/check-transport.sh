#!/bin/sh
# Prove a freshly built s6-ipcserver transport (in $1) is shippable, before anything stages it.
# This is what lets a skalibs/s6 bump ride the green build: every other test stubs s6-ipcserver,
# so without this a bump that compiled but changed how the transport behaves would ship broken.
#   1. The 10.9 compat guard on all three binaries (x86_64, min-10.9, no post-10.9 imports).
#   2. The real thing, run as the launchers and the op ssh-agent bridge run it:
#      `PATH=<bin>:... s6-ipcserver -a 0600 <sock> <prog>` must bind <sock> owner-only, chain-load
#      its siblings from PATH, and relay a connection's bytes through <prog> and back.
# Knobs: PORTHOLE_COMPAT_GUARD (the guard script; default: shipyard's), CHECK_TRANSPORT_TIMEOUT
# (seconds to wait for the socket and the echo; generous by default -- a first x86_64 run under
# Rosetta is slow).
set -eu
BIN="${1:?usage: check-transport.sh <bin-dir>}"
BIN=$(cd "$BIN" && pwd)
die() { echo "check-transport: $*" >&2; exit 1; }

GUARD="${PORTHOLE_COMPAT_GUARD:-}"
if [ -z "$GUARD" ]; then
  SH="${SHIPYARD_SCRIPTS:-$(cat "$HOME/.cmake/packages/MavericksShipyard/"* 2>/dev/null | head -1)/scripts}"
  GUARD="$SH/assert_binary_compatible.sh"
fi
[ -f "$GUARD" ] || die "no compat guard to run ($GUARD) -- refusing to pass what was not measured"
sh "$GUARD" "$BIN/s6-ipcserver" "$BIN/s6-ipcserver-socketbinder" "$BIN/s6-ipcserverd" \
  || die "compat guard failed"

# /tmp, not $TMPDIR: a Unix socket path must fit in sun_path (104 bytes on macOS).
T=$(mktemp -d /tmp/check-transport.XXXXXX)
SOCK="$T/s"
PID=""
# Reap the server before removing its socket dir; its killed status must not become ours (set -e).
cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || :; wait "$PID" 2>/dev/null || :; fi
  rm -rf "$T"
}
trap cleanup EXIT
# A PATH with nothing else skarnet on it: a sibling that cannot be found in $BIN must fail here,
# not be quietly picked up from some other install.
PATH="$BIN:/usr/bin:/bin" "$BIN/s6-ipcserver" -a 0600 "$SOCK" cat &
PID=$!

python3 - "$SOCK" "${CHECK_TRANSPORT_TIMEOUT:-30}" <<'PY' || die "the real s6-ipcserver failed its smoke test"
import os, socket, stat, sys, time
path, timeout = sys.argv[1], float(sys.argv[2])
deadline = time.time() + timeout
while not os.path.exists(path):
    if time.time() > deadline:
        sys.exit("check-transport: no socket at %s after %gs (server did not listen)" % (path, timeout))
    time.sleep(0.1)
mode = stat.S_IMODE(os.stat(path).st_mode)
if mode != 0o600:
    sys.exit("check-transport: socket mode is %o, want 600 (-a 0600 not honored)" % mode)
token = os.urandom(16).hex().encode()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(max(deadline - time.time(), 1))
s.connect(path)
s.sendall(token)
s.shutdown(socket.SHUT_WR)
got = b''
try:
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        got += chunk
except socket.timeout:
    pass
if got != token:
    sys.exit("check-transport: sent %r, got back %r (connection not relayed through the child)" % (token, got))
PY
echo "check-transport: $BIN is 10.9-safe and relays a connection owner-only"
