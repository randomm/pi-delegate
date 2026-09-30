#!/usr/bin/env bash
# lib.sh — shared helpers for the benchmark harness. Sourced by the other
# scripts; never executed directly.
#
# Design rules (see docs/benchmark.md):
#   - All run captures live under $BENCH_OUT (default: /tmp/pi-bench),
#     OUTSIDE every repo — a file in a repo's tree is a dirty working tree.
#   - No framework: bash + git + jq. Every script is self-contained except
#     for the functions in this file.
#   - Every harness script starts with `set -euo pipefail` and a BENCH_OUT
#     guard (bench_out_guard): BENCH_OUT must be a non-empty absolute path.
#     Every destructive rm -rf is routed through guard_rm_rf, which refuses
#     targets outside $BENCH_OUT.
#
# This file defines functions and read-only path variables. It does not
# mutate the caller's environment beyond the exported BENCH_* variables.

# --- Resolve paths relative to this file ------------------------------------
bench_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="${BENCH_DIR:-$bench_lib_dir}"
TASKS_DIR="${TASKS_DIR:-$BENCH_DIR/tasks}"
# Note: ${BENCH_OUT-...} (dash form, not the colon form) is used so that an
# explicitly-empty export (BENCH_OUT=) is NOT silently replaced by the
# default — an empty value propagates to bench_out_guard, which refuses it.
BENCH_OUT="${BENCH_OUT-/tmp/pi-bench}"

# --- Task helpers -------------------------------------------------------------

# task_dir <id> — prints the task directory; dies if absent.
task_dir() {
  local id="$1"
  local dir="$TASKS_DIR/$id"
  if [ ! -d "$dir" ]; then
    echo "task '$id' not found (expected $dir)" >&2
    return 1
  fi
  echo "$dir"
}

# task_env <id> — loads a task's task.env into the caller's environment.
# task.env is a KEY=VALUE file (values are trusted — operator-supplied;
# the file is SOURCED by this function, so anything in it executes in the
# harness's shell. task.env files must be operator-authored).
# Returns 1 if the file cannot be sourced.
task_env() {
  local id="$1" dir
  dir="$(task_dir "$id")" || return 1
  if [ ! -f "$dir/task.env" ]; then
    echo "task '$id': missing task.env" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source "$dir/task.env"
}

# require_task_fields <id> — checks that all fields required by the harness
# are set in task.env; prints the first missing one and returns 1.
require_task_fields() {
  local id="$1" field
  task_env "$id" || return 1
  for field in REPO BASE_SHA TEST_CMD; do
    if [ -z "${!field:-}" ]; then
      echo "task '$id': missing required field $field in task.env" >&2
      return 1
    fi
  done
  # FIX_COMMIT or FIX_SHA must be set (either name is accepted).
  if [ -z "${FIX_SHA:-}" ] && [ -z "${FIX_COMMIT:-}" ]; then
    echo "task '$id': missing required field FIX_SHA (or FIX_COMMIT) in task.env" >&2
    return 1
  fi
  return 0
}

# --- Arm helpers ---------------------------------------------------------------

# bench_out_guard — refuses to operate if BENCH_OUT is unset/empty or not an
# absolute path under which runs may be created (rm -rf is run against run
# dirs under BENCH_OUT; a relative or empty value would rm the wrong tree).
# The BENCH_OUT value is passed to the child with -n because an empty
# assignment (BENCH_OUT=) exports an EMPTY string, not an unset variable,
# and the child's ${BENCH_OUT:-/tmp/pi-bench} default would silently fall
# back to /tmp/pi-bench instead of failing.
# Returns 1 on failure.
bench_out_guard() {
  local out="${BENCH_OUT-}"
  if [ -z "$out" ]; then
    echo "BENCH_OUT is not set; refusing to continue" >&2
    return 1
  fi
  case "$out" in
    /*) : ;;
    *)
      echo "BENCH_OUT must be an absolute path (got '$out')" >&2
      return 1
      ;;
  esac
  return 0
}

# guard_rm_rf <path> — rm -rf with the path validated: it must be non-empty
# and start with the BENCH_OUT prefix (with a / boundary). Refuses (returns
# 1, removes nothing) otherwise.
guard_rm_rf() {
  local path="$1"
  bench_out_guard || return 1
  case "$path" in
    "$BENCH_OUT"/*) rm -rf "$path" ;;
    *)
      echo "guard_rm_rf: refusing to remove '$path' (not under BENCH_OUT)" >&2
      return 1
      ;;
  esac
}

# validate_grading_patch <value> — a GRADING_PATCH must be a relative path
# inside the task dir: no leading '/' (absolute), no '..' component (path
# traversal out of the task dir). Returns 1 on violation.
validate_grading_patch() {
  local p="$1"
  if [ -z "$p" ]; then
    return 0
  fi
  case "$p" in
    /*)
      echo "GRADING_PATCH must be a relative path (got '$p')" >&2
      return 1
      ;;
  esac
  case "$p" in
    *..*)
      echo "GRADING_PATCH must not contain '..' (got '$p')" >&2
      return 1
      ;;
  esac
  return 0
}

# arm_run_dir <task> <arm> <run#> — prints and creates the run's output dir.
arm_run_dir() {
  local task="$1" arm="$2" run="$3"
  local dir="$BENCH_OUT/$task/$arm/$run"
  mkdir -p "$dir"
  echo "$dir"
}

# run_repo_dir <task> <arm> <run#> — prints the fresh-clone path for a run.
run_repo_dir() {
  local task="$1" arm="$2" run="$3"
  echo "$BENCH_OUT/$task/$arm/$run/repo"
}

# --- Millisecond clock ---------------------------------------------------------

# now_ms — current wall-clock time in milliseconds. Uses python3
# (int(time.time()*1000)) or perl Time::HiRes as fallbacks. Prints an
# empty string if neither is available (callers must tolerate that).
now_ms() {
  local out=""
  if command -v python3 >/dev/null 2>&1; then
    out="$(python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null)" || out=""
  fi
  if [ -z "$out" ] && command -v perl >/dev/null 2>&1; then
    out="$(perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time()*1000' 2>/dev/null)" || out=""
  fi
  if [ -z "$out" ]; then
    out=$(( $(date +%s) * 1000 ))
  fi
  case "$out" in
    ''|*[!0-9]*) echo "" ;;
    *) echo "$out" ;;
  esac
}

# --- pi shim setup ---------------------------------------------------------------

# Marker line written literally into the second line of every shim
# install_pi_shim generates; the grep check below uses it to detect (and
# refuse) a harness shim masquerading as a real pi.
PI_SHIM_MARKER="# pi-delegate-bench-shim"

# install_pi_shim <run-dir> — writes a `pi` wrapper into <run-dir>/bin/pi
# that logs every invocation and then runs the real pi.
#
# run-arm.sh prepends <run-dir>/bin to PATH so that Claude's Bash tool finds
# the shim first (it resolves `pi` via PATH lookup in the child process).
#
# The shim passes the real pi's stdout and exit code through
# BYTE-FOR-BYTE: orchestrate.sh (pi-review-loop) parses pi's --mode json
# stdout, so any line rebuilding in the shim (literal \n, dropped blank
# lines, first-line-only output) breaks arm B. The shim runs pi into a temp
# file, cats the temp file to stdout, cats it again into the per-call
# transcript (json mode), and preserves the exit code. On non-zero exit,
# stderr is passed through to the shim's stderr AND kept as a copy at
# <run-dir>/pi-err-<call_id>.log.
#
# Behaviour:
#   --mode json (review-loop path):
#     - keeps a byte-identical copy of pi's stdout as
#       <run-dir>/pi-<N>.jsonl (N = the call id); collect.sh parses usage
#       from the per-call JSONL files.
#   text mode (oneshot path):
#     - record argv + wall clock + exit code to <run-dir>/pi-calls.jsonl.
#     - the per-call token count is not available (text mode has no usage
#       events); collect.sh reports pi_tokens as null for those calls.
#     - This is the documented token-accounting gap (docs/benchmark.md).
#
# --no-context-files: injected exactly once if not already present in argv.
# This enforces the operator's decision (issue #41: pi runs without project
# context files) for the pi-oneshot path without editing the shipped skill.
# pi-review-loop already passes it itself, so the injection is a no-op there.
install_pi_shim() {
  local run_dir="$1" bin_dir="$1/bin"
  mkdir -p "$bin_dir"
  local shim="$bin_dir/pi"

  # Resolve the real pi path at install time so the shim is stable even if
  # PATH changes between install and invocation. The shim's own bin dir
  # (this run's <run-dir>/bin) is removed from PATH before resolution:
  # without that, `command -v pi` could return the shim itself (if a prior
  # install left one on PATH) and the shim would exec itself forever.
  local real_pi
  if [ -d "$bin_dir" ]; then
    local cleaned_path cleaned_entry
    local -a parts
    IFS=':' read -ra parts <<< "$PATH"
    cleaned_path=""
    for cleaned_entry in "${parts[@]}"; do
      [ "$cleaned_entry" = "$bin_dir" ] && continue
      if [ -z "$cleaned_path" ]; then
        cleaned_path="$cleaned_entry"
      else
        cleaned_path="$cleaned_path:$cleaned_entry"
      fi
    done
    real_pi="$(PATH="$cleaned_path" bash -c 'command -v pi 2>/dev/null')" || real_pi=""
  else
    real_pi="$(command -v pi 2>/dev/null)" || real_pi=""
  fi
  if [ -z "$real_pi" ]; then
    echo "install_pi_shim: pi not found on PATH (outside the shim dir)" >&2
    return 1
  fi
  # If the resolved pi is a harness shim (a pi script in another run dir's
  # bin), refuse rather than nest shims. Detection is by the marker line
  # install_pi_shim writes into every generated shim (PI_SHIM_MARKER above),
  # NOT by the path shape: a genuine pi legitimately lives in */bin/pi
  # (e.g. ~/.bun/bin/pi) and must be accepted.
  local pi_target
  pi_target="$(readlink -f "$real_pi" 2>/dev/null)" || pi_target=""
  if [ -z "$pi_target" ] || [ ! -f "$pi_target" ]; then
    pi_target="$real_pi"
  fi
  if [ -f "$pi_target" ] && grep -q -F "$PI_SHIM_MARKER" "$pi_target" 2>/dev/null; then
    echo "install_pi_shim: real pi resolves to a harness shim ('$real_pi'); refusing" >&2
    return 1
  fi

  # The shim is written in two parts to avoid sed substitution of the
  # real pi path (which could contain sed special characters). Part 1:
  # header lines with the marker and the real pi path (quoted via %q so
  # special characters in the path cannot break the assignment). Part 2:
  # the heredoc body (QUOTED delimiter so that $@, $$, $a, $prev, etc.
  # are NOT expanded at install time — they are evaluated at CALL time).
  # Double-quote the path (the benchmark pi path will not contain shell
  # metacharacters; if it did, the escaping below handles backslash, quote,
  # dollar, and backtick). No sed needed.
  local safe_real_pi="$real_pi"
  safe_real_pi="${safe_real_pi//\\/\\\\}"
  safe_real_pi="${safe_real_pi//\"/\\\"}"
  safe_real_pi="${safe_real_pi//\$/\\\$}"
  local _bt
  _bt='`'
  safe_real_pi="${safe_real_pi//${_bt}/\\${_bt}}"
  printf '#!/usr/bin/env bash\n%s\nREAL_PI="%s"\n' "$PI_SHIM_MARKER" "$safe_real_pi" > "$shim"
  cat >> "$shim" <<'SHEOF'
# pi shim — benchmark harness (docs/benchmark.md §pi-shim).
# Generated by bench/lib.sh install_pi_shim. Do not edit.
#
# The real pi's stdout and exit code pass through BYTE-FOR-BYTE:
# pi-review-loop parses --mode json stdout, so the shim must never rebuild
# the output (no literal \n, no dropped blank lines, no first-line-only).
set -u

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${PI_SHIM_LOG:-$RUN_DIR/pi-calls.jsonl}"
# Per-call id: epoch-seconds + $$ is portable (BSD date has no %3N).
# The pid is the real uniqueness source for concurrent calls in one run;
# two pids can never be equal, so call ids are unique per run and the
# per-run transcript files (pi-<call_id>.jsonl) never collide.
CALL_TAG="$(date +%s)_$$"

# now_ms_shell — millisecond wall clock (python3, perl Time::HiRes, or
# epoch-seconds fallback). Defined before first use (the shim body is
# top-down; bash functions are not hoisted).
now_ms_shell() {
  local out=""
  if command -v python3 >/dev/null 2>&1; then
    out="$(python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null)" || out=""
  fi
  if [ -z "$out" ] && command -v perl >/dev/null 2>&1; then
    out="$(perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time()*1000' 2>/dev/null)" || out=""
  fi
  if [ -z "$out" ]; then
    out=$(( $(date +%s) * 1000 ))
  fi
  printf '%s' "$out"
}

t0="$(now_ms_shell)"

args=("$@")

# Inject --no-context-files exactly once if not already present.
injected=0
for a in "${args[@]}"; do
  if [ "$a" = "--no-context-files" ] || [ "$a" = "-nc" ]; then
    injected=1
    break
  fi
done
if [ "$injected" -eq 0 ]; then
  args+=(--no-context-files)
fi

# Detect --mode json in argv (adjacent pair).
json_mode=0
prev=""
for a in "${args[@]}"; do
  if [ "$prev" = "--mode" ] && [ "$a" = "json" ]; then
    json_mode=1
  fi
  prev="$a"
done

stdout_file="$RUN_DIR/pi-stdout-$CALL_TAG.tmp"
err_file="$RUN_DIR/pi-err-$CALL_TAG.tmp"

# Run the real pi: stdout → temp file (byte-for-byte), stderr → temp file.
"$REAL_PI" "${args[@]}" > "$stdout_file" 2> "$err_file"
rc=$?

# Pass stdout through byte-for-byte (cat, no line processing).
cat "$stdout_file"

if [ "$json_mode" -eq 1 ]; then
  # Review-loop path: keep a byte-identical copy as the per-call transcript.
  cat "$stdout_file" > "$RUN_DIR/pi-$CALL_TAG.jsonl"
fi

# Non-zero rc: pass stderr through to stderr AND keep a copy as the
# per-call error log.
if [ "$rc" -ne 0 ]; then
  if [ -s "$err_file" ]; then
    cat "$err_file" >&2
  fi
  cp "$err_file" "$RUN_DIR/pi-err-$CALL_TAG.log"
fi
rm -f "$stdout_file" "$err_file"

t1="$(now_ms_shell)"
dur_ms=$(( t1 - t0 ))

# Build argv as a JSON array. Each element is one argv entry: "${args[@]}"
# (never "${args[*]}") so element boundaries survive even if an argument
# contains spaces; one element per line, one line per argv element.
argv_json="$(for a in "${args[@]}"; do printf '%s\n' "$a"; done | jq -Rn '[inputs]')"

# Append one metadata line to pi-calls.jsonl.
jq -cn \
  --argjson argv "$argv_json" \
  --argjson duration_ms "$dur_ms" \
  --argjson exit "$rc" \
  --arg mode "$([ "$json_mode" -eq 1 ] && echo json || echo text)" \
  --arg call_id "$CALL_TAG" \
  '{argv:$argv, duration_ms:$duration_ms, exit:$exit, mode:$mode, call_id:$call_id}' \
  >> "$LOG_FILE" 2>/dev/null

exit "$rc"
SHEOF
  chmod +x "$shim"
}

# --- Claude config-dir setup ---------------------------------------------------

# claude_config_dir <run-dir> — prints and creates a per-run CLAUDE_CONFIG_DIR.
#
# Subscription auth on macOS lives in the login keychain under
# "Claude Code-credentials", keyed by user account — NOT by config dir.
# A fresh CLAUDE_CONFIG_DIR therefore starts with no plugins/settings but
# still authenticates via the same subscription login (dry-run verified).
claude_config_dir() {
  local run_dir="$1"
  local dir="$run_dir/claude-config"
  mkdir -p "$dir"
  echo "$dir"
}

# install_pi_delegate_plugin <config-dir> <pinned-source-dir> <log-file>
# Installs the pi-delegate plugin from <pinned-source-dir> into the config
# dir via the supported CLI only:
#   1. `claude plugin marketplace add <pinned-source-dir>`
#   2. `claude plugin install pi-delegate@pi-delegate`
# 3. Verify with `claude plugin list --json` that pi-delegate@pi-delegate is
#    installed and enabled.
#
# Hand-seeding plugins/known_marketplaces.json is NOT supported — a
# hand-written catalog entry fails validation at install time ("Invalid
# discriminator value"). The CLI writes the catalog entry itself in the
# shape it validates.
#
# All CLI stdout/stderr is appended to <log-file> (in the run dir) and
# printed on failure — never discarded.
#
# A plugin install failure is FATAL for arm B: the run would run without
# the plugin while the prompt still asserts it is installed. This function
# returns 1 on install failure and the caller (run-arm.sh) aborts the run.
install_pi_delegate_plugin() {
  local config_dir="$1" src_dir="$2" log_file="$3"
  # NO `|| true`: any step failure aborts arm B (the prompt asserts the
  # plugin is installed; a run without it is unmeasurable).
  if ! CLAUDE_CONFIG_DIR="$config_dir" timeout 120 claude plugin marketplace add \
    "$src_dir" >>"$log_file" 2>&1; then
    echo "install_pi_delegate_plugin: claude plugin marketplace add failed; see $log_file" >&2
    cat "$log_file" >&2 2>/dev/null || true
    return 1
  fi
  if ! CLAUDE_CONFIG_DIR="$config_dir" timeout 120 claude plugin install \
    pi-delegate@pi-delegate >>"$log_file" 2>&1; then
    echo "install_pi_delegate_plugin: claude plugin install failed; see $log_file" >&2
    cat "$log_file" >&2 2>/dev/null || true
    return 1
  fi
  # Verify the plugin is actually installed and enabled (stub claude in
  # tests must implement `plugin list --json`). The real CLI reports
  # {"id": "pi-delegate@pi-delegate", ...}; test stubs may report the
  # {"name", "source"} pair instead — both shapes are accepted.
  local list_json
  if ! list_json="$(CLAUDE_CONFIG_DIR="$config_dir" timeout 120 claude plugin list --json 2>>"$log_file")"; then
    echo "install_pi_delegate_plugin: claude plugin list failed after install; see $log_file" >&2
    cat "$log_file" >&2 2>/dev/null || true
    return 1
  fi
  if ! printf '%s' "$list_json" | jq -e \
    '[.[]? | select((.id? // ((.name? // "") + "@" + (.source? // ""))) == "pi-delegate@pi-delegate" or (.name? == "pi-delegate" and .source? == "pi-delegate")) and ((.enabled? // true) == true)] | length > 0' \
    >/dev/null 2>&1; then
    echo "install_pi_delegate_plugin: pi-delegate@pi-delegate not enabled after install" >&2
    printf '%s\n' "$list_json" >&2
    return 1
  fi
  return 0
}
