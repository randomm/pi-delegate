# pi-delegate

**Hand coding tasks from Claude Code to a cheaper model. Same tests pass, fewer Claude tokens.**

Claude plans and checks; [pi](https://pi.dev) (running any model you choose, even a local one) does the reading,
editing and test-running that burn most of the tokens.

| Claude cost per task (Sonnet 5.5; pi on a self-hosted Qwen) | Plain Claude | With pi-delegate |
|---|---|---|
| Multi-file features (3 tasks, 6 runs each arm) | $0.082 | **$0.055** (−33%) |
| Tiny edits (4 tasks, 8 runs each arm) | $0.042 | $0.047 (+11%) |
| Runs passing the hidden checks | 28 / 28 | 28 / 28 |

Delegation pays off once a task needs real reading and editing across files; on a ten-line fix it costs slightly more, so do those yourself.
Numbers, method and how to rerun them: [docs/benchmark.md](docs/benchmark.md) · [results](docs/benchmark-results.md).

## Install (Claude Code)

```
/plugin marketplace add randomm/pi-delegate
/plugin install pi-delegate@pi-delegate
```

You also need `pi` set up once (`npm install -g @earendil-works/pi-coding-agent`, then run `pi` and `/login` or
export an API key), plus `jq`. On macOS, `brew install coreutils` provides the `timeout` that bounds each pi call.

## Use

> delegate to pi: add a `--json` flag to cli.py, verify with `python3 -m unittest`

Claude makes one call; pi does the work; the project's verify command decides whether it worked:

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
- **Claude is told not to re-do the work** when the gate passes (re-reading the diff is what ate the savings
  in early benchmarks).
- **Guardrails:** it refuses to run on your default branch or next to `.env`/`*.pem`/`*.key` files, and disables
  `git push` for pi. This guards against mistakes, not a malicious model. For real isolation use a disposable
  clone or a container.

## Other agents

`skills/delegate/run.sh` is plain bash. Any agent that can run a shell command can use it:

```bash
bash skills/delegate/run.sh --verify "pytest -q" <<'TASK'
Fix the failing date parsing in utils.py; do not commit.
TASK
```

## Rerun the benchmark

```
bench/quick.sh -n 3     # ~5 minutes: plain Claude vs Claude + pi-delegate, prints REWARD
```

Details, tasks and the slower real-repo protocol: [docs/benchmark.md](docs/benchmark.md).
Settings (timeouts, safety opt-out): [docs/configuration.md](docs/configuration.md).

## License

Apache License 2.0 — see LICENSE. Copyright 2026 Janni Turunen.
