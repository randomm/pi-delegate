#!/usr/bin/env bash
# quick.sh — a fast, rough reward function for the delegation setup: tiny
# local tasks, plain Claude (A) vs Claude + the working-tree pi-delegate
# plugin (B), all runs in parallel (~2-5 min). Not scientifically accurate;
# it only tells you whether a change to the skills moved Claude's cost.
#
# Usage: bench/quick.sh [-n runs] [task...]
#   -n  runs per arm per task (default 1)
# Needs claude + pi on PATH (and `jq`; uses timeout/gtimeout when present); auth via the usual claude login (or
# CLAUDE_CODE_OAUTH_TOKEN in the environment).
# A run passes only if the hidden check.py passes AND the task's own tests (if
# it has a tests/ dir) still pass; diff size is reported to spot scope creep.
# Prints a per-run table, then: reward = 1 - costB/costA (positive = delegation
# is cheaper), forced to -1 if B fails more runs than A or never calls pi.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
n=1
while getopts n: o; do case "$o" in n) n=$OPTARG ;; *) exit 2 ;; esac; done
shift $((OPTIND - 1))
tasks=("$@"); [ "${#tasks[@]}" -gt 0 ] || { tasks=(); for d in "$here"/quick/tasks/*/; do tasks+=("$(basename "$d")"); done; }
real_pi="$(command -v pi)"
TMO=(); for c in timeout gtimeout; do command -v "$c" >/dev/null 2>&1 && { TMO=("$c" 1500); break; }; done
out="$(mktemp -d)"

run_one() {  # task arm i
  local task=$1 arm=$2 i=$3 d="$out/$1-$2-$3" t="$here/quick/tasks/$1"
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
  local lines; lines="$(cd "$d/repo" && git add -A -N . 2>/dev/null; git diff --numstat | grep -v '__pycache__\|\.pyc' | awk '{s+=$1+$2} END {print s+0}')"
  local pass=false
  ( cd "$d/repo" && cp "$t/check.py" ./_check.py && python3 _check.py >/dev/null 2>&1 \
    && { [ ! -d tests ] || python3 -m unittest discover -s tests >/dev/null 2>&1; } ) && pass=true
  jq -c --arg task "$task" --arg arm "$arm" --argjson pass "$pass" --argjson lines "$lines" \
    --argjson pi "$([ -f "$d/pi.calls" ] && wc -l < "$d/pi.calls" | tr -d ' ' || echo 0)" \
    '{task:$task,arm:$arm,pass:$pass,pi_calls:$pi,lines:$lines,cost:(.total_cost_usd//0),turns:.num_turns,secs:((.duration_ms//0)/1000|floor)}' \
    "$d/out.json" > "$d/row.json" 2>/dev/null || echo "{\"task\":\"$task\",\"arm\":\"$arm\",\"pass\":false,\"pi_calls\":0,\"lines\":0,\"cost\":0,\"turns\":0,\"secs\":0}" > "$d/row.json"
}

for task in "${tasks[@]}"; do for arm in A B; do for i in $(seq 1 "$n"); do
  run_one "$task" "$arm" "$i" &
done; done; done
wait
cat "$out"/*/row.json | jq -s -r '
  (sort_by(.task,.arm)[] | "\(.task)\t\(.arm)\tpass=\(.pass)\tpi=\(.pi_calls)\t$\(.cost*1000|round/1000)\tlines=\(.lines)\tturns=\(.turns)\t\(.secs)s"),
  (group_by(.arm) | map({arm:.[0].arm, cost:(map(.cost)|add), bad:(map(select(.pass|not))|length), nopi:(map(select(.pi_calls==0))|length)}) as $g
   | ($g[]|select(.arm=="A")) as $a | ($g[]|select(.arm=="B")) as $b
   | "A cost=\($a.cost*1000|round/1000) fails=\($a.bad)   B cost=\($b.cost*1000|round/1000) fails=\($b.bad) no-pi=\($b.nopi)",
     "REWARD \(if $b.bad>$a.bad or $b.nopi>0 then -1 else (1-$b.cost/([$a.cost,0.000001]|max))*100|round/100 end)")' | column -t -s "$(printf '\t')"
echo "runs in $out"
