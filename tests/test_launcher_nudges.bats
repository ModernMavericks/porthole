#!/usr/bin/env bats
# Generated launcher: container-staleness + xpra-compat nudges (parity with op).
# Mavericks: no `env -u`; set empty vars. HOME points into the temp dir so the
# once/day nudge marker is isolated per test (no cross-run suppression).
load test_helper

run_thunderbird() {  # $1 = image Created timestamp; DOCKER_HOST set -> preflight bypassed
  d="$(mktemp -d -t pln)"
  for b in socat docker-machine open; do printf '#!/bin/sh\nexit 0\n' > "$d/$b"; done
  cat > "$d/docker" <<EOF
#!/bin/sh
case "\$*" in
  *"image inspect -f"*) printf '%s\n' "\${CREATED:-}" ;;
  *"inspect -f"*) echo true ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "$d"/*
  printf '#!/bin/sh\necho "viewer-exec $*"\n' > "$d/viewer"; chmod +x "$d/viewer"
  run env DOCKER_HOST=tcp://192.0.2.1:2376 CREATED="$1" HOME="$d/home" PATH="$d:$PATH" \
      THUNDERBIRD_VIEWER_BIN="$d/viewer" \
      "${BATS_TEST_DIRNAME}/../examples/bin/thunderbird"
  rm -rf "$d"
}

@test "launcher: old container nudges to rebuild" {
  run_thunderbird "2000-01-01T00:00:00.000000000Z"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"days old"* ]] || return 1
  [[ "$output" == *"--rebuild"* ]] || return 1
}

@test "launcher: fresh container does not nudge" {
  run_thunderbird "2999-01-01T00:00:00.000000000Z"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"days old"* ]] || return 1
}

@test "launcher --rebuild forces a fresh image build" {
  d="$(mktemp -d -t pln)"
  for b in socat docker-machine open; do printf '#!/bin/sh\nexit 0\n' > "$d/$b"; done
  cat > "$d/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$LOGF"
case "$*" in *"inspect -f"*) echo true ;; *) : ;; esac
exit 0
EOF
  chmod +x "$d"/*
  printf '#!/bin/sh\necho "viewer-exec $*"\n' > "$d/viewer"; chmod +x "$d/viewer"
  run env DOCKER_HOST=tcp://192.0.2.1:2376 LOGF="$d/log" HOME="$d/home" PATH="$d:$PATH" \
      THUNDERBIRD_VIEWER_BIN="$d/viewer" \
      "${BATS_TEST_DIRNAME}/../examples/bin/thunderbird" --rebuild
  grep -q 'build --no-cache' "$d/log" || { cat "$d/log"; rm -rf "$d"; return 1; }
  grep -q 'rm -f thunderbird-gui' "$d/log" || { cat "$d/log"; rm -rf "$d"; return 1; }
  rm -rf "$d"
  [ "$status" -eq 0 ] || return 1
}

run_thunderbird_xpra() {  # $1 = `xpra --version` output; DOCKER_HOST set -> preflight bypassed
  d="$(mktemp -d -t plx)"
  for b in socat docker-machine open; do printf '#!/bin/sh\nexit 0\n' > "$d/$b"; done
  cat > "$d/docker" <<EOF
#!/bin/sh
case "\$*" in
  *"xpra --version"*) printf '%s\n' "\${XV:-}" ;;
  *"image inspect -f"*) echo 2999-01-01T00:00:00Z ;;
  *"inspect -f"*) echo true ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "$d"/*
  printf '#!/bin/sh\necho "viewer-exec $*"\n' > "$d/viewer"; chmod +x "$d/viewer"
  run env DOCKER_HOST=tcp://192.0.2.1:2376 XV="$1" HOME="$d/home" PATH="$d:$PATH" \
      THUNDERBIRD_VIEWER_BIN="$d/viewer" \
      "${BATS_TEST_DIRNAME}/../examples/bin/thunderbird"
  rm -rf "$d"
}

@test "launcher: matching xpra major.minor is silent" {
  run_thunderbird_xpra "xpra v6.5.2-r0"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"rebuild"* ]] || return 1
}

@test "launcher: mismatched xpra major.minor nudges to rebuild" {
  run_thunderbird_xpra "xpra v6.4.4-r0"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"--rebuild"* ]] || return 1
}
