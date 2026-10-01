# pi-delegate

Delegate coding work to a cheap headless agent — [pi](https://pi.dev) — while
your orchestrating agent (Claude Code or another CLI harness) judges the
result. **Cheap model builds, strong model judges:** the expensive part is the
judgment, and this keeps it on the model you already trust.

## Why

Your top model interprets your intent and judges the result — reading and
judging are cheap, and that is its job. pi does the expensive part — reading
the codebase, writing files, running tests — without spending your top model's
context. `pi-review-loop` makes the cheap output only admissible after an
adversarial reviewer passes it, so "trust the cheap model" becomes "trust the
cheap model *after an adversarial pass*".

## Quick start

### 1. Install

Prerequisites: a working `pi` (step 2 sets it up) and `jq`. On macOS,
`brew install jq coreutils` installs the GNU timeout binary that bounds each
pi call (the timeout contract is documented in
[configuration](docs/configuration.md#pi_timeout--seconds-allowed-per-pi-invocation-default-1800)).

Primary — install as a Claude Code plugin:

```
/plugin marketplace add randomm/pi-delegate
/plugin install pi-delegate@pi-delegate
```

The skills are namespaced: `/pi-delegate:pi-oneshot` and
`/pi-delegate:pi-review-loop`. Update: `/plugin marketplace update pi-delegate`
(or `claude plugin update pi-delegate` from your shell). Uninstall:
`claude plugin uninstall pi-delegate`.

Manual fallback — copy the skills into `~/.claude/skills/`:

```bash
git clone https://github.com/randomm/pi-delegate.git
mkdir -p ~/.claude/skills
cp -R pi-delegate/skills/pi-review-loop ~/.claude/skills/
cp -R pi-delegate/skills/pi-oneshot ~/.claude/skills/
```

If you already have a manual install and switch to the plugin, remove the
manual copies (`rm -rf ~/.claude/skills/pi-review-loop ~/.claude/skills/pi-oneshot`)
after the plugin works — verify the plugin first.

### 2. Set up pi once

Install pi (either works):

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
# or
curl -fsSL https://pi.dev/install.sh | sh
```

Authenticate — either export an API key (e.g. `export ANTHROPIC_API_KEY=…`
then `pi`), or run `pi` and use `/login` to pick a provider.

Pick and save a default model: in `pi`, use `/model` (press Ctrl+S in the
picker to save the highlighted model as the startup default).

Verify headless mode works:

```bash
pi -p "say ok"
```

Note: GUI apps (e.g. a Claude Code desktop app) do not inherit your shell's
`PATH` — if a skill says pi is not found, check `~/.bun/bin` or
`~/.local/bin` is on `PATH` for that app.

### 3. First delegation

Ask your agent for a trivial one-shot task:

```
delegate to pi: write a bash function that prints today's date in ISO format
```

The skill reports back with a summary of pi's output (pi prints its final
text on stdout in plain-text mode, and the exit code is 0 on success).
`pi-oneshot` makes a single text-mode call and has no review loop, so there
is no verdict to read; the review loop is where `provider/model` and verdict
logging appear — see [how it works](docs/how-it-works.md#verdicts).

## The skills

**`pi-oneshot`** — invoke as `/pi-delegate:pi-oneshot` (or "delegate to pi:
…"). One headless `pi -p --no-session` call with pi's full toolset, text mode,
no review loop: best for mechanical, self-contained, verifiable tasks. The
call is per-call bounded with a documented timeout wrapper — see
[configuration](docs/configuration.md#pi_timeout--seconds-allowed-per-pi-invocation-default-1800).

**`pi-review-loop`** — invoke as `/pi-delegate:pi-review-loop` (or "run the
review loop: …"). Runs `orchestrate.sh`, a deterministic bash driver: one
develop round, up to 3 read-only adversarial review rounds, up to 2 fix rounds
(hard cap 6 pi calls). All progress goes to stderr; exactly one JSON summary
is the last line of stdout (`status`, `verdict`, `rounds`, `total_pi_calls`,
`findings`, `raw_output`). Long runs exceed the Bash tool's foreground
ceiling: launch the run detached, record its pid, and wait with bounded
foreground calls — see
[configuration → Long runs](docs/configuration.md#long-runs-under-claude-codes-bash-tool).

Both skills are packaged as Claude Code skills, but `orchestrate.sh` is plain
bash with a small documented contract — usable from any agent harness.

![pi-delegate architecture: an orchestrating agent (Claude Code · Codex · any CLI
harness) calls either the pi-oneshot skill (one single pi call, full tools,
text output) or the pi-review-loop skill, which wraps orchestrate.sh; inside the
review loop (max 3 rounds) a full-tools pi developer produces a diff, a
read-only pi adversarial reviewer ends with a VERDICT and sends findings back
for fixes, repeating until approved or the round budget runs out; the verdict
and findings (status · verdict · findings) are read back by the agent.](docs/images/pi-delegate-architecture.png)

## Safety

pi has no sandbox. The skills refuse to run (exit 3, `REFUSED:` on stderr)
when the current branch is the repo's default branch, or when secret-looking
files (`.env`, `*.pem`, `*.key`, …) are present in the working tree, and they
neutralise `git push` for every pi process. **Real isolation is a feature
branch, a disposable clone/worktree, or a container** — use one of those; set
`PI_DELEGATE_UNSAFE=1` only when you have arranged real isolation and want to
opt out of all three guards. Details in
[troubleshooting](docs/troubleshooting.md#refused--safety-preflight).

## Docs

- [Configuration](docs/configuration.md) — environment variables, flags, the
  timeout wrapper, and long runs
- [Troubleshooting](docs/troubleshooting.md) — exit codes, `pi not found`,
  auth, INCOMPLETE, REJECTED, and the safety preflight
- [How it works](docs/how-it-works.md) — architecture, loop sequence, verdicts,
  JSON schema, prompt flow, and the cost rationale

## Benchmark

First MVS benchmark (2 tasks × 3 runs × 2 arms): quality at par (12/12 pass);
on small tasks, Claude cost was **~1.7–2.7× higher** with delegation. See
[benchmark results](docs/benchmark-results.md).

## License

Licensed under the Apache License, Version 2.0 — see LICENSE. Copyright 2026
Janni Turunen.
