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
if [ -n "$base_sha" ]; then
  echo "grade: base from setup.json" >&2
else
  # No setup.json base_sha: fall back to the task-level BASE_SHA. The
  # setup.json value is the authoritative base (written by setup-run.sh);
  # the task.env value is only a fallback for runs whose setup.json lacks
  # a base_sha.
  base_sha="${BASE_SHA:-}"
  echo "grade: base from task.env" >&2
fi
# head_moved is true/false on every path that reached base resolution and
# null otherwise (e.g. the missing-base early exit below, where the base
# sha could not be determined — docs §grade fields).
head_moved="true"
if [ -n "$base_sha" ]; then
  head_sha="$(git rev-parse HEAD 2>/dev/null)" || head_sha=""
  if [ -n "$head_sha" ] && [ "$head_sha" = "$base_sha" ]; then
    head_moved="false"
  fi
else
  head_moved="null"
fi
# head_moved_json — the JSON form of the head_moved state, used by EVERY
# grade.json writer (true/false/null consistently, via --argjson so the
# value is a real JSON boolean/null, never a string):
#   head_moved=true  → true;  false → false;  null → null
# (the defensive net: the missing-base early exit below writes head_moved:null
# directly with a literal 'null', matching this helper's null case).
head_moved_json() {
  case "$1" in
    true)  printf 'true' ;;
    false) printf 'false' ;;
    *)     printf 'null' ;;
  esac
}
[ -n "$base_sha" ] || {
  echo "grade: cannot determine base sha (no setup.json base_sha, no BASE_SHA in task.env)" >&2
  # grade.json is still recorded on this exit-2 path: the collect line must
  # never see a missing grade on a run dir that exists.
  # NOTE: this early exit is a defensive net, normally unreachable —
  # require_task_fields rejects an empty BASE_SHA before we get here, so
  # base_sha is only empty if task.env is edited between require_task_fields
  # and this point (or a future harness change bypasses that guard). The
  # literal '[]' is NOT $restored_json: that variable is initialised later
  # (before the restore step), so referencing it here would be unbound
  # under set -u.
  jq -cn \
    --arg task "$task_id" \
    --arg arm "$arm" \
    --argjson run "$run_num" \
    --arg test_cmd "$TEST_CMD" \
    --arg patch "$patch_path" \
    --argjson restored '[]' \
    --argjson head_moved "null" \
    --arg error "cannot determine base sha" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      restored_test_files:$restored, head_moved:$head_moved,
      pass:false, error:$error, graded_at:$graded_at}' \
    > "$run_dir/grade.json" || {
      echo "grade: FATAL — could not write $run_dir/grade.json" >&2
      exit 2
    }
  exit 2
}

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
# The file list is derived from the patch itself, from the per-file
# `--- ` / `+++ ` header lines (NOT from the `diff --git` lines — parsing
# those with ` b/` splitting breaks on paths containing " b/" and misses
# the `--- /dev/null` created-file form). Both forms of unified git diff
# (`git diff` and `git diff --no-index`) emit, per file:
#   --- a/<old path>   (or --- /dev/null when the patch creates the file)
#   +++ b/<new path>   (or +++ /dev/null when the patch deletes the file)
# Optionally followed by a TAB + timestamp, which is stripped. Only a `--- `
# line IMMEDIATELY followed by a `+++ ` line is treated as a header: the usual
# content lines inside hunks ("- "/"+ "/" " prefixes) are not in that position,
# so they are ignored. Caveat: a hunk whose content is EXACTLY a `--- ` line
# followed by a `+++ ` line would be misparsed as a header — there is no
# disambiguation. Such a patch is then caught downstream: the bogus path fails
# loudly at the path-safety check below, or at restore/`git apply` (a loud
# failure with a recorded grade.json error, never a silent wrong grade).
# Classification (old, new):
#   both real           → MODIFIED: restore the old path from BASE
#   old /dev/null       → CREATED: delete the new path if present
#   new /dev/null       → DELETED: restore the old path from BASE
#   both /dev/null      → ignored (not a valid patch)
# A patch with zero parseable file headers is a setup error (exit 2) — the
# list is never silently collapsed to empty.
restored_json="[]"
write_patch_header_error() {
  # $1 = error message. Writes the grade record and exits 2 (like the other
  # exit-2 paths, with head_moved). A `return 2` (rather than `exit 2`)
  # would NOT stop the script here: the function is invoked in a compound
  # `cmd || { ...; }` context, where bash disables errexit — only an `exit`
  # (or a failing simple command) aborts the script. The existing
  # write_restore_failure uses a plain exit 2 and is safe because it is
  # called in a plain (non-conditional) context.
  local pe="${1:-}"
  echo "grade: $pe" >&2
  jq -cn \
    --arg task "$task_id" \
    --arg arm "$arm" \
    --argjson run "$run_num" \
    --arg test_cmd "$TEST_CMD" \
    --arg patch "$patch_path" \
    --argjson restored "$restored_json" \
    --argjson head_moved "$(head_moved_json "$head_moved")" \
    --arg error "$pe" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      restored_test_files:$restored, head_moved:$head_moved,
      pass:false, error:$error, graded_at:$graded_at}' \
    > "$run_dir/grade.json" || {
      echo "grade: FATAL — could not write $run_dir/grade.json" >&2
      exit 2
    }
  exit 2
}
# Parse per-file headers from the patch with awk. A "--- " line is a header
# candidate only when the NEXT line begins with "+++ "; the pending candidate
# is discarded otherwise, so the usual content lines inside hunks ("- " / "+ "
# / " " prefixes) are not treated as headers. A hunk whose content is exactly
# a `--- ` line followed by a `+++ ` line WOULD be treated as a header (no
# disambiguation is possible); that misparse then fails loudly at the path-
# safety check below or at restore/`git apply` — never a silent wrong grade.
# The awk runs as a PLAIN command (not `VAR=$(awk …) || rc=$?`): bash
# applies `set -e` to a variable assignment in the same breath as the
# subshell exit status, so a failing awk would abort the script at the
# assignment line (the following `|| _parse_rc=$?` never runs), and no
# grade.json would be written. Running awk standalone and redirecting its
# stdout to a temp file is a simple command whose non-zero exit IS caught by
# the `|| _parse_rc=$?` guard. rc=0 is the success case; non-zero means awk
# could not read the file.
# The awk stdout goes to a FIXED path inside the run dir (not mktemp): the
# run dir is the harness's own scratch space under BENCH_OUT, and a fixed
# name plus an EXIT trap makes the temp file cleanup deterministic on every
# exit path (a leftover mktemp file in /tmp would survive a script failure).
_parse_out_file="$run_dir/.grade-parse.out"
trap 'rm -f "$run_dir/.grade-parse.out"' EXIT
_parse_rc=0
timeout 60 awk '
  /^--- / {
    pend = $0
    sub(/^--- /, "", pend)
    next
  }
  /^\+\+\+ / && pend != "" {
    pend_plus = $0
    sub(/^\+\+\+ /, "", pend_plus)
    # Strip a trailing TAB + anything (the optional timestamp field),
    # preserving everything before the first TAB (path with spaces).
    ti = index(pend, "\t")
    if (ti > 0) pend = substr(pend, 1, ti - 1)
    tj = index(pend_plus, "\t")
    if (tj > 0) pend_plus = substr(pend_plus, 1, tj - 1)
    # Old side: "a/<path>" or "/dev/null" (or bare "<path>").
    if (pend == "/dev/null") old = "/dev/null"
    else if (index(pend, "a/") == 1) old = substr(pend, 3)
    else old = pend
    # New side: "b/<path>" or "/dev/null".
    if (pend_plus == "/dev/null") newp = "/dev/null"
    else if (index(pend_plus, "b/") == 1) newp = substr(pend_plus, 3)
    else newp = pend_plus
    pend = ""
    tag = (old == "/dev/null" || newp == "/dev/null") ? "C" : "M"
    printf "%s\t%s\t%s\n", tag, old, newp
  }
  { pend = "" }
' "$patch_path" > "$_parse_out_file" 2>/dev/null || _parse_rc=$?
_parse_out="$(cat "$_parse_out_file" 2>/dev/null)" || true
rm -f "$_parse_out_file"
# A non-zero awk exit is "failed to read", independent of the -f/-r probes
# below; only an awk success with no output reaches the header probe.
if [ "$_parse_rc" -ne 0 ]; then
  write_patch_header_error "failed to read grading patch: $patch_path"
  # Unreachable: write_patch_header_error exits the script (exit 2).
  exit 2
fi
if [ -z "$_parse_out" ]; then
  # Read/grep failure OR zero file headers — both are setup errors. The list
  # is never silently collapsed to an empty list.
  if [ -f "$patch_path" ] && [ -r "$patch_path" ]; then
    write_patch_header_error "grading patch has no file headers: $patch_path"
  else
    write_patch_header_error "failed to read grading patch: $patch_path"
  fi
  # Unreachable: write_patch_header_error exits the script (exit 2).
  exit 2
fi
# Path safety: any parsed path (old or new side, not /dev/null) that is
# absolute or contains a `..` component is refused. A misparsed hunk (see the
# awk comment above) can only surface paths like these, so failing loudly here
# keeps a malformed patch from ever touching restore/apply with a bogus path.
patch_modified_json="[]"
patch_created_json="[]"
while IFS=$'\t' read -r _kind _old_path _new_path; do
  case "$_kind" in
    M)
      patch_modified_json="$(jq -cn --argjson acc "$patch_modified_json" --arg p "$_old_path" '$acc + [$p]')" \
        || write_patch_header_error "failed to build grading file list: jq failed for $_old_path"
      ;;
    C)
      if [ "$_old_path" = "/dev/null" ]; then
        # Created: delete the new path if present (below).
        patch_created_json="$(jq -cn --argjson acc "$patch_created_json" --arg p "$_new_path" '$acc + [$p]')" \
          || write_patch_header_error "failed to build grading file list: jq failed for $_new_path"
      elif [ "$_new_path" = "/dev/null" ]; then
        # Deleted by the patch: restore the old path from BASE (below).
        patch_modified_json="$(jq -cn --argjson acc "$patch_modified_json" --arg p "$_old_path" '$acc + [$p]')" \
          || write_patch_header_error "failed to build grading file list: jq failed for $_old_path"
      else
        : # both /dev/null — not a valid patch file, ignore.
      fi
      ;;
  esac
  for _pp in "$_old_path" "$_new_path"; do
    [ -n "$_pp" ] || continue
    [ "$_pp" = "/dev/null" ] && continue
    case "$_pp" in
      /*) write_patch_header_error "unsafe path in grading patch: $_pp" ;;
      ../*|*/..|*/../*) write_patch_header_error "unsafe path in grading patch: $_pp" ;;
    esac
  done
done <<< "$_parse_out"

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
    --argjson head_moved "$(head_moved_json "$head_moved")" \
    --arg error "restore failed for $rp: $rr" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      restored_test_files:$restored, head_moved:$head_moved,
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
    # This is also the natural case for a file the patch DELETES: the old
    # path is restored from BASE so `git apply` can delete it cleanly.
    _need_restore=1
  fi
  if [ "$_need_restore" -eq 1 ]; then
    _co_err=""
    _co_rc=0
    _co_err="$(timeout 60 git checkout "$base_sha" -- "$p" 2>&1)" || _co_rc=$?
    if [ "$_co_rc" -eq 124 ] || [ "$_co_rc" -eq 137 ]; then
      write_restore_failure "$p" "timeout after 60s"
    elif [ "$_co_rc" -ne 0 ]; then
      # Restore failure is a setup error: fail loudly (exit 2) with a
      # grade.json recording the error — do not swallow it and continue.
      write_restore_failure "$p" "${_co_err//$'\n'/ }"
    fi
    restored_json="$(jq -cn --argjson rest "$restored_json" --arg f "$p" '$rest + [$f]')" \
      || write_restore_failure "$p" "failed to record restore (jq error)"
  fi
done < <(jq -r '.[]' <<< "$patch_modified_json" 2>/dev/null)
# For each file the patch creates: delete it if present (a stray copy of the
# graded test file left by the agent would break `git apply`).
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ -f "$p" ]; then
    if ! rm -f -- "$p"; then
      # A stray copy that cannot be removed blocks `git apply`: fail loudly
      # (the file is not restored, so it is not recorded in the list).
      write_restore_failure "$p" "could not delete stray created file"
    fi
    restored_json="$(jq -cn --argjson rest "$restored_json" --arg f "$p" '$rest + [$f]')" \
      || write_restore_failure "$p" "failed to record restore (jq error)"
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
    --argjson head_moved "$(head_moved_json "$head_moved")" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      restored_test_files:$restored, head_moved:$head_moved,
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
    --argjson head_moved "$(head_moved_json "$head_moved")" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      test_log:$test_log, restored_test_files:$restored,
      head_moved:$head_moved,
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
    --argjson head_moved "$(head_moved_json "$head_moved")" \
    --arg graded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:$task, arm:$arm, run:$run, test_cmd:$test_cmd, patch:$patch,
      test_log:$test_log, restored_test_files:$restored,
      head_moved:$head_moved,
      test_rc:$test_rc, pass:false, error:"test command exited '"$test_rc"'",
      graded_at:$graded_at}' \
    > "$run_dir/grade.json" || {
      echo "grade: FATAL — could not write $run_dir/grade.json" >&2
      exit 2
    } 
  exit 1
fi
