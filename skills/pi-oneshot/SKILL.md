---
name: pi-oneshot
description: Delegates a self-contained coding task to the pi agent in one headless call. Use when asked to "delegate to pi" or "use pi for" a job.
user_invocable: true
---

# pi-oneshot

Run ONE Bash call with the Bash tool's `timeout` set to `590000`, the full
task as the heredoc (goal, files, "run the tests; do not commit"). Add
`--model MODEL` after `run.sh` only if the user named one:

```bash
bash "${CLAUDE_SKILL_DIR}/run.sh" <<'PI_TASK'
<the full task description>
PI_TASK
```

The output is `EXIT CODE: n`, pi's text, then the diff stat.

- `STILL RUNNING`: run the printed `run.sh --wait …` command again (also `timeout: 590000`) until an `EXIT CODE` line appears.
- `EXIT CODE: 0`: reply in at most 3 lines (what changed, files). Do not re-read the diff or re-run pi's tests.
- `124`/`137` = timed out (`PI_TIMEOUT`, 1800 s default); other non-zero, `REFUSED:` or `RUN DIED`: relay it, do not retry.
- Stop a run: `bash "${CLAUDE_SKILL_DIR}/run.sh" --abort <RUN_DIR>`.

`PI_DELEGATE_UNSAFE=1` skips the preflight (default branch, secret files, `git push`); see `docs/configuration.md`.
