#!/usr/bin/env bash
# orchestrate.sh — deterministic develop → review → [fix → review] loop
# over the working-tree diff (`git diff HEAD`), delegating each round to
# the `pi` coding agent.
#
# Usage: orchestrate.sh [--model <model>] [--max-rounds <N>] <task...>
#
#   <task...>        Task description for the develop round (passed
#                    through verbatim to the developer agent).
#   --model <model>  Passthrough; forwarded as --model to every pi call.
#                    No model is pinned; without this flag pi uses its
#                    configured default.
#   --max-rounds <N> Review-round budget. Default 3, hard cap 3 (develop
#                    1 + review 3 + fix 2 = 6 total pi invocations).
#
# Output: all progress on stderr; exactly one JSON summary on the LAST
# line of stdout (built with jq, never string interpolation).
#
# Exit codes:
#   0  PASS | PASSED_WITH_FINDINGS | EMPTY_DIFF
#   1  REJECTED (budget exhausted, no terminal verdict reached)
#   2  INCOMPLETE (no parseable verdict from pi)
#   3  PI_ERROR   (pi missing, not a git repo, or pi crashed)

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="$script_dir"
readonly DEVELOPER_MD="${SCRIPT_DIR}/developer.md"
readonly REVIEWER_MD="${SCRIPT_DIR}/adversarial-reviewer.md"
readonly DEFAULT_MAX_ROUNDS=3
readonly HARD_MAX_ROUNDS=3
readonly MAX_FIXES=2
readonly MAX_TOTAL_CALLS=6

# --- CLI parsing ----------------------------------------------------------

die_usage() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

task=""
model_arg=""
max_rounds="$DEFAULT_MAX_ROUNDS"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      [ "$#" -ge 2 ] || die_usage "--model requires a value"
      model_arg="$2"; shift 2
      ;;
    --max-rounds)
      [ "$#" -ge 2 ] || die_usage "--max-rounds requires a value"
      max_rounds="$2"; shift 2
      ;;
    --) shift; break ;;
    -*) die_usage "unknown option: $1" ;;
    *)
      if [ -n "$task" ]; then task="$task $1"; else task="$1"; fi
      shift
      ;;
  esac
done

if [ -z "$task" ]; then
  die_usage "a task description (positional argument) is required"
fi
if ! [[ "$max_rounds" =~ ^[0-9]+$ ]] || [ "$max_rounds" -lt 1 ]; then
  die_usage "--max-rounds must be a positive integer (got: $max_rounds)"
fi
if [ "$max_rounds" -gt "$HARD_MAX_ROUNDS" ]; then
  die_usage "--max-rounds must be at most $HARD_MAX_ROUNDS (got: $max_rounds)"
fi

# --- Environment ----------------------------------------------------------

log() { printf '%s\n' "$*" >&2; }

die_env() {
  log "ERROR: $1"
  log "hint: install pi (bun install -g @earendil-works/pi-coding-agent) and jq (brew install jq)"
  log "hint: run orchestrate.sh from inside a git repository"
  exit 3
}

command -v git >/dev/null 2>&1 || die_env "git is not installed or not on PATH"
git rev-parse --git-dir >/dev/null 2>&1 || die_env "not inside a git repository"
command -v jq >/dev/null 2>&1 || die_env "jq is not installed or not on PATH"

for f in "$DEVELOPER_MD" "$REVIEWER_MD"; do
  [ -f "$f" ] || die_env "missing role prompt: $f"
done

# pi discovery: PATH first (`command -v pi` + executable check), then
# well-known install locations.
find_pi() {
  local candidate dir
  if command -v pi >/dev/null 2>&1; then
    candidate="$(command -v pi)"
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  fi
  for dir in "$HOME/.bun/bin" "$HOME/.local/bin"; do
    if [ -x "$dir/pi" ]; then printf '%s' "$dir/pi"; return 0; fi
  done
  return 1
}

PI_BIN="$(find_pi)" || die_env "pi executable not found (PATH, ~/.bun/bin, ~/.local/bin)"

# --- Loop state -----------------------------------------------------------

round=0
total_pi_calls=0
fix_calls=0
verdict=""
findings_json='[]'
last_transcript=""
last_review_summary=""
status=""

# --- JSON summary ---------------------------------------------------------
# emit_json <status> <verdict-or-null> <rounds> <total_pi_calls> <findings-json> <raw>
emit_json() {
  local s="$1" v="$2" r="$3" t="$4" f="$5" raw="$6"
  jq -cn \
    --arg status "$s" \
    --arg verdict "${v}" \
    --argjson rounds "$r" \
    --argjson total_pi_calls "$t" \
    --argjson findings "$f" \
    --arg raw_output "$raw" \
    '{status: $status, verdict: (if $verdict == "" then null else $verdict end), rounds: $rounds, total_pi_calls: $total_pi_calls, findings: $findings, raw_output: $raw_output}'
}

fail_pi_error() {
  # $1 = stderr text to surface verbatim
  printf '%s\n' "$1" >&2
  emit_json "PI_ERROR" "$verdict" "$round" "$total_pi_calls" "$findings_json" "$last_transcript"
  exit 3
}

# --- pi invocation --------------------------------------------------------
# run_pi <prompt> <system-prompt-file|-> [tools]
# Runs pi headless in JSON mode; stores the extracted final text in
# $last_transcript. Returns 1 (and sets $pi_stderr) on non-zero exit.
run_pi() {
  local prompt="$1" system_prompt_file="$2" tools="${3:--}"
  local args=(--mode json -p --no-session --no-extensions --no-skills --no-prompt-templates)
  [ "$system_prompt_file" != "-" ] && args+=(--append-system-prompt "$(cat "$system_prompt_file")")
  [ "$tools" != "-" ] && args+=(--tools "$tools")
  [ -n "$model_arg" ] && args+=(--model "$model_arg")
  args+=("$prompt")

  local rc=0
  local output
  output="$("$PI_BIN" "${args[@]}" 2>&1)" || rc=$?
  total_pi_calls=$((total_pi_calls + 1))

  if [ "$rc" -ne 0 ]; then
    pi_stderr="$output"
    return 1
  fi

  # Final text: the LAST assistant message_end event whose stopReason is
  # "stop" (the terminal assistant message). message_end fires for every
  # message (user, assistant, tool); agent_settled has no text field.
  local text
  text="$(printf '%s' "$output" | jq -s -r '[.[] | select(.type == "message_end") | select(.message.role == "assistant") | select(.message.stopReason == "stop")] | last | (.message.content // [] | map(select(.type == "text") | .text) | join("\n")) // empty' 2>/dev/null)" || text=""
  last_transcript="$text"
  return 0
}

# --- Verdict parsing ------------------------------------------------------
# Last occurrence, case-insensitive, tolerates optional colon and markdown
# bold around the value.
parse_verdict() {
  local text="$1"
  local found
  found="$(printf '%s\n' "$text" | grep -ioE 'VERDICT[^A-Za-z]+(APPROVED|MINOR_OBSERVATIONS|ISSUES_FOUND|CRITICAL_ISSUES_FOUND)' | grep -ioE 'APPROVED|MINOR_OBSERVATIONS|ISSUES_FOUND|CRITICAL_ISSUES_FOUND' | tail -n 1 | tr '[:lower:]' '[:upper:]')" || true
  if [ -n "$found" ]; then
    verdict="$found"
    return 0
  fi
  return 1
}

# Summarize a reviewer round: findings list plus its verdict line, kept
# short enough to thread forward to later fix rounds.
summarize_round() {
  local text="$1"
  local lines
  lines="$(printf '%s\n' "$text" | grep -E '^[[:space:]]*[-*][[:space:]]' || true)"
  local vline
  vline="$(printf '%s\n' "$text" | grep -iE 'VERDICT[[:space:]]*:' | tail -n 1 || true)"
  {
    if [ -n "$lines" ]; then printf '%s\n' "$lines"; fi
    if [ -n "$vline" ]; then printf '%s\n' "$vline"; fi
  }
}

extract_findings() {
  local text="$1"
  local f
  f="$(printf '%s\n' "$text" | jq -R '[inputs | select(test("^\\s*[-*][[:space:]]") or test("^\\s*[0-9]+[.)][[:space:]]")) | sub("^\\s*[-*0-9.]+[[:space:]]*"; "") | select(length > 0)]' 2>/dev/null)" || f='[]'
  if ! printf '%s' "$f" | jq -e 'type == "array"' >/dev/null 2>&1; then
    f='[]'
  fi
  findings_json="$f"
}

# --- Entry: diff must be non-empty ----------------------------------------

if [ -z "$(git diff HEAD 2>/dev/null)" ]; then
  emit_json "EMPTY_DIFF" "" 0 0 '[]' ""
  exit 0
fi

# --- Develop (exactly once) -------------------------------------------------

log "=== Develop round (task: ${task}) ==="
pi_stderr=""
if ! run_pi "$task" "$DEVELOPER_MD" "-"; then
  fail_pi_error "$pi_stderr"
fi

# --- Review / fix loop ------------------------------------------------------

while [ "$round" -lt "$max_rounds" ]; do
  round=$((round + 1))
  log "=== Round ${round}/${max_rounds}: reviewing ==="

  # Fresh diff snapshot before every review round.
  current_diff="$(git diff HEAD 2>/dev/null)"
  if [ -z "$current_diff" ]; then
    log "Working-tree diff is empty after round ${round} — nothing left to review."
    status="EMPTY_DIFF"
    emit_json "EMPTY_DIFF" "$verdict" "$round" "$total_pi_calls" "$findings_json" "$last_transcript"
    exit 0
  fi

  review_prompt="Adversarially review the current working-tree diff against the task below."
  [ -n "$last_review_summary" ] && review_prompt="${review_prompt}"$'\n\n'"Context from the previous review round:"$'\n'"${last_review_summary}"
  review_prompt="${review_prompt}"$'\n\n'"Task:"$'\n'"${task}"
  review_prompt="${review_prompt}\n\nCurrent diff (git diff HEAD):\n${current_diff}"

  pi_stderr=""
  if ! run_pi "$review_prompt" "$REVIEWER_MD" "read,grep,find,ls"; then
    fail_pi_error "$pi_stderr"
  fi

  if ! parse_verdict "$last_transcript"; then
    emit_json "INCOMPLETE" "" "$round" "$total_pi_calls" "$findings_json" "$last_transcript"
    exit 2
  fi
  log "Verdict: ${verdict}"

  case "$verdict" in
    APPROVED)
      status="PASS"; break ;;
    MINOR_OBSERVATIONS)
      extract_findings "$last_transcript"
      status="PASSED_WITH_FINDINGS"; break ;;
    ISSUES_FOUND)
      extract_findings "$last_transcript"
      if [ "$round" -eq "$max_rounds" ]; then
        # ISSUES_FOUND at the terminal round: passed with findings.
        log "ISSUES_FOUND at terminal round — PASSED_WITH_FINDINGS."
        status="PASSED_WITH_FINDINGS"
        break
      elif [ "$fix_calls" -lt "$MAX_FIXES" ] && [ "$total_pi_calls" -lt "$MAX_TOTAL_CALLS" ]; then
        fix_calls=$((fix_calls + 1))
        log "Findings — dispatching fix (${fix_calls}/${MAX_FIXES})"
        log "=== Round ${round}/${max_rounds}: fix ==="
        fix_prompt="Fix the following reviewer findings in the working tree. Address each finding; do not change anything else."
        [ -n "$last_review_summary" ] && fix_prompt="${fix_prompt}"$'\n\n'"Context from an earlier review round:"$'\n'"${last_review_summary}"
        fix_prompt="${fix_prompt}"$'\n\n'"Current findings from the latest review:"$'\n'"${last_transcript}"
        fix_prompt="${fix_prompt}"$'\n\n'"Task:"$'\n'"${task}"
        pi_stderr=""
        if ! run_pi "$fix_prompt" "$DEVELOPER_MD" "-"; then
          fail_pi_error "$pi_stderr"
        fi
        last_review_summary="$(summarize_round "$last_transcript")"
      else
        log "Fix budget exhausted (${fix_calls}/${MAX_FIXES}) without a terminal verdict."
        status="REJECTED"
        break
      fi
      ;;
    CRITICAL_ISSUES_FOUND)
      extract_findings "$last_transcript"
      if [ "$round" -eq "$max_rounds" ]; then
        log "CRITICAL_ISSUES_FOUND at terminal round — REJECTED."
        status="REJECTED"
        break
      elif [ "$fix_calls" -lt "$MAX_FIXES" ] && [ "$total_pi_calls" -lt "$MAX_TOTAL_CALLS" ]; then
        fix_calls=$((fix_calls + 1))
        log "Critical findings — dispatching fix (${fix_calls}/${MAX_FIXES})"
        log "=== Round ${round}/${max_rounds}: fix ==="
        fix_prompt="Fix the following critical reviewer findings in the working tree. Address each finding; do not change anything else."
        [ -n "$last_review_summary" ] && fix_prompt="${fix_prompt}"$'\n\n'"Context from an earlier review round:"$'\n'"${last_review_summary}"
        fix_prompt="${fix_prompt}"$'\n\n'"Current findings from the latest review:"$'\n'"${last_transcript}"
        fix_prompt="${fix_prompt}"$'\n\n'"Task:"$'\n'"${task}"
        pi_stderr=""
        if ! run_pi "$fix_prompt" "$DEVELOPER_MD" "-"; then
          fail_pi_error "$pi_stderr"
        fi
        last_review_summary="$(summarize_round "$last_transcript")"
      else
        log "Fix budget exhausted (${fix_calls}/${MAX_FIXES}) without a terminal verdict."
        status="REJECTED"
        break
      fi
      ;;
  esac
done

# Loop exited because the review budget ran out with no terminal verdict.
if [ "$status" = "" ]; then
  log "Review budget exhausted (${round}/${max_rounds}) without a terminal verdict."
  status="REJECTED"
fi

log "=== Done: ${status} (rounds=${round}, pi_calls=${total_pi_calls}) ==="
emit_json "$status" "$verdict" "$round" "$total_pi_calls" "$findings_json" "$last_transcript"

case "$status" in
  PASS|PASSED_WITH_FINDINGS|EMPTY_DIFF) exit 0 ;;
  REJECTED) exit 1 ;;
  *) exit 2 ;;
esac
