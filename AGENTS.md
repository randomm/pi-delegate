# AGENTS.md

## Operator choices

- **Review-blocking severity:** CRITICAL and ISSUES block merge
- **Merge authority:** The /work driver may auto-merge once the adversarial review and lens review both pass; once CI exists, CI must also be green
- **Project intent & stack:** Claude Code skill package: bash + jq + BATS, delegating work to the pi CLI


## Architecture Notes

- skills/pi-review-loop/orchestrate.sh is the core engine and critical path — deterministic bash loop; SKILL.md files are thin wrappers (changes require BATS coverage)
- skills/pi-review-loop/SKILL.md wraps orchestrate.sh; bundles orchestrate.sh, developer.md, adversarial-reviewer.md referenced via ${CLAUDE_SKILL_DIR}
- skills/pi-oneshot/SKILL.md: single `pi -p --no-session "$ARGUMENTS"` call — no loop, no verdict parsing
- developer.md / adversarial-reviewer.md are passed via --append-system-prompt, never --system-prompt (replacement breaks pi tool-calling)
- Loop hard caps: develop ≤1, review ≤3, fix ≤2, total ≤6 pi invocations; no fix after terminal review
- All loop pi calls use `pi --mode json -p --no-session`; final text extracted only from message_end events
- Reviewer runs read-only: `--tools read,grep,find,ls`; developer/fixer get pi's full default toolset
- Diff source is `git diff HEAD`, re-read fresh before every review round; empty diff at entry → EMPTY_DIFF, exit 0, zero pi calls
- VERDICT parser takes the LAST occurrence, case-insensitive, tolerates optional colon and markdown bold; enum APPROVED|MINOR_OBSERVATIONS|ISSUES_FOUND|CRITICAL_ISSUES_FOUND
- Exit codes: 0=PASS/PASSED_WITH_FINDINGS/EMPTY_DIFF, 1=REJECTED, 2=INCOMPLETE, 3=PI_ERROR; JSON summary is last stdout line, built with jq (never string interpolation)
- pi discovery: `command -v pi` + `[ -x ]`, fallback ~/.bun/bin/pi then ~/.local/bin/pi; no pinned model, --model passthrough only
- Tests: BATS with a mock pi binary (args logged, scripted responses via env/fixtures)
- Out of scope: MCP server, pi SDK embedding, multi-worktree, session persistence

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
