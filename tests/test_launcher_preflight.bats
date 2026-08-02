#!/usr/bin/env bats
# The generated launcher preflights host prerequisites via docker-machine-ctl status.
# Note: Mavericks /usr/bin/env has no -u, so we set DOCKER_HOST=/DOCKER_CONTEXT= EMPTY
# (the preflight bypass tests `[ -n "$DOCKER_HOST" ]`, so empty == unset for its purposes).
load test_helper

run_launcher() {  # $1 = ctl status word; empty DOCKER_HOST so preflight runs
  d="$(mktemp -d -t plf)"
  cat > "$d/docker-machine-ctl" <<EOF
#!/bin/sh
[ "\$1" = status ] && echo "$1"
EOF
  for b in socat docker-machine open; do printf '#!/bin/sh\nexit 0\n' > "$d/$b"; done
  cat > "$d/docker" <<'EOF'
#!/bin/sh
case "$*" in *"inspect -f"*) echo true ;; *) : ;; esac
exit 0
EOF
  chmod +x "$d"/*
  printf '#!/bin/sh\necho "viewer-exec $*"\n' > "$d/viewer"; chmod +x "$d/viewer"
  run env DOCKER_HOST= DOCKER_CONTEXT= PATH="$d:$PATH" \
      THUNDERBIRD_VIEWER_BIN="$d/viewer" \
      "${BATS_TEST_DIRNAME}/../examples/bin/thunderbird"
  rm -rf "$d"
}

@test "launcher: no-fusion -> actionable VMware error" {
  run_launcher no-fusion
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"VMware Fusion"* ]] || return 1
}

@test "launcher: absent VM -> points at docker-machine-ctl setup" {
  run_launcher absent
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"docker-machine-ctl setup"* ]] || return 1
}

@test "launcher: Container Tools missing -> install hint" {
  d="$(mktemp -d -t plf)"
  for b in socat docker-machine open; do printf '#!/bin/sh\nexit 0\n' > "$d/$b"; done
  cat > "$d/docker" <<'EOF'
#!/bin/sh
case "$*" in *"inspect -f"*) echo true ;; *) : ;; esac
exit 0
EOF
  chmod +x "$d"/*
  printf '#!/bin/sh\necho "viewer-exec $*"\n' > "$d/viewer"; chmod +x "$d/viewer"
  # Restricted PATH: $d (no docker-machine-ctl) + system dirs ONLY -- excludes
  # /usr/local/bin where real Container Tools lives, so the "missing" path is genuine.
  run env DOCKER_HOST= DOCKER_CONTEXT= PATH="$d:/usr/bin:/bin" \
      THUNDERBIRD_VIEWER_BIN="$d/viewer" \
      "${BATS_TEST_DIRNAME}/../examples/bin/thunderbird"
  rm -rf "$d"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Container Tools"* ]] || return 1
}

@test "launcher: explicit DOCKER_HOST bypasses preflight" {
  d="$(mktemp -d -t plf)"
  for b in socat docker-machine open; do printf '#!/bin/sh\nexit 0\n' > "$d/$b"; done
  cat > "$d/docker" <<'EOF'
#!/bin/sh
case "$*" in *"inspect -f"*) echo true ;; *) : ;; esac
exit 0
EOF
  chmod +x "$d"/*
  printf '#!/bin/sh\necho "viewer-exec $*"\n' > "$d/viewer"; chmod +x "$d/viewer"
  run env DOCKER_HOST=tcp://192.0.2.1:2376 PATH="$d:$PATH" \
      THUNDERBIRD_VIEWER_BIN="$d/viewer" \
      "${BATS_TEST_DIRNAME}/../examples/bin/thunderbird"
  rm -rf "$d"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
