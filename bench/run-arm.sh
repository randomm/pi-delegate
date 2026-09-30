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
#   BENCH_OUT        Output root (default /tmp/pi-bench; must be absolute)
#   CLAUDE_MODEL     Claude model id (default: the literal id claude-sonnet-5-5)
#   CLAUDE_PERM_MODE Permission mode (default: auto)
#   PI_DELEGATE_REPO pi-delegate source for the arm-B pin (default: the local
#                    pi-delegate repo root derived from the harness location —
#                    the repo is private, arm B never touches GitHub; a
#                    remote URL is only an explicit override; a local repo
#                    path also works). NEVER the task REPO.
#   PI_DELEGATE_SHA  Pinned pi-delegate commit to measure (default: the
#                    remote's default-branch HEAD at the first pin)
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
#   3. (Arm B only) Clone the pinned pi-delegate commit into
#      $BENCH_OUT/pin/pi-delegate-<sha> (keyed by SHA only, shared by all
#      runs and all arms) and seed the marketplace catalog + install the
#      plugin. A plugin install failure ABORTS the run (exit 2): a run
#      without the plugin while the prompt asserts it is installed is
#      unmeasurable.
#   4. Install the pi shim into <run-dir>/bin (both arms: the shim logs any
#      accidental pi call in arm A as well).
#   5. Build the prompt: prompt.md + (arm B) delegation suffix.
#   6. Run: claude -p <prompt> --output-format json --model <model>
#          --permission-mode <mode>
#      with the run's CLAUDE_CONFIG_DIR, PATH prefixed with the shim, and
#      **the task checkout as the working directory** (the script cd's into
#      <run-dir>/repo before launching claude, so the run is independent of
#      the caller's cwd — Claude Code refuses a task whose source tree is not
#      the current directory, which bit the dry-run 4 invocation launched
#      from the pi-delegate repo).
#      agent_ms (ms-resolution, run-arm start → claude exit) is recorded in
#      run-meta.json alongside claude's own duration_ms, and the claude
#      wall-clock start/stop are written with millisecond precision
#      (started_ms/ended_ms) so collect.sh can compute wall_clock_ms without
#      the second-resolution truncation that read wall_clock_ms to 0.
#   7. Save claude's raw JSON output to <run-dir>/claude/output.json.
#
# Exit codes:
#   0  claude exited 0 (the run may still be a fail — grade.sh decides)
#   1  claude exited non-zero (see <run-dir>/claude/output.json)
#   2  setup/precondition error (missing task, missing clone, missing claude,
#      pi-delegate pin or plugin install failure)
#   3  claude timed out (exit 124 or 137 from the timeout wrapper)
#
# The script does NOT grade the run; use bench/grade.sh after.
#
# NOTE: a non-zero claude exit still records run-meta.json before exiting —
# failed runs are always recorded (docs/benchmark.md §failed-runs).

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

[ -d "$repo_dir" ] || {
  echo "run-arm: repo not found at $repo_dir — run setup-run.sh first" >&2
  exit 2
}

command -v claude >/dev/null 2>&1 || {
  echo "run-arm: claude not found on PATH" >&2; exit 2
}

# --- Resolve config and model ------------------------------------------------
# The model is pinned to the literal id (not the "sonnet" alias) so runs are
# reproducible and claude's JSON reports usage against the exact id.
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-5-5}"
CLAUDE_PERM_MODE="${CLAUDE_PERM_MODE:-auto}"
# The pi-delegate pin comes from the pi-delegate repo itself
# (PI_DELEGATE_REPO), never from the task REPO. The default is the LOCAL
# pi-delegate repo root (derived from the harness location): the repo is
# private and arm B must never depend on GitHub access — the marketplace is
# added from the local pin directory, never from a remote URL. A remote URL
# may only be supplied as an explicit PI_DELEGATE_REPO override.
PI_DELEGATE_REPO="${PI_DELEGATE_REPO:-$(git -C "$BENCH_DIR" rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$PI_DELEGATE_REPO" ] || [ ! -d "$PI_DELEGATE_REPO" ]; then
  echo "run-arm: PI_DELEGATE_REPO is not a local directory ('$PI_DELEGATE_REPO'); set PI_DELEGATE_REPO explicitly (the pi-delegate repo is private; a remote URL is only an explicit override)" >&2
  exit 2
fi
PI_DELEGATE_SHA="${PI_DELEGATE_SHA:-}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-${BENCH_CLAUDE_TIMEOUT:-10800}}"
CLAUDE_KILL_AFTER="${CLAUDE_KILL_AFTER:-60}"

config_dir="$(claude_config_dir "$run_dir")"

# --- Arm B: pin pi-delegate and install the plugin -----------------------------
# The pinned commit is cloned once per SHA into
# $BENCH_OUT/pin/pi-delegate-<sha> — keyed by SHA only and shared by all
# runs and all arms (same source commit → same tree). If PI_DELEGATE_SHA is
# unset, it is resolved once to the source's default-branch HEAD at the
# first pin and recorded in run-meta.json.
if [ "$arm" = "B" ]; then
  pin_dir="$BENCH_OUT/pin/pi-delegate-$PI_DELEGATE_SHA"
  if [ -z "$PI_DELEGATE_SHA" ]; then
    # Resolve the SHA once from the source (default branch HEAD).
    PI_DELEGATE_SHA="$(timeout 60 git ls-remote "$PI_DELEGATE_REPO" HEAD 2>/dev/null | awk '{print $1}')" || PI_DELEGATE_SHA=""
    [ -n "$PI_DELEGATE_SHA" ] || {
      echo "run-arm: cannot resolve PI_DELEGATE_SHA from $PI_DELEGATE_REPO (set PI_DELEGATE_SHA explicitly)" >&2
      exit 2
    }
    pin_dir="$BENCH_OUT/pin/pi-delegate-$PI_DELEGATE_SHA"
  fi
  if [ ! -d "$pin_dir" ]; then
    echo "run-arm: cloning pi-delegate at $PI_DELEGATE_SHA → $pin_dir" >&2
    mkdir -p "$BENCH_OUT/pin"
    if ! timeout 300 git clone -q "$PI_DELEGATE_REPO" "$pin_dir" 2>"$run_dir/pin-clone-err.log"; then
      echo "run-arm: pi-delegate pin clone failed; see $run_dir/pin-clone-err.log" >&2
      exit 2
    fi
  fi
  # Verify the pin: HEAD must equal PI_DELEGATE_SHA and the plugin
  # marketplace manifest must exist (a bare commit without the skill is
  # not a usable pin). For local sources the clone already shares objects;
  # for remote sources fetch the pinned commit first.
  if [ ! -d "$pin_dir/.git" ] || [ -z "$(timeout 30 git -C "$pin_dir" rev-parse --verify -q "^{commit}" 2>/dev/null)" ] || [ "$(timeout 30 git -C "$pin_dir" rev-parse HEAD 2>/dev/null)" != "$PI_DELEGATE_SHA" ]; then
    if timeout 300 git -C "$pin_dir" fetch -q "$PI_DELEGATE_REPO" "$PI_DELEGATE_SHA" 2>>"$run_dir/pin-clone-err.log" \
      && timeout 30 git -C "$pin_dir" checkout -q "$PI_DELEGATE_SHA"; then
      : # fetched + checked out
    fi
  fi
  if [ "$(timeout 30 git -C "$pin_dir" rev-parse HEAD)" != "$PI_DELEGATE_SHA" ]; then
    echo "run-arm: pi-delegate pin verification failed: HEAD != $PI_DELEGATE_SHA" >&2
    exit 2
  fi
  if [ ! -f "$pin_dir/.claude-plugin/marketplace.json" ]; then
    echo "run-arm: pi-delegate pin is missing .claude-plugin/marketplace.json at $PI_DELEGATE_SHA" >&2
    exit 2
  fi
  # Install the plugin; a failure ABORTS arm B (the prompt asserts the
  # plugin is installed; a run without it is unmeasurable). The CLI's
  # stdout/stderr is captured in <run-dir>/plugin-install.log and printed
  # on failure.
  if ! install_pi_delegate_plugin "$config_dir" "$pin_dir" "$run_dir/plugin-install.log"; then
    echo "run-arm: ABORT — pi-delegate plugin install failed (arm B is unmeasurable without the plugin); see $run_dir/plugin-install.log" >&2
    exit 2
  fi
fi

# --- Install the pi shim (both arms) ----------------------------------------
# The shim is installed for both arms so that any pi call (whether via the
# delegation prompt in arm B or an accidental call in arm A) is logged.
# For arm A the shim will cause pi's preflight to run; if pi is invoked on a
# default branch or in a repo with secret files, it will refuse (exit 3),
# which is the expected and correct behaviour.
# install_pi_shim returns 1 when pi is not found on PATH (outside the shim
# dir) or resolves to a harness shim; arm B must abort (the delegation
# target would be missing), arm A may proceed without a shim.
if ! install_pi_shim "$run_dir"; then
  if [ "$arm" = "B" ]; then
    echo "run-arm: ABORT — arm B requires pi on PATH (pi shim install failed)" >&2
    exit 2
  fi
  echo "run-arm: WARNING — pi not found on PATH (or a shim was resolved); the shim will not be installed; arm A may proceed" >&2
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

You have the `pi-delegate` plugin installed, which provides the
`pi-review-loop` skill: a deterministic bash review loop that delegates a
code-change task to the `pi` CLI, then reviews the diff and iterates
(develop → review → fix, with hard caps).

You MUST delegate the implementation work to pi via the `pi-review-loop`
skill, passing the task description above as the task. Do NOT implement
the code change yourself — the actual edit work must go through the skill.
After the loop completes, verify the result by running the task's test
command (if any) and report the final state (tests pass/fail, what
changed).
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
# agent_ms: millisecond-resolution wall time from just before the claude
# invocation to just after it exits (run-arm start → claude exit). It is
# recorded alongside claude's own duration_ms in run-meta.json; docs say
# the COMPARISON METRIC is claude.duration_ms (agent_ms is the harness
# side's figure and includes prompt/stdin setup and wrapper overhead).
agent_start_ms="$(now_ms)"

# Run claude in the task checkout, not the caller's cwd. Claude Code refuses
# a task whose source tree is not the current working directory (the dry-run
# 4 launch from the pi-delegate repo failed this way), so the script cd's
# into the run's own checkout before the invocation. All claude output paths
# are absolute, so the cd does not change where output.json is written.
cd "$repo_dir"

# PATH is prefixed with the shim's bin dir so that Claude's Bash tool
# resolves `pi` to the shim (the shim then execs the real pi).
# CLAUDE_CONFIG_DIR isolates this run's plugin/config state.
#
# The prompt is passed on stdin to avoid argv size limits (E2BIG) for
# long prompts.
#
# A non-zero claude exit must NOT abort the script before run-meta.json is
# written: failed runs are always recorded (docs/benchmark.md §failed-runs).
claude_out="$run_dir/claude"
mkdir -p "$claude_out"
rc=0
PATH="$run_dir/bin:$PATH" \
CLAUDE_CONFIG_DIR="$config_dir" \
PI_SHIM_LOG="$run_dir/pi-calls.jsonl" \
"${wrap[@]+${wrap[@]}}" \
  claude -p \
    --output-format json \
    --model "$CLAUDE_MODEL" \
    --permission-mode "$CLAUDE_PERM_MODE" \
    < "$prompt_file" \
  > "$claude_out/output.json" 2> "$claude_out/stderr.log" || rc=$?
agent_end_ms="$(now_ms)"
if [ -n "${agent_start_ms:-}" ] && [ -n "${agent_end_ms:-}" ]; then
  agent_ms=$(( agent_end_ms - agent_start_ms ))
else
  agent_ms=0
fi

# --- Record run metadata --------------------------------------------------------
# (claude's own JSON is in claude/output.json; this is the harness-side
#  record of how the run was invoked.) Written on every path — including
#  non-zero claude exit (a null grade must never pass validation, so a
#  failed run must still exist to be collected with grade.pass=false).
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
  --argjson agent_ms "$agent_ms" \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg ended_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson started_ms "${agent_start_ms:-null}" \
  --argjson ended_ms "${agent_end_ms:-null}" \
  '{task:$task, arm:$arm, run:$run, model:$model, perm_mode:$perm_mode,
    pi_delegate_sha:$pi_delegate_sha, config_dir:$config_dir,
    prompt_file:$prompt_file, claude_exit:$claude_exit, agent_ms:$agent_ms,
    started_at:$started_at, ended_at:$ended_at,
    started_ms: (if $started_ms == null then null else $started_ms end),
    ended_ms: (if $ended_ms == null then null else $ended_ms end)}' \
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
