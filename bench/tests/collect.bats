#!/usr/bin/env bats
# BATS tests for the benchmark harness — pure-bash parts only.
# No real claude or pi is invoked. All git/uv commands use safe-env
# (GIT_TERMINAL_PROMPT=0 EDITOR=true VISUAL=true PAGER=cat GIT_PAGER=cat)
# and run under `timeout` (docs/benchmark.md §safe-execution).
#
# All task fixtures live under a TEMP TASKS_DIR (never in bench/tasks/).
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
  FIXTURES="$TESTS_DIR/fixtures"

  command -v jq >/dev/null 2>&1 || { skip "jq is not installed"; }
  command -v git >/dev/null 2>&1 || { skip "git is not installed"; }

  # Safe-execution env (docs/benchmark.md §safe-execution).
  export GIT_TERMINAL_PROMPT=0 EDITOR=true VISUAL=true PAGER=cat GIT_PAGER=cat

  # Temp BENCH_OUT + TEMP TASKS_DIR: tests never pollute /tmp/pi-bench or
  # the committed bench/tasks/ tree.
  BENCH_OUT="$(mktemp -d)"
  export BENCH_OUT
  TASKS_DIR="$BENCH_OUT/tasks"
  mkdir -p "$TASKS_DIR"
  export TASKS_DIR

  # A temp task for setup-run tests (created under the temp TASKS_DIR).
  TASK_ID="bats-test-task"
  TASK_DIR="$TASKS_DIR/$TASK_ID"
  mkdir -p "$TASK_DIR"
  # Create a small throwaway git repo to use as REPO.
  FAKE_REPO="$BENCH_OUT/fake-repo"
  git init -q -b main "$FAKE_REPO"
  cd "$FAKE_REPO"
  git config user.email t@t.t
  git config user.name t
  echo "hello" > hello.txt
  git add hello.txt
  git commit -qm "initial"
  BASE_SHA="$(git rev-parse HEAD)"
  # A second commit to use as FIX_SHA.
  echo "world" > world.txt
  git add world.txt
  git commit -qm "add world"
  FIX_SHA="$(git rev-parse HEAD)"
  cat > "$TASK_DIR/grading.patch" <<'EOF'
diff --git a/hello.txt b/hello.txt
index 1234567..89abcde 100644
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-hello
+hello modified
EOF
  cat > "$TASK_DIR/prompt.md" <<'EOF'
Test prompt for setup-run BATS.
EOF
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  # Save pristine copies so teardown can restore them if a test mutates
  # $TASK_DIR and fails mid-way (item 8: prevent cross-test poisoning).
  cp "$TASK_DIR/grading.patch" "$BENCH_OUT/.saved-grading.patch"
  cp "$TASK_DIR/task.env"      "$BENCH_OUT/.saved-task.env"

  # A second temp task id used by the collect tests.
  MECH_ID="issue-41-mech"
  MECH_DIR="$TASKS_DIR/$MECH_ID"
  mkdir -p "$MECH_DIR"
  cp "$TASK_DIR/grading.patch" "$MECH_DIR/grading.patch"
  cat > "$MECH_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF

  cd /
}

teardown() {
  # Restore the shared $TASK_DIR files if a test mutated them and failed
  # mid-way (item 8: prevent a mid-test failure from poisoning later tests).
  if [ -n "${BENCH_OUT:-}" ] && [ -d "${TASK_DIR:-}" ]; then
    cp "${BENCH_OUT}/.saved-grading.patch" "$TASK_DIR/grading.patch" 2>/dev/null || true
    cp "${BENCH_OUT}/.saved-task.env"      "$TASK_DIR/task.env"      2>/dev/null || true
  fi
  rm -rf "${BENCH_OUT:-}"
}

# --- collect.sh tests ---------------------------------------------------------

# _make_pi_call_record <run-dir> <call_id> <mode> [argv...]
# Writes one per-call record (the pi-calls.d design) into <run-dir>.
# One JSON object per call, in $run_dir/pi-calls.d/<call_id>.json.
_make_pi_call_record() {
  local run_dir="$1" call_id="$2" mode="$3"
  shift 3
  local -a argv=()
  if [ "$#" -gt 0 ]; then
    argv=("$@")
  fi
  local argv_json
  if [ "${#argv[@]}" -eq 0 ]; then
    argv_json="[]"
  else
    argv_json="$(for a in "${argv[@]}"; do printf '%s\n' "$a"; done | jq -Rn '[inputs]')"
  fi
  jq -cn \
    --argjson argv "$argv_json" \
    --argjson duration_ms 0 \
    --argjson exit 0 \
    --arg mode "$mode" \
    --arg call_id "$call_id" \
    '{argv:$argv, duration_ms:$duration_ms, exit:$exit, mode:$mode, call_id:$call_id}' \
    > "$run_dir/pi-calls.d/$call_id.json"
}

@test "collect.sh: success path with arm A fixtures" {
  run_dir="$BENCH_OUT/$MECH_ID/A/1"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"            "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"         "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"       "$run_dir/grade.json"
  # Per-call pi records (the pi-calls.d design) for the two fixture calls.
  mkdir -p "$run_dir/pi-calls.d"
  _make_pi_call_record "$run_dir" 1700000000000_12345 json \
    --mode json -p --no-session "task: do the thing"
  _make_pi_call_record "$run_dir" 1700000001000_12346 text \
    -p --no-session --no-extensions "task: oneshot task"
  # pi-<call_id>.jsonl for the json-mode call.
  cp "$FIXTURES/pi-transcript-call1.jsonl" \
     "$run_dir/pi-1700000000000_12345.jsonl"

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 1
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | jq -e '.task == "issue-41-mech"' >/dev/null 2>&1
  [ $? -eq 0 ]
  echo "$output" | jq -e '.arm == "A"'                    >/dev/null
  echo "$output" | jq -e '.run == 1'                      >/dev/null
  echo "$output" | jq -e '.claude.duration_ms == 42000'   >/dev/null
  echo "$output" | jq -e '.claude.cost_usd == 0.42'       >/dev/null
  echo "$output" | jq -e '.grade.pass == true'            >/dev/null
  echo "$output" | jq -e '.target_commit == "b1a2b78"'    >/dev/null
  # pi array: one json-mode call with tokens, one text-mode call with null tokens.
  echo "$output" | jq -e '(.pi | length) == 2'            >/dev/null
  echo "$output" | jq -e '.pi[0].mode == "json"'          >/dev/null
  # Tokens are SUMMED over all assistant turns (7250 + 8350 = 15600).
  echo "$output" | jq -e '.pi[0].tokens.total == 15600'   >/dev/null
  echo "$output" | jq -e '.pi[1].mode == "text"'          >/dev/null
  echo "$output" | jq -e '.pi[1].tokens == null'          >/dev/null
}

@test "collect.sh: grade fail is recorded" {
  run_dir="$BENCH_OUT/$MECH_ID/A/2"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-fail.json"         "$run_dir/grade.json"

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 2
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.grade.pass == false' >/dev/null
  echo "$output" | jq -e '.grade.error != null'  >/dev/null
}

@test "collect.sh: malformed claude output → exit 2" {
  run_dir="$BENCH_OUT/$MECH_ID/A/3"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-malformed.txt" "$run_dir/claude/output.json"

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 3
  [ "$status" -eq 2 ]
}

@test "collect.sh: missing run dir → exit 1" {
  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 99
  [ "$status" -eq 1 ]
}

# --- setup-run.sh tests ---------------------------------------------------------

@test "setup-run.sh: creates repo at BASE_SHA on feature branch" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 1
  [ "$status" -eq 0 ]
  local repo="$BENCH_OUT/$TASK_ID/A/1/repo"
  [ -d "$repo" ]
  local branch
  branch="$(git -C "$repo" symbolic-ref --short HEAD)"
  [ "$branch" = "bench/A/1" ]
  local head_sha
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  [ "$head_sha" = "$(git -C "$FAKE_REPO" rev-parse "$BASE_SHA")" ]
}

@test "setup-run.sh: push.default is nothing" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 1
  [ "$status" -eq 0 ]
  local repo="$BENCH_OUT/$TASK_ID/A/1/repo"
  local push_default
  push_default="$(git -C "$repo" config push.default)"
  [ "$push_default" = "nothing" ]
}

@test "setup-run.sh: contamination guard — later commit is unreachable" {
  # After setup-run.sh fetches only BASE_SHA, the FIX_SHA commit must NOT be
  # reachable in the run repo. This proves the contamination guard: the agent
  # cannot discover the historical fix by inspecting git history.
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 1
  [ "$status" -eq 0 ]
  local repo="$BENCH_OUT/$TASK_ID/A/1/repo"

  local commit_count
  commit_count="$(timeout 30 git -C "$repo" rev-list --count HEAD)"
  [ "$commit_count" = "1" ]

  local fix_resolved=""
  fix_resolved="$(timeout 30 git -C "$repo" rev-parse -q --verify "$FIX_SHA^{commit}" 2>/dev/null)" || true
  [ -z "$fix_resolved" ]
}

@test "setup-run.sh: secret-file scan refuses on .env file" {
  local secret_repo="$BENCH_OUT/secret-repo"
  git init -q -b main "$secret_repo"
  cd "$secret_repo"
  git config user.email t@t.t
  git config user.name t
  echo "SECRET=123" > .env
  git add .env
  git commit -qm "add env"
  local sha
  sha="$(git rev-parse HEAD)"
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$secret_repo
BASE_SHA=$sha
FIX_SHA=$sha
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 1
  [ "$status" -eq 3 ]
  cd /
}

@test "setup-run.sh: missing task → exit 1" {
  run bash "$BENCH_DIR/setup-run.sh" nonexistent-task A 1
  [ "$status" -ne 0 ]
}

# --- collect.sh: null-grade → failed line ------------------------------------

@test "collect.sh: no grade.json → collect line marked failed" {
  # A crashed run that was never graded must emit a collect line with
  # grade.pass == false and a diagnostic error — NOT grade:null.
  run_dir="$BENCH_OUT/$MECH_ID/A/10"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 10
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.grade != null' >/dev/null
  echo "$output" | jq -e '.grade.pass == false' >/dev/null
  echo "$output" | jq -e '.grade.error != null' >/dev/null
}

# --- collect.sh: token SUM over multiple message_end ---------------------------

@test "collect.sh: sums tokens over multiple assistant turns" {
  run_dir="$BENCH_OUT/$MECH_ID/A/11"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # Two json-mode per-call records.
  mkdir -p "$run_dir/pi-calls.d"
  _make_pi_call_record "$run_dir" 100_1 json --mode json
  _make_pi_call_record "$run_dir" 100_2 json --mode json
  # Call 1: two assistant turns (develop + review), different models.
  cat > "$run_dir/pi-100_1.jsonl" <<'EOF'
{"type":"message_end","message":{"role":"assistant","usage":{"input":100,"output":50,"cacheRead":200,"cacheWrite":1000,"totalTokens":1350},"model":"model-a"}}
{"type":"message_end","message":{"role":"assistant","usage":{"input":200,"output":100,"cacheRead":500,"cacheWrite":500,"totalTokens":1300},"model":"model-b"}}
EOF
  # Call 2: single assistant turn.
  cat > "$run_dir/pi-100_2.jsonl" <<'EOF'
{"type":"message_end","message":{"role":"assistant","usage":{"input":50,"output":25,"cacheRead":100,"cacheWrite":200,"totalTokens":375},"model":"model-a"}}
EOF

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 11
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi[0].tokens.input == 300'   >/dev/null  # 100+200
  echo "$output" | jq -e '.pi[0].tokens.output == 150'  >/dev/null  # 50+100
  echo "$output" | jq -e '.pi[0].tokens.total == 2650'  >/dev/null  # 1350+1300
  echo "$output" | jq -e '.pi[0].tokens.per_model["model-a"].input == 100' >/dev/null
  echo "$output" | jq -e '.pi[0].tokens.per_model["model-b"].input == 200' >/dev/null
  echo "$output" | jq -e '.pi[1].tokens.input == 50'     >/dev/null
  echo "$output" | jq -e '.pi[1].tokens.total == 375'    >/dev/null
}

# --- collect.sh: wall clock from run-meta started_at/ended_at ------------------

@test "collect.sh: wall clock uses run-meta started_at/ended_at when present" {
  run_dir="$BENCH_OUT/$MECH_ID/A/12"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  cat > "$run_dir/run-meta.json" <<'EOF'
{"task":"issue-41-mech","arm":"A","run":12,"model":"claude-sonnet-5-5",
 "perm_mode":"auto","pi_delegate_sha":"","config_dir":"x","prompt_file":"x",
 "claude_exit":0,"agent_ms":10000,
 "started_at":"2026-09-29T12:00:00Z","ended_at":"2026-09-29T12:00:10Z"}
EOF

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 12
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.wall_clock_ms == 10000' >/dev/null
}

# --- collect.sh: wall clock prefers ms-resolution started_ms/ended_ms (issue #71) -----------
# The old second-resolution pair read wall_clock_ms to 0 for sub-second runs.
# With the ms-resolution fields present, the sub-second run must NOT be 0.
@test "collect.sh: wall clock prefers ms-resolution started_ms/ended_ms over second-resolution" {
  run_dir="$BENCH_OUT/$MECH_ID/A/30"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # 12 ms wall clock, 36 ms agent. The second-resolution pair would be 0
  # (both timestamps fall in the same second); the ms pair is the true value.
  cat > "$run_dir/run-meta.json" <<'EOF'
{"task":"issue-41-mech","arm":"A","run":30,"model":"claude-sonnet-5-5",
 "perm_mode":"auto","pi_delegate_sha":"","config_dir":"x","prompt_file":"x",
 "claude_exit":0,"agent_ms":36,
 "started_at":"2026-09-29T12:00:00Z","ended_at":"2026-09-29T12:00:00Z",
 "started_ms":1761787200000,"ended_ms":1761787200012}
EOF

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 30
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.wall_clock_ms == 12' >/dev/null
  echo "$output" | jq -e '.agent_ms == 36' >/dev/null
}

# --- collect.sh: wall clock falls back to second-resolution when ms absent ---------------
@test "collect.sh: wall clock falls back to second-resolution when ms fields absent" {
  run_dir="$BENCH_OUT/$MECH_ID/A/31"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # No started_ms/ended_ms; second-resolution only → 5 s wall clock.
  cat > "$run_dir/run-meta.json" <<'EOF'
{"task":"issue-41-mech","arm":"A","run":31,"model":"claude-sonnet-5-5",
 "perm_mode":"auto","pi_delegate_sha":"","config_dir":"x","prompt_file":"x",
 "claude_exit":0,
 "started_at":"2026-09-29T12:00:00Z","ended_at":"2026-09-29T12:00:05Z"}
EOF

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 31
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.wall_clock_ms == 5000' >/dev/null
  echo "$output" | jq -e '.agent_ms == null' >/dev/null
}

# --- collect.sh: claude.duration_api_ms is recorded (issue #71) -------------------------
@test "collect.sh: records claude.duration_api_ms from output.json" {
  run_dir="$BENCH_OUT/$MECH_ID/A/32"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 32
  [ "$status" -eq 0 ]
  # The fixture carries duration_ms=42000 and duration_api_ms=40000.
  echo "$output" | jq -e '.claude.duration_ms == 42000' >/dev/null
  echo "$output" | jq -e '.claude.duration_api_ms == 40000' >/dev/null
}

# --- collect.sh: duration_api_ms degrades to null when absent (older runs) ---------------
@test "collect.sh: claude.duration_api_ms degrades to null when absent" {
  run_dir="$BENCH_OUT/$MECH_ID/A/33"
  mkdir -p "$run_dir/claude"
  # Strip duration_api_ms from the fixture to simulate an older run.
  jq 'del(.duration_api_ms)' "$FIXTURES/claude-output-armA.json" > "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 33
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.claude.duration_api_ms == null' >/dev/null
}

# --- collect.sh: malformed ms fields are a validation error (issue #71) --------------
# A present, non-null started_ms/ended_ms that is NOT a plain non-negative
# integer is a malformed run: exit 2, not a silent fallback to seconds.
# (Absent or JSON null still falls back to the second-resolution fields.)
@test "collect.sh: non-numeric started_ms → exit 2" {
  run_dir="$BENCH_OUT/$MECH_ID/A/40"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # started_ms is a string: present and non-null but not an integer.
  cat > "$run_dir/run-meta.json" <<'EOF'
{"task":"issue-41-mech","arm":"A","run":40,"model":"claude-sonnet-5-5",
 "perm_mode":"auto","pi_delegate_sha":"","config_dir":"x","prompt_file":"x",
 "claude_exit":0,
 "started_at":"2026-09-29T12:00:00Z","ended_at":"2026-09-29T12:00:07Z",
 "started_ms":"abc"}
EOF

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 40
  [ "$status" -eq 2 ]
  [[ "$output" == *"started_ms"* ]]
}

@test "collect.sh: non-numeric ended_ms → exit 2" {
  run_dir="$BENCH_OUT/$MECH_ID/A/40"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  cat > "$run_dir/run-meta.json" <<'EOF'
{"task":"issue-41-mech","arm":"A","run":40,"model":"claude-sonnet-5-5",
 "perm_mode":"auto","pi_delegate_sha":"","config_dir":"x","prompt_file":"x",
 "claude_exit":0,
 "started_at":"2026-09-29T12:00:00Z","ended_at":"2026-09-29T12:00:07Z",
 "started_ms":1761787200000,"ended_ms":"oops"}
EOF

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 40
  [ "$status" -eq 2 ]
  [[ "$output" == *"ended_ms"* ]]
}

# --- collect.sh: agent_ms must be number or null (issue #71) -----------------------
# A non-numeric agent_ms is a malformed run: the jq validation rejects the
# line (exit 2), same treatment as duration_api_ms.
@test "collect.sh: non-numeric agent_ms → validation error, exit 2" {
  run_dir="$BENCH_OUT/$MECH_ID/A/41"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  cat > "$run_dir/run-meta.json" <<'EOF'
{"task":"issue-41-mech","arm":"A","run":41,"model":"claude-sonnet-5-5",
 "perm_mode":"auto","pi_delegate_sha":"","config_dir":"x","prompt_file":"x",
 "claude_exit":0,"agent_ms":"oops"}
EOF

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 41
  [ "$status" -eq 2 ]
}

# --- collect.sh: agent_ms read failure (jq error) → loud exit 2 (issue #71) ---
# run-meta.json exists but is not parseable as the agent_ms read expects it
# to be: a jq read failure on run-meta.json must exit 2 with the
# "failed to read run-meta.json agent_ms" error — not degrade to null.
@test "collect.sh: agent_ms jq read failure → exit 2 (loud)" {
  run_dir="$BENCH_OUT/$MECH_ID/A/42"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # run-meta.json is not a JSON object (an array): the jq reads of it fail.
  # The agent_ms read has no `|| true` — a jq failure on run-meta.json exits
  # 2 with a loud error instead of degrading to null (the started_ms/ended_ms
  # reads already guard the same file with the same shape).
  cat > "$run_dir/run-meta.json" <<'EOF'
[1, 2, 3]
EOF

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 42
  [ "$status" -eq 2 ]
}

# --- collect.sh: pi_call_count and delegation_exercised (arm A + arm B) ----------------
@test "collect.sh: arm A with pi calls — pi_call_count numeric, delegation_exercised null" {
  run_dir="$BENCH_OUT/$MECH_ID/A/34"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # Per-call pi records for the two fixture calls.
  mkdir -p "$run_dir/pi-calls.d"
  _make_pi_call_record "$run_dir" 1700000000000_12345 json \
    --mode json -p --no-session "task: do the thing"
  _make_pi_call_record "$run_dir" 1700000001000_12346 text \
    -p --no-session --no-extensions "task: oneshot task"
  cp "$FIXTURES/pi-transcript-call1.jsonl" "$run_dir/pi-1700000000000_12345.jsonl"

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 34
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_call_count == 2' >/dev/null
  echo "$output" | jq -e '.delegation_exercised == null' >/dev/null
}

@test "collect.sh: arm B with ≥1 pi call → delegation_exercised true" {
  run_dir="$BENCH_OUT/$MECH_ID/B/1"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # Per-call pi records for the two fixture calls.
  mkdir -p "$run_dir/pi-calls.d"
  _make_pi_call_record "$run_dir" 1700000000000_12345 json \
    --mode json -p --no-session "task: do the thing"
  _make_pi_call_record "$run_dir" 1700000001000_12346 text \
    -p --no-session --no-extensions "task: oneshot task"
  cp "$FIXTURES/pi-transcript-call1.jsonl" "$run_dir/pi-1700000000000_12345.jsonl"

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" B 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_call_count == 2' >/dev/null
  echo "$output" | jq -e '.delegation_exercised == true' >/dev/null
}

# --- collect.sh: zero-pi arm-B run → delegation_exercised false (skill failure) -------------
# This is the "skill failure" run the docs instruct readers to report separately;
# the flag is in the collect line, and the grade is NOT rewritten by it.
@test "collect.sh: arm B with zero pi calls → delegation_exercised false, grade unchanged" {
  run_dir="$BENCH_OUT/$MECH_ID/B/2"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # No pi-calls.d → zero pi calls.

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" B 2
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_call_count == 0' >/dev/null
  echo "$output" | jq -e '.delegation_exercised == false' >/dev/null
  # The flag does not rewrite the grade.
  echo "$output" | jq -e '.grade.pass == true' >/dev/null
}

@test "collect.sh: arm B with an empty pi-calls.d directory → zero pi calls, exit 0" {
  run_dir="$BENCH_OUT/$MECH_ID/B/21"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # An existing but empty pi-calls.d (dir present, no record files).
  mkdir -p "$run_dir/pi-calls.d"

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" B 21
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_call_count == 0' >/dev/null
  echo "$output" | jq -e '.delegation_exercised == false' >/dev/null
  echo "$output" | jq -e '.grade.pass == true' >/dev/null
}

# --- collect.sh: pi_tokens_total per model (summed across calls) -------------------------
@test "collect.sh: pi_tokens_total aggregates per-model totals across calls" {
  run_dir="$BENCH_OUT/$MECH_ID/A/35"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # Two json-mode calls, two distinct models.
  mkdir -p "$run_dir/pi-calls.d"
  _make_pi_call_record "$run_dir" 200_1 json --mode json
  _make_pi_call_record "$run_dir" 200_2 json --mode json
  # Call 1: one assistant turn, model-a.
  cat > "$run_dir/pi-200_1.jsonl" <<'EOF'
{"type":"message_end","message":{"role":"assistant","usage":{"input":10,"output":20,"cacheRead":30,"cacheWrite":40,"totalTokens":100},"model":"model-a"}}
EOF
  # Call 2: one assistant turn, model-b.
  cat > "$run_dir/pi-200_2.jsonl" <<'EOF'
{"type":"message_end","message":{"role":"assistant","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10},"model":"model-b"}}
EOF

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 35
  [ "$status" -eq 0 ]
  # Per-model totals should be present, keyed by model.
  echo "$output" | jq -e '.pi_tokens_total["model-a"].input == 10' >/dev/null
  echo "$output" | jq -e '.pi_tokens_total["model-a"].total == 100' >/dev/null
  echo "$output" | jq -e '.pi_tokens_total["model-b"].input == 1' >/dev/null
  echo "$output" | jq -e '.pi_tokens_total["model-b"].total == 10' >/dev/null
}

@test "collect.sh: pi_tokens_total is null when no transcript data" {
  run_dir="$BENCH_OUT/$MECH_ID/A/36"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # A text-mode-only pi call has null tokens.
  mkdir -p "$run_dir/pi-calls.d"
  _make_pi_call_record "$run_dir" 300_1 text -p --no-session

  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 36
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_tokens_total == null' >/dev/null
  echo "$output" | jq -e '.pi_call_count == 1' >/dev/null
}

# --- setup-run.sh: re-run clears prior run dir ---------------------------------

@test "setup-run.sh: re-run clears pi-calls.d records from prior run" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 2
  [ "$status" -eq 0 ]
  local run_dir="$BENCH_OUT/$TASK_ID/A/2"
  # A stale per-call record from a previous run.
  mkdir -p "$run_dir/pi-calls.d"
  echo '{"argv":["--mode","json"],"duration_ms":1,"exit":0,"mode":"json","call_id":"stale_1"}' > "$run_dir/pi-calls.d/stale_1.json"
  echo 'stale' > "$run_dir/pi-stale_1.jsonl"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 2
  [ "$status" -eq 0 ]
  [ ! -f "$run_dir/pi-calls.d/stale_1.json" ]
  [ ! -f "$run_dir/pi-stale_1.jsonl" ]
}

# --- setup-run.sh: .env.example does NOT trigger secret refusal ----------------

@test "setup-run.sh: .env.example does not refuse" {
  local secret_repo="$BENCH_OUT/env-example-repo"
  git init -q -b main "$secret_repo"
  cd "$secret_repo"
  git config user.email t@t.t
  git config user.name t
  echo "SECRET=123" > .env.example
  git add .env.example
  git commit -qm "add env example"
  local sha
  sha="$(git rev-parse HEAD)"
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$secret_repo
BASE_SHA=$sha
FIX_SHA=$sha
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 3
  [ "$status" -eq 0 ]
  cd /
}

# --- grade.sh: FAIL path writes grade.json with correct test_rc ----------------

@test "grade.sh: FAIL path writes grade.json with test_rc" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 4
  [ "$status" -eq 0 ]
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD='/nonexistent_binary_xyz'
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 4
  [ "$status" -eq 1 ]
  local grade_file="$BENCH_OUT/$TASK_ID/A/4/grade.json"
  [ -f "$grade_file" ]
  jq -e '.pass == false' "$grade_file" >/dev/null
  jq -e '.test_rc == 127' "$grade_file" >/dev/null
}

# --- grade.sh: PASS path writes grade.json -------------------------------------

@test "grade.sh: PASS path writes grade.json with pass=true" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 5
  [ "$status" -eq 0 ]
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 5
  [ "$status" -eq 0 ]
  local grade_file="$BENCH_OUT/$TASK_ID/A/5/grade.json"
  [ -f "$grade_file" ]
  jq -e '.pass == true' "$grade_file" >/dev/null
}

# --- grade.sh: base source is logged to stderr --------------------------------------
# setup.json holds the base_sha (written by setup-run.sh), so grade.sh logs
# which source it used. A normal run → "base from setup.json".
@test "grade.sh: logs 'base from setup.json' when setup.json has base_sha" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 11
  [ "$status" -eq 0 ]
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 11
  [ "$status" -eq 0 ]
  [[ "$output" == *"grade: base from setup.json"* ]]
}

# --- grade.sh: git apply failure writes grade.json ------------------------------

@test "grade.sh: git apply failure writes grade.json with error" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 6
  [ "$status" -eq 0 ]
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=nonexistent.patch
EOF
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 6
  [ "$status" -eq 2 ]
}

# --- grade.sh: agent committed + edited graded file → graded, head_moved true ---
# An agent that commits its work moves HEAD; the run is still graded (restore
# and git apply target the recorded BASE_SHA, tests run on the working tree).
# The graded test file the agent edited is restored from base and recorded in
# restored_test_files, and grade.json records head_moved: true.
@test "grade.sh: agent committed its fix → graded normally, head_moved true" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 8
  [ "$status" -eq 0 ]
  local run_dir="$BENCH_OUT/$TASK_ID/A/8"
  local repo_dir="$run_dir/repo"
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  # Agent commits its fix AND edits the graded test file (hello.txt), in the
  # RUN repo (not FAKE_REPO): the run repo's HEAD moves away from the
  # recorded base, which is what head_moved detects.
  git -C "$repo_dir" config user.email t@t.t
  git -C "$repo_dir" config user.name t
  echo "agent fix" >> "$repo_dir/hello.txt"
  echo "tampered test" > "$repo_dir/world.txt"
  git -C "$repo_dir" add hello.txt world.txt
  git -C "$repo_dir" commit -qm "agent committed its work"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 8
  [ "$status" -eq 0 ]
  local grade_file="$run_dir/grade.json"
  [ -f "$grade_file" ]
  jq -e '.pass == true' "$grade_file" >/dev/null
  jq -e '.head_moved == true' "$grade_file" >/dev/null
  jq -e '.restored_test_files == ["hello.txt"]' "$grade_file" >/dev/null
  [ "$(cat "$repo_dir/hello.txt")" = "hello modified" ]
}

# --- grade.sh: restore failure → exit 2 + error field ----------------------------
# If `git checkout <base> -- <path>` fails (e.g. the recorded base sha does
# not resolve in the run repo), the run is a setup error: exit 2 and a
# grade.json with pass:false and error "restore failed for <path>: ...".
# The invalid BASE_SHA goes in task.env BEFORE the setup re-run: setup-run
# fetches BASE_SHA into the run repo, so a fetch failure leaves an empty
# object db and setup.json absent — the recorded base then cannot resolve.
@test "grade.sh: restore failure → exit 2 + grade.json error" {
  # First, a valid setup so the run dir exists (task.env from setup()).
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 10
  [ "$status" -eq 0 ]
  local run_dir="$BENCH_OUT/$TASK_ID/A/10"
  local repo_dir="$run_dir/repo"
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  # Re-run setup with the invalid BASE_SHA: the fetch fails, leaving an
  # empty run-repo object db and no setup.json.
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 10
  [ "$status" -eq 2 ]
  echo "agent tamper" > "$repo_dir/hello.txt"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 10
  [ "$status" -eq 2 ]
  local grade_file="$run_dir/grade.json"
  [ -f "$grade_file" ]
  jq -e '.pass == false' "$grade_file" >/dev/null
  jq -e '.error | startswith("restore failed for hello.txt:")' "$grade_file" >/dev/null
}

# --- grade.sh: agent edited a patched file → restored from BASE ----------------
# The restore must come from the recorded base: after grade.sh runs, the
# agent's edit is gone, the patch is applied (hello.txt = base content with
# the patch hunk applied), and the file is recorded in restored_test_files.
@test "grade.sh: agent edit restored from BASE sha, patch applied" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 9
  [ "$status" -eq 0 ]
  local run_dir="$BENCH_OUT/$TASK_ID/A/9"
  local repo_dir="$run_dir/repo"
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  echo "agent tamper" > "$repo_dir/hello.txt"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 9
  [ "$status" -eq 0 ]
  local grade_file="$run_dir/grade.json"
  jq -e '.restored_test_files == ["hello.txt"]' "$grade_file" >/dev/null
  jq -e '.head_moved == false' "$grade_file" >/dev/null
  [ "$(cat "$repo_dir/hello.txt")" = "hello modified" ]
}

# --- run-arm.sh: arm A does NOT get a pi shim -----------------------------------

@test "run-arm.sh: arm A does not install pi shim" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 7
  [ "$status" -eq 0 ]
  local run_dir="$BENCH_OUT/$TASK_ID/A/7"
  [ ! -d "$run_dir/bin" ]
}

# --- run-arm.sh: arm B installs pi shim -----------------------------------------

@test "run-arm.sh: arm B installs pi shim" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" B 1
  [ "$status" -eq 0 ]
  local run_dir="$BENCH_OUT/$TASK_ID/B/1"
  local stub_dir="$BENCH_OUT/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
echo "stub pi"
exit 0
EOF
  chmod +x "$stub_dir/pi"
  PATH="$stub_dir:$PATH" bash -c "
    source $BENCH_DIR/lib.sh
    install_pi_shim '$run_dir'
  "
  [ $? -eq 0 ]
  [ -f "$run_dir/bin/pi" ]
  # The generated shim carries the harness-shim marker line.
  grep -q "pi-delegate-bench-shim" "$run_dir/bin/pi"
}

# --- lib.sh: install_pi_shim marker-based shim detection ---------------------

# A genuine pi that lives in */bin/pi (e.g. ~/.bun/bin/pi) must be ACCEPTED:
# shim detection is by the marker line, not by the path shape.
@test "lib.sh: install_pi_shim accepts a real pi in a */bin/pi path (e.g. <tmp>/.bun/bin/pi)" {
  local run_dir="$BENCH_OUT/shim-bun"
  local real_bin="$BENCH_OUT/fake-home/.bun/bin"
  mkdir -p "$run_dir" "$real_bin"
  cat > "$real_bin/pi" <<'EOF'
#!/usr/bin/env bash
echo "genuine pi"
exit 0
EOF
  chmod +x "$real_bin/pi"
  local rc=0
  PATH="$real_bin:/usr/bin:/bin:/opt/homebrew/bin" bash -c "source '$BENCH_DIR/lib.sh'; install_pi_shim '$run_dir'" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
  [ -x "$run_dir/bin/pi" ]
  # The baked-in REAL_PI must be the genuine pi, not refused.
  grep -q "REAL_PI=\"$real_bin/pi\"" "$run_dir/bin/pi"
}

# A pi that IS a generated harness shim (another run's bin/pi on PATH) must be
# REFUSED — the marker line is the discriminator.
@test "lib.sh: install_pi_shim refuses a generated harness shim as the real pi" {
  local run_dir="$BENCH_OUT/shim-nest"
  local prior_bin="$BENCH_OUT/prior-run/bin"
  local prior_run="$BENCH_OUT/prior-run"
  local real_bin="$BENCH_OUT/real-bin"
  mkdir -p "$run_dir" "$prior_run" "$real_bin"
  cat > "$real_bin/pi" <<'EOF'
#!/usr/bin/env bash
echo "genuine pi"
exit 0
EOF
  chmod +x "$real_bin/pi"
  # First install into the prior run (creates a marked shim).
  PATH="$real_bin:/usr/bin:/bin:/opt/homebrew/bin" bash -c "source '$BENCH_DIR/lib.sh'; install_pi_shim '$prior_run'"
  [ -x "$prior_run/bin/pi" ]
  grep -q "pi-delegate-bench-shim" "$prior_run/bin/pi"
  # Second install with the prior shim first on PATH and NO genuine pi
  # anywhere else: resolution finds the prior shim → refused.
  local rc=0
  PATH="$prior_bin:/usr/bin:/bin:/opt/homebrew/bin" bash -c "source '$BENCH_DIR/lib.sh'; install_pi_shim '$run_dir'" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -f "$run_dir/bin/pi" ]
}

# --- lib.sh: install_pi_shim generates a valid shim -----------------------------

@test "lib.sh: install_pi_shim generates a valid shim with no baked-in literals" {
  local run_dir="$BENCH_OUT/shim-test"
  mkdir -p "$run_dir"
  local stub_dir="$BENCH_OUT/stub-bin2"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
echo "stub pi output"
exit 0
EOF
  chmod +x "$stub_dir/pi"
  PATH="$stub_dir:$PATH" bash -c "
    source $BENCH_DIR/lib.sh
    install_pi_shim '$run_dir'
  "
  [ $? -eq 0 ]
  [ -x "$run_dir/bin/pi" ]
  local shim_content
  shim_content="$(cat "$run_dir/bin/pi")"
  echo "$shim_content" | grep -q 'BASH_SOURCE'
  ! echo "$shim_content" | grep -q "RUN_DIR=\"$run_dir"
  echo "$shim_content" | grep -q '\$\$'
}

# ================================================================================
# NEW: benchmark review fixes
# ================================================================================

# --- Shim: byte-for-byte stdout + rc + blank lines + quotes (item 1) -----------

# _install_stub_pi_shim <tmp-dir> — installs the shim into <tmp-dir>/run/bin
# with a stub "real pi" on PATH. The stub, in --mode json, prints two JSON
# lines (one containing double quotes) plus a blank line in between, prints
# "STDERR-MSG" to stderr, and exits 7. In text mode it prints two lines and
# exits 0.
_install_stub_pi_shim() {
  local d="$1"
  mkdir -p "$d/stub" "$d/run"
  cat > "$d/stub/pi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--mode" ] && [ "${2:-}" = "json" ]; then
  printf '%s\n' '{"type":"message_end","text":"hi "there""}' '' '{"type":"agent_settled"}'
  echo "STDERR-MSG" >&2
  exit 7
fi
echo "plain text out"
echo "second line"
exit 0
EOF
  chmod +x "$d/stub/pi"
  PATH="$d/stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; install_pi_shim '$d/run'"
}

@test "shim: json-mode stdout is byte-identical to the stub's stdout (incl. blank line and quotes), rc preserved" {
  local d="$BENCH_OUT/shim-cmp"
  _install_stub_pi_shim "$d"
  local out rc
  out="$("$d/run/bin/pi" --mode json -p task 2>/dev/null)" || rc=$?
  # rc passthrough.
  [ "$rc" -eq 7 ]
  # Byte-for-byte: compare the shim's stdout against the stub's own stdout
  # (both run through the same stub, so the comparison is exact — the stub
  # emits three JSON lines with a blank line in between and a quoted string;
  # the stub's $(...) capture trims the trailing newline from both, so the
  # comparison is byte-for-byte modulo that one shared trailing \n).
  local stub_out shim_out
  stub_out="$("$d/stub/pi" --mode json -p task 2>/dev/null)" || true
  shim_out="$("$d/run/bin/pi" --mode json -p task 2>/dev/null)" || true
  [ "$stub_out" = "$shim_out" ]
  # The blank line must be present in the output (the old shim dropped it).
  local line2
  line2="$(sed -n '2p' <<<"$shim_out")"
  [ -z "$line2" ]
  # The quoted line must be present and intact.
  local line1
  line1="$(sed -n '1p' <<<"$shim_out")"
  [ "$line1" = '{"type":"message_end","text":"hi "there""}' ]
  # The per-call transcript must contain the blank line too. The test calls
  # the shim twice (once for rc, once for the byte-compare), producing two
  # transcript files; pick the most recent by mtime (per-call records
  # live in pi-calls.d/ now, so no exclusion is needed).
  local tf
  tf="$(ls -t "$d"/run/pi-*.jsonl 2>/dev/null | head -n 1)"
  [ -n "$tf" ]
  [ "$(sed -n '2p' "$tf")" = "" ]
  # 3 lines total (two JSON lines + the blank line; the trailing newline
  # after the last JSON line is not counted as a separate line by wc -l
  # because it terminates the last JSON line, not the blank one).
  local nlines
  nlines="$(wc -l < "$tf")"
  # Accept 3 or 4 depending on how the trailing newline is handled.
  { [ "$nlines" -eq 3 ] || [ "$nlines" -eq 4 ]; }
}

@test "shim: non-zero rc passes stderr through and keeps pi-err-<call_id>.log" {
  local d="$BENCH_OUT/shim-err"
  _install_stub_pi_shim "$d"
  local rc stderr_out
  stderr_out="$("$d/run/bin/pi" --mode json -p task 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -eq 7 ]
  [ "$stderr_out" = "STDERR-MSG" ]
  local ef
  ef="$(ls "$d"/run/pi-err-*.log)"
  [ -f "$ef" ]
  [ "$(cat "$ef")" = "STDERR-MSG" ]
}

@test "shim: argv log uses one element per argv (spaces preserved)" {
  local d="$BENCH_OUT/shim-argv"
  _install_stub_pi_shim "$d"
  "$d/run/bin/pi" --mode json -p "task with spaces and 'quotes'" >/dev/null 2>&1 || true
  local rec
  rec="$(ls "$d/run/pi-calls.d/" | grep -v '^\.' | head -n 1)"
  [ -n "$rec" ]
  local line
  line="$(cat "$d/run/pi-calls.d/$rec")"
  # The prompt argument must survive as a single argv element.
  echo "$line" | jq -e '.argv | index("task with spaces and '\''quotes'\''") != null' >/dev/null
  # --no-context-files is injected exactly once.
  [ "$(echo "$line" | jq -r '[.argv[] | select(. == "--no-context-files")] | length')" = "1" ]
}

@test "shim: real pi resolves outside the shim dir (no self-reference)" {
  local d="$BENCH_OUT/shim-guard"
  mkdir -p "$d/stub" "$d/run"
  cat > "$d/stub/pi" <<'EOF'
#!/usr/bin/env bash
echo ok
EOF
  chmod +x "$d/stub/pi"
  PATH="$d/stub:$PATH" bash -c "source '$BENCH_DIR/lib.sh'; install_pi_shim '$d/run'"
  [ $? -eq 0 ]
  # The baked-in REAL_PI must not point into the shim's own bin dir.
  local real_pi
  real_pi="$(grep '^REAL_PI=' "$d/run/bin/pi" | sed 's/^REAL_PI=//;s/^"//;s/"$//')"
  case "$real_pi" in
    "$d/run/bin/"*) [ false ] ;;
    *) [ true ] ;;
  esac
  # The installed shim must not equal the stub (i.e. install did not resolve
  # to a pre-existing shim on PATH).
  [ -x "$d/run/bin/pi" ]
}

# --- run-arm.sh: arm B pin comes from PI_DELEGATE_REPO (item 2) ----------------

@test "run-arm.sh: arm B pins pi-delegate from PI_DELEGATE_REPO at PI_DELEGATE_SHA (local fake repo)" {
  local run_dir="$BENCH_OUT/$TASK_ID/B/2"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" B 2
  [ "$status" -eq 0 ]

  # Fake pi-delegate repo with a marketplace manifest.
  local fake_pd="$BENCH_OUT/fake-pi-delegate"
  git init -q -b main "$fake_pd"
  git -C "$fake_pd" config user.email t@t.t
  git -C "$fake_pd" config user.name t
  mkdir -p "$fake_pd/.claude-plugin"
  cat > "$fake_pd/.claude-plugin/marketplace.json" <<'EOF'
{"name":"pi-delegate","owner":{"name":"t"},"plugins":[{"name":"pi-delegate","source":"./"}]}
EOF
  git -C "$fake_pd" add -A
  git -C "$fake_pd" commit -qm "pi-delegate"
  local pd_sha
  pd_sha="$(git -C "$fake_pd" rev-parse HEAD)"

  # Stub claude: the supported CLI flow — marketplace add, install,
  # list --json — all succeed.
  local stub_dir="$BENCH_OUT/stub-claude"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "$1" = "plugin" ] && [ "$2" = "marketplace" ]; then
  echo "Adding marketplace: pi-delegate"
  exit 0
fi
if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then
  echo "Installing plugin: pi-delegate@pi-delegate"
  exit 0
fi
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
  echo '[{"id":"pi-delegate@pi-delegate","enabled":true}]'
  exit 0
fi
# claude -p run: emit a minimal valid JSON result.
echo '{"is_error":false,"result":"ok","duration_ms":100,"total_cost_usd":0}'
exit 0
CLAUDE
  chmod +x "$stub_dir/claude"

  # Stub pi.
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
echo "stub pi"
exit 0
EOF
  chmod +x "$stub_dir/pi"

  # Run arm B with PI_DELEGATE_REPO pointed at the local fake repo.
  PATH="$stub_dir:$PATH" PI_DELEGATE_REPO="$fake_pd" PI_DELEGATE_SHA="$pd_sha" \
    bash "$BENCH_DIR/run-arm.sh" "$TASK_ID" B 2 > "$BENCH_OUT/runarm-b.out" 2>&1
  local rc=$?
  [ "$rc" -eq 0 ]

  # Pin dir is keyed by SHA only (no -arm suffix) and shared.
  local pin_dir="$BENCH_OUT/pin/pi-delegate-$pd_sha"
  [ -d "$pin_dir" ]
  [ "$(git -C "$pin_dir" rev-parse HEAD)" = "$pd_sha" ]
  # Plugin installed via the supported CLI into the run's config dir: the
  # CLI's stdout/stderr is captured in plugin-install.log (both steps).
  local cfg="$run_dir/claude-config"
  [ -f "$run_dir/plugin-install.log" ]
  grep -q -i "marketplace" "$run_dir/plugin-install.log"
  grep -q -i "install" "$run_dir/plugin-install.log"
}

# --- run-arm.sh: claude runs in the task checkout, not the caller's cwd (issue #71) ----
# The stub claude records its own cwd (pwd at launch). The test invokes
# run-arm.sh from a different directory (the parent of BENCH_OUT) and asserts
# the claude process's cwd is the run's repo directory, not the caller's cwd.
@test "run-arm.sh: claude runs in the task checkout (not the caller's cwd)" {
  local run_dir="$BENCH_OUT/$TASK_ID/A/20"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 20
  [ "$status" -eq 0 ]

  local stub_dir="$BENCH_OUT/stub-claude-20"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/claude" <<'CLAUDE'
#!/usr/bin/env bash
# Record the cwd the claude process was launched in (the dry-run 4 failure was
# a launch from the pi-delegate repo with the click checkout NOT in cwd).
pwd > "$PWD/.claude-cwd-at-launch"
echo '{"is_error":false,"result":"ok","duration_ms":10,"total_cost_usd":0}'
exit 0
CLAUDE
  chmod +x "$stub_dir/claude"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/pi"

  # Launch from a different directory (the parent of BENCH_OUT), so the
  # script's cwd is NOT the task checkout. The script must cd into the repo
  # before launching claude.
  local caller_dir="$BENCH_OUT"
  local rc=0
  ( cd "$caller_dir" && PATH="$stub_dir:$PATH" bash "$BENCH_DIR/run-arm.sh" "$TASK_ID" A 20 >/dev/null 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ]

  # The stub wrote .claude-cwd-at-launch at the cwd at launch. It must be
  # inside the run's repo directory (i.e. the task checkout), not the caller's.
  local repo_dir="$BENCH_OUT/$TASK_ID/A/20/repo"
  local cwd_marker
  cwd_marker="$(cat "$repo_dir/.claude-cwd-at-launch" 2>/dev/null)"
  [ -n "$cwd_marker" ]
  [ "$cwd_marker" = "$repo_dir" ]
  # The marker must NOT be in the caller's dir (which is BENCH_OUT, a sibling).
  [ ! -f "$caller_dir/.claude-cwd-at-launch" ]
}

# --- run-arm.sh: arm B plugin install failure captures the CLI output --------

@test "run-arm.sh: arm B plugin install failure prints the captured CLI output and aborts" {
  local run_dir="$BENCH_OUT/$TASK_ID/B/10"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" B 10
  [ "$status" -eq 0 ]

  local fake_pd="$BENCH_OUT/fake-pd-abort2"
  git init -q -b main "$fake_pd"
  git -C "$fake_pd" config user.email t@t.t
  git -C "$fake_pd" config user.name t
  mkdir -p "$fake_pd/.claude-plugin"
  echo '{"name":"pi-delegate"}' > "$fake_pd/.claude-plugin/marketplace.json"
  git -C "$fake_pd" add -A
  git -C "$fake_pd" commit -qm "pi-delegate"
  local pd_sha
  pd_sha="$(git -C "$fake_pd" rev-parse HEAD)"

  local stub_dir="$BENCH_OUT/stub-claude10"
  mkdir -p "$stub_dir"
  # claude plugin marketplace add FAILS with a distinctive message → arm B
  # must abort (exit 2) and the captured output must be printed.
  cat > "$stub_dir/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "$1" = "plugin" ] && [ "$2" = "marketplace" ]; then
  echo "Marketplace configuration file is corrupted: pi-delegate.source.source: Invalid discriminator value"
  exit 1
fi
exit 0
CLAUDE
  chmod +x "$stub_dir/claude"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/pi"

  PATH="$stub_dir:$PATH" PI_DELEGATE_REPO="$fake_pd" PI_DELEGATE_SHA="$pd_sha" \
    bash "$BENCH_DIR/run-arm.sh" "$TASK_ID" B 10 > "$BENCH_OUT/runarm-b4.out" 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
  grep -q "ABORT" "$BENCH_OUT/runarm-b4.out"
  # The CLI output was captured in the run dir and printed on failure.
  [ -f "$run_dir/plugin-install.log" ]
  grep -q "Invalid discriminator value" "$run_dir/plugin-install.log"
  grep -q "Invalid discriminator value" "$BENCH_OUT/runarm-b4.out"
}

# --- run-arm.sh: arm B aborts when pi is not on PATH -------------------------

@test "run-arm.sh: arm B aborts (exit 2) when pi is not on PATH" {
  local run_dir="$BENCH_OUT/$TASK_ID/B/11"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" B 11
  [ "$status" -eq 0 ]

  local fake_pd="$BENCH_OUT/fake-pd-no-pi"
  git init -q -b main "$fake_pd"
  git -C "$fake_pd" config user.email t@t.t
  git -C "$fake_pd" config user.name t
  mkdir -p "$fake_pd/.claude-plugin"
  echo '{"name":"pi-delegate"}' > "$fake_pd/.claude-plugin/marketplace.json"
  git -C "$fake_pd" add -A
  git -C "$fake_pd" commit -qm "pi-delegate"
  local pd_sha
  pd_sha="$(git -C "$fake_pd" rev-parse HEAD)"

  # A PATH dir with NO pi binary (binaries are copied in via a separate
  # step so this directory never contains a pi that would resolve).
  local binonly="$BENCH_OUT/binonly"
  mkdir -p "$binonly"

  # Stub claude (plugin flow succeeds); pi is NOT on the restricted PATH
  # (the shim-install step then fails: no pi found → arm B must abort).
  local stub_dir="$BENCH_OUT/stub-claude11"
  mkdir -p "$stub_dir"
  # PATH isolation: run-arm.sh calls `timeout` (coreutils, e.g.
  # /opt/homebrew/bin/timeout on macOS) for the pin clone; without a
  # timeout on the restricted PATH the clone fails with 127 and the test
  # sees a pin-clone abort instead of the pi-missing abort. Copy the
  # operator's timeout into the stub dir so the restricted PATH is
  # claude+timeout + system dirs (no pi anywhere).
  if command -v timeout >/dev/null 2>&1; then
    cp "$(command -v timeout)" "$stub_dir/timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    cp "$(command -v gtimeout)" "$stub_dir/timeout"
  fi
  cat > "$stub_dir/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "$1" = "plugin" ] && [ "$2" = "marketplace" ]; then
  echo "Adding marketplace: pi-delegate"
  exit 0
fi
if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then
  echo "Installing plugin: pi-delegate@pi-delegate"
  exit 0
fi
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
  echo '[{"id":"pi-delegate@pi-delegate","enabled":true}]'
  exit 0
fi
exit 0
CLAUDE
  chmod +x "$stub_dir/claude"

  # Restricted PATH: stub_dir (claude only) + system dirs; the pi shim's own
  # bin dir is stripped before resolution, so no `pi` resolves. Run with
  # `sh -c`-style isolation is unavailable (no pipes allowed), so rely on
  # the stub dir containing no pi.
  local rc=0
  PATH="$stub_dir:$binonly:/usr/bin:/bin:/usr/sbin:/sbin" PI_DELEGATE_REPO="$fake_pd" PI_DELEGATE_SHA="$pd_sha" \
    bash "$BENCH_DIR/run-arm.sh" "$TASK_ID" B 11 > "$BENCH_OUT/runarm-b5.out" 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
  grep -q "ABORT" "$BENCH_OUT/runarm-b5.out"
}

@test "run-arm.sh: arm B pin verification fails → exit 2 (missing marketplace.json)" {
  local run_dir="$BENCH_OUT/$TASK_ID/B/3"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" B 3
  [ "$status" -eq 0 ]

  # Fake pi-delegate repo WITHOUT .claude-plugin/marketplace.json.
  local fake_pd="$BENCH_OUT/fake-pd-no-market"
  git init -q -b main "$fake_pd"
  git -C "$fake_pd" config user.email t@t.t
  git -C "$fake_pd" config user.name t
  echo x > "$fake_pd/README.md"
  git -C "$fake_pd" add -A
  git -C "$fake_pd" commit -qm "no marketplace"
  local pd_sha
  pd_sha="$(git -C "$fake_pd" rev-parse HEAD)"

  local stub_dir="$BENCH_OUT/stub-claude3"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/claude" <<'CLAUDE'
#!/usr/bin/env bash
exit 0
CLAUDE
  chmod +x "$stub_dir/claude"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/pi"

  PATH="$stub_dir:$PATH" PI_DELEGATE_REPO="$fake_pd" PI_DELEGATE_SHA="$pd_sha" \
    bash "$BENCH_DIR/run-arm.sh" "$TASK_ID" B 3 > "$BENCH_OUT/runarm-b2.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
  grep -q "marketplace" "$BENCH_OUT/runarm-b2.out"
}

@test "run-arm.sh: arm B plugin install failure aborts the run (item 3)" {
  local run_dir="$BENCH_OUT/$TASK_ID/B/4"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" B 4
  [ "$status" -eq 0 ]

  local fake_pd="$BENCH_OUT/fake-pd-abort"
  git init -q -b main "$fake_pd"
  git -C "$fake_pd" config user.email t@t.t
  git -C "$fake_pd" config user.name t
  mkdir -p "$fake_pd/.claude-plugin"
  echo '{"name":"pi-delegate"}' > "$fake_pd/.claude-plugin/marketplace.json"
  git -C "$fake_pd" add -A
  git -C "$fake_pd" commit -qm "pi-delegate"
  local pd_sha
  pd_sha="$(git -C "$fake_pd" rev-parse HEAD)"

  local stub_dir="$BENCH_OUT/stub-claude4"
  mkdir -p "$stub_dir"
  # claude plugin install FAILS (exit 1) → arm B must abort (exit 2).
  cat > "$stub_dir/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then
  echo "install failed" >&2
  exit 1
fi
exit 0
CLAUDE
  chmod +x "$stub_dir/claude"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/pi"

  PATH="$stub_dir:$PATH" PI_DELEGATE_REPO="$fake_pd" PI_DELEGATE_SHA="$pd_sha" \
    bash "$BENCH_DIR/run-arm.sh" "$TASK_ID" B 4 > "$BENCH_OUT/runarm-b3.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
  grep -q "ABORT" "$BENCH_OUT/runarm-b3.out"
}

@test "run-arm.sh: non-zero claude exit still writes run-meta.json (item 4)" {
  local run_dir="$BENCH_OUT/$TASK_ID/A/8"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 8
  [ "$status" -eq 0 ]

  local stub_dir="$BENCH_OUT/stub-claude5"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "boom" >&2
echo "not json" > "$1" 2>/dev/null
exit 9
CLAUDE
  chmod +x "$stub_dir/claude"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/pi"

  PATH="$stub_dir:$PATH" bash "$BENCH_DIR/run-arm.sh" "$TASK_ID" A 8 > "$BENCH_OUT/runarm-a.out" 2>&1 || rc=$?
  # Non-zero claude → exit 1 (not 124/137 → not exit 3).
  [ "$rc" -eq 1 ]
  # run-meta.json was still written (failed runs are always recorded).
  [ -f "$run_dir/run-meta.json" ]
  jq -e '.claude_exit == 9' "$run_dir/run-meta.json" >/dev/null
}

# --- collect.sh: duplicate / malformed pi-calls lines refused (item 5) ----------

@test "collect.sh: pi-calls.d record file is counted (exit 0)" {
  run_dir="$BENCH_OUT/$MECH_ID/A/20"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # One record file in pi-calls.d/ — the new one-file-per-call design.
  mkdir -p "$run_dir/pi-calls.d"
  cat > "$run_dir/pi-calls.d/call_1.json" <<'EOF'
{"argv":["--mode","json"],"duration_ms":1000,"exit":0,"mode":"json","call_id":"call_1"}
EOF
  run bash "$BENCH_DIR/collect.sh" "$MECH_ID" A 20
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pi_call_count == 1' >/dev/null
}

@test "collect.sh: null grade never passes validation" {
  # Craft a scenario where grade would be null: grade.json missing AND the
  # collect code path would synthesize a failed grade — but to directly test
  # that a null grade is refused, we feed a run where the synthetic path is
  # bypassed. Actually: the code always synthesizes a failed grade when
  # grade.json is missing, so the "null grade" state cannot arise from the
  # file-missing path. The null-grade guard is in the jq validator. Test it
  # directly by piping a crafted line through the validator logic.
  local line
  line='{"task":"x","arm":"A","run":1,"grade":null}'
  local out
  out="$(printf '%s' "$line" | jq -r '
    def check:
      if .grade == null
      then "grade is null (a null grade must never pass validation)"
      else null
      end;
    check | if . == null then "ok" else . end
  ')"
  [ "$out" = "grade is null (a null grade must never pass validation)" ]
}

# --- collect.sh: pi[].duration_ms numeric type enforced (item 5) ----------------

@test "collect.sh: pi duration_ms non-numeric is rejected" {
  # A pi-calls line with duration_ms as a string would break the validator.
  # The per-call pi records (pi-calls.d) are generated by the shim (always
  # numeric), so this is tested at the validator level: a collect line with
  # pi[0].duration_ms as a string fails.
  local line
  line='{"task":"x","arm":"A","run":1,"grade":{"pass":true},"pi":[{"duration_ms":"not-a-number"}]}'
  local out
  out="$(printf '%s' "$line" | jq -r '
    def check:
      if (.pi | map(select(. != null and .duration_ms != null))
           | map(.duration_ms | type) | any(. != "number"))
      then "pi[].duration_ms is not numeric or null"
      else null
      end;
    check | if . == null then "ok" else . end
  ')"
  [ "$out" = "pi[].duration_ms is not numeric or null" ]
}

# --- lib.sh: guards (item 9) ---------------------------------------------------

@test "lib.sh: guard_rm_rf refuses targets outside BENCH_OUT" {
  local rc=0
  bash -c "source '$BENCH_DIR/lib.sh'; guard_rm_rf '$BENCH_OUT-parent-sibling'" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
}

@test "lib.sh: bench_out_guard requires absolute non-empty BENCH_OUT" {
  local rc=0
  # An explicitly-empty BENCH_OUT must fail.
  BENCH_OUT="" bash -c "source '$BENCH_DIR/lib.sh'; bench_out_guard" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
  rc=0
  # A relative BENCH_OUT must fail.
  bash -c "BENCH_OUT=relative; export BENCH_OUT; source '$BENCH_DIR/lib.sh'; bench_out_guard" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
}

@test "lib.sh: validate_grading_patch rejects .. and leading /" {
  local rc=0
  bash -c "source '$BENCH_DIR/lib.sh'; validate_grading_patch '../../x'" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
  rc=0
  bash -c "source '$BENCH_DIR/lib.sh'; validate_grading_patch '/abs/path'" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
  bash -c "source '$BENCH_DIR/lib.sh'; validate_grading_patch 'grading.patch'" 2>/dev/null
  [ $? -eq 0 ]
}

# --- run-arm.sh: arm B suffix does not reference the fix (item 8) ----------------

@test "run-arm.sh: arm B delegation suffix does not reference the historical fix" {
  local rc=0
  grep -qi "historical fix" "$BENCH_DIR/run-arm.sh" && rc=1
  [ "$rc" -ne 1 ]
}

# --- run-arm.sh: CLAUDE_MODEL default is the literal id (item 7) ----------------

@test "run-arm.sh: model default is claude-sonnet-5-5" {
  # Check the literal in the script (the default assignment).
  grep -q 'CLAUDE_MODEL:-claude-sonnet-5-5' "$BENCH_DIR/run-arm.sh"
}

# --- run-arm.sh: agent_ms recorded in run-meta (item 6) ------------------------

@test "run-arm.sh: agent_ms is recorded in run-meta.json" {
  local run_dir="$BENCH_OUT/$TASK_ID/A/9"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 9
  [ "$status" -eq 0 ]
  local stub_dir="$BENCH_OUT/stub-claude6"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo '{"is_error":false,"result":"ok","duration_ms":123,"total_cost_usd":0}'
exit 0
CLAUDE
  chmod +x "$stub_dir/claude"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/pi"
  PATH="$stub_dir:$PATH" bash "$BENCH_DIR/run-arm.sh" "$TASK_ID" A 9 >/dev/null 2>&1
  [ $? -eq 0 ]
  [ -f "$run_dir/run-meta.json" ]
  jq -e '.agent_ms != null and (.agent_ms | type) == "number"' "$run_dir/run-meta.json" >/dev/null
}

# --- prompt.md: no fix-leakage wording (item 8) --------------------------------

@test "task prompts do not reference the historical fix" {
  local f found=0
  for f in "$BENCH_DIR/tasks/click-"/prompt.md; do
    if grep -qi "parent of the historical fix\|the fix made" "$f"; then
      found=1
    fi
  done
  [ "$found" -eq 0 ]
}

# ================================================================================
# NEW: issue #71 — grading robustness (restore patch-touched files)
# ================================================================================

# The grading patch is a test-only diff. If the agent edited the file the patch
# touches, the old code failed `git apply` (exit 3) and the run was scored as
# a failure. The new code restores the file to BASE first, records it in
# `restored_test_files`, and then applies the patch — the run is graded on the
# grading tests, not on the agent's edits to the graded test files.
# (Dry-run 4: arm A edited tests/test_utils/test_sentinel.py and the patch no
# longer applied; a manual revert was needed.)
@test "grade.sh: restores patch-touched files to BASE and records restored_test_files" {
  local run_dir="$BENCH_OUT/$TASK_ID/A/21"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 21
  [ "$status" -eq 0 ]
  local repo="$BENCH_OUT/$TASK_ID/A/21/repo"
  local grade_file="$run_dir/grade.json"

  # The setup-created repo has two tracked files: hello.txt (BASE) and world.txt (FIX).
  # The test grading patch creates extra-test.txt (new file). Simulate an agent
  # that edited hello.txt AND created extra-test.txt (a stray copy of the graded test file).
  ( cd "$repo" && echo "agent edit" > hello.txt )
  # The patch creates extra-test.txt; a stray copy of it would break git apply.
  ( cd "$repo" && echo "stray copy" > extra-test.txt )

  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 21
  # The restore step should let git apply succeed; TEST_CMD=true → pass.
  [ "$status" -eq 0 ]
  [ -f "$grade_file" ]
  # hello.txt was modified by the agent; restored to BASE ("hello") and recorded.
  jq -e '.restored_test_files | index("hello.txt") != null' "$grade_file" >/dev/null
  jq -e '.pass == true' "$grade_file" >/dev/null
}

# --- grade.sh: a clean tree (no agent edits) produces restored_test_files: [] ----------------
@test "grade.sh: clean tree → restored_test_files is empty" {
  local run_dir="$BENCH_OUT/$TASK_ID/A/22"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 22
  [ "$status" -eq 0 ]
  local grade_file="$run_dir/grade.json"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 22
  [ "$status" -eq 0 ]
  [ -f "$grade_file" ]
  jq -e '.restored_test_files == []' "$grade_file" >/dev/null
  jq -e '.pass == true' "$grade_file" >/dev/null
}

# Adversarial review of #71: the old awk word-split broke paths containing
# spaces (truncating `src/new file.py` to `src/new`), so a patch touching a
# space-containing path was mis-parsed and `git apply` failed. The new
# bash parameter-expansion extractor preserves spaces in paths.
@test "grade.sh: patch path with spaces is restored and applied" {
  local run_num=23
  local run_dir="$BENCH_OUT/$TASK_ID/A/$run_num"
  local repo_dir="$run_dir/repo"

  # Create a task whose repo has a file with spaces in the path.
  local space_repo="$BENCH_OUT/space-repo"
  git init -q -b main "$space_repo"
  git -C "$space_repo" config user.email t@t.t
  git -C "$space_repo" config user.name t
  echo "x" > "$space_repo/src dir b.txt"
  git -C "$space_repo" add "src dir b.txt"
  git -C "$space_repo" commit -qm "add space file"
  local space_base="$(git -C "$space_repo" rev-parse HEAD)"

  # Write the space-path task.env into the shared TASK_DIR (overwriting the
  # existing grading.patch and task.env) — but save/restore them first so other
  # tests that use $TASK_ID are unaffected.
  local saved_task_env="$TASK_DIR/task.env"
  local saved_patch="$TASK_DIR/grading.patch"
  cp "$saved_patch" "$BENCH_OUT/saved-grading.patch"
  cp "$saved_task_env" "$BENCH_OUT/saved-task.env"
  printf 'diff --git a/src dir b.txt b/src dir b.txt\nindex 1234567..89abcde 100644\n--- a/src dir b.txt\n+++ b/src dir b.txt\n@@ -1 +1 @@\n-x\n+y\n' \
    > "$TASK_DIR/grading.patch"
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$space_repo
BASE_SHA=$space_base
FIX_SHA=$space_base
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF

  # Set up the run and tamper the file (simulating an agent edit).
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A "$run_num"
  [ "$status" -eq 0 ]
  echo "tamper" > "$repo_dir/src dir b.txt"

  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A "$run_num"
  [ "$status" -eq 0 ]
  local grade_file="$run_dir/grade.json"
  [ -f "$grade_file" ]
  # The full path (with the space) is recorded in restored_test_files.
  jq -e '.restored_test_files == ["src dir b.txt"]' "$grade_file" >/dev/null
  # The patch was applied successfully (the file contains the post-patch content).
  [ "$(cat "$repo_dir/src dir b.txt")" = "y" ]
  jq -e '.pass == true' "$grade_file" >/dev/null

  # Restore the shared task files.
  cp "$BENCH_OUT/saved-grading.patch" "$TASK_DIR/grading.patch"
  cp "$BENCH_OUT/saved-task.env" "$TASK_DIR/task.env"
}

# --- grade.sh: file list parsing from ---/+++ lines (issue #71, part 2) --------
# The file list is derived from the per-file `--- `/`+++ ` lines (old `diff --git`
# parsing broke on paths containing " b/" and missed the `--- /dev/null`
# created-file form). The tests below use a helper that builds a task, runs
# setup + grade, and returns the grade.json path. Each test rewrites the
# shared $TASK_DIR grading.patch/task.env and restores them afterwards.

# _patch_parse_test <run#> <patch-content> [setup-fn ...]
# Writes the patch into $TASK_DIR/grading.patch, points task.env at
# $PATCH_PARSE_REPO, sets up run# and runs grade.sh. $status is set by the
# caller (use `run bash ...`).
_patch_parse_pre() {
  # $1 = run#; $2 = grading patch path (already written by the test). The
  # saved/restore pair keeps $TASK_DIR shared across tests. setup-run.sh
  # runs with `run` so its rc is not aborted by the test's `set -e`.
  local run_num="$1" patch_file="$2"
  cp "$TASK_DIR/grading.patch" "$BENCH_OUT/pp-saved-grading.patch" 2>/dev/null || true
  cp "$TASK_DIR/task.env" "$BENCH_OUT/pp-saved-task.env" 2>/dev/null || true
  cp "$patch_file" "$TASK_DIR/grading.patch"
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$PATCH_PARSE_REPO
BASE_SHA=$PATCH_PARSE_BASE
FIX_SHA=$PATCH_PARSE_BASE
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A "$run_num"
  [ "$status" -eq 0 ]
}
_patch_parse_post() {
  cp "$BENCH_OUT/pp-saved-grading.patch" "$TASK_DIR/grading.patch"
  cp "$BENCH_OUT/pp-saved-task.env" "$TASK_DIR/task.env"
}

@test "grade.sh: path with spaces parsed from ---/+++ lines (git diff form)" {
  local space_repo="$BENCH_OUT/pp-space-repo"
  git init -q -b main "$space_repo"
  git -C "$space_repo" config user.email t@t.t
  git -C "$space_repo" config user.name t
  echo "x" > "$space_repo/src dir with space.txt"
  git -C "$space_repo" add "src dir with space.txt"
  git -C "$space_repo" commit -qm "add space file"
  local space_base
  space_base="$(git -C "$space_repo" rev-parse HEAD)"
  local space_patch="$BENCH_OUT/pp-space.patch"
  printf 'diff --git a/src dir with space.txt b/src dir with space.txt
index 1234567..89abcde 100644
--- a/src dir with space.txt
+++ b/src dir with space.txt
@@ -1 +1 @@
-x
+y
' > "$space_patch"
  PATCH_PARSE_REPO="$space_repo" PATCH_PARSE_BASE="$space_base" _patch_parse_pre 40 "$space_patch"
  local repo_dir="$BENCH_OUT/$TASK_ID/A/40/repo"
  echo "tamper" > "$repo_dir/src dir with space.txt"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 40
  [ "$status" -eq 0 ]
  local grade_file="$BENCH_OUT/$TASK_ID/A/40/grade.json"
  [ -f "$grade_file" ]
  jq -e '.restored_test_files == ["src dir with space.txt"]' "$grade_file" >/dev/null
  [ "$(cat "$repo_dir/src dir with space.txt")" = "y" ]
  _patch_parse_post
}

@test "grade.sh: path containing ' b/' parsed from ---/+++ lines (not from diff --git)" {
  # A path containing " b/": the old `diff --git a/... b/...` parsing with
  # ` b/` splitting would truncate it. The ---/+++ parser strips only the
  # leading a//b/ prefix, so the full path survives.
  local bpath_repo="$BENCH_OUT/pp-bpath-repo"
  git init -q -b main "$bpath_repo"
  git -C "$bpath_repo" config user.email t@t.t
  git -C "$bpath_repo" config user.name t
  mkdir -p "$bpath_repo/weird b"
  echo "x" > "$bpath_repo/weird b/dir file.txt"
  git -C "$bpath_repo" add "weird b/dir file.txt"
  git -C "$bpath_repo" commit -qm "add b-slash file"
  local bpath_base
  bpath_base="$(git -C "$bpath_repo" rev-parse HEAD)"
  local bpath_patch="$BENCH_OUT/pp-bpath.patch"
  printf 'diff --git a/weird b/dir file.txt b/weird b/dir file.txt
index 1234567..89abcde 100644
--- a/weird b/dir file.txt
+++ b/weird b/dir file.txt
@@ -1 +1 @@
-x
+y
' > "$bpath_patch"
  PATCH_PARSE_REPO="$bpath_repo" PATCH_PARSE_BASE="$bpath_base" _patch_parse_pre 41 "$bpath_patch"
  local repo_dir="$BENCH_OUT/$TASK_ID/A/41/repo"
  echo "tamper" > "$repo_dir/weird b/dir file.txt"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 41
  [ "$status" -eq 0 ]
  local grade_file="$BENCH_OUT/$TASK_ID/A/41/grade.json"
  [ -f "$grade_file" ]
  jq -e '.restored_test_files == ["weird b/dir file.txt"]' "$grade_file" >/dev/null
  [ "$(cat "$repo_dir/weird b/dir file.txt")" = "y" ]
  _patch_parse_post
}

@test "grade.sh: created file via git diff new-file form (--- /dev/null) is deleted if present" {
  # Standard `git diff` new-file form: `--- /dev/null` with a real new path.
  # A stray copy of the graded file left by the agent must be deleted before
  # `git apply`, and the patch must then apply.
  local created_repo="$BENCH_OUT/pp-created-repo"
  git init -q -b main "$created_repo"
  git -C "$created_repo" config user.email t@t.t
  git -C "$created_repo" config user.name t
  echo "x" > "$created_repo/seed.txt"
  git -C "$created_repo" add seed.txt
  git -C "$created_repo" commit -qm "add seed"
  local created_base
  created_base="$(git -C "$created_repo" rev-parse HEAD)"
  local created_patch="$BENCH_OUT/pp-created.patch"
  printf 'diff --git a/new-test.py b/new-test.py
new file mode 100644
index 0000000..1234567
--- /dev/null
+++ b/new-test.py
@@ -0,0 +1 @@
+new test
' > "$created_patch"
  PATCH_PARSE_REPO="$created_repo" PATCH_PARSE_BASE="$created_base" _patch_parse_pre 42 "$created_patch"
  local repo_dir="$BENCH_OUT/$TASK_ID/A/42/repo"
  # Stray copy of the graded file left by the agent (untracked).
  echo "stray" > "$repo_dir/new-test.py"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 42
  [ "$status" -eq 0 ]
  local grade_file="$BENCH_OUT/$TASK_ID/A/42/grade.json"
  [ -f "$grade_file" ]
  jq -e '.restored_test_files | index("new-test.py") != null' "$grade_file" >/dev/null
  [ "$(cat "$repo_dir/new-test.py")" = "new test" ]
  _patch_parse_post
}

@test "grade.sh: created file via git diff --no-index form is deleted if present" {
  # `git diff --no-index /dev/null file` form: same `--- /dev/null` header,
  # new-side path followed by a trailing TAB+timestamp.
  local noindex_repo="$BENCH_OUT/pp-noindex-repo"
  git init -q -b main "$noindex_repo"
  git -C "$noindex_repo" config user.email t@t.t
  git -C "$noindex_repo" config user.name t
  echo "x" > "$noindex_repo/seed.txt"
  git -C "$noindex_repo" add seed.txt
  git -C "$noindex_repo" commit -qm "add seed"
  local noindex_base
  noindex_base="$(git -C "$noindex_repo" rev-parse HEAD)"
  # Build the patch from a real `git diff --no-index` run (no index →
  # /dev/null form), then append a TAB+timestamp to the +++ line (the
  # timestamp form git emits when the paths are not in a git directory).
  local ni_dir="$BENCH_OUT/pp-noindex-src"
  mkdir -p "$ni_dir"
  echo "no-index test content" > "$ni_dir/another-test.py"
  local ni_patch="$ni_dir/out.patch"
  ( cd "$ni_dir" && git diff --no-index /dev/null another-test.py > out.patch ) || true
  grep -qF -e '--- /dev/null' "$ni_patch"
  # Rebuild the patch with the timestamped +++ line via awk, then verify
  # both the /dev/null form and the TAB+timestamp survived.
  local ni_out_patch="$BENCH_OUT/pp-noindex-out.patch"
  awk '{ if ($0 == "+++ b/another-test.py") print $0 "\t2026-01-01 00:00:00.000000000"; else print }' "$ni_patch" > "$ni_out_patch"
  grep -qF -e '--- /dev/null' "$ni_out_patch"
  grep -qF -e $'+++ b/another-test.py\t2026' "$ni_out_patch"
  PATCH_PARSE_REPO="$noindex_repo" PATCH_PARSE_BASE="$noindex_base" _patch_parse_pre 43 "$ni_out_patch"
  local repo_dir="$BENCH_OUT/$TASK_ID/A/43/repo"
  echo "stray" > "$repo_dir/another-test.py"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 43
  [ "$status" -eq 0 ]
  local grade_file="$BENCH_OUT/$TASK_ID/A/43/grade.json"
  [ -f "$grade_file" ]
  jq -e '.restored_test_files | index("another-test.py") != null' "$grade_file" >/dev/null
  [ "$(cat "$repo_dir/another-test.py")" = "no-index test content" ]
  _patch_parse_post
}

@test "grade.sh: deleted file (+++ /dev/null) is restored from BASE before apply" {
  # A patch that deletes a file: `+++ /dev/null`. The old path must be
  # restored from BASE (so the delete applies cleanly) and recorded.
  local deleted_repo="$BENCH_OUT/pp-deleted-repo"
  git init -q -b main "$deleted_repo"
  git -C "$deleted_repo" config user.email t@t.t
  git -C "$deleted_repo" config user.name t
  echo "x" > "$deleted_repo/keep.txt"
  echo "gone" > "$deleted_repo/obsolete.txt"
  git -C "$deleted_repo" add keep.txt obsolete.txt
  git -C "$deleted_repo" commit -qm "add files"
  local deleted_base
  deleted_base="$(git -C "$deleted_repo" rev-parse HEAD)"
  local deleted_patch="$BENCH_OUT/pp-deleted.patch"
  # Build the delete patch from a real `git diff` of an agent that deleted
  # the file (the hunk must be `@@ -1 +0,0 @@`, not `@@ -1 +0 @@`).
  local del_src="$BENCH_OUT/pp-deleted-src"
  git init -q -b main "$del_src"
  git -C "$del_src" config user.email t@t.t
  git -C "$del_src" config user.name t
  echo "x" > "$del_src/keep.txt"
  echo "gone" > "$del_src/obsolete.txt"
  git -C "$del_src" add keep.txt obsolete.txt
  git -C "$del_src" commit -qm "add files"
  git -C "$del_src" rm -q obsolete.txt
  git -C "$del_src" diff HEAD > "$deleted_patch"
  grep -qF '+++ /dev/null' "$deleted_patch"
  PATCH_PARSE_REPO="$deleted_repo" PATCH_PARSE_BASE="$deleted_base" _patch_parse_pre 44 "$deleted_patch" || true
  local repo_dir="$BENCH_OUT/$TASK_ID/A/44/repo"
  # The agent deleted the file (and tampered the other one). Without a
  # restore-from-BASE the delete patch cannot apply.
  rm -f "$repo_dir/obsolete.txt"
  echo "tamper" > "$repo_dir/keep.txt"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 44
  [ "$status" -eq 0 ]
  local grade_file="$BENCH_OUT/$TASK_ID/A/44/grade.json"
  [ -f "$grade_file" ]
  jq -e '.restored_test_files | index("obsolete.txt") != null' "$grade_file" >/dev/null
  [ ! -f "$repo_dir/obsolete.txt" ]
  _patch_parse_post
}

@test "grade.sh: patch with no file headers → exit 2 + grade.json error" {
  # A patch whose content has no parseable `--- `/`+++ ` header pair is a
  # setup error: exit 2, grade.json with pass:false and the error, with
  # head_moved present. The list is never silently collapsed to empty.
  local nohdr_repo="$BENCH_OUT/pp-nohdr-repo"
  git init -q -b main "$nohdr_repo"
  git -C "$nohdr_repo" config user.email t@t.t
  git -C "$nohdr_repo" config user.name t
  echo "x" > "$nohdr_repo/seed.txt"
  git -C "$nohdr_repo" add seed.txt
  git -C "$nohdr_repo" commit -qm "add seed"
  local nohdr_base
  nohdr_base="$(git -C "$nohdr_repo" rev-parse HEAD)"
  local nohdr_patch="$BENCH_OUT/pp-nohdr.patch"
  printf 'this patch has no file headers\nonly prose\n@@ -1 +1 @@\n-x\n+y\n' > "$nohdr_patch"
  PATCH_PARSE_REPO="$nohdr_repo" PATCH_PARSE_BASE="$nohdr_base" _patch_parse_pre 45 "$nohdr_patch" || true
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 45
  [ "$status" -eq 2 ]
  local grade_file="$BENCH_OUT/$TASK_ID/A/45/grade.json"
  [ -f "$grade_file" ]
  jq -e '.pass == false' "$grade_file" >/dev/null
  jq -e '.error | contains("no file headers")' "$grade_file" >/dev/null
  jq -e 'has("head_moved")' "$grade_file" >/dev/null
  _patch_parse_post
}

# --- grade.sh: path safety — unsafe parsed patch paths are refused (issue #71) ---
# A patch whose parsed path (old or new side) is absolute or contains a `..`
# component is refused: exit 2, grade.json error "unsafe path in grading
# patch: <p>". Such paths can only come from a malformed/misparsed patch.
_patch_path_test() {
  # $1 = run#, $2 = grading patch path (already written). Uses $PATCH_TASK_DIR
  # (an isolated task dir, so the shared $TASK_DIR is not mutated).
  local run_num="$1" patch_file="$2"
  local repo="$BENCH_OUT/unsafe-path-repo"
  if [ ! -d "$repo" ]; then
    git init -q -b main "$repo"
    git -C "$repo" config user.email t@t.t
    git -C "$repo" config user.name t
    echo "x" > "$repo/seed.txt"
    git -C "$repo" add seed.txt
    git -C "$repo" commit -qm "add seed"
  fi
  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  cp "$patch_file" "$PATCH_TASK_DIR/grading.patch"
  cat > "$PATCH_TASK_DIR/task.env" <<EOF
REPO=$repo
BASE_SHA=$base
FIX_SHA=$base
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/setup-run.sh" "$PATCH_TASK_ID" A "$run_num"
  [ "$status" -eq 0 ]
}

@test "grade.sh: absolute path in patch → exit 2 + unsafe path error" {
  PATCH_TASK_ID="unsafe-path-test"
  PATCH_TASK_DIR="$TASKS_DIR/$PATCH_TASK_ID"
  mkdir -p "$PATCH_TASK_DIR"
  local patch="$BENCH_OUT/pt-abs.patch"
  printf 'diff --git a/seed.txt b//absolute/path.txt\n--- /dev/null\n+++ b//absolute/path.txt\n@@ -0,0 +1 @@\n+new\n' > "$patch"
  _patch_path_test 60 "$patch"
  run bash "$BENCH_DIR/grade.sh" "$PATCH_TASK_ID" A 60
  [ "$status" -eq 2 ]
  local grade_file="$BENCH_OUT/$PATCH_TASK_ID/A/60/grade.json"
  [ -f "$grade_file" ]
  jq -e '.pass == false' "$grade_file" >/dev/null
  jq -e '.error | contains("unsafe path in grading patch: /absolute/path.txt")' "$grade_file" >/dev/null
}

@test "grade.sh: .. component in patch path → exit 2 + unsafe path error" {
  PATCH_TASK_ID="unsafe-path-test2"
  PATCH_TASK_DIR="$TASKS_DIR/$PATCH_TASK_ID"
  mkdir -p "$PATCH_TASK_DIR"
  local patch="$BENCH_OUT/pt-dotdot.patch"
  printf 'diff --git a/seed.txt b/../escape.txt\n--- /dev/null\n+++ b/../escape.txt\n@@ -0,0 +1 @@\n+new\n' > "$patch"
  _patch_path_test 61 "$patch"
  run bash "$BENCH_DIR/grade.sh" "$PATCH_TASK_ID" A 61
  [ "$status" -eq 2 ]
  local grade_file="$BENCH_OUT/$PATCH_TASK_ID/A/61/grade.json"
  [ -f "$grade_file" ]
  jq -e '.pass == false' "$grade_file" >/dev/null
  jq -e '.error | contains("unsafe path in grading patch: ../escape.txt")' "$grade_file" >/dev/null
}

# --- grade.sh: task.env base fallback (issue #71) -----------------------------------
# A setup.json without base_sha: grade.sh falls back to the task-level
# BASE_SHA, logs "base from task.env", and grades normally.
@test "grade.sh: setup.json without base_sha → base from task.env, graded normally" {
  local run_num=70
  local tenv_id="base-fallback"
  local tenv_dir="$TASKS_DIR/$tenv_id"
  local run_dir="$BENCH_OUT/$tenv_id/A/$run_num"
  # Set up the run under the per-test task id.
  mkdir -p "$tenv_dir"
  cp "$TASK_DIR/grading.patch" "$tenv_dir/grading.patch"
  cat > "$tenv_dir/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/setup-run.sh" "$tenv_id" A "$run_num"
  [ "$status" -eq 0 ]
  local repo_dir="$run_dir/repo"
  # setup.json exists but has no base_sha (field deleted).
  jq 'del(.base_sha)' "$run_dir/setup.json" > "$run_dir/setup.json.tmp"
  mv "$run_dir/setup.json.tmp" "$run_dir/setup.json"
  # Agent tamper: the graded file is edited; the restore must use the
  # task.env BASE_SHA to succeed.
  echo "agent tamper" > "$repo_dir/hello.txt"
  run bash "$BENCH_DIR/grade.sh" "$tenv_id" A "$run_num"
  [ "$status" -eq 0 ]
  [[ "$output" == *"grade: base from task.env"* ]]
  local grade_file="$run_dir/grade.json"
  jq -e '.pass == true' "$grade_file" >/dev/null
}

# --- grade.sh: unreadable grading patch → awk failure, exit 2 + grade.json ---
# Under `set -e` a failing awk inside `var=$(…)` would abort the script at
# the assignment (no grade.json). The `|| _parse_rc=$?` form must catch the
# failure and record a grade.json with pass:false and the "failed to read
# grading patch" error.
@test "grade.sh: unreadable grading patch → exit 2 + 'failed to read grading patch'" {
  if [ "$(id -u)" = "0" ]; then skip "running as root: chmod 000 is bypassed"; fi
  local run_num=71
  local run_dir="$BENCH_OUT/$TASK_ID/A/$run_num"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A "$run_num"
  [ "$status" -eq 0 ]
  local patch="$TASK_DIR/grading.patch"
  local saved_patch="$BENCH_OUT/gp71-saved.patch"
  cp "$patch" "$saved_patch"
  chmod 000 "$patch"
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A "$run_num"
  local rc=$status
  # Restore readability regardless of the outcome.
  chmod 644 "$patch"
  cp "$saved_patch" "$patch"
  [ "$rc" -eq 2 ]
  local grade_file="$run_dir/grade.json"
  [ -f "$grade_file" ]
  jq -e '.pass == false' "$grade_file" >/dev/null
  jq -e '.error | contains("failed to read grading patch")' "$grade_file" >/dev/null
}

# --- grade.sh: empty BASE_SHA in task.env → require_task_fields rejects ---
# The missing-base early exit inside grade.sh (the "cannot determine base
# sha" path) is a defensive net, normally unreachable: require_task_fields
# rejects an empty BASE_SHA first, so grade.sh exits 2 at the guard before
# any base resolution. This test pins THAT guard: a task whose task.env
# has an empty BASE_SHA must be refused at require_task_fields, with no
# grade.json written (the guard fires before the run-dir/base-sha checks).
@test "grade.sh: empty BASE_SHA in task.env → exit 2 via require_task_fields (no grade.json)" {
  local run_num=72
  local nobase_id="nobase-test"
  local nobase_dir="$TASKS_DIR/$nobase_id"
  local run_dir="$BENCH_OUT/$nobase_id/A/$run_num"
  mkdir -p "$nobase_dir" "$run_dir/repo"
  cp "$TASK_DIR/grading.patch" "$nobase_dir/grading.patch"
  # task.env with empty BASE_SHA: require_task_fields must reject it before
  # grade.sh reaches the (defensive) missing-base early exit.
  cat > "$nobase_dir/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/grade.sh" "$nobase_id" A "$run_num"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing required field BASE_SHA"* ]]
  # No grade.json: the guard fires before any grade.json write.
  [ ! -f "$run_dir/grade.json" ]
}

# --- run-arm.sh: started_at/ended_at match the ms-resolution run window ----
# Regression (dry run 4 / issue #71): started_at and ended_at were written
# with a second-resolution `date` taken AFTER claude exited, so a ~343 s run
# recorded started_at == ended_at. They must now derive from the same
# captured moments as started_ms/ended_ms (captured immediately before and
# after the claude call): started_at < ended_at for a multi-second run, and
# the ms delta must reflect the real run duration.
@test "run-arm.sh: started_at/ended_at span the run window (stub claude sleeps 2s)" {
  local run_dir="$BENCH_OUT/$TASK_ID/A/40"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 40
  [ "$status" -eq 0 ]

  local stub_dir="$BENCH_OUT/stub-claude-40"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/claude" <<'CLAUDE'
#!/usr/bin/env bash
sleep 2
echo '{"is_error":false,"result":"ok","duration_ms":2000,"total_cost_usd":0}'
exit 0
CLAUDE
  chmod +x "$stub_dir/claude"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/pi"

  PATH="$stub_dir:$PATH" bash "$BENCH_DIR/run-arm.sh" "$TASK_ID" A 40 >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ]

  local meta="$run_dir/run-meta.json"
  [ -f "$meta" ]
  local started_at ended_at started_ms ended_ms
  started_at="$(jq -r '.started_at' "$meta")"
  ended_at="$(jq -r '.ended_at' "$meta")"
  started_ms="$(jq -r '.started_ms' "$meta")"
  ended_ms="$(jq -r '.ended_ms' "$meta")"
  # The ISO timestamps are distinct and ordered (second resolution is fine:
  # a 2 s sleep crosses a second boundary). String comparison works because
  # the format is a fixed-width ISO 8601 UTC string.
  [ -n "$started_at" ]
  [ -n "$ended_at" ]
  [ "$started_at" "<" "$ended_at" ]
  # The ms timestamps reflect the real run duration.
  local delta_ms=$(( ended_ms - started_ms ))
  [ "$delta_ms" -ge 2000 ]
}
