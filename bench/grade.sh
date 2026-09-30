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
#   3. Restores every file the grading patch touches to its BASE version
#      (tracked files the patch modifies → `git checkout HEAD -- <path>`;
#      files the patch creates → deleted if present). The agent's edits to
#      those files are the only thing that can block `git apply`, and they
#      are irrelevant to grading (the grading tests are the ground truth),
#      so the harness normalises them away instead of failing the run.
#      Files the agent had modified are recorded as
#      `restored_test_files: [...]` in grade.json. (Dry-run 4: arm A edited
#      tests/test_utils/test_sentinel.py and the patch no longer applied;
#      a manual revert was needed.)
#   4. Applies <task-dir>/<GRADING_PATCH> with `git apply`.
#   5. Runs TEST_CMD (from task.env) in the repo directory.
#   6. Writes <run-dir>/grade.json with pass/fail, test_cmd, the
#      grading-patch path, and restored_test_files.
#
# Exit codes:
#   0  tests passed
#   1  tests failed (grading patch applied, but TEST_CMD returned non-zero)
#   2  setup error (missing run dir, missing grading patch, git apply failed)
#   3  grading patch could not be applied (conflict / already applied)
#
# NOTE: Before applying the patch, every file the patch touches is restored
# to its BASE version (see step 3 above). The working tree is otherwise
# whatever the agent (Claude/pi) left behind: the grading patch is a diff of
# test files only, and agent edits to non-test files must survive into the
# test run (that is the actual change under test). Restoring the patch's own
# files is NOT a cheat signal — it is the grading contract: the graded test
# files are the ground truth, so the agent's version of them is discarded.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

bench_out_guard || exit 2

# Safe-execution env (docs/benchmark.md §safe-execution).
export GIT_TERMINAL_PROMPT=0 EDITOR=true VISUAL=true PAGER=cat GIT_PAGER=cat

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
# The grading patch path must stay inside the task dir: no leading '/'
# (absolute) and no '..' components (path traversal out of the task dir).
validate_grading_patch "$GRADING_PATCH" || {
  echo "grade: task '$task_id' has an unsafe GRADING_PATCH: $GRADING_PATCH" >&2
  exit 2
}
patch_path="$task_dir/$GRADING_PATCH"
[ -f "$patch_path" ] || {
  echo "grade: grading patch not found at $patch_path" >&2
  exit 2
}
# Convert to an absolute path before cd-ing into the repo dir (the relative
# path would no longer resolve after the cd). 
patch_path="$(cd "$(dirname "$patch_path")" && pwd)/$(basename "$patch_path")"

cd "$repo_dir"

# --- Restore the patch's files to BASE ----------------------------------------
# The grading patch is a test-only diff. If the agent edited any of the files
# it touches, `git apply` fails and the run is ungradeable. Those edits carry
# no grading signal (the graded test files are the ground truth), so we
# normalise the tree first: restore every file the patch MODIFIES to its BASE
# version and delete every file the patch CREATES (if present). This makes
# grading robust to agent test-file edits (issue #71) while leaving the
# agent's non-test changes — the change under test — untouched.
#
# The file list is derived from the patch itself: a `diff --git a/<old> b/<new>`
# line (old/new relative to the repo root) with the old path empty (/dev/null)
# meaning the patch creates the file.
# Parse the patch header to extract two lists:
#   patch_files_json  – files the patch MODIFIES (old path is not /dev/null)
#   patch_created_json – files the patch CREATES (old path is /dev/null)
patch_files_json="[]"
patch_created_json="[]"
restored_json="[]"
_h="$(timeout 60 grep -F -- 'diff --git ' "$patch_path" 2>/dev/null)" || _h=""
if [ -n "$_h" ]; then
  # Extract a/<old> b/<new> pairs, strip the a/ and b/ prefixes, then split
  # into modified (old != /dev/null) and created (old == /dev/null).
  patch_files_json="$(printf '%s\n' "$_h" | awk '{sub(/^a\//, "", $3); sub(/^b\//, "", $4); if ($3 != "/dev/null") print $3}' | jq -Rn '[inputs]')" || patch_files_json="[]"
  patch_created_json="$(printf '%s\n' "$_h" | awk '{sub(/^a\//, "", $3); sub(/^b\//, "", $4); if ($3 == "/dev/null") print $4}' | jq -Rn '[inputs]')" || patch_created_json="[]"
fi
# For each file the patch modifies: if the working tree differs from BASE
# (agent modified it) or it is absent, restore it from BASE and record it.
# `git diff --quiet HEAD -- <file>` is empty when the tree matches BASE.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! timeout 60 git diff --quiet HEAD -- "$p" 2>/dev/null; then
    timeout 60 git checkout HEAD -- "$p" >/dev/null 2>&1 || true
    restored_json="$(jq -cn --argjson rest "$restored_json" --arg f "$p" '$rest + [$f]')" || true
  elif [ ! -f "$p" ]; then
    # File was deleted by the agent (tracked at BASE, missing in the tree).
    timeout 60 git checkout HEAD -- "$p" >/dev/null 2>&1 || true
    restored_json="$(jq -cn --argjson rest "$restored_json" --arg f "$p" '$rest + [$f]')" || true
  fi
done < <(jq -r '.[]' <<< "$patch_files_json" 2>/dev/null)
# For each file the patch creates: delete it if present (a stray copy of the
# graded test file left by the agent would break `git apply`).
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ -f "$p" ]; then
    rm -f -- "$p" || true
    restored_json="$(jq -cn --argjson rest "$restored_json" --arg f "$p" '$rest + [$f]')" || true
  fi
done < <(jq -r '.[]' <<< "$patch_created_json" 2>/dev/null)

# --- Apply the grading patch ---------------------------------------------------
# git apply fails if the patch conflicts with the working tree. After the
# restore step above the conflict is expected to be gone; if it still fails
# we record it as a failure (exit 3) because the grading contract cannot be
# verified in that case.
apply_err="$run_dir/apply-err.log"
if ! timeout 120 git apply --whitespace=nowarn "$patch_path" 2> "$apply_err"; then
  echo "grade: git apply failed (see $apply_err):" >&2
  cat "$apply_err" >&2
  # The failure path must still record a grade.json (docs/benchmark.md
  # §grading): a crashed grade that drops the record would let collect.sh
  # emit a collect line with grade:null that passes validation.
  jq -cn \
    --arg task "$task_id" \
    --arg arm "$arm" \
    --argjson run "$run_num" \
    --arg test_cmd "$TEST_CMD" \
    --arg patch "$patch_path" \
    --arg error "git apply failed" \
    --argjson restored "$restored_json" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      restored_test_files:$restored,
      pass:false, error:$error, graded_at:$graded_at}' \
    > "$run_dir/grade.json" || {
      echo "grade: FATAL — could not write $run_dir/grade.json" >&2
      exit 2
    }
  exit 3
fi

# --- Run the test command --------------------------------------------------------
# TEST_CMD is a shell command (e.g. `timeout 120 $PWD/venv/bin/python -m
# pytest ...`). It is run in the repo directory. We capture stdout/stderr
# to files and record the exit code. The command is already bounded by
# `timeout` inside the TEST_CMD string (see task.env); we wrap the outer
# bash invocation in timeout 600 as belt-and-braces.
test_log="$run_dir/test-output.log"
test_rc=0
timeout 600 bash -c "$TEST_CMD" > "$test_log" 2>&1 || test_rc=$?

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
    --argjson restored "$restored_json" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      test_log:$test_log, restored_test_files:$restored,
      pass:true, error:null, graded_at:$graded_at}' \
    > "$run_dir/grade.json" || {
      echo "grade: FATAL — could not write $run_dir/grade.json" >&2
      exit 2
    }
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
    --argjson restored "$restored_json" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      test_log:$test_log, restored_test_files:$restored,
      test_rc:$test_rc, pass:false, error:"test command exited '"$test_rc"'",
      graded_at:$graded_at}' \
    > "$run_dir/grade.json" || {
      echo "grade: FATAL — could not write $run_dir/grade.json" >&2
      exit 2
    }
  exit 1
fi
