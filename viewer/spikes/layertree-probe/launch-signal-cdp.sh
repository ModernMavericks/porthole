#!/bin/sh
# Launch a throwaway Signal Electron with a CDP port + bridge it to the Mac.
# Usage: ./launch-signal-cdp.sh   (prints the Mac-side CDP HTTP base URL)
set -eu
CONTAINER=signal-gui
PORT=9222
DISPLAY_NUM=:100
# The container runs the Xpra/Signal stack as the unprivileged 'signal' user
# (uid 1000); the Xvfb is X11-auth-guarded by /home/signal/.Xauthority. A root
# `docker exec` hits the auth wall ("Missing X server or $DISPLAY"), so we must
# run the throwaway Electron AS that user with its XAUTHORITY + XDG_RUNTIME_DIR.
RUN_USER=signal
XAUTH=/home/signal/.Xauthority
XDG=/run/user/1000

command -v socat >/dev/null 2>&1 || { echo "socat not found on Mac" >&2; exit 1; }

# 1. Drop the test pages into the container (owned by RUN_USER so Electron,
#    which runs as that user, can read them).
docker exec -u "$RUN_USER" "$CONTAINER" mkdir -p /tmp/probe-pages
docker cp pages/. "$CONTAINER":/tmp/probe-pages/
docker exec "$CONTAINER" chown -R "$RUN_USER":"$RUN_USER" /tmp/probe-pages

# 2. Launch a SECOND Electron instance on a throwaway profile with the debug
#    port, as RUN_USER so it clears the X11 auth wall and owns its own profile.
#    --remote-allow-origins=* is required by modern Chromium to accept a CDP
#    websocket from a non-localhost origin (our bridge).
docker exec -u "$RUN_USER" "$CONTAINER" rm -rf /tmp/probe-profile
docker exec -u "$RUN_USER" -d "$CONTAINER" sh -c \
  "DISPLAY=$DISPLAY_NUM XAUTHORITY=$XAUTH XDG_RUNTIME_DIR=$XDG signal-desktop --no-sandbox \
     --user-data-dir=/tmp/probe-profile \
     --enable-gpu-rasterization --ignore-gpu-blocklist \
     --remote-debugging-port=$PORT --remote-allow-origins=* \
     >/tmp/probe-electron.log 2>&1"

# 3. Wait for the debug endpoint to answer inside the container.
i=0
until docker exec "$CONTAINER" curl -sf "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 40 ] && { echo "CDP port never came up; see /tmp/probe-electron.log" >&2; exit 1; }
  sleep 0.5
done

# 4. Bridge the container port to the Mac (kill any stale bridge first).
pkill -f "TCP-LISTEN:$PORT.*$CONTAINER" 2>/dev/null || true
sleep 0.3
socat "TCP-LISTEN:$PORT,fork,reuseaddr,bind=127.0.0.1" \
      "EXEC:docker exec -i $CONTAINER socat STDIO TCP\\:127.0.0.1\\:$PORT" \
      >/tmp/probe-bridge.log 2>&1 &
sleep 1

echo "http://127.0.0.1:$PORT"
