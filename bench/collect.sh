#!/usr/bin/env bash
# collect.sh — parse a run's captured output into a single JSON metrics line.
#
# Usage:
#   bench/collect.sh <task-id> <arm> <run#> [output.jsonl]
#
# Reads from <run-dir>:
#   claude/output.json   raw claude -p --output-format json output
#   run-meta.json        harness run metadata (model, perm mode, pi-delegate sha)
#   setup.json           setup metadata (base sha, branch, etc.)
#   grade.json           grading result (pass/fail, test cmd, test log path)
#   pi-calls.jsonl       one line per pi call (argv, duration, exit, mode)
#   pi-<N>.jsonl         per-call pi --mode json transcript (review-loop path)
#
# Writes (to stdout or [output.jsonl] if given):
#   One JSON object per run with:
#     task, arm, run, model, permission_mode, pi_delegate_commit,
#     target_commit (base sha from setup.json),
#     claude: {
#       cost_usd, duration_ms, permission_denials (array),
#       model_usage: {<model>: {input_tokens, output_tokens, cache_read,
#                              cache_creation, cost_usd}}
#     },
#     pi: [
#       {call_id, mode, exit, duration_ms, argv,
#        tokens: {input, output, cache_read, cache_write, total} | null}
#     ],
#     grade: {pass, test_cmd, error},
#     wall_clock_ms (from setup/setup_at to grade/graded_at, or null)
#
# Exit codes:
#   0  success (one JSON line written)
#   1  run directory missing or claude/output.json missing
#   2  claude/output.json is not valid JSON (malformed run)
#
# Validation: the output line is validated with jq before being written.
# Required fields: task, arm, run, model, target_commit, grade.pass.
# Numeric fields: claude.duration_ms, claude.cost_usd (nullable),
#   pi[].duration_ms, pi[].tokens.* (nullable).
# A malformed run (missing required fields, non-numeric where numeric
# expected) causes a non-zero exit so the caller can flag it.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo "Usage: $0 <task-id> <arm> <run#> [output.jsonl]" >&2
  exit 1
}
[ "${#}" -eq 3 ] || [ "${#}" -eq 4 ] || usage
task_id="$1"; arm="$2"; run_num="$3"
out_file="${4:-}"

case "$arm" in A|B) ;; *) echo "arm must be A or B" >&2; exit 1 ;; esac
if ! [[ "$run_num" =~ ^[0-9]+$ ]] || [ "$run_num" -lt 1 ]; then
  echo "run# must be a positive integer" >&2; exit 1
fi

run_dir="$BENCH_OUT/$task_id/$arm/$run_num"
[ -d "$run_dir" ] || { echo "collect: run dir not found: $run_dir" >&2; exit 1; }

# require_task_fields writes to stderr on failure; it is not needed for
# collection (the run dir already contains everything we read). We only
# need the task to exist in TASKS_DIR for the id to be valid.
[ -d "$TASKS_DIR/$task_id" ] || {
  echo "collect: task '$task_id' not found in $TASKS_DIR" >&2; exit 1
}

claude_json="$run_dir/claude/output.json"
[ -f "$claude_json" ] || {
  echo "collect: claude output not found: $claude_json" >&2; exit 1
}

# Validate claude/output.json is JSON.
if ! jq -e . "$claude_json" >/dev/null 2>&1; then
  echo "collect: claude/output.json is not valid JSON" >&2; exit 2
fi

# Load setup.json (base sha) — optional but expected.
setup_json="$run_dir/setup.json"
target_commit="null"
if [ -f "$setup_json" ]; then
  target_commit="$(jq -r '.base_sha // "null"' "$setup_json")"
fi

# Load run-meta.json (model, perm mode, pi_delegate_sha) — optional.
meta_json="$run_dir/run-meta.json"
model="null"; perm_mode="null"; pi_delegate_sha="null"
if [ -f "$meta_json" ]; then
  model="$(jq -r '.model // "null"' "$meta_json")"
  perm_mode="$(jq -r '.perm_mode // "null"' "$meta_json")"
  pi_delegate_sha="$(jq -r '.pi_delegate_sha // ""' "$meta_json")"
  [ -z "$pi_delegate_sha" ] && pi_delegate_sha="null"
fi

# Load grade.json — optional but expected after grading.
grade_json="$run_dir/grade.json"
grade_obj='null'
if [ -f "$grade_json" ]; then
  grade_obj="$(jq -c '{pass, test_cmd, error}' "$grade_json" 2>/dev/null || echo 'null')"
fi

# Parse claude metrics.
# claude -p --output-format json produces a JSON object with:
#   total_cost_usd, duration_ms, permission_denials (array),
#   modelUsage: {<model>: {inputTokens, outputTokens, cacheReadInputTokens,
#                        cacheCreationInputTokens, costUSD, ...}},
#   is_error, result, etc.
claude_metrics="$(jq -c '
  {
    cost_usd: (.total_cost_usd // 0),
    duration_ms: (.duration_ms // null),
    permission_denials: (.permission_denials // []),
    is_error: (.is_error // false),
    model_usage: (
      (.modelUsage // {}) | to_entries | map({
        ( .key ): {
          input_tokens:    (.value.inputTokens            // 0),
          output_tokens:   (.value.outputTokens           // 0),
          cache_read:      (.value.cacheReadInputTokens   // 0),
          cache_creation:  (.value.cacheCreationInputTokens // 0),
          cost_usd:        (.value.costUSD                // 0)
        }
      }) | add // {}
    )
  }
' "$claude_json")"

# Parse pi calls.
# pi-calls.jsonl: one JSON object per pi invocation (argv, duration_ms,
# exit, mode, call_id).
# pi-<N>.jsonl: per-call transcript for --mode json invocations.
# For each call, if mode is "json" and a corresponding pi-<call_id>.jsonl
# exists, extract usage from the last message_end event.
# For "text" mode calls, tokens is null (documented gap).


# Build the pi array. If no pi-calls.jsonl, the array is empty.
pi_calls_json="[]"
if [ -f "$run_dir/pi-calls.jsonl" ]; then
  # Process each line of pi-calls.jsonl. Accumulate a jq array by parsing
  # the whole file at once (one JSON array input) instead of concatenating
  # per-line strings (which breaks when a call spans multiple lines after
  # jq pretty-prints, or when the shell mangles embedded newlines).
  #
  # We use a two-step approach:
  #   1. For each call_id with mode=json, extract tokens from the transcript.
  #   2. Build the pi array in one jq call over the whole pi-calls.jsonl,
  #      looking up tokens from a temp map file.
  # Build the tokens map as a JSONL file (one {id, tokens} object per line).
  tokens_map="$run_dir/.pi-tokens-map.jsonl"
  : > "$tokens_map"
  # Build the tokens map as a JSONL file (one {id, tokens} object per line).
  # All stderr from the loop is suppressed so jq errors inside the loop
  # (e.g. from a malformed call line) do not pollute the script's stderr.
  # NOTE: the `} 2>/dev/null` wrapper redirects stderr of the entire block;
  # the loop body's individual 2>/dev/null redirects are redundant but harmless.
  {
    while IFS= read -r call_line; do
      [ -z "$call_line" ] && continue
      call_id="$(printf '%s' "$call_line" | jq -r '.call_id // empty' 2>/dev/null)" || call_id=""
      [ -z "$call_id" ] && continue
      mode="$(printf '%s' "$call_line" | jq -r '.mode // empty' 2>/dev/null)" || mode=""
      [ "$mode" = "json" ] || continue
      transcript="$run_dir/pi-${call_id}.jsonl"
      [ -f "$transcript" ] || continue
      # Extract usage from the last assistant message_end in the transcript.
      tok="$(jq -s -c '[.[] | select(.type == "message_end") | select(.message.role == "assistant") | (.message.usage // {})] | last | {input:(.input//0),output:(.output//0),cache_read:(.cacheRead//0),cache_write:(.cacheWrite//0),total:(.totalTokens//0)}' "$transcript" 2>/dev/null)" || tok="null"
      # Normalise: ensure tok is a valid JSON value.
      tok="$(printf '%s' "$tok" | jq -c . 2>/dev/null)" || tok="null"
      jq -cn --arg id "$call_id" --argjson tok "$tok" '{id:$id, tokens:$tok}' \
        >> "$tokens_map" 2>/dev/null || true
    done < "$run_dir/pi-calls.jsonl"
  } 2>/dev/null

  # Build the pi array in one jq call.
  # --rawfile + split("\n") + fromjson is robust across jq versions (the
  # --slurpfile semantics for JSONL differ between jq versions).
  pi_calls_json="$(jq -cn \
    --rawfile calls "$run_dir/pi-calls.jsonl" \
    --rawfile tmap "$tokens_map" \
    '($calls | split("\n") | map(select(length > 0) | fromjson)) as $calls_arr
     | ($tmap  | split("\n") | map(select(length > 0) | fromjson)) as $tmap_arr
     | [$calls_arr[]
       | . as $c
       | ([ $tmap_arr[] | select(.id == $c.call_id) ] | if length > 0 then .[0].tokens else null end)
       | . as $tok
       | ($c + {tokens: $tok})
      ]' 2>/dev/null)" || pi_calls_json="[]"
  rm -f "$tokens_map"
fi

# Wall clock: from setup_at to graded_at (both ISO-8601 UTC).
wall_clock_ms="null"
if [ -f "$setup_json" ] && [ -f "$grade_json" ]; then
  setup_at="$(jq -r '.setup_at // empty' "$setup_json")"
  graded_at="$(jq -r '.graded_at // empty' "$grade_json")"
  if [ -n "$setup_at" ] && [ -n "$graded_at" ]; then
    # Convert ISO-8601 to epoch seconds and compute the difference.
    # date -j -f is BSD (macOS); date -d is GNU (Linux).
    setup_epoch=""
    graded_epoch=""
    if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$setup_at" >/dev/null 2>&1; then
      setup_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$setup_at" +%s)"
      graded_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$graded_at" +%s)"
    elif date -d "$setup_at" +%s >/dev/null 2>&1; then
      setup_epoch="$(date -d "$setup_at" +%s)"
      graded_epoch="$(date -d "$graded_at" +%s)"
    fi
    if [ -n "$setup_epoch" ] && [ -n "$graded_epoch" ]; then
      wall_clock_ms=$(( (graded_epoch - setup_epoch) * 1000 ))
    fi
  fi
fi

# Build the final JSON line.
final_json="$(jq -cn \
  --arg task "$task_id" \
  --arg arm "$arm" \
  --argjson run "$run_num" \
  --arg model_str "$model" \
  --arg permission_mode "$perm_mode" \
  --arg pi_delegate_commit "$pi_delegate_sha" \
  --arg target_commit "$target_commit" \
  --argjson claude "$claude_metrics" \
  --argjson pi "$pi_calls_json" \
  --argjson grade "$grade_obj" \
  --argjson wall_clock_ms "$wall_clock_ms" \
  '{
    task: $task,
    arm: $arm,
    run: $run,
    model: (if $model_str == "null" then null else $model_str end),
    permission_mode: (if $permission_mode == "null" then null else $permission_mode end),
    pi_delegate_commit: (if $pi_delegate_commit == "null" then null else $pi_delegate_commit end),
    target_commit: (if $target_commit == "null" then null else $target_commit end),
    claude: $claude,
    pi: $pi,
    grade: $grade,
    wall_clock_ms: $wall_clock_ms
  }')"

# --- Validation ----------------------------------------------------------------
validate_err=""

# Required fields must be present (model and target_commit are nullable —
# they may be missing when run-meta.json / setup.json were not written).
for field in task arm run grade; do
  val="$(printf '%s' "$final_json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null || true)"
  if [ -z "$val" ]; then
    validate_err="missing required field: $field"
    break
  fi
done

if [ -z "$validate_err" ]; then
  # grade.pass must be a boolean (or null if grade is null).
  grade_pass_type="$(printf '%s' "$final_json" | jq -r '(.grade // null) | if . == null then "null" elif (.pass | type) == "boolean" then "ok" else "bad" end' 2>/dev/null || echo "bad")"
  if [ "$grade_pass_type" = "bad" ]; then
    validate_err="grade.pass is not a boolean"
  fi
fi

# claude.duration_ms must be numeric or null.
if [ -z "$validate_err" ]; then
  dur_type="$(printf '%s' "$final_json" | jq -r '.claude.duration_ms | if . == null then "null" elif (type == "number") then "num" else "bad" end' 2>/dev/null || echo "bad")"
  if [ "$dur_type" = "bad" ]; then
    validate_err="claude.duration_ms is not numeric or null"
  fi
fi

# claude.cost_usd must be numeric or null.
if [ -z "$validate_err" ]; then
  cost_type="$(printf '%s' "$final_json" | jq -r '.claude.cost_usd | if . == null then "null" elif (type == "number") then "num" else "bad" end' 2>/dev/null || echo "bad")"
  if [ "$cost_type" = "bad" ]; then
    validate_err="claude.cost_usd is not numeric or null"
  fi
fi

if [ -n "$validate_err" ]; then
  echo "collect: VALIDATION FAILED: $validate_err" >&2
  echo "  raw: $final_json" >&2
  exit 2
fi

# Write the validated line.
if [ -n "$out_file" ]; then
  printf '%s\n' "$final_json" >> "$out_file"
else
  printf '%s\n' "$final_json"
fi
