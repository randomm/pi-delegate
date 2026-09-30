#!/usr/bin/env bats
# BATS tests for bench/cleanup.sh.
#
# cleanup.sh deletes run directories under a TEMP BENCH_OUT (never
# /tmp/pi-bench or the committed bench/tasks/ tree). No real claude or pi
# is invoked.
#
# Run:
#   timeout 300 bats bench/tests </dev/null

setup() {
  local test_file="$BATS_TEST_FILENAME"
  case "$test_file" in
    /*) ;;
    *) test_file="$PWD/$test_file" ;;
  esac
  TESTS_DIR="$(cd "$(dirname "$test_file")" && pwd)"
  BENCH_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  FIXTURES="$TESTS_DIR/fixtures"

  command -v jq >/dev/null 2>&1 || { skip "jq is not installed"; }
  command -v git >/dev/null 2>&1 || { skip "git is not installed"; }

  export GIT_TERMINAL_PROMPT=0 EDITOR=true VISUAL=true PAGER=cat GIT_PAGER=cat

  BENCH_OUT="$(mktemp -d)"
  export BENCH_OUT
  TASKS_DIR="$BENCH_OUT/tasks"
  mkdir -p "$TASKS_DIR"
  export TASKS_DIR

  MECH_ID="issue-41-mech"
  MECH_DIR="$TASKS_DIR/$MECH_ID"
  mkdir -p "$MECH_DIR"
  cat > "$MECH_DIR/task.env" <<'EOF'
REPO=/dev/null
BASE_SHA=0000000000000000000000000000000000000000
FIX_SHA=0000000000000000000000000000000000000001
TEST_CMD=true
EOF

  cd /
}

teardown() {
  rm -rf "$BENCH_OUT"
}

# --- helpers ---------------------------------------------------------------

# make_run <task> <arm> <run#> [with-collect] — creates an empty run dir;
# with-collect=1 adds a collect.json that records exactly this run.
make_run() {
  local task="$1" arm="$2" run="$3" flag="${4:-0}"
  local run_dir="$BENCH_OUT/$task/$arm/$run"
  mkdir -p "$run_dir/repo"
  echo "x" > "$run_dir/keepme.txt"
  if [ "$flag" = "1" ]; then
    jq -cn --arg t "$task" --arg a "$arm" --argjson r "$run" \
      '{task:$t, arm:$a, run:$r, grade:{pass:true,test_cmd:null,error:null}}' \
      > "$run_dir/collect.json"
  fi
}

# --- usage ------------------------------------------------------------------

@test "cleanup.sh: no args exits 1 with usage" {
  run bash "$BENCH_DIR/cleanup.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "cleanup.sh: unknown mode exits 1" {
  run bash "$BENCH_DIR/cleanup.sh" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown mode"* ]]
}

@test "cleanup.sh: extra args after --list exit 1" {
  run bash "$BENCH_DIR/cleanup.sh" --list A
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- --list -----------------------------------------------------------------

@test "cleanup.sh --list: lists runs with statuses and deletes nothing" {
  make_run alpha A 1 1
  make_run alpha A 2 0
  make_run alpha B 1 1
  run bash "$BENCH_DIR/cleanup.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *alpha/A/1*collected* ]]
  [[ "$output" == *alpha/A/2*not-collected* ]]
  [[ "$output" == *alpha/B/1*collected* ]]
  # Nothing removed.
  [ -d "$BENCH_OUT/alpha/A/1" ]
  [ -d "$BENCH_OUT/alpha/A/2" ]
  [ -d "$BENCH_OUT/alpha/B/1" ]
  [[ "$output" == *Total:* ]]
}

@test "cleanup.sh --list: multi-digit run numbers are listed" {
  make_run alpha A 10 0
  make_run alpha A 100 1
  run bash "$BENCH_DIR/cleanup.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *alpha/A/10*not-collected* ]]
  [[ "$output" == *alpha/A/100*collected* ]]
}

@test "cleanup.sh --list: malformed collect.json is flagged, not collected" {
  make_run alpha A 1 1
  echo 'not json' > "$BENCH_OUT/alpha/A/1/collect.json"
  run bash "$BENCH_DIR/cleanup.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *malformed-collect* ]]
  [ -d "$BENCH_OUT/alpha/A/1" ]
}

@test "cleanup.sh --list: empty BENCH_OUT is fine" {
  run bash "$BENCH_DIR/cleanup.sh" --list
  [ "$status" -eq 0 ]
  # Only the header line.
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "cleanup.sh --list: ignores non-run entries (notes, tasks, misc files)" {
  mkdir -p "$BENCH_OUT/notes" "$BENCH_OUT/tasks"
  echo hi > "$BENCH_OUT/notes/readme.md"
  # A file directly under BENCH_OUT is not a run dir.
  echo x > "$BENCH_OUT/stray.txt"
  # A depth-3 path whose arm is not A or B is not a run.
  mkdir -p "$BENCH_OUT/alpha/X/1"
  # A depth-3 path whose run is not numeric is not a run.
  mkdir -p "$BENCH_OUT/alpha/A/foo"
  make_run alpha A 1 0
  run bash "$BENCH_DIR/cleanup.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *alpha/A/1*not-collected* ]]
  # Only header + the single run line + the Total line.
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]
  [ -d "$BENCH_OUT/notes" ]
  [ -d "$BENCH_OUT/alpha/X/1" ]
  [ -d "$BENCH_OUT/alpha/A/foo" ]
}

# --- --collected: full prefix ------------------------------------------------

@test "cleanup.sh --collected: removes only the named collected run" {
  make_run alpha A 1 1
  make_run alpha A 2 0
  make_run alpha B 1 1
  make_run beta  A 1 1
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/A/1
  [ "$status" -eq 0 ]
  [ ! -d "$BENCH_OUT/alpha/A/1" ]
  [ -d "$BENCH_OUT/alpha/A/2" ]
  [ -d "$BENCH_OUT/alpha/B/1" ]
  [ -d "$BENCH_OUT/beta/A/1" ]
}

@test "cleanup.sh --collected: prefix alpha/A removes collected runs only" {
  make_run alpha A 1 1
  make_run alpha A 2 0
  make_run alpha A 3 1
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/A
  [ "$status" -eq 0 ]
  [ ! -d "$BENCH_OUT/alpha/A/1" ]
  [ -d "$BENCH_OUT/alpha/A/2" ]
  [ ! -d "$BENCH_OUT/alpha/A/3" ]
}

@test "cleanup.sh --collected: task prefix removes all collected under it" {
  make_run alpha A 1 1
  make_run alpha B 2 1
  make_run beta  A 1 0
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha
  [ "$status" -eq 0 ]
  [ ! -d "$BENCH_OUT/alpha/A/1" ]
  [ ! -d "$BENCH_OUT/alpha/B/2" ]
  [ -d "$BENCH_OUT/beta/A/1" ]
}

@test "cleanup.sh --collected: multi-digit run# prefix works" {
  make_run alpha A 10 1
  make_run alpha A 11 0
  make_run alpha A 100 1
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/A/10
  [ "$status" -eq 0 ]
  [ ! -d "$BENCH_OUT/alpha/A/10" ]
  [ -d "$BENCH_OUT/alpha/A/11" ]
  [ -d "$BENCH_OUT/alpha/A/100" ]
}

@test "cleanup.sh --collected: un-collected run is never removed" {
  make_run alpha A 1 0
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/A/1
  [ "$status" -eq 0 ]
  [ -d "$BENCH_OUT/alpha/A/1" ]
}

@test "cleanup.sh --collected: stale collect.json (wrong run) is skipped" {
  make_run alpha A 1 0
  jq -cn '{task:"alpha", arm:"A", run:99, grade:{pass:true,test_cmd:null,error:null}}' \
    > "$BENCH_OUT/alpha/A/1/collect.json"
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/A/1
  [ "$status" -eq 0 ]
  [ -d "$BENCH_OUT/alpha/A/1" ]
  [[ "$output" == *"does not record this run"* ]]
}

@test "cleanup.sh --collected: malformed collect.json is never removed" {
  make_run alpha A 1 0
  echo 'not json' > "$BENCH_OUT/alpha/A/1/collect.json"
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/A/1
  [ "$status" -eq 0 ]
  [ -d "$BENCH_OUT/alpha/A/1" ]
}

@test "cleanup.sh --collected: bad prefix (non-numeric run#) exits 1" {
  make_run alpha A 1 1
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/A/abc
  [ "$status" -eq 1 ]
  [ -d "$BENCH_OUT/alpha/A/1" ]
}

@test "cleanup.sh --collected: bad prefix (bad arm) exits 1" {
  make_run alpha A 1 1
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/X/1
  [ "$status" -eq 1 ]
  [ -d "$BENCH_OUT/alpha/A/1" ]
}

@test "cleanup.sh --collected: bad prefix (4 components) exits 1" {
  make_run alpha A 1 1
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/A/1/extra
  [ "$status" -eq 1 ]
  [ -d "$BENCH_OUT/alpha/A/1" ]
}

@test "cleanup.sh --collected: no matches prints message, exit 0" {
  make_run alpha A 1 0
  run bash "$BENCH_DIR/cleanup.sh" --collected alpha/A/1
  [ "$status" -eq 0 ]
  [ -d "$BENCH_OUT/alpha/A/1" ]
  [[ "$output" == *"no collected runs"* ]]
}

@test "cleanup.sh --collected: empty BENCH_OUT exit 0" {
  run bash "$BENCH_DIR/cleanup.sh" --collected
  [ "$status" -eq 0 ]
  [[ "$output" == *"no collected runs"* ]]
}

# --- --collected: no prefix (whole tree) ------------------------------------

@test "cleanup.sh --collected (no prefix): removes every collected run" {
  make_run alpha A 1 1
  make_run alpha B 2 0
  make_run beta  A 1 1
  run bash "$BENCH_DIR/cleanup.sh" --collected
  [ "$status" -eq 0 ]
  [ ! -d "$BENCH_OUT/alpha/A/1" ]
  [ -d "$BENCH_OUT/alpha/B/2" ]
  [ ! -d "$BENCH_OUT/beta/A/1" ]
}

# --- --all -------------------------------------------------------------------

@test "cleanup.sh --all: non-interactive without --force refuses" {
  make_run alpha A 1 0
  run bash -c "bash '$BENCH_DIR/cleanup.sh' --all </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing"* ]]
  [ -d "$BENCH_OUT/alpha/A/1" ]
}

@test "cleanup.sh --all --force: non-interactive removes every run" {
  make_run alpha A 1 0
  make_run alpha B 2 1
  make_run beta  A 1 0
  run bash "$BENCH_DIR/cleanup.sh" --all --force
  [ "$status" -eq 0 ]
  [ ! -d "$BENCH_OUT/alpha/A/1" ]
  [ ! -d "$BENCH_OUT/alpha/B/2" ]
  [ ! -d "$BENCH_OUT/beta/A/1" ]
}

@test "cleanup.sh --all: unknown flag exits 1" {
  make_run alpha A 1 0
  run bash "$BENCH_DIR/cleanup.sh" --all --bogus
  [ "$status" -eq 1 ]
  [ -d "$BENCH_OUT/alpha/A/1" ]
}

@test "cleanup.sh --all: empty BENCH_OUT exit 0, no prompt needed" {
  run bash -c "bash '$BENCH_DIR/cleanup.sh' --all </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no run directories"* ]]
}

@test "cleanup.sh --all: leaves non-run dirs under BENCH_OUT alone" {
  mkdir -p "$BENCH_OUT/tasks" "$BENCH_OUT/notes"
  echo hi > "$BENCH_OUT/notes/readme.md"
  make_run alpha A 1 0
  run bash "$BENCH_DIR/cleanup.sh" --all --force
  [ "$status" -eq 0 ]
  [ -d "$BENCH_OUT/tasks" ]
  [ -d "$BENCH_OUT/notes" ]
  [ -f "$BENCH_OUT/notes/readme.md" ]
  [ ! -d "$BENCH_OUT/alpha/A/1" ]
}

# TTY-backed --all: exercise the real confirmation prompt path via a pty.
@test "cleanup.sh --all: TTY 'y' removes every run (skips without pty)" {
  command -v script >/dev/null 2>&1 || { skip "script(1) not available"; }
  make_run alpha A 1 0
  make_run alpha B 2 1
  local pty_out
  pty_out="$(mktemp)"
  # `echo y` writes 'y\n' then EOF; script feeds it to the pty as two
  # characters ('y' then EOT). The read in cleanup.sh sees 'y' first
  # (then EOT), which is accepted. Order matters: the prompt must be
  # flushed before the answer is typed, otherwise the TTY may see
  # EOF before the 'y'. The `y\n` from `echo y` is the standard
  # confirmation shape and is what the operator would type.
  # script(1) on macOS does not propagate the child's exit code, so
  # we cannot rely on rc. Instead, verify the run dirs were removed.
  ( echo y; sleep 1 ) | script -q "$pty_out" bash -c "bash '$BENCH_DIR/cleanup.sh' --all" >/dev/null 2>&1 || true
  rm -f "$pty_out"
  # The run dirs must be gone (the 'y' answer confirmed the removal).
  [ ! -d "$BENCH_OUT/alpha/A/1" ]
  [ ! -d "$BENCH_OUT/alpha/B/2" ]
}

@test "cleanup.sh --all: TTY 'n' declines (skips without pty)" {
  command -v script >/dev/null 2>&1 || { skip "script(1) not available"; }
  make_run alpha A 1 0
  local pty_out
  pty_out="$(mktemp)"
  # script(1) on macOS does not propagate the child's exit code, so
  # we cannot rely on rc. Instead, verify the run dir was NOT removed.
  ( echo n; sleep 1 ) | script -q "$pty_out" bash -c "bash '$BENCH_DIR/cleanup.sh' --all" >/dev/null 2>&1 || true
  rm -f "$pty_out"
  # The run dir must still exist (the 'n' answer declined the removal).
  [ -d "$BENCH_OUT/alpha/A/1" ]
}

# --- guard integration -------------------------------------------------------

@test "cleanup.sh: BENCH_OUT unset falls back to /tmp/pi-bench (lib.sh default)" {
  # lib.sh:25 does BENCH_OUT="${BENCH_OUT-/tmp/pi-bench}" — when BENCH_OUT
  # is unset, it is set to the default before bench_out_guard runs. The
  # guard's "unset" path is therefore unreachable; the script operates
  # on the default BENCH_OUT (/tmp/pi-bench). We verify the script runs
  # and does not crash, but we do NOT verify it refuses (that path is
  # unreachable by design).
  local BENCH_DIR_LOCAL="$BENCH_DIR"
  local out rc
  out="$(env -u BENCH_OUT bash -c "bash '$BENCH_DIR_LOCAL/cleanup.sh' --list" 2>&1)"
  rc=$?
  # The script runs successfully against the default BENCH_OUT.
  [ "$rc" -eq 0 ]
  [[ "$out" == *"/tmp/pi-bench"* ]]
}

@test "cleanup.sh: relative BENCH_OUT is refused" {
  run bash -c "BENCH_OUT=relative/path bash '$BENCH_DIR/cleanup.sh' --list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"absolute path"* ]]
}

@test "cleanup.sh: empty BENCH_OUT is refused" {
  run bash -c "BENCH_OUT= bash '$BENCH_DIR/cleanup.sh' --list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BENCH_OUT"* ]]
}
