# Benchmark Results

Sections 1-6 are the first run (arm B = the since-removed `pi-review-loop`);
section 7 and later measure the current `delegate` skill.

## First MVS run

Date: 2026-06-18 · Tasks: 2 · Runs: 3 × 2 arms · Model: `claude-sonnet-5-5`

---

## 1. What was measured

| | Arm A | Arm B |
|---|---|---|
| Claude model | `claude-sonnet-5-5` | same |
| Permission mode | `auto` | `auto` |
| Plugin | none (fresh `CLAUDE_CONFIG_DIR`) | `pi-delegate` @ `486c0d1` |
| Delegation | n/a | `pi-review-loop` (chosen by Claude in all 6 B runs) |
| pi model | n/a | `RedHatAI/Qwen3.8-27B-INT4` (self-hosted) |
| Target fork | `randomm/click` | same |
| Interleaved | yes | yes |

**Operator decision criteria:**
- **Primary:** Claude token / cost savings
- **Secondary (gate):** quality at par (objective test pass)
- **Explicitly excluded:** pi/Qwen speed (self-hosted; wall time is not a decision factor)

Protocol & harness details: [docs/benchmark.md](benchmark.md)

---

## 2. Results

### Summary by task and arm

| Task | Arm | n | Pass | mean cost ($) | mean out tok | mean cache_read | mean cache_creation | mean API ms | mean wall ms |
|---|---|---|---|---|---|---|---|---|---|
| sentinel-pickle | A | 3 | 3/3 | 0.0658 | 1781 | 78507 | 8058 | 17376 | 21184 |
| sentinel-pickle | B | 3 | 3/3 | 0.1772 | 3545 | 272735 | 21778 | 36769 | 1009728 |
| sentinel-pickle | **B/A** | — | — | **2.70×** | **2.0×** | **3.5×** | **2.7×** | **2.1×** | — |
| param-source | A | 3 | 3/3 | 0.0866 | 1919 | 117548 | 10976 | 21978 | 27715 |
| param-source | B | 3 | 3/3 | 0.1503 | 2639 | 200105 | 20956 | 34646 | 346955 |
| param-source | **B/A** | — | — | **1.73×** | **1.38×** | **1.70×** | **1.91×** | **1.58×** | — |

**Claude cost ratio:** sentinel-pickle **2.70×** · param-source **1.73×**

### Per-run detail

| Task | Arm | Run | Pass | cost ($) | out tok | cache_read | cache_creation | API ms | wall ms |
|---|---|---|---|---|---|---|---|---|---|
| sentinel-pickle | A | 1 | ✓ | 0.0594 | 1542 | 59932 | 7998 | 15137 | 16966 |
| sentinel-pickle | A | 2 | ✓ | 0.0558 | 1404 | 60250 | 7422 | 14635 | 21802 |
| sentinel-pickle | A | 3 | ✓ | 0.0821 | 2398 | 115339 | 8754 | 22355 | 24783 |
| sentinel-pickle | B | 1 | ✓ | 0.1431 | 2835 | 189853 | 19197 | 27896 | 483582 |
| sentinel-pickle | B | 2 | ✓* | 0.1848 | 3542 | 280710 | 23287 | 37935 | 2310391 |
| sentinel-pickle | B | 3 | ✓ | 0.2036 | 4259 | 347642 | 22851 | 44477 | 235211 |
| param-source | A | 1 | ✓ | 0.0789 | 1841 | 101242 | 10042 | 19124 | 23294 |
| param-source | A | 2 | ✓ | 0.0980 | 2078 | 130465 | 12779 | 22598 | 29787 |
| param-source | A | 3 | ✓ | 0.0830 | 1838 | 120936 | 10106 | 24211 | 30065 |
| param-source | B | 1 | ✓ | 0.1596 | 2906 | 228185 | 21205 | 34988 | 344235 |
| param-source | B | 2 | ✓ | 0.1522 | 2670 | 203455 | 21189 | 46536 | 534592 |
| param-source | B | 3 | ✓ | 0.1391 | 2341 | 168675 | 20475 | 22414 | 162037 |

\*sentinel-pickle B2: the loop's review pi call timed out, so this pass was
reached with Claude's own review standing in for the loop's review; the
objective grading tests still passed (see [§4](#4-anomaly--sentinel-pickle-b2)).

### pi tokens per B run (context only — reported cost $0, self-hosted)

| Task | Arm | Run | pi in | pi out | pi cache_read | pi total |
|---|---|---|---|---|---|---|
| sentinel-pickle | B | 1 | 86068 | 14511 | 1324960 | 1425539 |
| sentinel-pickle | B | 2 | 108732 | 15441 | 2245376 | 2369549 |
| sentinel-pickle | B | 3 | 56385 | 9787 | 424928 | 491100 |
| param-source | B | 1 | 69490 | 7668 | 642880 | 720038 |
| param-source | B | 2 | 94959 | 11860 | 1473920 | 1580739 |
| param-source | B | 3 | 60799 | 5958 | 479808 | 546565 |

---

## 3. Findings

**Quality is at par.** Test outcome is at par: all 12 valid runs (6 per
arm) pass the grading tests. Two caveats on how those 12 are counted:

- One run (param-source, arm A run 1) was re-run after a broken test
  environment (unpinned pytest 9) was fixed. The re-run — the param-source
  A1 shown in the tables — is one of the 12; the broken first attempt is
  excluded and not counted.
- Sentinel-pickle B2 (marked ✓* above) passed with Claude's own review
  standing in for the loop's timed-out review; the objective grading tests
  still passed.

Note that pass/fail grading does not distinguish between passing solutions of
different quality — this only measures whether the graded tests pass.

**Arm B used more Claude, not less.** Two data points; consistent with a
roughly fixed per-task overhead, not yet distinguishable from other
explanations — the larger-task experiment in §5 would test it:

| Task | Claude cost ratio (B/A) | Absolute overhead (B−A mean) |
|---|---|---|
| sentinel-pickle (mechanical) | 2.70× | +$0.111 |
| param-source (intricate) | 1.73× | +$0.064 |

**Where the overhead comes from:**

1. **Skill text loaded into context** — cache_creation roughly doubles
   (sentinel: 8058 → 21778; param-source: 10976 → 20956), because the
   skill's developer and reviewer prompts are injected into every pi call.
2. **Launch / wait / summary turns** — arm B has extra Claude turns to
   launch the loop, wait for pi to finish, and read back the summary.
3. **Claude re-verifying pi's work** — after the loop's own adversarial
   review, Claude re-runs tests and reads the diff to confirm the result
   before reporting completion. This contributes to the wall-clock gap —
   though wall time is explicitly not a decision factor here.

Both tasks are small (arm A finishes in ~15–25 s of API time). **This
data says nothing yet about larger tasks** where the fixed overhead
would be amortised over more Claude work.

---

## 4. Anomaly — sentinel-pickle B2

The review pi call in run B2 hit `PI_TIMEOUT` (1800 s) on the slow
self-hosted endpoint → `PI_ERROR` (exit 3). Claude reported the timeout
honestly, reviewed the diff itself, and graded the run as pass.

**Part 1 (sentinel-pickle) was collected with the harness before PR #76**,
so B2's recorded `pi_call_count` is 1 although the loop made 2 calls — the
timed-out review call wasn't recorded. B2's pi token totals in the table
above therefore cover the develop call only. Part 2 (param-source) was
collected after PR #76, which added per-call records in `pi-calls.d/`.

---

## 5. Next experiments (not yet done)

| # | Experiment | Hypothesis |
|---|---|---|
| 1 | **Arm C**: pi develops, Claude reviews in-session (replaces Claude's duplicate verification; cheap approximation: prompt Claude to use `pi-oneshot` and then review the diff) | Reduces Claude re-verification overhead |
| 2 | **Larger multi-file tasks** (≥3 files changed) | Find the break-even point where delegation cost savings exceed the fixed overhead |
| 3 | **Slimmer SKILL.md** — move long-run launch/wait/abort blocks into a script | Cuts the fixed per-task skill-text overhead |

---

## 6. Caveats

- **n = 3** per cell; small sample, no confidence intervals.
- **Two small tasks** only (MVS subset of the 5-task matrix).
- **One Claude model** (`claude-sonnet-5-5`); no cross-model comparison.
- **Self-hosted pi model** (`RedHatAI/Qwen3.8-27B-INT4`); reported cost
  is $0 — token counts only, no dollar comparison possible for pi.
- Dollar figures are Claude's reported `cost_usd` under the subscription
  rate; not API list price.

---

## 7. Follow-up: script-backed `pi-oneshot` (issue #78)

Same two click tasks, arm B delegating through the slimmed `pi-oneshot`
(a ~25-line SKILL.md; the preflight/launch/wait/abort logic lives in
`run.sh`; the result is one compact tool output and Claude is told not to
re-verify a clean result). Claude cost per run, USD, pass in all runs
except the first v1 attempt below:

| Task | Arm A (n) | Arm B (n) | B/A |
|---|---|---|---|
| sentinel-pickle | 0.082, 0.062, 0.104 (3) | 0.057, 0.057, 0.056 (3) | 0.69× |
| param-source | 0.085, 0.069 (2) | 0.064, 0.067 (2) | 0.85× |

Arm B now costs less Claude than plain Claude. The first v1 attempt
(sentinel-pickle B2) failed because the skill did not tell Claude to raise
the Bash tool timeout: the wait was cut at the 120 s default and Claude
ended its turn while pi was still running. The skill now says
`timeout: 590000`. Caveats: n = 2-3, run concurrently, one Claude model;
`pi-review-loop` was not re-measured.

---

## 8. Quick benchmark, single `delegate` skill with `--verify`

`bench/quick.sh -n 2` (4 tiny local tasks, 2 runs per arm, run concurrently;
pass = hidden check AND the task's own tests; `lines` = diff size). 16/16
runs passed in both arms. Claude cost, USD (sum over runs):

| Task | Plain Claude | With pi-delegate |
|---|---|---|
| json-flag | 0.097 | 0.092 |
| ledger | 0.202 | 0.113 |
| merge-ranges | 0.084 | 0.092 |
| slugify | 0.083 | 0.090 |
| **Total** | **0.466** | **0.386 (REWARD +0.17)** |

Reading: on the three tiny tasks delegation is break-even (slightly more
expensive: the skill text plus one tool round-trip cost about what pi saves);
on `ledger` it is 44% cheaper. Scope note: pi's `ledger` diffs were larger
(132-143 changed lines vs 78-81), mostly extra tests. Caveats: n = 2, rough
costs, one Claude model, one self-hosted pi model, and the click tasks were
not re-run with `--verify`.
