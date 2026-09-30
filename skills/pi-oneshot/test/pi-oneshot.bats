#!/usr/bin/env bats
# Doc-drift tests for skills/pi-oneshot/SKILL.md and README.md (issue #39).
#
# Grep-style assertions that keep the documented invocation in sync with the
# timeout-wrapper contract: the pi call is wrapped in
# `timeout --kill-after=${PI_KILL_AFTER:-30} ${PI_TIMEOUT:-1800}` (gtimeout
# fallback with a --kill-after probe; unbounded + warning when absent),
# exit 124/137 mean "timed out", and Claude Code long-run safety goes
# through a detached launch with a pid file plus bounded foreground waits
# (not run_in_background — issue #69).
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

@test "docs/configuration.md owns the long-run guidance (detached + foreground wait)" {
  grep -q 'detached' "$CONFIG_FILE"
  grep -q 'pid' "$CONFIG_FILE"
  run grep -q 'run_in_background' "$CONFIG_FILE"
  [ "$status" -ne 0 ]
}

@test "docs/configuration.md owns the worst-case loop wall clock (183 min, not 33)" {
  grep -q '183 min' "$CONFIG_FILE"
}

@test "README carries no timeout-contract literals (single source: docs/configuration.md)" {
  # The README points at configuration.md instead of re-stating the
  # contract, so the literals must NOT appear there. (the long-run
  # pointer may still appear; the contract literals may not.)
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

@test "pi-oneshot SKILL.md states the preflight must run in the same call as the launch" {
  grep -q 'SAME Bash tool call that launches pi' "$SKILL_FILE"
}

@test "pi-oneshot foreground invocation block embeds the safety preflight in the launch call" {
  local block
  block="$(preflight_in_launch_block fg)"
  [[ -n "$block" ]]
  # The push-neutralising exports must be inside the launch block itself —
  # in the same shell call as the pi invocation — and the spliced block
  # must remain valid shell.
  grep -qF 'GIT_CONFIG_KEY_' <<<"$block"
  grep -qF 'push.default' <<<"$block"
  grep -qF 'PI_DELEGATE_UNSAFE' <<<"$block"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$block" > "$tmp"
  bash -n "$tmp"
  shellcheck --norc --severity=warning -s bash "$tmp"
  rm -f "$tmp"
}

@test "pi-oneshot detached launch block embeds the safety preflight in the launch call" {
  local block
  block="$(preflight_in_launch_block detached)"
  [[ -n "$block" ]]
  grep -qF 'GIT_CONFIG_KEY_' <<<"$block"
  grep -qF 'push.default' <<<"$block"
  grep -qF 'PI_DELEGATE_UNSAFE' <<<"$block"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$block" > "$tmp"
  bash -n "$tmp"
  shellcheck --norc --severity=warning -s bash "$tmp"
  rm -f "$tmp"
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

# Extract the FIRST ```bash block of the SKILL.md section named $1 (the
# invocation block in the Invocation section, not a later section's block —
# the previous single-awk form kept collecting past the next ##/### heading
# and concatenated blocks from Model, Long runs, etc. into one file).
first_skill_block() {
  local s
  s=$(skill_section "$1")
  printf '%s\n' "$s" | awk 'BEGIN{n=0} /^```bash$/{n++; f=(n==1); next} /^```$/{if (f) exit; f=0} f {print}'
}

@test "pi-oneshot SKILL.md invocation block passes bash -n and shellcheck" {
  local block
  block=$(first_skill_block "## Invocation")
  [[ -n "$block" ]]

  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$block" > "$tmp"
  bash -n "$tmp"
  shellcheck --norc --severity=warning -s bash "$tmp"
  rm -f "$tmp"
}

@test "pi-oneshot SKILL.md instructs detached launch + foreground wait for long runs" {
  grep -q 'detached' "$SKILL_FILE"
  grep -q 'PID_FILE' "$SKILL_FILE"
  # The completion signal for a single pi call is the exit-code file.
  grep -q 'RC_FILE' "$SKILL_FILE"
}

# (Cross-file agreement tests with pi-oneshot SKILL.md live in the
# "Cross-file agreement" block above; SKILL.md-vs-orchestrate.sh checks
# for the wrapper are in the Invocation-block tests.)

# --- Issue #30: safety preflight doc-drift ---

oneshot_preflight_block() {
  awk '/^## Safety preflight/,/^## Invocation$/' "$SKILL_FILE" |
    awk 'BEGIN{n=0} /^```bash$/{n++; f=(n==1); next} /^```$/{if (f) exit; f=0} f {print}'
}

# Reconstruct a launch block with the preflight placeholder replaced by the
# verbatim ## Safety preflight block (the documented contract: the preflight
# runs in the SAME Bash call as the launch — its push-neutralising exports
# must reach the pi process as its environment, and an export in a separate
# earlier Bash call would not survive into the launch).
# Args: fg (foreground ## Invocation block) or detached (launch block).
preflight_in_launch_block() {
  local preflight launch preflight_file launch_file
  preflight="$(oneshot_preflight_block)"
  if [ "$1" = "fg" ]; then
    local s
    s=$(skill_section "## Invocation")
    launch=$(printf '%s\n' "$s" | awk 'BEGIN{n=0} /^```bash$/{n++; f=(n==1); next} /^```$/{if (f) exit; f=0} f {print}')
  else
    launch="$(long_runs_block 1)"
  fi
  # The placeholder line is spliced out and the verbatim preflight block is
  # read in from a file (macOS awk rejects newlines in -v string values).
  preflight_file="$(mktemp)"
  launch_file="$(mktemp)"
  printf '%s\n' "$preflight" > "$preflight_file"
  printf '%s\n' "$launch" > "$launch_file"
  sed -e "r $preflight_file" -e 's/<the verbatim ## Safety preflight block:.*>//' "$launch_file" > "${launch_file}.out"
  cat "${launch_file}.out"
  rm -f "$preflight_file" "$launch_file" "${launch_file}.out"
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

# --- Issue #69: cross-call RUN_DIR state + single abort recipe --------------
# Claude runs the launch and each wait/abort as SEPARATE Bash tool calls, so
# shell variables do not persist: the launch block must print RUN_DIR and
# every later block must re-derive LOG/PID_FILE/RC_FILE from D.

# The three Long-runs blocks (launch, wait, abort) by fence number.
long_runs_block() {
  local s
  s="$(awk '/^### Long runs under/{s=1; next} s && /^##(#[^#]|[^# ])/{s=0} s' "$SKILL_FILE")"
  if [ "$1" = "1" ]; then
    # The launch block reuses `wrap` (built in the ## Invocation block) and
    # `$PI_BIN` (resolved in ## Locating the pi binary); seed both for lint.
    printf '%s\n%s\n%s\n' 'wrap=()' 'PI_BIN=pi' "$(printf '%s\n' "$s" | awk 'BEGIN{c=0} /^```bash$/{c++; f=(c==1); next} f && /^```$/{f=0} f{print}')"
  else
    printf '%s\n' "$s" | awk -v n="$1" 'BEGIN{c=0} /^```bash$/{c++; f=(c==n); next} f && /^```$/{f=0} f{print}'
  fi
}

@test "pi-oneshot launch block prints RUN_DIR= as its last line" {
  local block
  block="$(long_runs_block 1)"
  [[ -n "$block" ]]
  [[ "$(printf '%s\n' "$block" | tail -n 1)" = 'echo "RUN_DIR=$D"' ]]
}

@test "pi-oneshot SKILL.md states RUN_DIR must be copied into every later call" {
  grep -q 'State does not persist between Bash tool calls' "$SKILL_FILE"
  grep -q 'every later call' "$SKILL_FILE"
}

@test "pi-oneshot wait block starts with the D placeholder and re-derives LOG/PID_FILE/RC_FILE" {
  local block
  block="$(long_runs_block 2)"
  [[ -n "$block" ]]
  [[ "$(printf '%s\n' "$block" | head -n 1)" = 'D="<the RUN_DIR printed at launch>"' ]]
  grep -qF 'LOG="$D/pi-oneshot.log"; PID_FILE="$D/pi-oneshot.pid"; RC_FILE="$D/pi-oneshot.rc"' <<<"$block"
  # The pid file is read once, and an unreadable pid file stops the wait
  # with a distinct message (not a dead-pid report, not an infinite loop).
  grep -qF 'PID="$(cat "$PID_FILE" 2>/dev/null)"' <<<"$block"
  grep -qF 'PID FILE UNREADABLE — check RUN_DIR' <<<"$block"
}

@test "pi-oneshot abort block starts with the D placeholder and re-derives PID_FILE" {
  local block
  block="$(long_runs_block 3)"
  [[ -n "$block" ]]
  [[ "$(printf '%s\n' "$block" | head -n 1)" = 'D="<the RUN_DIR printed at launch>"' ]]
  grep -qF 'PID_FILE="$D/pi-oneshot.pid"' <<<"$block"
  # The pid-reuse guard checks the command line before killing.
  grep -q 'ps -o command= -p' <<<"$block"
  grep -q '\$PI_BIN' <<<"$block"
}

@test "lint: pi-oneshot launch, wait and abort blocks pass bash -n and shellcheck" {
  local n
  for n in 1 2 3; do
    local block
    block="$(long_runs_block "$n")"
    [[ -n "$block" ]]
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "$block" > "$tmp"
    bash -n "$tmp"
    shellcheck --norc --severity=warning -s bash "$tmp"
    rm -f "$tmp"
  done
}
