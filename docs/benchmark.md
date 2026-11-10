# Benchmark Protocol

> The review-loop skill this protocol was first run against has been
> removed (see `docs/benchmark-results.md`); arm B now delegates through the
> single `delegate` skill. References below to `pi-review-loop`, `--mode json`
> calls and `pi-oneshot` describe the harness's handling of both call modes.

Benchmark: plain **Claude Code** (arm A) vs **Claude Code + pi-delegate**
(arm B) on the same tasks in the same target repo. Measures tokens,
wall-clock, and outcome quality (objective test pass/fail).

## Arms

| | Arm A | Arm B |
|---|---|---|
| Claude model | `sonnet` (resolves to `claude-sonnet-5-5`) | same |
| Permission mode | `auto` (fixed, documented) | same |
| Plugin | none (fresh `CLAUDE_CONFIG_DIR`, no plugins) | `pi-delegate` installed at pinned commit |
| Prompt | `prompt.md` (task body verbatim) | `prompt.md` + delegation suffix directing use of the `delegate` skill |
| pi shim | installed (logs any accidental pi call) | installed (logs all pi calls) |
| pi context files | n/a | `--no-context-files` (the shipped `run.sh` default since #94; the shim re-injects it idempotently) |

`--no-context-files` is what `skills/delegate/run.sh` passes on every pi call,
so arm B's pi is configured the way a user's is. The opt-in
`PI_DELEGATE_CONTEXT_FILES=1` (`docs/configuration.md`, §project-context-files)
changes behaviour outside the harness only: inside these runs the shim injects
the flag regardless, so the opt-in is a no-op the harness cannot observe.

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

`task.env` is **sourced** by the harness (KEY=VALUE shell file) and must be
**operator-authored** — anything in it executes in the harness's shell.

| Field | Purpose |
|---|---|
| `REPO` | `https://github.com/randomm/click.git` (all tasks) |
| `BASE_SHA` | Full 40-char SHA of the base commit (the commit the agent starts from) |
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
(a known macOS failure). Grading patches must be unified git diffs
(`git diff` or `git diff --no-index`); `grade.sh` derives the file list
from the per-file `--- `/`+++ ` header lines, so paths containing
spaces or ` b/` are preserved intact, and the `--- /dev/null` /
`+++ /dev/null` created/deleted-file forms are recognised.
A patch with no parseable file headers is a setup error: `grade.sh`
records `pass: false` with `error: "grading patch has no file headers: …"`
and exits 2.
Before applying, `grade.sh` restores every file
the patch touches to its recorded `BASE_SHA`, and a restore failure is a
setup error: the run is recorded as a failure in `grade.json`
(`pass: false`, `error: "restore failed for <path>: …"`) and `grade.sh`
exits 2, rather than silently grading a tree that was never normalised.
A run whose repo HEAD is not the recorded base (the agent committed its
work) is still graded normally — restore and `git apply` target the
recorded base and tests run on the working tree — but is flagged
`head_moved: true` in `grade.json` (false otherwise) on every exit path,
so consumers can distinguish committed runs from the normal uncommitted
flow.

**Contamination note:** `grading.patch` is the *sole* location of the issue
URLs and fix details for a task. It lives in the task dir (`bench/tasks/<id>/`),
NOT in the run repo, and is only read by `grade.sh` at grading time — after
the run has ended. The agent runs in the run repo (`<run-dir>/repo/`), which
contains only the BASE commit and no reference to the task dir, so the
grading patch is unreachable during the run. (The agent *can* list
`$TASKS_DIR` in theory, but it has no reason to do so, and the task dir is
outside the run repo's filesystem scope for the run.)

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
3. Sets `push.default=nothing` so `git push` with no args pushes nothing
   (no remote exists, so there is nothing to push to in any case).

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
- Disables push: `push.default=nothing` (no remote is configured, so
  there is nothing to push to).
- Runs `SETUP_CMD` (creates venv, installs deps) in the repo dir.
- The test toolchain in `SETUP_CMD` is version-pinned (e.g.
  `"pytest>=8,<9"`) for reproducibility: an unpinned install drifts with
  time (a fresh `uv pip install pytest` now pulls pytest 9.x, whose
  `PytestRemovedIn10Warning` on non-Collection iterables is fatal under
  the click repo's `filterwarnings=error` and breaks the base suite of
  the May 2026 base commits). The pin matches the era of each task's
  base commit.
- Secret-file scan (`.env`, `.env.*`, `*.pem`, `*.key`) — refuses (exit 3)
  if any are present, pruning dependency dirs by name at any depth
  (`node_modules`, `.venv`, `venv`, `site-packages`, `vendor`, `.git`).
  Mirrors the safety preflight in `skills/delegate/run.sh`; unlike run.sh this
  copy has no per-check opt-out, since the scan runs before `SETUP_CMD`.
- Writes `setup.json`.

### run-arm.sh

- Creates a per-run `CLAUDE_CONFIG_DIR` (isolation).
- Arm B only: clones the pinned pi-delegate commit (`PI_DELEGATE_SHA`,
  resolved from `PI_DELEGATE_REPO`, default: the **local** pi-delegate repo
  root derived from the harness location — the pi-delegate repo is **private**
  and arm B never depends on GitHub access) into
  `$BENCH_OUT/pin/pi-delegate-<sha>` (keyed by SHA only, shared by all runs
  and arms), verifies `git rev-parse HEAD == PI_DELEGATE_SHA` and the
  presence of `.claude-plugin/marketplace.json`, then installs the plugin
  into the config dir via the supported CLI — `claude plugin marketplace add
  <pin_dir>` (from the **local** pin directory, never a remote URL) then
  `claude plugin install pi-delegate@pi-delegate` — and verifies with
  `claude plugin list --json`. The CLI's stdout/stderr is captured in
  `<run-dir>/plugin-install.log` and printed on failure. A plugin install
  failure ABORTS arm B (exit 2). Arm B also ABORTS (exit 2) if `pi` is not
  found on PATH; arm A may proceed without a shim.
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
  (`--no-context-files` or `-nc` counts as present). Since #94 the shipped
  `run.sh` passes the flag itself, so for a run against the pinned commit this
  is a no-op; the injection still enforces the operator decision for any call
  path that does not.
- **`--mode json` calls** (pi-review-loop): tees pi's stdout (one JSON event per
  line) to `<run-dir>/pi-<call_id>.jsonl`; collect.sh parses usage from the
  last assistant `message_end`.
- **text-mode calls** (pi-oneshot): records argv + wall clock + exit code only.
  The per-call token count is **not available** in text mode — collect.sh
  reports `tokens: null` for those calls (documented gap, §metrics).
- **Never injects `--mode json`** — the shim must not change skill behaviour.
  For pi-oneshot this means a documented token-accounting gap rather than a
  silent behaviour change.
- Records one JSON object per call in `<run-dir>/pi-calls.d/<call_id>.json`:
  written atomically at start (with `exit: null`) and atomically replaced on
  completion or TERM/INT. A SIGKILLed call keeps `exit: null` and is still
  counted. Each call owns its own file, so concurrent calls never clobber
  each other's record. This directory is the ONLY pi-call source — the
  legacy `pi-calls.jsonl` file is no longer read.
- Prints pi's captured output to its own stdout so Claude's Bash tool sees
  the same text it would have without the shim.
- Refuses to nest: a real pi whose file contains the marker string
  `# pi-delegate-bench-shim` (written into every generated shim) is refused
  at install time.

## Metrics (one JSON line per run, `collect.sh`)

```json
{
  "task": "click-sentinel-pickle", "arm": "B", "run": 1,
  "model": "claude-sonnet-5-5",
  "permission_mode": "auto",
  "pi_delegate_commit": "<pinned sha>",
  "target_commit": "3cbcf9b…",
  "claude": {
    "cost_usd": 0.42, "duration_ms": 42000, "duration_api_ms": 40000,
    "permission_denials": [ … ], "is_error": false,
    "model_usage": { "<model>": { "input_tokens": …, "output_tokens": …,
      "cache_read": …, "cache_creation": …, "cost_usd": … } },
    "resolved_models": [ "…" ]
  },
  "pi": [
    { "argv": [ … ], "duration_ms": 5000, "exit": 0, "mode": "json",
      "call_id": "…",
      "tokens": { "input": …, "output": …, "cache_read": …, "cache_write": …, "total": …,
        "per_model": { "<model>": { "input": …, "output": …, "cache_read": …,
          "cache_write": …, "total": … } } } },
    { "argv": [ … ], "duration_ms": 2000, "exit": 0, "mode": "text",
      "call_id": "…", "tokens": null }
  ],
  "pi_call_count": 2,
  "delegation_exercised": true,
  "pi_tokens_total": { "<model>": { "input": …, "output": …, "cache_read": …,
    "cache_write": …, "total": … } },
  "grade": { "pass": true, "test_cmd": "…", "error": null },
  "agent_ms": 900000,
  "wall_clock_ms": 900000
}
```

`collect.sh` **validates with a single jq program** before emitting:
required fields present (`task`, `arm`, `run`, `grade`), a **null grade
never passes validation**, `grade.pass` boolean, `claude.duration_ms` /
`claude.duration_api_ms` / `claude.cost_usd` numeric-or-null, `pi_call_count`
numeric, `pi_tokens_total` object-or-null, and `pi[].duration_ms` and
`pi[].tokens.*` numeric when non-null. A malformed run fails loudly (exit 2)
instead of polluting the report. Duplicate `task`/`arm`/`run` lines (i.e.
duplicate pi-call records in `pi-calls.d`) are refused.

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

The OAuth token must be passed on the command line as an env prefix — never
as a standalone export (a stray `echo $CLAUDE_CODE_OAUTH_TOKEN` in an error
path would leak it into a log or terminal history):

```bash
CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -w -s 'Claude Code-credentials' | jq -r .claudeAiOauth.accessToken)" \
  bench/run-arm.sh click-sentinel-pickle A 1
```

After collecting results, scan the run output for any leaked token
(Claude Code OAuth tokens use the `sk-ant-oat01-` prefix, which is why the
grep targets that prefix):

```bash
grep -rl 'sk-ant-oat01-' "$BENCH_OUT" && echo "TOKEN LEAKED" || echo "clean"
```

```
# MVS, one run per arm on the mechanical task (pipeline dry run)
bench/setup-run.sh click-sentinel-pickle A 1
bench/run-arm.sh    click-sentinel-pickle A 1
bench/grade.sh      click-sentinel-pickle A 1
bench/collect.sh    click-sentinel-pickle A 1
# repeat with arm B and run 2/3, then the intricate task

# Full matrix: loop task × arm × run over the task list above.
```

**Disk use:** a task with a Python venv or `node_modules` can use over 1 GB
per run, and parallel runs multiply that. On a small or RAM-backed (tmpfs)
`/tmp`, run the arms one at a time or point `BENCH_OUT` at a disk-backed
path; `setup-run.sh` warns (it does not fail) when under 5 GiB is free under
`BENCH_OUT`. After collecting, clean up with `rm -rf "$BENCH_OUT"`, and also
when a run is abandoned. Do not run it while runs are active: it also removes
the shared `pin/` cache (re-fetched on the next run) and any run not yet
collected. `bench/quick.sh` removes its own temp dir on exit unless `-k` is
given (`-k` prints the path); it starts all tasks x arms x `-n` runs at once,
so `-n` and the task list bound its parallelism.

Environment overrides: `BENCH_OUT`, `CLAUDE_MODEL` (default: the literal
id `claude-sonnet-5-5`), `CLAUDE_PERM_MODE`, `PI_DELEGATE_REPO` (default:
the local pi-delegate repo root derived from the harness location — the repo
is private, so arm B never touches GitHub; a remote URL is only an explicit
override),
`PI_DELEGATE_SHA`, `CLAUDE_TIMEOUT`, `PI_TIMEOUT`, `PI_KILL_AFTER`.

## How to read results

- **Outcome quality**: `grade.pass` (the objective test standard, identical in
  both arms).
- **Claude cost**: `claude.cost_usd` + `claude.model_usage` (tokens per model).
- **pi cost**: `pi[].tokens` per call; sum per arm and apply the stated cost
  basis before comparing to arm A.
- **Time comparison**:
  - `claude.duration_ms` — Claude's **session wall clock** (includes tool
    execution and any foreground Bash calls waiting on pi). **Not** pure API
    time; can be smaller or larger than `duration_api_ms`.
  - `claude.duration_api_ms` — Claude's **API time only** (model inference
    excluding tool execution). Can exceed `duration_ms` (live evidence:
    29904 > 20690 in dry-run 4 arm B).
  - `wall_clock_ms` — run wall clock (Claude start → end), ms resolution.
    Uses `run-meta.json` `started_ms`/`ended_ms` when present; falls back to
    second-resolution `started_at`/`ended_at`; then `setup_at`→`graded_at`.
  - `agent_ms` — harness-side start→claude-exit, ms resolution (from
    `run-meta.json`). The **primary cross-arm comparison metric** (includes
    pi wait time for arm B).
- **Delegation flag** (arm B only):
  - `pi_call_count` — number of pi calls (0 if `pi-calls.d` is absent or
    empty).
  - `delegation_exercised` — arm B: `true` iff `pi_call_count > 0`; arm A:
    `null` (arm A's pi calls are accidental and not a delegation signal).
  - Arm-B runs with `delegation_exercised == false` are **skill failures**
    (Claude never invoked pi). Filter them out before computing arm-B
    averages: `jq 'select(.arm == "B" and .delegation_exercised == true)'`.
  - The flag does **not** rewrite `grade.pass`; a zero-pi arm-B run that
    passes the tests is still `grade.pass == true` but must be reported
    separately.
- **pi tokens per model**: `pi_tokens_total` — per-model totals summed over
  all json-mode pi calls (input, output, cache_read, cache_write, total).
  Null when no json-mode call recorded usage (all text-mode or no
  transcripts). Use for the pi side of the cost comparison.
- **Intervention proxy**: `claude.permission_denials` under the fixed
  `auto` permission mode.
- **Arm B internals**: `pi[]` call list (loop verdict/rounds are in the
  per-call transcripts `pi-<call_id>.jsonl`), `pi_delegate_commit`.

## Known limitations

- `CLAUDE_CONFIG_DIR` isolation is per-run, not per-arm — two concurrent runs
  of the same arm share nothing (each run has its own config dir).
- The pi shim's `--no-context-files` injection is idempotent but string-based;
  it does not parse `--no-context-files=…` (pi uses the plain form).
- `delegation_exercised` is a proxy: it flags arm-B runs with zero pi calls,
  which usually mean Claude never invoked pi (a skill failure). A run that
  delegated but whose pi call produced no transcript (e.g. a crash before
  the first message) will still have `pi_call_count > 0` and thus
  `delegation_exercised == true` even though no useful work was done.
  Cross-check against `pi[]` entries and per-call transcripts for a
  definitive answer.
- Grading is test-only patch + TEST_CMD; it does not diff the agent's change
  against the historical fix (that would require the non-test diff, which is
  intentionally withheld from the agent to avoid leakage). Before applying
  the patch, `grade.sh` restores every file the patch touches to its BASE
  version (tracked files → `git checkout <base-sha> -- <path>`, where the
  base sha is the recorded `BASE_SHA` from `setup.json`/`task.env`; patch-
  created files → deleted if present) and records the affected files in
  `restored_test_files` in `grade.json`. A run whose repo HEAD is not that
  recorded base (e.g. the agent committed its work) is still graded,
  flagged `head_moved: true` in `grade.json`; a restore failure is a loud
  exit 2 with `error: "restore failed for <path>: …"` in `grade.json`. This makes grading robust to agent
  test-file edits (issue #71 dry-run 4) without leaking the fix to the agent.
- The contamination guard relies on `git fetch --depth=1` not fetching
  additional objects. A future git version change could alter this
  behaviour; the BATS test verifies the guard on every run.

## Quick benchmark (`bench/quick.sh`)

A fast, rough reward function for iterating on the skills — not a
replacement for the protocol above. Tiny local Python tasks
(`bench/quick/tasks/<id>/{repo,prompt.md,check.py}`, hidden check run after
the agent finishes) run plain Claude (A) and Claude + the **working-tree**
plugin (B, via `--plugin-dir`) in parallel, in a couple of minutes:

```
bench/quick.sh                       # all tasks, 1 run per arm
bench/quick.sh -n 2 ledger           # 2 runs, one task
bench/quick.sh -k                    # keep the run dirs for inspection
```

It prints a per-task table grouped by `CLASS` (see "Task-class taxonomy")
with a `fbc=` column (failing hidden-check cases), per-arm summaries with
`fbc=` and `fbc_unknown=`, and
`REWARD = 1 - costB/costA` (forced to -1 if a B run fails its check or
never calls pi). Use it to decide whether a change helps, then confirm on
the real protocol. `fbc` is deliberately named apart from the
`bugs_found_in_verification` metric below, which counts the opposite.

What it showed: delegation is break-even on trivial tasks (`slugify`,
`json-flag`, `merge-ranges`: Claude finishes in 3-6 cheap turns) and wins
once Claude would need real exploration and editing (`ledger`, 6 files:
about -48% Claude cost, same pass rate). The savings come from a thin
skill (one script call, compact result, no re-verification) — a 500-line
skill that makes Claude assemble the launch blocks costs more than it saves.

## Task-class taxonomy (issue #96)

Every task directory carries a `task.env` with two labels:

```
CLASS=MECHANICAL          # or INTRICATE | ASYNC_TIMING | MULTI_FILE_REFACTOR
BRIEF_STYLE=PINPOINT      # or DISCOVERY
```

The classes exist because the ~20-task anecdotal dataset split roughly
half mechanical / half intricate, and mechanical tasks mostly just measure
Claude's knowledge of Python — cheap signal, and it inflated the observed
win rate. Per-class reporting exists so a 1-on-1 win on one
MULTI_FILE_REFACTOR task can never be confused with a win on the suite.

| CLASS | What it probes | Example tasks |
|-------|----------------|---------------|
| `MECHANICAL` | known solution, small edit — measures knowledge + tool overhead | `slugify`, `json-flag` |
| `INTRICATE` | subtle parsing / escape / boundary logic, no obvious solution | `merge-ranges`, `tokenize-lines`, `cache-*` |
| `ASYNC_TIMING` | time-dependent behavior; the model's weakest class — a correct-looking fix ships and the hidden check catches it when the real one hangs or flakes | `debounce-queue` |
| `MULTI_FILE_REFACTOR` | coordinated change across files; the test suite must keep passing | `ledger-*`, `move-report` |

`BRIEF_STYLE` is orthogonal and answers the "vague prompt" half of the
suggestion dataset: `PINPOINT` briefs name the file, the function, the
expected behavior, and the verification command; `DISCOVERY` briefs state
the symptom only and make the model find the defect itself. The pilot
dataset was **all-PINPOINT and never measured this axis** (~20 delegated
tasks: ~8 clean, ~6 good drafts with 1-2 bugs verification caught, ~4-5
weak/unfinished) — there is no per-style success rate to quote, and
`cache-pinpoint` and `cache-discovery` are the paired exemplars built to
produce one: the same buggy repo and the same hidden check, differing
**only** in brief style, so a cost delta between their rows is
attributable to the brief, not to the task.

`ASYNC_TIMING` grading is bounded: the hidden check and the agent's own
`tests/` run under `QUICK_CHECK_TIMEOUT` (default 120 s) — a hang scores
FAIL, it never wedges the harness.

## Retry-feedback experiment (issue #96)

`bench/experiment-retry-feedback.sh` A/Bs the one `run.sh` knob the
dataset blamed for retry waste: the verify-failure tail relayed into the
retry prompt (arm A, reproduced with run.sh's framing — the production
code path itself is untouched; the excerpt is passed through an
**allowlist** filter, see "Keeping the hidden check hidden from both
models") vs a short numbered
instruction list authored by one `claude -p` call (arm B). Metrics per
arm: `retry_success` (did the retry pass verify), `pi_retry_tokens`
(retry-call input tokens, a proxy for prompt size — the "3× more
expensive retries" signal), and `claude_instruction_cost_usd` (arm B's
authoring cost, null for arm A).

One invocation runs both arms over every quick task (or only the ones you
name):

```
bash bench/experiment-retry-feedback.sh            # all tasks, 1 run per arm
bash bench/experiment-retry-feedback.sh -n 10      # 10 runs per arm per task
bash bench/experiment-retry-feedback.sh -k tokenize-lines
```

It needs claude + pi + jq + git on PATH (uses timeout/gtimeout when
present) and uses the quick suite's task template (any
`bench/quick/tasks/*` dir works). Rows are emitted **on stdout** — one
JSON object per run, pipe it to a file if you want to keep it; nothing is
written into the repo and there is no results directory or viewer. A
per-arm summary goes to stderr. `-n` takes runs per arm per task
(positive integer), `-k` keeps the run dirs and prints their path **and
the separate private dir holding the raw verify logs**.
Readout: B pays more per retry attempt (one claude call) — it earns that
back only if `retry_success` is materially higher or `pi_retry_tokens`
drops enough. The harness never implements the task, so the initial
verify fails and every run exercises the retry path. Both pi calls run
**inside** the per-run repo copy (never the invoking tree).

### Keeping the hidden check hidden from both models

Both models get read/bash tools, so anything on disk near their cwd is
readable, and a prompt that quotes it hands out the grading tests. Two
channels were confirmed by reading from inside a real run dir:

- the grader at `$d/check.py` — reachable as `../check.py` from either
  model's cwd, invisible to `author_touched_repo`, which snapshots
  `git status` and so detects **writes**, not reads;
- unittest's **column-0** assertion diff in the failure output —
  `+ ['a""b']` is the hidden expected value itself, with the test names
  and `Ran 8 tests` alongside it, while the old denylist counter reported
  a tidy 6 lines dropped.

So: (1) the grader is staged into a private dir **outside the run tree**
and deleted before `verify` returns, and the raw log stays there (under
`-k` it is never copied into the run dir — sibling run dirs are `../`
from a still-running model); during a model call there is no grading file
anywhere the model can traverse to. (2) The excerpt is an **allowlist**:
only unittest's separators, `FAIL:`/`ERROR:` headers with the
`(__main__.T.<name>)` tail stripped, the `OK`/`Ran`/`FAILED` summaries,
and the terminal `SomeError: message` line survive. Anything naming an
expected value (`AssertionError`, the diff block, any line containing
`!=`) is dropped, and a second pass re-checks the kept lines against the
private/run paths. `feedback_dropped_lines` counts what the allowlist
removed; on a real failure it is large **by design** — read it as "how
much the model did not see", not as a contamination alarm. Arm B's
instruction author also runs outside the graded copy, and a row with
`author_touched_repo: true` is contaminated on the write channel and must
be discarded.

**Read arm A as a lower bound, not as production arm A.** The control
here is run.sh's framing with the tail run through that allowlist, which
also strips unittest's traceback body — the informative part of a
failure. Production arm A gets `tail -n 40` of the operator's own
`--verify` log, unsanitized. A **B-win** here is therefore evidence that
the instruction format helps relative to a deliberately thinned control;
it is **not** an absolute claim that arm B beats the tail `run.sh` ships,
which carries strictly more information than the excerpt does.

## bugs_found_in_verification

A green `pass` can still hide a missing acceptance criterion — the
click-fork sentinel bug shipped through a passing test suite. The metric
captures what grading misses: a human (or a separate model, manually)
reads the diff against the criteria and records how many bugs
verification failed to catch. It is deliberately **recorded, never
model-automated** — AGENTS.md defers model reviewers until a benchmark
pays for their tokens. The analyst writes `<run-dir>/verification-bugs.json`
(`{"count": <int>, "notes": "..."}`); `collect.sh` copies `count` into
every row as `bugs_found_in_verification` — `null` means nobody looked,
`0` means looked and nothing was missed, a malformed file is a malformed
run (exit 2). Report it **separately** from `pass_rate` and never fold it
into REWARD: it is a quality signal, not a gate — like the adversarial
review's finding count.
