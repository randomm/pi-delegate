#!/usr/bin/env bats
# Doc-drift tests for skills/pi-oneshot/SKILL.md and README.md (issue #39).
#
# These are grep-style assertions that keep the documented invocation in
# sync with the timeout-wrapper contract decided in issue #39: the pi call
# is wrapped in `timeout --kill-after=${PI_KILL_AFTER:-30} ${PI_TIMEOUT:-1800}`
# (with a gtimeout fallback and an unbounded-with-warning path), exit 124/137
# mean "timed out", and Claude Code long-run safety goes through
# run_in_background polling, not a larger foreground timeout.
#
# The README-side assertions are this workstream's own (task-c) and pass
# now. The SKILL.md-side assertions pin the contract that workstream
# task-a implements (the inline wrapper in skills/pi-oneshot/SKILL.md);
# they are expected to be RED until task-a lands in the merged tree —
# run the README tests in isolation with:
#   bats -f "README" skills/pi-oneshot/test/pi-oneshot.bats
# (bats -f matches test names as a regex).
#
# No pi binary is needed: the tests only assert on the doc text.

setup() {
  # Resolve files relative to the repo root (this file lives at
  # skills/pi-oneshot/test/) so the suite works from any cwd.
  local test_dir root
  test_dir=$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)
  root=$(cd "$test_dir/../../.." && pwd)
  SKILL_FILE="$root/skills/pi-oneshot/SKILL.md"
  README_FILE="$root/README.md"
  if [ ! -f "$SKILL_FILE" ]; then
    echo "missing $SKILL_FILE" >&2
    return 1
  fi
  if [ ! -f "$README_FILE" ]; then
    echo "missing $README_FILE" >&2
    return 1
  fi
}

# --- README: pi-oneshot section (task-c's own contract — must pass now) ---

@test "README names PI_TIMEOUT/PI_KILL_AFTER with the 1800/30 defaults for pi-oneshot" {
  grep -q 'PI_TIMEOUT:-1800' "$README_FILE"
  grep -q 'PI_KILL_AFTER:-30' "$README_FILE"
}

@test "README names the timeout wrapper (--kill-after) for pi-oneshot" {
  grep -q -- '--kill-after' "$README_FILE"
}

@test "README mentions gtimeout for pi-oneshot" {
  grep -q 'gtimeout' "$README_FILE"
}

@test "README documents 124/137 = timed out for pi-oneshot" {
  grep -q '124' "$README_FILE"
  grep -q '137' "$README_FILE"
}

@test "README documents the pi-oneshot unbounded-with-warning path" {
  grep -qEi 'unbounded|no time limit|without a time limit' "$README_FILE"
  grep -q 'warn' "$README_FILE"
}

@test "README carries the long-run guidance (run_in_background) for both skills" {
  grep -q 'run_in_background' "$README_FILE"
}

@test "README states the correct worst-case loop wall clock (183 min, not 33)" {
  grep -q '183 min' "$README_FILE"
}

# --- pi-oneshot SKILL.md: Invocation block has the timeout wrapper ---
# (contract implemented by task-a; green once its edits are in the tree)

@test "pi-oneshot SKILL.md names the PI_TIMEOUT and PI_KILL_AFTER env vars" {
  grep -q 'PI_TIMEOUT' "$SKILL_FILE"
  grep -q 'PI_KILL_AFTER' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md documents the 1800/30 default values" {
  grep -q 'PI_TIMEOUT:-1800' "$SKILL_FILE"
  grep -q 'PI_KILL_AFTER:-30' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md wraps the pi call in timeout with --kill-after" {
  grep -q -- '--kill-after' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md covers the gtimeout fallback (macOS)" {
  grep -q 'gtimeout' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md explains exit 124 (SIGTERM at PI_TIMEOUT) as timed out" {
  grep -q '124' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md explains exit 137 (SIGKILL escalation) as timed out" {
  grep -q '137' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md documents the unbounded-with-warning path" {
  # The degraded-mode wording must be present: neither binary -> no time
  # limit, with a warning, bounded only by the Bash tool's own limit.
  grep -qEi 'unbounded|no time limit|without a time limit' "$SKILL_FILE"
  grep -q 'warn' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md Model variant keeps the timeout wrapper" {
  # The "Model" subsection must not show a bare unwrapped pi call: the
  # wrapper must apply to every variant, including --model <model>. Assert
  # the Model section (text between "### Model" and the next "## ") either
  # shows the wrapped command or explicitly states the wrapper applies.
  local model_section
  model_section=$(awk '/^### Model$/{flag=1; next} flag && /^## /{flag=0} flag' "$SKILL_FILE")
  [[ -n "$model_section" ]]
  {
    printf '%s' "$model_section" | grep -q -- 'timeout'
  } || {
    # Fallback: the section explicitly states the wrapper applies to all
    # variants.
    grep -qEi 'wrapper applies|wrapped command|same wrapper' "$SKILL_FILE"
  }
}

@test "pi-oneshot SKILL.md instructs run_in_background polling for long runs" {
  grep -q 'run_in_background' "$SKILL_FILE"
}

# --- Cross-file consistency: README and SKILL.md agree (SKILL.md side
#     is task-a's; green once its edits are in the tree) ---

@test "README and SKILL.md agree on the 1800 default" {
  grep -q '1800' "$SKILL_FILE"
  grep -q '1800' "$README_FILE"
}

@test "README and SKILL.md agree on the 30 default" {
  grep -q '30' "$SKILL_FILE"
  grep -q '30' "$README_FILE"
}

@test "README and SKILL.md agree on 124/137 = timed out" {
  grep -q '124' "$SKILL_FILE"
  grep -q '137' "$SKILL_FILE"
  grep -q '124' "$README_FILE"
  grep -q '137' "$README_FILE"
}
