#!/usr/bin/env bash
# run-arm.sh — run one benchmark arm (A: plain Claude; B: Claude + pi-delegate)
# for a task/arm/run triple.
#
# Usage:
#   bench/run-arm.sh <task-id> <arm> <run#>
#
# Prerequisites:
#   - setup-run.sh <task> <arm> <run>  (creates the clone at BASE_SHA)
#   - task.env fields: REPO, BASE_SHA, FIX_COMMIT, TEST_CMD, GRADING_PATCH
#   - Claude CLI and pi CLI on PATH (pi is found by the shim)
#
# Environment:
#   BENCH_OUT        Output root (default /tmp/pi-bench)
#   CLAUDE_MODEL     Claude model id (default: sonnet alias → claude-sonnet-5-5)
#   CLAUDE_PERM_MODE Permission mode (default: auto)
#   PI_DELEGATE_SHA  Pinned pi-delegate commit to measure (default: be98114)
#   CLAUDE_TIMEOUT   Claude wall-clock seconds (default: 10800)
#   CLAUDE_KILL_AFTER  Kill-after grace (default: 60)
#   BENCH_CLAUDE_TIMEOUT  Same as CLAUDE_TIMEOUT (alias)
#   PI_TIMEOUT       pi wall-clock seconds passed to the wrapper (default: 1800)
#   PI_KILL_AFTER    pi kill-after grace (default: 30)
#
# What this script does (arm A and arm B differ only in the prompt suffix and
# whether the pi-delegate plugin is installed into the per-run config dir):
#   1. Load task.env, resolve the run directory.
#   2. Create a per-run CLAUDE_CONFIG_DIR (isolation: no shared plugin state).
#   3. (Arm B only) Clone the pinned pi-delegate commit into $BENCH_OUT/pin/
#      and seed the marketplace catalog + install the plugin.
#   4. Install the pi shim into <run-dir>/bin (arm B only; arm A does not
#      delegate, but the shim is installed anyway so that an accidental pi
#      call by arm A is still logged — it will fail preflight and exit 3,
#      which is the expected and correct behaviour).
#   5. Build the prompt: prompt.md + (arm B) delegation suffix.
#   6. Run: claude -p <prompt> --output-format json --model <model>
#          --permission-mode <mode>
#      with the run's CLAUDE_CONFIG_DIR and PATH prefixed with the shim.
#   7. Save claude's raw JSON output to <run-dir>/claude/output.json.
#
# Exit codes:
#   0  claude exited 0 (the run may still be a fail — grade.sh decides)
#   1  claude exited non-zero (see <run-dir>/claude/output.json)
#   2  setup/precondition error (missing task, missing clone, missing claude)
#   3  claude timed out (exit 124 or 137 from the timeout wrapper)
#
# The script does NOT grade the run; use bench/grade.sh after.

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

[ -d "$repo_dir" ] || {
  echo "run-arm: repo not found at $repo_dir — run setup-run.sh first" >&2
  exit 2
}

command -v claude >/dev/null 2>&1 || {
  echo "run-arm: claude not found on PATH" >&2; exit 2
}

# --- Resolve config and model ------------------------------------------------
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"
CLAUDE_PERM_MODE="${CLAUDE_PERM_MODE:-auto}"
PI_DELEGATE_SHA="${PI_DELEGATE_SHA:-be98114}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-${BENCH_CLAUDE_TIMEOUT:-10800}}"
CLAUDE_KILL_AFTER="${CLAUDE_KILL_AFTER:-60}"

config_dir="$(claude_config_dir "$run_dir")"

# --- Arm B: pin pi-delegate and install the plugin -----------------------------
# The pinned commit is cloned once per run into $BENCH_OUT/pin/ (shared across
# runs of the same pin, but not shared across arms to avoid cross-contamination
# — each arm has its own config dir and its own plugin install).
if [ "$arm" = "B" ]; then
  pin_dir="$BENCH_OUT/pin/pi-delegate-${PI_DELEGATE_SHA:0:8}-${arm}"
  if [ ! -d "$pin_dir" ]; then
    echo "run-arm: cloning pi-delegate at $PI_DELEGATE_SHA → $pin_dir" >&2
    mkdir -p "$(dirname "$pin_dir")"
    if ! git clone -q "$REPO" "$pin_dir" 2>"$run_dir/pin-clone-err.log"; then
      echo "run-arm: pi-delegate pin clone failed; see $run_dir/pin-clone-err.log" >&2
      exit 2
    fi
  fi
  if ! git -C "$pin_dir" checkout -q "$PI_DELEGATE_SHA"; then
    echo "run-arm: failed to checkout pinned pi-delegate commit $PI_DELEGATE_SHA" >&2
    exit 2
  fi
  if ! install_pi_delegate_plugin "$config_dir" "$pin_dir"; then
    echo "run-arm: WARNING — pi-delegate plugin install failed; arm B will run" >&2
    echo "run-arm:          without the plugin (delegation prompt still applies)." >&2
  fi
fi

# --- Install the pi shim (both arms) ----------------------------------------
# The shim is installed for both arms so that any pi call (whether via the
# delegation prompt in arm B or an accidental call in arm A) is logged.
# For arm A the shim will cause pi's preflight to run; if pi is invoked on a
# default branch or in a repo with secret files, it will refuse (exit 3),
# which is the expected and correct behaviour.
if command -v pi >/dev/null 2>&1; then
  install_pi_shim "$run_dir"
else
  echo "run-arm: WARNING — pi not found on PATH; the shim will not be installed" >&2
  echo "run-arm:          arm B delegation will fail (no pi available)." >&2
fi

# --- Build the prompt ----------------------------------------------------------
prompt_file="$run_dir/prompt.txt"
task_dir="$(task_dir "$task_id")"

# prompt.md is the base; for arm B we append a delegation suffix directing
# Claude to use the pi-delegate skills for the implementation work.
cat "$task_dir/prompt.md" > "$prompt_file"
if [ "$arm" = "B" ]; then
  cat >> "$prompt_file" <<'DELEGSUFFIX'

---

**Delegation instruction (benchmark arm B):**

You have the `pi-delegate` plugin installed, which provides two skills:
- `pi-review-loop` — a deterministic bash review loop that delegates a
  code-change task to the `pi` CLI (cheaper model), then reviews the diff
  and iterates (develop → review → fix, with hard caps).
- `pi-oneshot` — a single `pi -p` invocation for a self-contained task.

For this task, you MUST delegate the implementation work to pi using the
`pi-review-loop` skill (the prompt above is the task description). You
( Claude Code) are responsible for:
  1. Verifying the task is a code change suitable for the review loop.
  2. Invoking the `pi-review-loop` skill with the task description.
  3. After the loop completes, verifying the result by running the test
     command from the task (if present) and confirming the working tree
     has the expected changes.
  4. Reporting the final state (tests pass/fail, what changed).

Do NOT implement the code change yourself. Delegate it to pi via
`pi-review-loop`. You may read files to understand the task, but the
actual edit work must go through the skill.
DELEGSUFFIX
fi

# --- Timeout wrapper -----------------------------------------------------------
# Same pattern as orchestrate.sh: discover timeout/gtimeout, probe
# --kill-after support.
TIMEOUT_CMD=""
for cand in timeout gtimeout; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --kill-after=1 1 true >/dev/null 2>&1; then
    TIMEOUT_CMD="$cand"
    break
  fi
done
wrap=()
if [ -n "$TIMEOUT_CMD" ]; then
  wrap=("$TIMEOUT_CMD" --kill-after="$CLAUDE_KILL_AFTER" "$CLAUDE_TIMEOUT")
fi

# --- Run claude ----------------------------------------------------------------
# PATH is prefixed with the shim's bin dir so that Claude's Bash tool
# resolves `pi` to the shim (the shim then execs the real pi).
# CLAUDE_CONFIG_DIR isolates this run's plugin/config state.
#
# The prompt is passed on stdin to avoid argv size limits (E2BIG) for
# long prompts.
claude_out="$run_dir/claude"
mkdir -p "$claude_out"
PATH="$run_dir/bin:$PATH" \
CLAUDE_CONFIG_DIR="$config_dir" \
PI_SHIM_LOG="$run_dir/pi-calls.jsonl" \
"${wrap[@]+${wrap[@]}}" \
  claude -p \
    --output-format json \
    --model "$CLAUDE_MODEL" \
    --permission-mode "$CLAUDE_PERM_MODE" \
    < "$prompt_file" \
  > "$claude_out/output.json" 2> "$claude_out/stderr.log"
rc=$?

# --- Record run metadata --------------------------------------------------------
# (claude's own JSON is in claude/output.json; this is the harness-side
#  record of how the run was invoked.)
jq -cn \
  --arg task "$task_id" \
  --arg arm "$arm" \
  --argjson run "$run_num" \
  --arg model "$CLAUDE_MODEL" \
  --arg perm_mode "$CLAUDE_PERM_MODE" \
  --arg pi_delegate_sha "$([ "$arm" = "B" ] && echo "$PI_DELEGATE_SHA" || echo "")" \
  --arg config_dir "$config_dir" \
  --arg prompt_file "$prompt_file" \
  --argjson claude_exit "$rc" \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{task:$task, arm:$arm, run:$run, model:$model, perm_mode:$perm_mode,
    pi_delegate_sha:$pi_delegate_sha, config_dir:$config_dir,
    prompt_file:$prompt_file, claude_exit:$claude_exit, started_at:$started_at}' \
  > "$run_dir/run-meta.json"

if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  echo "run-arm: claude timed out after ${CLAUDE_TIMEOUT}s (exit $rc)" >&2
  exit 3
elif [ "$rc" -ne 0 ]; then
  echo "run-arm: claude exited with code $rc; see $claude_out/output.json" >&2
  exit 1
fi

echo "run-arm: OK  task=$task_id arm=$arm run=$run_num" >&2
echo "$run_dir"
