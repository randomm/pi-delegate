# How it works

## Architecture

![pi-delegate architecture: an orchestrating agent (Claude Code · Codex · any CLI
harness) calls either the pi-oneshot skill (one single pi call, full tools,
text output) or the pi-review-loop skill, which wraps orchestrate.sh; inside the
review loop (max 3 rounds) a full-tools pi developer produces a diff, a
read-only pi adversarial reviewer ends with a VERDICT and sends findings back
for fixes, repeating until approved or the round budget runs out; the verdict
and findings (status · verdict · findings) are read back by the agent.](images/pi-delegate-architecture.png)

The skills are packaged for Claude Code, but `orchestrate.sh` is plain bash
with a documented CLI (flags in, one JSON summary line out), so any agent
harness — or a plain shell — can drive it directly.

## Loop sequence

1. **Preflight:** `jq` present, `pi` resolvable, `git rev-parse --git-dir`
   succeeds, and the safety preflight passes (feature branch, no secret-looking
   files — see [troubleshooting → REFUSED](troubleshooting.md#refused--safety-preflight)).
   A start ref is recorded before the develop round (`git rev-parse --verify -q
   HEAD`, or the empty tree for unborn repos). A clean working tree at entry
   is normal and is not a short-circuit — there is no entry-time diff gate.
2. **Develop:** one pi call with `developer.md` as the appended system prompt;
   the task description is the user prompt.
3. **Review (≤ 3 rounds, hard cap 3):** the diff against the start ref is
   re-read fresh each round (including committed work and new untracked
   non-ignored files) and embedded in the review prompt, along with the
   original task and any previous-round findings (so findings cannot regress
   unnoticed). The reviewer runs read-only.
4. **Verdict parsing:** the final assistant text is extracted from the last
   `message_end` event (role `assistant`, stop reason `stop`) of pi's JSONL
   stream; the `VERDICT:` line is parsed (last occurrence, case-insensitive,
   optional colon/bold) and the `## Findings` section is extracted.
5. **Loop or terminate** — the two blocking arms diverge only at the terminal
   round (`INCOMPLETE`, exit 2, ends the loop if no verdict is ever parsed):
   - `APPROVED` / `MINOR_OBSERVATIONS` → `PASS`.
   - `ISSUES_FOUND` → a fix round at any **non-terminal** round; at the
     terminal round → `PASSED_WITH_FINDINGS` (findings surfaced, not
     blocking).
   - `CRITICAL_ISSUES_FOUND` → a fix round at any **non-terminal** round; when
     the round budget is exhausted (terminal round, or fix budget spent) →
     `REJECTED`.
   - No parseable verdict → `INCOMPLETE` (exit 2).
   If the diff against the start ref is empty **after** the develop round, the
   loop ends with `EMPTY_DIFF`, exit 0 — the develop round produced nothing to
   review.

Each fix consumes a review round; there is at most one develop round, at most
3 review rounds (hard cap 3), and at most 2 fix rounds (6 pi invocations
total). At `--max-rounds 1` the single review round is terminal, so there is
no fix round — a blocking verdict at round 1 ends the loop immediately.

## Verdicts

The reviewer's final message must end with `VERDICT: <value>`. The parser
takes the **last** occurrence, case-insensitively, tolerating an optional
colon and markdown bold.

| Verdict | Meaning | Loop outcome |
|---|---|---|
| `APPROVED` | Change is correct and complete | `PASS` |
| `MINOR_OBSERVATIONS` | Only informational notes | `PASS` |
| `ISSUES_FOUND` | Real problems, non-critical | A fix round at any non-terminal round; at the terminal round → `PASSED_WITH_FINDINGS` (findings surfaced, not blocking) |
| `CRITICAL_ISSUES_FOUND` | Blocking problems | A fix round at any non-terminal round; when the round budget is exhausted → `REJECTED` |

## JSON summary

All progress goes to **stderr**; exactly one JSON summary is the **last line
of stdout** (built with `jq`, never string interpolation):

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
| `verdict` | Last parsed reviewer verdict, or `null` when no verdict was reached |
| `rounds` | Review rounds that ran |
| `total_pi_calls` | Total pi invocations (develop + reviews + fixes) |
| `findings` | Reviewer findings from the final round |
| `raw_output` | Raw transcript of the last pi call (context only) |

## Prompt flow

Each pi call is headless (`--mode json -p --no-session`, no
extensions/skills/prompt templates), so the prompt templates are the only
role definition the agent gets:

- **`developer.md`** — tells pi it is an implementation agent (or fixer):
  make minimal, targeted changes, verify with the project's tests/linters, and
  end with a fixed `## Completed` / `## Files Changed` / `## Notes` structure.
- **`adversarial-reviewer.md`** — tells pi it is a read-only, evidence-driven
  reviewer: every finding must cite `[file:line]` with a quote, pre-existing
  debt is capped at MINOR, severity must not be inflated, and the message ends
  with the exact `## Findings` + `VERDICT:` structure the parser expects.

Templates are passed via `--append-system-prompt` (never `--system-prompt`,
which replaces pi's system prompt and breaks tool-calling).

A deliberate doctrine runs through the whole design: pi's output is treated as
a **colleague, not an authority**. The orchestrator verifies the claims in
`findings` against the diff (against the start ref, so committed and newly
created files are covered) before reporting them, and an `APPROVED` verdict
never replaces the orchestrator's own judgment about the diff.

## Worst case and cost rationale

**Worst case.** At the default budget (3 review rounds), the loop can make up to
6 pi calls (develop 1 + review 3 + fix 2). Each is bounded by
`PI_TIMEOUT` (default 1800 s) plus the `PI_KILL_AFTER` (default 30 s) SIGKILL
escalation — for non-detached processes (a process that detaches into its own
session escapes the timeout entirely). That is far above Claude Code's Bash
foreground ceiling, which is why long runs go through
`run_in_background` + polling — see
[configuration → Long runs](configuration.md#long-runs-under-claude-codes-bash-tool)
for the worst-case derivation.

**Cost rationale.** The pattern works because the two agents have different
price profiles:

- **The orchestrator** — the model you already run. It interprets your intent,
  hands a concrete task to pi, then *reads* the diff and the verdict and
  judges the result. Reading and judging are cheap; that is its job.
- **pi (worker)** — a headless, cheaper coding agent that does the expensive
  part: reading the codebase, writing files, running tests. Its full toolset
  runs without consuming your top model's context with tool-call transcripts.

So the expensive work (generating and verifying code) happens on the cheaper
model, while your expensive model does the work it is best at: deciding
*what* to build and *whether* the result is trustworthy. Without the review
loop this would be "trust the cheap model"; with it, the cheap model's output
is only admitted after an adversarial pass — which is why the reviewer is the
one role where you should not skimp on model quality.

Models are not pinned: the driver forwards `--model` only when you name one,
otherwise pi uses its configured default — and it logs the `provider/model`
pair pi reports after every successful call (to stderr, e.g. `pi call 1:
provider/model anthropic/claude-opus-4`).

Pick models by the *kind* of work:

| Work | Model class | Rationale |
|---|---|---|
| Renames, scaffolds, boilerplate, test fixtures, doc updates | Cheaper/faster | Mechanical; the reviewer catches mistakes |
| Small fixes with a clear finding list | Cheaper/faster | The findings *are* the spec |
| New logic, refactors across files, API changes | More capable | Complex decisions compound errors |
| Adversarial review rounds | More capable | The reviewer's judgment is the quality gate — a weak reviewer lets bad code through, defeating the arbitrage |

Heuristic: **cheap model builds, strong model judges.** If the reviewer
approves a diff you cannot stand behind, the problem is the reviewer's model,
not the developer's.
