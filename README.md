<h1 align="center">pi-delegate</h1>

<p align="center"><strong>Claude Code plans and checks. A cheaper model does the heavy lifting.</strong></p>

<p align="center">
  <img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue">
  <img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude%20Code-plugin-black">
  <img alt="bash + jq" src="https://img.shields.io/badge/built%20with-bash%20%2B%20jq-lightgrey">
</p>

<p align="center">
  <img src="docs/images/pi-delegate-flow.svg" width="880" alt="You ask Claude Code to delegate; Claude writes a brief; run.sh runs safety checks; pi, on any model you pick, reads, edits and runs your tests; your verify command decides, with one retry; Claude gets a short result. On multi-file tasks Claude's cost falls from $0.082 to $0.055 (-33%) because the work moves to pi.">
</p>

Say "delegate to pi" and the heavy part of a coding task (reading files, editing, running tests) runs on
[pi](https://pi.dev), an open-source coding agent that can drive any model you pick, even one on your own
machine. Claude only writes the brief and reads a short result, and your tests decide whether it worked.

> [!TIP]
> On multi-file tasks, delegating cut Claude's cost by **a third (−33%)** with every hidden test still passing.

| | Plain Claude | With pi-delegate | Verdict |
|:--|:--:|:--:|:--|
| 🧩 **Multi-file features** | $0.082 | **$0.055** | ✅ **−33%** Claude cost |
| ✏️ **Tiny edits** (ten-line fixes) | $0.042 | $0.047 | ⚠️ +11%: do these yourself |
| 🧪 **Hidden checks passing** | 28 / 28 | 28 / 28 | ✅ same quality |

> [!NOTE]
> **The honest fine print.** The numbers count Claude's cost only: pi's own spend comes on top (nothing if you
> self-host, cents on a hosted cheap model). Delegated runs are also slower, several times in our runs on a
> self-hosted pi (about 25 s plain vs 2-3 minutes). Samples are small (2 runs per task); the benchmark takes
> about five minutes to rerun yourself ([how](#rerun-the-benchmark)).

## Is it for you?

| ✅ A good fit | ❌ Not a fit |
|:--|:--|
| You use Claude Code and your tasks touch several files | Quick one-file edits (Claude alone is cheaper) |
| You want fewer Claude tokens, or less of your usage limit, spent on routine implementation | Tasks with no way to check the result |
| You have a test command that can say whether the work is right | Speed matters more than cost |

## Install (Claude Code)

**1. Add the plugin**

```
/plugin marketplace add randomm/pi-delegate
/plugin install pi-delegate@pi-delegate
```

**2. Set up pi once**

```bash
npm install -g @earendil-works/pi-coding-agent   # then run `pi`, /login (or export an API key), /model
```

Cheap and local models work; the benchmark used a self-hosted Qwen. Also install `jq`, and on macOS
`brew install coreutils` for the `timeout` that bounds each pi call.

## Use

> delegate to pi: add a `--json` flag to cli.py, verify with `python3 -m unittest`

Claude makes one call, pi does the work, and your verify command decides whether it worked:

```
EXIT CODE: 0
<pi's summary>
VERIFY: PASS (retries=0)
 cli.py | 12 +++++++++---
```

If verification fails, pi gets one more attempt with the failure output. If it still fails, Claude says so
instead of claiming success.

## How quality is kept

- **A deterministic gate, not a second opinion.** `--verify "<your tests>"` runs after pi. No model reviews the
  work: a same-model reviewer approves most changes, tests don't.
- **Claude is told not to redo the work** when the gate passes. Re-reading the diff and re-running the tests is
  exactly what ate the savings in our first benchmark.
- **Guardrails:** it refuses to run on your default branch or next to `.env`/`*.pem`/`*.key` files, and disables
  `git push` for pi. This guards against mistakes, not a malicious model. For stronger isolation set
  `PI_DELEGATE_WRAP` (sandbox recipes in [docs/configuration.md](docs/configuration.md#sandbox-optional)) or use a
  disposable clone or container.

## Other agents

`skills/delegate/run.sh` in this repo is plain bash. Any agent that can run a shell command can use it:

```bash
git clone https://github.com/randomm/pi-delegate.git
bash pi-delegate/skills/delegate/run.sh --verify "pytest -q" <<'TASK'
Fix the failing date parsing in utils.py; do not commit.
TASK
```

## Rerun the benchmark

```
bench/quick.sh -n 3     # about five minutes: plain Claude vs Claude + pi-delegate, prints a REWARD score
```

Method, tasks and the slower real-repo protocol: [docs/benchmark.md](docs/benchmark.md) ·
[results](docs/benchmark-results.md). Settings (timeouts, safety, sandbox): [docs/configuration.md](docs/configuration.md).

## License

Apache License 2.0, see LICENSE. Copyright 2026 Janni Turunen.
