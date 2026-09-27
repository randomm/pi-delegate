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

## Usage — pi-oneshot

`pi-oneshot` is the lightweight skill: a single `pi -p --no-session "$ARGUMENTS"`
call — text mode, pi's full default toolset, no review loop, no structured JSON
parsing. Claude runs it, reads pi's output, and summarizes what happened back to
you.

Good fits — mechanical, self-contained, verifiable tasks:

```
delegate to pi: rename the file utils/helpers.py to utils/utils.py and update imports
use pi for: write a bats test for scripts/validate.sh
pi oneshot: scaffold a Makefile with build, test, and clean targets
```

`--model <model>` is passed through to pi only when you explicitly name a model;
otherwise pi uses its configured default.

## Usage — pi-review-loop

`pi-review-loop` is for work you want **reviewed, not just done**. It runs
`orchestrate.sh`, a deterministic bash driver that owns the entire loop:

```
run the review loop: implement retry_with_backoff() in src/retry.py
```

The driver takes your request as the develop-round task, then loops:

```
develop ──> review ──> fix ──> review ──> … (rounds ≤ 3, capped at 5)
```

- **Round 1 (develop):** pi implements your task with full tool access.
- **Each review round:** a *separate* pi instance, run **read-only**
  (`--tools read,grep,find,ls`), reviews the fresh `git diff HEAD` and ends
  with a `VERDICT:` line.
- **Fix round:** on a blocking verdict, the developer prompt re-runs with the
  findings threaded in, then the loop reviews again.

Each fix consumes a review round; there is at most one develop round, at most
3 review rounds (cap 5), and at most 2 fix rounds.

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
| `status` | Terminal loop state: `PASS`, `PASSED_WITH_FINDINGS`, `EMPTY_DIFF`, `REJECTED`, `INCOMPLETE`, `PI_ERROR` |
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
- `--max-rounds <N>` — review-round budget (default 3, hard cap 5).

## Model selection guide

There are **no pinned model defaults** — both skills pass `--model` through only
when you explicitly name one, otherwise pi uses whatever default its config has.
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
| 0 | `PASS`, `PASSED_WITH_FINDINGS`, or `EMPTY_DIFF` | Report the verdict. For `PASSED_WITH_FINDINGS`, surface the `findings` array as observations. |
| 1 | `REJECTED` — `CRITICAL_ISSUES_FOUND` with the round budget exhausted | Relay the findings; do **not** claim the change is safe. |
| 2 | `INCOMPLETE` — no parseable verdict (malformed pi output) | Re-run, or inspect `raw_output` to see what pi actually emitted. |
| 3 | `PI_ERROR` — pi missing/unresolvable, not a git repo, or pi crashed (auth, etc.) | Fix the environment, then re-run. |

### Verdicts

The reviewer's final message must end with `VERDICT: <value>`. The parser takes
the **last** occurrence, case-insensitively, tolerating an optional colon and
markdown bold.

| Verdict | Meaning | Loop outcome |
|---|---|---|
| `APPROVED` | Change is correct and complete | `PASS` |
| `MINOR_OBSERVATIONS` | Only informational notes | `PASS` |
| `ISSUES_FOUND` | Real problems, non-critical | `PASSED_WITH_FINDINGS` (findings surfaced, not blocking) |
| `CRITICAL_ISSUES_FOUND` | Blocking problems | Fix round; after budget exhausted → `REJECTED` |

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
- re-run with `--max-rounds 5` to give the loop more budget (the driver is
  hard-capped at 5).

### The diff is empty at entry

Exit 0 with `EMPTY_DIFF` — nothing to review. The driver does not invoke pi at
all.

## How it works

### Architecture

```
                you
                 │
                 ▼
        Claude Code (orchestrator)
        ├── pi-oneshot  ─────────────────────────►  pi -p --no-session "$ARGUMENTS"
        │                                            (single call, full tools,
        │                                             text mode, passthrough)
        └── pi-review-loop
                 │
                 ▼
           orchestrate.sh  (deterministic bash driver, repo root)
           ├── round 1: developer  ──►  pi --mode json -p --no-session
           │                             --append-system-prompt developer.md
           │                             (full tools)
           ├── round N: reviewer   ──►  pi --mode json -p --no-session
           │                             --append-system-prompt adversarial-reviewer.md
           │                             --tools read,grep,find,ls   (read-only)
           └── fix rounds: developer ─►  (same as round 1, findings threaded in)
                 │
                 ▼
          one JSON summary (last line of stdout)
```

### Loop sequence

1. **Preflight:** `jq` present, `pi` resolvable, `git rev-parse --git-dir`
   succeeds. `git diff HEAD` empty → `EMPTY_DIFF`, exit 0, zero pi calls.
2. **Develop:** one pi call with `developer.md` as the appended system prompt;
   the task description is the user prompt.
3. **Review (≤ 3 rounds, cap 5):** the diff is re-read fresh from
   `git diff HEAD` each round and embedded in the review prompt, along with the
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
   `INCOMPLETE`.

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
against `git diff HEAD` before reporting them, and an `APPROVED` verdict never
replaces Claude's own judgment about the diff.
