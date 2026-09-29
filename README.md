# pi-delegate

A pair of Claude Code skills for the **token-cost arbitrage pattern**: instead of
paying your top model to do the heavy lifting, have Claude *orchestrate and judge*
while a cheaper, headless coding agent — [pi](https://pi.dev) — writes and fixes
the code. One skill (`pi-oneshot`) delegates a single task in one shot; the other
(`pi-review-loop`) wraps a deterministic bash driver that runs a
develop → review → fix loop with an adversarial reviewer, hard-capped by round
budgets.

## Quick start

You need three things: Claude Code, a working `pi` installation, and `jq`.

1. **Check that pi is installed.** pi's headless mode is what both skills call:

   ```bash
   pi --version
   ```

   If `pi` is not found, install it:

   ```bash
   curl -fsSL https://pi.dev/install.sh | sh
   ```

   The skills look for `pi` on `PATH`, then `~/.bun/bin/pi`, then
   `~/.local/bin/pi`. pi must also be authenticated for the provider you
   use — run `pi` once interactively and complete its auth flow before
   delegating.

2. **Check that jq is installed** (only the review loop needs it — it is
   used to parse pi's JSON output):

   ```bash
   jq --version
   ```

3. **Install the skills** into `~/.claude/skills/`:

   ```bash
   git clone https://github.com/randomm/pi-delegate.git
   mkdir -p ~/.claude/skills
   cp -R pi-delegate/skills/pi-review-loop ~/.claude/skills/
   cp -R pi-delegate/skills/pi-oneshot   ~/.claude/skills/
   ```

   (The `pi-oneshot` directory ships with this repo per issue #5; if it is
   not present yet, install `pi-review-loop` only.)

4. **Verify.** In Claude Code, ask for a trivial one-shot delegation and
   confirm pi runs:

   ```
   delegate to pi: write a bash function that prints today's date in ISO format
   ```

## Safety

**pi has no sandbox.** Its full toolset can read every file in the working tree
(including git-ignored ones), run arbitrary commands, and push to remotes. The
skills mitigate — but do not eliminate — this:

- **Branch guard:** `orchestrate.sh` (and the `pi-oneshot` preflight) **refuse
to run** (exit 3, `REFUSED:` on stderr + `PI_ERROR` JSON) when the current
  branch is the repo's default branch (or HEAD is detached at its tip). Work on
  a feature branch.
- **Secret-file guard:** the same preflight **refuses to run** when secret-looking
  files are present in the working tree (`.env`, `.env.*` except `*.example` /
  `*.sample` / `*.template`, `*.pem`, `*.key`) — pi's tools can read them and
  send them to the model provider.
- **Push neutralisation:** for every pi process, the driver exports
  `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` (0-indexed,
  appended to any pre-existing entries) with `push.default = nothing` and a
  per-remote `remote.<name>.pushurl = pi-delegate-push-disabled://dead`, so
  `git push` (with or without a refspec) fails. URL-based pushes
  (`git push <url>`) are **not** blocked — an inherent git limitation.

**Real isolation is a disposable clone/worktree or a container.** The preflight
is a last-resort guardrail, not a substitute. If you need to run on the default
branch, with secret files present, or with push enabled, set
`PI_DELEGATE_UNSAFE=1` — and understand that you are opting out of all three
guards.

## Usage — pi-oneshot

`pi-oneshot` is the lightweight skill: a single `pi -p --no-session` call
with `--no-extensions --no-skills --no-prompt-templates` (same isolation as
the review loop — context files stay loaded by design) — text mode, pi's full
default toolset, no review loop, no structured JSON parsing. Claude runs it,
reads pi's output, and summarizes what happened back to you.

The pi call is wrapped in a per-call timeout —
`timeout --kill-after=${PI_KILL_AFTER:-30} ${PI_TIMEOUT:-1800}` (falling back
to `gtimeout` on macOS; if neither binary exists the call runs without a time
limit and a warning is logged, bounded only by Claude Code's Bash-tool
timeout). Exit code 124 (SIGTERM at `PI_TIMEOUT`) and 137 (SIGKILL escalation
at `PI_TIMEOUT + PI_KILL_AFTER`) both mean **pi timed out**; any other
non-zero exit is a real pi failure and is relayed verbatim. The wrapper
applies to every invocation variant, including `--model <model>`.

Good fits — mechanical, self-contained, verifiable tasks:

```
delegate to pi: rename the file utils/helpers.py to utils/utils.py and update imports
use pi for: write a bats test for scripts/validate.sh
pi oneshot: scaffold a Makefile with build, test, and clean targets
```

### Per-call timeout

The pi invocation is wrapped in `timeout` the same way `orchestrate.sh`
wraps its pi calls:

```bash
printf '%s' "$ARGUMENTS" | timeout --kill-after="$PI_KILL_AFTER" "$PI_TIMEOUT" pi -p --no-session --no-extensions --no-skills --no-prompt-templates
```

(The prompt goes on stdin, the same transport `orchestrate.sh` uses — no
argv size limit — and the timeout wrapper wraps pi only; the pipe feeds
pi's stdin.)

- `PI_TIMEOUT` — seconds allowed per pi invocation (default 1800).
- `PI_KILL_AFTER` — seconds to wait after the `PI_TIMEOUT` SIGTERM before
  escalating to SIGKILL (default 30; passed to timeout as `--kill-after`).
- The wrapper prefers `timeout` (coreutils) and falls back to `gtimeout`
  (macOS brew coreutils); if neither exists, the call runs unbounded at the
  script level and a warning is printed to stderr.
- **Exit codes 124 and 137 mean "timed out"** — 124 is pi SIGTERMed at
  `PI_TIMEOUT`, 137 is pi SIGKILLed at `PI_TIMEOUT + PI_KILL_AFTER` after
  ignoring SIGTERM. Any other non-zero exit is a genuine pi failure.
  (On the unbounded path, 124/137 from this wrapper do not apply.)

### Long runs under Claude Code's Bash tool

Claude Code's Bash tool imposes a per-foreground-call timeout (`BASH_DEFAULT_TIMEOUT_MS`
defaults to 120000 ms / 2 minutes; `BASH_MAX_TIMEOUT_MS` defaults to 600000 ms /
10 minutes; values above the max are silently clamped). A single pi task can
legitimately run far longer than the 10-minute foreground ceiling, so the skill
instructs Claude to run the invocation with `run_in_background: true` and poll
the background task's output file with the `Read` tool until pi exits — not
to pass a larger foreground `timeout` (clamped values would not help).

## Usage — pi-review-loop

`pi-review-loop` is for work you want **reviewed, not just done**. It runs
`orchestrate.sh`, a deterministic bash driver that owns the entire loop:

```
run the review loop: implement retry_with_backoff() in src/retry.py
```

The driver takes your request as the develop-round task, then loops:

```
develop ──> review ──> fix ──> review ──> … (≤ 3 rounds, hard cap 3)
```

**Long runs under Claude Code:** at the default `PI_TIMEOUT`/`PI_KILL_AFTER`
the loop's worst-case wall clock is `6 × (1800 + 30)` s ≈ 183 min (~3 h) —
far above the Bash tool's foreground ceiling (10 min by default). Invoke
`orchestrate.sh` with `run_in_background: true` and poll by reading the
background task's output until the final JSON summary line (the last line of
stdout) appears — don't rely on the 2-minute foreground default, and don't
try to raise the foreground `timeout` parameter, which is silently clamped
to `BASH_MAX_TIMEOUT_MS` (600000 ms, 10 min).

- **Round 1 (develop):** pi implements your task with full tool access.
- **Each review round:** a *separate* pi instance, run **read-only**
  (`--tools read,grep,find,ls`), reviews the changes against the base commit
  recorded before the develop round — committed work and new untracked
  (non-ignored) files included — and ends with a `VERDICT:` line.
- **Fix round:** on a blocking verdict, the developer prompt re-runs with the
  findings threaded in, then the loop reviews again.

Each fix consumes a review round; there is at most one develop round, at most
3 review rounds (hard cap 3), and at most 2 fix rounds.

### Expected output

All progress goes to **stderr**; exactly one JSON summary is the **last line of
stdout**:

```json
{
  "status": "PASSED_WITH_FINDINGS",
  "verdict": "ISSUES_FOUND",
  "rounds": 2,
  "total_pi_calls": 3,
  "findings": ["line 42: unhandled error path in save()"],
  "raw_output": "<last pi transcript>"
}
```

| Field | Meaning |
|---|---|
| `status` | Terminal loop state: `PASS`, `PASSED_WITH_FINDINGS`, `EMPTY_DIFF` (the develop round produced no change vs the base), `REJECTED`, `INCOMPLETE`, `PI_ERROR` |
| `verdict` | Last parsed reviewer verdict, or `null` |
| `rounds` | Review rounds that ran |
| `total_pi_calls` | Total pi invocations (develop + reviews + fixes) |
| `findings` | Reviewer findings from the final round |
| `raw_output` | Raw transcript of the last pi call (context only) |

Optional flags (only use them when you need them):

```bash
orchestrate.sh --model <model> --max-rounds <N> "<task description>"
```

- `--model <model>` — forwarded to every pi invocation; omit to use pi's
  configured default.
- `--max-rounds <N>` — review-round budget (default 3, hard cap 3).

### Long runs under Claude Code's Bash tool

Claude Code's Bash tool imposes a per-foreground-call timeout (`BASH_DEFAULT_TIMEOUT_MS`
defaults to 120000 ms / 2 minutes; `BASH_MAX_TIMEOUT_MS` defaults to 600000 ms /
10 minutes; values above the max are silently clamped). The loop's worst-case
wall clock is `6 × (PI_TIMEOUT + PI_KILL_AFTER)` — at the defaults ≈ 183 min
(~3 h) — which exceeds even the 10-minute foreground ceiling, so a foreground
invocation is always killed mid-loop. The skill therefore instructs Claude to
run `orchestrate.sh` with the Bash tool's `run_in_background: true` and poll
the background task's output file with the `Read` tool until the final JSON
line (the summary) appears — background tasks are not subject to the
foreground ceiling, so the full per-call budget is honored.

### Environment

- `PI_TIMEOUT` — seconds allowed per pi invocation (default 1800). Requires
  `timeout` (coreutils) or `gtimeout` (macOS brew coreutils) on `PATH`; if
  neither exists, pi calls run without a time limit and a warning is logged
  once. Must be a positive integer, or the driver exits 2.
- `PI_KILL_AFTER` — seconds to wait after the `PI_TIMEOUT` SIGTERM before
  escalating to SIGKILL (default 30; passed to timeout as `--kill-after`). A
  pi process that ignores SIGTERM is SIGKILLed at `PI_TIMEOUT + PI_KILL_AFTER`
  and both resulting exit codes (124 SIGTERM / 137 SIGKILL) are classified as
  a timeout (`PI_ERROR`, exit 3). Must be a positive integer, or the driver
  exits 2. Ignored when no timeout binary exists (unbounded path). Known
  limit: processes that detach into their own session (`setsid`/daemons)
  escape the timeout entirely — worst-case wall clock for the loop is
  `6 × (PI_TIMEOUT + PI_KILL_AFTER)` (≈ 183 min, ~3 h, at the defaults) for
  non-detached processes.
- `PI_TIMEOUT` / `PI_KILL_AFTER` also apply to **pi-oneshot**: the single pi
call is wrapped in the identical per-call timeout
(`timeout --kill-after=${PI_KILL_AFTER:-30} ${PI_TIMEOUT:-1800}`; `gtimeout`
fallback on macOS; unbounded with a warning if neither binary exists), and
exit 124 (SIGTERM) / 137 (SIGKILL escalation) both mean "timed out". On the
unbounded path there is no 124/137 at all — only Claude Code's Bash-tool
timeout bounds the run.
- `PI_DIFF_MAX_BYTES` — max bytes of the diff (or fix-prompt transcript) embedded
  in a review prompt (default 90000); larger content is truncated with a
  notice. The lower default (was 100000) ensures the total prompt stays well
  under `MAX_ARG_STRLEN` (131072 on Linux).
- `PI_PROMPT_MAX_BYTES` — max total bytes for a single pi call (all argv args +
  stdin combined, default 120000). If the total exceeds this, the driver
  produces a clear `PI_ERROR` (exit 3) instead of an opaque `E2BIG` from the
  kernel. The prompt itself is passed via **stdin** (piped to pi), not as an
  argv string, which avoids `E2BIG` for large prompts on its own; this check
  is a second, explicit guard for the combined size.

> **Model pinning (issue #26, closed — declined by operator policy):** the
> original proposal to add `PI_PROVIDER` / `PI_MODEL` env vars that forward
> `--provider` / `--model` to every pi call was explicitly declined in issue
> #26. The model remains unpinned; `--model` passthrough is the only supported
> way to select a model. Instead, after every successful pi call the driver
> reads the `provider` and `model` fields from the assistant `message_end`
> events in the `--mode json` transcript and logs the pair to **stderr**
> (e.g. `pi call 1: provider/model anthropic/claude-opus-4`). This is purely
> informational: missing fields are reported as `unknown/unknown`, the exit
> code and JSON summary contract are unchanged, and no failure mode is
> introduced. A `pi` that reports a different provider/model than expected
> will be visible in the stderr log, but the driver does not fail.

## Model selection guide

There are **no pinned model defaults** — both skills pass `--model` through only
when you explicitly name one, otherwise pi uses whatever default its config has.
After each pi call the review-loop driver logs the `provider/model` pair reported
by pi's `message_end` events to stderr (issue #26); check the stderr output to
confirm which model actually answered each round.
Pick models by the *kind* of work:

| Work | Model class | Rationale |
|---|---|---|
| Renames, scaffolds, boilerplate, test fixtures, doc updates | Cheaper/faster | Mechanical; the reviewer catches mistakes |
| Small fixes with a clear finding list | Cheaper/faster | The findings *are* the spec |
| New logic, refactors across files, API changes | More capable | Complex decisions compound errors |
| Adversarial review rounds | More capable | The reviewer's judgment is the quality gate — a weak reviewer lets bad code through, defeating the arbitrage |

Heuristic: **cheap model builds, strong model judges.** If the reviewer approves
a diff you cannot stand behind, the problem is the reviewer's model, not the
developer's.

## Cost rationale

The pattern works because the two agents have different price profiles:

- **Claude (orchestrator)** — the model you already run. It interprets your
  intent, hands a concrete task to pi, then *reads* the diff and the verdict and
  judges the result. Reading and judging are cheap; that is its job.
- **pi (worker)** — a headless, cheaper coding agent that does the expensive
  part: reading the codebase, writing files, running tests. Its full toolset
  runs without consuming your top model's context with tool-call transcripts.

So the expensive work (generating and verifying code) happens on the cheaper
model, while your expensive model does the work it is best at: deciding *what*
to build and *whether* the result is trustworthy. Without the review loop this
would be "trust the cheap model"; with it, the cheap model's output is only
admitted after an adversarial pass — which is why the reviewer is the one role
where you should not skimp on model quality.

## Exit codes and verdicts

### Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | `PASS`, `PASSED_WITH_FINDINGS`, or `EMPTY_DIFF` | Report the verdict. For `PASSED_WITH_FINDINGS`, surface the `findings` array as observations. For `EMPTY_DIFF`, the develop round produced no change vs the base — nothing was reviewed. |
| 1 | `REJECTED` — `CRITICAL_ISSUES_FOUND` with the round budget exhausted | Relay the findings; do **not** claim the change is safe. |
| 2 | `INCOMPLETE` — no parseable verdict (malformed pi output); JSON summary is emitted | Re-run, or inspect `raw_output` to see what pi actually emitted. |
| 2 | CLI usage error (unknown flag, missing task, invalid `--max-rounds`, `PI_TIMEOUT`, or `PI_KILL_AFTER`); stderr `ERROR:`, no JSON | Fix the command line, then re-run. |
| 3 | `PI_ERROR` — pi missing/unresolvable, not a git repo, git/jq missing, pi crashed (auth, etc.), a diff snapshot against the base failed, or pi timed out after `PI_TIMEOUT` seconds (SIGTERM rc 124, or SIGKILL escalation rc 137 at `PI_TIMEOUT + PI_KILL_AFTER` for pi that ignores SIGTERM) | Fix the environment, then re-run. |

### Verdicts

The reviewer's final message must end with `VERDICT: <value>`. The parser takes
the **last** occurrence, case-insensitively, tolerating an optional colon and
markdown bold.

| Verdict | Meaning | Loop outcome |
|---|---|---|
| `APPROVED` | Change is correct and complete | `PASS` |
| `MINOR_OBSERVATIONS` | Only informational notes | `PASS` |
| `ISSUES_FOUND` | Real problems, non-critical | Triggers a fix round at any non-terminal round; at the terminal round → `PASSED_WITH_FINDINGS` (findings surfaced, not blocking) |
| `CRITICAL_ISSUES_FOUND` | Blocking problems | Triggers a fix round at any non-terminal round; if the round budget is exhausted → `REJECTED` |

## Troubleshooting

### `pi not found`

The driver tries `PATH`, then `~/.bun/bin/pi`, then `~/.local/bin/pi`. Install pi
and make sure the binary is executable:

```bash
curl -fsSL https://pi.dev/install.sh | sh
command -v pi
```

If you installed via Bun, check `~/.bun/bin/pi` exists and is on `PATH` for the
Claude Code process (GUI apps do not inherit your shell's `PATH`).

### pi auth errors

pi runs headless, so it cannot prompt for credentials. Auth failures surface as
`PI_ERROR` (exit 3) with pi's stderr relayed verbatim. Fix auth interactively
first:

```bash
pi -p "echo ok"
```

If that works, the loop will too.

### `INCOMPLETE` verdicts

Means the reviewer's last message had no parseable `VERDICT:` line — usually pi
emitted malformed JSONL or the final message was truncated. Look at `raw_output`
in the JSON summary and the stderr transcript; a re-run usually recovers. If it
persists, check that `jq` is installed (the driver dies with exit 3 without it).

### `REJECTED`

The reviewer found critical issues and the round budget is exhausted. The change
is **not** safe as-is. Read the `findings` array, then either:

- fix the findings yourself and re-run the loop, or
- re-run with `--max-rounds 3` (the maximum; the driver is hard-capped at 3).

### The develop round produced no change

A clean working tree at entry is normal — the loop is develop-first, so the
base commit (the HEAD before the develop round; the empty tree for unborn
repos) is recorded first and the diff is taken against it, which includes
committed work and new untracked (non-ignored) files. `EMPTY_DIFF` (exit 0)
means the develop round itself produced no change vs that base — nothing was
reviewed; the JSON summary and stderr say so.

## How it works

### Architecture

```
                you
                 │
                 ▼
        Claude Code (orchestrator)
        ├── pi-oneshot  ─────────────────────────►  pi -p --no-session \
        │                                            --no-extensions --no-skills \
        │                                            --no-prompt-templates "$ARGUMENTS"
        │                                            (single call, full tools,
        │                                             text mode, passthrough)
        └── pi-review-loop
                 │
                 ▼
           orchestrate.sh  (deterministic bash driver, repo root)
           ├── round 1: developer  ──►  pi --mode json -p --no-session \
           │                             --no-extensions --no-skills --no-prompt-templates
           │                             --append-system-prompt developer.md
           │                             (full tools)
           ├── round N: reviewer   ──►  pi --mode json -p --no-session \
           │                             --no-extensions --no-skills --no-prompt-templates
           │                             --append-system-prompt adversarial-reviewer.md
           │                             --tools read,grep,find,ls   (read-only)
           └── fix rounds: developer ─►  (same as round 1, findings threaded in)
                 │
                 ▼
          one JSON summary (last line of stdout)
```

### Loop sequence

1. **Preflight:** `jq` present, `pi` resolvable, `git rev-parse --git-dir`
   succeeds. A base commit is recorded before the develop round (`git rev-parse HEAD`, or the empty tree for unborn repos) — a clean working tree at entry is normal and is not a short-circuit.
2. **Develop:** one pi call with `developer.md` as the appended system prompt;
   the task description is the user prompt.
3. **Review (≤ 3 rounds, hard cap 3):** the diff against the base commit is
   re-read fresh each round (including committed work and new untracked
   non-ignored files) and embedded in the review prompt, along with the
   original task and any previous-round findings (so findings cannot regress
   unnoticed). The reviewer runs read-only.
4. **Verdict parsing:** the final assistant text is extracted from the last
   `message_end` event (role `assistant`, stop reason `stop`) of pi's JSONL
   stream; the `VERDICT:` line is parsed (last occurrence, case-insensitive,
   optional colon/bold) and the `## Findings` section is extracted.
5. **Loop or terminate:** `APPROVED`/`MINOR_OBSERVATIONS` → `PASS`;
   `ISSUES_FOUND` → `PASSED_WITH_FINDINGS` (terminal);
   `CRITICAL_ISSUES_FOUND` → fix round + re-review while budget remains, else
   `REJECTED`; no parseable verdict → one more round if budget remains, else
   `INCOMPLETE`. If the diff against the base is empty after the develop
   round, the loop ends with `EMPTY_DIFF`, exit 0 — the develop round
   produced nothing to review.

### Prompt flow

Each pi call is headless (`--no-session`, no extensions/skills/prompt templates),
so the prompt templates are the only role definition the agent gets:

- **`developer.md`** — tells pi it is an implementation agent (or fixer): make
  minimal, targeted changes, verify with the project's tests/linters, and end
  with a fixed `## Completed` / `## Files Changed` / `## Notes` structure.
- **`adversarial-reviewer.md`** — tells pi it is a read-only, evidence-driven
  reviewer: every finding must cite `[file:line]` with a quote, pre-existing
  debt is capped at MINOR, severity must not be inflated, and the message ends
  with the exact `## Findings` + `VERDICT:` structure the parser expects.

Templates are passed via `--append-system-prompt` (never `--system-prompt`,
which replaces pi's system prompt and breaks tool-calling).

A deliberate doctrine runs through the whole design: pi's output is treated as a
**colleague, not an authority**. Claude verifies the claims in `findings`
against the diff (against the base commit, so committed and newly created
files are covered) before reporting them, and an `APPROVED` verdict never
replaces Claude's own judgment about the diff.

## License

Licensed under the Apache License, Version 2.0 — see LICENSE. Copyright 2026 Janni Turunen.
