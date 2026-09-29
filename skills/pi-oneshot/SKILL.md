---
name: pi-oneshot
description: Delegates a self-contained task to the pi coding agent in a single headless `pi -p` invocation — text mode, full toolset, no review loop. Use when the user asks to "delegate to pi", to run a "pi task", to "use pi for" a job, or to "run pi oneshot" — a quick task you want done in one shot and then summarized.
user_invocable: true
---

# pi-oneshot

Runs **one** headless `pi` invocation for a single task, then summarizes
pi's output and reports back. This skill is the lightweight alternative to
`pi-review-loop`: no loop, no verdict parsing, no JSON — just ask pi for a
task, read what it says, and relay it.

## Locating the pi binary

Resolve `pi` the same way `orchestrate.sh` does — `command -v pi` on PATH
first, then the common install locations:

```bash
PI_BIN=""
for candidate in "$(command -v pi 2>/dev/null || true)" "$HOME/.bun/bin/pi" "$HOME/.local/bin/pi"; do
  [[ -n "$candidate" ]] || continue
  if [[ -x "$candidate" ]]; then
    PI_BIN="$candidate"
    break
  fi
done
```

If none is executable, do not try to run pi. Tell the user pi is not
installed (tried: PATH, `~/.bun/bin/pi`, `~/.local/bin/pi`) and suggest:

```
curl -fsSL https://pi.dev/install.sh | sh
```

then offer to re-run once it is available.

## Invocation

Run the task as a single one-shot, stateless call, passing the user's
request through as `$ARGUMENTS` (the full task description). The call is
wrapped in `timeout` exactly the way `orchestrate.sh` wraps its pi calls
(`PI_TIMEOUT` default 1800 s, `PI_KILL_AFTER` default 30 s, `timeout`
preferred with a `gtimeout` fallback, and a probe that treats a missing
`--kill-after` flag as "no timeout binary at all"). Run this single block —
it covers both prompt transports (positional argument and stdin) and both
wrapper states (wrapped and unbounded) safely:

```bash
# NOTE: the `--kill-after=1 1 true` probe is GNU-timeout-specific by design —
# non-GNU shims fail it and fall back to the unbounded path on purpose.
# Discover the timeout binary and probe --kill-after support; if the probe
# fails (e.g. an old macOS `timeout` without the flag) treat it as absent —
# unbounded call + warning — mirroring orchestrate.sh.
TIMEOUT_CMD=""
for cand in timeout gtimeout; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --kill-after=1 1 true >/dev/null 2>&1; then
    TIMEOUT_CMD="$cand"
    break
  fi
done

# One wrapper array for every variant: empty when no usable timeout binary
# exists, so "${wrap[@]+...}" expands to nothing (never to a bare --kill-after)
# and is safe under `set -u` on bash 3.2 (where empty arrays trip -u).
wrap=()
if [ -n "$TIMEOUT_CMD" ]; then
  wrap=("$TIMEOUT_CMD" --kill-after="${PI_KILL_AFTER:-30}" "${PI_TIMEOUT:-1800}")
fi

# Short prompts (a sentence or two): positional argument.
${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates "$ARGUMENTS"

# Long prompts (more than a few hundred words): stdin transport, same wrapper.
# printf '%s' "$ARGUMENTS" | ${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates

# Neither binary (or the probe failed): the wrapper is empty, so the call
# runs unbounded at the script level — bounded only by Claude Code's Bash
# tool timeout (below). Print a warning to stderr before the call:
# echo "warning: no usable timeout binary found; pi call is unbounded at the script level" >&2
```

(`PI_TIMEOUT` and `PI_KILL_AFTER` must be positive integers when set —
non-positive or non-numeric values make the wrapper fail or behave
unpredictably.)

The stdin variant keeps the wrapper around pi only (the pipe feeds pi's
stdin; the timeout command is never piped) and avoids `E2BIG` on Linux
where a single argv element is capped at 128 KiB (`MAX_ARG_STRLEN`).

### Timeout wrapper

When the wrapper runs, a deadline failure surfaces as pi's exit code:

- **124** — pi was SIGTERMed at `PI_TIMEOUT` seconds (SIGTERM at `PI_TIMEOUT`): the call **timed out**.
- **137** — pi ignored SIGTERM and was SIGKILLed at `PI_TIMEOUT + PI_KILL_AFTER` seconds (SIGKILL at `PI_TIMEOUT + PI_KILL_AFTER`): the call **timed out**.

Both mean "timed out" — tell the user the single pi call hit the time limit
and offer a re-run (optionally with a larger `PI_TIMEOUT`). Any other
non-zero exit is a genuine pi failure and is relayed verbatim per the
"Reporting back" section below.

On the **unbounded path** (no usable `timeout`/`gtimeout` binary), the
warning is printed to stderr and there is no script-level deadline —
exit codes 124/137 from this wrapper do not apply; only Claude Code's
Bash tool timeout (below) can kill the run, and a bare non-zero exit is
pi's own.

### Long runs under Claude Code's Bash tool

Claude Code's Bash tool imposes a per-foreground-call timeout: `BASH_DEFAULT_TIMEOUT_MS`
defaults to `120000` ms (2 minutes) and `BASH_MAX_TIMEOUT_MS` defaults to
`600000` ms (10 minutes); `timeout` values above the max are silently clamped
to the max. A single pi task can legitimately run for well over 10 minutes
(the wrapper above defaults to a 30-minute deadline), so a foreground
invocation can be killed mid-run by the Bash tool even when the script-level
timeout would not fire.

So: **do not** try to fix long runs by passing a larger foreground `timeout`
parameter — values above the ceiling are silently clamped. Instead:

1. Run the invocation command with the Bash tool's `run_in_background` set
   to `true`.
2. Poll by reading the background task's output file with the `Read` tool,
   at an interval of a few minutes, until the output stops growing.
3. When pi exits, report per the "Reporting back" section below. On a
   deadline kill, the exit code is 124 or 137 = "timed out" (see above).

Background tasks are not subject to the foreground `BASH_MAX_TIMEOUT_MS`
ceiling, so the full `${PI_TIMEOUT}` budget is honored.

- `-p` — print mode: pi runs headless and emits its final text on stdout.
- `--no-session` — no session is persisted or resumed; each invocation is
  self-contained.
- `--no-extensions --no-skills --no-prompt-templates` — same isolation flags
  `pi-review-loop` uses: installed pi extensions, skills, and prompt templates
  are not loaded, so the task runs exactly as asked. (Context files are still
  loaded by design — the repo's `AGENTS.md`/`CLAUDE.md` conventions are useful to the delegated run.)
- Full default toolset — pi reads, edits, and runs commands as needed.
  Do not restrict tools with `--tools`.
- Plain text mode (no `--mode json`) — stdout is the transcript's final
  text, nothing to parse.

### Model

The same wrapper wraps the **whole** command, model flag included — never
append `--model` to an un-wrapped call:

```bash
${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates "$ARGUMENTS" --model "MODEL"
```

- If the user explicitly named a model, append `--model <model>` to the
  **same wrapped invocation** shown above — the wrapper wraps the whole
  command (… `"$PI_BIN" … "$ARGUMENTS" [--model X]`), so the
  model-passthrough variant is bounded identically.
- Otherwise omit `--model` entirely — pi falls back to its configured
  default.

## Reporting back

After pi exits, **summarize** its output and report it to the user:

- Summarize what pi did and found — do not paste the full transcript
  back unless the user asked for it.
- If pi exited **124** or **137**, it timed out — say so ("pi timed out
  after ${PI_TIMEOUT}s"), suggest raising `PI_TIMEOUT`/`PI_KILL_AFTER` and
  re-running.
- If pi exited non-zero for any other reason, or printed an error (auth
  failure, model unavailable, crash), relay the error verbatim and suggest
  fixing the environment, then re-running.
- Do not loop: this skill makes exactly one pi invocation per request. If
  the result is wrong or incomplete, tell the user and let them decide —
  a new request (or `pi-review-loop` for a reviewed change) is the way
  forward.
