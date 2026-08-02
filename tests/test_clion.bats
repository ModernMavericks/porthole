#!/usr/bin/env bats
# Viewer #5, generated. The contrast case: a JetBrains IDE (Swing/JBR, NOT Electron)
# installed from a TARBALL (not apt) -- exercises the generator's non-apt install path.

@test "CLion Dockerfile installs from a tarball (not apt) and pulls the Swing/X11 deps" {
  df="${BATS_TEST_DIRNAME}/../examples/clion/Dockerfile"
  # tarball install path: fetch + extract to /opt + symlink the launcher
  grep -q "download.jetbrains.com/product" "$df" || return 1
  grep -qE 'tar -xz -C /opt/clion --strip-components=1' "$df" || return 1
  grep -qE 'ln -sf /opt/clion/bin/clion.sh /usr/local/bin/clion' "$df" || return 1
  # no apt app package (APT_PKGS empty -> just xpra xvfb)
  grep -qE 'apt-get install -y +xpra=6.5.2-r0-1 xvfb' "$df" || return 1
  # the Swing/JBR X11 + font deps
  grep -qE 'libxtst6' "$df" || return 1
  # no Signal/1Password/VNC baggage (non-comment lines)
  ! grep -v '^[[:space:]]*#' "$df" | grep -qiE 'signal|1password|tigervnc|openbox|helium' || return 1
}

@test "CLion entrypoint + child are valid sh and launch clion under xpra" {
  sh -n "${BATS_TEST_DIRNAME}/../examples/clion/start-clion-gui.sh" || return 1
  sh -n "${BATS_TEST_DIRNAME}/../examples/clion/clion-child.sh" || return 1
  grep -q 'xpra start' "${BATS_TEST_DIRNAME}/../examples/clion/start-clion-gui.sh" || return 1
  grep -qE '^exec clion' "${BATS_TEST_DIRNAME}/../examples/clion/clion-child.sh" || return 1
}

@test "CLion menu manifest is valid JSON with the expected menus + forwarded shortcuts" {
  mj="${BATS_TEST_DIRNAME}/../examples/clion.menu.json"
  python3 -c "import json,sys; d=json.load(open('$mj')); t=[m['title'] for m in d['menus']]; sys.exit(0 if all(x in t for x in ['File','Navigate','Code','Refactor','Run']) else 1)" || return 1
  # a forwarded combo (Go to Class = Linux ctrl+n) and a native-ish Cmd key are present
  grep -q '"send": "ctrl+n"' "$mj" || return 1
}

@test "bin/clion launches the viewer (port 10004) + supports a launch-time project mount" {
  tmp="$(mktemp -d -t cliontest)"
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
  mkdir -p "$tmp/app/build-native-clion/porthole/viewer/Porthole.app"
  run env PATH="$tmp:$PATH" CLION_NO_PREFLIGHT=1 \
        CLION_APP="$tmp/app/build-native-clion/porthole/viewer/Porthole.app" \
        "${BATS_TEST_DIRNAME}/../examples/bin/clion"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'open .*Porthole.app --args .*/clion-xpra.sock' "$tmp/log" || { cat "$tmp/log"; return 1; }
  grep -q '${CLION_MOUNTS:-}' "${BATS_TEST_DIRNAME}/../examples/bin/clion" || return 1
}
