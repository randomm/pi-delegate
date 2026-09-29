#!/usr/bin/env bash
# grade.sh — apply the task's grading patch and run TEST_CMD in a run's
# working tree. Records pass/fail to <run-dir>/grade.json.
#
# Usage:
#   bench/grade.sh <task-id> <arm> <run#>
#
# What it does:
#   1. Loads task.env (REPO, BASE_SHA, FIX_COMMIT, TEST_CMD, GRADING_PATCH).
#   2. cd's into <run-dir>/repo (the fresh clone from setup-run.sh).
#   3. Applies <task-dir>/<GRADING_PATCH> with `git apply`.
#   4. Runs TEST_CMD (from task.env) in the repo directory.
#   5. Writes <run-dir>/grade.json with pass/fail, test_cmd, and the
#      grading-patch path.
#
# Exit codes:
#   0  tests passed
#   1  tests failed (grading patch applied, but TEST_CMD returned non-zero)
#   2  setup error (missing run dir, missing grading patch, git apply failed)
#   3  grading patch could not be applied (conflict / already applied)
#
# NOTE: This script does NOT check out a clean tree before applying the
# patch. The working tree is whatever the agent (Claude/pi) left behind.
# This is intentional: the grading patch is a diff of test files only,
# and `git apply` will fail if the agent modified the same test files
# (which would be a signal that the agent "cheated" by editing tests —
# a documented edge case in docs/benchmark.md §grading).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo "Usage: $0 <task-id> <arm> <run#>" >&2
  exit 1
}
[ "${#}" -eq 3 ] || usage
task_id="$1"; arm="$2"; run_num="$3"

case "$arm" in A|B) ;; *) echo "arm must be A or B" >&2; exit 1 ;; esac
if ! [[ "$run_num" =~ ^[0-9]+$ ]] || [ "$run_num" -lt 1 ]; then
  echo "run# must be a positive integer" >&2; exit 1
fi

require_task_fields "$task_id" || exit 2

run_dir="$BENCH_OUT/$task_id/$arm/$run_num"
repo_dir="$run_dir/repo"
task_dir="$(task_dir "$task_id")"

[ -d "$repo_dir" ] || {
  echo "grade: repo not found at $repo_dir — run setup-run.sh first" >&2
  exit 2
}
[ -n "${GRADING_PATCH:-}" ] || {
  echo "grade: task '$task_id' has no GRADING_PATCH in task.env" >&2
  exit 2
}
patch_path="$task_dir/$GRADING_PATCH"
[ -f "$patch_path" ] || {
  echo "grade: grading patch not found at $patch_path" >&2
  exit 2
}

cd "$repo_dir"

# --- Apply the grading patch ---------------------------------------------------
# git apply fails if the patch conflicts with the working tree (e.g. the
# agent edited the same test files). We record that as a failure (exit 3)
# because the grading contract cannot be verified in that case.
apply_err="$run_dir/apply-err.log"
if ! git apply --whitespace=nowarn "$patch_path" 2> "$apply_err"; then
  echo "grade: git apply failed (see $apply_err):" >&2
  cat "$apply_err" >&2
  jq -cn \
    --arg task "$task_id" \
    --arg arm "$arm" \
    --argjson run "$run_num" \
    --arg test_cmd "$TEST_CMD" \
    --arg patch "$patch_path" \
    --arg error "git apply failed" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      pass:false, error:$error, graded_at:$graded_at}' \
    > "$run_dir/grade.json"
  exit 3
fi

# --- Run the test command --------------------------------------------------------
# TEST_CMD is a shell command (e.g. "bats skills/pi-review-loop/test/").
# It is run in the repo directory. We capture stdout/stderr to files and
# record the exit code.
test_log="$run_dir/test-output.log"
test_rc=0
if ! bash -c "$TEST_CMD" > "$test_log" 2>&1; then
  test_rc=$?
fi

# --- Record result -------------------------------------------------------------
if [ "$test_rc" -eq 0 ]; then
  echo "grade: PASS  task=$task_id arm=$arm run=$run_num" >&2
  jq -cn \
    --arg task "$task_id" \
    --arg arm "$arm" \
    --argjson run "$run_num" \
    --arg test_cmd "$TEST_CMD" \
    --arg patch "$patch_path" \
    --arg test_log "$test_log" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      test_log:$test_log, pass:true, error:null, graded_at:$graded_at}' \
    > "$run_dir/grade.json"
  exit 0
else
  echo "grade: FAIL  task=$task_id arm=$arm run=$run_num (exit $test_rc)" >&2
  jq -cn \
    --arg task "$task_id" \
    --arg arm "$arm" \
    --argjson run "$run_num" \
    --arg test_cmd "$TEST_CMD" \
    --arg patch "$patch_path" \
    --arg test_log "$test_log" \
    --argjson test_rc "$test_rc" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      test_log:$test_log, pass:false, error:"test command exited $test_rc",
      graded_at:$graded_at}' \
    > "$run_dir/grade.json"
  exit 1
fi
