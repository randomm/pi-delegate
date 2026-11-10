#!/usr/bin/env bats
# BATS tests for bench/quick.sh run-dir cleanup and bench/lib.sh warn_low_space
# (issue #60), and for the class-grouped table + failing_check_cases row
# field and the retry-feedback experiment (issue #96 D1/D3/D4). Stub
# claude/pi/df binaries only: no network, no root.
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

# --- issue #96: class taxonomy, grouped reporting, verification-bug metric ----

@test "quick.sh groups the table by task class and reports failing_check_cases" {
  run timeout 120 bash "$BENCH_DIR/quick.sh" -k slugify </dev/null
  [ "$status" -eq 0 ]
  # Class group header from slugify/task.env (CLASS=MECHANICAL), the brief
  # style column, and the failing-check-cases column on the summary line.
  [[ "$output" == *"CLASS MECHANICAL"* ]]
  [[ "$output" == *"PINPOINT"* ]]
  [[ "$output" == *"fbc="* ]]
  kept="$(printf '%s\n' "$output" | sed -n 's/^runs kept in //p' | tail -1)"
  [ -n "$kept" ]
  run jq -e '.class == "MECHANICAL" and .brief_style == "PINPOINT"
             and (.failing_check_cases | type) == "number"' \
       "$kept/slugify-A-1/row.json"
  [ "$status" -eq 0 ]
}

@test "quick.sh: agent-authored test failures never count as hidden-check cases" {
  # Regression (issue #96 review): one shared check.log let the agent's own
  # `unittest discover` FAILED summary be summed into the hidden-check bug
  # count. Reference solution (hidden check passes) + an agent test that
  # always fails -> pass=false but failing_check_cases must be 0, and the
  # two phases must live in separate logs.
  local ref="$BENCH_DIR/tests/fixtures/references/tokenize-lines"
  [ -d "$ref" ]
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
    "cp -R \"$ref/.\" ." \
    'mkdir -p tests' \
    'printf "import unittest\nclass Bad(unittest.TestCase):\n    def test_bad(self):\n        self.assertTrue(False)\n" > tests/test_bad.py' \
    'echo "{\"total_cost_usd\":0.01,\"num_turns\":1,\"duration_ms\":1000}"' > "$STUBS/claude"
  run timeout 120 bash "$BENCH_DIR/quick.sh" -k tokenize-lines </dev/null
  [ "$status" -eq 0 ]
  kept="$(printf '%s\n' "$output" | sed -n 's/^runs kept in //p' | tail -1)"
  [ -n "$kept" ]
  run jq -e '.pass == false and .failing_check_cases == 0' "$kept/tokenize-lines-A-1/row.json"
  [ "$status" -eq 0 ]
  # The agent-authored failure lives only in agent-tests.log…
  grep -q 'failures=1' "$kept/tokenize-lines-A-1/agent-tests.log"
  # …and the hidden-check log holds no agent output.
  ! grep -q 'test_bad' "$kept/tokenize-lines-A-1/check.log"
}

@test "quick.sh class-c: a hanging agent test suite yields a bounded FAIL" {
  # Stub claude implements debounce-queue correctly (reference solution) but
  # adds a test that waits forever — grading must time out and score
  # pass=false instead of wedging (QUICK_CHECK_TIMEOUT keeps it fast).
  local ref="$BENCH_DIR/tests/fixtures/references/debounce-queue"
  [ -d "$ref" ]
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
    "cp -R \"$ref/.\" ." \
    'mkdir -p tests' \
    'printf "import time\nimport unittest\nclass Hang(unittest.TestCase):\n    def test_hang(self):\n        time.sleep(600)\n" > tests/test_hang.py' \
    'echo "{\"total_cost_usd\":0.01,\"num_turns\":1,\"duration_ms\":1000}"' > "$STUBS/claude"
  run env QUICK_CHECK_TIMEOUT=3 timeout 120 bash "$BENCH_DIR/quick.sh" -k debounce-queue </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *REWARD* ]]
  kept="$(printf '%s\n' "$output" | sed -n 's/^runs kept in //p' | tail -1)"
  [ -n "$kept" ]
  # The hidden check alone would pass with the reference solution; the
  # hanging agent tests must drag it to pass=false.
  run jq -e '.pass == false' "$kept/debounce-queue-A-1/row.json"
  [ "$status" -eq 0 ]
}

@test "quick.sh new class tasks: hidden check passes on the reference solution" {
  # The base-fails half is covered everywhere (stub claude implements
  # nothing -> pass=false); this asserts the passes-on-reference half.
  for task in tokenize-lines debounce-queue move-report cache-pinpoint cache-discovery; do
    local ref="$BENCH_DIR/tests/fixtures/references/$task"
    [ -d "$ref" ]
    printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
      "cp -R \"$ref/.\" ." \
      'echo touched > touched.txt' \
      'echo "{\"total_cost_usd\":0.01,\"num_turns\":1,\"duration_ms\":1000}"' > "$STUBS/claude"
    run timeout 120 bash "$BENCH_DIR/quick.sh" -k "$task" </dev/null
    [ "$status" -eq 0 ]
    kept="$(printf '%s\n' "$output" | sed -n 's/^runs kept in //p' | tail -1)"
    [ -n "$kept" ]
    run jq -e '.pass == true' "$kept/$task-A-1/row.json"
    [ "$status" -eq 0 ] || { echo "task $task: reference solution did not pass check.py" >&3; return 1; }
  done
}

# --- issue #96: retry-feedback experiment -------------------------------------

@test "experiment-retry-feedback.sh: one invocation, rows for both arms with the three metrics" {
  # Stub pi never implements anything -> initial verify fails -> both arms
  # retry; stub claude authors the instruction and carries a cost.
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$STUBS/pi"
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
    'echo "{\"result\":\"1. Fix split_fields escape branch\",\"total_cost_usd\":0.02,\"num_turns\":1,\"duration_ms\":900}"' > "$STUBS/claude"
  run timeout 120 bash "$BENCH_DIR/experiment-retry-feedback.sh" tokenize-lines </dev/null
  [ "$status" -eq 0 ]
  rows="$(echo "$output" | grep '^{' || true)"
  echo "$rows" | jq -se 'length == 2' >/dev/null
  echo "$rows" | jq -se 'all(has("retry_success") and has("pi_retry_tokens") and has("claude_instruction_cost_usd"))' >/dev/null
  echo "$rows" | jq -se '[.[].arm] | sort == ["A","B"]' >/dev/null
  # arm A pays nothing for instructions; arm B records the stub's 0.02.
  echo "$rows" | jq -se '[.[] | select(.arm=="A")][0].claude_instruction_cost_usd == null' >/dev/null
  echo "$rows" | jq -se '[.[] | select(.arm=="B")][0].claude_instruction_cost_usd == 0.02' >/dev/null
  # Contamination guards exist: arm A has no author call (null), arm B's
  # stub author leaves the repo untouched (false), and the leak counter is
  # a number on both rows.
  echo "$rows" | jq -se '[.[] | select(.arm=="A")][0].author_touched_repo == null' >/dev/null
  echo "$rows" | jq -se '[.[] | select(.arm=="B")][0].author_touched_repo == false' >/dev/null
  echo "$rows" | jq -se 'all(.feedback_dropped_lines | type == "number")' >/dev/null
}

@test "experiment-retry-feedback.sh: pi runs inside the per-run repo copy, never the invoking dir" {
  # Regression (issue #96 review, CRITICAL): pi_call lacked a cd, so pi
  # landed in the operator's live tree, both arms' verify graded a copy pi
  # never touched, and every retry_success was false. A stub pi that
  # records $PWD pins the contract: every invocation runs with cwd ending
  # in the per-run /repo copy.
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' 'echo "$PWD" >> "$PI_CWD_LOG"' > "$STUBS/pi"
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
    'echo "{\"result\":\"1. Fix split_fields escape branch\",\"total_cost_usd\":0.02,\"num_turns\":1,\"duration_ms\":900}"' > "$STUBS/claude"
  export PI_CWD_LOG="$WORK/pi.cwd"; : > "$PI_CWD_LOG"
  ( cd "$BENCH_DIR" && timeout 120 bash ./experiment-retry-feedback.sh tokenize-lines ) </dev/null
  # pi1 + retry per arm = 4 invocations, all inside a repo copy.
  [ "$(wc -l < "$PI_CWD_LOG" | tr -d ' ')" -ge 4 ]
  [ "$(grep -cv '/repo$' "$PI_CWD_LOG")" -eq 0 ]
}

@test "experiment-retry-feedback.sh: retry prompt never names or quotes the hidden check" {
  # Regression (issue #96 review, round 2). Two channels leaked the oracle:
  # (a) the grader sat at $d/check.py, one `../check.py` from either model
  # cwd, and (b) the excerpt denylist let unittest's COLUMN-0 assertion diff
  # through — `+ ['a""b']` is the hidden expected value itself. Now the
  # grader is staged outside the run tree and deleted before every model
  # call, and verify_excerpt is an allowlist. Assert both, on the real
  # tokenize-lines failure output (non-vacuous: the base repo fails).
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$STUBS/pi"
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
    'echo "{\"result\":\"1. Fix split_fields escape branch\",\"total_cost_usd\":0.02,\"num_turns\":1,\"duration_ms\":900}"' > "$STUBS/claude"
  run timeout 120 bash "$BENCH_DIR/experiment-retry-feedback.sh" -k tokenize-lines </dev/null
  [ "$status" -eq 0 ]
  kept="$(printf '%s\n' "$output" | sed -n 's/^runs kept in //p' | tail -1)"
  [ -n "$kept" ]
  # (a) No grading file inside the run tree at all — the model-reachable
  # half of the run dir. The raw logs live in the separate private dir.
  [ -z "$(find "$kept" \( -name 'check.py' -o -name '_check.py' \) -print)" ]
  # (b) No oracle content in either arm's retry prompt: the expected value
  # the grader asserts, the diff block, or any grader path/source line.
  for arm in A B; do
    local prompt="$kept/tokenize-lines-$arm-1/retry.txt"
    [ -s "$prompt" ]
    ! grep -qF 'a""b' "$prompt"
    ! grep -qF 'First differing' "$prompt"
    ! grep -qF 'assertEqual' "$prompt"
    ! grep -qE '^\s*[+-] \[' "$prompt"
    ! grep -qF 'check.py' "$prompt"
    # No run-dir path survives either (the excerpt scrubs absolute paths to
    # <path> rather than dropping the informative line with them).
    ! grep -qF "$kept" "$prompt"
  done
  # The excerpt kept unittest's structural lines (so the prompt still says
  # which cases failed) and the leak counter is a real number.
  grep -qE '^FAIL: test_' "$kept/tokenize-lines-A-1/retry.txt"
  run jq -se 'all(.feedback_dropped_lines >= 1)' "$kept"/*/row.json
  [ "$status" -eq 0 ]
}

@test "experiment-retry-feedback.sh: the grader is absent from the run tree while models run" {
  # The read channel round 2 flagged: a claude author sitting in $d/author
  # could `sed -n '1,6p' ../check.py` and print the grading tests, with
  # author_touched_repo still false (it only snapshots writes); pi had the
  # same reach from $d/repo. Both the grader and the raw verify log now live
  # in a private dir OUTSIDE the run tree, so a probe from either model cwd
  # must find nothing in the tree it can traverse to. (Probing the whole of
  # TMPDIR would race a sibling run's verify window, which is why the probe
  # is scoped to the run tree.)
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
    ': > "$PROBE_RAN_CLAUDE"' \
    'find "$PWD/.." \( -name check.py -o -name verify.log \) -print >> "$PROBE_OUT" 2>/dev/null' \
    'echo "{\"result\":\"1. Fix split_fields escape branch\",\"total_cost_usd\":0.02,\"num_turns\":1,\"duration_ms\":900}"' > "$STUBS/claude"
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
    ': > "$PROBE_RAN_PI"' \
    'find "$PWD/.." \( -name check.py -o -name verify.log \) -print >> "$PROBE_OUT" 2>/dev/null' \
    'exit 0' > "$STUBS/pi"
  export PROBE_RAN_CLAUDE="$WORK/probe.claude"
  export PROBE_RAN_PI="$WORK/probe.pi"
  export PROBE_OUT="$WORK/probe.found"; : > "$PROBE_OUT"
  run timeout 120 bash "$BENCH_DIR/experiment-retry-feedback.sh" tokenize-lines </dev/null
  [ "$status" -eq 0 ]
  # Both model calls really ran, and neither found a grading file or raw log
  # inside the run tree it could have read.
  [ -f "$PROBE_RAN_CLAUDE" ]
  [ -f "$PROBE_RAN_PI" ]
  [ ! -s "$PROBE_OUT" ]
}

@test "experiment-retry-feedback.sh: -n rejects a non-numeric run count" {
  run bash "$BENCH_DIR/experiment-retry-feedback.sh" -n abc slugify </dev/null
  [ "$status" -eq 2 ]
}
