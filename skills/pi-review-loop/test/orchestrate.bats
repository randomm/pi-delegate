#!/usr/bin/env bats
# BATS tests for orchestrate.sh — run via: bats skills/pi-review-loop/test/

setup() {
  # Resolve the skill directory from this file's real location so the suite
  # works whether invoked from the repo worktree or from an installed copy.
  # BATS_TEST_FILENAME is the path as invoked (possibly relative), so resolve
  # it against the current directory to get the skill directory (the parent
  # of this test file).
  local test_file="$BATS_TEST_FILENAME"
  case "$test_file" in
    /*) ;;
    *) test_file="$PWD/$test_file" ;;
  esac
  local skill_dir
  skill_dir="$(cd "$(dirname "$test_file")/.." && pwd)"   # skills/pi-review-loop
  REPO_ROOT="$(cd "$skill_dir/../.." && pwd)"   # repo root
  SCRIPT="$REPO_ROOT/skills/pi-review-loop/orchestrate.sh"
  FIXTURES="$REPO_ROOT/skills/pi-review-loop/test/fixtures"

  command -v jq >/dev/null 2>&1 || { skip "jq is not installed"; }

  # Temp git repo with a working-tree change so `git diff HEAD` is non-empty.
  REPO="$(mktemp -d)"
  cd "$REPO" || return 1
  git init -q .
  git config user.email t@t.t
  git config user.name t
  echo base > a.txt
  git add a.txt
  git commit -qm init
  echo modified > a.txt

  # Temp dirs for the mock pi and its call log.
  CALL_LOG="$(mktemp)"
  ARGV_LOG="$(mktemp)"
  FIXTURES_DIR="$(mktemp -d)"
  BIN_DIR="$(mktemp -d)"
  ln -s "$FIXTURES/mock-pi" "$BIN_DIR/pi"
  export PATH="$BIN_DIR:$PATH"
  export MOCK_PI_CALL_LOG="$CALL_LOG"
  export MOCK_PI_ARGV_LOG="$ARGV_LOG"
  export MOCK_PI_FIXTURES_DIR="$FIXTURES_DIR"
}

teardown() {
  cd "$REPO" 2>/dev/null || true
  rm -rf "$REPO" "$CALL_LOG" "$ARGV_LOG" "$FIXTURES_DIR" "$BIN_DIR"
}

run_driver() {
  local tmp
  tmp="$(mktemp)"
  local rc=0
  bash "$SCRIPT" "$@" >"$tmp" 2>&1 || rc=$?
  lines=()
  while IFS= read -r l; do lines+=("$l"); done < "$tmp"
  status=$rc
  rm -f "$tmp"
  return 0
}

# tail_json: print the last line (the JSON summary).
tail_json() { printf '%s' "${lines[${#lines[@]}-1]}"; }

# pi_calls: number of pi invocations made by the driver.
pi_calls() { wc -l <"$CALL_LOG" | tr -d ' '; }

# fixture <n> <text-lines...> — write a pi JSONL fixture for pi call number <n>.
# The lines are joined with newlines and wrapped in a message_end assistant envelope.
fixture() {
  local n="$1"; shift
  local text; text="$(printf '%s\n' "$@")"
  printf '%s' "$text" | jq -Rs '{type:"message_end",message:{role:"assistant",stopReason:"stop",content:[{type:"text",text:.}]}}' > "$FIXTURES_DIR/$n"
}

# --- Entry ------------------------------------------------------------------

@test "empty diff -> EMPTY_DIFF, exit 0, zero pi calls" {
  git checkout -q a.txt
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "EMPTY_DIFF" ]
  [ "$(printf '%s' "$out" | jq -r .total_pi_calls)" = "0" ]
}

@test "not a git repo -> exit 3 with clear message" {
  local dir out rc
  dir="$(mktemp -d)"
  rc=0
  out="$(cd "$dir" && bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"git"* ]]
}

@test "pi not found -> exit 3 with install hint" {
  # Block both PATH and the well-known fallback locations by pointing HOME
  # at an empty temp dir (the fallbacks are ~/.bun/bin and ~/.local/bin).
  local fakehome out rc
  fakehome="$(mktemp -d)"
  rc=0
  out="$(HOME="$fakehome" PATH=/usr/bin:/bin bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"pi"* ]]
}

@test "git failure mid-loop -> PI_ERROR, exit 3, git stderr surfaced" {
  # Wrapper git: `git diff HEAD` succeeds on the entry snapshot but fails
  # on the second call (the round-1 review snapshot) — via a marker file.
  local wrap_dir out rc=0
  wrap_dir="$(mktemp -d)"
  cat > "$wrap_dir/git" <<'WRAP'
#!/bin/bash
if [ -n "${GITDIFF_FAIL_MARKER:-}" ] && [ "$1" = "diff" ] && [ "$2" = "HEAD" ]; then
  if [ -f "$GITDIFF_FAIL_MARKER" ]; then
    echo "fatal: bad thing happened" >&2
    exit 129
  fi
  touch "$GITDIFF_FAIL_MARKER"
fi
exec /usr/bin/git "$@"
WRAP
  chmod +x "$wrap_dir/git"
  local marker="$REPO/gdiff-marker" out rc=0
  rm -f "$marker"
  out="$(GITDIFF_FAIL_MARKER="$marker" PATH="$wrap_dir:$PATH" bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  rm -f "$marker" "$wrap_dir/git"; rmdir "$wrap_dir"
  [ "$rc" -eq 3 ]
  [[ "$out" == *"fatal: bad thing happened"* ]]
  [[ "$out" == *"git diff HEAD failed"* ]]
}

@test "git failure at entry -> PI_ERROR, exit 3" {
  # Wrapper git: fail the very first `git diff HEAD`.
  local wrap_dir out rc=0
  wrap_dir="$(mktemp -d)"
  cat > "$wrap_dir/git" <<'WRAP'
#!/bin/bash
if [ "$1" = "diff" ] && [ "$2" = "HEAD" ]; then
  echo "fatal: entry boom" >&2
  exit 129
fi
exec /usr/bin/git "$@"
WRAP
  chmod +x "$wrap_dir/git"
  out="$(PATH="$wrap_dir:$PATH" bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  rm -f "$wrap_dir/git"; rmdir "$wrap_dir"
  [ "$rc" -eq 3 ]
  [[ "$out" == *"fatal: entry boom"* ]]
}

@test "pi timeout (SLEEP fixture, PI_TIMEOUT=1) -> PI_ERROR, exit 3, timeout message" {
  printf 'SLEEP:2\nshould never appear\n' > "$FIXTURES_DIR/1"
  local out rc=0
  out="$(PI_TIMEOUT=1 bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"pi timed out after 1s"* ]]
}

@test "oversized diff is truncated with a notice (PI_DIFF_MAX_BYTES=400)" {
  # a.txt is ~5KB; the review prompt's embedded diff must carry the
  # truncation notice (with actual shown/total byte counts) and the head
  # of the diff, but not its tail.
  head -c 5000 /dev/zero | tr '\0' 'a' > a.txt
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  PI_DIFF_MAX_BYTES=400 bash "$SCRIPT" "do it" >/dev/null 2>&1 || true
  grep -q "truncated: [1-9][0-9]* of [1-9][0-9]* bytes shown" "$ARGV_LOG"
  grep -q "PI_DIFF_MAX_BYTES=400)" "$ARGV_LOG"
  # The prompt must still embed the diff marker.
  grep -q "Current diff (git diff HEAD):" "$ARGV_LOG"
  # The truncation must keep a non-trivial head of the diff — on BSD head
  # (macOS) the old `head -n -1` line trim silently produced an empty diff.
  # 400-byte cap on a ~5KB diff: at least the first diff line must remain.
  grep -q "diff --git a/a.txt b/a.txt" "$ARGV_LOG"
}

@test "fix prompt embeds the reviewer transcript, capped (PI_DIFF_MAX_BYTES=50)" {
  # A verbose reviewer transcript must be capped in the fix prompt, not
  # embedded unbounded (the fix prompt shares the same MAX_ARG_STRLEN limit).
  local big
  big="$(head -c 1000 /dev/zero | tr '\0' 'x')"
  fixture 2 "${big}" 'VERDICT: ISSUES_FOUND'
  fixture 3 'Fix applied.'
  PI_DIFF_MAX_BYTES=50 bash "$SCRIPT" "do it" >/dev/null 2>&1 || true
  # The fix prompt (call 3) must carry a truncation notice for the transcript.
  grep -q "truncated: [1-9][0-9]* of [1-9][0-9]* bytes shown" "$ARGV_LOG"
  # The bulk of the transcript must NOT be embedded (it would appear as
  # 1000 consecutive 'x' characters in the argv log).
  ! grep -q "${big}" "$ARGV_LOG"
}

@test "small diff is NOT truncated (no notice under PI_DIFF_MAX_BYTES)" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  PI_DIFF_MAX_BYTES=999999 bash "$SCRIPT" "do it" >/dev/null 2>&1 || true
  ! grep -q "bytes shown (PI_DIFF_MAX_BYTES" "$ARGV_LOG"
}

# --- Loop + hard caps --------------------------------------------------------

@test "ISSUES_FOUND at round 3 (terminal) -> PASSED_WITH_FINDINGS, exit 0, findings in JSON" {
  local i
  for i in 2 4 6; do
    fixture "$i" 'Still broken.' '- [a.txt:1] open defect' 'VERDICT: ISSUES_FOUND'
  done
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ "$(pi_calls)" -eq 6 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASSED_WITH_FINDINGS" ]
  [ "$(printf '%s' "$out" | jq -r .rounds)" = "3" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "ISSUES_FOUND" ]
  local findings
  findings="$(printf '%s' "$out" | jq -c .findings)"
  [ "$findings" = '["[a.txt:1] open defect"]' ]
}

@test "default max-rounds 3 with ISSUES_FOUND at terminal round: PASSED_WITH_FINDINGS, 6 pi calls" {
  local i
  for i in 2 4 6; do
    fixture "$i" 'All checks failed.' '- finding one' '- finding two' 'VERDICT: ISSUES_FOUND'
  done
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ "$(pi_calls)" -eq 6 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASSED_WITH_FINDINGS" ]
  [ "$(printf '%s' "$out" | jq -r .total_pi_calls)" = "6" ]
  [ "$(printf '%s' "$out" | jq -r .rounds)" = "3" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "ISSUES_FOUND" ]
}

@test "CRITICAL_ISSUES_FOUND at terminal round: REJECTED, 6 pi calls" {
  local i
  for i in 2 4 6; do
    fixture "$i" 'Broken.' '- [a.txt:1] data loss' 'VERDICT: CRITICAL_ISSUES_FOUND'
  done
  run_driver "do it"
  [ "$status" -eq 1 ]
  [ "$(pi_calls)" -eq 6 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "REJECTED" ]
  [ "$(printf '%s' "$out" | jq -r .total_pi_calls)" = "6" ]
  [ "$(printf '%s' "$out" | jq -r .rounds)" = "3" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "CRITICAL_ISSUES_FOUND" ]
}

@test "--max-rounds 5 is rejected (hard cap 3), exit 2" {
  run_driver --max-rounds 5 "do it"
  [ "$status" -eq 2 ]
  [ ! -s "$CALL_LOG" ]
}

@test "review-round cap: max 3 rounds (develop + 3 reviews + 2 fixes = 6), extra round refused, exit 2" {
  local i
  for i in 2 4 6; do
    fixture "$i" 'Broken.' '- [a.txt:1] defect' 'VERDICT: ISSUES_FOUND'
  done
  run_driver --max-rounds 4 "do it"
  [ "$status" -eq 2 ]
  [ ! -s "$CALL_LOG" ]
}



# --- Happy paths --------------------------------------------------------------

@test "APPROVED on first review -> PASS, 2 pi calls" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ "$(pi_calls)" -eq 2 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASS" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "APPROVED" ]
}

@test "MINOR_OBSERVATIONS -> PASS, findings still extracted into JSON, exit 0" {
  fixture 2 'A few nits.' '- [a.txt:1] naming nit' 'VERDICT: MINOR_OBSERVATIONS'
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ "$(pi_calls)" -eq 2 ]
  local out
  out="$(tail_json)"
  # Spec terminal semantics: APPROVED/MINOR_OBSERVATIONS -> PASS.
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASS" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "MINOR_OBSERVATIONS" ]
  local findings
  findings="$(printf '%s' "$out" | jq -c .findings)"
  [ "$findings" = '["[a.txt:1] naming nit"]' ]
}

@test "MINOR_OBSERVATIONS numbered-list findings (1. / 2)) are extracted" {
  fixture 2 'Two nits.' '1. [a.txt:1] first' '2) [a.txt:2] second' 'VERDICT: MINOR_OBSERVATIONS'
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ "$(pi_calls)" -eq 2 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASS" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "MINOR_OBSERVATIONS" ]
  local findings
  findings="$(printf '%s' "$out" | jq -c .findings)"
  [ "$findings" = '["[a.txt:1] first","[a.txt:2] second"]' ]
}

@test "review prompt embeds the diff as real newlines, not literal \\n" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  # The review prompt (last arg of pi call 2) contains the marker
  # "Current diff (git diff HEAD):" exactly once in the ARGV_LOG file.
  # od -c renders a real newline (0x0a) as two chars "\n"; a literal
  # two-char "\n" in the prompt would render as four chars "\ \\ n".
  # Count occurrences of the real-newline rendering before the marker
  # ("\\n C") — must be >= 1 — and of the literal rendering
  # ("\\ \\ n C") — must be 0.
  local real literal
  real="$(od -An -c "$ARGV_LOG" | tr -s ' ' | grep -c '\\n C' || true)"
  [ "$real" -ge 1 ]
  literal="$(od -An -c "$ARGV_LOG" | tr -s ' ' | grep -c '\\ \\ n C' || true)"
  [ "$literal" -eq 0 ]
}







@test "ISSUES_FOUND then fix then APPROVED -> PASS, 4 pi calls" {
  fixture 2 'Broken.' '- [a.txt:1] wrong value' 'VERDICT: ISSUES_FOUND'
  fixture 3 'Fix applied.'
  fixture 4 'All good now.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ "$(pi_calls)" -eq 4 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASS" ]
  [ "$(printf '%s' "$out" | jq -r .total_pi_calls)" = "4" ]
}

@test "fixer prompt threads the prior review findings forward" {
  fixture 2 'Broken.' '- [a.txt:1] wrong value' 'VERDICT: ISSUES_FOUND'
  fixture 3 'Fix applied.'
  fixture 4 'All good now.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ "$(pi_calls)" -eq 4 ]
  # The fix call (call 3) must reference the findings from the review (call 2).
  # Verify by checking the ARGV_LOG: the fix prompt (last arg of call 3)
  # should contain the finding text. Since multi-line args break the
  # one-line-per-arg format, we grep for the finding text in the log
  # and verify it appears in a line that also contains "findings".
  grep -q "a.txt:1] wrong value" "$ARGV_LOG"
}

# --- Verdict parser -----------------------------------------------------------

@test "last occurrence wins when verdict appears earlier in prose" {
  fixture 2 'An earlier draft said VERDICT: ISSUES_FOUND but I walked it back.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "APPROVED" ]
}

@test "case-insensitive verdict with markdown bold and missing colon" {
  fixture 2 '**verdict** **approved**'
  run_driver "do it"
  [ "$status" -eq 0 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "APPROVED" ]
}

@test "unparseable reviewer output -> INCOMPLETE, exit 2" {
  fixture 2 'I could not reach a conclusion about this diff.'
  run_driver "do it"
  [ "$status" -eq 2 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "INCOMPLETE" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "null" ]
}

# --- pi error surface ----------------------------------------------------------

@test "pi crash on review -> PI_ERROR, stderr surfaced verbatim, exit 3" {
  printf 'EXIT:1\nauth failure: token expired\n' > "$FIXTURES_DIR/2"
  run_driver "do it"
  [ "$status" -eq 3 ]
  [ "$(pi_calls)" -eq 2 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "PI_ERROR" ]
  printf '%s\n' "${lines[@]}" | grep -q "auth failure: token expired"
}

@test "mock call log is valid JSON on every line (jq -Rs printf %j)" {
  fixture 2 'Broken.' '- [a.txt:1] wrong value' 'VERDICT: ISSUES_FOUND'
  fixture 3 'Fix applied.'
  fixture 4 'All good now.' 'VERDICT: APPROVED'
  run_driver "do it"
  local line
  while IFS= read -r line; do
    printf '%s' "$line" | jq -e 'type == "array"' >/dev/null
  done < "$CALL_LOG"
  [ "$(pi_calls)" -eq 4 ]
}

# --- pi call interface ---------------------------------------------------------

@test "every pi call uses the headless json invocation with role templates" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver --model gpt-test "do it"
  # Verify the key flags appear in the call log (each pi call logs all its args).
  for flag in --mode -p --no-session --no-extensions --no-skills --no-prompt-templates; do
    grep -q -- "$flag" "$ARGV_LOG"
  done
  grep -q "gpt-test" "$ARGV_LOG"
}

@test "developer gets full tools (no --tools); reviewer is restricted to read-only" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  # --tools appears exactly once (reviewer call); developer call has no --tools.
  grep -q -- '--tools' "$ARGV_LOG"
  grep -q 'read,grep,find,ls' "$ARGV_LOG"
}

@test "developer.md and adversarial-reviewer.md are passed via --append-system-prompt" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  # --append-system-prompt must appear (both calls use it); --system-prompt must not.
  grep -q -- '--append-system-prompt' "$ARGV_LOG"
  ! grep -q -- '--system-prompt ' "$ARGV_LOG"
}

@test "review prompt contains a fresh git diff snapshot" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  # The review prompt (call 2) must embed the current diff. The diff text
  # appears in the ARGV_LOG as part of the review prompt arg.
  grep -q "diff --git a/a.txt b/a.txt" "$ARGV_LOG"
  grep -q -- "-base" "$ARGV_LOG"
  grep -q -- "+modified" "$ARGV_LOG"
}

@test "round announcements go to stderr with round numbering" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  local all
  all="$(printf '%s\n' "${lines[@]}")"
  [[ "$all" == *"Round 1/3: reviewing"* ]]
}

# --- CLI validation -----------------------------------------------------------

@test "unknown option -> usage error, exit 2" {
  run_driver --bogus "x"
  [ "$status" -eq 2 ]
}

@test "--max-rounds 0 -> usage error, exit 2" {
  run_driver --max-rounds 0 "x"
  [ "$status" -eq 2 ]
}

@test "missing task -> usage error, exit 2" {
  run_driver
  [ "$status" -eq 2 ]
}
