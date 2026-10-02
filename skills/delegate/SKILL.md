---
name: delegate
description: Delegates a self-contained coding task to the pi agent (cheaper model) in one headless call, gated by a verification command. Use when asked to "delegate to pi" or "use pi for" a job.
user_invocable: true
---

# delegate

Run ONE Bash call with the Bash tool's `timeout` set to `590000`, the full
task as the heredoc (goal, files involved, "keep the change minimal and in scope; do not commit"). Pass
`--verify "<cmd>"` with the project's test/lint command so the result is
checked deterministically; add `--model MODEL` only if the user named one:

```bash
bash "${CLAUDE_SKILL_DIR}/run.sh" --verify "<test command>" <<'PI_TASK'
<the full task description>
PI_TASK
```

The output is `EXIT CODE: n`, pi's text, `VERIFY: PASS|FAIL`, then the diff stat.

- `STILL RUNNING`: run the printed `run.sh --wait …` command again (also `timeout: 590000`) until `EXIT CODE` appears.
- `EXIT CODE: 0` and `VERIFY: PASS`: reply in one or two sentences (what changed). Do not re-read the diff or re-run the tests.
- `VERIFY: FAIL` (pi already retried once), or no `--verify` given: say so plainly, then check the diff yourself or fix it.
- `124`/`137` = timed out (`PI_TIMEOUT`, 1800 s default); other non-zero, `REFUSED:` or `RUN DIED`: relay it, do not retry.
- Stop a run: `bash "${CLAUDE_SKILL_DIR}/run.sh" --abort <RUN_DIR>`.

`PI_DELEGATE_UNSAFE=1` skips the preflight (default branch, secret files, `git push`); see `docs/configuration.md`.
