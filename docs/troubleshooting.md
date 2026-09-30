# Troubleshooting

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | `PASS`, `PASSED_WITH_FINDINGS`, or `EMPTY_DIFF` | Report the verdict. For `PASSED_WITH_FINDINGS`, surface the `findings` array as observations. For `EMPTY_DIFF`, the develop round produced no change vs the base — nothing was reviewed. |
| 1 | `REJECTED` — `CRITICAL_ISSUES_FOUND` with the round budget exhausted | Relay the findings; do **not** claim the change is safe. |
| 2 | `INCOMPLETE` — no parseable verdict (malformed pi output); JSON summary is emitted | Re-run, or inspect `raw_output` to see what pi actually emitted. |
| 2 | CLI usage error (unknown flag, missing task, invalid `--max-rounds`, `PI_TIMEOUT`, or `PI_KILL_AFTER`); stderr `ERROR:`, no JSON | Fix the command line, then re-run. |
| 3 | `PI_ERROR` — pi missing/unresolvable, not a git repo, git/jq missing, pi crashed (auth, etc.), a diff snapshot against the base failed, pi timed out (exit 124 / 137 — semantics in [configuration](configuration.md#timeout-exit-codes-124-and-137-sigterm-at-pi_timeout-sigkill-escalation)), or the safety preflight refused the run (`REFUSED:` on stderr) | Fix the environment (or the refusal), then re-run. |

## `pi not found`

The driver tries `PATH`, then `~/.bun/bin/pi`, then `~/.local/bin/pi`.
Install pi and make sure the binary is executable:

```bash
curl -fsSL https://pi.dev/install.sh | sh
command -v pi
```

If you installed via Bun, check `~/.bun/bin/pi` exists and is on `PATH`
for the Claude Code process — **GUI apps do not inherit your shell's
`PATH`**, so a `pi` that works in your terminal may be invisible to a GUI
Claude Code; add its bin directory to that app's `PATH`.

## pi auth errors

pi runs headless, so it cannot prompt for credentials. Auth failures surface
as `PI_ERROR` (exit 3) with pi's stderr relayed verbatim. Fix auth
interactively first:

```bash
pi -p "say ok"
```

If that works, the loop will too.

## `INCOMPLETE` verdicts

Means the reviewer's last message had no parseable `VERDICT:` line — usually
pi emitted malformed JSONL or the final message was truncated. Look at
`raw_output` in the JSON summary and the stderr transcript; a re-run usually
recovers. If it persists, check that `jq` is installed (the driver dies with
exit 3 without it).

## `REJECTED`

The reviewer found critical issues and the round budget is exhausted. The
change is **not** safe as-is. The round budget is hard-capped at 3 — raising
`--max-rounds` cannot help (3 is both the default and the cap), so fix the
work instead:

- narrow or split the task so a single loop can complete it,
- address the specific items in the `findings` array from the JSON summary
  yourself and re-run, or
- fix the findings in a separate session, then re-run the loop to confirm.

## The develop round produced no change (`EMPTY_DIFF`)

A clean working tree at entry is normal — the loop is develop-first, so the
start ref (the HEAD before the develop round; the empty tree for unborn
repos) is recorded first and the diff is taken against it, which includes
committed work and new untracked (non-ignored) files. `EMPTY_DIFF` (exit 0)
means the develop round itself produced no change vs that base — nothing was
reviewed; the JSON summary and stderr say so.

## `REFUSED:` (safety preflight)

The preflight refuses to run (exit 3, `PI_ERROR` JSON, `REFUSED:` on stderr)
in three cases:

- **Default branch** — the current branch is the repo's default branch (or
  HEAD is detached at its tip). Work on a feature branch instead.
- **Secret-looking files** — `.env`, `.env.*` (except `*.example` /
  `*.sample` / `*.template`), `*.pem`, or `*.key` exist in the working tree
  (regular files and symlinks alike; the scan is fail-closed, so an unreadable
  directory also refuses). Move them out of the tree or name the examples
  `*.example`.
- **Push neutralisation** — for every pi process the driver exports
  `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`
  (appended to any pre-existing entries) with `push.default = nothing` and a
  per-remote `pushurl` to an invalid URL, so `git push` fails. Explicit-URL
  pushes are rewritten via `pushInsteadOf` for the common prefixes
  (`https://`, `http://`, `ssh://`, `git://`, `file://`, the scp-like `git@`
  form, and absolute local paths).

If you genuinely need to run on the default branch, with secret files present,
or with push enabled, set `PI_DELEGATE_UNSAFE=1` — and understand that you are
opting out of all three guards. **Real isolation is a disposable clone/worktree
or a container**; the preflight is a last-resort guardrail, not a substitute.
A disposable clone/worktree is, as the name implies, disposable — delete it
when the work is done (`rm -rf <the-clone>`).

## `ENOSPC` (out of disk space)

Tool calls fail with `ENOSPC` and the machine gets slow, as if memory were
exhausted. Two causes:

- **A tmpfs-backed `/tmp`.** Check where your scratch/output dir lives:
  `findmnt -no FSTYPE <dir>`. If it reports a tmpfs type (e.g. `tmpfs`),
  point the output at a disk-backed directory instead (for the benchmark
  harness: `BENCH_OUT=/local/disk/…`).
- **Forgotten disposable clones / run dirs.** Every clone, worktree, or
  benchmark run dir left behind takes real space. Delete the ones you are
done with. See
  [benchmark → Disk use and cleanup](benchmark.md#disk-use-and-cleanup-docs--disk-use)
  for the run-dir cleanup step and the tmpfs warning.
