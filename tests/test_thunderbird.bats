#!/usr/bin/env bats
# Viewer #3, generated. Proves the generator handles a Gecko/GTK, Debian-native app
# (no third-party apt repo, no Electron sandbox flag) -- not just the Signal mold.

@test "Thunderbird Dockerfile installs thunderbird from the base distro (no third-party apt repo)" {
  df="${BATS_TEST_DIRNAME}/../examples/thunderbird/Dockerfile"
  grep -qE 'apt-get install -y thunderbird xpra=6.5.2-r0-1 xvfb' "$df" || return 1
  # base-distro path: no per-app apt key fetch or sources.list.d entry
  ! grep -q 'sources.list.d/thunderbird' "$df" || return 1
  ! grep -qi 'keyrings/thunderbird-desktop' "$df" || return 1
  # no Signal/1Password/VNC baggage (non-comment lines only)
  ! grep -v '^[[:space:]]*#' "$df" | grep -qiE 'signal|1password|tigervnc|openbox|cups' || return 1
}

@test "Thunderbird entrypoint + child are valid sh and launch thunderbird under xpra" {
  sh -n "${BATS_TEST_DIRNAME}/../examples/thunderbird/start-thunderbird-gui.sh" || return 1
  sh -n "${BATS_TEST_DIRNAME}/../examples/thunderbird/thunderbird-child.sh" || return 1
  grep -q 'xpra start' "${BATS_TEST_DIRNAME}/../examples/thunderbird/start-thunderbird-gui.sh" || return 1
  grep -q 'exec thunderbird' "${BATS_TEST_DIRNAME}/../examples/thunderbird/thunderbird-child.sh" || return 1
  # GTK app: no Electron --no-sandbox flag on the actual exec line (comments may mention it)
  ! grep '^[[:space:]]*exec ' "${BATS_TEST_DIRNAME}/../examples/thunderbird/thunderbird-child.sh" \
      | grep -q -- '--no-sandbox' || return 1
}

@test "bin/thunderbird launches the viewer pointed at the xpra tunnel (port 10002)" {
  tmp="$(mktemp -d -t tbtest)"
  cat > "$tmp/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "container inspect") exit 0 ;;
esac
case "$*" in
  *"inspect -f"*) echo true ;;
  *"ps -eo args"*) exit 0 ;;
  *) : ;;
esac
exit 0
EOF
  cat > "$tmp/open" <<EOF
#!/bin/sh
echo "open \$*" >> "$tmp/log"
EOF
  printf '#!/bin/sh\nexit 0\n' > "$tmp/socat"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/docker-machine"
  chmod +x "$tmp"/docker "$tmp"/open "$tmp"/socat "$tmp"/docker-machine
  printf '#!/bin/sh\necho "viewer-exec $*"\n' > "$tmp/viewer"; chmod +x "$tmp/viewer"
  run env PATH="$tmp:$PATH" THUNDERBIRD_NO_PREFLIGHT=1 \
        THUNDERBIRD_VIEWER_BIN="$tmp/viewer" \
        "${BATS_TEST_DIRNAME}/../examples/bin/thunderbird"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # the launcher execs its OWN viewer binary in place (distinct app), passing the xpra sock
  [[ "$output" == *"viewer-exec "*"/thunderbird-xpra.sock"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"launching -> "*"/thunderbird-xpra.sock"* ]] || return 1
}

@test "bin/thunderbird auto-recovers the viewer on a lost backend (marker)" {
  b="${BATS_TEST_DIRNAME}/../examples/bin/thunderbird"
  grep -q 'MARKER="${XPRA_SOCK%-xpra.sock}-viewer-lost"' "$b" || return 1
  grep -q 'RW_RELAUNCH="open ' "$b" || return 1     # recovery re-opens the .app (keeps its identity)
  grep -q 'porthole-recover-watch' "$b" || return 1
}

@test "thunderbird image installs a11y + bakes the menu daemon" {
  df="${BATS_TEST_DIRNAME}/../examples/thunderbird/Dockerfile"
  grep -q 'python3-pyatspi' "$df" || return 1
  grep -q 'at-spi2-core' "$df" || return 1
  grep -q 'porthole-menu-daemon.py' "$df" || return 1
}

@test "thunderbird child.sh enables a11y and starts the menu daemon before exec" {
  ch="${BATS_TEST_DIRNAME}/../examples/thunderbird/thunderbird-child.sh"
  grep -q 'GTK_MODULES=atk-bridge' "$ch" || return 1
  grep -q 'at-spi-bus-launcher' "$ch" || return 1
  grep -q 'porthole-menu-daemon.py' "$ch" || return 1
}
