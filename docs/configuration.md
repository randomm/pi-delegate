# Configuration

All knobs are environment variables read by `orchestrate.sh` (and the
`pi-oneshot` skill). None are required — the defaults work.

## Environment variables

### `PI_TIMEOUT` — seconds allowed per pi invocation (default 1800)

**Applies to:** both skills — `pi-oneshot`'s single call and each
`pi-review-loop` pi call use this wrapper.

Every pi call is wrapped in
`timeout --kill-after=${PI_KILL_AFTER:-30} ${PI_TIMEOUT:-1800}` (falling back
to `gtimeout` on macOS; if neither binary exists the call runs **unbounded**
without a time limit and a **warning** is logged once — the run is then
bounded only by Claude Code's Bash-tool timeout). Must be a positive integer,
or the driver exits 2.

### `PI_KILL_AFTER` — SIGKILL escalation grace window (default 30)

**Applies to:** both skills (the same wrapper as `PI_TIMEOUT` above).

Seconds to wait after the `PI_TIMEOUT` SIGTERM before escalating to SIGKILL
(passed to timeout as `--kill-after`). A pi (or its child) that ignores
SIGTERM is SIGKILLed at `PI_TIMEOUT + PI_KILL_AFTER`; both resulting exit
codes are classified as a timeout. Must be a positive integer, or the driver
exits 2. Ignored on the unbounded path. Known limit: processes that detach
into their own session (`setsid`/daemons) escape the timeout entirely.

### Timeout exit codes: 124 and 137 (SIGTERM at `PI_TIMEOUT`, SIGKILL escalation)

- **Exit 124** — pi was SIGTERMed at `PI_TIMEOUT` seconds (SIGTERM at `PI_TIMEOUT`): the call **timed out**.
- **Exit 137** — pi ignored SIGTERM and was SIGKILLed (SIGKILL escalation) at `PI_TIMEOUT + PI_KILL_AFTER`:
  the call **timed out**.

The driver reports both as `pi timed out after 1800s (SIGKILL after a further 30s if needed)` — the message interpolates the caller's `PI_TIMEOUT`/`PI_KILL_AFTER` values (shown here with their defaults); the clause documents the second phase and its cost.

Any other non-zero exit is a genuine pi failure and is relayed verbatim. On
the unbounded path (no `timeout`/`gtimeout` binary) there is no 124/137 at
all — only Claude Code's Bash-tool timeout bounds the run.

These apply to both skills: `pi-oneshot`'s single pi call uses the identical
wrapper, and each loop call in `pi-review-loop` is wrapped the same way.

### `PI_DIFF_MAX_BYTES` — max diff bytes embedded in a review prompt (default 90000)

**Applies to:** `pi-review-loop` only (review and fix prompts).

Larger content is truncated to whole lines with a notice
(`[truncated: N of M bytes shown (PI_DIFF_MAX_BYTES=…)]`). The lower default
(90000, not 100000) keeps the total prompt well under `MAX_ARG_STRLEN`
(131072 on Linux). The same cap applies to the reviewer transcript threaded
into a fix prompt.

### `PI_PROMPT_MAX_BYTES` — max total bytes for a single pi call (default 120000)

**Applies to:** `pi-review-loop` only.

All argv args + stdin combined. The prompt itself is passed via **stdin**
(piped to pi), not as an argv string, which already avoids `E2BIG` for large
prompts; this check is a second, explicit guard for the combined size. If the
total exceeds it, the driver produces a clear `PI_ERROR` (exit 3) instead of
an opaque `E2BIG` from the kernel.

### `PI_CONTEXT_FILES` — opt back into pi's context files (unset by default)

**Applies to:** `pi-review-loop` only.

When set to a non-empty value (e.g. `1`), pi's context files (AGENTS.md /
CLAUDE.md) are loaded for every pi call. Unset by default: every call passes
`--no-context-files` so the target repo's agent instructions do not override
the role prompts.

### `PI_DELEGATE_UNSAFE` — opt out of the safety preflight (unset by default)

**Applies to:** both skills (the preflight runs in `orchestrate.sh` and in
the `pi-oneshot` preflight block).

Set to `1` to skip all three safety guards: allow running on the default
branch, allow secret-looking files, do not neutralise `git push`. Only set
this when you have arranged real isolation (a disposable clone/worktree or a
container) and understand that pi has no sandbox. See
[troubleshooting → REFUSED](troubleshooting.md#refused--safety-preflight).

## Flags (`orchestrate.sh`)

```bash
orchestrate.sh --model <model> --max-rounds <N> "<task description>"
```

Both flags apply to `pi-review-loop` only (`pi-oneshot` has no loop).

- `--model <model>` — forwarded to every pi invocation in the loop; omit to
  use pi's configured default.
- `--max-rounds <N>` — review-round budget, 1–3, default 3, hard cap 3.
  At `--max-rounds 1` there is a single review round and no fix round — any
  blocking verdict at that round terminates the loop immediately.

Models are not pinned: `--model` passthrough is the only selection
mechanism, and after every successful pi call the driver logs the reported
`provider/model` pair to stderr (e.g. `pi call 1: provider/model
anthropic/claude-opus-4`).

## Long runs under Claude Code's Bash tool

**Applies to:** both skills.

Claude Code's Bash tool imposes a per-foreground-call timeout
(`BASH_DEFAULT_TIMEOUT_MS` defaults to 120000 ms / 2 minutes;
`BASH_MAX_TIMEOUT_MS` defaults to 600000 ms / 10 minutes; values above the
max are silently clamped). A full loop's worst-case wall clock is
`6 × (PI_TIMEOUT + PI_KILL_AFTER)` — at the defaults `6 × (1800 + 30)` s =
10980 s ≈ 183 min (~3 h) — and a single pi-oneshot task can legitimately
run far longer than the 10-minute foreground ceiling, so one foreground
call cannot cover the run.

Strategy (verified by the issue #69 real-claude experiments): **launch
detached, record the pid, wait with foreground bounded calls.**

- **Do not** use the Bash tool's background-task mode: in headless
  `claude -p` the session ends its turn and the background task is killed
  (the task's output file ends with `[killed]`), so the run dies with the
  session. The agent must also **never end the turn or reply** before the
  completion signal has been read.
- **Do not** try to fix long runs by passing a larger foreground `timeout` —
  values above the ceiling are silently clamped.
- **Launch detached** in one foreground Bash call: first remove stale
  helper files from a previous run (`rm -f "$LOG" "$PID_FILE" "$RC_FILE"`)
  so a leftover completion signal cannot look like a completed run, then
  redirect the invocation's output to a log file (`$LOG`) and record the
  process pid to a file (`$PID_FILE`). The helper files must live **outside
  the target repo** (e.g. a `mktemp -d` directory under the system temp
  dir) — untracked files inside the repo enter the reviewed diff. For
  `pi-review-loop` the completion signal is the final JSON summary line in
  `$LOG` (check the last line with `tail -n 1`); for `pi-oneshot` (no
  JSON summary) the invocation is wrapped so its exit code is written to
  an exit-code file (`$RC_FILE`). $LOG grows as pi streams output and can
  be deleted after the run.
- **Wait in foreground, bounded calls**: repeat a foreground Bash call
  with `timeout` just under the 600000 ms ceiling (the Bash tool's
  `timeout` parameter, e.g. 595000); each call exits as soon as the
  completion signal appears (JSON summary line / exit-code file) or the
  recorded pid is gone. If the pid is gone and no valid completion signal
  exists, the run died without completing — report it as **failed** with
  the log tail (e.g. `tail -n 20 "$LOG"`), and never present a result as
  if the run had completed. If a wait call is killed at
  the ceiling, start the next — the detached run survives and the wait
  resumes from the same files. Worst case at the defaults:
  `6 × (1800 + 30)` s = 10980 s ≈ **183 min** (~3 h), covered by enough
  10-minute wait calls.
- **Stop / abort (before ending the turn)**: use the pid file to kill the
  run **and its children** (orchestrate.sh has no signal trap; a plain
  `kill` of the loop can leave pi children). macOS has no `setsid`, so
  walk the child tree level by level (`ps -axo pid,ppid`), SIGTERM, then
  SIGKILL stragglers after 5 s. **State does not persist between Bash
  tool calls**: start the block with `D=` set to the `RUN_DIR` the
  launch call printed (the `D=$(mktemp -d)` directory), derive the pid
  file from `$D`, and apply the **pid-reuse guard** before killing — a
  recycled pid would hit an unrelated process. The loop variant guards
  for `orchestrate.sh` in the pid's command line; the oneshot variant
  guards for the pi binary (`$PI_BIN`). The loop's verbatim block:
```bash
D="<the RUN_DIR printed at launch>"
PID_FILE="$D/review-loop.pid"
PID="$(cat "$PID_FILE")"
# Pid-reuse guard: only proceed if the recorded pid still belongs to the pi
# process (a plain `kill` on a recycled pid would hit an unrelated process).
cmd="$(ps -o command= -p "$PID" 2>/dev/null || true)"
if ! [[ "$cmd" == *orchestrate.sh* ]]; then
  echo "pid $PID no longer runs orchestrate.sh — skipping kill"
else
  front="$PID"
  all="$PID"
  for _ in 1 2 3 4 5; do
    next=""
    for p in $front; do
      next="${next}$(ps -axo pid,ppid | awk -v r="$p" '$2 == r { print $1 }')"
    done
    [ -n "$next" ] || break
    all="$all $next"
    front="$next"
  done
  for p in $all; do
    kill "$p" 2>/dev/null || true
  done
  sleep 5
  for p in $all; do
    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true
  done
fi
```

Both SKILL.md files carry a verbatim copy of this block (each skill must
be self-contained); the BATS suites assert the copies are identical.
This was verified on macOS against a multi-level process tree.
