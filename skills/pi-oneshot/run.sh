#!/usr/bin/env bash
# run.sh — pi-oneshot driver: one headless `pi -p` call, run detached and
# waited on inside bounded foreground calls (Claude Code's Bash tool kills
# a foreground call at ~10 min; a detached pi run survives that).
#
# Usage:
#   run.sh [--model M] < task     start pi on the task from stdin, then wait
#   run.sh --wait  RUN_DIR        keep waiting for a run that was still going
#   run.sh --abort RUN_DIR        stop a run (kills its process group)
#
# Output: "EXIT CODE: <n>", the tail of pi's output, then `git status`/
# `git diff --stat` of the working tree. While the run is still going after
# the wait budget it prints "STILL RUNNING" and the --wait command to repeat.
#
# Environment: PI_TIMEOUT (default 1800 s), PI_KILL_AFTER (default 30 s),
# PI_WAIT_BUDGET (default 540 s per call), PI_DELEGATE_UNSAFE=1 skips the
# safety preflight (default branch / secret files / push neutralisation).
# Exit codes: 0 done (pi exit code is in the output), 1 run died or pi
# missing, 2 usage/knob error, 3 preflight refusal.

set -euo pipefail

PI_TIMEOUT="${PI_TIMEOUT:-1800}"
PI_KILL_AFTER="${PI_KILL_AFTER:-30}"
PI_WAIT_BUDGET="${PI_WAIT_BUDGET:-540}"
for knob in PI_TIMEOUT PI_KILL_AFTER PI_WAIT_BUDGET; do
  v="${!knob}"
  if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ]; then
    echo "ERROR: $knob must be a positive integer (got: $v)" >&2
    exit 2
  fi
done

find_pi() {
  local candidate
  for candidate in "$(command -v pi 2>/dev/null || true)" "$HOME/.bun/bin/pi" "$HOME/.local/bin/pi"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Print the result of a finished run (or the still-running notice).
report() {
  local d="$1" pid rc_file="$1/pi.rc" log_file="$1/pi.log" waited=0
  pid="$(cat "$d/pi.pid" 2>/dev/null || true)"
  [ -n "$pid" ] || { echo "PID FILE UNREADABLE — check RUN_DIR"; return 1; }
  while [ ! -s "$rc_file" ] && kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$PI_WAIT_BUDGET" ]; then
      echo "STILL RUNNING — repeat: bash $0 --wait $d"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  if [ ! -s "$rc_file" ]; then
    echo "RUN DIED — no exit code recorded; tail of log:"
    tail -n 20 "$log_file"
    return 1
  fi
  echo "EXIT CODE: $(cat "$rc_file")  (124/137 = timed out)"
  tail -n 40 "$log_file"
  echo "--- working tree ---"
  git status --short 2>/dev/null | head -20 || true
  git diff --stat 2>/dev/null | tail -n 20 || true
}

abort() {
  local d="$1" pid c
  pid="$(cat "$d/pi.pid" 2>/dev/null || true)"
  [ -n "$pid" ] || { echo "PID FILE UNREADABLE — check RUN_DIR"; return 1; }
  # Two-factor guard against a recycled pid: it must lead its own process
  # group (set -m at launch) and its command line must be this script (the
  # recorded pid is the launching subshell, which shows as run.sh).
  if [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ] \
    && ps -o command= -p "$pid" 2>/dev/null | grep -qF "$(basename "$0")"; then
    # GNU timeout moves itself and pi into a group of its own, so kill the
    # groups of the subshell's direct children as well as the subshell's.
    local groups="$pid"
    for c in $(pgrep -P "$pid" 2>/dev/null || true); do groups="$groups $c"; done
    for c in $groups; do kill -TERM -- "-$c" 2>/dev/null || true; done
    sleep 5
    for c in $groups; do kill -KILL -- "-$c" 2>/dev/null || true; done
    echo "aborted"
  else
    echo "not a pi-delegate run group — skipping"
  fi
}

case "${1:-}" in
  --wait) [ -n "${2:-}" ] || { echo "usage: $0 --wait RUN_DIR" >&2; exit 2; }; report "$2"; exit $? ;;
  --abort) [ -n "${2:-}" ] || { echo "usage: $0 --abort RUN_DIR" >&2; exit 2; }; abort "$2"; exit $? ;;
esac

model_args=()
if [ "${1:-}" = "--model" ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 --model MODEL < task" >&2; exit 2; }
  model_args=(--model "$2")
  shift 2
fi
[ "$#" -eq 0 ] || { echo "usage: $0 [--model M] < task | --wait RUN_DIR | --abort RUN_DIR" >&2; exit 2; }

task="$(cat)"
[ -n "$task" ] || { echo "ERROR: empty task on stdin" >&2; exit 2; }

PI_BIN="$(find_pi)" || { echo "pi not found (PATH, ~/.bun/bin/pi, ~/.local/bin/pi) — install: curl -fsSL https://pi.dev/install.sh | sh"; exit 1; }

timeout_cmd=""
for cand in timeout gtimeout; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --kill-after=1 1 true >/dev/null 2>&1; then
    timeout_cmd="$cand"
    break
  fi
done
wrap=()
if [ -n "$timeout_cmd" ]; then
  wrap=("$timeout_cmd" --kill-after="$PI_KILL_AFTER" "$PI_TIMEOUT")
else
  echo "WARNING: no GNU timeout/gtimeout found — pi runs without a time limit" >&2
fi

# --- Safety preflight (issue #30; same checks as orchestrate.sh) -----------
if [ "${PI_DELEGATE_UNSAFE:-}" != "1" ]; then
  default_branch=""
  head_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || head_ref=""
  if [ -n "$head_ref" ]; then
    default_branch="${head_ref#origin/}"
  else
    cur="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || cur=""
    for cand in main master; do
      if [ -z "$cur" ] || [ "$cur" = "$cand" ]; then
        if git show-ref --verify --quiet "refs/heads/$cand" 2>/dev/null; then default_branch="$cand"; break; fi
      fi
    done
  fi
  cur_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || cur_branch=""
  if [ -n "$default_branch" ]; then
    if [ "$cur_branch" = "$default_branch" ]; then
      echo "REFUSED: current branch is the default branch '${default_branch}' (set PI_DELEGATE_UNSAFE=1 to override)" >&2
      exit 3
    fi
    if [ -z "$cur_branch" ]; then
      head_sha="$(git rev-parse --quiet --verify HEAD 2>/dev/null)" || head_sha=""
      def_sha="$(git rev-parse --quiet --verify "refs/heads/${default_branch}" 2>/dev/null)" || def_sha=""
      if [ -n "$head_sha" ] && [ "$head_sha" = "$def_sha" ]; then
        echo "REFUSED: detached HEAD at the tip of the default branch '${default_branch}' (set PI_DELEGATE_UNSAFE=1 to override)" >&2
        exit 3
      fi
    fi
  fi
  # Secret-looking files, fail-closed: any find error is a refusal.
  repo_root="$(git rev-parse --show-toplevel)" || { echo "REFUSED: could not determine the repo root" >&2; exit 3; }
  scan_file="$(mktemp)"; scan_err="$(mktemp)"
  find "$repo_root" -not -path "$repo_root/.git" -not -path "$repo_root/.git/*" -not -path "$repo_root/node_modules" -not -path "$repo_root/node_modules/*" \
    \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \) \( -type f -o -type l \) \
    > "$scan_file" 2> "$scan_err" || { echo "REFUSED: secret-file scan failed: $(cat "$scan_err")" >&2; exit 3; }
  secrets_found=""; shown=0
  while IFS= read -r sf; do
    sf="${sf#"$repo_root"/}"
    case "$sf" in *.example|*.sample|*.template) continue ;; esac
    secrets_found="${secrets_found:+$secrets_found, }$sf"
    shown=$((shown + 1))
    [ "$shown" -ge 5 ] && break
  done < "$scan_file"
  rm -f "$scan_file" "$scan_err"
  if [ -n "$secrets_found" ]; then
    echo "REFUSED: secret-looking file(s) present: ${secrets_found} (set PI_DELEGATE_UNSAFE=1 to override)" >&2
    exit 3
  fi
  # Neutralise git push for the pi process (appends to any caller entries).
  _gc="${GIT_CONFIG_COUNT:-0}"
  if ! [[ "$_gc" =~ ^[0-9]+$ ]]; then
    echo "REFUSED: pre-existing GIT_CONFIG_COUNT='${GIT_CONFIG_COUNT}' is not a non-negative integer (set PI_DELEGATE_UNSAFE=1 to override)" >&2
    exit 3
  fi
  export GIT_CONFIG_KEY_${_gc}=push.default GIT_CONFIG_VALUE_${_gc}=nothing
  _gc=$((_gc + 1))
  for _p in https:// http:// ssh:// git:// file:// git@ / ""; do
    export GIT_CONFIG_KEY_${_gc}="url.pi-delegate-push-disabled://.pushInsteadOf" GIT_CONFIG_VALUE_${_gc}="${_p}"
    _gc=$((_gc + 1))
  done
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    export GIT_CONFIG_KEY_${_gc}="remote.${_r}.pushurl" GIT_CONFIG_VALUE_${_gc}=pi-delegate-push-disabled://dead
    _gc=$((_gc + 1))
  done < <(git remote 2>/dev/null)
  export GIT_CONFIG_COUNT="${_gc}"
fi

# Run files live outside the repo (untracked files there would show up in
# the diff).
D="$(mktemp -d)"
printf '%s' "$task" > "$D/task.txt"
set -m
( rc=0; ${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates ${model_args[@]+"${model_args[@]}"} < "$D/task.txt" > "$D/pi.log" 2>&1 || rc=$?; echo "$rc" > "$D/pi.rc" ) &
echo "$!" > "$D/pi.pid"
set +m
echo "RUN_DIR=$D"
report "$D"
