# Configuration

Environment variables read by `skills/delegate/run.sh`. None are required.

| Variable | Default | Meaning |
|---|---|---|
| `PI_TIMEOUT` | 1800 | Seconds allowed for one pi call. On expiry pi gets SIGTERM, and SIGKILL after `PI_KILL_AFTER`. |
| `PI_KILL_AFTER` | 30 | Grace seconds between SIGTERM and SIGKILL. |
| `PI_VERIFY_TIMEOUT` | 600 | Seconds allowed for the `--verify` command. |
| `PI_WAIT_BUDGET` | 540 | Seconds one `run.sh` call waits before printing `STILL RUNNING` (keep it under the Bash tool's 10-minute limit). |
| `PI_DELEGATE_UNSAFE` | unset | Set to `1` to skip the safety preflight. |

All values must be positive integers.

## Timeouts

The pi call is wrapped in GNU `timeout --kill-after=$PI_KILL_AFTER $PI_TIMEOUT`
(`timeout`, or `gtimeout` on macOS with `brew install coreutils`). Exit code
**124** means SIGTERM at the deadline and **137** means SIGKILL: both mean
"timed out". If neither binary supports `--kill-after`, pi runs unbounded
and `run.sh` prints a warning.

## Long runs

Claude Code's Bash tool kills a foreground call at about 10 minutes, so
`run.sh` starts pi detached (own process group, pid file in a temp run
directory outside your repo) and waits in bounded chunks. When a call ends
with `STILL RUNNING`, repeat the printed `run.sh --wait <RUN_DIR>` command.
Do not use `run_in_background`: background tasks are killed when a
headless `claude -p` turn ends.

`run.sh --abort <RUN_DIR>` stops a run. It only kills a process group led by
the recorded pid whose command line is `run.sh`, plus the groups of that
process's direct children (GNU `timeout` moves pi into its own group).

## Safety preflight

pi has no sandbox: it can read every file in the tree and run any command.
Unless `PI_DELEGATE_UNSAFE=1`, `run.sh` refuses to start when:

- the current branch is the default branch (or HEAD is detached at its tip);
- the tree contains `.env`, `.env.*`, `*.pem` or `*.key` files
  (`*.example`, `*.sample` and `*.template` are fine; the scan is fail-closed);

and it disables `git push` for the pi process. This guards against mistakes,
not against a malicious pi; use a container or a disposable clone for real
isolation.

## `--verify`

`--verify "<cmd>"` runs `cmd` (via `bash -c`, in the repo) after pi
succeeds. On failure pi gets one more call with the task plus the failure
output; the result reports `VERIFY: PASS|FAIL (retries=n)`. The command is
not run if pi itself failed.
