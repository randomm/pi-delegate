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
#       cost_usd, duration_ms, duration_api_ms (API time only — the
#       session wall clock is duration_ms and is NOT the same quantity;
#       duration_api_ms can exceed duration_ms, so treat them as
#       independent), permission_denials (array),
#       model_usage: {<model>: {input_tokens, output_tokens, cache_read,
#                              cache_creation, cost_usd}}
#     },
#     pi: [
#       {call_id, mode, exit, duration_ms, argv,
#        tokens: {input, output, cache_read, cache_write, total, per_model}
#                 | null}
#     ],
#     pi_call_count (number of pi calls, 0 if pi-calls.jsonl is absent),
#     delegation_exercised (arm B: boolean — arm B with pi_call_count > 0;
#       arm A: null, since pi calls in arm A are accidental and are not a
#       delegation signal),
#     pi_tokens_total (per-model totals summed over all pi calls, or null
#       when no json-mode call recorded usage — arm A has the same shape,
#       keyed by model, since it too runs the pi shim),
#     grade: {pass, test_cmd, error},
#     wall_clock_ms (run wall clock: claude started → ended. Prefer the
#       ms-resolution started_ms/ended_ms from run-meta.json when present;
#       otherwise fall back to the second-resolution started_at/ended_at;
#       otherwise the setup_at→graded_at range. null when nothing is known.)
#
# Exit codes:
#   0  success (one JSON line written)
#   1  run directory missing or claude/output.json missing
#   2  claude/output.json is not valid JSON (malformed run), or the
#       pi-calls.jsonl contains a duplicate/malformed line
#
# Validation: the output line is validated with jq before being written.
# Required fields: task, arm, run, model, target_commit, grade.pass.
# Numeric fields: claude.duration_ms, claude.duration_api_ms (nullable),
#   claude.cost_usd (nullable), agent_ms (nullable), pi_call_count (number),
#   pi_tokens_total (nullable object with numeric leaves),
#   pi[].duration_ms, pi[].tokens.* (nullable).
# A malformed run (missing required fields, non-numeric where numeric
# expected) causes a non-zero exit so the caller can flag it.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

bench_out_guard || exit 1

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
agent_ms="null"; started_ms="null"; ended_ms="null"
if [ -f "$meta_json" ]; then
  model="$(jq -r '.model // "null"' "$meta_json")" || { echo "collect: failed to read run-meta.json model" >&2; exit 2; }
  perm_mode="$(jq -r '.perm_mode // "null"' "$meta_json")" || { echo "collect: failed to read run-meta.json perm_mode" >&2; exit 2; }
  pi_delegate_sha="$(jq -r '.pi_delegate_sha // ""' "$meta_json")" || { echo "collect: failed to read run-meta.json pi_delegate_sha" >&2; exit 2; }
  [ -z "$pi_delegate_sha" ] && pi_delegate_sha="null"
  # started_ms/ended_ms: present + non-null but not a plain non-negative
  # integer is a malformed run (exit 2) — not silently degraded. Absent or
  # JSON null falls back to the second-resolution fields below (older runs).
  started_ms="$(jq -c '.started_ms // null' "$meta_json")" || { echo "collect: failed to read run-meta.json started_ms" >&2; exit 2; }
  ended_ms="$(jq -c '.ended_ms // null' "$meta_json")" || { echo "collect: failed to read run-meta.json ended_ms" >&2; exit 2; }
  for _ms_field in started_ms ended_ms; do
    if [ "$_ms_field" = "started_ms" ]; then _ms_val="$started_ms"; else _ms_val="$ended_ms"; fi
    if [ -n "$_ms_val" ] && [ "$_ms_val" != "null" ]; then
      case "$_ms_val" in
        0|[1-9][0-9]*) ;;
        *) echo "collect: run-meta.json $_ms_field is not a non-negative integer: $_ms_val" >&2; exit 2 ;;
      esac
    fi
  done
  # agent_ms must be a number or null; a non-numeric value is a malformed
  # run (same treatment as duration_api_ms below → exit 2 validation error).
  # A string-valued agent_ms is malformed (exit 2 via validation below); a
  # missing or JSON-null agent_ms degrades to null. Number/null are kept as
  # their JSON form ("null" for a missing/null field).
  # A jq FAILURE (unreadable/corrupt run-meta.json) is a loud exit 2 — the
  # run-meta.json was already read successfully for the fields above, so a
  # failure here is an I/O or parse error we must not silently swallow.
  agent_ms="$(jq -c 'if (has("agent_ms") and (.agent_ms | type) == "number") then .agent_ms
                     elif (has("agent_ms") and (.agent_ms | type) == "string") then .agent_ms
                     else null end' "$meta_json")" \
    || { echo "collect: failed to read run-meta.json agent_ms" >&2; exit 2; }
  [ -n "$agent_ms" ] || agent_ms="null"
fi

# Load grade.json — optional but expected after grading.
# If it is missing, the run was never graded (crashed, or grade.sh was not
# run). We synthesise a failed grade so the collect line is marked failed
# with a diagnostic error rather than emitting grade:null — a null grade
# previously passed the "grade.pass is a boolean" validation (null has no
# .pass), so a crashed run would look un-graded but not failed. (review item 6)
grade_json="$run_dir/grade.json"
grade_obj='null'
if [ -f "$grade_json" ]; then
  grade_obj="$(jq -c '{pass, test_cmd, error}' "$grade_json" 2>/dev/null || echo 'null')"
  if [ "$grade_obj" = "null" ]; then
    # grade.json exists but is unreadable/malformed — treat as failed.
    grade_obj='{"pass":false,"test_cmd":null,"error":"grade.json exists but is unreadable"}'
  fi
else
  grade_obj='{"pass":false,"test_cmd":null,"error":"not graded: grade.json missing (run crashed or grade.sh was not run)"}'
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
    duration_api_ms: (.duration_api_ms // null),
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

# Claude's resolved model(s) from modelUsage (claude may fall back to a
# different model than the --model id; model_usage keys are the resolved
# ids; the first entry is the primary).
claude_models_json="$(jq -c '[(.modelUsage // {}) | keys[]]' "$claude_json")"

# Parse pi calls.
# pi-calls.jsonl: one JSON object per pi invocation (argv, duration_ms,
# exit, mode, call_id).
# pi-<N>.jsonl: per-call transcript for --mode json invocations.
# For each call, if mode is "json" and a corresponding pi-<call_id>.jsonl
# exists, extract usage from the transcript. Tokens are SUMMED over every
# assistant message_end in the call (a review-loop pi call has multiple
# turns; taking only the last message_end under-counted by an order of
# magnitude — review item 3). Per-model breakdowns are included so the
# per-model token requirement holds for pi too. For "text" mode calls,
# tokens is null (documented gap).


# Build the pi array. If no pi-calls.jsonl, the array is empty.
pi_calls_json="[]"
if [ -f "$run_dir/pi-calls.jsonl" ] || [ -d "$run_dir/pi-calls.d" ]; then
  # One file per call: $RUN_DIR/pi-calls.d/<call_id>.json. Fall back to
  # the legacy pi-calls.jsonl if the directory is absent. Each file is one
  # JSON object; exit may be null (SIGKILLed call that never completed).
  calls_dir="$run_dir/pi-calls.d"
  deduped_calls="$run_dir/.pi-calls-deduped.jsonl"
  # Temp files (deduped calls, tokens map) are removed on every exit path
  # via trap EXIT — never left in the run dir.
  _cleanup_tmp() {
    if [ -n "${_tmp_deduped:-}" ]; then rm -f "$_tmp_deduped" 2>/dev/null; fi
    if [ -n "${_tmp_tmap:-}" ]; then rm -f "$_tmp_tmap" 2>/dev/null; fi
    return 0
  }
  trap _cleanup_tmp EXIT
  _tmp_deduped=""; _tmp_tmap=""
  if [ -d "$calls_dir" ]; then
    # Build the deduped JSONL from the per-call files (sorted by filename
    # for deterministic order). Each file is one JSON object.
    _tmp_deduped="$deduped_calls"
    : > "$deduped_calls"
    for f in "$calls_dir"/*.json; do
      [ -e "$f" ] || continue
      cat "$f" >> "$deduped_calls"
    done
  else
    # Legacy: read pi-calls.jsonl directly.
    deduped_calls="$run_dir/pi-calls.jsonl"
  fi
  # Validate: each line must have call_id (string), mode (string), and
  # exit (number or null).
  if ! jq -e -s 'all(.[]; (.call_id | type) == "string" and (.mode | type) == "string" and ((.exit | type) == "number" or (.exit | type) == "null"))' "$deduped_calls" >/dev/null 2>&1; then
    echo "collect: pi-calls contains a malformed line (bad call_id/mode/exit); refusing" >&2
    exit 2
  fi
  # Process each line of the deduped pi calls. Accumulate a jq array by parsing
  # the whole file at once (one JSON array input) instead of concatenating
  # per-line strings (which breaks when a call spans multiple lines after
  # jq pretty-prints, or when the shell mangles embedded newlines).
  #
  # We use a two-step approach:
  #   1. For each call_id with mode=json, extract tokens from the transcript.
  #   2. Build the pi array in one jq call over the deduped calls,
  #      looking up tokens from a temp map file.
  # Build the tokens map as a JSONL file (one {id, tokens} object per line).
  tokens_map="$run_dir/.pi-tokens-map.jsonl"
  _tmp_tmap="$tokens_map"
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
      # Extract usage from EVERY assistant message_end in the transcript and
      # sum, rather than taking only the last one. A review-loop pi call has
      # multiple assistant turns (develop, review, fix); summing gives the
      # true per-call token cost (review item 3). Per-model totals are
      # included so the per-model token requirement holds for pi too.
      tok="$(jq -s -c '
        [.[] | select(.type == "message_end") | select(.message.role == "assistant")] as $msgs
        | ([$msgs[].message.usage // {}]) as $usages
        | ([$msgs[].message.model // "unknown"]) as $models
        | (reduce range(0; $usages | length) as $i ({};
            .[$models[$i]] = (
              .[$models[$i]] // {input:0,output:0,cache_read:0,cache_write:0,total:0}
              | .input += ($usages[$i].input // 0)
              | .output += ($usages[$i].output // 0)
              | .cache_read += ($usages[$i].cacheRead // 0)
              | .cache_write += ($usages[$i].cacheWrite // 0)
              | .total += ($usages[$i].totalTokens // 0)
            ))
          ) as $per_model
        | {
            input:      ([ $usages[].input // 0 ] | add // 0),
            output:     ([ $usages[].output // 0 ] | add // 0),
            cache_read: ([ $usages[].cacheRead // 0 ] | add // 0),
            cache_write:([ $usages[].cacheWrite // 0 ] | add // 0),
            total:      ([ $usages[].totalTokens // 0 ] | add // 0),
            per_model:  $per_model
          }' "$transcript" 2>/dev/null)" || tok="null"
      # Normalise: ensure tok is a valid JSON value.
      tok="$(printf '%s' "$tok" | jq -c . 2>/dev/null)" || tok="null"
      jq -cn --arg id "$call_id" --argjson tok "$tok" '{id:$id, tokens:$tok}' \
        >> "$tokens_map" 2>/dev/null || true
    done < "$deduped_calls"
  } 2>/dev/null

  # Build the pi array in one jq call.
  # --rawfile + split("\n") + fromjson is robust across jq versions (the
  # --slurpfile semantics for JSONL differ between jq versions).
  # The pi array is a core field: a jq failure building it is a malformed
  # run (exit 2), not a silent empty list.
  pi_calls_json="$(jq -cn \
    --rawfile calls "$deduped_calls" \
    --rawfile tmap "$tokens_map" \
    '($calls | split("\n") | map(select(length > 0) | fromjson)) as $calls_arr
     | ($tmap  | split("\n") | map(select(length > 0) | fromjson)) as $tmap_arr
     | ([$calls_arr[]
       | . as $c
       | ([ $tmap_arr[] | select(.id == $c.call_id) ] | if length > 0 then .[0].tokens else null end)
       | . as $tok
       | ($c + {tokens: $tok})
      ]) as $arr
     | $arr')" || { echo "collect: failed to build pi call array from pi-calls.jsonl" >&2; exit 2; }
  # Temp files (.pi-calls-deduped.jsonl, .pi-tokens-map.jsonl) are cleaned
  # by trap EXIT on every exit path — never left in the run dir.
fi

# pi_call_count: number of pi calls (0 when pi-calls.jsonl is absent).
# delegation_exercised: arm B with ≥1 pi call; arm A is null (not
# applicable — arm A's pi calls are accidental, not a delegation signal).
# docs/benchmark.md §"How to read results" defines it: arm B true iff
# pi_call_count > 0, arm A null; a zero-pi arm-B run is a skill failure.

pi_call_count="$(jq -c 'length' <<< "$pi_calls_json")" || pi_call_count="0"
if [ "$arm" = "B" ]; then
  delegation_exercised="$(jq -cn --argjson n "$pi_call_count" '($n > 0)')" || delegation_exercised="false"
else
  delegation_exercised="null"
fi

# pi_tokens_total: per-model totals summed over every pi call (json-mode
# calls only — text-mode calls have null tokens). Aggregates on the per_model
# field so the per-model breakdown is preserved; if no call had a transcript
# (no per_model data) the total is null. (docs: §metrics — the pi side is
# costed by tokens per model, not by cost_usd, which is 0.0 locally.)
# The per-model aggregation uses a single jq program to keep the syntax
# simple and portable across jq versions.
pi_tokens_total="$(jq -c '
  [ .[] | select(.tokens != null and (.tokens.per_model != null)) | .tokens.per_model ] as $per_model_arr
  | reduce $per_model_arr[] as $m ({};
      reduce ($m | keys[]) as $k (.;
        .[$k] = ((.[$k] // {input:0,output:0,cache_read:0,cache_write:0,total:0})
          | .input += $m[$k].input
          | .output += $m[$k].output
          | .cache_read += $m[$k].cache_read
          | .cache_write += $m[$k].cache_write
          | .total += $m[$k].total))
    )
  | if (. | length) == 0 then null else . end
' <<< "$pi_calls_json")" || { echo "collect: failed to compute pi_tokens_total" >&2; exit 2; }

# Wall clock: the run's own duration, from run-meta.json started_at to
# ended_at (both ISO-8601 UTC, recorded by run-arm.sh around the claude
# invocation). This is the run's wall time, excluding setup (review item 9:
# the old code used setup_at → graded_at, which included setup and graded
# after the fact, and started_at was written after claude exited — effectively
# "ended_at"). Falls back to setup_at → graded_at if run-meta.json lacks
# the new fields (e.g. a run produced by an older harness).
# Wall clock (run start → run end). The old code used second-resolution
# started_at/ended_at from run-meta.json (date -u +%Y-%m-%dT%H:%M:%SZ), which
# read wall_clock_ms to 0 for any run under a second (issue #71: dry-run 4
# recorded agent_ms=36490 but wall_clock_ms=0). run-arm.sh now writes the
# ms-resolution started_ms/ended_ms alongside the second-resolution
# ISO-8601 fields; collect.sh prefers the ms-resolution pair, falling back to
# the second-resolution pair (and then to setup_at→graded_at) for older runs.
wall_clock_ms="null"
# $started_ms and $ended_ms are either the literal string "null" (field
# absent or older run) or a positive integer in ms. The jq -c output for a
# JSON null is the literal string "null", not empty, so we compare against
# that explicitly.
# Both must be plain non-negative integers for the ms subtraction to be
# safe; a malformed value (e.g. "abc") falls through to the
# seconds-resolution fallback below instead of aborting the collection.
if [[ "$started_ms" =~ ^[0-9]+$ ]] && [[ "$ended_ms" =~ ^[0-9]+$ ]]; then
  wall_clock_ms=$(( ended_ms - started_ms ))
fi
start_epoch=""
end_epoch=""
if [ "$wall_clock_ms" = "null" ] && [ -f "$meta_json" ]; then
  start_at="$(jq -r '.started_at // empty' "$meta_json")"
  end_at="$(jq -r '.ended_at // empty' "$meta_json")"
  if [ -n "$start_at" ] && [ -n "$end_at" ]; then
    if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_at" >/dev/null 2>&1; then
      start_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_at" +%s)"
      end_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end_at" +%s)"
    elif date -d "$start_at" +%s >/dev/null 2>&1; then
      start_epoch="$(date -d "$start_at" +%s)"
      end_epoch="$(date -d "$end_at" +%s)"
    fi
  fi
fi
if [ "$wall_clock_ms" = "null" ] && [ -z "${start_epoch:-}" ] && [ -f "$setup_json" ] && [ -f "$grade_json" ]; then
  setup_at="$(jq -r '.setup_at // empty' "$setup_json")"
  graded_at="$(jq -r '.graded_at // empty' "$grade_json")"
  if [ -n "$setup_at" ] && [ -n "$graded_at" ]; then
    if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$setup_at" >/dev/null 2>&1; then
      start_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$setup_at" +%s)"
      end_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$graded_at" +%s)"
    elif date -d "$setup_at" +%s >/dev/null 2>&1; then
      start_epoch="$(date -d "$setup_at" +%s)"
      end_epoch="$(date -d "$graded_at" +%s)"
    fi
  fi
fi
if [ -n "${start_epoch:-}" ] && [ -n "${end_epoch:-}" ]; then
  wall_clock_ms=$(( (end_epoch - start_epoch) * 1000 ))
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
  --argjson claude_models "$claude_models_json" \
  --argjson pi "$pi_calls_json" \
  --argjson pi_call_count "$pi_call_count" \
  --argjson delegation_exercised "$delegation_exercised" \
  --argjson pi_tokens_total "$pi_tokens_total" \
  --argjson grade "$grade_obj" \
  --argjson wall_clock_ms "$wall_clock_ms" \
  --argjson agent_ms "$agent_ms" \
  '{
    task: $task,
    arm: $arm,
    run: $run,
    model: (if $model_str == "null" then null else $model_str end),
    permission_mode: (if $permission_mode == "null" then null else $permission_mode end),
    pi_delegate_commit: (if $pi_delegate_commit == "null" then null else $pi_delegate_commit end),
    target_commit: (if $target_commit == "null" then null else $target_commit end),
    claude: ($claude + {resolved_models: $claude_models}),
    pi: $pi,
    pi_call_count: $pi_call_count,
    delegation_exercised: $delegation_exercised,
    pi_tokens_total: $pi_tokens_total,
    grade: $grade,
    agent_ms: $agent_ms,
    wall_clock_ms: $wall_clock_ms
  }')"

# --- Validation (a single jq program) -----------------------------------------
# One jq program checks the whole line and prints "ok" or a violation
# message (exit 0 either way); a non-"ok" result (or a jq failure) means
# the line must not be emitted. (docs: §metrics — null grade must never
# pass validation; numeric types for pi[].duration_ms and tokens.* when
# non-null.)
validation_out="$(printf '%s' "$final_json" | jq -r '
  def check:
    if .task == null or .arm == null or .run == null
       or ((.task | type) != "string") or ((.arm | type) != "string")
       or ((.run | type) != "number")
    then "missing required field (task/arm/run)"
    elif .grade == null
    then "grade is null (a null grade must never pass validation)"
    elif (.grade.pass | type) != "boolean"
    then "grade.pass is not a boolean"
    elif .claude.duration_ms != null and (.claude.duration_ms | type) != "number"
    then "claude.duration_ms is not numeric or null"
    elif .claude.duration_api_ms != null and (.claude.duration_api_ms | type) != "number"
    then "claude.duration_api_ms is not numeric or null"
    elif .claude.cost_usd != null and (.claude.cost_usd | type) != "number"
    then "claude.cost_usd is not numeric or null"
    elif .agent_ms != null and (.agent_ms | type) != "number"
    then "agent_ms is not numeric or null"
    elif ((.pi_call_count | type) != "number")
    then "pi_call_count is not numeric"
    elif (.delegation_exercised | type) != "boolean" and (.delegation_exercised != null)
    then "delegation_exercised is not a boolean or null"
    elif .pi_tokens_total != null and ((.pi_tokens_total | type) != "object")
    then "pi_tokens_total is not an object or null"
    elif (.pi | map(select(. != null and .duration_ms != null))
             | map(.duration_ms | type) | any(. != "number"))
    then "pi[].duration_ms is not numeric or null"
    elif (.pi | map(.tokens) | map(select(. != null))
             | any( (.input | type) != "number"
                 or (.output | type) != "number"
                 or (.cache_read | type) != "number"
                 or (.cache_write | type) != "number"
                 or (.total | type) != "number" ))
    then "pi[].tokens.* is not numeric"
    else null
    end;
  check | if . == null then "ok" else . end
' 2>/dev/null)" || validation_out=""

validate_err=""
if [ -z "$validation_out" ]; then
  validate_err="collect line failed jq validation (unparseable)"
elif [ "$validation_out" != "ok" ]; then
  validate_err="$validation_out"
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
