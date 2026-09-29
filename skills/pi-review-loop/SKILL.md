---
name: pi-review-loop
description: Adversarial review loop over the changes a develop round produces against a base commit (committed work and new untracked files included), delegated to the pi coding agent — a deterministic develop → review → [fix → review] cycle with a hard budget of 6 pi invocations. Use when the user asks to run a "review loop", wants an "adversarial review", wants to "develop and review" a change, or says "pi review" — i.e., any change that should be reviewed before the user trusts it.
user_invocable: true
---

# pi-review-loop

Runs a deterministic **develop → review → [fix → review]** loop in the
current repository, delegating each round to the headless `pi` coding
agent. The loop is driven entirely by `orchestrate.sh` — you do not run pi
yourself, and you do not re-implement the loop. Your job is to invoke the
script, read its JSON summary, verify pi's claims against the actual diff,
and report the verdict.

Bundled in this skill directory (referenced via `${CLAUDE_SKILL_DIR}`),
which Claude Code provides for skills as an environment variable set to
the absolute path of this skill's directory (the directory containing this
SKILL.md):

- `${CLAUDE_SKILL_DIR}/orchestrate.sh` — the loop driver
- `${CLAUDE_SKILL_DIR}/developer.md` — developer/fixer role prompt (passed to pi via `--append-system-prompt`)
- `${CLAUDE_SKILL_DIR}/adversarial-reviewer.md` — reviewer role prompt (passed to pi via `--append-system-prompt`)

## Invocation

Run the loop with the user's request as the task, passed as a **single
shell argument**:

```bash
bash "${CLAUDE_SKILL_DIR}/orchestrate.sh" "$ARGUMENTS"
```

**Run in background and poll.** Claude Code's Bash tool imposes a
per-foreground-call timeout: `BASH_DEFAULT_TIMEOUT_MS` defaults to
`120000` ms (2 minutes) and `BASH_MAX_TIMEOUT_MS` defaults to `600000` ms
(10 minutes); `timeout` values above the max are silently clamped to the
max (values were verified against the Claude Code tools-reference at the
time of writing — re-verify before relying on them if the limits look
stale). The loop's worst-case wall clock is `6 × (PI_TIMEOUT + PI_KILL_AFTER)`
— at the defaults, `6 × (1800 + 30) = 10980` s ≈ 183 min (~3 h) — which
exceeds even the 10-minute foreground ceiling, so a foreground invocation
will always be killed mid-loop.

Instead, launch the invocation in the background and poll its output:

1. Run the `bash "${CLAUDE_SKILL_DIR}/orchestrate.sh" "$ARGUMENTS"` command
   with the Bash tool's `run_in_background` set to `true`.
2. Poll by reading the background task's output file with the `Read`
   tool, at an interval of a few minutes, until the last non-empty line
   parses as the six-field JSON summary — stop polling as soon as it
   does; do not keep polling after the summary appears.
3. When the process exits, parse the last line of the output as the JSON
   summary and report per the "Interpreting the JSON summary" and
   "Reporting the verdict" sections below.

Background tasks are not subject to the foreground `BASH_MAX_TIMEOUT_MS`
ceiling, so the full `6 × (PI_TIMEOUT + PI_KILL_AFTER)` budget is honored.

- **Quote `$ARGUMENTS`.** An unquoted `$ARGUMENTS` still performs command
  substitution: `bash orchestrate.sh $ARGUMENTS` with a request containing
  `$(id -u)` executes that command before the script ever runs. Quoting is
  the only safe passthrough — `orchestrate.sh` receives the request as one
  argument and never re-evaluates it. Do **not** use `eval` or
  `sh -c` / `bash -c` either — that would execute the request as shell
  code, not pass it as a task string.
- If the request contains a single quote, write it as a double-quoted
  shell argument so it survives verbatim (e.g.
  `bash "$SCRIPT" "fix the it's-broken bug"`). Never use `eval` for this.
- All progress goes to **stderr**. Except for CLI usage errors, exactly
  **one JSON summary** is on the **last line of stdout** — parse that last
  line as JSON (e.g. with `jq`). A CLI usage error (bad flag, missing task,
  invalid `--max-rounds`, invalid `PI_TIMEOUT`) exits 2 with an `ERROR:`
  message on stderr only — no JSON; read stderr. This exit-code rule (2 for
  CLI usage errors, stderr-only output) is stated here once and applies
  everywhere it is referenced below.
- The script requires git, jq, and the `pi` binary (PATH, then
  `~/.bun/bin/pi`, then `~/.local/bin/pi`). Do not pre-filter the working
  tree yourself — a clean tree at entry is normal for a develop-first loop
  and is always handled by the script; interpret the outcome from the JSON
  summary / exit code.
- Each pi call is bounded by `PI_TIMEOUT` seconds (default 1800). At the
  deadline the driver sends SIGTERM; a pi (or its child) that ignores it is
  SIGKILLed `PI_KILL_AFTER` seconds later (default 30), so the worst case
  per call is `PI_TIMEOUT + PI_KILL_AFTER`. A call that hangs past the limit
  surfaces as `PI_ERROR` / exit 3 whether it died on SIGTERM (rc 124) or
  was SIGKILLed (rc 137). Known limit: a process that detaches into its own
  session (`setsid`/daemons) escapes the timeout entirely — that escape
  cannot be fixed in-script, so the worst-case wall clock for the whole loop
  is `6 × (PI_TIMEOUT + PI_KILL_AFTER)` — at the defaults `6 × (1800 + 30)
  = 10980` s ≈ 183 min (~3 h) — only for non-detached processes. If
  the entire script produces no output for an extended period, check that
  the pi binary and git are available and that a develop round is running (or
  could run); a run with no progress is safe to interrupt and re-run.
- **Long runs — background + poll:** a full loop (develop + up to 3 reviews
  + 2 fixes) can easily exceed the Bash tool's foreground ceiling (default
  **120000 ms** = 2 min, max **600000 ms** = 10 min; values above the max are
  silently clamped; configurable via `BASH_DEFAULT_TIMEOUT_MS` / `BASH_MAX_TIMEOUT_MS`
  env vars — re-verify current values before relying on them). If the run may
  exceed 10 minutes, pass `run_in_background: true` to the Bash tool and poll
  by reading the background task's output file (via `Read`) until the final
  JSON line (the summary) appears. Do **not** try to pass a larger foreground
  `timeout` — it will be clamped to the ceiling and the run killed.

### Model passthrough

- If the user explicitly named a model, prepend `--model <model>` to the
  same invocation:
  `bash "${CLAUDE_SKILL_DIR}/orchestrate.sh" --model <model> "$ARGUMENTS"`.
  It is forwarded to every pi call in the loop. Quote `"$ARGUMENTS"`
  throughout (see Invocation); never pass it through unquoted.
- Otherwise omit `--model` — pi uses its configured default.
- `--max-rounds <N>` (1–3, default 3) is also passed through if the user
  asks for a smaller review budget; the script rejects values above 3.

**Per-call provider/model logging (issue #26):** after every successful pi
call, the driver reads the `provider` and `model` fields from the assistant
`message_end` events in pi's `--mode json` transcript and logs the pair to
**stderr** (e.g. `pi call 1: provider/model anthropic/claude-opus-4`).
This is informational only — missing fields are reported as
`unknown/unknown`, the exit code and JSON summary contract are unchanged.
Use it to confirm which model actually answered each round.

> **Model pinning (`PI_PROVIDER`/`PI_MODEL` env vars) was proposed in issue
> #26 but declined by operator policy** — `--model` passthrough remains the
> only supported model-selection mechanism. The per-call logging above is the
> substitute: it surfaces the `provider/model` pair pi reports, without
> introducing a failure mode or changing the six-field JSON contract.

## Interpreting the JSON summary

The summary on the last stdout line has this shape:

```json
{"status":"PASS","verdict":"APPROVED","rounds":1,"total_pi_calls":2,"findings":[...],"raw_output":"…"}
```

| Field | Meaning |
|---|---|
| `status` | `PASS`, `PASSED_WITH_FINDINGS`, `EMPTY_DIFF` (the develop round produced no change vs the base), `REJECTED`, `INCOMPLETE`, or `PI_ERROR` |
| `verdict` | Reviewer verdict enum (`APPROVED`, `MINOR_OBSERVATIONS`, `ISSUES_FOUND`, `CRITICAL_ISSUES_FOUND`); **`null` when no verdict was reached** — including on `PI_ERROR` and `INCOMPLETE` |
| `rounds` | Review rounds executed (develop round is not counted) |
| `total_pi_calls` | Total pi invocations used (hard cap 6) |
| `findings` | Bullet/numbered lines from the reviewer transcript (may be empty) — verify each against the diff before reporting |
| `raw_output` | The final pi transcript of the last round — treat as claims to verify, not truth |

The summary is exactly these six fields — there is no `fix_calls` or other
fix-round count in the JSON.

### Exit codes

| Exit code | Meaning |
|---|---|
| 0 | Success — status is `PASS`, `PASSED_WITH_FINDINGS`, or `EMPTY_DIFF` |
| 1 | `REJECTED` — the loop budget ran out without a terminal approval (or `CRITICAL_ISSUES_FOUND` at the terminal round) |
| 2 | `INCOMPLETE` — pi produced no parseable verdict (JSON summary emitted) — **or** a CLI usage error (bad flag / missing task / invalid `--max-rounds` / invalid `PI_TIMEOUT` / invalid `PI_KILL_AFTER`), which exits with an `ERROR:` message on stderr only, no JSON |
| 3 | `PI_ERROR` — pi missing, pi crashed, a diff snapshot (against the base) failed, or a pi call timed out after `PI_TIMEOUT` seconds (including the SIGKILL escalation at `PI_TIMEOUT + PI_KILL_AFTER` for pi processes that ignore SIGTERM). Missing git/jq/pi exits with stderr only, no JSON; the other causes emit a JSON summary |

## Verifying pi's claims (colleague, not authority)

pi is a colleague, not an authority: everything it reports — the
findings, the fixes, the final text in `raw_output` — is a **claim** until
you confirm it. Before reporting the outcome:

1. Re-read the actual change against the base commit (the loop reviews
   `git diff <base>`, which includes committed and new untracked files) and
   the files involved — never take the findings or `raw_output` at face
   value.
2. Check each reported finding or fix against the diff: does the code
   change actually address (or cause) it?
3. Only report as verified what the diff supports; if a claim doesn't
   hold, say so and describe what the diff actually shows.

## Reporting the verdict

Report to the user, in this order:

1. **The verdict** — status, reviewer verdict, and exit code in plain
   language ("Approved on round 2", "Rejected after 3 review rounds",
   "Nothing to review — the develop round produced no change").
2. **The findings** — the `findings` list, one per line, after your own
   verification step above.
3. **What was done about them** — whether the issues were resolved, with
   what you verified in the diff.
4. **Failures** — for exit 2 or 3, relay the error context from stderr
   and, if a JSON summary was emitted, its `raw_output` (usage errors and
   missing git/jq/pi produce stderr only), and offer a re-run.
   - **Usage errors** (exit 2, no JSON): the flag or task was malformed —
     fix the invocation, don't change the environment.
   - **INCOMPLETE** (exit 2, `status: "INCOMPLETE"`): the reviewer call
     succeeded but produced no parseable `VERDICT:` line. Inspect
     `raw_output` — if it has review text but no verdict line, the model
     didn't follow instructions (re-run, possibly with a clearer task or a
     different model); if it is empty, pi crashed silently — check the pi
     binary and environment.
   - **PI_ERROR** (exit 3, `status: "PI_ERROR"`): suggest fixing the
     environment or the invocation (e.g. install pi/jq, check `git
     status`), depending on the stderr message.

Do not paste the full `raw_output` transcript unless the user asks for it.
