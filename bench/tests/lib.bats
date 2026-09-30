#!/usr/bin/env bats
# BATS tests for bench/lib.sh tmpfs detection (issue #60: a RAM-backed
# tmpfs BENCH_OUT fills up quickly with disposable clones — the harness
# must warn, never refuse).
#
# bench_out_fs prints the filesystem type under $BENCH_OUT via
# `findmnt -no FSTYPE` and returns 0 with empty output when findmnt is
# unavailable (degrade gracefully — macOS ships no findmnt).
#
# Run:
#   timeout 300 bats bench/tests </dev/null

setup() {
  # Resolve the bench dir from this file's location.
  local test_file="$BATS_TEST_FILENAME"
  case "$test_file" in
    /*) ;;
    *) test_file="$PWD/$test_file" ;;
  esac
  TESTS_DIR="$(cd "$(dirname "$test_file")" && pwd)"
  BENCH_DIR="$(cd "$TESTS_DIR/.." && pwd)"

  # Temp BENCH_OUT: tests never pollute /tmp/pi-bench.
  BENCH_OUT="$(mktemp -d)"
  export BENCH_OUT
}

teardown() {
  rm -rf "$BENCH_OUT"
}

# --- bench_out_fs: detection logic via stub findmnt ---------------------------

# A stub findmnt that answers "tmpfs" must be reported verbatim, rc 0.
@test "lib.sh: bench_out_fs reports tmpfs for a tmpfs-backed BENCH_OUT" {
  local stub="$BENCH_OUT/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "tmpfs"
EOF
  chmod +x "$stub/findmnt"
  local out
  out="$(PATH="$stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; bench_out_fs" 2>/dev/null)"
  local rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "tmpfs" ]
}

# A stub findmnt that answers "apfs" (disk-backed) must be reported verbatim.
@test "lib.sh: bench_out_fs reports the real fstype for a disk-backed BENCH_OUT" {
  local stub="$BENCH_OUT/stub-bin2"
  mkdir -p "$stub"
  cat > "$stub/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "apfs"
EOF
  chmod +x "$stub/findmnt"
  local out
  out="$(PATH="$stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; bench_out_fs" 2>/dev/null)"
  local rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "apfs" ]
}

# A stub findmnt that answers tmpfs + ext4 (multiple mounts under the
# path) — the first line (deepest mount) wins; still reported as tmpfs.
@test "lib.sh: bench_out_fs uses the first line when findmnt lists several mounts" {
  local stub="$BENCH_OUT/stub-bin4"
  mkdir -p "$stub"
  cat > "$stub/findmnt" <<'EOF'
#!/usr/bin/env bash
printf 'tmpfs\next4\n'
EOF
  chmod +x "$stub/findmnt"
  local out
  out="$(PATH="$stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; bench_out_fs" 2>/dev/null)"
  local rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "tmpfs" ]
}

# When findmnt is unavailable the detection must degrade gracefully: empty
# output, rc 0, no noise on stderr.
@test "lib.sh: bench_out_fs degrades gracefully when findmnt is missing" {
  # A findmnt stub that fails (as if the binary were missing entirely by
  # not being on PATH) — emulate via a PATH dir that holds a non-executable
  # findmnt so `command -v findmnt` cannot find it.
  local nobin
  nobin="$(mktemp -d)"
  local out
  out="$(PATH="$nobin:/usr/bin:/bin" /bin/bash -c "source '$BENCH_DIR/lib.sh'; if command -v findmnt >/dev/null 2>&1; then exit 99; fi; bench_out_fs" 2>&1)"
  local rc=$?
  rm -rf "$nobin"
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
}

# --- bench_out_fs: end-to-end against the real BENCH_OUT ----------------------

@test "lib.sh: bench_out_fs returns rc 0 for the real BENCH_OUT (empty when findmnt is absent)" {
  local out
  out="$(bash -c "source '$BENCH_DIR/lib.sh'; bench_out_fs")"
  local rc=$?
  [ "$rc" -eq 0 ]
  # If findmnt exists on this machine the output must be a non-empty fstype;
  # otherwise empty (graceful degradation).
  if command -v findmnt >/dev/null 2>&1; then
    [ -n "$out" ]
  else
    [ -z "$out" ]
  fi
}

# --- bench_out_guard: tmpfs warning does not change the guard contract --------

# bench_out_guard must keep returning 0 for a valid absolute BENCH_OUT even
# when it sits on tmpfs (issue #60 option 3: warn only, never refuse).
@test "lib.sh: bench_out_guard passes on a tmpfs-backed BENCH_OUT and warns" {
  local stub="$BENCH_OUT/stub-bin3"
  mkdir -p "$stub"
  cat > "$stub/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "tmpfs"
EOF
  chmod +x "$stub/findmnt"
  local out
  out="$(PATH="$stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; bench_out_guard" 2>&1)"
  local rc=$?
  [ "$rc" -eq 0 ]
  # The warning must name the RAM-backed tmpfs hazard.
  echo "$out" | grep -q "tmpfs"
  echo "$out" | grep -q "RAM"
}

# No warning on stderr for a disk-backed BENCH_OUT.
@test "lib.sh: bench_out_guard is silent on a disk-backed BENCH_OUT" {
  local stub="$BENCH_OUT/stub-bin5"
  mkdir -p "$stub"
  cat > "$stub/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "apfs"
EOF
  chmod +x "$stub/findmnt"
  local out
  out="$(PATH="$stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; bench_out_guard" 2>&1)"
  local rc=$?
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
}
