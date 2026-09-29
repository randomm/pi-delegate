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
  CONFIG_FILE="$root/docs/configuration.md"
  [ -f "$SKILL_FILE" ] || { echo "setup: missing $SKILL_FILE" >&2; return 1; }
  [ -f "$README_FILE" ] || { echo "setup: missing $README_FILE" >&2; return 1; }
  [ -f "$CONFIG_FILE" ] || { echo "setup: missing $CONFIG_FILE" >&2; return 1; }
}

# Extract the SKILL.md section named $1 (heading to the next ##/### boundary).
skill_section() {
  awk -v h="$1" 'BEGIN{s=0} $0 == h {s=1; next} s && /^##(#[^#]|[^# ])/ {s=0} s {print}' "$SKILL_FILE"
}

# --- docs/configuration.md is the single source of truth for the timeout
# contract (issue #45). The literals below are asserted in the ONE owning
# file (docs/configuration.md), never with an `A || B` across files. ---

@test "docs/configuration.md owns PI_TIMEOUT/PI_KILL_AFTER with the 1800/30 defaults" {
  grep -qF 'PI_TIMEOUT:-1800' "$CONFIG_FILE"
  grep -qF 'PI_KILL_AFTER:-30' "$CONFIG_FILE"
}

@test "docs/configuration.md owns the timeout wrapper (--kill-after)" {
  grep -q -- '--kill-after' "$CONFIG_FILE"
}

@test "docs/configuration.md owns the gtimeout fallback" {
  grep -q 'gtimeout' "$CONFIG_FILE"
}

@test "docs/configuration.md owns 124/137 = timed out" {
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$CONFIG_FILE"
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$CONFIG_FILE"
}

@test "docs/configuration.md owns the unbounded-with-warning path" {
  grep -qEi 'unbounded|no time limit|without a time limit' "$CONFIG_FILE"
  grep -qi 'warn' "$CONFIG_FILE"
}

@test "docs/configuration.md owns the long-run guidance (run_in_background)" {
  grep -q 'run_in_background' "$CONFIG_FILE"
}

@test "docs/configuration.md owns the worst-case loop wall clock (183 min, not 33)" {
  grep -q '183 min' "$CONFIG_FILE"
}

@test "README carries no timeout-contract literals (single source: docs/configuration.md)" {
  # The README points at configuration.md instead of re-stating the
  # contract, so the literals must NOT appear there. (run_in_background
  # may still appear as a pointer; the contract literals may not.)
  run grep -qF 'PI_TIMEOUT:-1800' "$README_FILE"
  [ "$status" -ne 0 ]
  run grep -qF 'PI_KILL_AFTER:-30' "$README_FILE"
  [ "$status" -ne 0 ]
  run grep -q -- '--kill-after' "$README_FILE"
  [ "$status" -ne 0 ]
  run grep -q 'gtimeout' "$README_FILE"
  [ "$status" -ne 0 ]
  run grep -qE '(^|[^0-9])124([^0-9]|$)' "$README_FILE"
  [ "$status" -ne 0 ]
  run grep -qE '(^|[^0-9])137([^0-9]|$)' "$README_FILE"
  [ "$status" -ne 0 ]
  run grep -qi 'unbounded' "$README_FILE"
  [ "$status" -ne 0 ]
  run grep -q '183 min' "$README_FILE"
  [ "$status" -ne 0 ]
}

# --- Cross-file agreement: docs/configuration.md vs pi-oneshot SKILL.md
# (SKILL.md is the executable wrapper spec; it must agree with the doc.) ---

@test "docs/configuration.md and pi-oneshot SKILL.md agree on the 1800 default" {
  grep -qE '(^|[^0-9])1800([^0-9]|$)' "$SKILL_FILE"
  grep -qE '(^|[^0-9])1800([^0-9]|$)' "$CONFIG_FILE"
}

@test "docs/configuration.md and pi-oneshot SKILL.md agree on the 30 default" {
  grep -qF 'PI_KILL_AFTER:-30' "$SKILL_FILE"
  grep -qF 'PI_KILL_AFTER:-30' "$CONFIG_FILE"
}

@test "docs/configuration.md and pi-oneshot SKILL.md agree on 124/137 = timed out" {
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$SKILL_FILE"
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$SKILL_FILE"
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$CONFIG_FILE"
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$CONFIG_FILE"
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
  grep -qF '${wrap[@]+"${wrap[@]}"}' "$SKILL_FILE"
}

@test "pi-oneshot SKILL.md uses the single stdin transport (no positional variant)" {
  local block
  block=$(skill_section "## Invocation" | awk 'BEGIN{n=0} /^```bash$/{n++; f=(n==1); next} /^```$/{if (f) exit; f=0} f {print}')
  printf '%s' "$block" | grep -qF -- 'printf '"'"'%s'"'"' "$ARGUMENTS" | ${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates'
  # The old positional variant must not remain as live code.
  ! printf '%s' "$block" | grep -qE '^\$\{wrap\[@\]\+.*"\$ARGUMENTS"$'
}

@test "pi-oneshot SKILL.md prints the missing-timeout warning as live code" {
  local block
  block=$(skill_section "## Invocation" | awk 'BEGIN{n=0} /^```bash$/{n++; f=(n==1); next} /^```$/{if (f) exit; f=0} f {print}')
  printf '%s' "$block" | grep -qE '^if \[ -z "\$TIMEOUT_CMD" \]'
  printf '%s' "$block" | grep -q 'WARNING: no GNU timeout/gtimeout found'
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
  printf '%s' "$model_section" | grep -qF '${wrap[@]+"${wrap[@]}"}'
  # Same single stdin transport in the Model variant.
  printf '%s' "$model_section" | grep -qF -- 'printf '"'"'%s'"'"' "$ARGUMENTS" | ${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates --model'
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

# (Cross-file agreement tests with pi-oneshot SKILL.md live in the
# "Cross-file agreement" block above; SKILL.md-vs-orchestrate.sh checks
# for the wrapper are in the Invocation-block tests.)

# --- Issue #30: safety preflight doc-drift ---

oneshot_preflight_block() {
  awk '/^## Safety preflight/,/^## Invocation$/' "$SKILL_FILE" |
    awk 'BEGIN{n=0} /^```bash$/{n++; f=(n==1); next} /^```$/{if (f) exit; f=0} f {print}'
}

@test "pi-oneshot SKILL.md has a safety preflight section (issue #30)" {
  grep -q '^## Safety preflight' "$SKILL_FILE"
}

@test "pi-oneshot safety preflight checks the default branch" {
  oneshot_preflight_block | grep -qF 'default_branch'
  oneshot_preflight_block | grep -qF 'refs/remotes/origin/HEAD'
}

@test "pi-oneshot safety preflight checks secret-looking files" {
  oneshot_preflight_block | grep -qF -- '.env'
  oneshot_preflight_block | grep -qF -- '*.pem'
  oneshot_preflight_block | grep -qF -- '*.key'
}

@test "pi-oneshot safety preflight neutralises git push via GIT_CONFIG" {
  oneshot_preflight_block | grep -qF 'GIT_CONFIG_KEY_'
  oneshot_preflight_block | grep -qF 'push.default'
  oneshot_preflight_block | grep -qF 'pi-delegate-push-disabled'
}

@test "pi-oneshot safety preflight honours the PI_DELEGATE_UNSAFE=1 opt-out" {
  oneshot_preflight_block | grep -qF 'PI_DELEGATE_UNSAFE'
  oneshot_preflight_block | grep -qF 'PI_DELEGATE_UNSAFE=1'
}

@test "pi-oneshot safety preflight block passes bash -n and shellcheck" {
  local block
  block="$(oneshot_preflight_block)"
  [[ -n "$block" ]]
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$block" > "$tmp"
  bash -n "$tmp"
  shellcheck --norc --severity=warning -s bash "$tmp"
  rm -f "$tmp"
}

@test "pi-oneshot SKILL.md documents PI_DELEGATE_UNSAFE opt-out in prose" {
  grep -q 'PI_DELEGATE_UNSAFE=1' "$SKILL_FILE"
}
