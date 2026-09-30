#!/usr/bin/env bash
# orchestrate.sh — deterministic develop → review → [fix → review] loop
# over the change set since a start ref recorded at entry (`git diff
# <start-ref>` plus `git diff --no-index` for untracked, non-ignored
# files), delegating each round to the `pi` coding agent.
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
#                      Default 90000 (total prompt budget is 120000 bytes
#                      to stay well under Linux MAX_ARG_STRLEN of 131072;
#                      90000 leaves ~30KB for the rest of the prompt).
#   PI_PROMPT_MAX_BYTES  Max total bytes for a single pi call (all argv
#                      args + stdin combined). Default 120000. Exceeding
#                      this causes a clear PI_ERROR instead of an opaque
#                      E2BIG from the kernel.
#   PI_TIMEOUT         Seconds to allow each pi invocation. Default 1800.
#                      Requires `timeout` (coreutils) or `gtimeout`
#                      (macOS brew coreutils) on PATH; if neither exists,
#                      pi runs unbounded and a warning is logged once.
#   PI_KILL_AFTER      Seconds to wait after the PI_TIMEOUT SIGTERM before
#                      escalating to SIGKILL (passed as `--kill-after`).
#                      Default 30. A pi (or its child) that ignores SIGTERM
#                      is SIGKILLed at PI_TIMEOUT + PI_KILL_AFTER; both the
#                      SIGTERM (124) and SIGKILL (137) exit codes are
#                      classified as a timeout. Ignored when no timeout
#                      binary exists (unbounded path).
#                      Known limit: processes that detach into their own
#                      session (setsid/daemons) escape the timeout entirely.
#   PI_DELEGATE_UNSAFE  Set to 1 to skip the safety preflight (allow running
#                      on the default branch, allow secret-looking files,
#                      do not neutralise git push). Only set this when you
#                      have arranged real isolation (a disposable clone /
#                      worktree or a container) and understand that pi has
#                      no sandbox. See the README "Safety" section.
#
# Output: all progress on stderr; exactly one JSON summary on the LAST
# line of stdout (built with jq, never string interpolation).
#
# Exit codes:
#   0  PASS | PASSED_WITH_FINDINGS | EMPTY_DIFF
#   1  REJECTED (budget exhausted, no terminal verdict reached)
#   2  INCOMPLETE (no parseable verdict from pi)
#   3  PI_ERROR   (pi missing, pi crashed, a diff snapshot failed
#       (git rev-parse / git diff / git ls-files / git diff --no-index)
#       with git's stderr surfaced verbatim, or pi timed out after
#       PI_TIMEOUT seconds, or the safety preflight refused the run
#       (default branch / secret files) — the refusal emits a JSON
#       summary with status PI_ERROR)
#   2  is also used for CLI usage errors (unknown flag, missing task,
#       invalid --max-rounds, invalid PI_TIMEOUT, invalid PI_KILL_AFTER) —
#       the spec defines exit codes 0-3 only, and a distinct usage code
#       would require a new code; documented here.
#
# Safety preflight (issue #30): unless PI_DELEGATE_UNSAFE=1, the driver
# refuses to run (exit 3, JSON summary) when the current branch is the
# default branch (or HEAD is detached on its tip) or when secret-looking
# files (.env, .env.*, *.pem, *.key) are present in the working tree.
# It also neutralises `git push` for every pi process via the
# GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n env (push.default
# = nothing + per-remote pushurl to an invalid URL). See the README "Safety"
# section for the rationale and the PI_DELEGATE_UNSAFE=1 opt-out.

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

# --- Push neutralisation (skipped when PI_DELEGATE_UNSAFE=1) ---------------
# pi's full toolset can run `git push`. To keep the developer from pushing
# feature-branch work (or, worse, the default branch) to a remote, the env is
# configured so that every pi process's `git push` fails. This uses
# GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n (0-indexed, git's
# native env mechanism) to append to any existing GIT_CONFIG_* entries rather
# than clobbering them. The config sets push.default=nothing (so a bare
# `git push` with no refspec fails) and, for every `git remote`, a pushurl
# pointing at an invalid URL (so `git push <remote>` fails). Pushes to an
# explicit URL (`git push <url>`) bypass per-remote config, so common URL
# prefixes (https://, http://, ssh://, git://, file://, the scp-like git@
# form, and absolute local paths /) are additionally rewritten via
# pushInsteadOf to the same dead helper. pushInsteadOf cannot rewrite bare
# relative local paths (e.g. ../repo) — see the code comment below. The
# single opt-out is PI_DELEGATE_UNSAFE=1.
if [ "${PI_DELEGATE_UNSAFE:-}" != "1" ]; then
  # Build the GIT_CONFIG_* entries, appending to any pre-existing ones so we
  # never clobber a caller's config. GIT_CONFIG entries are 0-indexed; the
  # single cursor _gc starts at the validated pre-existing GIT_CONFIG_COUNT,
  # and each entry exports its KEY_n / VALUE_n pair then increments (COUNT
  # is exported once, at the end). A caller-provided
  # GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n (e.g. git
  # re-exports them in a subshell) is preserved. A pre-existing count that
  # is not a non-negative integer is refused (git hard-errors on it anyway):
  # the guards are never built on top of garbage indices.
  _gc="${GIT_CONFIG_COUNT:-0}"
  if ! [[ "$_gc" =~ ^[0-9]+$ ]]; then
    # emit_json is defined later in the script (after this block); build the
    # refusal summary inline (jq, never string interpolation) so the JSON
    # contract is identical to every other PI_ERROR refusal path.
    log "REFUSED: pre-existing GIT_CONFIG_COUNT='${GIT_CONFIG_COUNT}' is not a non-negative integer (set PI_DELEGATE_UNSAFE=1 to override)"
    jq -cn '{status:"PI_ERROR",verdict:null,rounds:0,total_pi_calls:0,findings:[],raw_output:""}'
    exit 3
  fi
  export GIT_CONFIG_KEY_${_gc}=push.default GIT_CONFIG_VALUE_${_gc}=nothing
  _gc=$((_gc + 1))
  # pushInsteadOf rewrites matching URL prefixes to the dead helper. The
  # final entry has an EMPTY value, which matches every remaining URL
  # (including bare relative local paths like `git push ../repo`, which
  # have no prefix for the per-prefix entries above) — closing the last
  # form a caller could use to bypass the dead helper.
  for _p in https:// http:// ssh:// git:// file:// git@ / ""; do
    export GIT_CONFIG_KEY_${_gc}="url.pi-delegate-push-disabled://.pushInsteadOf" GIT_CONFIG_VALUE_${_gc}="${_p}"
    _gc=$((_gc + 1))
  done
  # For every configured remote, set a pushurl to an invalid URL. This makes
  # `git push <remote>` (and `git push <remote> <ref>`) fail with a clear
  # "remote helper ... aborted session" error rather than pushing.
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    export GIT_CONFIG_KEY_${_gc}="remote.${_r}.pushurl" GIT_CONFIG_VALUE_${_gc}=pi-delegate-push-disabled://dead
    _gc=$((_gc + 1))
  done < <(git remote 2>/dev/null || true)
  export GIT_CONFIG_COUNT="${_gc}"
  unset _gc _p _r
fi

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
# SIGKILL escalation grace window (see PI_KILL_AFTER above); the unbounded
# path (no timeout binary) silently ignores it.
PI_KILL_AFTER="${PI_KILL_AFTER:-30}"
if ! [[ "$PI_KILL_AFTER" =~ ^[0-9]+$ ]] || [ "$PI_KILL_AFTER" -lt 1 ]; then
  die_usage "PI_KILL_AFTER must be a positive integer (got: $PI_KILL_AFTER)"
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

# --- Safety preflight (skipped entirely when PI_DELEGATE_UNSAFE=1) ---------
# pi has no sandbox: its full toolset can read every file in the working tree
# (including ignored ones) and run arbitrary commands. This preflight refuses
# to hand an unsafe tree to pi. Two checks: (1) the current branch must not be
# the repo's default branch (or HEAD must not be detached on its tip) — pi must
# work on a feature branch so its edits are not lost if it pushes or amends the
# mainline; (2) secret-looking files (.env, .env.*, *.pem, *.key) must be
# absent — pi's tools can read them and send them to the model provider. The
# single opt-out is PI_DELEGATE_UNSAFE=1 (documented in README + both SKILL.md).
# The preflight runs after loop-state init and function definitions so that
# emit_json and the loop-state variables (verdict, round, total_pi_calls,
# findings_json, last_transcript) are all in scope for the refusal path.
if [ "${PI_DELEGATE_UNSAFE:-}" != "1" ]; then
  # Default branch: origin/HEAD target (minus "origin/"), else main, else
  # master (only when the local branch exists); otherwise empty (no default).
  default_branch=""
  head_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || head_ref=""
  if [ -n "$head_ref" ]; then
    default_branch="${head_ref#origin/}"
  else
    cur="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || cur=""
    for cand in main master; do
      if [ -z "$cur" ] || [ "$cur" = "$cand" ]; then
        if git show-ref --verify --quiet "refs/heads/$cand" 2>/dev/null; then
          default_branch="$cand"
          break
        fi
      fi
    done
  fi
  cur_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || cur_branch=""
  if [ -n "$default_branch" ]; then
    if [ -n "$cur_branch" ] && [ "$cur_branch" = "$default_branch" ]; then
      log "REFUSED: current branch is the default branch '${default_branch}' (set PI_DELEGATE_UNSAFE=1 to override)"
      emit_json "PI_ERROR" "" 0 0 '[]' ""
      exit 3
    fi
    # Detached HEAD exactly at the default branch's tip is equally unsafe.
    if [ -z "$cur_branch" ]; then
      head_sha="$(git rev-parse --quiet --verify HEAD 2>/dev/null)" || head_sha=""
      def_sha="$(git rev-parse --quiet --verify "refs/heads/${default_branch}" 2>/dev/null)" || def_sha=""
      if [ -n "$head_sha" ] && [ "$head_sha" = "$def_sha" ]; then
        log "REFUSED: detached HEAD at the tip of the default branch '${default_branch}' (set PI_DELEGATE_UNSAFE=1 to override)"
        emit_json "PI_ERROR" "" 0 0 '[]' ""
        exit 3
      fi
    fi
  fi
  # Secret-looking files anywhere in the working tree (tracked, untracked,
  # and ignored — pi can read ignored files too). `find` runs from the repo
  # root (paths are reported relative to it), pruning .git and node_modules,
  # matching the secret patterns on regular files and symlinks alike. The
  # scan is fail-closed: any non-zero `find` exit (e.g. an unreadable
  # directory) is refused as PI_ERROR — a partial scan must never pass.
  repo_root="$(git rev-parse --show-toplevel)"
  secrets_file="$(mktemp)"
  scan_err_file="$(mktemp)"
  secrets_rc=0
  find "$repo_root" -not -path "$repo_root/.git" -not -path "$repo_root/.git/*" -not -path "$repo_root/node_modules" -not -path "$repo_root/node_modules/*" \
    \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \) \( -type f -o -type l \) \
    > "$secrets_file" 2> "$scan_err_file" || secrets_rc=$?
  if [ "$secrets_rc" -ne 0 ]; then
    scan_err="$(cat "$scan_err_file")"
    [ -n "$scan_err" ] || scan_err="(no output)"
    log "REFUSED: secret-file scan failed: ${scan_err}"
    emit_json "PI_ERROR" "" 0 0 '[]' ""
    rm -f "$secrets_file" "$scan_err_file"
    exit 3
  fi
  # .env.example / .env.sample / .env.template are safe (no secrets). Max 5
  # paths are listed in the refusal message (integer counter, not a per-
  # iteration grep|wc pipeline).
  secrets_found=""
  sf=""
  shown=0
  while IFS= read -r sf; do
    sf="${sf#"$repo_root"/}"
    case "$sf" in
      *.example|*.sample|*.template) continue ;;
    esac
    if [ -z "$secrets_found" ]; then
      secrets_found="$sf"
    else
      secrets_found="${secrets_found}, ${sf}"
    fi
    shown=$((shown + 1))
    [ "$shown" -ge 5 ] && break
  done < "$secrets_file"
  rm -f "$secrets_file" "$scan_err_file"
  if [ -n "$secrets_found" ]; then
    log "REFUSED: secret-looking file(s) present in the working tree: ${secrets_found} (set PI_DELEGATE_UNSAFE=1 to override)"
    emit_json "PI_ERROR" "" 0 0 '[]' ""
    exit 3
  fi
fi

# --- Diff snapshot --------------------------------------------------------
# get_diff <label> — snapshot the full change set since START_REF:
#   - `git diff $START_REF`          tracked changes (also covers work
#     committed during the develop/fix rounds, since START_REF is the
#     pre-develop commit, not HEAD), and
#   - `git diff --no-index /dev/null <f>` per untracked, non-ignored file
#     from `git ls-files --others --exclude-standard -z` (NUL-delimited, so
#     paths with spaces, newlines, or other special characters are safe, and
#     files inside a new directory are listed individually rather than as a
#     `?? dir/` entry), which shows new files to the reviewer. `--no-index`
#     exits 0/1 when the files are alike/differ (both are the diff, captured
#     on stdout) and 2 on a real failure, captured via GIT_ERR_FILE so a
#     genuine failure surfaces as PI_ERROR.
# Git's stderr is redirected straight into $GIT_ERR_FILE (a writable path
# created once at startup; the function runs in a subshell when its stdout
# is captured, so a variable could not be used) and truncated first so a
# stale failure message from an earlier round is never re-surfaced.
# Returns 0 on a non-empty diff (echoed on stdout), 1 on an empty diff,
# and 2 on a git failure.
get_diff() {
  local label="$1"
  local rc
  local head_part=""
  local f
  local untracked_part=""
  : >"${GIT_ERR_FILE:?GIT_ERR_FILE not set}"

  # Tracked changes since the start ref (a commit recorded at entry, or the
  # empty-tree hash on an unborn repo; both are valid `git diff` refs).
  # Note: tracked symlinks are safe here — git renders a committed symlink
  # as a mode-120000 blob whose only diff line is the target path string,
  # never the target's file content (verified empirically with `git diff
  # <start-ref>` on this host).
  rc=0
  head_part="$(git diff "$START_REF" 2>"$GIT_ERR_FILE")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "ERROR: git diff ${START_REF} failed during ${label}"
    return 2
  fi

  # Untracked, non-ignored files (new files the develop/fix round produced).
  # The tracked diff above already covers modifications and deletions of
  # tracked files (including renames), so only genuinely new files are
  # appended here. `git ls-files --others --exclude-standard -z` emits
  # NUL-delimited paths (no C-quoting), enumerates files inside a new
  # directory individually (not as a `dir/` entry), and honors .gitignore
  # via --exclude-standard. `git diff --no-index -- /dev/null <f>` renders
  # the file as an addition; --no-index exits 1 when the files differ
  # (that IS the diff), 0 when alike, and 2 on a real failure.
  rc=0
  git ls-files --others --exclude-standard -z >"$LS_FILE" 2>"$GIT_ERR_FILE" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "ERROR: git ls-files failed during ${label}"
    return 2
  fi
  while IFS= read -r -d '' f; do
    local untracked_diff
    rc=0
    # Untracked symlinks: never pass to git diff --no-index (which would
    # expose the target path in the diff). Instead emit a one-line synthetic
    # note. `readlink` (not readlink -f) returns the stored target path even
    # for dangling symlinks, so this is safe regardless of target existence.
    if [ -L "$f" ]; then
      local link_target
      link_target="$(readlink "$f")"
      if [ -n "$untracked_part" ]; then
        untracked_part="${untracked_part}"$'\n'"new symlink ${f} -> ${link_target} (content not shown)"
      else
        untracked_part="new symlink ${f} -> ${link_target} (content not shown)"
      fi
      continue
    fi
    untracked_diff="$(git diff --no-index -- /dev/null "$f" 2>"$GIT_ERR_FILE")" || rc=$?
    if [ "$rc" -gt 1 ]; then
      log "ERROR: git diff --no-index failed during ${label} for ${f}"
      return 2
    fi
    if [ -n "$untracked_diff" ]; then
      if [ -n "$untracked_part" ]; then
        untracked_part="${untracked_part}"$'\n'"${untracked_diff}"
      else
        untracked_part="$untracked_diff"
      fi
    fi
  done <"$LS_FILE"

  local combined="${head_part}"
  if [ -n "$untracked_part" ]; then
    if [ -n "$combined" ]; then
      combined="${combined}"$'\n'"${untracked_part}"
    else
      combined="$untracked_part"
    fi
  fi
  [ -n "$combined" ] || return 1
  printf '%s' "$combined"
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
# transcript in a fix prompt) to PI_DIFF_MAX_BYTES (default 90000),
# keeping whole lines and appending a truncation notice if dropped.
# Rationale: the prompt is passed to pi (via stdin or argv), and Linux
# caps a single argv element at ~128KB (MAX_ARG_STRLEN). Byte lengths
# are measured with `wc -c` (locale-independent) so the notice always
# shows byte counts even in a UTF-8 locale.
trim_diff() {
  local raw="$1" limit="${PI_DIFF_MAX_BYTES:-90000}"
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
  # Edge case: if the truncated prefix contains no newline at all, keep
  # the prefix as-is (the old code emptied it, producing a useless
  # prompt with only the truncation notice).
  if [[ "$shown" == *$'\n'* ]]; then
    shown="${shown%$'\n'*}"
  fi
  printf '%s\n[truncated: %s of %s bytes shown (PI_DIFF_MAX_BYTES=%s)]' "$shown" "$(printf '%s' "$shown" | wc -c | tr -d ' ')" "$total" "$limit"
}

# --- pi invocation --------------------------------------------------------
# run_pi <prompt> <system-prompt-content|-> [tools]
# Runs pi headless in JSON mode; stores the extracted final text in
# $last_transcript. Returns 1 (and sets $pi_stderr) on non-zero exit.
#
# The prompt is passed via stdin (piped to pi) rather than as an argv
# string. This avoids E2BIG ("Argument list too long") when the prompt
# exceeds MAX_ARG_STRLEN (131072 bytes on Linux). Pi reads piped stdin
# and merges it into the initial prompt (stdin content + @file content +
# positional message, joined). Since no positional message is given,
# the prompt text is the entire initial prompt.
#
# Total size check: the combined byte count of all argv elements and
# stdin content is verified against PI_PROMPT_MAX_BYTES (default 120000)
# before calling pi. If exceeded, a clear error is produced (exit 3)
# instead of an opaque E2BIG from the kernel.
run_pi() {
  local prompt="$1" system_prompt="$2" tools="${3:--}"
  local args=(--mode json -p --no-session --no-extensions --no-skills --no-prompt-templates)
  [ -z "${PI_CONTEXT_FILES:-}" ] && args+=(--no-context-files)
  [ "$system_prompt" != "-" ] && args+=(--append-system-prompt "$system_prompt")
  [ "$tools" != "-" ] && args+=(--tools "$tools")
  [ -n "$model_arg" ] && args+=(--model "$model_arg")

  # Total byte budget check: sum of all argv elements + prompt (stdin).
  # This catches cases where the system prompt, tools, or other args are
  # large enough to push the total over MAX_ARG_STRLEN even after the
  # diff/transcript has been trimmed to PI_DIFF_MAX_BYTES.
  local prompt_bytes argv_bytes total_bytes
  prompt_bytes="$(printf '%s' "$prompt" | wc -c | tr -d ' ')"
  argv_bytes=0
  local a
  for a in "${args[@]}"; do
    local a_len
    a_len="$(printf '%s' "$a" | wc -c | tr -d ' ')"
    argv_bytes=$((argv_bytes + a_len))
  done
  total_bytes=$((prompt_bytes + argv_bytes))
  local max_bytes="${PI_PROMPT_MAX_BYTES:-120000}"
  if [ "$total_bytes" -gt "$max_bytes" ]; then
    log "ERROR: total prompt size ${total_bytes} bytes exceeds PI_PROMPT_MAX_BYTES=${max_bytes} (prompt=${prompt_bytes}, args=${argv_bytes})"
    pi_stderr="prompt size ${total_bytes} bytes exceeds limit ${max_bytes} bytes (PI_PROMPT_MAX_BYTES)"
    return 1
  fi
  pi_stderr=""

  local rc=0
  local output
  # pi's stderr goes to a temp file, not the captured output: pi prints
  # diagnostics and warnings via console.error, and a single non-JSON line
  # mixed into the stdout stream would make `jq -s` fail on the whole input
  # (issue #57). Stdout is parsed only; stderr is surfaced on failure paths.
  local pi_stderr_file pi_stderr_out
  pi_stderr_file="$(mktemp)"
  if [ -n "$TIMEOUT_CMD" ]; then
    # --kill-after escalates to SIGKILL if pi (or its child) ignores the
    # SIGTERM sent at PI_TIMEOUT; that path exits 137 instead of 124.
    output="$(printf '%s' "$prompt" | "$TIMEOUT_CMD" --kill-after="$PI_KILL_AFTER" "$PI_TIMEOUT" "$PI_BIN" "${args[@]}" 2>"$pi_stderr_file")" || rc=$?
  else
    if [ "$no_timeout_warned" -eq 0 ]; then
      no_timeout_warned=1
      log "WARNING: neither timeout nor gtimeout found on PATH; pi calls run without a time limit"
    fi
    output="$(printf '%s' "$prompt" | "$PI_BIN" "${args[@]}" 2>"$pi_stderr_file")" || rc=$?
  fi
  pi_stderr_out="$(cat "$pi_stderr_file")"
  rm -f "$pi_stderr_file"
  total_pi_calls=$((total_pi_calls + 1))

  # 124 = timed out (SIGTERM honored); 137 = survived SIGTERM, SIGKILLed
  # at the --kill-after grace expiry (128+9). Both are timeouts; the fixed
  # message overrides $output so partial output from the hung run never
  # leaks into pi_stderr. The message names the SIGKILL escalation so the
  # caller knows the second phase exists and its cost (PI_KILL_AFTER).
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    pi_stderr="pi timed out after ${PI_TIMEOUT}s (SIGKILL after a further ${PI_KILL_AFTER}s if needed)"
    [ -n "$pi_stderr_out" ] && pi_stderr="${pi_stderr}
${pi_stderr_out}"
    # The hung run never produced a usable transcript; drop whatever a
    # prior successful call left in $last_transcript so the PI_ERROR
    # summary's raw_output reflects this failed call, not an old one.
    last_transcript=""
    return 1
  fi

  if [ "$rc" -ne 0 ]; then
    pi_stderr="$output"
    [ -n "$pi_stderr_out" ] && pi_stderr="${pi_stderr}
${pi_stderr_out}"
    # Same as the timeout branch: a failed call's summary must not carry a
    # previous call's transcript (issue #50).
    last_transcript=""
    return 1
  fi

  # Final text: the LAST assistant message_end event whose stopReason is
  # "stop" (the terminal assistant message). Fallback (issue #57): runs that
  # end on a toolUse/length/error stop have no "stop" message; fall back to
  # the last assistant message_end with any text content — in practice that
  # message is the report. message_end fires for every message (user,
  # assistant, tool); agent_settled has no text field.
  local text
  text="$(printf '%s' "$output" | jq -s -r '[.[] | select(.type == "message_end") | select(.message.role == "assistant") | select(.message.stopReason == "stop")] | last | (.message.content // [] | map(select(.type == "text") | .text) | join("\n")) // empty' 2>/dev/null)" || text=""
  if [ -z "$text" ]; then
    text="$(printf '%s' "$output" | jq -s -r '[.[] | select(.type == "message_end") | select(.message.role == "assistant") | select((.message.content // []) | map(select(.type == "text") | .text) | join("\n") | length > 0)] | last | .message.content | map(select(.type == "text") | .text) | join("\n")' 2>/dev/null)" || text=""
  fi
  last_transcript="$text"

  verify_provider_model "$output" "pi call ${total_pi_calls}"
  return 0
}

# --- Provider/model verification ------------------------------------------
# After each successful pi call, read every assistant message_end from the
# --mode json transcript and log to stderr which provider/model answered
# (issue #26: the model is intentionally unpinned, so the user can see
# where the work actually went). No failure mode: a missing field is
# reported as "unknown", never fatal. Runs once per call; the jq parse is
# on a single run's output only.
verify_provider_model() {
  local output="$1" label="$2"
  local pm
  pm="$(printf '%s' "$output" | jq -s -r '[.[] | select(.type == "message_end") | select(.message.role == "assistant") | ((.message.provider // "unknown") + "/" + (.message.model // "unknown"))] | unique | .[]' 2>/dev/null)" || pm=""
  if [ -n "$pm" ]; then
    local pair
    for pair in $pm; do
      log "${label}: provider/model ${pair}"
    done
  else
    log "${label}: provider/model not reported in transcript"
  fi
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

# --- Start ref (recorded before develop) -----------------------------------

# git stderr lands in GIT_ERR_FILE only on failure paths that exit
# immediately (die_git_error / fail_pi_error / INCOMPLETE), so a single
# EXIT trap covers every exit route without double-cleanup races.
GIT_ERR_FILE="$(mktemp)"
LS_FILE="$(mktemp)"
trap 'rm -f "$GIT_ERR_FILE" "$LS_FILE"' EXIT
# Record the start ref before the develop round so the review diff covers
# work the developer commits (a diff against a moving ref would miss it).
# On an unborn repo (no commits yet) HEAD does not resolve, so fall back
# to the empty tree: everything present after develop is then "new".
# If git itself fails (corrupt repo), surface it as PI_ERROR.
if START_REF="$(git rev-parse --verify -q HEAD 2>"$GIT_ERR_FILE")"; then
  :
else
  # Unborn repo (no commits yet): diff against the empty tree.
  START_REF="$(git hash-object -t tree /dev/null 2>"$GIT_ERR_FILE")" || die_git_error
fi

# A clean working tree at entry is normal for a develop-first loop: the
# developer round is what produces the work. There is no entry-time diff
# gate; EMPTY_DIFF is only reported post-develop, when the developer left
# no change at all relative to the start ref.

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
    # EMPTY_DIFF is NOT an error: the loop ran, the developer simply
    # produced no change in the working tree. Exit stays 0; the JSON
    # summary (status=EMPTY_DIFF) and this stderr line make that explicit.
    log "EMPTY_DIFF: the developer produced no change in the working tree; nothing to review."
    status="EMPTY_DIFF"
    emit_json "EMPTY_DIFF" "$verdict" "$round" "$total_pi_calls" "$findings_json" "$last_transcript"
    exit 0
  fi

  review_prompt="Adversarially review the current change set (since ${START_REF}, including new untracked files) against the task below."
  [ -n "$last_review_summary" ] && review_prompt="${review_prompt}"$'\n\n'"Context from the previous review round:"$'\n'"${last_review_summary}"
  review_prompt="${review_prompt}"$'\n\n'"Task:"$'\n'"${task}"
  review_prompt="${review_prompt}"$'\n\n'"Current diff (git diff ${START_REF} + untracked):"$'\n'"$(trim_diff "$current_diff")"

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
