# AGENTS.md

## Operator choices

- **Review-blocking severity:** CRITICAL and ISSUES block merge
- **Merge authority:** The /work driver may auto-merge once the adversarial review and lens review both pass; once CI exists, CI must also be green
- **Project intent & stack:** Claude Code skill package: bash + jq + BATS, delegating work to the pi CLI


## Architecture Notes

- skills/delegate/run.sh is the core engine and critical path; SKILL.md is a thin wrapper kept tiny on purpose (its text is paid for in Claude tokens on every delegation). Changes require BATS coverage (stub pi, no network)
- One pi call per task: `pi -p --no-session --no-extensions --no-skills --no-prompt-templates`, full default toolset, task on stdin; no pinned model, `--model` passthrough only
- `--verify CMD` is the quality gate: deterministic command after pi, one fix retry with the failure output, no model reviewer (same-model reviewers approve most changes)
- run.sh runs detached (`set -m`, pid file, run dir outside the repo) and is waited on in bounded calls; `--abort` kills the recorded group plus its children's groups (GNU timeout re-groups pi); pi.rc is written last as the completion signal
- Safety preflight (default branch, secret files, git push disabled) is a guardrail against mistakes, not a sandbox
- pi discovery: `command -v pi` + `[ -x ]`, fallback ~/.bun/bin/pi then ~/.local/bin/pi
- Benchmarks: bench/quick.sh is the fast reward function (plain Claude vs Claude + plugin, hidden checks, REWARD = 1 - costB/costA, -1 if quality drops); the click-fork harness (bench/*.sh) is the slower evidence run
- Tests: BATS with a stub pi binary
- Out of scope: MCP server, pi SDK embedding, multi-worktree, session persistence, model reviewers/review loops until a benchmark shows they pay for their tokens

# Minimalist Engineering

Every line of code is a liability. Before creating anything:

- **Is this explicitly required** by the GitHub issue?
- **Can existing code/tools** solve this instead?
- **What's the SIMPLEST** way to meet the requirement?
- **Am I building for hypothetical** future needs?

If you cannot justify necessity, DO NOT CREATE IT.

# Git Workflow

## Conventional commits

```
<type>(<scope>): <description>
```

Types: `feat` | `fix` | `refactor` | `docs` | `test` | `chore`

## Branch naming

```
feature/issue-{N}-brief-description
```

## Branch protection

- ❌ NO direct commits to `main`
- ✅ All work on feature branches → PR
- ✅ PRs squash-merged

# Documentation Policy

## The 200-PR test

Before adding documentation: *"Will this be true in 200 PRs?"*

- **YES** (enduring principle) → Document the principle (WHY)
- **NO** (implementation detail) → Skip, or use code comments (WHAT/HOW)

## Forbidden documentation

- ❌ Issue drafts, implementation summaries, fix notes, scratch files
- ❌ `TODO` comments — create GitHub issues instead

# Issue-Driven Development

## Before starting

1. GitHub issue exists for the work
2. Issue clearly describes the requirement
3. Your approach matches issue scope exactly
4. No scope expansion without updating the issue

## Linking

Link PRs to issues via `Closes #N` in the PR body. Use the issue number
in the branch name, never in the commit scope.

# Code Review Doctrine

## Quality gates (blocking)

All checks must pass locally before push:

- [ ] Tests passing (0 failures)
- [ ] Coverage meets threshold
- [ ] Linting passing (0 errors)
- [ ] Type checking passing (0 errors)

## Zero technical debt

- ❌ No `# noqa`, `@ts-ignore`, `# type: ignore`
- ❌ No `// biome-ignore` without explicit justification
- ❌ No suppressions in the diff

# Context7 Protocol

Before writing ANY code, check Context7 for current documentation:
- Library APIs and syntax
- Framework patterns and best practices
- Configuration options

Training data is often months out of date. Context7 provides
authoritative, up-to-date docs. Skip it for the project's own code
standard-library features, or meta-questions about the project.

# Testing Standards

- TDD preferred: write the failing test first, then the minimal
  implementation that passes it; refactor with the tests green.
- Coverage threshold: **≥80%** for new code.
- Coverage for lower-risk areas (documentation, config, formatting)
  may be lower; the threshold is the floor for logic, not a target for
  boilerplate.
- A bug fix ships with its regression test — a fix without a test that
  failed first is an incomplete fix.
