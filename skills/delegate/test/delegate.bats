#!/usr/bin/env bats
# Tests for skills/delegate/run.sh (a stub pi stands in for the real
# one).

setup() {
  local test_dir root
  test_dir=$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)
  root=$(cd "$test_dir/../../.." && pwd)
  SKILL_FILE="$root/skills/delegate/SKILL.md"
  RUN="$root/skills/delegate/run.sh"

  # Throwaway repo on a feature branch, plus a stub pi that records its
  # argv/stdin/env and optionally edits a file, sleeps, or fails.
  REPO="$(mktemp -d)"
  BIN="$(mktemp -d)"
  cat > "$BIN/pi" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$STUB_DIR/argv"
cat > "$STUB_DIR/stdin"
env | grep '^GIT_CONFIG_COUNT=' > "$STUB_DIR/env" || true
env | grep '^PI_DELEGATE_RUN=' > "$STUB_DIR/marker" || true
[ -z "$STUB_IGNORE_TERM" ] || trap '' TERM
[ -z "$STUB_DETACH" ] || bash -c 'set -m; sleep 300 >/dev/null 2>&1 & echo $! > "$STUB_DIR/child.pid"'
[ -z "$STUB_WRITE" ] || echo changed > "$STUB_WRITE"
grep -q 'verification command' "$STUB_DIR/stdin" && echo fixed > fixed.txt
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

# --- SKILL.md contract ---

@test "SKILL.md tells Claude to raise the Bash timeout and never use run_in_background" {
  grep -q 'timeout: 590000\|`590000`' "$SKILL_FILE"
  run grep -q 'run_in_background' "$SKILL_FILE"
  [ "$status" -ne 0 ]
}

@test "SKILL.md documents --verify, --wait, --abort, 124/137 and PI_DELEGATE_UNSAFE" {
  grep -q -- '--verify' "$SKILL_FILE"
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$SKILL_FILE"
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$SKILL_FILE"
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
  grep -q '^do the thing$' "$STUB_DIR/stdin"
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

@test "run.sh --verify: passing command -> VERIFY: PASS (retries=0), one pi call" {
  run bash "$RUN" --verify "true" <<< "t"
  [[ "$output" == *"VERIFY: PASS (retries=0)"* ]]
}

@test "run.sh --verify: failing command is retried once with the failure output, then passes" {
  run bash "$RUN" --verify 'echo BOOM-DETAIL; test -f fixed.txt' <<< "t"
  [[ "$output" == *"VERIFY: PASS (retries=1)"* ]]
  grep -q 'BOOM-DETAIL' "$STUB_DIR/stdin"
}

@test "run.sh --verify: still failing after the one retry -> VERIFY: FAIL with the output tail" {
  run bash "$RUN" --verify 'echo STILL-BAD; false' <<< "t"
  [[ "$output" == *"VERIFY: FAIL (retries=1, exit 1)"* ]]
  [[ "$output" == *"STILL-BAD"* ]]
}

@test "run.sh --verify: not run when pi itself failed" {
  STUB_EXIT=5 run bash "$RUN" --verify "true" <<< "t"
  [[ "$output" == *"EXIT CODE: 5"* ]]
  [[ "$output" != *"VERIFY:"* ]]
}

@test "run.sh: no VERIFY line without --verify" {
  run bash "$RUN" <<< "t"
  [[ "$output" != *"VERIFY:"* ]]
}

# --- leftover-child reaping (issue #56): pi's bash-tool children run in
# their own sessions, so the timeout's group kill never reaches them. run.sh
# tags pi's environment with PI_DELEGATE_RUN=<run dir> and kills every process
# carrying the tag after each pi call and on --abort. The environment scan is
# complete on Linux (/proc); the tests skip where /proc is absent.

# Wait up to ~5 s for the detached child recorded by the stub to be gone.
child_dead() {
  for _ in $(seq 1 50); do
    kill -0 "$(cat "$STUB_DIR/child.pid")" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

@test "run.sh: pi's environment carries the PI_DELEGATE_RUN marker (the run dir)" {
  run bash "$RUN" <<< "t"
  dir="$(printf '%s\n' "$output" | sed -n 's/^RUN_DIR=//p')"
  [ "$(cat "$STUB_DIR/marker")" = "PI_DELEGATE_RUN=$dir" ]
}

@test "run.sh: the task handed to pi asks for per-command timeouts" {
  run bash "$RUN" <<< "t"
  grep -q 'timeout parameter' "$STUB_DIR/stdin"
}

@test "run.sh: a detached child left behind by pi is reaped when pi exits" {
  [ -d /proc/self ] || skip "environment scan needs /proc"
  STUB_DETACH=1 run bash "$RUN" <<< "t"
  [[ "$output" == *"EXIT CODE: 0"* ]]
  child_dead
}

@test "run.sh: reaping spares processes without the marker" {
  [ -d /proc/self ] || skip "environment scan needs /proc"
  sleep 300 &
  bystander=$!
  STUB_DETACH=1 run bash "$RUN" <<< "t"
  kill -0 "$bystander"
  kill "$bystander"
}

@test "run.sh: --abort reaps a detached child (also with a trailing slash)" {
  [ -d /proc/self ] || skip "environment scan needs /proc"
  STUB_DETACH=1 STUB_SLEEP=60 bash "$RUN" <<< "t" > "$REPO/out.txt" 2>&1 &
  waiter=$!
  for _ in $(seq 1 50); do
    [ -s "$STUB_DIR/child.pid" ] && break
    sleep 0.1
  done
  dir="$(sed -n 's/^RUN_DIR=//p' "$REPO/out.txt")"
  run bash "$RUN" --abort "$dir/"
  [[ "$output" == *"aborted"* ]]
  wait "$waiter" || true
  child_dead
}

@test "run.sh: a SIGKILLed pi (timeout path) leaves no child behind" {
  [ -d /proc/self ] || skip "environment scan needs /proc"
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || skip "no timeout binary"
  STUB_DETACH=1 STUB_IGNORE_TERM=1 STUB_SLEEP=30 PI_TIMEOUT=1 PI_KILL_AFTER=1 run bash "$RUN" <<< "t"
  [[ "$output" == *"EXIT CODE: 137"* ]]
  child_dead
}

@test "run.sh --verify: children of the retry call are reaped too" {
  [ -d /proc/self ] || skip "environment scan needs /proc"
  STUB_DETACH=1 run bash "$RUN" --verify 'test -f fixed.txt' <<< "t"
  [[ "$output" == *"VERIFY: PASS (retries=1)"* ]]
  child_dead
  grep -q 'timeout parameter' "$STUB_DIR/stdin"
}
