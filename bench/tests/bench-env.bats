#!/usr/bin/env bats
# BATS tests: bench task environment fixes —
#   1. every bench/*.sh entry point is executable in the git index (100755)
#   2. the pi shim records every invocation, including ones killed by
#      orchestrate's PI_TIMEOUT (SIGTERM/SIGKILL → exit 143/137), and
#      collect.sh counts them in pi_call_count.
#
# No real claude or pi is invoked — the killed-pi test uses a stub `pi`
# that sleeps. All commands run under `timeout` with safe-env
# (GIT_TERMINAL_PROMPT=0 EDITOR=true VISUAL=true PAGER=cat GIT_PAGER=cat).
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
  REPO_ROOT="$(cd "$BENCH_DIR/.." && pwd)"

  command -v jq >/dev/null 2>&1 || { skip "jq is not installed"; }
  command -v git >/dev/null 2>&1 || { skip "git is not installed"; }

  export GIT_TERMINAL_PROMPT=0 EDITOR=true VISUAL=true PAGER=cat GIT_PAGER=cat

  BENCH_OUT="$(mktemp -d)"
  export BENCH_OUT
  TASKS_DIR="$BENCH_OUT/tasks"
  mkdir -p "$TASKS_DIR"
  export TASKS_DIR
}

teardown() {
  rm -rf "${BENCH_OUT:-}"
}

# --- bench/*.sh entry points: executable in the git index ---------------------

# The docs invoke the bench scripts directly (bench/collect.sh ...); git
# records the executable bit (mode 100755 vs 100644), so a 100644 entry
# point lands non-executable after a clean checkout and fails with
# "Permission denied". lib.sh is sourced, not invoked, and is intentionally
# not executable in the index.
_entry_points() {
  echo "collect.sh"
  echo "grade.sh"
  echo "run-arm.sh"
  echo "setup-run.sh"
}

@test "bench: every bench/*.sh entry point is mode 100755 in the git index" {
  local mode f
  for f in $(_entry_points); do
    mode="$(git -C "$REPO_ROOT" ls-files -s "bench/$f" | awk '{print $1}')"
    [ "$mode" = "100755" ]
  done
}

@test "bench: collect.sh runs directly (./ path) — executable bit is honoured" {
  # The worktree files are chmod +x'd by the operator (main checkout), so
  # a direct `./collect.sh` here is valid only if the index bit is set —
  # the committed mode bit (100755) is what a clean checkout gets. The
  # previous test (100755 in the git index) is the primary guard; this test
  # verifies the bit is actually applied in THIS worktree (i.e. the commit
  # landed and git applied the mode).
  local rc=0
  ( cd "$BENCH_DIR" && timeout 30 ./collect.sh ) >/dev/null 2>&1 || rc=$?
  # A non-zero usage error is fine (no args); 126 = not executable (the
  # bug this test pins), 127 = not found.
  [ "$rc" -ne 126 ]
  [ "$rc" -ne 127 ]
}

# --- pi shim: killed invocations are recorded --------------------------------

# _install_killer_pi_shim <d> — writes a stub "real pi" (sleep 10, SIGTERM-
# trap exits 143, SIGKILL is fatal) on PATH and installs the harness shim
# into <d>/run.
_install_killer_pi_shim() {
  local d="$1"
  mkdir -p "$d/stub" "$d/run"
  cat > "$d/stub/pi" <<'EOF'
#!/usr/bin/env bash
trap 'exit 143' TERM
sleep 10
exit 0
EOF
  chmod +x "$d/stub/pi"
  PATH="$d/stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; install_pi_shim '$d/run'"
}

@test "shim: a SIGTERM-killed pi call is recorded (exit 143) and counted" {
  local d="$BENCH_OUT/kill-term"
  _install_killer_pi_shim "$d"

  # Invoke the shim in the background, SIGTERM it after the stub pi is
  # sleeping (the stub traps TERM and exits 143, mirroring a pi call
  # killed by orchestrate's timeout wrapper — PI_TIMEOUT → 143).
  "$d/run/bin/pi" -p "kill me" >/dev/null 2>&1 &
  local shim_pid=$!
  sleep 2
  kill -TERM "$shim_pid" 2>/dev/null || true
  local rc=0
  wait "$shim_pid" 2>/dev/null || rc=$?
  # 143 = 128 + SIGTERM (the stub's trapped exit).
  [ "$rc" -eq 143 ]

  # The shim must have written a metadata line for the killed call.
  local line
  line="$(head -n 1 "$d/run/pi-calls.jsonl")"
  echo "$line" | jq -e '.exit == 143' >/dev/null
  echo "$line" | jq -e '.mode == "text"' >/dev/null
  # Duration is a number (0 for the killed call: the trap records before
  # the wall clock advances — the exit code is the signal of the kill).
  echo "$line" | jq -e '(.duration_ms | type) == "number"' >/dev/null

  # collect.sh counts the killed call: pi_call_count == 1. The task env
  # points at a non-REPO (collect never clones; the task dir only has to
  # exist under TASKS_DIR).
  local run_dir="$BENCH_OUT/kill-task/A/1"
  mkdir -p "$BENCH_OUT/tasks/kill-task" "$run_dir/claude"
  cat > "$BENCH_OUT/tasks/kill-task/task.env" <<EOF
REPO=/nonexistent
BASE_SHA=x
FIX_SHA=x
TEST_CMD=true
GRADING_PATCH=
EOF
  printf '{"total_cost_usd":0,"duration_ms":100,"duration_api_ms":100,"permission_denials":[],"modelUsage":{}}' \
    > "$run_dir/claude/output.json"
  printf '{"base_sha":"basesha"}' > "$run_dir/setup.json"
  printf '{"model":"stub","perm_mode":"auto"}' > "$run_dir/run-meta.json"
  printf '{"pass":true,"test_cmd":"true","error":null}' > "$run_dir/grade.json"
  cp "$d/run/pi-calls.jsonl" "$run_dir/pi-calls.jsonl"

  run bash "$BENCH_DIR/collect.sh" kill-task A 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_call_count == 1' >/dev/null
  echo "$output" | jq -e '.pi[0].exit == 143' >/dev/null
}

@test "shim: a completed call is still recorded exactly once (exit 0)" {
  local d="$BENCH_OUT/kill-ok"
  mkdir -p "$d/stub" "$d/run"
  cat > "$d/stub/pi" <<'EOF'
#!/usr/bin/env bash
echo "done"
exit 0
EOF
  chmod +x "$d/stub/pi"
  PATH="$d/stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; install_pi_shim '$d/run'"

  local rc=0
  "$d/run/bin/pi" -p "fast task" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]

  local n
  n="$(wc -l < "$d/run/pi-calls.jsonl" | tr -d ' ')"
  [ "$n" -eq 1 ]
  head -n 1 "$d/run/pi-calls.jsonl" | jq -e '.exit == 0' >/dev/null
}
