#!/usr/bin/env bats
# Doc-drift tests for skills/pi-oneshot/SKILL.md and README.md (issue #39).
#
# Grep-style assertions that keep the documented invocation in sync with the
# timeout-wrapper contract: the pi call is wrapped in
# `timeout --kill-after=${PI_KILL_AFTER:-30} ${PI_TIMEOUT:-1800}` (gtimeout
# fallback with a --kill-after probe; unbounded + warning when absent),
# exit 124/137 mean "timed out", and Claude Code long-run safety goes through
# run_in_background polling, not a larger foreground timeout.
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
  [ -f "$SKILL_FILE" ] || { echo "setup: missing $SKILL_FILE" >&2; return 1; }
  [ -f "$README_FILE" ] || { echo "setup: missing $README_FILE" >&2; return 1; }
}

# Extract the SKILL.md section named $1 (heading to the next ##/### boundary).
skill_section() {
  awk -v h="$1" 'BEGIN{s=0} $0 == h {s=1; next} s && /^##(#[^#]|[^# ])/ {s=0} s {print}' "$SKILL_FILE"
}

# --- README: pi-oneshot section ---

@test "README names PI_TIMEOUT/PI_KILL_AFTER with the 1800/30 defaults for pi-oneshot" {
  grep -qF 'PI_TIMEOUT:-1800' "$README_FILE"
  grep -qF 'PI_KILL_AFTER:-30' "$README_FILE"
}

@test "README names the timeout wrapper (--kill-after) for pi-oneshot" {
  grep -q -- '--kill-after' "$README_FILE"
}

@test "README mentions gtimeout for pi-oneshot" {
  grep -q 'gtimeout' "$README_FILE"
}

@test "README documents 124/137 = timed out for pi-oneshot" {
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$README_FILE"
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$README_FILE"
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

@test "pi-oneshot SKILL.md names the PI_TIMEOUT and PI_KILL_AFTER env vars" {
  grep -q 'PI_TIMEOUT' "$SKILL_FILE"
  grep -q 'PI_KILL_AFTER' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md documents the 1800/30 default values" {
  grep -qF 'PI_TIMEOUT:-1800' "$SKILL_FILE"
  grep -qF 'PI_KILL_AFTER:-30' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md wraps the pi call in timeout with --kill-after" {
  grep -q -- '--kill-after' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md covers the gtimeout fallback (macOS)" {
  grep -q 'gtimeout' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md probes --kill-after support before trusting the binary" {
  grep -qF -- '--kill-after=1 1 true' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md uses a single wrap array for every invocation variant" {
  grep -qF 'wrap=()' "$SKILL_FILE"
  grep -qF '"${wrap[@]}"' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md documents the stdin transport via the same wrapper" {
  grep -qF -- 'printf '"'"'%s'"'"' "$ARGUMENTS" | "${wrap[@]}" "$PI_BIN" -p' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md explains exit 124 (SIGTERM at PI_TIMEOUT) as timed out" {
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md explains exit 137 (SIGKILL escalation) as timed out" {
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md documents the unbounded-with-warning path" {
  # The degraded-mode wording must be present: no usable binary -> no time
  # limit, with a warning, bounded only by the Bash tool's own limit.
  grep -qEi 'unbounded|no time limit|without a time limit' "$SKILL_FILE"
  grep -q 'warn' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md states PI_TIMEOUT/PI_KILL_AFTER must be positive integers" {
  grep -q 'positive integers' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md Model variant keeps the timeout wrapper" {
  # The Model section (text between "### Model" and the next "## ") must
  # show the wrapped command (or state the wrapper applies) — never a bare
  # unwrapped pi call.
  local model_section
  model_section=$(skill_section "### Model")
  [[ -n "$model_section" ]]
  {
    printf '%s' "$model_section" | grep -qF '"${wrap[@]}"'
  } || {
    # Fallback: the section explicitly states the wrapper applies to all
    # variants.
    grep -qEi 'wrapper applies|wrapped command|same wrapper' "$SKILL_FILE"
  }
}

@test "pi-oneshot SKILL.md invocation block passes bash -n and shellcheck" {
  local block
  block=$(skill_section "## Invocation" | awk 'BEGIN{n=0} /^```bash$/{n++; f=(n==1); next} /^```$/{if (f) exit; f=0} f {print}')
  [[ -n "$block" ]]
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$block" > "$tmp"
  bash -n "$tmp"
  shellcheck --norc --severity=warning -s bash "$tmp"
  rm -f "$tmp"
}

@test "pi-oneshot SKILL.md instructs run_in_background polling for long runs" {
  grep -q 'run_in_background' "$SKILL_FILE"
}

# --- Cross-file consistency: README and SKILL.md agree ---

@test "README and SKILL.md agree on the 1800 default" {
  grep -qE '(^|[^0-9])1800([^0-9]|$)' "$SKILL_FILE"
  grep -qE '(^|[^0-9])1800([^0-9]|$)' "$README_FILE"
}

@test "README and SKILL.md agree on the 30 default" {
  grep -qF 'PI_KILL_AFTER:-30' "$SKILL_FILE"
  grep -qF 'PI_KILL_AFTER:-30' "$README_FILE"
}

@test "README and SKILL.md agree on 124/137 = timed out" {
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$SKILL_FILE"
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$SKILL_FILE"
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$README_FILE"
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$README_FILE"
}
