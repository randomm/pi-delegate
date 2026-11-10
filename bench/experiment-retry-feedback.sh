#!/usr/bin/env bash
# experiment-retry-feedback.sh — arm A vs arm B on the *kind* of retry
# feedback (issue #96, suggestion 2). Bench-side only:
# skills/delegate/run.sh is neither invoked nor modified — its shipped
# retry (task text + "The verification command `X` failed (exit N) with:" +
# the verify.log tail + "Fix the cause...") is the arm-A CONTROL, reproduced
# with the same framing here so the comparison is honest. One deliberate
# deviation: the tail is passed through verify_excerpt's ALLOWLIST before it
# reaches pi, because verify here is the task's HIDDEN check.py (run.sh's
# --verify is the operator's own command, which never names a grading file).
# That makes arm A a LOWER BOUND, not production arm A: production gets
# `tail -n 40` of the operator's own verify log unsanitized, i.e. strictly
# more information than the control here. A B-win is evidence about the
# feedback *format* relative to a thinned control, not an absolute claim
# about run.sh's shipped tail (docs/benchmark.md says the same). The row
# records feedback_dropped_lines so the analyst can see how much was
# withheld.
#
#   arm A (raw)          retry feedback = the verify-failure tail (passed
#                        through verify_excerpt's allowlist, see there), the
#                        framing run.sh --verify feeds today.
#   arm B (instruction)  one extra `claude -p` call turns the same failure
#                        output into a short numbered list of concrete
#                        instructions; that list replaces the tail.
#
# Hypothesis under test (NOT a result): feedback written as a short numbered
# list of concrete instructions fixes exactly the defects named, reliably;
# the raw tail (or vague feedback) does not converge. B pays Claude tokens
# to author the instruction, so B only wins if its extra pi success
# outweighs that cost — the rows this script prints are what the benchmark
# should say. No savings claim is made here.
#
# Usage: bench/experiment-retry-feedback.sh [-k] [-n runs] [task...]
#   -n  runs per arm per task (default 1)
#   -k  keep the run dirs (path printed at the end); removed by default
# Needs claude + pi on PATH (and `jq`; uses timeout/gtimeout when present).
#
# Protocol per (task, arm, run):
#   1. fresh copy of bench/quick/tasks/<task>/repo, git-committed as base;
#   2. pi call 1 drafts the implementation (text mode, same argv as run.sh);
#   3. verify = the task's hidden check.py, staged in a private dir OUTSIDE
#      the run tree and deleted again before the next model call (see
#      verify); its raw output stays there too — only verify_excerpt's
#      allowlisted output is ever copied toward a prompt;
#   4. on verify failure build the arm's feedback and run pi call 2 (the
#      retry) — json mode, so the retry call's token usage is recorded
#      (documented text-mode gap otherwise; both arms instrumented
#      identically, so the A/B comparison is internally valid);
#   5. verify again -> retry_success.
# One JSON row per run on stdout, then a per-arm summary on stderr.
#
# Rows: task, arm (A|B), feedback (raw-tail|numbered-instruction), run,
#   verify_initial_pass, retried, retry_success (null when no retry was
#   needed), pi_retry_tokens (json usage of the retry call, or null),
#   pi_retry_exit, claude_instruction_cost_usd (arm B instruction call,
#   null for arm A), claude_instruction_result (arm B instruction text),
#   feedback_dropped_lines (tail lines verify_excerpt's allowlist removed —
#   the count is large by design: tracebacks and the assertion diff are
#   dropped, so read it as "how much the model did NOT see", not as a
#   contamination alarm; kept lines are structural by construction),
#   author_touched_repo (arm B: the instruction author edited the graded
#   copy while "writing an instruction" — treat that row as contaminated;
#   null for arm A, which has no author call).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
n=1; keep=0
while getopts kn: o; do case "$o" in k) keep=1 ;; n) n=$OPTARG ;; *) exit 2 ;; esac; done
shift $((OPTIND - 1))
case "$n" in ''|*[!0-9]*) echo "runs (-n) must be a positive integer" >&2; exit 2 ;; esac
[ "$n" -ge 1 ] || { echo "runs (-n) must be >= 1" >&2; exit 2; }
tasks=("$@"); [ "${#tasks[@]}" -gt 0 ] || { tasks=(); for d in "$here"/quick/tasks/*/; do tasks+=("$(basename "$d")"); done; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
# `|| true` keeps the missing-pi guard reachable under set -e (a bare
# failing command substitution in an assignment exits with status 1 and no
# message, which is what the reviewer found on the first form).
real_pi="$(command -v pi || true)"; [ -n "$real_pi" ] || { echo "pi not on PATH" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || { echo "claude not on PATH" >&2; exit 2; }
TMO=(); for c in timeout gtimeout; do command -v "$c" >/dev/null 2>&1 && { TMO=("$c" 1500); break; }; done
VTO=(); for c in timeout gtimeout; do command -v "$c" >/dev/null 2>&1 && { VTO=("$c" "${EXP_VERIFY_TIMEOUT:-120}"); break; }; done
out="$(mktemp -d "${TMPDIR:-/tmp}/pi-retry-exp.XXXXXX")"
# The grader and its raw output live OUTSIDE the run tree. Both models get
# read/bash tools with their cwd inside the run tree, so a grader at
# $d/check.py was one `../check.py` away (round-2 review printed the
# grading tests that way), and $d/verify.log was equally reachable at
# ../verify.log — unittest tracebacks quote the grader's own source there.
# Neither file is therefore placed in the run dir: verify() stages the
# grader here and deletes it again before returning, and the raw log stays
# here for the lifetime of the run with mode 000 while a model can be
# running (under -k its directory is printed alongside the run dir; it is
# deliberately NOT copied into the run tree, because sibling run dirs are
# `../` from a model that is still running). Position and permission are
# both needed: the models run as this same user, so 000 is a deterrent, not
# a wall — the wall is that the grader file does not exist at all during a
# model call.
priv="$(mktemp -d "${TMPDIR:-/tmp}/pi-retry-exp-priv.XXXXXX")"
[ "$keep" = 1 ] || trap 'rm -rf "$out" "$priv"' EXIT

verify() {  # run-dir task-dir priv-dir -> rc
  # The grader is copied into the private dir, executed with the repo on
  # PYTHONPATH but never inside it, and DELETED before returning: during
  # every model call there is no check.py on disk in anything the model can
  # traverse to from its cwd. The raw log stays here, but it is chmod 000
  # while a model can run — same user, so "outside the run tree" alone is
  # position, not permission (round-2 finding: a read channel needs both).
  local d=$1 t=$2 p=$3 rc=0
  mkdir -p "$p"; chmod 700 "$p" 2>/dev/null || true
  chmod 600 "$p/verify.log" 2>/dev/null || true
  cp "$t/check.py" "$p/check.py"
  ( cd "$d/repo" && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$d/repo" \
      ${VTO[@]+"${VTO[@]}"} python3 "$p/check.py" ) > "$p/verify.log" 2>&1 || rc=$?
  rm -f "$p/check.py"
  chmod 000 "$p/verify.log" 2>/dev/null || true
  return "$rc"
}

# Excerpt of the raw verify output that is safe to paste into a pi/claude
# prompt. ALLOWLIST, not a denylist: the round-2 review measured that the
# old denylist (drop the run-dir path, drop 'check.py', drop 4-space lines)
# still handed the oracle over at column 0 — unittest prints the assertion
# diff there, so `+ ['a""b']` (the hidden expected value), the test names
# and `Ran 8 tests` all reached both prompts while the leak counter read a
# tidy 6. So: keep unittest's separators, its FAIL/ERROR headers with the
# `(__main__.T.<name>)` tail stripped, its OK/Ran/FAILED summaries, and the
# terminal `SomeError: message` line. That last class is a deliberate
# exception to "no failure detail": without it an import-time failure
# (ledger-export: `ModuleNotFoundError: No module named 'ledger.export'`)
# sanitizes down to nothing and the retry measures nothing. It names the
# missing symbol, which a PINPOINT brief already states, and it is the
# code's own exception, not the grader's assertion. What is never kept is
# the grader's quoted source and the assertion diff — the expected values
# themselves — which is what `AssertionError`, `First/Second differing`,
# the `[+-] ` diff lines and any line containing `!=` remove. A second pass
# re-checks the kept lines against the private/run paths and 'check.py' so
# a future unittest line cannot smuggle a path through the allowlist.
verify_excerpt() {  # priv-dir -> excerpt on stdout; sets SANITIZED_DROPPED
  local p=$1 before after nb=0 na=0
  SANITIZED_DROPPED=0
  [ -s "$p/verify.log" ] || { echo "(no verify output)"; return; }
  # The log is 000 while a model can run (verify leaves it that way); the
  # harness is the only reader, and it puts the mode back on the way out.
  chmod 600 "$p/verify.log" 2>/dev/null || true
  before="$(tail -n 40 "$p/verify.log")"
  chmod 000 "$p/verify.log" 2>/dev/null || true
  after="$(printf '%s\n' "$before" \
    | sed -E 's/^((FAIL|ERROR): [^ ]+) \(.*\)$/\1/' \
    | grep -E '^(OK|FAILED|Ran |TEST/|=+$|-+$|(FAIL|ERROR): [A-Za-z0-9_.]+$|[A-Za-z_][A-Za-z0-9_.]*(Error|Exception|Warning|Interrupt|Exit): )' \
    | grep -vE '^(AssertionError|First |Second |[+-]\s|[-+?]\s|\s+[-+])' \
    | grep -v '!=' || true)"
  # Path scrubbing, not path filtering: the line
  # `ImportError: cannot import name 'over_budget' from 'ledger.report'
  # (/tmp/.../repo/ledger/report.py)` is the most informative thing an
  # import-time failure prints, and the old `grep -vF "$d"` threw the whole
  # line away with it. Any absolute path in a kept line is replaced with
  # `<path>` — pattern-based, because the path python prints in a traceback
  # is not always string-equal to `$out` (TMPDIR ends in a slash, so the
  # run dir is `/T//pi-retry-exp.XXX` on the command line and `/T/pi-retry-
  # exp.XXX` in the traceback, and a literal replace would miss it).
  after="$(printf '%s\n' "$after" \
    | sed -E -e 's#(/[[:graph:]]*)+#<path>#g' -e 's/ \(<path>[^)]*$//' \
    | grep -vF 'check.py' || true)"
  nb="$(printf '%s\n' "$before" | grep -c . || true)"; nb="${nb:-0}"
  if [ -n "$after" ]; then
    na="$(printf '%s\n' "$after" | grep -c . || true)"; na="${na:-0}"
    printf '%s\n' "$after"
  else
    echo "(failure output withheld: no line survived the excerpt allowlist)"
  fi
  SANITIZED_DROPPED=$(( nb > na ? nb - na : 0 ))
}

# pi call, run.sh argv + json mode for token capture. Executes INSIDE the
# per-run repo copy: pi takes no path argument and edits its cwd, exactly
# like run.sh's run_pi — which relies on being invoked from inside the
# target repo. Here the target is the copy, so without this cd pi would
# land in the operator's live tree (measurement void + no run.sh safety
# preflight). The bats stub asserting $PWD ends in /repo guards this.
pi_call() {  # taskfile outfile errfile dir
  local rc=0
  ( cd "$4" && ${TMO[@]+"${TMO[@]}"} "$real_pi" -p --no-session --no-extensions \
      --no-skills --no-prompt-templates --mode json < "$1" > "$2" 2>>"$3" ) || rc=$?
  return "$rc"
}

retry_tokens() {  # jsonl transcript -> {input,output,total}|null
  jq -s -c '
    [.[] | select(.type == "message_end") | select(.message.role == "assistant")] as $m
    | ([$m[].message.usage // {}]) as $u
    | if ($m | length) == 0 then null else {
        input:  ([$u[].input       // 0] | add // 0),
        output: ([$u[].output      // 0] | add // 0),
        total:  ([$u[].totalTokens // 0] | add // 0)
      } end' "$1" 2>/dev/null || echo null
}

run_one() {  # task arm i
  local task=$1 arm=$2 i=$3 d="$out/$1-$2-$3" t="$here/quick/tasks/$1"
  # Grader + raw verify output live in the private dir, never in $d (see
  # verify): a model with read/bash tools and cwd $d/repo or $d/author reaches
  # anything in $d through `../`.
  local p="$priv/$1-$2-$3"
  # The command string named in the retry framing. run.sh interpolates the
  # operator's real --verify; the real check here is hidden, so the name is
  # a decoy that shares no substring with the grading file (naming check.py
  # would tell a model with read tools what to go look for, and would make
  # the leak assertion in quick.bats uncheckable). Both arms share the
  # string, so A/B symmetry holds.
  local verify_cmd='python3 _verify.py'
  mkdir -p "$d/cfg" "$d/author" "$p"
  cp -R "$t/repo" "$d/repo"
  ( cd "$d/repo" && git init -q -b exp && git add -A && git -c user.email=e@e -c user.name=e commit -qm base )
  # run.sh prepends this timeout guidance to the task file; reproduced.
  { cat "$t/prompt.md"
    printf '\n\nWhen running tests, builds or servers with the bash tool, always pass its timeout parameter (in seconds): about 120 for a single test file, more for a full suite.\n'
  } > "$d/task.txt"

  local pass1=false retried=false retry_success=null pi_tokens=null pi_retry_exit=null
  local claude_cost=null claude_instr=null dropped=0 author_touched=null
  pi_call "$d/task.txt" "$d/pi1.jsonl" "$d/pi1.err" "$d/repo" || true
  local vrc=0; verify "$d" "$t" "$p" || vrc=$?
  if [ "$vrc" -eq 0 ]; then pass1=true; else
    retried=true
    verify_excerpt "$p" > "$d/excerpt.txt"
    dropped="$SANITIZED_DROPPED"
    if [ "$arm" = A ]; then
      # Same framing as skills/delegate/run.sh's retry (arm-A control); the
      # sanitized excerpt stands in for the raw tail (see verify_excerpt).
      { cat "$d/task.txt"
        printf '\n\nThe verification command `%s` failed (exit %s) with:\n' "$verify_cmd" "$vrc"
        cat "$d/excerpt.txt"
        printf '\nFix the cause in the code. Do not change the verification command or weaken tests.\n'
      } > "$d/retry.txt"
    else
      { cat "$d/task.txt"
        printf '\n\nThe verification command `%s` failed (exit %s) with:\n\n' "$verify_cmd" "$vrc"
        cat "$d/excerpt.txt"
        printf '\nWrite at most 5 numbered, concrete instructions that fix exactly these defects in the code (name the file/function/condition to change). Output ONLY the numbered list.\n'
      } > "$d/instruct-prompt.txt"
      local irc=0
      # The author only writes text, so it runs in an empty dir OUTSIDE the
      # graded copy and the repo's work state is snapshotted around the
      # call: if it edits $d/repo anyway, the row flags author_touched_repo
      # and the analyst discards it (a silent edit would inflate arm B's
      # retry_success while claude_instruction_cost_usd under-prices it).
      git -C "$d/repo" status --porcelain > "$d/pre-author.status" 2>/dev/null || : > "$d/pre-author.status"
      ( cd "$d/author" && CLAUDE_CONFIG_DIR="$d/cfg" ${TMO[@]+"${TMO[@]}"} claude -p --output-format json \
          --model "${CLAUDE_MODEL:-claude-sonnet-5-5}" --permission-mode auto \
          < "$d/instruct-prompt.txt" > "$d/instruct.json" 2> "$d/instruct.err" ) || irc=$?
      git -C "$d/repo" status --porcelain > "$d/post-author.status" 2>/dev/null || : > "$d/post-author.status"
      author_touched=true
      cmp -s "$d/pre-author.status" "$d/post-author.status" && author_touched=false
      if [ "$irc" -eq 0 ] && jq -e '(.result // "") | length > 0' "$d/instruct.json" >/dev/null 2>&1; then
        claude_cost="$(jq -c '.total_cost_usd // 0' "$d/instruct.json")"
        claude_instr="$(jq -c '.result // null' "$d/instruct.json")"
        { cat "$d/task.txt"
          printf '\n\nThe verification command `%s` failed (exit %s). Address every one of these instructions:\n' "$verify_cmd" "$vrc"
          jq -r '.result' "$d/instruct.json"
          printf '\nFix the cause in the code. Do not change the verification command or weaken tests.\n'
        } > "$d/retry.txt"
      else
        # Claude failed to author: record it, retry on the arm-A control text
        # so the pi side still runs, and flag the fallback for the analyst.
        claude_cost="null"; claude_instr="\"instruct-call-failed\""
        { cat "$d/task.txt"
          printf '\n\nThe verification command `%s` failed (exit %s) with:\n' "$verify_cmd" "$vrc"
          cat "$d/excerpt.txt"
          printf '\nFix the cause in the code. Do not change the verification command or weaken tests.\n'
        } > "$d/retry.txt"
      fi
    fi
    local rrc=0; pi_call "$d/retry.txt" "$d/pi2.jsonl" "$d/pi2.err" "$d/repo" || rrc=$?
    pi_retry_exit="$rrc"
    pi_tokens="$(retry_tokens "$d/pi2.jsonl")"
    local vrc2=0; verify "$d" "$t" "$p" || vrc2=$?
    [ "$vrc2" -eq 0 ] && retry_success=true || retry_success=false
  fi
  # The model calls for this run are done; make the raw log readable again
  # for the analyst (it is chmod 000 while a model can be running).
  chmod 600 "$p/verify.log" 2>/dev/null || true
  jq -cn --arg task "$task" --arg arm "$arm" \
    --arg feedback "$( [ "$arm" = A ] && echo raw-tail || echo numbered-instruction )" \
    --argjson run "$i" --argjson pass1 "$pass1" --argjson retried "$retried" \
    --argjson retry_success "$retry_success" --argjson pi_tokens "$pi_tokens" \
    --argjson pi_retry_exit "${pi_retry_exit:-null}" \
    --argjson claude_cost "${claude_cost:-null}" --argjson claude_instr "${claude_instr:-null}" \
    --argjson feedback_dropped_lines "${dropped:-0}" --argjson author_touched "${author_touched:-null}" \
    '{task:$task,arm:$arm,feedback:$feedback,run:$run,verify_initial_pass:$pass1,
      retried:$retried,retry_success:$retry_success,pi_retry_tokens:$pi_tokens,
      pi_retry_exit:$pi_retry_exit,claude_instruction_cost_usd:$claude_cost,
      claude_instruction_result:$claude_instr,
      feedback_dropped_lines:$feedback_dropped_lines,author_touched_repo:$author_touched}' > "$d/row.json"
}

for task in "${tasks[@]}"; do for arm in A B; do for i in $(seq 1 "$n"); do
  run_one "$task" "$arm" "$i" &
done; done; done
wait

cat "$out"/*/row.json | jq -s -c '.[]'
echo "--- summary ---" >&2
cat "$out"/*/row.json | jq -s -r '
  group_by(.arm)[] | "arm \(.[0].arm) (\(.[0].feedback)): runs=\(length) initial_pass=\([.[]|select(.verify_initial_pass)]|length) retried=\([.[]|select(.retried)]|length) retry_success=\([.[]|select(.retry_success==true)]|length) pi_retry_tokens_total=\([.[]|.pi_retry_tokens.total|select(.!=null)]|add//0) claude_instruction_cost=\([.[]|.claude_instruction_cost_usd|select(.!=null)]|add//0)"' >&2
if [ "$keep" = 1 ]; then
  # The raw verify logs stay in the private dir rather than being copied
  # into the run dir: $d/<task>-<arm>-<run> dirs are siblings under $out, so
  # a model still running in one run could `cat` a finished run's copied
  # log — and that log quotes the grader's source. Both paths are printed;
  # the run dir has the prompts/rows, the private dir has the raw tails.
  echo "runs kept in $out" >&2
  echo "raw verify logs kept in $priv" >&2
fi
