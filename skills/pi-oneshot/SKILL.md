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
- **Prompt transport:** if the task description is long (more than a few
  hundred words), pass it via stdin instead of as a positional argument:
  `printf '%s' "$ARGUMENTS" | "$PI_BIN" -p --no-session ...`. This avoids
  `E2BIG` on Linux where a single argv element is capped at 128 KiB
  (`MAX_ARG_STRLEN`). Short prompts (a sentence or two) work fine as a
  positional argument.

### Model

- If the user explicitly named a model, append `--model <model>` to the
  same invocation.
- Otherwise omit `--model` entirely — pi falls back to its configured
  default.

## Reporting back

After pi exits, **summarize** its output and report it to the user:

- Summarize what pi did and found — do not paste the full transcript
  back unless the user asked for it.
- If pi exited non-zero or printed an error (auth failure, model
  unavailable, crash), relay the error verbatim and suggest fixing the
  environment, then re-running.
- Do not loop: this skill makes exactly one pi invocation per request. If
  the result is wrong or incomplete, tell the user and let them decide —
  a new request (or `pi-review-loop` for a reviewed change) is the way
  forward.
