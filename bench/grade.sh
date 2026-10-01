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
#      (tracked files the patch modifies → `git checkout <base> -- <path>`
#      where <base> is the recorded BASE_SHA; files the patch creates →
#      deleted if present). The agent's edits to
#      those files are the only thing that can block `git apply`, and they
#      are irrelevant to grading (the grading tests are the ground truth),
#      so the harness normalises them away instead of failing the run.
#      Files the agent had modified are recorded as
#      `restored_test_files: [...]` in grade.json. A restore failure
#      (checkout error) is a setup error: exit 2 with a grade.json
#      recording `error: "restore failed for <path>: <stderr>"`.
#      (Dry-run 4: arm A edited tests/test_utils/test_sentinel.py and
#      the patch no longer applied; a manual revert was needed.)
#   4. Applies <task-dir>/<GRADING_PATCH> with `git apply`.
#   5. Runs TEST_CMD (from task.env) in the repo directory.
#   6. Writes <run-dir>/grade.json with pass/fail, test_cmd, the
#      grading-patch path, and restored_test_files.
#
# Exit codes:
#   0  tests passed
#   1  tests failed (grading patch applied, but TEST_CMD returned non-zero)
#   2  setup error (missing run dir, missing grading patch, or a restore
#      checkout failed)
#   3  grading patch could not be applied (conflict / already applied)
#
# NOTE: Before applying the patch, every file the patch touches is restored
# to its BASE version (see step 3 above). The working tree is otherwise
# whatever the agent (Claude/pi) left behind: the grading patch is a diff of
# test files only, and agent edits to non-test files must survive into the
# test run (that is the actual change under test). Restoring the patch's own
# files is NOT a cheat signal — it is the grading contract: the graded test
# files are the ground truth, so the agent's version of them is discarded.
#
# Committed runs: the agent is instructed not to commit, but if it does
# (HEAD != recorded BASE_SHA) the run is still graded normally — the
# restore and `git apply` target the recorded BASE_SHA, and TEST_CMD runs
# on the working tree (the agent's final state, committed or not). The
# divergence is recorded as `head_moved: true` in grade.json (false
# otherwise), on every exit path.

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

# --- Pin the restore base ------------------------------------------------------
# Every restore below must target the recorded BASE_SHA, NOT `HEAD`.
# Normally HEAD == BASE_SHA (setup-run.sh fetches only BASE_SHA and the
# agent is instructed not to commit), but an agent that commits its work
# moves HEAD, and `git checkout HEAD -- <file>` would restore the agent's
# own version instead of the base — the wrong source for grading. The base
# is read from setup.json (written by setup-run.sh); a run whose HEAD is
# not the base is still graded (restore/apply target BASE_SHA, tests run
# on the working tree) and is flagged `head_moved: true` in grade.json.
base_sha="$(jq -r '.base_sha // empty' "$run_dir/setup.json" 2>/dev/null)" || base_sha=""
echo "grade: base_sha='$base_sha'" >&2
if [ -z "$base_sha" ]; then
  # setup.json holds the BASE_SHA that setup-run.sh fetched into the run
  # repo — prefer that over the task-level BASE_SHA, which need not be
  # fetchable in the run repo (e.g. a task env pointing elsewhere).
  base_sha="${BASE_SHA:-}"
fi
[ -n "$base_sha" ] || {
  echo "grade: cannot determine base sha (no setup.json base_sha, no BASE_SHA in task.env)" >&2
  exit 2
}
head_sha="$(git rev-parse HEAD 2>/dev/null)" || head_sha=""
if [ -z "$head_sha" ] || [ "$head_sha" != "$base_sha" ]; then
  head_moved="true"
else
  head_moved="false"
fi

# --- Restore the patch's files to BASE ----------------------------------------
# The grading patch is a test-only diff. If the agent edited any of the files
# it touches, `git apply` fails and the run is ungradeable. Those edits carry
# no grading signal (the graded test files are the ground truth), so we
# normalise the tree first: restore every file the patch MODIFIES to its BASE
# version (`git checkout <base> -- <path>`) and delete every file the patch
# CREATES (if present). This makes grading robust to agent test-file edits
# (issue #71) while leaving the agent's non-test changes — the change under
# test — untouched.
#
# The file list is derived from the patch itself: a `diff --git a/<old> b/<new>`
# line (old/new relative to the repo root) with the old path empty (/dev/null)
# meaning the patch creates the file. The extractor is anchored and space-safe
# (adversarial review of #71: an awk word-split broke paths containing spaces,
# truncating `src/new file.py` to `src/new`): the header is stripped of the
# `a/` prefix and everything from ` b/` on, leaving the whole old path intact
# (spaces preserved); the new path is everything after the first ` b/`.
patch_files_json="[]"
patch_created_json="[]"
restored_json="[]"
_h="$(timeout 60 grep -F -- 'diff --git ' "$patch_path" 2>/dev/null)" || _h=""
if [ -n "$_h" ]; then
  while IFS= read -r _hdr; do
    _rest="${_hdr#"diff --git "}"
    _old_path="${_rest#a/}"
    _old_path="${_old_path%% b/*}"
    _new_path="${_rest#* b/}"
    # The file is CREATED when the old side is /dev/null. (A standard `git diff`
    # patch writes real paths on both a/ and b/ sides and marks creation in the
    # `--- /dev/null` line; those files simply do not appear in the patch
    # header as /dev/null — the created-file case is only reached by patches
    # explicitly using the /dev/null form, e.g. hand-written or git diff
    # --no-index style.)
    if [ -n "$_old_path" ] && [ "$_old_path" != "/dev/null" ]; then
      patch_files_json="$(jq -cn --argjson acc "$patch_files_json" --arg p "$_old_path" '$acc + [$p]')" || patch_files_json="[]"
    elif [ -n "$_new_path" ] && [ "$_new_path" != "$_rest" ]; then
      patch_created_json="$(jq -cn --argjson acc "$patch_created_json" --arg p "$_new_path" '$acc + [$p]')" || patch_created_json="[]"
    fi
  done <<< "$_h"
fi
# Renames (`diff --git a/old b/new`): the old path is restored to BASE below
# (it appears in the modified list) and the new path is left as the agent left
# it — its content ships in the patch hunk, so there is no separate restore.

# For each file the patch modifies: if the working tree differs from BASE
# (agent modified it) or it is absent, restore it from BASE and record it.
# `git diff --quiet <base> -- <file>` is empty when the tree matches BASE.
# The base is a commit object, so a bare rev (no refname ambiguity): it is
# the fetched commit that exists in this repo's object database.
write_restore_failure() {
  # $1 = path, $2 = stderr. Writes the grade record and exits 2.
  local rp="$1" rr="${2:-}"
  echo "grade: restore failed for $rp" >&2
  jq -cn \
    --arg task "$task_id" \
    --arg arm "$arm" \
    --argjson run "$run_num" \
    --arg test_cmd "$TEST_CMD" \
    --arg patch "$patch_path" \
    --argjson restored "$restored_json" \
    --arg head_moved "$head_moved" \
    --arg error "restore failed for $rp: $rr" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      restored_test_files:$restored, head_moved:($head_moved|if . == "true" then true else false end),
      pass:false, error:$error, graded_at:$graded_at}' \
    > "$run_dir/grade.json" || {
      echo "grade: FATAL — could not write $run_dir/grade.json" >&2
      exit 2
    }
  exit 2
}

while IFS= read -r p; do
  [ -n "$p" ] || continue
  _need_restore=0
  if ! timeout 60 git diff --quiet "$base_sha" -- "$p" 2>/dev/null; then
    # Covers "tree differs from base" AND "base sha does not resolve in
    # this repo" (git diff fails non-zero) — both need a restore.
    _need_restore=1
  elif [ ! -f "$p" ]; then
    # File was deleted by the agent (tracked at BASE, missing in the tree).
    _need_restore=1
  fi
  if [ "$_need_restore" -eq 1 ]; then
    _co_err=""
    if ! _co_err="$(timeout 60 git checkout "$base_sha" -- "$p" 2>&1)"; then
      # Restore failure is a setup error: fail loudly (exit 2) with a
      # grade.json recording the error — do not swallow it and continue.
      write_restore_failure "$p" "${_co_err//$'\n'/ }"
    fi
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
    --arg head_moved "$head_moved" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      restored_test_files:$restored, head_moved:($head_moved == "true"),
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
    --arg head_moved "$head_moved" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      test_log:$test_log, restored_test_files:$restored,
      head_moved:($head_moved == "true"),
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
    --arg head_moved "$head_moved" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      test_log:$test_log, restored_test_files:$restored,
      head_moved:($head_moved == "true"),
      test_rc:$test_rc, pass:false, error:"test command exited '"$test_rc"'",
      graded_at:$graded_at}' \
    > "$run_dir/grade.json" || {
      echo "grade: FATAL — could not write $run_dir/grade.json" >&2
      exit 2
    }
  exit 1
fi
