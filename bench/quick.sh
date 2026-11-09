#!/usr/bin/env bash
# quick.sh — a fast, rough reward function for the delegation setup: tiny
# local tasks, plain Claude (A) vs Claude + the working-tree pi-delegate
# plugin (B), all runs in parallel (~2-5 min). Not scientifically accurate;
# it only tells you whether a change to the skills moved Claude's cost.
#
# Usage: bench/quick.sh [-k] [-n runs] [task...]
#   -n  runs per arm per task (default 1)
#   -k  keep the run dirs (their path is printed at the end); removed by default
# Needs claude + pi on PATH (and `jq`; uses timeout/gtimeout when present); auth via the usual claude login (or
# CLAUDE_CODE_OAUTH_TOKEN in the environment).
# A run passes only if the hidden check.py passes AND the task's own tests (if
# it has a tests/ dir) still pass; diff size is reported to spot scope creep.
# Each task dir may carry a task.env (KEY=VALUE, operator-authored, same
# convention as bench/tasks/*/task.env) with CLASS (MECHANICAL | INTRICATE |
# ASYNC_TIMING | MULTI_FILE_REFACTOR) and BRIEF_STYLE (PINPOINT | DISCOVERY);
# quick.sh reads it for labelling only and groups the table by class.
# Every row also carries failing_check_cases — the count of failing
# hidden-check test cases the harness recorded (0 when the run passes; null
# only for the degraded fallback row), read from check.log ALONE: the
# agent's own test run lands in agent-tests.log and can never be counted as
# a hidden-check failure. Recorded from the objective check, never
# model-judged (AGENTS.md defers model reviewers). Deliberately named apart
# from collect.sh's bugs_found_in_verification, which counts the OPPOSITE:
# bugs verification failed to catch (docs/benchmark.md).
# Prints a per-run table, then: reward = 1 - costB/costA (positive = delegation
# is cheaper), forced to -1 if B fails more runs than A or never calls pi.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
n=1; keep=0
while getopts kn: o; do case "$o" in k) keep=1 ;; n) n=$OPTARG ;; *) exit 2 ;; esac; done
shift $((OPTIND - 1))
tasks=("$@"); [ "${#tasks[@]}" -gt 0 ] || { tasks=(); for d in "$here"/quick/tasks/*/; do tasks+=("$(basename "$d")"); done; }
# `|| true` keeps the missing-pi guard reachable under set -e: a bare
# failing command substitution in an assignment exits with status 1 and no
# message, which is what the round-2 review saw in the sibling script
# (bench/experiment-retry-feedback.sh) before it got the same guard.
real_pi="$(command -v pi || true)"; [ -n "$real_pi" ] || { echo "quick.sh: pi not on PATH" >&2; exit 2; }
TMO=(); for c in timeout gtimeout; do command -v "$c" >/dev/null 2>&1 && { TMO=("$c" 1500); break; }; done
# Bound the grading phase too: a class-c (ASYNC_TIMING) task tempts the
# agent to add timing tests that wait forever, and the hidden check itself
# exercises agent code — a hang must score FAIL, never wedge the harness.
CKTMO=(); for c in timeout gtimeout; do command -v "$c" >/dev/null 2>&1 && { CKTMO=("$c" "${QUICK_CHECK_TIMEOUT:-120}"); break; }; done
# Explicit template: macOS mktemp -d ignores TMPDIR without one.
out="$(mktemp -d "${TMPDIR:-/tmp}/pi-quick.XXXXXX")"
[ "$keep" = 1 ] || trap 'rm -rf "$out"' EXIT

run_one() {  # task arm i
  local task=$1 arm=$2 i=$3 d="$out/$1-$2-$3" t="$here/quick/tasks/$1"
  local task_class=UNTAGGED task_brief=PINPOINT
  if [ -f "$t/task.env" ]; then
    CLASS='' BRIEF_STYLE=''
    # shellcheck disable=SC1090  # operator-authored, same convention as bench/tasks
    . "$t/task.env"
    task_class="${CLASS:-UNTAGGED}"; task_brief="${BRIEF_STYLE:-PINPOINT}"
  fi
  mkdir -p "$d/bin" "$d/cfg"
  cp -R "$t/repo" "$d/repo"
  printf '#!/bin/sh\necho x >> "%s/pi.calls"\nexec "%s" "$@"\n' "$d" "$real_pi" > "$d/bin/pi"; chmod +x "$d/bin/pi"
  ( cd "$d/repo" && git init -q -b quick && git add -A && git -c user.email=q@q -c user.name=q commit -qm base )
  { cat "$t/prompt.md"
    [ "$arm" = B ] && printf '\n---\nDelegate the implementation to pi with the `delegate` skill (pi-delegate plugin), passing the verification command as --verify; do not implement it yourself.\n'
  } > "$d/prompt.txt"
  local plug=(); [ "$arm" = B ] && plug=(--plugin-dir "$root")
  ( cd "$d/repo" && PATH="$d/bin:$PATH" CLAUDE_CONFIG_DIR="$d/cfg" ${TMO[@]+"${TMO[@]}"} claude -p --output-format json \
      --model "${CLAUDE_MODEL:-claude-sonnet-5-5}" --permission-mode auto "${plug[@]+"${plug[@]}"}" \
      < "$d/prompt.txt" > "$d/out.json" 2> "$d/err.log" ) || true
  local lines; lines="$(cd "$d/repo" && git add -A -N . 2>/dev/null; git diff --numstat | grep -v '__pycache__\|\.pyc' | awk '{s+=$1+$2} END {print s+0}' || true)"
  local pass=false hidden_ok=false bugs=0
  # SEPARATE logs per phase: check.log holds only the hidden check, so the
  # failing-case count below cannot absorb the agent's self-authored
  # unittest summary (the over-count the review found: one log, two
  # FAILED lines, bugs summed across both).
  ( cd "$d/repo" && cp "$t/check.py" ./_check.py && ${CKTMO[@]+"${CKTMO[@]}"} python3 _check.py >"$d/check.log" 2>&1 ) && hidden_ok=true
  if [ "$hidden_ok" = true ]; then
    if [ ! -d "$d/repo/tests" ]; then pass=true
    else
      ( cd "$d/repo" && ${CKTMO[@]+"${CKTMO[@]}"} python3 -m unittest discover -s tests >"$d/agent-tests.log" 2>&1 ) && pass=true
    fi
  fi
  # failing_check_cases: failing hidden-check test cases recorded by the
  # harness (unittest's own FAILED line in check.log). A failed hidden check
  # with no parseable summary (crash before tests ran) still counts as at
  # least one case. When the hidden check passed and only the agent's own
  # tests failed, this is 0 — no hidden case failed.
  if [ "$hidden_ok" = false ]; then
    bugs="$(grep -hoE '(failures|errors)=[0-9]+' "$d/check.log" 2>/dev/null | cut -d= -f2 | awk '{s+=$1} END {print s+0}' || true)"
    [ "${bugs:-0}" -gt 0 ] 2>/dev/null || bugs=1
  fi
  jq -c --arg task "$task" --arg arm "$arm" --argjson pass "$pass" --argjson lines "$lines" \
    --arg class "$task_class" --arg brief "$task_brief" --argjson bugs "$bugs" \
    --argjson pi "$([ -f "$d/pi.calls" ] && wc -l < "$d/pi.calls" | tr -d ' ' || echo 0)" \
    '{task:$task,arm:$arm,class:$class,brief_style:$brief,pass:$pass,failing_check_cases:$bugs,pi_calls:$pi,lines:$lines,cost:(.total_cost_usd//0),turns:.num_turns,secs:((.duration_ms//0)/1000|floor)}' \
    "$d/out.json" > "$d/row.json" 2>/dev/null || echo "{\"task\":\"$task\",\"arm\":\"$arm\",\"class\":\"$task_class\",\"brief_style\":\"$task_brief\",\"pass\":false,\"failing_check_cases\":null,\"pi_calls\":0,\"lines\":0,\"cost\":0,\"turns\":0,\"secs\":0}" > "$d/row.json"
}

for task in "${tasks[@]}"; do for arm in A B; do for i in $(seq 1 "$n"); do
  run_one "$task" "$arm" "$i" &
done; done; done
wait
cat "$out"/*/row.json | jq -s -r '
  (group_by(.class)[] | "CLASS \(.[0].class)",
     (sort_by(.task,.arm)[] | "\(.task)\t\(.arm)\t\(.brief_style)\tpass=\(.pass)\tfbc=\(.failing_check_cases)\tpi=\(.pi_calls)\t$\(.cost*1000|round/1000)\tlines=\(.lines)\tturns=\(.turns)\t\(.secs)s")),
  (. as $rows | group_by(.arm) | map({arm:.[0].arm, cost:(map(.cost)|add), bad:(map(select(.pass|not))|length), nopi:(map(select(.pi_calls==0))|length)}) as $g
   | ($g[]|select(.arm=="A")) as $a | ($g[]|select(.arm=="B")) as $b
   | "A cost=\($a.cost*1000|round/1000) fails=\($a.bad) fbc=\([$rows[]|select(.arm=="A")|.failing_check_cases|select(.!=null)]|add//0) fbc_unknown=\([$rows[]|select(.arm=="A" and .failing_check_cases==null)]|length)   B cost=\($b.cost*1000|round/1000) fails=\($b.bad) fbc=\([$rows[]|select(.arm=="B")|.failing_check_cases|select(.!=null)]|add//0) fbc_unknown=\([$rows[]|select(.arm=="B" and .failing_check_cases==null)]|length) no-pi=\($b.nopi)",
     "REWARD \(if $b.bad>$a.bad or $b.nopi>0 then -1 else (1-$b.cost/([$a.cost,0.000001]|max))*100|round/100 end)")' | column -t -s "$(printf '\t')"
if [ "$keep" = 1 ]; then echo "runs kept in $out"; fi
