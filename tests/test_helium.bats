#!/usr/bin/env bats
# Viewer #4, generated. The flagship browser (Chromium-based, imputnet/helium) from
# its own Debian repo, with the audio bridge on.

@test "Helium Dockerfile installs helium-bin from Helium's own apt repo" {
  df="${BATS_TEST_DIRNAME}/../examples/helium/Dockerfile"
  grep -q 'pkg.helium.computer/deb' "$df" || return 1
  grep -qE 'apt-get install -y helium-bin xpra=6.5.2-r0-1 xvfb' "$df" || return 1
  # audio bridge on: pulseaudio pulled in
  grep -q 'pulseaudio' "$df" || return 1
  # no Signal/1Password/VNC baggage (non-comment lines only)
  ! grep -v '^[[:space:]]*#' "$df" | grep -qiE 'signal|1password|tigervnc|openbox|cups' || return 1
}

@test "Helium entrypoint + child are valid sh and launch helium under xpra with audio" {
  sh -n "${BATS_TEST_DIRNAME}/../examples/helium/start-helium-gui.sh" || return 1
  sh -n "${BATS_TEST_DIRNAME}/../examples/helium/helium-child.sh" || return 1
  grep -q 'xpra start' "${BATS_TEST_DIRNAME}/../examples/helium/start-helium-gui.sh" || return 1
  grep -q -- '--speaker=on' "${BATS_TEST_DIRNAME}/../examples/helium/start-helium-gui.sh" || return 1
  # Helium sandboxes via user namespaces -> must NOT pass --no-sandbox (unsupported)
  ! grep '^[[:space:]]*exec ' "${BATS_TEST_DIRNAME}/../examples/helium/helium-child.sh" \
      | grep -q -- '--no-sandbox' || return 1
}

@test "bin/helium launches the viewer pointed at the xpra tunnel (port 10003)" {
  tmp="$(mktemp -d -t heliumtest)"
  cat > "$tmp/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "container inspect") exit 0 ;;
esac
case "$*" in
  *"inspect -f"*) echo true ;;
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
  run env PATH="$tmp:$PATH" HELIUM_NO_PREFLIGHT=1 \
        HELIUM_VIEWER_BIN="$tmp/viewer" \
        "${BATS_TEST_DIRNAME}/../examples/bin/helium"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"viewer-exec "*"/helium-xpra.sock"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"launching -> "*"/helium-xpra.sock"* ]] || return 1
}

@test "bin/helium mounts the Mac Downloads at the browser download dir + supports ad-hoc mounts" {
  b="${BATS_TEST_DIRNAME}/../examples/bin/helium"
  grep -q 'HOME/Downloads:/home/helium/Downloads' "$b" || return 1
  grep -q '${HELIUM_MOUNTS:-}' "$b" || return 1
  grep -q -- '-v "$VOLUME:.*" $MOUNT_ARGS' "$b" || return 1
}

@test "bin/helium auto-recovers the viewer on a lost backend (marker)" {
  b="${BATS_TEST_DIRNAME}/../examples/bin/helium"
  grep -q 'MARKER="${XPRA_SOCK%-xpra.sock}-viewer-lost"' "$b" || return 1
  grep -q 'RW_RELAUNCH="open ' "$b" || return 1     # recovery re-opens the .app (keeps its identity)
  grep -q 'porthole-recover-watch' "$b" || return 1
}
