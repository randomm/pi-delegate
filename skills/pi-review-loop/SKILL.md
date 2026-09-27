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

## Invocation

Run the loop with the user's request as the task. Quote `$ARGUMENTS` and
pass it through as a **single argument**:

```bash
bash "${CLAUDE_SKILL_DIR}/orchestrate.sh" "$ARGUMENTS"
```

- **Quote `$ARGUMENTS`.** An unquoted `$ARGUMENTS` still performs command
  substitution: `bash orchestrate.sh $ARGUMENTS` with a request containing
  `$(id -u)` executes that command before the script ever runs. Quoting is
  the only safe passthrough — `orchestrate.sh` receives the request as one
  argument and never re-evaluates it.
- Do **not** use `eval` or `sh -c` / `bash -c` — that would execute the
  request as shell code, not pass it as a task string.
- All progress goes to **stderr**. Except for CLI usage errors, exactly
  **one JSON summary** is on the **last line of stdout** — parse that last
  line as JSON (e.g. with `jq`). A CLI usage error (bad flag, missing task,
  invalid `--max-rounds`, invalid `PI_TIMEOUT`) exits 2 with an `ERROR:`
  message on stderr only — no JSON; read stderr.
- The script requires git, jq, and the `pi` binary, and an empty
  `git diff HEAD` produces an immediate `EMPTY_DIFF` result — do not
  pre-filter these yourself; interpret them from the JSON summary / exit
  code.
- Each pi call is bounded by `PI_TIMEOUT` seconds (default 1800). A call
  that hangs past the limit surfaces as `PI_ERROR` / exit 3. If the entire
  script produces no output for an extended period, check that the pi
  binary and git are available and that the working tree has an uncommitted
  diff; a run with no progress is safe to interrupt and re-run.

### Model passthrough

- If the user explicitly named a model, prepend `--model <model>` to the
  same invocation:
  `bash "${CLAUDE_SKILL_DIR}/orchestrate.sh" --model <model> "$ARGUMENTS"`.
  It is forwarded to every pi call in the loop. Quote `"$ARGUMENTS"`
  throughout (see Invocation); never pass it through unquoted.
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
| `fix_calls` | Fix rounds executed (0–2) |
| `findings` | Bullet/numbered lines from the reviewer transcript (may be empty) — verify each against the diff before reporting |
| `raw_output` | The final pi transcript of the last round — treat as claims to verify, not truth |

### Exit codes

| Exit code | Meaning |
|---|---|
| 0 | Success — status is `PASS`, `PASSED_WITH_FINDINGS`, or `EMPTY_DIFF` |
| 1 | `REJECTED` — the loop budget ran out without a terminal approval (or `CRITICAL_ISSUES_FOUND` at the terminal round) |
| 2 | `INCOMPLETE` — pi produced no parseable verdict (JSON summary emitted) — **or** a CLI usage error (bad flag / missing task / invalid `--max-rounds` / invalid `PI_TIMEOUT`), which exits with an `ERROR:` message on stderr only, no JSON (see Invocation) |
| 3 | `PI_ERROR` — pi missing, pi crashed, a `git diff HEAD` call failed, or a pi call timed out. Missing git/jq/pi exits with stderr only, no JSON (see Invocation); the other causes emit a JSON summary |

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
3. **What was done about them** — the `fix_calls` count (how many fix
   rounds ran) and whether the issues were resolved, with what you
   verified in the diff.
4. **Failures** — for exit 2 or 3, relay the error context from stderr
   and, if a JSON summary was emitted, its `raw_output`. Usage errors and
   missing git/jq/pi produce stderr only (see Invocation).

Do not paste the full `raw_output` transcript unless the user asks for it.
