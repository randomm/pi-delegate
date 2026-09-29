#!/usr/bin/env bats
# BATS tests for the benchmark harness — pure-bash parts only.
# No real claude or pi is invoked.
#
# Run:
#   bats bench/tests/collect.bats
#   bats bench/tests/setup-run.bats
#   (or: bats bench/tests/)

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

  # A temp BENCH_OUT so tests don't pollute /tmp/pi-bench.
  BENCH_OUT="$(mktemp -d)"
  export BENCH_OUT
  export TASKS_DIR="$BENCH_DIR/tasks"

  # A throwaway task for setup-run tests.
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
  # A second commit to use as FIX_COMMIT.
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
FIX_COMMIT=$FIX_SHA
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
  echo "$output" | jq -e '.pi[0].tokens.total == 8350'    >/dev/null
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
FIX_COMMIT=$FIX_SHA
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
FIX_COMMIT=$FIX_SHA
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
FIX_COMMIT=$FIX_SHA
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/collect.sh" issue-41-mech A 99
  [ "$status" -eq 1 ]
}

# --- setup-run.sh tests ---------------------------------------------------------

@test "setup-run.sh: creates clone at BASE_SHA on feature branch" {
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

@test "setup-run.sh: push URL is disabled" {
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 1
  [ "$status" -eq 0 ]
  local repo="$BENCH_OUT/$TASK_ID/A/1/repo"
  # push.default should be "nothing".
  local push_default
  push_default="$(git -C "$repo" config push.default)"
  [ "$push_default" = "nothing" ]
  # The origin pushurl should be the dead helper.
  local pushurl
  pushurl="$(git -C "$repo" remote get-url --push origin)"
  [ "$pushurl" = "pi-delegate-push-disabled://dead" ]
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
FIX_COMMIT=$sha
TEST_CMD=true
GRADING_PATCH=grading.patch
EOF
  run bash "$BENCH_DIR/setup-run.sh" "$TASK_ID" A 1
  [ "$status" -eq 3 ]
  # Clean up the secret repo (rm -rf of the run dir in teardown handles the rest).
  cd /
}

@test "setup-run.sh: missing task → exit 1" {
  run bash "$BENCH_DIR/setup-run.sh" nonexistent-task A 1
  [ "$status" -ne 0 ]
}
