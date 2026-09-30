---
name: pi-oneshot
description: Delegates a self-contained task to the pi coding agent in a single headless `pi -p` invocation — text mode, full toolset, no review loop. Use when the user asks to "delegate to pi", to run a "pi task", to "use pi for" a job, or to "run pi oneshot" — a quick task you want done in one shot and then summarized.
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
bash <<'PI_DELEGATE_BLOCK'
PI_BIN=""
for candidate in "$(command -v pi 2>/dev/null || true)" "$HOME/.bun/bin/pi" "$HOME/.local/bin/pi"; do
  [[ -n "$candidate" ]] || continue
  if [[ -x "$candidate" ]]; then
    PI_BIN="$candidate"
    break
  fi
done
PI_DELEGATE_BLOCK
```

If none is executable, do not try to run pi. Tell the user pi is not
installed (tried: PATH, `~/.bun/bin/pi`, `~/.local/bin/pi`) and suggest:

```
curl -fsSL https://pi.dev/install.sh | sh
```

then offer to re-run once it is available.

## Safety preflight (issue #30)

pi has **no sandbox**: its full toolset can read every file in the working tree
(including ignored ones) and run arbitrary commands — including `git push`.
Before running pi, perform the same checks `orchestrate.sh` performs, unless
`PI_DELEGATE_UNSAFE=1` is set.

**The preflight must run in the SAME Bash tool call that launches pi.**
The push-neutralising step only `export`s `GIT_CONFIG_*` variables, and a
`Bash` tool call is one shell process: exported variables do **not** survive
into a later, separate Bash call. A preflight run in its own call would leave
the launch unguarded (free `git push` for pi). So the preflight block below
is included **verbatim at the top** of each launch block — the foreground
`## Invocation` block and the detached launch block under `### Long runs`
(only the `# --- End safety preflight ---` line and the launch line itself
differ). Do not run it as a standalone step.
```bash
bash <<'PI_DELEGATE_BLOCK'
# --- Safety preflight (skip if PI_DELEGATE_UNSAFE=1) -----------------------
if [ "${PI_DELEGATE_UNSAFE:-}" != "1" ]; then
  # 1. Refuse the default branch (or detached HEAD at its tip).
  default_branch=""
  head_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || head_ref=""
  if [ -n "$head_ref" ]; then
    default_branch="${head_ref#origin/}"
  else
    for dcand in main master; do
      git show-ref --verify --quiet "refs/heads/$dcand" 2>/dev/null && { default_branch="$dcand"; break; }
    done
  fi
  cur_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || cur_branch=""
  if [ -n "$default_branch" ]; then
    if [ -n "$cur_branch" ] && [ "$cur_branch" = "$default_branch" ]; then
      echo "REFUSED: current branch is the default branch '${default_branch}' (set PI_DELEGATE_UNSAFE=1 to override)" >&2
      exit 3
    fi
    if [ -z "$cur_branch" ]; then
      head_sha="$(git rev-parse --quiet --verify HEAD 2>/dev/null)" || head_sha=""
      def_sha="$(git rev-parse --quiet --verify "refs/heads/${default_branch}" 2>/dev/null)" || def_sha=""
      if [ -n "$head_sha" ] && [ "$head_sha" = "$def_sha" ]; then
        echo "REFUSED: detached HEAD at the tip of the default branch '${default_branch}' (set PI_DELEGATE_UNSAFE=1 to override)" >&2
        exit 3
      fi
    fi
  fi
  # 2. Refuse secret-looking files (.env, .env.*, *.pem, *.key) — regular
  #    files and symlinks alike, anywhere in the tree. The scan runs from
  #    the repo root (paths are reported relative to it) and is fail-closed:
  #    any non-zero `find` exit (e.g. an unreadable directory) is a refusal
  #    — a partial scan must never pass.
  repo_root="$(git rev-parse --show-toplevel)" || { echo "REFUSED: could not determine the repo root" >&2; exit 3; }
  secrets_found=""
  scan_file="$(mktemp)"
  scan_err_file="$(mktemp)"
  find "$repo_root" -not -path "$repo_root/.git" -not -path "$repo_root/.git/*" -not -path "$repo_root/node_modules" -not -path "$repo_root/node_modules/*" \
    \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \) \( -type f -o -type l \) \
    > "$scan_file" 2> "$scan_err_file" || { echo "REFUSED: secret-file scan failed: $(cat "$scan_err_file")" >&2; exit 3; }
  rm -f "$scan_err_file"
  # .env.example / .env.sample / .env.template are safe (no secrets). Max 5
  # paths are listed in the refusal message (integer counter, not a
  # per-iteration grep|wc pipeline).
  shown=0
  while IFS= read -r sf; do
    sf="${sf#"$repo_root"/}"
    case "$sf" in *.example|*.sample|*.template) continue ;; esac
    if [ -z "$secrets_found" ]; then secrets_found="$sf"; else secrets_found="${secrets_found}, ${sf}"; fi
    shown=$((shown + 1))
    [ "$shown" -ge 5 ] && break
  done < "$scan_file"
  rm -f "$scan_file"
  if [ -n "$secrets_found" ]; then
    echo "REFUSED: secret-looking file(s) present: ${secrets_found} (set PI_DELEGATE_UNSAFE=1 to override)" >&2
    exit 3
  fi
  # 3. Neutralise git push for the pi process via GIT_CONFIG_* env.
  #    The single cursor _gc starts at the validated pre-existing
  #    GIT_CONFIG_COUNT (so caller entries are preserved) and each entry
  #    exports its KEY_n / VALUE_n pair then increments; a non-numeric
  #    pre-existing count is a refusal (git itself hard-errors on it).
  _gc="${GIT_CONFIG_COUNT:-0}"
  if ! [[ "$_gc" =~ ^[0-9]+$ ]]; then
    echo "REFUSED: pre-existing GIT_CONFIG_COUNT='${GIT_CONFIG_COUNT}' is not a non-negative integer (set PI_DELEGATE_UNSAFE=1 to override)" >&2
    exit 3
  fi
  export GIT_CONFIG_KEY_${_gc}=push.default GIT_CONFIG_VALUE_${_gc}=nothing
  _gc=$((_gc + 1))
  # pushInsteadOf rewrites common URL prefixes to the dead helper; the
  # empty value in the last entry matches every remaining URL (including
  # bare relative local paths like `git push ../repo`).
  for _p in https:// http:// ssh:// git:// file:// git@ / ""; do
    export GIT_CONFIG_KEY_${_gc}="url.pi-delegate-push-disabled://.pushInsteadOf" GIT_CONFIG_VALUE_${_gc}="${_p}"
    _gc=$((_gc + 1))
  done
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    export GIT_CONFIG_KEY_${_gc}="remote.${_r}.pushurl" GIT_CONFIG_VALUE_${_gc}=pi-delegate-push-disabled://dead
    _gc=$((_gc + 1))
  done < <(git remote 2>/dev/null)
  export GIT_CONFIG_COUNT="${_gc}"
  unset _gc _r _p
fi
# --- End safety preflight ---------------------------------------------------
PI_DELEGATE_BLOCK
```

Then proceed to the `## Invocation` block below. Real isolation (a disposable
clone/worktree or a container) is the correct fix; this preflight is a
last-resort guardrail, not a substitute.

## Invocation

Run the task as a single one-shot, stateless call, passing the user's
request (the full task description) to pi. The block is
self-contained — it re-resolves the pi binary (`PI_BIN`, per `## Locating
the pi binary`) and re-runs the timeout-wrapper resolution (mirroring
`orchestrate.sh`: `PI_TIMEOUT` default 1800 s, `PI_KILL_AFTER` default 30 s,
`timeout` preferred with a `gtimeout` fallback, and a probe that treats a
missing `--kill-after` flag as "no timeout binary at all"), because nothing
persists between Bash tool calls. Run this single block — it is complete
and covers both wrapper states (wrapped and unbounded). The user's request
comes in via a task file written with a quoted heredoc (as in the
`pi-review-loop` launch guidance) — `cat > "$D/task.txt"` style, in its own
Bash call; this block reads it back, so no quoting of the request is needed
in this call:
```bash
bash <<'PI_DELEGATE_BLOCK'
# Re-resolve the pi binary (nothing from an earlier Bash call persists).
PI_BIN=""
for candidate in "$(command -v pi 2>/dev/null || true)" "$HOME/.bun/bin/pi" "$HOME/.local/bin/pi"; do
  [ -n "$candidate" ] || continue
  if [ -x "$candidate" ]; then
    PI_BIN="$candidate"
    break
  fi
done
[ -n "$PI_BIN" ] || { echo "pi not found (PATH, ~/.bun/bin/pi, ~/.local/bin/pi) — install it and re-run"; exit 1; }

# NOTE: the `--kill-after=1 1 true` probe is GNU-timeout-specific by design —
# non-GNU shims fail it and fall back to the unbounded path on purpose.
# Discover the timeout binary and probe --kill-after support; if the probe
# fails (e.g. an old macOS `timeout` without the flag) treat it as absent —
# unbounded call + warning — mirroring orchestrate.sh.
TIMEOUT_CMD=""
for tcand in timeout gtimeout; do
  if command -v "$tcand" >/dev/null 2>&1 && "$tcand" --kill-after=1 1 true >/dev/null 2>&1; then
    TIMEOUT_CMD="$tcand"
    break
  fi
done

if [ -z "$TIMEOUT_CMD" ]; then
  echo "WARNING: no GNU timeout/gtimeout found — pi runs without a time limit" >&2
fi

# --- Safety preflight (skip if PI_DELEGATE_UNSAFE=1) — SAME call as the
# pi launch below: the push-neutralising exports below only live in THIS
# shell process and must reach the pi process as its environment.
<the verbatim ## Safety preflight block above: from `if [ "${PI_DELEGATE_UNSAFE:-}" != "1" ]; then` down to `fi`, including the `# --- End safety preflight ---` marker line>

# Validate the timeout knobs the same way orchestrate.sh does (positive
# integers) before building the wrapper — a bad value must fail the
# launch with the driver's message, not reach the timeout binary.
PI_TIMEOUT="${PI_TIMEOUT:-1800}"
if ! [[ "$PI_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$PI_TIMEOUT" -lt 1 ]; then
  echo "ERROR: PI_TIMEOUT must be a positive integer (got: $PI_TIMEOUT)"
  exit 2
fi
PI_KILL_AFTER="${PI_KILL_AFTER:-30}"
if ! [[ "$PI_KILL_AFTER" =~ ^[0-9]+$ ]] || [ "$PI_KILL_AFTER" -lt 1 ]; then
  echo "ERROR: PI_KILL_AFTER must be a positive integer (got: $PI_KILL_AFTER)"
  exit 2
fi

# One wrapper array for every invocation: empty when no usable timeout
# binary exists. The "${wrap[@]+...}" guard keeps empty-array expansion safe
# under `set -u` on old bash (where an unset/empty array trips -u), so the
# call runs unbounded rather than failing or emitting a bare --kill-after.
wrap=()
if [ -n "$TIMEOUT_CMD" ]; then
  wrap=("$TIMEOUT_CMD" --kill-after="${PI_KILL_AFTER:-30}" "${PI_TIMEOUT:-1800}")
fi

# The prompt goes on stdin, exactly as orchestrate.sh passes its prompts to
# pi: the wrapper wraps pi only (the pipe feeds pi's stdin, the timeout
# command is never piped), and stdin has no argv size limit, so long task
# descriptions cannot hit E2BIG (a single argv element is capped at 128 KiB
# on Linux).
printf '%s' "$(cat <the task file from the call above>)" | ${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates
PI_DELEGATE_BLOCK
```

(`PI_TIMEOUT` and `PI_KILL_AFTER` must be positive integers when set — the
block validates them before launching and refuses with the same message
`orchestrate.sh` uses, so a bad value cannot reach the wrapper.)

### Timeout wrapper

When the wrapper runs, a deadline failure surfaces as pi's exit code:

- **124** — pi was SIGTERMed at `PI_TIMEOUT` seconds (SIGTERM at `PI_TIMEOUT`): the call **timed out**.
- **137** — pi ignored SIGTERM and was SIGKILLed at `PI_TIMEOUT + PI_KILL_AFTER` seconds (SIGKILL at `PI_TIMEOUT + PI_KILL_AFTER`): the call **timed out**.

Both mean "timed out" — tell the user the single pi call hit the time limit
and offer a re-run (optionally with a larger `PI_TIMEOUT`). Any other
non-zero exit is a genuine pi failure and is relayed verbatim per the
"Reporting back" section below.

On the **unbounded path** (no usable `timeout`/`gtimeout` binary), the
warning is printed to stderr and there is no script-level deadline —
exit codes 124/137 from this wrapper do not apply; only Claude Code's
Bash tool timeout (below) can kill the run, and a bare non-zero exit is
pi's own.

### Long runs under Claude Code's Bash tool

Claude Code's Bash tool imposes a per-foreground-call timeout: `BASH_DEFAULT_TIMEOUT_MS`
defaults to `120000` ms (2 minutes) and `BASH_MAX_TIMEOUT_MS` defaults to
`600000` ms (10 minutes); `timeout` values above the max are silently clamped
to the max. A single pi task can legitimately run for well over 10 minutes
(the wrapper above defaults to a 30-minute deadline), so a foreground
invocation can be killed mid-run by the Bash tool even when the script-level
timeout would not fire.

So: **do not** try to fix long runs by passing a larger foreground `timeout`
parameter — values above the ceiling are silently clamped (the ceiling is
the Bash tool's `timeout` parameter, not a value in any block below).
Instead, launch the invocation **detached**, record its pid, and wait with
foreground bounded calls (`run_in_background` is NOT safe — see
`docs/configuration.md`):

1. **Prepare, remove stale files, then launch detached** in one foreground
   Bash call. As in the `## Invocation` guidance, first write the request
   to a task file with a quoted heredoc (its own Bash call); the launch
   block reads it back. The block below is self-contained: state does not
   persist between Bash tool calls, so it re-resolves the pi binary
   (`PI_BIN`) and re-runs the timeout-wrapper resolution (`TIMEOUT_CMD` +
   `wrap`) itself rather than reusing the `## Invocation` block's
   variables. The helper files MUST live **outside the target repo** —
   for example in a temp directory made with `mktemp -d` (untracked files
   inside the repo enter the reviewed diff). Remove any stale files from a
   previous run so a leftover `$RC_FILE` cannot look like a completed run,
   then redirect the pi call's output to `$LOG`, the wrapper's exit code to
   an **exit-code file** (`$RC_FILE` — the completion signal for a single
   pi call; this skill has no JSON summary), and record the pid to
   `$PID_FILE`. Note that `$LOG` grows as pi streams output and can be
   deleted after the run:
```bash
bash <<'PI_DELEGATE_BLOCK'
D=$(mktemp -d); LOG="$D/pi-oneshot.log"; PID_FILE="$D/pi-oneshot.pid"; RC_FILE="$D/pi-oneshot.rc"
rm -f "$LOG" "$PID_FILE" "$RC_FILE"
# Re-resolve the pi binary (nothing from an earlier Bash call persists).
PI_BIN=""
for candidate in "$(command -v pi 2>/dev/null || true)" "$HOME/.bun/bin/pi" "$HOME/.local/bin/pi"; do
  [ -n "$candidate" ] || continue
  if [ -x "$candidate" ]; then
    PI_BIN="$candidate"
    break
  fi
done
[ -n "$PI_BIN" ] || { echo "pi not found (PATH, ~/.bun/bin/pi, ~/.local/bin/pi) — install it and re-run"; exit 1; }
# Re-run the timeout-wrapper resolution (timeout preferred, gtimeout
# fallback; the --kill-after probe treats a missing flag as "no timeout
# binary at all" → unbounded + warning, mirroring orchestrate.sh).
TIMEOUT_CMD=""
for tcand in timeout gtimeout; do
  if command -v "$tcand" >/dev/null 2>&1 && "$tcand" --kill-after=1 1 true >/dev/null 2>&1; then
    TIMEOUT_CMD="$tcand"
    break
  fi
done
if [ -z "$TIMEOUT_CMD" ]; then
  echo "WARNING: no GNU timeout/gtimeout found — pi runs without a time limit" >&2
fi
# Validate the timeout knobs the same way orchestrate.sh does (positive
# integers) before building the wrapper — a bad value must fail the
# launch with the driver's message, not reach the timeout binary.
PI_TIMEOUT="${PI_TIMEOUT:-1800}"
if ! [[ "$PI_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$PI_TIMEOUT" -lt 1 ]; then
  echo "ERROR: PI_TIMEOUT must be a positive integer (got: $PI_TIMEOUT)"
  exit 2
fi
PI_KILL_AFTER="${PI_KILL_AFTER:-30}"
if ! [[ "$PI_KILL_AFTER" =~ ^[0-9]+$ ]] || [ "$PI_KILL_AFTER" -lt 1 ]; then
  echo "ERROR: PI_KILL_AFTER must be a positive integer (got: $PI_KILL_AFTER)"
  exit 2
fi
wrap=()
if [ -n "$TIMEOUT_CMD" ]; then
  wrap=("$TIMEOUT_CMD" --kill-after="${PI_KILL_AFTER:-30}" "${PI_TIMEOUT:-1800}")
fi
# --- Safety preflight (skip if PI_DELEGATE_UNSAFE=1) — SAME call as the
# detached launch below: the push-neutralising exports below only live in
# THIS shell process and must reach the pi process as its environment.
<the verbatim ## Safety preflight block: from `if [ "${PI_DELEGATE_UNSAFE:-}" != "1" ]; then` down to `fi`, including the `# --- End safety preflight ---` marker line>
# The prompt goes on pi's stdin (the wrapper wraps pi only; the pipe feeds
# pi's stdin, the timeout command is never piped) so long task descriptions
# cannot hit E2BIG.
set -m
( printf '%s' "$(cat <the task file from the call above>)" | ${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates > "$LOG" 2>&1; echo $? > "$RC_FILE" ) &
echo "$!" > "$PID_FILE"
echo "RUN_DIR=$D"
PI_DELEGATE_BLOCK
```

   The block above is the complete, verbatim launch — `PI_BIN`,
   `TIMEOUT_CMD` and `wrap` are all re-resolved INSIDE the block (nothing
   from an earlier Bash call persists), and the prompt goes to pi's stdin
   via `printf` (the task file content, `$(cat <the task file from the
call above>)` — substitute the path literally). If the user
   explicitly named a model, the only variant is the same block with
   `--model "MODEL"` appended to the pi flags (before the `>` redirect);
   otherwise omit `--model` — pi uses its configured default.

   **State does not persist between Bash tool calls.** Each step runs in
   a separate `bash` process, so shell variables (`D`, `LOG`,
   `PID_FILE`, `RC_FILE`) do not carry over. Copy the `RUN_DIR=...` line
   the launch call printed into every later call: each wait/abort block
   below starts with `D=<the RUN_DIR printed at launch>` (replacing the
   placeholder with the actual path) and derives `$LOG`/`$PID_FILE`/
   `$RC_FILE` from `$D`.
2. **Wait in foreground, bounded calls.** Repeatedly run a foreground
   Bash call with `timeout` just under the 600000 ms ceiling (the Bash
   tool's `timeout` parameter, e.g. 595000). Each call exits as soon as
   the exit-code file appears, or as soon as the recorded pid is gone.
   Read the pid file **once** (`PID=...`): an unreadable pid file is a
   distinct failure ("PID FILE UNREADABLE") from a dead pid, because
   re-reading it on every loop iteration would loop forever on a missing
   file. Replace the `D=` line with the `RUN_DIR` the launch printed
   before running:
```bash
bash <<'PI_DELEGATE_BLOCK'
D="<the RUN_DIR printed at launch>"
LOG="$D/pi-oneshot.log"; PID_FILE="$D/pi-oneshot.pid"; RC_FILE="$D/pi-oneshot.rc"
PID="$(cat "$PID_FILE" 2>/dev/null)"
if [ -z "$PID" ]; then
  echo "PID FILE UNREADABLE — check RUN_DIR"
  exit 1
fi
until [ -s "$RC_FILE" ]; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 15
done
if [ -s "$RC_FILE" ]; then
  echo "EXIT CODE: $(cat "$RC_FILE")"
  tail -n 50 "$LOG"
else
  echo "RUN DIED — no exit code recorded; tail of log:"
  tail -n 20 "$LOG"
  exit 1
fi
PI_DELEGATE_BLOCK
```

   If one wait call is killed at its 10-minute ceiling, start the next: the
   launch is detached and survives, and the wait resumes from the same
   files (re-deriving them from the launch's `RUN_DIR`). When the loop
   exits, the wait block has left you `$RC_FILE` (the recorded exit code)
   and `$LOG` (the pi output) ready to read.
3. **Do not end the turn** before the exit-code file is read (or the pid is
   confirmed gone) — no "the task is running, I'll report when it
   finishes". When done, read `$RC_FILE` and the output in `$LOG` and
   report per the "Reporting back" section below. On a deadline kill, the
   recorded exit code is 124 or 137 = "timed out" (see above). If the pid
   is gone but `$RC_FILE` is empty, the run died without recording an exit
   code — **report the task as failed** ("run died — no exit code recorded;
   tail of log:") with `tail -n 20 "$LOG"`, and **never** report a result
   as if the run had completed.
4. **Stop / abort (before ending the turn).** On abort, kill the recorded
   pid and its children with the recipe below — the same recipe (kept
   identical across both skills and `docs/configuration.md`; the
   authoritative copy is `docs/configuration.md`, **Long runs → Stop /
   abort**). The launch block ran `set -m` before backgrounding, so the
   recorded pid leads its own process group (PGID == pid); killing that
   group kills the run and all its children in one shot. The guard is two-factor:
   a recycled pid almost never leads its own group, but the group-leader check
   alone would still be fooled by a recycled pid that happens to lead one, so
   the block also checks the recorded process's command line — it must be the
   resolved pi path (or a pi invocation, matched as ` pi ` with surrounding
   whitespace to keep it self-contained) before any kill is attempted:
```bash
bash <<'PI_DELEGATE_BLOCK'
D="<the RUN_DIR printed at launch>"
PID_FILE="$D/pi-oneshot.pid"
PID="$(cat "$PID_FILE")"
# Re-resolve the pi path (nothing persists between Bash tool calls).
PI_BIN=""
for candidate in "$(command -v pi 2>/dev/null || true)" "$HOME/.bun/bin/pi" "$HOME/.local/bin/pi"; do
  [ -n "$candidate" ] || continue
  if [ -x "$candidate" ]; then
    PI_BIN="$candidate"
    break
  fi
done
if [ -z "$PI_BIN" ]; then
  echo "pi path could not be resolved — cannot verify command line, skipping the kill"
  exit 0
fi
if [ "$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ')" = "$PID" ] && ps -o command= -p "$PID" 2>/dev/null | grep -qF "$PI_BIN"; then
  kill -TERM -- "-$PID" 2>/dev/null || true
  sleep 5
  kill -KILL -- "-$PID" 2>/dev/null || true
else
  echo "not a pi-delegate run group — skipping"
fi
PI_DELEGATE_BLOCK
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

### Model

The same wrapper wraps the **whole** command, model flag included — never
append `--model` to an un-wrapped call:
```bash
bash <<'PI_DELEGATE_BLOCK'
printf '%s' "$(cat <the task file from the call above>)" | ${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates --model "MODEL"
PI_DELEGATE_BLOCK
```

- If the user explicitly named a model, append `--model <model>` to the
  **same wrapped invocation** shown above — the wrapper wraps the whole
  command, so the model-passthrough variant is bounded identically.
- Otherwise omit `--model` entirely — pi falls back to its configured
  default.

## Reporting back

After pi exits, **summarize** its output and report it to the user:

- Summarize what pi did and found — do not paste the full transcript
  back unless the user asked for it.
- If pi exited **124** or **137**, it timed out — say so ("pi timed out
  after ${PI_TIMEOUT}s (SIGKILL after a further ${PI_KILL_AFTER}s if
  needed)"), suggest raising `PI_TIMEOUT`/`PI_KILL_AFTER` and re-running.
- If pi exited non-zero for any other reason, or printed an error (auth
  failure, model unavailable, crash), relay the error verbatim and suggest
  fixing the environment, then re-running.
- Do not loop: this skill makes exactly one pi invocation per request. If
  the result is wrong or incomplete, tell the user and let them decide —
  a new request (or `pi-review-loop` for a reviewed change) is the way
  forward.
