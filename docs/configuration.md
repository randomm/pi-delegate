# Configuration

Environment variables read by `skills/delegate/run.sh`. None are required.

| Variable | Default | Meaning |
|---|---|---|
| `PI_TIMEOUT` | 1800 | Seconds allowed for one pi call. On expiry pi gets SIGTERM, and SIGKILL after `PI_KILL_AFTER`. A hung command pi started is not killed earlier. |
| `PI_KILL_AFTER` | 30 | Grace seconds between SIGTERM and SIGKILL. |
| `PI_VERIFY_TIMEOUT` | 600 | Seconds allowed for the `--verify` command. |
| `PI_WAIT_BUDGET` | 540 | Seconds one `run.sh` call waits before printing `STILL RUNNING` (keep it under the Bash tool's 10-minute limit). |
| `PI_DELEGATE_UNSAFE` | unset | Set to `1` to skip the safety preflight. |
| `PI_DELEGATE_WRAP` | unset | Command prefix run in front of every pi call and the `--verify` command (see [Sandbox](#sandbox-optional)). |

All values must be positive integers.

## Timeouts

The pi call is wrapped in GNU `timeout --kill-after=$PI_KILL_AFTER $PI_TIMEOUT`
(`timeout`, or `gtimeout` on macOS with `brew install coreutils`). Exit code
**124** means SIGTERM at the deadline and **137** means SIGKILL: both mean
"timed out". If neither binary supports `--kill-after`, pi runs unbounded
and `run.sh` prints a warning.

## Leftover processes

pi runs each bash-tool command in its own session, so the timeout's signal
does not reach those commands directly: on SIGTERM pi normally stops its own
tool commands, but after SIGKILL it cannot. `run.sh` therefore tags pi's
environment with `PI_DELEGATE_RUN=<run dir>` and, after every pi call and on
`--abort`, kills every process still carrying the tag, best effort. That
includes servers the task deliberately left running. The scan is complete on
Linux (`/proc`); on macOS it sees only non-Apple binaries (for example
Homebrew or uv Python, node), and was checked on macOS 26.5 only.

This does not stop a hung test early: it still blocks the call until
`PI_TIMEOUT`. The task text asks pi to pass its bash tool's `timeout`
parameter, which the model may ignore.

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
not against a malicious pi, and a feature branch or worktree is not isolation
(pi can `cd` into other checkouts and read `~/.ssh`). For real isolation use
the [sandbox](#sandbox-optional) option, a container or a disposable clone.

## Sandbox (optional)

pi has no built-in sandbox. Set `PI_DELEGATE_WRAP` to a command prefix and
`run.sh` puts it in front of every pi call and the `--verify` command (after
`timeout`, so the time limit still applies). Unset, nothing changes. If the
first word is not an executable, `run.sh` refuses with exit 3 (also under
`PI_DELEGATE_UNSAFE=1`) rather than run unconfined. The prefix is split on
whitespace; for anything with quoting, point it at a script that ends with
`exec "$@"`. The wrapper runs with the repo as its working directory and sees
`PI_DELEGATE_RUN` (the run directory, which it must keep writable).

The recipes below are examples, not code this project tests or secures: they
are not run in CI, they are **not a security boundary**, and the network stays
open, so anything pi can read it can send to the model endpoint. Both need
`~/.pi/agent` writable (pi keeps settings and credentials there), so pi can
read its own API key.

**macOS** (`sandbox-exec`, deprecated but working; checked on macOS 26.5 with
a real pi: in-repo writes and `git commit` work, writes to a sibling
directory and reads of `~/.ssh` and `~/.config` fail). Save as an executable
script, for example `~/bin/pi-sandbox`, and set
`PI_DELEGATE_WRAP=~/bin/pi-sandbox`:

```sh
#!/bin/sh
RUN=$(cd "$PI_DELEGATE_RUN" && pwd -P)
PROFILE='(version 1) (allow default) (deny file-write*)
(allow file-write* (subpath (param "REPO")) (subpath (param "RUN"))
  (subpath (param "PI")) (subpath (param "CACHE"))
  (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper")
  (regex #"^/dev/(fd/[0-9]+|ttys[0-9]+|std(in|out|err))$"))
(deny file-read* file-write* (subpath (param "SSH")) (subpath (param "AWS"))
  (subpath (param "CONFIG")) (subpath (param "GNUPG")))
(allow file-read* (subpath (param "GITCFG")))'
exec env TMPDIR="$RUN/" sandbox-exec -p "$PROFILE" \
  -D REPO="$(pwd -P)" -D RUN="$RUN" -D PI="$HOME/.pi" -D CACHE="$HOME/.cache" \
  -D SSH="$HOME/.ssh" -D AWS="$HOME/.aws" -D CONFIG="$HOME/.config" \
  -D GNUPG="$HOME/.gnupg" -D GITCFG="$HOME/.config/git" "$@"
```

Paths must be resolved (`pwd -P`; `/tmp` and `/var` are under `/private`).
Not shown: that `~/.aws` reads are blocked, that commit signing works
(`~/.gnupg` is denied), or that macOS services (`open`, `osascript`) are
blocked. It cannot nest inside another Seatbelt sandbox such as Claude Code's
own Bash sandbox.

**Linux** (`bwrap`; the mount layout was checked with bash, git and curl,
not with pi itself). Save as an executable script:

```sh
#!/bin/sh
exec bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs "$HOME" \
  --bind "$PWD" "$PWD" --bind "$PI_DELEGATE_RUN" "$PI_DELEGATE_RUN" \
  --bind "$HOME/.pi/agent" "$HOME/.pi/agent" --ro-bind-try "$HOME/.bun" "$HOME/.bun" \
  --ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig" --bind-try "$HOME/.cache" "$HOME/.cache" \
  --die-with-parent --unshare-pid --new-session -- "$@"
```

Adjust the read-only bind to wherever pi is installed. In a linked git
worktree also bind the main repository's git directory
(`git rev-parse --path-format=absolute --git-common-dir`) writable, which
exposes its shared refs. On Ubuntu 24.04, `bwrap` fails with `setting up uid
map: Permission denied` because unprivileged user namespaces are restricted
(`kernel.apparmor_restrict_unprivileged_userns=1`); fixing that is a host
policy decision (a scoped AppArmor profile is safer than the global sysctl).
A container remains the stronger option when you need all of `$HOME` hidden
or network control.

## `--verify`

`--verify "<cmd>"` runs `cmd` (via `bash -c`, in the repo) after pi
succeeds. On failure pi gets one more call with the task plus the failure
output; the result reports `VERIFY: PASS|FAIL (retries=n)`. The command is
not run if pi itself failed.
