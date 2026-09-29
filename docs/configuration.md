# Configuration

All knobs are environment variables read by `orchestrate.sh` (and the
`pi-oneshot` skill). None are required — the defaults work.

## Environment variables

### `PI_TIMEOUT` — seconds allowed per pi invocation (default 1800)

Every pi call is wrapped in
`timeout --kill-after=${PI_KILL_AFTER:-30} ${PI_TIMEOUT:-1800}` (falling back
to `gtimeout` on macOS; if neither binary exists the call runs **unbounded**
without a time limit and a **warning** is logged once — the run is then
bounded only by Claude Code's Bash-tool timeout). Must be a positive integer,
or the driver exits 2.

### `PI_KILL_AFTER` — SIGKILL escalation grace window (default 30)

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

Any other non-zero exit is a genuine pi failure and is relayed verbatim. On
the unbounded path (no `timeout`/`gtimeout` binary) there is no 124/137 at
all — only Claude Code's Bash-tool timeout bounds the run.

These apply to both skills: `pi-oneshot`'s single pi call uses the identical
wrapper, and each loop call in `pi-review-loop` is wrapped the same way.

### `PI_DIFF_MAX_BYTES` — max diff bytes embedded in a review prompt (default 90000)

Larger content is truncated to whole lines with a notice
(`[truncated: N of M bytes shown (PI_DIFF_MAX_BYTES=…)]`). The lower default
(90000, not 100000) keeps the total prompt well under `MAX_ARG_STRLEN`
(131072 on Linux). The same cap applies to the reviewer transcript threaded
into a fix prompt.

### `PI_PROMPT_MAX_BYTES` — max total bytes for a single pi call (default 120000)

All argv args + stdin combined. The prompt itself is passed via **stdin**
(piped to pi), not as an argv string, which already avoids `E2BIG` for large
prompts; this check is a second, explicit guard for the combined size. If the
total exceeds it, the driver produces a clear `PI_ERROR` (exit 3) instead of
an opaque `E2BIG` from the kernel.

### `PI_CONTEXT_FILES` — opt back into pi's context files (unset by default)

When set to a non-empty value (e.g. `1`), pi's context files (AGENTS.md /
CLAUDE.md) are loaded for every pi call. Unset by default: every call passes
`--no-context-files` so the target repo's agent instructions do not override
the role prompts.

### `PI_DELEGATE_UNSAFE` — opt out of the safety preflight (unset by default)

Set to `1` to skip all three safety guards: allow running on the default
branch, allow secret-looking files, do not neutralise `git push`. Only set
this when you have arranged real isolation (a disposable clone/worktree or a
container) and understand that pi has no sandbox. See
[troubleshooting → REFUSED](troubleshooting.md#refused--safety-preflight).

## Flags (`orchestrate.sh`)

```bash
orchestrate.sh --model <model> --max-rounds <N> "<task description>"
```

- `--model <model>` — forwarded to every pi invocation in the loop; omit to
  use pi's configured default.
- `--max-rounds <N>` — review-round budget, 1–3, default 3, hard cap 3.

Models are not pinned: `--model` passthrough is the only selection
mechanism, and after every successful pi call the driver logs the reported
`provider/model` pair to stderr (e.g. `pi call 1: provider/model
anthropic/claude-opus-4`).

## Long runs under Claude Code's Bash tool

Claude Code's Bash tool imposes a per-foreground-call timeout
(`BASH_DEFAULT_TIMEOUT_MS` defaults to 120000 ms / 2 minutes;
`BASH_MAX_TIMEOUT_MS` defaults to 600000 ms / 10 minutes; values above the
max are silently clamped). A full loop's worst-case wall clock is
`6 × (PI_TIMEOUT + PI_KILL_AFTER)` — at the defaults ≈ 183 min (~3 h) — and
a single pi-oneshot task can legitimately run far longer than the 10-minute
foreground ceiling, so a foreground invocation is killed mid-run.

Therefore:

- **Do not** try to fix long runs by passing a larger foreground `timeout` —
  values above the ceiling are silently clamped.
- Run the invocation with the Bash tool's `run_in_background: true` and poll
  the background task's output file with the `Read` tool until the final JSON
  summary line (the last line of stdout) appears. Background tasks are not
  subject to the foreground ceiling, so the full per-call budget is honored.
  Worst case at the defaults (`6 × (PI_TIMEOUT + PI_KILL_AFTER)`):
  `6 × (1800 + 30)` s = 10980 s ≈ **183 min** (~3 h).
