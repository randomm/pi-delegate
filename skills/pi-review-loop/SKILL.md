---
name: pi-review-loop
description: Adversarial review loop over the current working-tree diff, delegated to the pi coding agent — a deterministic develop → review → [fix → review] cycle with a hard budget of 6 pi invocations. Use when the user asks to run a "review loop", wants an "adversarial review", wants to "develop and review" a change, or says "pi review" — i.e., any change that should be reviewed before the user trusts it.
user_invocable: true
---

# pi-review-loop

Runs a deterministic **develop → review → [fix → review]** loop over
`git diff HEAD` in the current repository, delegating each round to the
headless `pi` coding agent. The loop is driven entirely by
`orchestrate.sh` — you do not run pi yourself, and you do not re-implement
the loop. Your job is to invoke the script, read its JSON summary, verify
pi's claims against the actual diff, and report the verdict.

Bundled in this skill directory (referenced via `${CLAUDE_SKILL_DIR}`):

- `${CLAUDE_SKILL_DIR}/orchestrate.sh` — the loop driver
- `${CLAUDE_SKILL_DIR}/developer.md` — developer/fixer role prompt (passed to pi via `--append-system-prompt`)
- `${CLAUDE_SKILL_DIR}/adversarial-reviewer.md` — reviewer role prompt (passed to pi via `--append-system-prompt`)

## Invocation

Run the loop with the user's request as the task, passed through verbatim
as `$ARGUMENTS`:

```bash
bash "${CLAUDE_SKILL_DIR}/orchestrate.sh" $ARGUMENTS
```

- All progress goes to **stderr**; exactly **one JSON summary** is on the
  **last line of stdout**. Parse that last line as JSON (e.g. with `jq`).
- The script requires git, jq, and the `pi` binary (PATH, then
  `~/.bun/bin/pi`, then `~/.local/bin/pi`), and an empty `git diff HEAD`
  produces an immediate `EMPTY_DIFF` result — do not pre-filter these
  yourself; interpret them from the JSON summary / exit code.

### Model passthrough

- If the user explicitly named a model, prepend `--model <model>` to the
  same invocation:
  `bash "${CLAUDE_SKILL_DIR}/orchestrate.sh" --model <model> $ARGUMENTS`.
  It is forwarded to every pi call in the loop.
- Otherwise omit `--model` — pi uses its configured default.
- `--max-rounds <N>` (1–3, default 3) is also passed through if the user
  asks for a smaller review budget; the script rejects values above 3.

## Interpreting the JSON summary

The summary on the last stdout line has this shape:

```json
{"status":"PASS","verdict":"APPROVED","rounds":1,"total_pi_calls":2,"findings":[...],"raw_output":"…"}
```

| Field | Meaning |
|---|---|
| `status` | `PASS`, `PASSED_WITH_FINDINGS`, `EMPTY_DIFF`, `REJECTED`, `INCOMPLETE`, or `PI_ERROR` |
| `verdict` | Reviewer verdict enum (`APPROVED`, `MINOR_OBSERVATIONS`, `ISSUES_FOUND`, `CRITICAL_ISSUES_FOUND`) or `null` |
| `rounds` | Review rounds executed (develop round is not counted) |
| `total_pi_calls` | Total pi invocations used (hard cap 6) |
| `findings` | Findings list extracted from the latest review (may be empty) |
| `raw_output` | The final pi transcript of the last round — treat as claims to verify, not truth |

### Exit codes

| Exit code | Meaning |
|---|---|
| 0 | Success — status is `PASS`, `PASSED_WITH_FINDINGS`, or `EMPTY_DIFF` |
| 1 | `REJECTED` — the loop budget ran out without a terminal approval (or `CRITICAL_ISSUES_FOUND` at the terminal round) |
| 2 | `INCOMPLETE` — pi produced no parseable verdict, **or** a CLI usage error (bad flag / missing task / invalid `--max-rounds`) |
| 3 | `PI_ERROR` — pi missing, pi crashed, a `git diff HEAD` call failed, or a pi call timed out |

## Verifying pi's claims (colleague, not authority)

pi is a colleague, not an authority: everything it reports — the
findings, the fixes, the final text in `raw_output` — is a **claim** until
you confirm it. Before reporting the outcome:

1. Re-read the actual change with `git diff HEAD` and the files involved
   — never take the findings or `raw_output` at face value.
2. Check each reported finding or fix against the diff: does the code
   change actually address (or cause) it?
3. Only report as verified what the diff supports; if a claim doesn't
   hold, say so and describe what the diff actually shows.

## Reporting the verdict

Report to the user, in this order:

1. **The verdict** — status, reviewer verdict, and exit code in plain
   language ("Approved on round 2", "Rejected after 3 review rounds",
   "Nothing to review — working tree clean").
2. **The findings** — the `findings` list, one per line, after your own
   verification step above.
3. **What was done about them** — how many fix rounds ran (derived from
   `total_pi_calls` minus develop + review rounds) and whether the issues
   were resolved, with what you verified in the diff.
4. **Failures** — for exit 2 or 3, relay the error context from stderr
   and `raw_output`, suggest fixing the environment or the invocation
   (e.g. install pi/jq, fix the task description, check `git status`),
   and offer a re-run.

Do not paste the full `raw_output` transcript unless the user asks for it.
