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
  # Shared doc-block extraction helper (must not mask a missing file —
  # an empty section_block result would make the doc-drift tests pass
  # silently on a drifted doc).
  local _lib
  _lib="$root/test/lib/blocks.bash"
  [ -f "$_lib" ] || { echo "setup: missing test lib: $_lib" >&2; return 1; }
  source "$_lib"
}

# Extract the SKILL.md section named $1 (heading to the next ##/### boundary).
skill_section() {
  section_text "$SKILL_FILE" "$1"
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
  block=$(section_block "$SKILL_FILE" "## Invocation" 1)
  # The request is read from a task file (a quoted-heredoc write in its own
  # call): the block carries the task-file read (anchored to the literal
  # TASK_FILE after extraction) piped into the wrapped pi invocation with
  # the full flag set, and fails fast if the task file is missing or empty.
  printf '%s' "$block" | grep -qF -- 'TASK_FILE="<the task file from the call above>"'
  printf '%s' "$block" | grep -qF 'ERROR: task file missing or empty: $TASK_FILE'
  printf '%s' "$block" | grep -qF '| ${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates'
  # The raw (unextracted) block must carry the literal task-file read.
  printf '%s' "$(section_text "$SKILL_FILE" "## Invocation")" | grep -qF -- '$(cat "$TASK_FILE")'
  # The old positional variant must not remain as live code.
  ! printf '%s' "$block" | grep -qE '^\$\{wrap\[@\]\+.*"\$ARGUMENTS"$'
}

@test "pi-oneshot SKILL.md Model variant block carries the task-file guard" {
  local block
  block=$(section_block "$SKILL_FILE" "### Model" 1)
  # The --model passthrough variant must carry the same task-file lines as
  # the foreground Invocation block: the caller-substituted TASK_FILE line,
  # the -s guard, and the $(cat "$TASK_FILE") read (after extraction).
  printf '%s' "$block" | grep -qF -- 'TASK_FILE="<the task file from the call above>"'
  printf '%s' "$block" | grep -qF 'ERROR: task file missing or empty: $TASK_FILE'
  printf '%s' "$block" | grep -qF '$(cat "$TASK_FILE")'
}

@test "pi-oneshot detached launch block carries the task-file guard and literal read" {
  local block
  block="$(long_runs_block 1)"
  printf '%s' "$block" | grep -qF 'TASK_FILE="<the task file from the call above>"'
  printf '%s' "$block" | grep -qF 'ERROR: task file missing or empty: $TASK_FILE'
  printf '%s' "$block" | grep -qF '$(cat "$TASK_FILE")'
}

@test "pi-oneshot SKILL.md abort exits 3 when pi cannot be resolved" {
  local block
  block="$(long_runs_block 3)"
  # The "cannot resolve pi" leg must exit 3 (NOT performed), not 0.
  printf '%s' "$block" | grep -qF 'kill NOT performed'
  printf '%s' "$block" | grep -qF 'kill -0 <pid>'
  # The guard must not silently succeed when the kill was skipped.
  printf '%s' "$block" | grep -qF 'exit 3'
}

@test "pi-oneshot SKILL.md prints the missing-timeout warning as live code" {
  local block
  block=$(section_block "$SKILL_FILE" "## Invocation" 1)
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

@test "pi-oneshot SKILL.md blocks validate PI_TIMEOUT/PI_KILL_AFTER before launch" {
  # The launch blocks (foreground invocation + detached) must run the same
  # positive-integer validation orchestrate.sh runs, with the driver's
  # message, BEFORE any pi resolution, preflight or launch — the block must
  # refuse on a bad knob regardless of whether a pi binary is present.
  local fg detached
  fg=$(section_block "$SKILL_FILE" "## Invocation" 1)
  detached=$(long_runs_block 1)
  printf '%s' "$fg" | grep -qF 'PI_TIMEOUT must be a positive integer'
  printf '%s' "$fg" | grep -qF 'PI_KILL_AFTER must be a positive integer'
  printf '%s' "$detached" | grep -qF 'PI_TIMEOUT must be a positive integer'
  printf '%s' "$detached" | grep -qF 'PI_KILL_AFTER must be a positive integer'
  # Validation precedes every later step (pi resolution, preflight, the
  # wrap-array construction, the pi call) — refuse before launch. Anchor the
  # preflight check on the LIVE if-line (not the comment): a commented-out
  # line would make the comparison a false pass, and the PI_DELEGATE_UNSAFE
  # opt-out line is the first live occurrence in both blocks.
  for anchor in 'command -v pi' 'if [ "${PI_DELEGATE_UNSAFE:-}"' 'wrap=' 'PI_BIN'; do
    [ "$(printf '%s\n' "$fg" | grep -n 'must be a positive integer' | head -n 1 | cut -d: -f1)" -lt "$(printf '%s\n' "$fg" | grep -nF "$anchor" | head -n 1 | cut -d: -f1)" ]
    [ "$(printf '%s\n' "$detached" | grep -n 'must be a positive integer' | head -n 1 | cut -d: -f1)" -lt "$(printf '%s\n' "$detached" | grep -nF "$anchor" | head -n 1 | cut -d: -f1)" ]
  done
}

# A PATH directory with the bare minimum the blocks need — no pi, no GNU
# timeout/gtimeout — so the functional tests below behave identically on
# hosts that have a real pi (macOS dev boxes) and hosts that do not (CI).
nopy_path() {
  local p b
  p="$(mktemp -d)"
  for b in bash sh cat sed grep printf head tail sort mktemp mkdir rm echo tr sleep; do
    local src
    src=$(command -v "$b")
    [ -n "$src" ] && ln -sf "$src" "$p/$b"
  done
  printf '%s' "$p"
}

# A PATH directory with nopy_path's set PLUS the bare minimum a full valid
# foreground block needs to run end-to-end: a stub pi (records argv + stdin,
# exits 0), a stub GNU timeout (passes through, honours a negative deadline
# as immediate success), and the git/ps/find binaries the safety preflight
# calls. Used to prove the allowlist is sufficient — a missing allowlist
# binary would surface as "command not found" in the block's output.
stub_pi_path() {
  local p pi stub_timeout
  p="$(nopy_path)"
  for b in git ps find; do
    local src
    src=$(command -v "$b")
    [ -n "$src" ] && ln -sf "$src" "$p/$b"
  done
  pi="$p/pi"
  printf '%s\n' 'echo "STUB PI $*"' >> "$pi"
  printf '%s\n' 'cat > /dev/null' >> "$pi"
  printf '%s\n' 'exit 0' >> "$pi"
  chmod +x "$pi"
  stub_timeout="$p/timeout"
  # -N means "deadline already passed" — the probe (--kill-after=1 1 true)
  # and any bounded call return success immediately without running the
  # command or sleeping.
  printf '%s\n' 'case "${1}" in -N) exit 0 ;; esac' >> "$stub_timeout"
  printf '%s\n' 'shift' >> "$stub_timeout"
  printf '%s\n' 'while [ -n "${1:-}" ]; do case "${1:-}" in --*) shift ;; *) break ;; esac; done' >> "$stub_timeout"
  printf '%s\n' 'exec "$@"' >> "$stub_timeout"
  chmod +x "$stub_timeout"
  printf '%s' "$p"
}

@test "pi-oneshot foreground invocation: valid launch under stub PATH runs clean (allowlist sufficient)" {
  local dir block script out rc=0 nopy stub gitdir taskf
  dir="$(mktemp -d)"
  block="$(section_block "$SKILL_FILE" "## Invocation" 1)"
  # A minimal git repo on a feature branch (not the default branch) so the
  # preflight passes, with a task file to read.
  gitdir="$dir/repo"
  mkdir "$gitdir"
  git init -q -b feature/issue-69-hermetic "$gitdir" 2>/dev/null || git init -q "$gitdir"
  git -C "$gitdir" config user.email t@t
  git -C "$gitdir" config user.name t
  git -C "$gitdir" commit -q --allow-empty -m init
  git -C "$gitdir" checkout -q -b feature/issue-69-hermetic 2>/dev/null || true
  taskf="$dir/task.txt"
  printf 'do it' > "$taskf"
  nopy="$(nopy_path)"
  stub="$(stub_pi_path)"
  script="$dir/inv.sh"
  printf '%s\n' "$block" | sed "s|^TASK_FILE=.*|TASK_FILE=\"$taskf\"|" > "$script"
  out="$(cd "$gitdir" && HOME="$dir" PATH="$stub" bash "$script" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ]
  grep -qF 'STUB PI -p --no-session --no-extensions --no-skills --no-prompt-templates' <<<"$out"
  ! grep -qiF 'command not found' <<<"$out"
  rm -rf "$dir" "$nopy" "$stub"
}

@test "pi-oneshot detached launch block validates PI_TIMEOUT=0 -> ERROR, exit 2, no RUN_DIR" {
  local dir block script out rc=0 taskf nopy
  dir="$(mktemp -d)"
  block="$(long_runs_block 1)"
  # Point the task-file placeholder at a file with content so the -s guard
  # passes and the block reaches the PI_TIMEOUT validation.
  taskf="$(mktemp)"
  printf 'do it' > "$taskf"
  script="$dir/launch.sh"
  printf '%s\n' "$block" | sed "s|^TASK_FILE=.*|TASK_FILE=\"$taskf\"|" > "$script"
  nopy="$(nopy_path)"
  out="$(HOME="$dir" PATH="$nopy" PI_TIMEOUT=0 bash "$script" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  grep -qF 'PI_TIMEOUT must be a positive integer' <<<"$out"
  ! grep -qF 'RUN_DIR=' <<<"$out"
  ! grep -qF 'pi not found' <<<"$out"
  rm -f "$taskf"; rm -rf "$dir"; rm -rf "$nopy"
}

@test "pi-oneshot foreground invocation block validates PI_TIMEOUT=abc -> ERROR, exit 2, no pi call" {
  local dir block script out rc=0 nopy
  dir="$(mktemp -d)"
  block="$(section_block "$SKILL_FILE" "## Invocation" 1)"
  # Point the task-file placeholder at a file with content (the -s guard
  # passes); the block must refuse on PI_TIMEOUT before any pi launch.
  local taskf; taskf="$(mktemp)"
  printf 'do it' > "$taskf"
  script="$dir/inv.sh"
  printf '%s\n' "$block" | sed "s|^TASK_FILE=.*|TASK_FILE=\"$taskf\"|" > "$script"
  nopy="$(nopy_path)"
  out="$(HOME="$dir" PATH="$nopy" PI_TIMEOUT=abc bash "$script" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  grep -qF 'PI_TIMEOUT must be a positive integer' <<<"$out"
  ! grep -qF 'pi not found' <<<"$out"
  rm -f "$taskf"; rm -rf "$dir"; rm -rf "$nopy"
}

@test "pi-oneshot foreground invocation: missing task file -> exit 2, no pi call" {
  local dir block script out rc=0 nopy
  dir="$(mktemp -d)"
  block="$(section_block "$SKILL_FILE" "## Invocation" 1)"
  # Point the task-file placeholder at a nonexistent path so the -s guard
  # fires before any pi launch; PATH is restricted to the nopy_path set so
  # "no pi" is real, not just unlikely.
  nopy="$(nopy_path)"
  script="$dir/inv.sh"
  printf '%s\n' "$block" | sed "s|^TASK_FILE=.*|TASK_FILE=\"$dir/does-not-exist.txt\"|" > "$script"
  out="$(HOME="$dir" PATH="$nopy" bash "$script" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  grep -qF 'ERROR: task file missing or empty: /' <<<"$out"
  ! grep -qF 'pi not found' <<<"$out"
  rm -rf "$dir" "$nopy"
}

@test "pi-oneshot detached launch: missing task file -> exit 2, no RUN_DIR, no pi stub" {
  local dir block script out rc=0 nopy tmpd
  dir="$(mktemp -d)"
  block="$(long_runs_block 1)"
  # A restricted PATH (nopy_path: no pi, no timeout) makes "no pi" real, and
  # a fresh TMPDIR proves a refused launch allocates NO temp dir: every
  # mktemp in the block (task guard, run dir) would land in $tmpd.
  nopy="$(nopy_path)"
  tmpd="$(mktemp -d)"
  script="$dir/launch.sh"
  printf '%s\n' "$block" | sed "s|^TASK_FILE=.*|TASK_FILE=\"$dir/nope.txt\"|" > "$script"
  out="$(HOME="$dir" PATH="$nopy" TMPDIR="$tmpd" bash "$script" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  grep -qF 'ERROR: task file missing or empty: /' <<<"$out"
  ! grep -qF 'RUN_DIR=' <<<"$out"
  [ -z "$(ls -A "$tmpd")" ]
  rm -rf "$dir" "$nopy" "$tmpd"
}

@test "pi-oneshot detached launch: empty task file -> exit 2, no RUN_DIR" {
  local dir block script out rc=0 nopy tmpd
  dir="$(mktemp -d)"
  block="$(long_runs_block 1)"
  nopy="$(nopy_path)"
  tmpd="$(mktemp -d)"
  : > "$dir/empty.txt"
  script="$dir/launch.sh"
  printf '%s\n' "$block" | sed "s|^TASK_FILE=.*|TASK_FILE=\"$dir/empty.txt\"|" > "$script"
  out="$(HOME="$dir" PATH="$nopy" TMPDIR="$tmpd" bash "$script" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  grep -qF 'ERROR: task file missing or empty: /' <<<"$out"
  ! grep -qF 'RUN_DIR=' <<<"$out"
  [ -z "$(ls -A "$tmpd")" ]
  rm -rf "$dir" "$nopy" "$tmpd"
}

@test "pi-oneshot detached launch: bad PI_KILL_AFTER -> exit 2, no RUN_DIR, no temp dir" {
  local dir block script out rc=0 nopy tmpd taskf
  dir="$(mktemp -d)"
  block="$(long_runs_block 1)"
  nopy="$(nopy_path)"
  tmpd="$(mktemp -d)"
  taskf="$(mktemp)"
  printf 'do it' > "$taskf"
  script="$dir/launch.sh"
  printf '%s\n' "$block" | sed "s|^TASK_FILE=.*|TASK_FILE=\"$taskf\"|" > "$script"
  out="$(HOME="$dir" PATH="$nopy" TMPDIR="$tmpd" PI_KILL_AFTER=0 bash "$script" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  grep -qF 'PI_KILL_AFTER must be a positive integer' <<<"$out"
  ! grep -qF 'RUN_DIR=' <<<"$out"
  [ -z "$(ls -A "$tmpd")" ]
  rm -f "$taskf"; rm -rf "$dir" "$nopy" "$tmpd"
}

@test "pi-oneshot detached launch: bad PI_TIMEOUT -> exit 2, no RUN_DIR, no temp dir" {
  local dir block script out rc=0 nopy tmpd taskf
  dir="$(mktemp -d)"
  block="$(long_runs_block 1)"
  nopy="$(nopy_path)"
  tmpd="$(mktemp -d)"
  taskf="$(mktemp)"
  printf 'do it' > "$taskf"
  script="$dir/launch.sh"
  printf '%s\n' "$block" | sed "s|^TASK_FILE=.*|TASK_FILE=\"$taskf\"|" > "$script"
  out="$(HOME="$dir" PATH="$nopy" TMPDIR="$tmpd" PI_TIMEOUT=0 bash "$script" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  grep -qF 'PI_TIMEOUT must be a positive integer' <<<"$out"
  ! grep -qF 'RUN_DIR=' <<<"$out"
  [ -z "$(ls -A "$tmpd")" ]
  rm -f "$taskf"; rm -rf "$dir" "$nopy" "$tmpd"
}

@test "pi-oneshot SKILL.md abort skips the kill when pi cannot be resolved (exit 3)" {
  local block
  block="$(long_runs_block 3)"
  grep -qF 'cannot verify command line' <<<"$block"
  # A non-zero exit signals the kill was NOT performed; the prose tells the
  # reader to verify liveness with kill -0.
  grep -qF 'kill NOT performed' <<<"$block"
  grep -qF 'kill -0 <pid>' <<<"$block"
  # The bare-"pi" match is gone: the guard greps the resolved path only.
  ! printf '%s' "$block" | grep -qF 'pi_cmd='
}

@test "oneshot abort: pi unresolvable -> message + exit 3 (kill NOT performed)" {
  local dir block script out rc=0
  dir="$(mktemp -d)"
  block="$(long_runs_block 3)"
  # Point the RUN_DIR placeholder at a scratch dir with a dead pid so the
  # abort block reads a (missing) pid file and reaches the pi-resolution
  # leg; HOME is emptied of any pi so PI_BIN stays empty.
  : > "$dir/pi-oneshot.pid"
  printf '99999\n' > "$dir/pi-oneshot.pid"
  script="$dir/abort.sh"
  printf '%s\n' "$block" | sed "s|^D=.*|D=\"$dir\"|" > "$script"
  # Force PI_BIN to be empty by shadowing `command` so the pi-resolution
  # loop finds no executable pi binary.
  out="$(HOME="$dir" bash -c 'unset -f command 2>/dev/null; command() { return 1; }; export -f command; source "$1"' _ "$script" 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  grep -qF 'cannot verify command line' <<<"$out"
  grep -qF 'kill NOT performed' <<<"$out"
  rm -rf "$dir"
}

@test "pi-oneshot SKILL.md Model variant keeps the timeout wrapper" {
  # The Model section (text between "### Model" and the next "## ") must
  # show the wrapped command (or state the wrapper applies) — never a bare
  # unwrapped pi call.
  local model_section
  model_section=$(skill_section "### Model")
  [[ -n "$model_section" ]]
  printf '%s' "$model_section" | grep -qF '${wrap[@]+"${wrap[@]}"}'
  # Same single stdin transport (task file) in the Model variant.
  printf '%s' "$model_section" | grep -qF -- '${wrap[@]+"${wrap[@]}"} "$PI_BIN" -p --no-session --no-extensions --no-skills --no-prompt-templates --model'
}

# Extract the FIRST ```bash block of the SKILL.md section named $1 (the
# invocation block in the Invocation section, not a later section's block —
# a single-awk form without the section stop kept collecting past the next
# ##/### heading and concatenated blocks from Model, Long runs, etc. into
# one file).
first_skill_block() {
  section_block "$SKILL_FILE" "$1" 1
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
  section_block "$SKILL_FILE" "## Safety preflight (issue #30)" 1
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
    launch=$(first_skill_block "## Invocation")
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
  section_block "$SKILL_FILE" "### Long runs under Claude Code's Bash tool" "$1"
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
  # The group-leader guard checks pgid == pid before killing.
  grep -qF 'ps -o pgid= -p' <<<"$block"
  grep -qF 'kill -TERM -- "-$PID"' <<<"$block"
  grep -qF 'kill -KILL -- "-$PID"' <<<"$block"
}

@test "oneshot wait block: RC_FILE holds 7 -> prints EXIT CODE: 7" {
  local dir block script out rc=0
  dir="$(mktemp -d)"
  block="$(long_runs_block 2)"
  script="$dir/wait.sh"
  printf '%s\n' "$block" > "$script"
  printf '7\n' > "$dir/pi-oneshot.rc"
  printf 'log line\n' > "$dir/pi-oneshot.log"
  printf '1\n' > "$dir/pi-oneshot.pid"
  sed "s|^D=.*|D=\"$dir\"|" "$script" > "$script.run"
  out="$(bash "$script.run" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ]
  grep -qF 'EXIT CODE: 7' <<<"$out"
  rm -rf "$dir"
}

@test "oneshot wait block: dead pid and empty RC_FILE -> RUN DIED and exit 1" {
  local dir block script out rc=0 dead_pid
  dir="$(mktemp -d)"
  block="$(long_runs_block 2)"
  script="$dir/wait.sh"
  printf '%s\n' "$block" > "$script"
  : > "$dir/pi-oneshot.rc"
  printf 'log line\n' > "$dir/pi-oneshot.log"
  # A dead pid: spawn a child that exits immediately, reap it, record its pid.
  ( true ) &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null
  printf '%s\n' "$dead_pid" > "$dir/pi-oneshot.pid"
  sed "s|^D=.*|D=\"$dir\"|" "$script" > "$script.run"
  out="$(bash "$script.run" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ]
  grep -qF 'RUN DIED' <<<"$out"
  rm -rf "$dir"
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
