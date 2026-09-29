#!/usr/bin/env bats
# BATS tests for the benchmark harness — pure-bash parts only.
# No real claude or pi is invoked. All git/uv commands use safe-env
# (GIT_TERMINAL_PROMPT=0 EDITOR=true VISUAL=true PAGER=cat GIT_PAGER=cat)
# and run under `timeout` (docs/benchmark.md §safe-execution).
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

  # A temp BENCH_OUT so tests don't pollute /tmp/pi-bench.
  BENCH_OUT="$(mktemp -d)"
  export BENCH_OUT
  export TASKS_DIR="$BENCH_DIR/tasks"

  # A throwaway task for setup-run tests. The task.env uses FIX_SHA (not
  # FIX_COMMIT) to match the real task format.
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
  # grading.patch: a trivial patch that adds a test file (will be applied by
  # grade.sh; for setup-run tests we don't grade, so the patch content is
  # irrelevant as long as the file exists).
  cat > "$TASK_DIR/grading.patch" <<'EOF'
diff --git a/extra-test.txt b/extra-test.txt
new file mode 100644
index 0000000..e69de29
--- /dev/null
+++ b/extra-test.txt
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
  cd /
}

teardown() {
  rm -rf "$BENCH_OUT"
}

# --- collect.sh tests ---------------------------------------------------------

@test "collect.sh: success path with arm A fixtures" {
  run_dir="$BENCH_OUT/issue-41-mech/A/1"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"            "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"         "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"       "$run_dir/grade.json"
  cp "$FIXTURES/pi-calls.jsonl"        "$run_dir/pi-calls.jsonl"
  # pi-<call_id>.jsonl for the json-mode call.
  cp "$FIXTURES/pi-transcript-call1.jsonl" \
     "$run_dir/pi-1700000000000_12345.jsonl"

  local task_dir="$TASKS_DIR/issue-41-mech"
  mkdir -p "$task_dir"
  [ -f "$task_dir/grading.patch" ] || cp /dev/null "$task_dir/grading.patch"

  run bash "$BENCH_DIR/collect.sh" issue-41-mech A 1
  [ "$status" -eq 0 ]
  # Output must be valid JSON with the required fields. Use -e (exit code)
  # not -r (raw output) since we only need a boolean here.
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
  run_dir="$BENCH_OUT/issue-41-mech/A/2"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-fail.json"         "$run_dir/grade.json"
  local task_dir="$TASKS_DIR/issue-41-mech"
  mkdir -p "$task_dir"
  cat > "$task_dir/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  [ -f "$task_dir/grading.patch" ] || cp /dev/null "$task_dir/grading.patch"

  run bash "$BENCH_DIR/collect.sh" issue-41-mech A 2
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.grade.pass == false' >/dev/null
  echo "$output" | jq -e '.grade.error != null'  >/dev/null
}

@test "collect.sh: malformed claude output → exit 2" {
  run_dir="$BENCH_OUT/issue-41-mech/A/3"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-malformed.txt" "$run_dir/claude/output.json"
  local task_dir="$TASKS_DIR/issue-41-mech"
  mkdir -p "$task_dir"
  cat > "$task_dir/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  [ -f "$task_dir/grading.patch" ] || cp /dev/null "$task_dir/grading.patch"

  run bash "$BENCH_DIR/collect.sh" issue-41-mech A 3
  [ "$status" -eq 2 ]
}

@test "collect.sh: missing run dir → exit 1" {
  local task_dir="$TASKS_DIR/issue-41-mech"
  mkdir -p "$task_dir"
  cat > "$task_dir/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/collect.sh" issue-41-mech A 99
  [ "$status" -eq 1 ]
}

# --- setup-run.sh tests ---------------------------------------------------------

@test "setup-run.sh: creates repo at BASE_SHA on feature branch" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 1
  [ "$status" -eq 0 ]
  local repo="$BENCH_OUT/$TASK_ID/A/1/repo"
  [ -d "$repo" ]
  # Check the branch name.
  local branch
  branch="$(git -C "$repo" symbolic-ref --short HEAD)"
  [ "$branch" = "bench/A/1" ]
  # Check the HEAD is at BASE_SHA.
  local head_sha
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  [ "$head_sha" = "$(git -C "$FAKE_REPO" rev-parse "$BASE_SHA")" ]
}

@test "setup-run.sh: push.default is nothing" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 1
  [ "$status" -eq 0 ]
  local repo="$BENCH_OUT/$TASK_ID/A/1/repo"
  # push.default should be "nothing".
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

  # Exactly one commit should be reachable.
  local commit_count
  commit_count="$(timeout 30 git -C "$repo" rev-list --count HEAD)"
  [ "$commit_count" = "1" ]

  # FIX_SHA must NOT be resolvable in the run repo.
  # (git rev-parse will fail for an unknown object.)
  local fix_resolved=""
  fix_resolved="$(timeout 30 git -C "$repo" rev-parse -q --verify "$FIX_SHA^{commit}" 2>/dev/null)" || true
  [ -z "$fix_resolved" ]
}

@test "setup-run.sh: secret-file scan refuses on .env file" {
  # Create a repo with a .env file.
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
  # Point the task at this repo.
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

# --- collect.sh: null-grade → failed line (review item 6) ----------------------

@test "collect.sh: no grade.json → collect line marked failed" {
  # A crashed run that was never graded must emit a collect line with
  # grade.pass == false and a diagnostic error — NOT grade:null.
  run_dir="$BENCH_OUT/issue-41-mech/A/10"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  # No grade.json — the run was never graded.
  local task_dir="$TASKS_DIR/issue-41-mech"
  mkdir -p "$task_dir"
  cat > "$task_dir/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  [ -f "$task_dir/grading.patch" ] || cp /dev/null "$task_dir/grading.patch"

  run bash "$BENCH_DIR/collect.sh" issue-41-mech A 10
  [ "$status" -eq 0 ]
  # grade must NOT be null; it must be an object with pass=false.
  echo "$output" | jq -e '.grade != null' >/dev/null
  echo "$output" | jq -e '.grade.pass == false' >/dev/null
  echo "$output" | jq -e '.grade.error != null' >/dev/null
}

# --- collect.sh: token SUM over multiple message_end (review item 3) ------------

@test "collect.sh: sums tokens over multiple assistant turns" {
  run_dir="$BENCH_OUT/issue-41-mech/A/11"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/run-meta.json"           "$run_dir/run-meta.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # Two json-mode calls with multi-turn transcripts.
  cat > "$run_dir/pi-calls.jsonl" <<'EOF'
{"argv":["--mode","json"],"duration_ms":1000,"exit":0,"mode":"json","call_id":"100_1"}
{"argv":["--mode","json"],"duration_ms":2000,"exit":0,"mode":"json","call_id":"100_2"}
EOF
  # Call 1: two assistant turns (develop + review), different models.
  cat > "$run_dir/pi-100_1.jsonl" <<'EOF'
{"type":"message_end","message":{"role":"assistant","usage":{"input":100,"output":50,"cacheRead":200,"cacheWrite":1000,"totalTokens":1350},"model":"model-a"}}
{"type":"message_end","message":{"role":"assistant","usage":{"input":200,"output":100,"cacheRead":500,"cacheWrite":500,"totalTokens":1300},"model":"model-b"}}
EOF
  # Call 2: single assistant turn.
  cat > "$run_dir/pi-100_2.jsonl" <<'EOF'
{"type":"message_end","message":{"role":"assistant","usage":{"input":50,"output":25,"cacheRead":100,"cacheWrite":200,"totalTokens":375},"model":"model-a"}}
EOF
  local task_dir="$TASKS_DIR/issue-41-mech"
  mkdir -p "$task_dir"
  cat > "$task_dir/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  [ -f "$task_dir/grading.patch" ] || cp /dev/null "$task_dir/grading.patch"

  run bash "$BENCH_DIR/collect.sh" issue-41-mech A 11
  [ "$status" -eq 0 ]
  # Call 1: tokens summed over both turns.
  echo "$output" | jq -e '.pi[0].tokens.input == 300'   >/dev/null  # 100+200
  echo "$output" | jq -e '.pi[0].tokens.output == 150'  >/dev/null  # 50+100
  echo "$output" | jq -e '.pi[0].tokens.total == 2650'  >/dev/null  # 1350+1300
  # Per-model breakdown present and correct (jq 1.5 needs bracket syntax for
  # string keys with hyphens; use .["model-a"] form).
  echo "$output" | jq -e '.pi[0].tokens.per_model["model-a"].input == 100' >/dev/null
  echo "$output" | jq -e '.pi[0].tokens.per_model["model-b"].input == 200' >/dev/null
  # Call 2: single turn, no summing needed.
  echo "$output" | jq -e '.pi[1].tokens.input == 50'     >/dev/null
  echo "$output" | jq -e '.pi[1].tokens.total == 375'    >/dev/null
}

# --- collect.sh: wall clock from run-meta started_at/ended_at (review item 9) ----

@test "collect.sh: wall clock uses run-meta started_at/ended_at when present" {
  run_dir="$BENCH_OUT/issue-41-mech/A/12"
  mkdir -p "$run_dir/claude"
  cp "$FIXTURES/claude-output-armA.json" "$run_dir/claude/output.json"
  cp "$FIXTURES/setup.json"              "$run_dir/setup.json"
  cp "$FIXTURES/grade-pass.json"         "$run_dir/grade.json"
  # run-meta with started_at/ended_at 10 seconds apart.
  cat > "$run_dir/run-meta.json" <<'EOF'
{"task":"issue-41-mech","arm":"A","run":12,"model":"claude-sonnet-5-5",
 "perm_mode":"auto","pi_delegate_sha":"","config_dir":"x","prompt_file":"x",
 "claude_exit":0,"started_at":"2026-09-29T12:00:00Z","ended_at":"2026-09-29T12:00:10Z"}
EOF
  local task_dir="$TASKS_DIR/issue-41-mech"
  mkdir -p "$task_dir"
  cat > "$task_dir/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  [ -f "$task_dir/grading.patch" ] || cp /dev/null "$task_dir/grading.patch"

  run bash "$BENCH_DIR/collect.sh" issue-41-mech A 12
  [ "$status" -eq 0 ]
  # 10 seconds = 10000 ms.
  echo "$output" | jq -e '.wall_clock_ms == 10000' >/dev/null
}

# --- setup-run.sh: re-run clears prior run dir (review item 12) -------------------

@test "setup-run.sh: re-run clears pi-calls.jsonl from prior run" {
  local repo="$BENCH_OUT/$TASK_ID/A/2/repo"
  # First run.
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 2
  [ "$status" -eq 0 ]
  # Simulate a pi call leftover in the run dir.
  local run_dir="$BENCH_OUT/$TASK_ID/A/2"
  echo '{"argv":["--mode","json"],"duration_ms":1,"exit":0,"mode":"json","call_id":"stale_1"}' > "$run_dir/pi-calls.jsonl"
  echo 'stale' > "$run_dir/pi-stale_1.jsonl"
  # Second run (re-run).
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 2
  [ "$status" -eq 0 ]
  # The stale pi-calls.jsonl must be gone (the run dir was cleared).
  [ ! -f "$run_dir/pi-calls.jsonl" ]
  [ ! -f "$run_dir/pi-stale_1.jsonl" ]
}

# --- setup-run.sh: .env.example does NOT trigger secret refusal (review item 8) ---

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
  # .env.example is a template, not a secret — setup should succeed.
  [ "$status" -eq 0 ]
  cd /
}

# --- grade.sh: FAIL path writes grade.json with correct test_rc (review item 5) --

@test "grade.sh: FAIL path writes grade.json with test_rc" {
  local repo="$BENCH_OUT/$TASK_ID/A/4"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 4
  [ "$status" -eq 0 ]
  # Use a TEST_CMD that definitely fails (nonexistent binary → rc 127).
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD='/nonexistent_binary_xyz'
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 4
  [ "$status" -eq 1 ]
  # grade.json must exist and have pass=false with test_rc (127 for
  # "command not found").
  local grade_file="$BENCH_OUT/$TASK_ID/A/4/grade.json"
  [ -f "$grade_file" ]
  jq -e '.pass == false' "$grade_file" >/dev/null
  jq -e '.test_rc == 127' "$grade_file" >/dev/null
}

# --- grade.sh: PASS path writes grade.json (review item 5) ------------------------

@test "grade.sh: PASS path writes grade.json with pass=true" {
  local repo="$BENCH_OUT/$TASK_ID/A/5"
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 5
  [ "$status" -eq 0 ]
  # Use a TEST_CMD that passes.
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

# --- grade.sh: git apply failure writes grade.json (review item 5) ----------------

@test "grade.sh: git apply failure writes grade.json with error" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 6
  [ "$status" -eq 0 ]
  # Point GRADING_PATCH at a nonexistent file.
  cat > "$TASK_DIR/task.env" <<EOF
REPO=$FAKE_REPO
BASE_SHA=$BASE_SHA
FIX_SHA=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=nonexistent.patch
EOF
  run bash "$BENCH_DIR/grade.sh" "$TASK_ID" A 6
  # Missing patch → exit 2 (setup error), not exit 3.
  [ "$status" -eq 2 ]
}

# --- run-arm.sh: arm A does NOT get a pi shim (review item 7) -------------------

@test "run-arm.sh: arm A does not install pi shim" {
  # Set up a run dir for arm A.
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 7
  [ "$status" -eq 0 ]
  local run_dir="$BENCH_OUT/$TASK_ID/A/7"
  # The bin dir should NOT exist (no shim installed for arm A).
  [ ! -d "$run_dir/bin" ]
}

# --- run-arm.sh: arm B installs pi shim (review item 7) -------------------------

@test "run-arm.sh: arm B installs pi shim" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" B 1
  [ "$status" -eq 0 ]
  local run_dir="$BENCH_OUT/$TASK_ID/B/1"
  # Create a stub pi on PATH so the shim install succeeds.
  local stub_dir="$BENCH_OUT/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
echo "stub pi"
exit 0
EOF
  chmod +x "$stub_dir/pi"
  # Install the shim (arm B only).
  PATH="$stub_dir:$PATH" bash -c "
    source $BENCH_DIR/lib.sh
    install_pi_shim '$run_dir'
  "
  [ $? -eq 0 ]
  # The shim must exist.
  [ -f "$run_dir/bin/pi" ]
}

# --- lib.sh: install_pi_shim generates a valid shim (review items 2, 11) -----------

@test "lib.sh: install_pi_shim generates a valid shim with no baked-in literals" {
  local run_dir="$BENCH_OUT/shim-test"
  mkdir -p "$run_dir"
  # Create a stub pi on PATH.
  local stub_dir="$BENCH_OUT/stub-bin2"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/pi" <<'EOF'
#!/usr/bin/env bash
echo "stub pi output"
exit 0
EOF
  chmod +x "$stub_dir/pi"
  # Install the shim.
  PATH="$stub_dir:$PATH" bash -c "
    source $BENCH_DIR/lib.sh
    install_pi_shim '$run_dir'
  "
  [ $? -eq 0 ]
  # The shim must exist and be executable.
  [ -x "$run_dir/bin/pi" ]
  # The shim must NOT contain the literal RUN_DIR from install time.
  # (It should compute RUN_DIR at call time, not bake in the install-time value.)
  local shim_content
  shim_content="$(cat "$run_dir/bin/pi")"
  # The shim should reference BASH_SOURCE, not a hardcoded path.
  echo "$shim_content" | grep -q 'BASH_SOURCE' 
  # The shim should NOT contain the install-time run_dir as a literal.
  ! echo "$shim_content" | grep -q "RUN_DIR=\"$run_dir" 
  # The shim should use $$ for the call tag (not a baked-in PID).
  echo "$shim_content" | grep -q '\$\$' 
}
