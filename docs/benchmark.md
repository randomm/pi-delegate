# Benchmark Protocol

Benchmark: plain **Claude Code** (arm A) vs **Claude Code + pi-delegate**
(arm B) on the same tasks in the same target repo. Measures tokens,
wall-clock, and outcome quality (objective test pass/fail).

## Arms

| | Arm A | Arm B |
|---|---|---|
| Claude model | `sonnet` (resolves to `claude-sonnet-5-5`) | same |
| Permission mode | `auto` (fixed, documented) | same |
| Plugin | none (fresh `CLAUDE_CONFIG_DIR`, no plugins) | `pi-delegate` installed at pinned commit |
| Prompt | `prompt.md` (task body verbatim) | `prompt.md` + delegation suffix directing use of `pi-review-loop` |
| pi shim | installed (logs any accidental pi call) | installed (logs all pi calls) |
| pi context files | n/a | `--no-context-files` (operator decision, enforced by shim) |

Both arms use a **fresh `CLAUDE_CONFIG_DIR` per run** (`$BENCH_OUT/<task>/<arm>/<run>/claude-config`).
The subscription OAuth credential lives in the macOS **login keychain** under
`Claude Code-credentials`, keyed by user account — **not** by config dir — so
a fresh config dir starts plugin-clean but still authenticates. Verified by
dry-run: `CLAUDE_CONFIG_DIR=$(mktemp -d) claude plugin list --json` → `[]`
with no auth error; `claude plugin install pi-delegate@pi-delegate` into a
fresh config dir succeeds once the marketplace catalog is seeded.

## Tasks

Tasks use **historical fix replay**:

1. `REPO` — target repo (any well-known OSS repo, or pi-delegate itself).
2. `BASE_SHA` — the parent commit of a historical fix. The agent starts here.
3. `FIX_COMMIT` — the historical fix; its **test-only** diff is extracted at
   task creation time into `grading.patch`.
4. `TEST_CMD` — the target repo's own test/lint suite, run identically in both
   arms.
5. `prompt.md` — the historical issue body (verbatim), plus a fixed
   instruction paragraph.
6. `grading.patch` — the test-only portion of `FIX_COMMIT`
   (`git show --format="" <FIX_COMMIT> -- <test paths>`).

Grading: `bench/grade.sh` applies `grading.patch` to the run's working tree,
then runs `TEST_CMD`. If the agent edited the same test files the patch
touches, `git apply` fails and the run is scored as a failure with
`error: "git apply failed"` (documented edge case: test-editing is not
verifiable).

### Task layout

```
bench/tasks/<id>/
  prompt.md        # task body (historical issue text + instructions)
  task.env         # REPO, BASE_SHA, FIX_COMMIT, TEST_CMD, GRADING_PATCH
  grading.patch    # test-only diff of FIX_COMMIT
```

### Example task (shipped): `issue-41-mech`

- Target: pi-delegate itself (the repo being benchmarked)
- `BASE_SHA=b1a2b78`, `FIX_COMMIT=be3d614` ("SIGKILL escalation for pi
  timeouts")
- `TEST_CMD=bats skills/pi-review-loop/test/ skills/pi-oneshot/test/`
- Mechanical fix: add `--kill-after` to the `timeout` wrapper, classify rc 137
  as timeout, validate `PI_KILL_AFTER`.

To add a task for another repo: create the three files, extract the grading
patch with `git show --format="" <FIX_COMMIT> -- <test paths>`, and verify it
applies cleanly at `BASE_SHA` (`git apply --check`).

## Per-run pipeline

```
bench/setup-run.sh <task> <arm> <run>   # fresh clone at BASE_SHA, feature branch, push disabled
bench/run-arm.sh    <task> <arm> <run>  # run claude -p (arm A) or claude + pi-delegate (arm B)
bench/grade.sh      <task> <arm> <run>  # apply grading.patch, run TEST_CMD
bench/collect.sh    <task> <arm> <run>  # one JSON line per run, jq-validated
```

### setup-run.sh

- Clones `REPO` at `BASE_SHA` into `$BENCH_OUT/<task>/<arm>/<run>/repo`
  (**outside any repo**).
- Creates branch `bench/<arm>/<run>`.
- Disables push: `push.default=nothing` + `remote.origin.pushurl` rewritten to
  `pi-delegate-push-disabled://dead`.
- Secret-file scan (`.env`, `.env.*`, `*.pem`, `*.key`) — refuses (exit 3) if
  any are present (mirrors the pi-oneshot safety preflight).
- Writes `setup.json`.

### run-arm.sh

- Creates a per-run `CLAUDE_CONFIG_DIR` (isolation).
- Arm B only: clones the pinned pi-delegate commit (`PI_DELEGATE_SHA`, default
  `be98114`) and seeds the marketplace catalog + installs the plugin into the
  config dir.
- Installs the **pi shim** (`<run-dir>/bin/pi`) and prepends `<run-dir>/bin`
  to `PATH` for the claude invocation.
- Builds the prompt (task body + arm-B delegation suffix).
- Runs:

  ```
  claude -p --output-format json --model <model> --permission-mode <mode>
  ```

  with the prompt on **stdin** (avoids E2BIG), `CLAUDE_CONFIG_DIR` set, and
  the shim first on `PATH`. Wall-clock bounded by `timeout --kill-after`.
- Saves raw claude JSON to `<run-dir>/claude/output.json` and writes
  `run-meta.json`.

### The pi shim (docs: §pi-shim below)

A `pi` wrapper at `<run-dir>/bin/pi`, prepended to `PATH`, that:

- **Resolves the real pi** at install time (stable path).
- **Injects `--no-context-files`** exactly once if not already in argv
  (enforces the operator decision for pi-oneshot; no-op for pi-review-loop
  which passes it itself).
- **`--mode json` calls** (pi-review-loop): tees pi's stdout (one JSON event per
  line) to `<run-dir>/pi-<call_id>.jsonl`; collect.sh parses usage from the
  last assistant `message_end`.
- **text-mode calls** (pi-oneshot): records argv + wall clock + exit code only.
  The per-call token count is **not available** in text mode — collect.sh
  reports `tokens: null` for those calls (documented gap, §metrics).
- **Never injects `--mode json`** — the shim must not change skill behaviour.
  For pi-oneshot this means a documented token-accounting gap rather than a
  silent behaviour change.
- Appends one metadata line per call to `<run-dir>/pi-calls.jsonl`.
- Prints pi's captured output to its own stdout so Claude's Bash tool sees
  the same text it would have without the shim.

## Metrics (one JSON line per run, `collect.sh`)

```json
{
  "task": "issue-41-mech", "arm": "B", "run": 1,
  "model": "claude-sonnet-5-5",
  "permission_mode": "auto",
  "pi_delegate_commit": "be98114…",
  "target_commit": "b1a2b78",
  "claude": {
    "cost_usd": 0.42, "duration_ms": 42000,
    "permission_denials": [ … ], "is_error": false,
    "model_usage": { "<model>": { "input_tokens": …, "output_tokens": …,
      "cache_read": …, "cache_creation": …, "cost_usd": … } }
  },
  "pi": [
    { "argv": [ … ], "duration_ms": 5000, "exit": 0, "mode": "json",
      "call_id": "…",
      "tokens": { "input": …, "output": …, "cache_read": …, "cache_write": …, "total": … } },
    { "argv": [ … ], "duration_ms": 2000, "exit": 0, "mode": "text",
      "call_id": "…", "tokens": null }
  ],
  "grade": { "pass": true, "test_cmd": "…", "error": null },
  "wall_clock_ms": 900000
}
```

`collect.sh` **validates with jq** before emitting: required fields present
(`task`, `arm`, `run`, `grade`), `grade.pass` boolean, `claude.duration_ms` /
`claude.cost_usd` numeric-or-null. A malformed run fails loudly (exit 2)
instead of polluting the report.

### Cost basis

- **Claude**: list price from `claude -p` JSON (`total_cost_usd`,
  per-model `costUSD`).
- **pi**: the local/self-hosted pi provider reports **cost 0.0**. The
  benchmark tracks **tokens in/out per call and per model** (from `message_end`
  `usage`); a normalised cost basis (list price of an equivalent hosted model,
  or GPU-hour estimate) is applied **at report time** and must be stated in the
  results report. Do not compare raw `cost_usd` between arms without it.

### Token-accounting gap (pi-oneshot, text mode)

pi-oneshot runs pi in **text mode** by design (the shipped skill emits plain
text). Text mode has no per-message `usage` events, so per-call pi tokens for
oneshot runs are `null`. The wall-clock and argv are still recorded. This is
the documented gap — closing it would require forcing `--mode json` on
oneshot, which changes the skill's documented behaviour and was ruled out.

## Matrix

- **MVS (minimum viable slice)**: 1 mechanical + 1 intricate task × 3 runs ×
  2 arms — run this first to surface runaway runs cheaply.
- **Full matrix**: 3–5 tasks (mix of mechanical and intricate) × ≥3 runs ×
  2 arms.
- Worst-case arm-B run ≈ 6 × (PI_TIMEOUT 1800 s + PI_KILL_AFTER 30 s) ≈ 3 h.

## How to run

```bash
# MVS, one run per arm on the mechanical task (pipeline dry run)
bench/setup-run.sh issue-41-mech A 1
bench/run-arm.sh    issue-41-mech A 1
bench/grade.sh      issue-41-mech A 1
bench/collect.sh    issue-41-mech A 1
# repeat with arm B and run 2/3, then the intricate task

# Full matrix: loop task × arm × run over the task list above.
```

Environment overrides: `BENCH_OUT`, `CLAUDE_MODEL`, `CLAUDE_PERM_MODE`,
`PI_DELEGATE_SHA`, `CLAUDE_TIMEOUT`, `PI_TIMEOUT`, `PI_KILL_AFTER`.

## How to read results

- **Outcome quality**: `grade.pass` (the objective test standard, identical in
  both arms).
- **Claude cost**: `claude.cost_usd` + `claude.model_usage` (tokens per model).
- **pi cost**: `pi[].tokens` per call; sum per arm and apply the stated cost
  basis before comparing to arm A.
- **Wall clock**: `claude.duration_ms` (claude API time) and `wall_clock_ms`
  (setup→grade, whole run).
- **Intervention proxy**: `claude.permission_denials` under the fixed
  `auto` permission mode.
- **Arm B internals**: `pi[]` call list (loop verdict/rounds are in the
  per-call transcripts `pi-<call_id>.jsonl`), `pi_delegate_commit`.

## Known limitations

- `CLAUDE_CONFIG_DIR` isolation is per-run, not per-arm — two concurrent runs
  of the same arm share nothing (each run has its own config dir).
- The pi shim's `--no-context-files` injection is idempotent but string-based;
  it does not parse `--no-context-files=…` (pi uses the plain form).
- `collect.sh` wall-clock is setup→grade (includes claude + grading), not
  claude-only; use `claude.duration_ms` for the claude-only figure.
- Grading is test-only patch + TEST_CMD; it does not diff the agent's change
  against the historical fix (that would require the non-test diff, which is
  intentionally withheld from the agent to avoid leakage).
