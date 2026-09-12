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

@test "launcher --rebuild delegates a fresh build to porthole up --rebuild" {
  # The launcher no longer builds the image itself -- Porthole's `up` is the single creator, so
  # --rebuild must pass THROUGH to `porthole up --rebuild <spec>` (the porthole stub logs it).
  d="$(mktemp -d -t pln)"
  for b in socat docker-machine open; do printf '#!/bin/sh\nexit 0\n' > "$d/$b"; done
  printf '#!/bin/sh\ncase "$*" in *"inspect -f"*) echo true ;; *) : ;; esac\nexit 0\n' > "$d/docker"
  printf '#!/bin/sh\necho "viewer-exec $*"\n' > "$d/viewer"
  chmod +x "$d"/*
  run env DOCKER_HOST=tcp://192.0.2.1:2376 PORTHOLE_LOG="$d/plog" HOME="$d/home" PATH="$d:$PATH" \
      THUNDERBIRD_VIEWER_BIN="$d/viewer" \
      "${BATS_TEST_DIRNAME}/../examples/bin/thunderbird" --rebuild
  st=$status
  grep -q 'up --rebuild .*thunderbird.container' "$d/plog" || { echo plog:; cat "$d/plog" 2>/dev/null; rm -rf "$d"; return 1; }
  rm -rf "$d"
  [ "$st" -eq 0 ] || return 1
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

# Both cases derive from XPRA_VERSION, the one place the pin lives: a hardcoded version here would
# fail its own CI on the next xpra bump and block the very PR that is supposed to carry it.
xpra_pin_mm() { tr -d '[:space:]' < "${BATS_TEST_DIRNAME}/../XPRA_VERSION" | cut -d. -f1,2; }

@test "launcher: matching xpra major.minor is silent" {
  run_thunderbird_xpra "xpra v$(xpra_pin_mm).0-r0"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"rebuild"* ]] || return 1
}

@test "launcher: mismatched xpra major.minor nudges to rebuild" {
  # One minor BELOW the pin, whatever the pin is now.
  _mm="$(xpra_pin_mm)"
  run_thunderbird_xpra "xpra v${_mm%.*}.$(( ${_mm##*.} - 1 )).0-r0"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"--rebuild"* ]] || return 1
}
