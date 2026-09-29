---
name: pi-oneshot
description: Delegates a self-contained task to the pi coding agent in a single headless `pi -p` invocation — text mode, full toolset, no review loop. Use when the user asks to "delegate to pi", to run a "pi task", to "use pi for" a job, or to run "pi oneshot" — a quick task you want done in one shot and then summarized.
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
request through as `$ARGUMENTS` (the full task description):

```bash
"$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates "$ARGUMENTS"
```

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

### Timeouts and the Bash tool ceiling

A single pi run can be long (tens of minutes). Claude Code's Bash tool kills
a foreground command at its timeout: the default is **2 minutes**
(`BASH_DEFAULT_TIMEOUT_MS` = 120000 ms) and the ceiling is **10 minutes**
(`BASH_MAX_TIMEOUT_MS` = 600000 ms), with values above the ceiling silently
clamped. So a bare `pi` call above — left to the Bash tool's default — is
killed at 2 minutes. Handle this on **two layers**:

1. **Script-level (this skill's job):** wrap the `pi` call in `timeout`
   (or `gtimeout` on macOS) so a runaway run is bounded by *this* skill, not
   by the Bash tool. `--kill-after` escalates to SIGKILL if pi ignores the
   SIGTERM. Resolve the binary and invoke:

   ```bash
   if command -v timeout >/dev/null 2>&1; then
     timeout --kill-after="${PI_KILL_AFTER:-30}" ${PI_TIMEOUT:-1800} \
       "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates "$ARGUMENTS"
   elif command -v gtimeout >/dev/null 2>&1; then
     gtimeout --kill-after="${PI_KILL_AFTER:-30}" ${PI_TIMEOUT:-1800} \
       "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates "$ARGUMENTS"
   else
     echo "WARNING: neither timeout nor gtimeout on PATH; pi call is unbounded — run is limited only by the Bash tool ceiling" >&2
     "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates "$ARGUMENTS"
   fi
   ```

   - `PI_TIMEOUT` (default **1800** s) is the SIGTERM deadline; `PI_KILL_AFTER`
     (default **30** s) is the grace window before SIGKILL.
   - Exit **124** (SIGTERM at `PI_TIMEOUT`) and **137** (SIGKILL at
     `PI_TIMEOUT + PI_KILL_AFTER`) both mean *"pi timed out"* — report it
     that way, not as a crash. Any other non-zero exit is a real failure
     (auth, model unavailable, crash) — relay verbatim per the Reporting back
     section.
   - If neither binary exists the call runs **unbounded** at the script level
     — warn the user (as above), note the run is then limited only by the
     Bash tool's 10-minute ceiling (next layer), and state the 124/137
     semantics do not apply. Install GNU coreutils (`brew install coreutils`
     on macOS for `gtimeout`) to get the bound back.

2. **Bash-tool-level (Claude's job):** a wrapped call with
   `PI_TIMEOUT=1800` is bounded to ~30 minutes, which is **above** the Bash
   tool's 10-minute foreground ceiling. So the Bash tool must be told to
   **run the command in the background and poll** — pass
   `run_in_background: true` to the Bash tool and then poll the background
   task's output file (the `backgroundTaskId`'s output via `Read`) until the
   run finishes. Passing a larger foreground `timeout` does **not** work: it
   is clamped to 600000 ms (10 min), so a long task would still be killed.
   The background path is the only way a single long pi run survives.

- **Prompt transport:** if the task description is long (more than a few
  hundred words), pass it via stdin instead of as a positional argument.
  The timeout wrapper wraps only `pi`, not `printf`, so the pipe stays
  `printf '%s' "$ARGUMENTS" | timeout --kill-after="${PI_KILL_AFTER:-30}" ${PI_TIMEOUT:-1800} "$PI_BIN" -p --no-session ...`.
  This avoids `E2BIG` on Linux where a single argv element is capped at 128
  KiB (`MAX_ARG_STRLEN`). Short prompts (a sentence or two) work fine as a
  positional argument.

### Model

- If the user explicitly named a model, append `--model <model>` to the
  **same wrapped invocation** — the timeout wrapper wraps the whole command
  (… `"$PI_BIN" … "$ARGUMENTS" [--model X]`), so the model-passthrough variant
  is bounded identically.
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
