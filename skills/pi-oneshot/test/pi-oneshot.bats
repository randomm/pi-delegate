#!/usr/bin/env bats
# Tests for skills/pi-oneshot/run.sh (a stub pi stands in for the real
# one) and for the timeout contract that docs/configuration.md owns.

setup() {
  local test_dir root
  test_dir=$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)
  root=$(cd "$test_dir/../../.." && pwd)
  SKILL_FILE="$root/skills/pi-oneshot/SKILL.md"
  RUN="$root/skills/pi-oneshot/run.sh"
  README_FILE="$root/README.md"
  CONFIG_FILE="$root/docs/configuration.md"

  # Throwaway repo on a feature branch, plus a stub pi that records its
  # argv/stdin/env and optionally edits a file, sleeps, or fails.
  REPO="$(mktemp -d)"
  BIN="$(mktemp -d)"
  cat > "$BIN/pi" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$STUB_DIR/argv"
cat > "$STUB_DIR/stdin"
env | grep '^GIT_CONFIG_COUNT=' > "$STUB_DIR/env" || true
[ -z "$STUB_WRITE" ] || echo changed > "$STUB_WRITE"
[ -z "$STUB_SLEEP" ] || sleep "$STUB_SLEEP"
echo "pi says done"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$BIN/pi"
  export STUB_DIR="$BIN"
  export PATH="$BIN:$PATH"
  cd "$REPO"
  git init -q -b feat .
  git config user.email t@t.t
  git config user.name t
  echo base > a.txt
  git add a.txt
  git commit -qm init
}

teardown() {
  pkill -f "$BIN/pi" 2>/dev/null || true
  rm -rf "$REPO" "$BIN"
}

# --- docs/configuration.md is the single source of truth for the timeout
# contract (issue #45); the SKILL.md must agree with it. ---

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

@test "SKILL.md and docs/configuration.md agree on the 1800 default and 124/137" {
  grep -qF '1800' "$SKILL_FILE"
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$SKILL_FILE"
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$SKILL_FILE"
}

@test "SKILL.md tells Claude to raise the Bash timeout and never use run_in_background" {
  grep -q 'timeout: 590000\|`590000`' "$SKILL_FILE"
  run grep -q 'run_in_background' "$SKILL_FILE"
  [ "$status" -ne 0 ]
}

@test "SKILL.md documents --wait, --abort and PI_DELEGATE_UNSAFE" {
  grep -q -- '--wait' "$SKILL_FILE"
  grep -q -- '--abort' "$SKILL_FILE"
  grep -q 'PI_DELEGATE_UNSAFE=1' "$SKILL_FILE"
}

@test "run.sh passes bash -n and shellcheck" {
  bash -n "$RUN"
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --norc --severity=warning "$RUN"
}

# --- run.sh behaviour -------------------------------------------------------

@test "run.sh: task on stdin reaches pi, result carries exit code, output and diff stat" {
  STUB_WRITE=new.txt run bash "$RUN" <<< "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RUN_DIR="* ]]
  [[ "$output" == *"EXIT CODE: 0"* ]]
  [[ "$output" == *"pi says done"* ]]
  [[ "$output" == *"?? new.txt"* ]]
  [ "$(cat "$STUB_DIR/stdin")" = "do the thing" ]
  grep -qx -- '--no-session' "$STUB_DIR/argv"
  grep -qx -- '-p' "$STUB_DIR/argv"
}

@test "run.sh: --model is passed through" {
  run bash "$RUN" --model foo/bar <<< "t"
  [ "$status" -eq 0 ]
  grep -qx -- 'foo/bar' "$STUB_DIR/argv"
}

@test "run.sh: no --model flag by default" {
  run bash "$RUN" <<< "t"
  run grep -qx -- '--model' "$STUB_DIR/argv"
  [ "$status" -ne 0 ]
}

@test "run.sh: a failing pi is reported with its exit code" {
  STUB_EXIT=7 run bash "$RUN" <<< "t"
  [[ "$output" == *"EXIT CODE: 7"* ]]
}

@test "run.sh: refuses the default branch, pi not called" {
  git checkout -q -b main
  run bash "$RUN" <<< "t"
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"* ]]
  [ ! -e "$STUB_DIR/argv" ]
}

@test "run.sh: refuses secret-looking files, allows .env.example" {
  : > .env.example
  run bash "$RUN" <<< "t"
  [ "$status" -eq 0 ]
  : > .env
  run bash "$RUN" <<< "t"
  [ "$status" -eq 3 ]
  [[ "$output" == *".env"* ]]
}

@test "run.sh: PI_DELEGATE_UNSAFE=1 skips the preflight (default branch allowed)" {
  git checkout -q -b main
  PI_DELEGATE_UNSAFE=1 run bash "$RUN" <<< "t"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_DIR/env" ]
}

@test "run.sh: pi runs with git push neutralised" {
  run bash "$RUN" <<< "t"
  grep -q '^GIT_CONFIG_COUNT=' "$STUB_DIR/env"
  GIT_CONFIG_COUNT=junk run bash "$RUN" <<< "t"
  [ "$status" -eq 3 ]
}

@test "run.sh: bad PI_TIMEOUT / PI_KILL_AFTER / PI_WAIT_BUDGET -> exit 2, pi not called" {
  for v in PI_TIMEOUT PI_KILL_AFTER PI_WAIT_BUDGET; do
    env "$v=abc" bash "$RUN" <<< "t" && return 1
    [ ! -e "$STUB_DIR/argv" ]
  done
  PI_TIMEOUT=0 run bash "$RUN" <<< "t"
  [ "$status" -eq 2 ]
}

@test "run.sh: empty task -> exit 2" {
  run bash "$RUN" <<< ""
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_DIR/argv" ]
}

@test "run.sh: missing pi -> exit 1 with install hint" {
  rm "$BIN/pi"
  HOME=/nonexistent PATH="/usr/bin:/bin" run /bin/bash "$RUN" <<< "t"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pi not found"* ]]
}

@test "run.sh: slow pi -> STILL RUNNING with the --wait command to repeat" {
  STUB_SLEEP=8 PI_WAIT_BUDGET=1 run bash "$RUN" <<< "t"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STILL RUNNING — repeat: bash "*"--wait "* ]]
}

@test "run.sh: --wait collects a finished run" {
  run bash "$RUN" <<< "t"
  dir="$(printf '%s\n' "$output" | sed -n 's/^RUN_DIR=//p')"
  run bash "$RUN" --wait "$dir"
  [[ "$output" == *"EXIT CODE: 0"* ]]
}

@test "run.sh: --abort stops a running pi group" {
  STUB_SLEEP=60 bash "$RUN" <<< "t" > "$REPO/out.txt" 2>&1 &
  waiter=$!
  for _ in $(seq 1 50); do
    [ -s "$REPO/out.txt" ] && break
    sleep 0.1
  done
  dir="$(sed -n 's/^RUN_DIR=//p' "$REPO/out.txt")"
  [ -n "$dir" ]
  pid="$(cat "$dir/pi.pid")"
  run bash "$RUN" --abort "$dir"
  [[ "$output" == *"aborted"* ]]
  wait "$waiter" || true
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  # the pi process itself (in GNU timeout's own group) must be gone too
  run pgrep -f "$STUB_DIR/pi"
  [ "$status" -ne 0 ]
}

@test "run.sh: --abort ignores a pid that is not a run group" {
  mkdir "$REPO/rd"
  echo $$ > "$REPO/rd/pi.pid"
  run bash "$RUN" --abort "$REPO/rd"
  [[ "$output" == *"skipping"* ]]
  kill -0 $$
}

@test "run.sh: a run that dies without an exit code -> RUN DIED, exit 1" {
  mkdir "$REPO/rd"
  echo 999999 > "$REPO/rd/pi.pid"
  : > "$REPO/rd/pi.log"
  run bash "$RUN" --wait "$REPO/rd"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RUN DIED"* ]]
}

@test "run.sh: a pi that exceeds PI_TIMEOUT is reported as 124" {
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || skip "no timeout binary"
  STUB_SLEEP=20 PI_TIMEOUT=1 run bash "$RUN" <<< "t"
  [[ "$output" == *"EXIT CODE: 124"* ]]
}

@test "run.sh: refuses a detached HEAD at the default branch tip" {
  git checkout -q --detach
  git branch -q main
  run bash "$RUN" <<< "t"
  [ "$status" -eq 3 ]
  [ ! -e "$STUB_DIR/argv" ]
}

@test "run.sh: with main and master both present, working on master is refused" {
  git branch -q main
  git checkout -q -b master
  run bash "$RUN" <<< "t"
  [ "$status" -eq 3 ]
}
