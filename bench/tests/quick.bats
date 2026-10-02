#!/usr/bin/env bats
# BATS tests for bench/quick.sh run-dir cleanup and bench/lib.sh warn_low_space
# (issue #60). Stub claude/pi/df binaries only: no network, no root.
#
# Run:
#   timeout 300 bats bench/tests </dev/null

setup() {
  local test_file="$BATS_TEST_FILENAME"
  case "$test_file" in
    /*) ;;
    *) test_file="$PWD/$test_file" ;;
  esac
  BENCH_DIR="$(cd "$(dirname "$test_file")/.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq is not installed"

  WORK="$(mktemp -d)"
  STUBS="$WORK/stubs"
  mkdir -p "$STUBS" "$WORK/tmp"
  # claude must modify the repo (an empty diff is a separate quick.sh bug).
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' 'echo touched > touched.txt' \
    'echo "{\"total_cost_usd\":0.01,\"num_turns\":1,\"duration_ms\":1000}"' > "$STUBS/claude"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$STUBS/pi"
  chmod +x "$STUBS/claude" "$STUBS/pi"
  export PATH="$STUBS:$PATH"
  export TMPDIR="$WORK/tmp"
}

teardown() {
  rm -rf "$WORK"
}

@test "quick.sh removes its run dir by default" {
  run timeout 120 bash "$BENCH_DIR/quick.sh" slugify </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *REWARD* ]]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "quick.sh -k keeps the run dir and prints its path" {
  run timeout 120 bash "$BENCH_DIR/quick.sh" -k slugify </dev/null
  [ "$status" -eq 0 ]
  kept="$(ls -d "$TMPDIR"/pi-quick.*)"
  [[ "$output" == *"runs kept in $kept"* ]]
  [ -f "$kept/slugify-A-1/row.json" ]
}

@test "warn_low_space warns under 5 GiB free and stays silent above" {
  printf '%s\n' '#!/bin/sh' 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"' \
    'echo "/dev/x 100 1 1000 1% /"' > "$STUBS/df"
  chmod +x "$STUBS/df"
  run bash -c 'BENCH_OUT="$1/not/yet" source "$2/lib.sh"; warn_low_space' _ "$WORK" "$BENCH_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: only 0 MB free"* ]]
  printf '%s\n' '#!/bin/sh' 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"' \
    'echo "/dev/x 100 1 99999999 1% /"' > "$STUBS/df"
  run bash -c 'BENCH_OUT="$1/not/yet" source "$2/lib.sh"; warn_low_space' _ "$WORK" "$BENCH_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "warn_low_space never fails when df does" {
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$STUBS/df"
  chmod +x "$STUBS/df"
  run bash -c 'set -e; BENCH_OUT="$1" source "$2/lib.sh"; warn_low_space; echo after' _ "$WORK" "$BENCH_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *after* ]]
}

@test "quick.sh survives a run that leaves an empty diff (issue #82)" {
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
    'echo "{\"total_cost_usd\":0.01,\"num_turns\":1,\"duration_ms\":1000}"' > "$STUBS/claude"
  run timeout 120 bash "$BENCH_DIR/quick.sh" slugify </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *REWARD* ]]
  [[ "$output" == *"lines=0"* ]]
}
