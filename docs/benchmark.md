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

Tasks use **historical fix replay** against the `randomm/click` fork of
pallets/click. All SHAs below are verified present in the fork.

| Task id | Issue | Class | BASE_SHA | FIX_SHA | GRADING_TESTS |
|---|---|---|---|---|---|
| `click-sentinel-pickle` | #3805 | MECHANICAL (MVS) | `3cbcf9b` | `4295457` | `tests/test_utils/test_sentinel.py` |
| `click-param-source` | #3458 | INTRICATE (MVS) | `4b24a6c` | `7d05a59` | `tests/test_defaults.py tests/test_options.py` |
| `click-edit-pathlib` | #3781 | — | `2103e15` | `e1fd594` | `tests/test_termui.py` |
| `click-usage-no-args` | #3360 | — | `7c99ebe` | `0551bf5` | `tests/test_formatting.py` |
| `click-ansi-prompt` | #3572 | — | `6ec99f8` | `fe3ad76` | `tests/test_termui.py` |

### MVS (minimum viable slice)

`click-sentinel-pickle` (MECHANICAL) + `click-param-source` (INTRICATE) × 3
runs × 2 arms. Run this first to surface runaway runs cheaply.

### Task layout

```
bench/tasks/<id>/
  prompt.md        # task body (historical issue text + instructions)
  task.env         # REPO, BASE_SHA, FIX_SHA, SETUP_CMD, TEST_CMD, GRADING_TESTS, GRADING_PATCH
  grading.patch    # test-only diff of FIX_SHA
```

### task.env fields

| Field | Purpose |
|---|---|
| `REPO` | `https://github.com/randomm/click.git` (all tasks) |
| `BASE_SHA` | Full 40-char SHA of the base commit (parent of the historical fix) |
| `FIX_SHA` | Full 40-char SHA of the historical fix (used only for grading patch extraction, not exposed to the agent) |
| `SETUP_CMD` | Shell command run in the repo dir to create the venv and install deps |
| `TEST_CMD` | Shell command run in the repo dir to execute the grading tests + full suite |
| `GRADING_TESTS` | Space-separated list of test files for the grading tests |
| `GRADING_PATCH` | Relative path to the grading patch (always `grading.patch`) |

### Grading

`bench/grade.sh` applies `grading.patch` (test-only diff) to the run's
working tree, then runs `TEST_CMD`. The grading = **grading tests** (the
specific test files from `GRADING_TESTS`) + **full suite** with
`--deselect tests/test_utils/test__expand_args.py::test_expand_args`
(a known macOS failure). If the agent edited the same test files the patch
touches, `git apply` fails and the run is scored as a failure with
`error: "git apply failed"` (documented edge case: test-editing is not
verifiable).

### Deselection note

`tests/test_utils/test__expand_args.py::test_expand_args` is deselected
from the full-suite grading run because it fails on macOS (known upstream
issue). The grading tests themselves do not include this test.

## Safe execution (docs: §safe-execution)

Every git/uv/pytest command in the harness (setup-run.sh, grade.sh,
SETUP_CMD, TEST_CMD) is wrapped in `timeout` and runs with:

```
GIT_TERMINAL_PROMPT=0
EDITOR=true
VISUAL=true
PAGER=cat
GIT_PAGER=cat
```

This prevents:
- **git credential prompts** — `GIT_TERMINAL_PROMPT=0` forces immediate
  failure instead of hanging waiting for input.
- **editor hangs** — `EDITOR=true` / `VISUAL=true` make any editor
  invocation a no-op (used by `click.edit` tests and any git commands
  that might invoke an editor).
- **pager hangs** — `PAGER=cat` / `GIT_PAGER=cat` prevent `less` or
  `more` from waiting for a keypress.
- **infinite waits** — `timeout 120` (or 300/600 for longer operations)
  bounds every command.

The BATS test harness itself runs under `timeout 300 bats bench/tests
</dev/null` — stdin from `/dev/null` so no test can wait for input.

## Contamination guard (docs: §contamination-guard)

The run repo must contain **only** the `BASE_SHA` commit and its
trees/blobs. No refs, no tags, no other commits. The `FIX_SHA` commit
object must never exist in the run repo.

### How it works

`setup-run.sh` builds the run repo with:

```bash
git init -b "bench/<arm>/<run>" "$repo_dir"
git fetch --depth=1 "$REPO" "$BASE_SHA"
git checkout -b "bench/<arm>/<run>" FETCH_HEAD
```

`git fetch --depth=1` fetches exactly one commit (BASE_SHA) and its
object graph. No refs, no tags, no other commits are fetched. After the
fetch, the script:

1. Verifies `git rev-list --count HEAD` = 1 (exactly one commit
   reachable). Fails with exit 2 if more leaked in.
2. Removes any remaining remote (`git remote remove origin`) so the agent
   cannot re-fetch.
3. Sets `push.default=nothing` so `git push` with no args pushes nothing.
4. Sets `remote.origin.pushurl=pi-delegate-push-disabled://dead` as
   belt-and-braces (no remote exists, but the config key is harmless).

### BATS verification

The `setup-run.sh: contamination guard — later commit is unreachable`
BATS test uses a local throwaway repo with two commits (BASE and FIX).
After `setup-run.sh` fetches only BASE, it verifies:
- `git rev-list --count HEAD` = 1
- `git rev-parse FIX_SHA^{commit}` fails (FIX_SHA is not in the object DB)

This proves the FIX commit is unreachable in the run repo.

### Why it matters

Without the contamination guard, a full `git clone` would fetch all
branches, tags, and commits. The agent could then run `git log --all`,
`git diff BASE..FIX`, or `git show FIX` to find the historical fix
without actually implementing it. The contamination guard prevents this
by ensuring the FIX commit object never enters the run repo.

## Per-run pipeline

```
bench/setup-run.sh <task> <arm> <run>   # fetch BASE_SHA, create branch, run SETUP_CMD
bench/run-arm.sh    <task> <arm> <run>  # run claude -p (arm A) or claude + pi-delegate (arm B)
bench/grade.sh      <task> <arm> <run>  # apply grading.patch, run TEST_CMD
bench/collect.sh    <task> <arm> <run>  # one JSON line per run, jq-validated
```

### setup-run.sh

- Fetches `BASE_SHA` from `REPO` into `$BENCH_OUT/<task>/<arm>/<run>/repo`
  (**outside any repo**, **contamination guard** — no refs, no tags, no
  other commits).
- Creates branch `bench/<arm>/<run>`.
- Disables push: `push.default=nothing` + dead pushurl.
- Runs `SETUP_CMD` (creates venv, installs deps) in the repo dir.
- Secret-file scan (`.env`, `.env.*`, `*.pem`, `*.key`) — refuses (exit 3)
  if any are present (mirrors the pi-oneshot safety preflight).
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

### grade.sh

- Applies `grading.patch` to the run's working tree.
- Runs `TEST_CMD` (grading tests + full suite with deselection) in the repo
  dir.
- Writes `grade.json` with pass/fail.

### collect.sh

- Parses all run captures into one JSON line (claude metrics, pi calls,
  grade result, wall clock).
- Validates with jq before emitting.

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
  "task": "click-sentinel-pickle", "arm": "B", "run": 1,
  "model": "claude-sonnet-5-5",
  "permission_mode": "auto",
  "pi_delegate_commit": "be98114…",
  "target_commit": "3cbcf9b…",
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

- **MVS (minimum viable slice)**: `click-sentinel-pickle` (MECHANICAL) +
  `click-param-source` (INTRICATE) × 3 runs × 2 arms — run this first to
  surface runaway runs cheaply.
- **Full matrix**: all 5 tasks × ≥3 runs × 2 arms.
- Worst-case arm-B run ≈ 6 × (PI_TIMEOUT 1800 s + PI_KILL_AFTER 30 s) ≈ 3 h.

## How to run

```bash
# MVS, one run per arm on the mechanical task (pipeline dry run)
bench/setup-run.sh click-sentinel-pickle A 1
bench/run-arm.sh    click-sentinel-pickle A 1
bench/grade.sh      click-sentinel-pickle A 1
bench/collect.sh    click-sentinel-pickle A 1
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
- The contamination guard relies on `git fetch --depth=1` not fetching
  additional objects. A future git version change could alter this
  behaviour; the BATS test verifies the guard on every run.
