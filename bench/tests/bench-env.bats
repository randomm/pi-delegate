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
  local rc=0
  ( cd "$BENCH_DIR" && timeout 30 ./collect.sh ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 126 ]
  [ "$rc" -ne 127 ]
}

# --- pi shim: killed invocations are recorded --------------------------------

# _install_killer_pi_shim <d> — writes a stub "real pi" (touch readiness
# file, sleep 10, SIGTERM-trap exits 143) on PATH and installs the harness
# shim into <d>/run.
_install_killer_pi_shim() {
  local d="$1"
  mkdir -p "$d/stub" "$d/run"
  # Use an unquoted heredoc so $d is expanded into the stub script.
  cat > "$d/stub/pi" <<STUB
#!/usr/bin/env bash
trap 'exit 143' TERM
touch "$d/stub/ready"
sleep 10
exit 0
STUB
  chmod +x "$d/stub/pi"
  PATH="$d/stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; install_pi_shim '$d/run'"
}

@test "shim: a SIGTERM-killed pi call is recorded (exit 143) and counted" {
  local d="$BENCH_OUT/kill-term"
  _install_killer_pi_shim "$d"

  "$d/run/bin/pi" -p "kill me" >/dev/null 2>&1 &
  local shim_pid=$!
  # Wait for the stub pi to touch the readiness file.
  local i=0
  while [ $i -lt 100 ] && [ ! -f "$d/stub/ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "$d/stub/ready" ]
  kill -TERM "$shim_pid" 2>/dev/null || true
  local rc=0
  wait "$shim_pid" 2>/dev/null || rc=$?
  [ "$rc" -eq 143 ]

  # One record file in pi-calls.d/ with exit 143.
  local call_id rec
  call_id="$(ls "$d/run/pi-calls.d/" | grep -v '^\.' | head -n 1)"
  [ -n "$call_id" ]
  rec="$d/run/pi-calls.d/$call_id"
  [ -f "$rec" ]
  jq -e '.exit == 143' "$rec" >/dev/null
  jq -e '.mode == "text"' "$rec" >/dev/null
  jq -e '(.duration_ms | type) == "number"' "$rec" >/dev/null

  # collect.sh counts the killed call: pi_call_count == 1.
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
  cp -r "$d/run/pi-calls.d" "$run_dir/pi-calls.d"

  run bash "$BENCH_DIR/collect.sh" kill-task A 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_call_count == 1' >/dev/null
  echo "$output" | jq -e '.pi[0].exit == 143' >/dev/null
}

@test "shim: a completed call yields one record file with the real exit and duration" {
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

  # One record file in pi-calls.d/, with the real exit and duration.
  local n call_id
  n="$(ls "$d/run/pi-calls.d/" | grep -v '^\.' | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ]
  call_id="$(ls "$d/run/pi-calls.d/" | grep -v '^\.' | head -n 1)"
  local rec="$d/run/pi-calls.d/$call_id"
  jq -e '.exit == 0' "$rec" >/dev/null
  jq -e '(.duration_ms | type) == "number"' "$rec" >/dev/null

  # collect.sh counts the completed call: pi_call_count == 1.
  local run_dir="$BENCH_OUT/kill-ok-task/A/1"
  mkdir -p "$BENCH_OUT/tasks/kill-ok-task" "$run_dir/claude"
  cat > "$BENCH_OUT/tasks/kill-ok-task/task.env" <<EOF
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
  cp -r "$d/run/pi-calls.d" "$run_dir/pi-calls.d"

  run bash "$BENCH_DIR/collect.sh" kill-ok-task A 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_call_count == 1' >/dev/null
}

@test "shim: two sequential completed calls each retain their record (no truncation)" {
  local d="$BENCH_OUT/kill-two"
  mkdir -p "$d/stub" "$d/run"
  cat > "$d/stub/pi" <<'EOF'
#!/usr/bin/env bash
echo "call done: $1"
exit 0
EOF
  chmod +x "$d/stub/pi"
  PATH="$d/stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; install_pi_shim '$d/run'"

  local rc=0
  "$d/run/bin/pi" -p "task one" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
  sleep 1
  "$d/run/bin/pi" -p "task two" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]

  # Two record files in pi-calls.d/ (one per call).
  local n
  n="$(ls "$d/run/pi-calls.d/" | grep -v '^\.' | wc -l | tr -d ' ')"
  [ "$n" -eq 2 ]

  # Both records have exit 0.
  for f in "$d/run/pi-calls.d/"*.json; do
    [ -e "$f" ] || continue
    jq -e '.exit == 0' "$f" >/dev/null
  done

  # collect.sh counts both calls: pi_call_count == 2.
  local run_dir="$BENCH_OUT/kill-two-task/A/1"
  mkdir -p "$BENCH_OUT/tasks/kill-two-task" "$run_dir/claude"
  cat > "$BENCH_OUT/tasks/kill-two-task/task.env" <<EOF
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
  cp -r "$d/run/pi-calls.d" "$run_dir/pi-calls.d"

  run bash "$BENCH_DIR/collect.sh" kill-two-task A 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_call_count == 2' >/dev/null
}
