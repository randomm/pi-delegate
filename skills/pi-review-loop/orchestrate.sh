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
# Environment:
#   PI_CONTEXT_FILES   When set to a non-empty value (e.g. 1), pi context
#                      files (AGENTS.md/CLAUDE.md) are loaded for every pi
#                      call. Unset/empty by default: every pi call passes
#                      --no-context-files so the target repo's agent
#                      instructions do not override the role prompts.
#   PI_DIFF_MAX_BYTES  Max bytes of diff embedded in a review prompt.
#                      Default 100000 (Linux caps a single argv element
#                      at ~128KB, MAX_ARG_STRLEN; keep the prompt arg
#                      well under that).
#   PI_TIMEOUT         Seconds to allow each pi invocation. Default 1800.
#                      Requires `timeout` (coreutils) or `gtimeout`
#                      (macOS brew coreutils) on PATH; if neither exists,
#                      pi runs unbounded and a warning is logged once.
#
# Output: all progress on stderr; exactly one JSON summary on the LAST
# line of stdout (built with jq, never string interpolation).
#
# Exit codes:
#   0  PASS | PASSED_WITH_FINDINGS | EMPTY_DIFF
#   1  REJECTED (budget exhausted, no terminal verdict reached)
#   2  INCOMPLETE (no parseable verdict from pi)
#   3  PI_ERROR   (pi missing, pi crashed, a `git diff HEAD` call failed
#       with git's stderr surfaced verbatim, or pi timed out after
#       PI_TIMEOUT seconds)
#   2  is also used for CLI usage errors (unknown flag, missing task,
#       invalid --max-rounds, invalid PI_TIMEOUT) — the spec defines exit
#       codes 0-3 only, and a distinct usage code would require a new code;
#       documented here.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="$script_dir"
readonly DEVELOPER_MD="${SCRIPT_DIR}/developer.md"
readonly REVIEWER_MD="${SCRIPT_DIR}/adversarial-reviewer.md"
readonly DEFAULT_MAX_ROUNDS=3
readonly HARD_MAX_ROUNDS=3
readonly MAX_FIXES=2
# MAX_TOTAL_CALLS is implied by the round cap + fix cap (develop 1 +
# review 3 + fix 2 = 6); it is kept to mirror the spec's "total ≤ 6
# pi invocations" wording and as a second, independent guard.
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

# die_env <hint|-> — fatal environment error (exit 3). When $1 is not "-",
# an install hint for pi/jq is appended (for missing-binary errors only).
die_env() {
  local hint="${1:--}"
  log "ERROR: $2"
  if [ "$hint" != "-" ]; then
    log "hint: install pi (bun install -g @earendil-works/pi-coding-agent) and jq (brew install jq)"
  fi
  exit 3
}

command -v git >/dev/null 2>&1 || die_env "-" "git is not installed or not on PATH"
git rev-parse --git-dir >/dev/null 2>&1 || die_env "-" "not inside a git repository"
command -v jq >/dev/null 2>&1 || die_env hint "jq is not installed or not on PATH"

for f in "$DEVELOPER_MD" "$REVIEWER_MD"; do
  [ -f "$f" ] || die_env "-" "missing role prompt: $f"
done

# Load the role prompts once at startup (not via `cat` inside run_pi).
developer_md_content="$(cat "$DEVELOPER_MD")"
reviewer_md_content="$(cat "$REVIEWER_MD")"

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

PI_BIN="$(find_pi)" || die_env hint "pi executable not found (PATH, ~/.bun/bin, ~/.local/bin)"

# pi timeout: `timeout` (coreutils) or `gtimeout` (macOS); unbounded if
# neither exists (a warning is logged once).
PI_TIMEOUT="${PI_TIMEOUT:-1800}"
if ! [[ "$PI_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$PI_TIMEOUT" -lt 1 ]; then
  die_usage "PI_TIMEOUT must be a positive integer (got: $PI_TIMEOUT)"
fi
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi
no_timeout_warned=0

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
  local stderr_text="$1"
  [ -n "$stderr_text" ] || stderr_text="pi failed (no output)"
  printf '%s\n' "$stderr_text" >&2
  emit_json "PI_ERROR" "$verdict" "$round" "$total_pi_calls" "$findings_json" "$last_transcript"
  exit 3
}

# --- Diff snapshot --------------------------------------------------------
# get_diff <label> — snapshot `git diff HEAD`. Returns 0 on a non-empty
# diff (echoed on stdout), 1 on an empty diff, and 2 on a git failure.
# Git's stderr is redirected straight into $GIT_ERR_FILE (a writable path
# created once at startup; the function runs in a subshell when its stdout
# is captured, so a variable could not be used) and truncated first so a
# stale failure message from an earlier round is never re-surfaced.
get_diff() {
  local label="$1"
  local diff rc
  : >"${GIT_ERR_FILE:?GIT_ERR_FILE not set}"
  diff="$(git diff HEAD 2>"$GIT_ERR_FILE")" || rc=$?
  if [ "${rc:-0}" -ne 0 ]; then
    log "ERROR: git diff HEAD failed during ${label}"
    return 2
  fi
  [ -n "$diff" ] || return 1
  printf '%s' "$diff"
}

# die_git_error — surface a get_diff failure (rc 2) as PI_ERROR, reading
# git's stderr from $GIT_ERR_FILE. Called from a plain statement (never
# in an `if` condition), so its exit 3 is honored.
die_git_error() {
  local err=""
  [ -s "${GIT_ERR_FILE:?}" ] && err="$(cat "$GIT_ERR_FILE")"
  [ -n "$err" ] || err="git failed (no output)"
  printf '%s\n' "$err" >&2
  emit_json "PI_ERROR" "$verdict" "$round" "$total_pi_calls" "$findings_json" "$last_transcript"
  exit 3
}

# Truncate the review diff (or any embedded text such as the reviewer
# transcript in a fix prompt) to PI_DIFF_MAX_BYTES (default 100000),
# keeping whole lines and appending a truncation notice if dropped.
# Rationale: the diff is embedded in a single argv element passed to pi,
# and Linux caps one argument at ~128KB (MAX_ARG_STRLEN). Byte lengths
# are measured with `wc -c` (locale-independent) so the notice always
# shows byte counts even in a UTF-8 locale.
trim_diff() {
  local raw="$1" limit="${PI_DIFF_MAX_BYTES:-100000}"
  local total shown
  total="$(printf '%s' "$raw" | wc -c | tr -d ' ' )"
  if [ "$total" -le "$limit" ]; then
    printf '%s' "$raw"
    return 0
  fi
  shown="$(printf '%s' "$raw" | head -c "$limit")"
  # If the cut landed mid-line, drop the trailing partial line so the
  # prompt never contains a broken diff line. Pure parameter expansion so
  # the behaviour is identical on GNU and BSD (macOS `head -n -1` fails).
  if [[ "$shown" == *$'\n'* ]]; then
    shown="${shown%$'\n'*}"
  else
    shown=""
  fi
  printf '%s\n[truncated: %s of %s bytes shown (PI_DIFF_MAX_BYTES=%s)]' "$shown" "$(printf '%s' "$shown" | wc -c | tr -d ' ')" "$total" "$limit"
}

# --- pi invocation --------------------------------------------------------
# run_pi <prompt> <system-prompt-content|-> [tools]
# Runs pi headless in JSON mode; stores the extracted final text in
# $last_transcript. Returns 1 (and sets $pi_stderr) on non-zero exit.
run_pi() {
  local prompt="$1" system_prompt="$2" tools="${3:--}"
  local args=(--mode json -p --no-session --no-extensions --no-skills --no-prompt-templates)
  [ -z "${PI_CONTEXT_FILES:-}" ] && args+=(--no-context-files)
  [ "$system_prompt" != "-" ] && args+=(--append-system-prompt "$system_prompt")
  [ "$tools" != "-" ] && args+=(--tools "$tools")
  [ -n "$model_arg" ] && args+=(--model "$model_arg")
  args+=("$prompt")

  local rc=0
  local output
  if [ -n "$TIMEOUT_CMD" ]; then
    output="$("$TIMEOUT_CMD" "$PI_TIMEOUT" "$PI_BIN" "${args[@]}" </dev/null 2>&1)" || rc=$?
  else
    if [ "$no_timeout_warned" -eq 0 ]; then
      no_timeout_warned=1
      log "WARNING: neither timeout nor gtimeout found on PATH; pi calls run without a time limit"
    fi
    output="$("$PI_BIN" "${args[@]}" </dev/null 2>&1)" || rc=$?
  fi
  total_pi_calls=$((total_pi_calls + 1))

  if [ "$rc" -eq 124 ]; then
    pi_stderr="pi timed out after ${PI_TIMEOUT}s"
    return 1
  fi

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
  f="$(printf '%s\n' "$text" | jq -Rrs '[split("\n") | .[:-1] | .[] | select(test("^[[:space:]]*[-*][[:space:]]") or test("^[[:space:]]*[0-9]+[.)][[:space:]]")) | sub("^[[:space:]]*[-*][[:space:]]*"; "") | sub("^[[:space:]]*[0-9]+[.)][[:space:]]*"; "") | select(length > 0)]' 2>/dev/null)" || f='[]'
  if ! printf '%s' "$f" | jq -e 'type == "array"' >/dev/null 2>&1; then
    f='[]'
  fi
  findings_json="$f"
}

# dispatch_fix <label>
# Shared body for the ISSUES_FOUND and CRITICAL_ISSUES_FOUND fix arms:
# check the fix budget, then run one developer round against the
# findings from the latest review. On success, threads the round summary
# forward and returns 0; when the budget is exhausted, returns 1 (the
# caller sets the terminal status).
dispatch_fix() {
  local label="$1"
  if [ "$fix_calls" -ge "$MAX_FIXES" ] || [ "$total_pi_calls" -ge "$MAX_TOTAL_CALLS" ]; then
    log "Fix budget exhausted (${fix_calls}/${MAX_FIXES}) without a terminal verdict."
    return 1
  fi
  fix_calls=$((fix_calls + 1))
  log "${label} — dispatching fix (${fix_calls}/${MAX_FIXES})"
  log "=== Round ${round}/${max_rounds}: fix ==="
  # Cap the reviewer transcript threaded into the fix prompt so the total
  # prompt stays well under MAX_ARG_STRLEN (~128KB), like the review diff.
  local transcript_to_embed
  transcript_to_embed="$(trim_diff "$last_transcript")"
  local fix_prompt="Fix the following reviewer findings in the working tree. Address each finding; do not change anything else."
  [ -n "$last_review_summary" ] && fix_prompt="${fix_prompt}"$'\n\n'"Context from an earlier review round:"$'\n'"${last_review_summary}"
  fix_prompt="${fix_prompt}"$'\n\n'"Current findings from the latest review:"$'\n'"${transcript_to_embed}"
  fix_prompt="${fix_prompt}"$'\n\n'"Task:"$'\n'"${task}"
  pi_stderr=""
  if ! run_pi "$fix_prompt" "$developer_md_content" "-"; then
    fail_pi_error "$pi_stderr"
  fi
  last_review_summary="$(summarize_round "$last_transcript")"
  return 0
}

# --- Entry: diff must be non-empty ----------------------------------------

# git stderr lands in GIT_ERR_FILE only on failure paths that exit
# immediately (die_git_error / fail_pi_error / INCOMPLETE), so a single
# EXIT trap covers every exit route without double-cleanup races.
GIT_ERR_FILE="$(mktemp)"
trap 'rm -f "$GIT_ERR_FILE"' EXIT
entry_diff=""
diff_rc=0
entry_diff="$(get_diff "entry")" || diff_rc=$?
if [ "$diff_rc" -eq 2 ]; then
  die_git_error
fi
if [ "$diff_rc" -ne 0 ] || [ -z "$entry_diff" ]; then
  emit_json "EMPTY_DIFF" "" 0 0 '[]' ""
  exit 0
fi

# --- Develop (exactly once) -------------------------------------------------

log "=== Develop round (task: ${task}) ==="
pi_stderr=""
if ! run_pi "$task" "$developer_md_content" "-"; then
  fail_pi_error "$pi_stderr"
fi

# --- Review / fix loop ------------------------------------------------------

while [ "$round" -lt "$max_rounds" ]; do
  round=$((round + 1))
  log "=== Round ${round}/${max_rounds}: reviewing ==="

  # Fresh diff snapshot before every review round (git errors here are
  # PI_ERROR; a genuinely empty diff ends the loop with EMPTY_DIFF).
  current_diff=""
  diff_rc=0
  current_diff="$(get_diff "review round ${round}")" || diff_rc=$?
  if [ "$diff_rc" -eq 2 ]; then
    die_git_error
  fi
  if [ "$diff_rc" -ne 0 ] || [ -z "$current_diff" ]; then
    log "Working-tree diff is empty after round ${round} — nothing left to review."
    status="EMPTY_DIFF"
    emit_json "EMPTY_DIFF" "$verdict" "$round" "$total_pi_calls" "$findings_json" "$last_transcript"
    exit 0
  fi

  review_prompt="Adversarially review the current working-tree diff against the task below."
  [ -n "$last_review_summary" ] && review_prompt="${review_prompt}"$'\n\n'"Context from the previous review round:"$'\n'"${last_review_summary}"
  review_prompt="${review_prompt}"$'\n\n'"Task:"$'\n'"${task}"
  review_prompt="${review_prompt}"$'\n\n'"Current diff (git diff HEAD):"$'\n'"$(trim_diff "$current_diff")"

  pi_stderr=""
  if ! run_pi "$review_prompt" "$reviewer_md_content" "read,grep,find,ls"; then
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
      # Spec: APPROVED/MINOR_OBSERVATIONS -> PASS. Findings are still
      # carried in the JSON summary.
      extract_findings "$last_transcript"
      status="PASS"; break ;;
    ISSUES_FOUND)
      extract_findings "$last_transcript"
      if [ "$round" -eq "$max_rounds" ]; then
        # ISSUES_FOUND at the terminal round: passed with findings.
        log "ISSUES_FOUND at terminal round — PASSED_WITH_FINDINGS."
        status="PASSED_WITH_FINDINGS"
      elif ! dispatch_fix "Findings"; then
        status="REJECTED"
      fi
      [ -n "$status" ] && break
      ;;
    CRITICAL_ISSUES_FOUND)
      extract_findings "$last_transcript"
      if [ "$round" -eq "$max_rounds" ]; then
        log "CRITICAL_ISSUES_FOUND at terminal round — REJECTED."
        status="REJECTED"
      elif ! dispatch_fix "Critical findings"; then
        status="REJECTED"
      fi
      [ -n "$status" ] && break
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

# Final exit mapping. INCOMPLETE exits 2 immediately after emitting its JSON
# summary (above), so it never reaches this case; the *) arm guards against
# an unhandled status leaking into the wrong exit code.
case "$status" in
  PASS|PASSED_WITH_FINDINGS|EMPTY_DIFF) exit 0 ;;
  REJECTED) exit 1 ;;
  INCOMPLETE) exit 2 ;;
  *)
    log "internal error: unknown status '${status:-<unset>}'"
    exit 3
    ;;
esac
