#!/usr/bin/env bash
# cleanup.sh — delete benchmark run directories whose metrics have been
# collected (or runs abandoned mid-flight). Part of the benchmark harness
# (docs/benchmark.md §metrics, §safe-execution).
#
# The harness keeps every run under $BENCH_OUT (default: /tmp/pi-bench),
# OUTSIDE any repo, and nothing deletes a run after collection — on
# systems where /tmp is a RAM-backed tmpfs, leftover clones (often over
# 1 GB once SETUP_CMD has built a venv or node_modules) fill the
# filesystem quickly (issue #60). This script reclaims that space.
#
# Usage:
#   bench/cleanup.sh --list
#   bench/cleanup.sh --collected [task|task/arm|task/arm/run# ...]
#   bench/cleanup.sh --all [--force]
#
# Modes:
#   --list         Print every run's path and status (collected /
#                  not-collected / malformed-collect) and the total disk
#                  usage; deletes nothing.
#   --collected    Remove runs that have ALREADY been collected: the
#                  optional positional args are run prefixes (task,
#                  task/arm, or task/arm/run#); with no args, every
#                  collected run under $BENCH_OUT is removed. A run is
#                  "collected" when its path appears on one or more
#                  verified collect.sh output lines (see
#                  collect_line_exists). Un-collected or malformed
#                  collect lines are NEVER removed.
#   --all          Remove EVERY run directory under $BENCH_OUT (including
#                  un-collected and abandoned runs). In an interactive
#                  shell (TTY stdin) the operator is prompted for
#                  confirmation; in a non-interactive shell the script
#                  refuses UNLESS --force is given.
#
# Exit codes:
#   0  success (or nothing matched / nothing to do)
#   1  guard refusal, usage error, failed removal, or --all declined

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

bench_out_guard || exit 1

usage() {
  echo "Usage: $0 --list" >&2
  echo "       $0 --collected [task|task/arm|task/arm/run# ...]" >&2
  echo "       $0 --all [--force]" >&2
  exit 1
}

# --- Collect-line lookup -------------------------------------------------------
# A run is "collected" when some collect.sh output line on disk records it.
# collect.sh writes one JSON object per run to stdout or to the optional
# [output.jsonl] argument; the harness convention is
# $BENCH_OUT/<task>/<arm>/<run>/collect.json. This function checks every
# collect.json under $BENCH_OUT, verifies the line parses as JSON, and
# returns 0 when any line's task/arm/run triple matches the requested run.
collect_line_exists() {
  local task="$1" arm="$2" run_num="$3"
  local cj_file
  shopt -s nullglob
  for cj_file in "$BENCH_OUT"/*/*/*/collect.json; do
    jq -e . "$cj_file" >/dev/null 2>&1 || continue
    if jq -e -r --arg t "$task" --arg a "$arm" --argjson r "$run_num" \
        'select((.task == $t) and (.arm == $a) and (.run == $r)) | .task' \
        "$cj_file" >/dev/null 2>&1; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

# --- Run-directory enumeration --------------------------------------------------
# Each entry on stdout: "<task>/<arm>/<run>\t<path>"
# Run directories live at depth 3 under BENCH_OUT:
#   $BENCH_OUT/<task>/<arm>/<run>/
# A directory qualifies when:
#   - the arm component is exactly "A" or "B" (single uppercase letter),
#   - the run component is one or more digits.
list_runs() {
  local d
  # find does NOT do glob pattern matching, so numeric-looking directory
  # names match by real name — no [0-9] class semantics to worry about.
  while IFS= read -r -d '' d; do
    local rel="${d#"$BENCH_OUT"/}"
    local task="${rel%%/*}"
    local rest="${rel#*/}"
    local arm="${rest%%/*}"
    local run="${rest#*/}"
    [ "$task" = "tasks" ] && continue
    case "$arm" in
      A|B) : ;;
      *) continue ;;
    esac
    case "$run" in
      ''|*[!0-9]*) continue ;;
    esac
    printf '%s/%s/%s\t%s\n' "$task" "$arm" "$run" "$d"
  done < <(find "$BENCH_OUT" -mindepth 3 -maxdepth 3 -type d -print0 2>/dev/null)
}

# run_status <path> — prints collected | not-collected | malformed-collect.
run_status() {
  local p="$1"
  if [ -f "$p/collect.json" ]; then
    if jq -e . "$p/collect.json" >/dev/null 2>&1; then
      echo "collected"
    else
      echo "malformed-collect"
    fi
  else
    echo "not-collected"
  fi
}

# --- --list ------------------------------------------------------------------
do_list() {
  local key path status total=0 size
  echo "Run                                   Status            Path"
  while IFS=$'\t' read -r key path; do
    [ -n "$key" ] || continue
    status="$(run_status "$path")"
    printf '%-35s %-17s %s\n' "$key" "$status" "$path"
    size="$(du -sk "$path" 2>/dev/null | cut -f1 || true)"
    case "$size" in ''|*[!0-9]*) : ;; *) total=$(( total + size )) ;; esac
  done < <(list_runs)
  if [ "$total" -gt 0 ]; then
    printf 'Total: %s KiB under %s\n' "$total" "$BENCH_OUT"
  fi
  return 0
}

# --- Prefix parsing --------------------------------------------------------------
# parse_prefix <arg> — sets P_TASK/P_ARM/P_RUN, each either a value or
# "any". Returns 1 on a malformed prefix.
P_TASK=""; P_ARM=""; P_RUN=""
parse_prefix() {
  local p="$1"
  local -a parts
  IFS='/' read -ra parts <<< "$p"
  local n="${#parts[@]}"
  if [ "$n" -lt 1 ] || [ "$n" -gt 3 ] || [ -z "${parts[0]}" ]; then
    echo "cleanup: bad run prefix '$p' (expected task, task/arm, or task/arm/run#)" >&2
    return 1
  fi
  P_TASK="${parts[0]}"; P_ARM="any"; P_RUN="any"
  [ "$n" -ge 2 ] && P_ARM="${parts[1]}"
  [ "$n" -ge 3 ] && P_RUN="${parts[2]}"
  case "$P_ARM" in
    any|A|B) : ;;
    *)
      echo "cleanup: arm in prefix '$p' must be A or B" >&2
      return 1
      ;;
  esac
  case "$P_RUN" in
    any|'') : ;;
    *[!0-9]*)
      echo "cleanup: run# in prefix '$p' must be a positive integer" >&2
      return 1
      ;;
  esac
  return 0
}

# match_prefix <task> <arm> <run> — 0 when the run matches the parsed prefix.
match_prefix() {
  local task="$1" arm="$2" run="$3"
  [ "$P_TASK" = "$task" ] || return 1
  [ "$P_ARM" = any ] || [ "$P_ARM" = "$arm" ] || return 1
  [ "$P_RUN" = any ] || [ "$P_RUN" = "$run" ] || return 1
  return 0
}

# --- --collected ----------------------------------------------------------------
do_collected() {
  local key path task arm run status
  local removed=0
  local -a prefixes=("$@")
  while IFS=$'\t' read -r key path; do
    [ -n "$key" ] || continue
    task="${key%%/*}"
    local rest="${key#*/}"
    arm="${rest%%/*}"
    run="${rest#*/}"
    if [ "${#prefixes[@]}" -gt 0 ]; then
      local ok=0 p
      for p in "${prefixes[@]}"; do
        parse_prefix "$p" || return 1
        if match_prefix "$task" "$arm" "$run"; then ok=1; break; fi
      done
      [ "$ok" -eq 1 ] || continue
    fi
    status="$(run_status "$path")"
    [ "$status" = "collected" ] || continue
    # A collect.json file present in the run dir is NOT sufficient on its
    # own: the file must actually record THIS run (a stale file from a
    # prior, different run must not cause deletion of the new run).
    if ! collect_line_exists "$task" "$arm" "$run"; then
      echo "cleanup: $key: collect.json present but does not record this run; skipping" >&2
      continue
    fi
    echo "cleanup: removing $path (collected)" >&2
    guard_rm_rf "$path" || {
      echo "cleanup: failed to remove $path" >&2
      return 1
    }
    removed=1
  done < <(list_runs)
  [ "$removed" -eq 1 ] || echo "cleanup: no collected runs to remove" >&2
  return 0
}

# --- --all ----------------------------------------------------------------------
do_all() {
  local force="$1"
  local key path
  local -a all_paths=()
  while IFS=$'\t' read -r key path; do
    [ -n "$key" ] || continue
    all_paths+=("$path")
  done < <(list_runs)
  if [ "${#all_paths[@]}" -eq 0 ]; then
    echo "cleanup: no run directories under $BENCH_OUT" >&2
    return 0
  fi
  if [ "$force" != "1" ] && [ -t 0 ]; then
    printf 'Remove %s run director%s under %s ? (y/N) ' \
      "${#all_paths[@]}" "$([ "${#all_paths[@]}" -eq 1 ] && echo y || echo ies)" "$BENCH_OUT"
    local ans
    if ! read -r ans; then
      echo "cleanup: no confirmation; nothing removed" >&2
      return 1
    fi
    case "$ans" in
      y|Y|yes|YES) : ;;
      *)
        echo "cleanup: declined; nothing removed" >&2
        return 1
        ;;
    esac
  elif [ "$force" != "1" ]; then
    echo "cleanup: non-interactive shell — refusing --all without --force (re-run with a TTY or add --force)" >&2
    return 1
  fi
  local p
  for p in "${all_paths[@]}"; do
    echo "cleanup: removing $p" >&2
    guard_rm_rf "$p" || {
      echo "cleanup: failed to remove $p" >&2
      return 1
    }
  done
  return 0
}

# --- Main ------------------------------------------------------------------------
[ "${#}" -ge 1 ] || usage
mode="$1"
case "$mode" in
  --list)
    shift
    [ "${#}" -eq 0 ] || usage
    do_list
    ;;
  --collected)
    shift
    do_collected "$@"
    ;;
  --all)
    shift
    force=0
    while [ "${#}" -gt 0 ]; do
      case "$1" in
        --force) force=1 ;;
        *)
          echo "cleanup: unknown flag for --all: '$1'" >&2
          usage
          ;;
      esac
      shift
    done
    do_all "$force"
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "cleanup: unknown mode '$mode'" >&2
    usage
    ;;
esac
