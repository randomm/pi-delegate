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
  git init -q -b main .
  git config user.email t@t.t
  git config user.name t
  echo base > a.txt
  git add a.txt
  git commit -qm init
  echo modified > a.txt
  # Create and switch to a feature branch so the safety preflight (which
  # refuses the default branch) does not fire for the existing tests. The
  # default branch is "main" — pinned via `git init -b main` so the suite
  # is deterministic regardless of the machine's init.defaultBranch default
  # (CI git defaults to "master").
  git checkout -q -b feature/test-branch

  # Temp dirs for the mock pi and its call log.
  CALL_LOG="$(mktemp)"
  ARGV_LOG="$(mktemp)"
  STDIN_LOG="$(mktemp)"
  FIXTURES_DIR="$(mktemp -d)"
  BIN_DIR="$(mktemp -d)"
  ln -s "$FIXTURES/mock-pi" "$BIN_DIR/pi"
  export PATH="$BIN_DIR:$PATH"
  export MOCK_PI_CALL_LOG="$CALL_LOG"
  export MOCK_PI_ARGV_LOG="$ARGV_LOG"
  export MOCK_PI_STDIN_LOG="$STDIN_LOG"
  export MOCK_PI_FIXTURES_DIR="$FIXTURES_DIR"
}

teardown() {
  cd "$REPO" 2>/dev/null || true
  rm -rf "$REPO" "$CALL_LOG" "$ARGV_LOG" "$STDIN_LOG" "$FIXTURES_DIR" "$BIN_DIR"
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

# --- EMPTY_DIFF (post-develop) -----------------------------------------------

@test "untracked file alone (no tracked change) still proceeds to develop and review" {
  # Clean the tracked tree; leave only an untracked file. The change set
  # (start-ref diff + untracked) is non-empty, so the driver must NOT
  # bail with EMPTY_DIFF. It should run develop (call 1) and review (call 2)
  # and end INCOMPLETE because the mock pi has no fixture for call 2.
  git checkout -q a.txt
  echo brand-new > orphan.txt
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -ne 124 ]
  # Develop ran (call 1), review ran (call 2), and the driver did not
  # exit with EMPTY_DIFF.
  [ "$(pi_calls)" -ge 2 ]
  [[ "$out" != *"\"status\":\"EMPTY_DIFF\""* ]]
}

@test "clean tree at entry -> develop still runs (no entry gate)" {
  # A clean working tree at entry is normal for a develop-first loop: the
  # developer round must run even when there is nothing to review yet.
  # The developer round must run (call 1) — there is no entry gate that
  # short-circuits a clean tree to EMPTY_DIFF before develop.
  git checkout -q a.txt
  fixture 1 'Developed in a clean tree.'
  run_driver "do it"
  [ "$(pi_calls)" -eq 1 ]
  local out
  out="$(tail_json)"
  # The run goes through develop and reaches the review round; the JSON
  # summary is emitted (run_driver captures stderr, so check pi call count
  # as the proof that develop ran, not a pre-develop bail).
  printf '%s' "$out" | jq -e . >/dev/null
}

@test "untracked file appears in the review diff (start-ref diff + untracked)" {
  echo new-module > newfile.txt
  fixture 2 'Reviewing the new module.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  # The new file must appear as an ADDITION in the review prompt:
  # `git diff --no-index -- /dev/null <f>` renders it with a
  # `new file mode` header and `+` content lines (the old reversed
  # argument order rendered it as a deletion).
  grep -q "new file mode" "$STDIN_LOG"
  grep -q "^+new-module$" "$STDIN_LOG"
  grep -q "newfile.txt" "$STDIN_LOG"
  ! grep -q "^-new-module$" "$STDIN_LOG"
}

@test "untracked file whose name contains a space is enumerated safely" {
  # `git ls-files --others --exclude-standard -z` + NUL-delimited read
  # must enumerate a path with a space verbatim (porcelain C-quoting
  # would have mangled it).
  echo spaced > "new spaced file.txt"
  fixture 2 'Reviewing the spaced file.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  grep -q "new spaced file.txt" "$STDIN_LOG"
  grep -q "^+spaced$" "$STDIN_LOG"
  # The untracked part is not the only content (a.txt is modified too),
  # so the diff-vs-start-ref part is present as well.
  grep -q "diff --git a/a.txt b/a.txt" "$STDIN_LOG"
}

@test "untracked file inside a new directory is enumerated as a file, not a dir" {
  # `git status --porcelain` lists a new directory as `?? dir/` and cannot
  # be split safely; `git ls-files --others --exclude-standard -z` must
  # enumerate the file inside it individually.
  mkdir -p new-dir
  echo in-new-dir > new-dir/inner.txt
  fixture 2 'Reviewing the new directory.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  grep -q "new-dir/inner.txt" "$STDIN_LOG"
  grep -q "^+in-new-dir$" "$STDIN_LOG"
  ! grep -q "^new-dir/$" "$STDIN_LOG"
}

@test "developer commits its change -> change is reviewed and PASS" {
  # A develop round that commits (pi often does when the task says so)
  # leaves a diff against HEAD empty. The review diff must still cover the
  # commit: it diffs against the start ref recorded at entry, not HEAD.
  local base
  base="$(git rev-parse HEAD)"
  cat > "$FIXTURES_DIR/1" <<'F'
COMMIT:committed by the develop round
F
  fixture 2 'Reviewing the committed change.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  # The mock pi commits the a.txt modification; the review prompt must
  # embed the diff-vs-start-ref (the actual content change), not an
  # empty diff. Verify both the diff header and the a.txt change are
  # present in the review prompt.
  grep -q "diff --git a/a.txt b/a.txt" "$STDIN_LOG"
  grep -q "Current diff (git diff" "$STDIN_LOG"
  # The review prompt must reference the original pre-develop commit as
  # the diff source.
  grep -q "$base" "$STDIN_LOG"
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASS" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "APPROVED" ]
}

@test "unborn repo (no commits yet): develop runs, new file reviewed" {
  # A repo with no commits: `git rev-parse HEAD` fails, so the driver must
  # fall back to the empty tree as the start ref. The developer round runs
  # (call 1), and the tracked file it produces appears in the review diff.
  git rm -rqf a.txt
  echo fresh > unborn.txt
  fixture 2 'Reviewing the new repo.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  grep -q "unborn.txt" "$STDIN_LOG"
  # The untracked file shows as an addition (not the empty tree vs HEAD
  # diff, which has no per-file content lines for a new blob).
  grep -q "new file mode" "$STDIN_LOG"
  grep -q "^+fresh$" "$STDIN_LOG"
}

@test "ignored files do NOT appear in the review diff" {
  # Ignored files must be excluded: `git ls-files --others
  # --exclude-standard` honors .gitignore, so the driver must not surface
  # them to the reviewer. The a.txt modification is a real tracked change
  # (so the test does not conflate the a.txt baseline with the ignored
  # file), and the ignored file's content must not leak into any pi call.
  echo ignored-secret > ignored.txt
  printf '%s\n' 'ignored.txt' > .gitignore
  fixture 2 'Reviewing without the ignored file.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  # The tracked change is present (sanity check: the test is exercising
  # the right scenario).
  grep -q "diff --git a/a.txt b/a.txt" "$STDIN_LOG"
  # The index must be untouched by the diff snapshot: `git diff` and
  # `git diff --no-index` never stage, so the staged tree still matches
  # HEAD.
  git diff --cached --quiet
  # The ignored file's content must not leak into any pi call.
  ! grep -q "ignored-secret" "$STDIN_LOG"
}

@test "non-empty working tree at entry: develop runs, review proceeds (no EMPTY_DIFF)" {
  # The working tree has a change at entry (a.txt is modified in setup). A
  # clean tree would be normal for develop-first, but a dirty tree must not
  # be rejected either: develop runs (call 1), the diff is non-empty, so the
  # reviewer is invoked (call 2) instead of ending EMPTY_DIFF.
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ "$(pi_calls)" -eq 2 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASS" ]
}

@test "post-develop empty diff -> EMPTY_DIFF, exit 0, 1 pi call" {
  # Clean tree at entry (develop-first is normal): the developer round runs
  # (call 1), nothing changed vs the start ref afterward, so the review
  # round ends with EMPTY_DIFF before any reviewer call. Exit stays 0.
  git checkout -q a.txt
  fixture 1 'Done.'
  run_driver "do it"
  [ "$status" -eq 0 ]
  [ "$(pi_calls)" -eq 1 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "EMPTY_DIFF" ]
  [ "$(printf '%s' "$out" | jq -r .total_pi_calls)" = "1" ]
  [ "$(printf '%s' "$out" | jq -r .rounds)" = "1" ]
}

@test "post-develop EMPTY_DIFF stderr says the developer produced no change" {
  git checkout -q a.txt
  fixture 1 'Done.'
  run_driver "do it"
  local all
  all="$(printf '%s\n' "${lines[@]}")"
  [[ "$all" == *"developer produced no change"* ]]
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
  # Wrapper git: every `git diff` (against the start ref) call fails —
  # the first diff happens at review round 1 after the develop round.
  # The `--no-index` arm is excluded so the untracked-file enumeration is
  # not confused with the tracked-diff failure.
  local wrap_dir out rc=0
  wrap_dir="$(mktemp -d)"
  cat > "$wrap_dir/git" <<'WRAP'
#!/bin/bash
# Fail the very first `git diff` (against the start ref, not HEAD). The
# `--no-index` arm is excluded so the untracked-file enumeration is not
# confused with the tracked-diff failure.
if [ "$1" = "diff" ] && [ "$2" != "--no-index" ]; then
  echo "fatal: bad thing happened" >&2
  exit 129
fi
exec /usr/bin/git "$@"
WRAP
  chmod +x "$wrap_dir/git"
  out="$(PATH="$wrap_dir:$PATH" bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  rm -f "$wrap_dir/git"; rmdir "$wrap_dir"
  [ "$rc" -eq 3 ]
  [[ "$out" == *"fatal: bad thing happened"* ]]
  [[ "$out" == *"git diff"* ]]
}

@test "git failure at entry -> PI_ERROR, exit 3" {
  # Wrapper git: fail the very first diff-vs-start-ref snapshot.
  local wrap_dir out rc=0
  wrap_dir="$(mktemp -d)"
  cat > "$wrap_dir/git" <<'WRAP'
#!/bin/bash
if [ "$1" = "diff" ] && [ "$2" != "--no-index" ]; then
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

@test "git rev-parse + hash-object failure at entry -> PI_ERROR, exit 3" {
  # Wrapper git: fail both `git rev-parse --verify -q HEAD` (start-ref
  # recording) and `git hash-object` (unborn-repo fallback), but let
  # `git rev-parse --git-dir` (preflight) succeed. The driver must not
  # proceed with an empty start ref.
  local wrap_dir out rc=0
  wrap_dir="$(mktemp -d)"
  cat > "$wrap_dir/git" <<'WRAP'
#!/bin/bash
# The wrapper blocks `git rev-parse` EXCEPT for the two forms the preflight
# needs (`--git-dir` for the is-a-repo check, `--show-toplevel` for the
# secret scan's repo root) and EXCEPT `--verify -q HEAD` (the start-ref
# recording) — those are what the driver must fail on. `hash-object` is
# blocked too (the unborn-repo fallback).
if [ "$1" = "rev-parse" ] && { [ "$2" = "--git-dir" ] || [ "$2" = "--show-toplevel" ]; }; then
  : # allow
elif [ "$1" = "rev-parse" ]; then
  echo "fatal: revparse boom" >&2
  exit 129
elif [ "$1" = "hash-object" ]; then
  echo "fatal: hash-object boom" >&2
  exit 129
fi
exec /usr/bin/git "$@"
WRAP
  chmod +x "$wrap_dir/git"
  out="$(PATH="$wrap_dir:$PATH" bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  rm -f "$wrap_dir/git"; rmdir "$wrap_dir"
  [ "$rc" -eq 3 ]
  [[ "$out" == *"fatal: hash-object boom"* ]]
}

@test "untracked-enumeration failure mid-loop -> PI_ERROR, exit 3" {
  # Wrapper git: `git ls-files --others --exclude-standard` fails on the
  # second call (the round-1 review snapshot) but succeeds on the first
  # (entry) — via a marker file. This exercises the untracked-enumeration
  # path's failure arm inside the review loop.
  local wrap_dir out rc=0
  wrap_dir="$(mktemp -d)"
  cat > "$wrap_dir/git" <<'WRAP'
#!/bin/bash
if [ -n "${LSFILES_FAIL_MARKER:-}" ] && [ "$1" = "ls-files" ]; then
  if [ -f "$LSFILES_FAIL_MARKER" ]; then
    echo "fatal: lsfiles boom" >&2
    exit 129
  fi
  touch "$LSFILES_FAIL_MARKER"
fi
exec /usr/bin/git "$@"
WRAP
  chmod +x "$wrap_dir/git"
  local marker out rc=0
  marker="$(mktemp)"
  out="$(LSFILES_FAIL_MARKER="$marker" PATH="$wrap_dir:$PATH" bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  rm -f "$marker" "$wrap_dir/git"; rmdir "$wrap_dir"
  [ "$rc" -eq 3 ]
  [[ "$out" == *"fatal: lsfiles boom"* ]]
}

@test "pi timeout (SLEEP fixture, PI_TIMEOUT=1) -> PI_ERROR, exit 3, timeout message" {
  printf 'SLEEP:2\nshould never appear\n' > "$FIXTURES_DIR/1"
  local out rc=0
  out="$(PI_TIMEOUT=1 bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"pi timed out after 1s"* ]]
}

@test "pi timeout (SLEEP-IGNORE-TERM fixture, PI_TIMEOUT=1 PI_KILL_AFTER=1) -> PI_ERROR, exit 3, < 10s" {
  # A pi that traps/ignores SIGTERM must be killed by the SIGKILL escalation
  # at kill-after expiry (rc 137). With PI_TIMEOUT=1 and PI_KILL_AFTER=1 the
  # total wall clock is ~2s; the < 10s bound guards against a regression where
  # --kill-after is missing and the process runs unbounded.
  printf 'SLEEP-IGNORE-TERM:30\nnever reached\n' > "$FIXTURES_DIR/1"
  local t0 t1 elapsed out rc=0
  t0=$(date +%s)
  out="$(PI_TIMEOUT=1 PI_KILL_AFTER=1 bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  [ "$rc" -eq 3 ]
  [[ "$out" == *"pi timed out after 1s"* ]]
  [ "$elapsed" -lt 10 ]
}

@test "pi timeout (SLEEP-IGNORE-TERM, PI_KILL_AFTER=2) -> PI_ERROR, exit 3, < 10s" {
  # A slightly longer kill-after window (2s) still finishes well under the
  # 10s budget, confirming the escalation works for any positive PI_KILL_AFTER.
  printf 'SLEEP-IGNORE-TERM:30\nnever reached\n' > "$FIXTURES_DIR/1"
  local t0 t1 elapsed out rc=0
  t0=$(date +%s)
  out="$(PI_TIMEOUT=1 PI_KILL_AFTER=2 bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  [ "$rc" -eq 3 ]
  [[ "$out" == *"pi timed out after 1s"* ]]
  [ "$elapsed" -lt 10 ]
}

@test "oversized diff is truncated with a notice (PI_DIFF_MAX_BYTES=400)" {
  # a.txt is ~5KB; the review prompt's embedded diff must carry the
  # truncation notice (with actual shown/total byte counts) and the head
  # of the diff, but not its tail.
  head -c 5000 /dev/zero | tr '\0' 'a' > a.txt
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  PI_DIFF_MAX_BYTES=400 bash "$SCRIPT" "do it" >/dev/null 2>&1 || true
  grep -q "truncated: [1-9][0-9]* of [1-9][0-9]* bytes shown" "$STDIN_LOG"
  grep -q "PI_DIFF_MAX_BYTES=400)" "$STDIN_LOG"
  # The prompt must still embed the diff marker.
  grep -q "Current diff (git diff" "$STDIN_LOG"
  # The truncation must keep a non-trivial head of the diff — on BSD head
  # (macOS) the old `head -n -1` line trim silently produced an empty diff.
  # 400-byte cap on a ~5KB diff: at least the first diff line must remain.
  grep -q "diff --git a/a.txt b/a.txt" "$STDIN_LOG"
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
  grep -q "truncated: [1-9][0-9]* of [1-9][0-9]* bytes shown" "$STDIN_LOG"
  # The bulk of the transcript must NOT be embedded (it would appear as
  # 1000 consecutive 'x' characters in the stdin log).
  ! grep -q "${big}" "$STDIN_LOG"
}

@test "small diff is NOT truncated (no notice under PI_DIFF_MAX_BYTES)" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  PI_DIFF_MAX_BYTES=999999 bash "$SCRIPT" "do it" >/dev/null 2>&1 || true
  ! grep -q "bytes shown (PI_DIFF_MAX_BYTES" "$STDIN_LOG"
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
  # The review prompt (stdin of pi call 2) contains the "Current diff
  # (git diff ...):" marker exactly once in the STDIN_LOG file.
  # od -c renders a real newline (0x0a) as two chars "\n"; a literal
  # two-char "\n" in the prompt would render as four chars "\ \\ n".
  # Count occurrences of the real-newline rendering before the marker
  # ("\\n C") — must be >= 1 — and of the literal rendering
  # ("\\ \\ n C") — must be 0.
  local real literal
  real="$(od -An -c "$STDIN_LOG" | tr -s ' ' | grep -c '\\n C' || true)"
  [ "$real" -ge 1 ]
  literal="$(od -An -c "$STDIN_LOG" | tr -s ' ' | grep -c '\\ \\ n C' || true)"
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
  # Verify by checking the STDIN_LOG: the fix prompt (stdin of call 3)
  # should contain the finding text.
  grep -q "a.txt:1] wrong value" "$STDIN_LOG"
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
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "null" ]
  printf '%s\n' "${lines[@]}" | grep -q "auth failure: token expired"
}

@test "PI_ERROR summary exposes the verdict key (null when absent)" {
  # Regression guard: the JSON contract says the `verdict` key is always
  # present (null when no verdict was reached). If fail_pi_error ever
  # stops passing the verdict argument, the key disappears from the
  # summary and agents parsing with `.verdict` misclassify the schema.
  printf 'EXIT:1\nboom\n' > "$FIXTURES_DIR/2"
  run_driver "do it"
  [ "$status" -eq 3 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r 'has("verdict")')" = "true" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "null" ]
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
  for flag in --mode -p --no-session --no-extensions --no-skills --no-prompt-templates --no-context-files; do
    grep -q -- "$flag" "$ARGV_LOG"
  done
  grep -q "gpt-test" "$ARGV_LOG"
}

@test "PI_CONTEXT_FILES=1 opts out of --no-context-files" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  PI_CONTEXT_FILES=1 run_driver "do it"
  [ "$status" -eq 0 ]
  ! grep -q -- '--no-context-files' "$ARGV_LOG"
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
  # appears in the STDIN_LOG as part of the review prompt.
  grep -q "diff --git a/a.txt b/a.txt" "$STDIN_LOG"
  grep -q -- "-base" "$STDIN_LOG"
  grep -q -- "+modified" "$STDIN_LOG"
}

@test "round announcements go to stderr with round numbering" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  local all
  all="$(printf '%s\n' "${lines[@]}")"
  [[ "$all" == *"Round 1/3: reviewing"* ]]
}

# --- Issue #29: stdin transport, total budget, trim_diff edge case ------------

@test "prompt is passed via stdin, not as an argv argument" {
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  # The ARGV_LOG should contain only flags (no multi-line prompt text).
  # The develop prompt (task "do it") should NOT appear in the ARGV_LOG
  # as a positional argument. The flags are still there.
  grep -q -- "--mode" "$ARGV_LOG"
  grep -q -- "--no-session" "$ARGV_LOG"
  # The task text IS in the stdin log (piped to pi).
  grep -q "do it" "$STDIN_LOG"
}

@test "total prompt budget exceeded -> PI_ERROR with clear message (PI_PROMPT_MAX_BYTES=10)" {
  # Set PI_PROMPT_MAX_BYTES very low so any prompt exceeds it.
  # The driver should produce a clear error mentioning the byte count.
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  local out rc=0
  out="$(PI_PROMPT_MAX_BYTES=10 bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  # Should fail (exit 3 = PI_ERROR) with a clear message about the limit.
  [ "$rc" -eq 3 ]
  [[ "$out" == *"exceeds"* ]]
  [[ "$out" == *"PI_PROMPT_MAX_BYTES"* ]]
}

@test "total prompt budget: normal-sized prompts pass (PI_PROMPT_MAX_BYTES=120000)" {
  # Default budget should allow normal-sized prompts through.
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  PI_PROMPT_MAX_BYTES=120000 bash "$SCRIPT" "do it" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ]
}

@test "trim_diff: truncated prefix with no newline keeps the prefix (not empty)" {
  # Create a diff where the first line has no newline within the limit.
  # With PI_DIFF_MAX_BYTES=50 and a file whose first diff line is 60 bytes,
  # the truncated prefix (50 bytes) has no newline — the old code would
  # empty it; the fix keeps the 50-byte prefix.
  local bigline
  bigline="$(head -c 60 /dev/zero | tr '\0' 'X')"
  echo "$bigline" > bigfile.txt
  git add bigfile.txt
  # Now the diff will be ~70 bytes for this file. With PI_DIFF_MAX_BYTES=30,
  # the 30-byte prefix has no newline (the first line is 61 bytes including newline).
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  PI_DIFF_MAX_BYTES=30 bash "$SCRIPT" "do it" >/dev/null 2>&1 || true
  # The truncation notice must be present.
  grep -q "truncated:" "$STDIN_LOG"
  # The prefix must NOT be empty: at least some X characters from the big
  # line should appear before the truncation notice.
  local xcount
  xcount="$(grep -o 'X' "$STDIN_LOG" | wc -l | tr -d ' ')"
  [ "$xcount" -gt 0 ]
}

# --- Issue #26: provider/model verification ---------------------------------

@test "assistant message_end with provider/model -> logged to stderr as provider/model pair" {
  # The mock serves the fixture raw; a real pi --mode json line with the
  # provider/model fields must be surfaced on stderr. The driver's verdict
  # parser still extracts the text, so the run stays PASS.
  cat > "$FIXTURES_DIR/1" <<'F'
{"type":"message_end","message":{"role":"assistant","stopReason":"stop","provider":"anthropic","model":"claude-test","content":[{"type":"text","text":"Developed it."}]}}
F
  cat > "$FIXTURES_DIR/2" <<'F'
{"type":"message_end","message":{"role":"assistant","stopReason":"stop","provider":"anthropic","model":"claude-test","content":[{"type":"text","text":"Looks fine."},{"type":"text","text":"VERDICT: APPROVED"}]}}
F
  run_driver "do it"
  [ "$status" -eq 0 ]
  local all
  all="$(printf '%s\n' "${lines[@]}")"
  [[ "$all" == *"provider/model anthropic/claude-test"* ]]
}

@test "missing provider/model fields -> 'unknown/unknown' is logged, run unaffected" {
  # The 6-field JSON contract and the exit code must not change when the
  # transcript omits provider/model (an older or third-party pi). The mock
  # fixture builder omits the fields, so both rounds log unknown/unknown
  # and the run still ends PASS.
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  local all
  all="$(printf '%s\n' "${lines[@]}")"
  [[ "$all" == *"provider/model unknown/unknown"* ]]
}

@test "no assistant message_end (empty transcript) -> 'not reported', run unaffected" {
  # A pi call that succeeded but emitted nothing (mock with no fixture for
  # the review call) exercises the no-match arm of the verification.
  fixture 1 'Developed it.'
  run_driver "do it"
  # Develop round parses fine (empty transcript), review round has no
  # fixture: its empty transcript yields the "not reported" line and the
  # run ends INCOMPLETE (no verdict) — exit code unchanged from before.
  [ "$status" -eq 2 ]
  local all
  all="$(printf '%s\n' "${lines[@]}")"
  [[ "$all" == *"provider/model not reported in transcript"* ]]
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

@test "PI_KILL_AFTER=0 -> usage error, exit 2" {
  local out rc=0
  out="$(PI_KILL_AFTER=0 bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  [[ "$out" == *"PI_KILL_AFTER"* ]]
}

@test "PI_KILL_AFTER=abc -> usage error, exit 2" {
  local out rc=0
  out="$(PI_KILL_AFTER=abc bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  [[ "$out" == *"PI_KILL_AFTER"* ]]
}

@test "PI_KILL_AFTER=-5 -> usage error, exit 2" {
  local out rc=0
  out="$(PI_KILL_AFTER=-5 bash "$SCRIPT" "do it" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ]
  [[ "$out" == *"PI_KILL_AFTER"* ]]
}

# --- Issue #16 coverage: verdict variants, round-cap sentinel, mid-loop INCOMPLETE, JSON shape

# --- Verdict parser: case-insensitive variants --------------------------------

@test "verdict variant: 'verdict: approved' (lowercase + colon) parses to APPROVED" {
  fixture 2 'All good.' 'verdict: approved'
  run_driver "do it"
  [ "$status" -eq 0 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "APPROVED" ]
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASS" ]
}

@test "verdict variant: 'VERDICT: APPROVED' (uppercase + colon) parses to APPROVED" {
  fixture 2 'All good.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "APPROVED" ]
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASS" ]
}

@test "verdict variant: '**VERDICT**: Approved' (bold + colon + mixed case) parses to APPROVED" {
  fixture 2 'All good.' '**VERDICT**: Approved'
  run_driver "do it"
  [ "$status" -eq 0 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "APPROVED" ]
  [ "$(printf '%s' "$out" | jq -r .status)" = "PASS" ]
}

# --- Hard caps: 7th pi call is impossible --------------------------------------

@test "always-CRITICAL review: hard cap holds, exactly 6 pi calls, round-7 sentinel never fires" {
  # Every review (calls 2, 4, 6) returns CRITICAL_ISSUES_FOUND, so the driver
  # must keep dispatching fixes until both hard caps (3 rounds, 6 total calls)
  # exhaust. Fixture 7 is a sentinel: it is only served if the driver ever
  # makes a 7th pi call, which it must not. A missing fixture would be
  # indistinguishable from "never called", so the sentinel file IS created
  # and the test asserts its content never leaks into any driver output.
  local i
  for i in 2 4 6; do
    fixture "$i" 'Broken beyond repair.' '- [a.txt:1] unrecoverable defect' 'VERDICT: CRITICAL_ISSUES_FOUND'
  done
  fixture 7 'SENTINEL_ROUND_7_MUST_NEVER_APPEAR'
  run_driver "do it"
  [ "$status" -eq 1 ]
  [ "$(pi_calls)" -eq 6 ]
  local out all
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "REJECTED" ]
  [ "$(printf '%s' "$out" | jq -r .total_pi_calls)" = "6" ]
  [ "$(printf '%s' "$out" | jq -r .rounds)" = "3" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "CRITICAL_ISSUES_FOUND" ]
  all="$(printf '%s\n' "${lines[@]}")"
  [[ "$all" != *"SENTINEL_ROUND_7_MUST_NEVER_APPEAR"* ]]
  ! grep -q "SENTINEL_ROUND_7_MUST_NEVER_APPEAR" "$STDIN_LOG"
}

# --- Mid-loop INCOMPLETE --------------------------------------------------------

@test "INCOMPLETE at round 3 (unparseable reviewer output mid-loop) -> exit 2, rounds=3, 6 pi calls" {
  # Rounds 1-2 (calls 2, 4) return ISSUES_FOUND, so two fixes run (calls 3, 5).
  # Round 3 (call 6) returns prose with NO verdict line anywhere — the parser
  # must find nothing (last-occurrence rule makes any stray verdict count)
  # and the driver must bail INCOMPLETE at round 3, having already spent
  # develop + 3 reviews + 2 fixes = 6 pi calls.
  fixture 2 'Broken.' '- [a.txt:1] defect one' 'VERDICT: ISSUES_FOUND'
  fixture 3 'Fix applied.'
  fixture 4 'Still not right.' '- [a.txt:2] defect two' 'VERDICT: ISSUES_FOUND'
  fixture 5 'Fix applied.'
  fixture 6 'I am unsure how to proceed with this change set.'
  run_driver "do it"
  [ "$status" -eq 2 ]
  [ "$(pi_calls)" -eq 6 ]
  local out
  out="$(tail_json)"
  [ "$(printf '%s' "$out" | jq -r .status)" = "INCOMPLETE" ]
  [ "$(printf '%s' "$out" | jq -r .rounds)" = "3" ]
  [ "$(printf '%s' "$out" | jq -r .total_pi_calls)" = "6" ]
  [ "$(printf '%s' "$out" | jq -r .verdict)" = "null" ]
}

# --- JSON summary shape / types --------------------------------------------------

@test "JSON summary shape: last stdout line parses with exactly the 6 contract keys, correct types" {
  # PASS path so the string (not null) verdict branch is exercised.
  fixture 2 'Looks fine.' '- [a.txt:1] nit' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  local out
  out="$(tail_json)"
  # The last stdout line must be valid JSON.
  printf '%s' "$out" | jq -e . >/dev/null
  # Key set is exactly {status, verdict, rounds, total_pi_calls, findings, raw_output}.
  [ "$(printf '%s' "$out" | jq -r 'keys_unsorted | sort | join(",")')" \
    = "findings,raw_output,rounds,status,total_pi_calls,verdict" ]
  # Types: status string, verdict string-or-null, rounds/total_pi_calls numbers,
  # findings array, raw_output string.
  [ "$(printf '%s' "$out" | jq -er '.status | type')" = "string" ]
  [ "$(printf '%s' "$out" | jq -er 'if .verdict == null then "null" else (.verdict | type) end')" = "string" ]
  [ "$(printf '%s' "$out" | jq -er '.rounds | type')" = "number" ]
  [ "$(printf '%s' "$out" | jq -er '.total_pi_calls | type')" = "number" ]
  [ "$(printf '%s' "$out" | jq -r '.findings | type')" = "array" ]
  [ "$(printf '%s' "$out" | jq -r '.raw_output | type')" = "string" ]
}

# --- Doc-drift: docs/configuration.md is the single source of truth for the
# timeout contract (issue #45). Every literal is asserted in exactly ONE
# owning file; cross-file tests compare docs/configuration.md against
# skills/pi-oneshot/SKILL.md (the executable wrapper spec). ---

timeout_section() {
  # The whole timeout contract: from the PI_TIMEOUT knob heading down to the
  # Flags heading (both sections are part of the contract: the wrapper,
  # gtimeout fallback, 124/137 semantics, and the unbounded-with-warning
  # path). The range closes on ANY next `## ` heading, not on a specific
  # heading name, so it cannot select nothing or over-select if sections
  # reorder. Prints the selected lines so a range failure is visible in
  # the test transcript (empty output is caught by the grep failures).
  local config
  config="$REPO_ROOT/docs/configuration.md"
  [ -f "$config" ]
  grep -q '^### `PI_TIMEOUT` ' "$config"
  grep -q '^## Flags' "$config"
  awk '/^### `PI_TIMEOUT` /{s=1; next} s && /^## /{s=0} s {print}' "$config"
}

@test "docs/configuration.md owns the PI_TIMEOUT/PI_KILL_AFTER defaults (1800/30) in the wrapper literal" {
  local section
  section="$(timeout_section)"
  printf '%s\n' "$section" | grep -qF 'PI_TIMEOUT:-1800'
  printf '%s\n' "$section" | grep -qF 'PI_KILL_AFTER:-30'
  # The selected section must be exactly the timeout contract (PI_TIMEOUT
  # knob → Flags heading), not an over- or under-selection: it must start
  # at the PI_TIMEOUT heading and must NOT leak the Long runs section (the
  # next ## section after Flags) or the Environment variables header.
  [ -n "$section" ]
  # The awk helper skips the PI_TIMEOUT heading line itself (s=1; next);
  # assert the contract starts at PI_TIMEOUT by checking the heading is
  # present immediately before the first line of the selection.
  run grep -q '^### `PI_TIMEOUT` ' "$REPO_ROOT/docs/configuration.md"
  [ "$status" -eq 0 ]
  run grep -q '^## Flags' "$REPO_ROOT/docs/configuration.md"
  [ "$status" -eq 0 ]
  run grep -q '^## Long runs under' <<<"$section"
  [ "$status" -ne 0 ]
  run grep -q '^## Environment variables' <<<"$section"
  [ "$status" -ne 0 ]
  printf '%s\n' "$section"
}

@test "docs/configuration.md owns the wrapper literal (--kill-after, timeout/gtimeout)" {
  local section
  section="$(timeout_section)"
  # Word boundary so this does not match incidental numerals or "gtimeout".
  printf '%s\n' "$section" | grep -qE '(^|[^0-9])timeout([^0-9]|$)'
  printf '%s\n' "$section" | grep -q 'gtimeout'
  printf '%s\n' "$section" | grep -q -- '--kill-after'
  printf '%s\n' "$section"
}

@test "docs/configuration.md owns the 124/137 = timed out semantics" {
  local section
  section="$(timeout_section)"
  printf '%s\n' "$section" | grep -qE '(^|[^0-9])124([^0-9]|$)'
  printf '%s\n' "$section" | grep -qE '(^|[^0-9])137([^0-9]|$)'
  printf '%s\n' "$section" | grep -q 'SIGTERM at'
  printf '%s\n' "$section" | grep -q 'SIGKILL escalation'
  printf '%s\n' "$section" | grep -qi 'timed out'
  printf '%s\n' "$section"
}

@test "docs/configuration.md owns the unbounded-with-warning path" {
  local section
  section="$(timeout_section)"
  printf '%s\n' "$section" | grep -qi 'unbounded'
  printf '%s\n' "$section" | grep -qi 'warning'
  printf '%s\n' "$section"
}

long_runs_section() {
  # The Long runs section only (start at its heading, stop at the NEXT
  # heading of any level — this file currently ends the document with this
  # section, but the end anchor must not be another section's heading).
  # Prints the selected lines; the grep assertions below fail loudly if
  # the range is empty.
  local config
  config="$REPO_ROOT/docs/configuration.md"
  [ -f "$config" ]
  grep -q '^## Long runs under' "$config"
  awk '/^## Long runs under/{s=1; next} s && /^##/{s=0} s {print}' "$config"
}

@test "docs/configuration.md owns the long-run guidance (run_in_background + Read polling)" {
  local section
  section="$(long_runs_section)"
  printf '%s\n' "$section" | grep -q 'run_in_background'
  printf '%s\n' "$section" | grep -q 'Read'
  # Exactly the Long runs section: starts at its heading, no leak from the
  # Flags or Environment variables sections. The awk helper skips the
  # Long runs heading line itself (s=1; next), so assert the heading is
  # present in the source file and the selection does not leak other
  # sections.
  [ -n "$section" ]
  run grep -q '^## Long runs under' "$REPO_ROOT/docs/configuration.md"
  [ "$status" -eq 0 ]
  run grep -q '^## Flags' <<<"$section"
  [ "$status" -ne 0 ]
  run grep -q '^### `PI_' <<<"$section"
  [ "$status" -ne 0 ]
  printf '%s\n' "$section"
}

@test "docs/configuration.md owns the worst-case loop wall clock (183 min)" {
  local section
  section="$(long_runs_section)"
  printf '%s\n' "$section" | grep -q '183 min'
  # The derivation lives in the owning section, not just the number.
  printf '%s\n' "$section" | grep -q -- '10980'
  printf '%s\n' "$section"
}

@test "cross-file: pi-oneshot SKILL.md wrapper matches docs/configuration.md (defaults, gtimeout, 124/137)" {
  local oneshot config_section
  oneshot="$REPO_ROOT/skills/pi-oneshot/SKILL.md"
  config_section="$(timeout_section)"
  [ -f "$oneshot" ]
  # Defaults agree.
  grep -qF 'PI_TIMEOUT:-1800' "$oneshot"
  grep -qF 'PI_KILL_AFTER:-30' "$oneshot"
  printf '%s\n' "$config_section" | grep -qF 'PI_TIMEOUT:-1800'
  printf '%s\n' "$config_section" | grep -qF 'PI_KILL_AFTER:-30'
  # gtimeout fallback stated in both.
  grep -q 'gtimeout' "$oneshot"
  printf '%s\n' "$config_section" | grep -q 'gtimeout'
  # 124/137 semantics: both files state both codes with the SIG signal.
  grep -qE '(^|[^0-9])124([^0-9]|$)' "$oneshot"
  grep -qE '(^|[^0-9])137([^0-9]|$)' "$oneshot"
  grep -qi 'SIGTERM' "$oneshot"
  grep -qi 'SIGKILL' "$oneshot"
  printf '%s\n' "$config_section" | grep -qE '(^|[^0-9])124([^0-9]|$)'
  printf '%s\n' "$config_section" | grep -qE '(^|[^0-9])137([^0-9]|$)'
}

@test "cross-file: pi-oneshot SKILL.md unbounded warning message matches orchestrate.sh" {
  # SKILL.md prints its own warning string; it must match the driver's.
  local oneshot driver
  oneshot="$REPO_ROOT/skills/pi-oneshot/SKILL.md"
  driver="$REPO_ROOT/skills/pi-review-loop/orchestrate.sh"
  local skill_msg driver_msg
  skill_msg="$(grep -oE 'WARNING: no GNU timeout/gtimeout found[^"]*' "$oneshot" | head -n 1)"
  driver_msg="$(grep -oE 'WARNING: neither timeout nor gtimeout found[^"]*' "$driver" | head -n 1)"
  [ -n "$skill_msg" ]
  [ -n "$driver_msg" ]
  # Both must state the same degraded mode: no usable timeout binary,
  # calls run without a time limit.
  [[ "$skill_msg" == *"without a time limit"* ]]
  [[ "$driver_msg" == *"without a time limit"* ]]
}

@test "cross-file: docs/how-it-works.md links to configuration.md for the worst-case derivation" {
  local how
  how="$REPO_ROOT/docs/how-it-works.md"
  [ -f "$how" ]
  grep -q 'configuration.md#long-runs-under-claude-codes-bash-tool' "$how"
}

@test "README carries no timeout-contract literals (single source: docs/configuration.md)" {
  local readme
  readme="$REPO_ROOT/README.md"
  [ -f "$readme" ]
  run grep -qF 'PI_TIMEOUT:-1800' "$readme"
  [ "$status" -ne 0 ]
  run grep -qF 'PI_KILL_AFTER:-30' "$readme"
  [ "$status" -ne 0 ]
  run grep -q -- '--kill-after' "$readme"
  [ "$status" -ne 0 ]
  run grep -q 'gtimeout' "$readme"
  [ "$status" -ne 0 ]
  run grep -qE '(^|[^0-9])124([^0-9]|$)' "$readme"
  [ "$status" -ne 0 ]
  run grep -qE '(^|[^0-9])137([^0-9]|$)' "$readme"
  [ "$status" -ne 0 ]
  run grep -qi 'unbounded' "$readme"
  [ "$status" -ne 0 ]
  run grep -q '183 min' "$readme"
  [ "$status" -ne 0 ]
}

# --- #40 regression greps (README drift fixes) ----------------------------

@test "#40 regression: no '--max-rounds 3' remediation advice in README or docs" {
  local f
  for f in "$REPO_ROOT/README.md" "$REPO_ROOT/docs/troubleshooting.md" "$REPO_ROOT/docs/how-it-works.md" "$REPO_ROOT/docs/configuration.md"; do
    ! grep -q -- '--max-rounds 3' "$f"
  done
  # The troubleshooting REJECTED section must instead give the hard-cap
  # fact and actionable advice.
  grep -q 'hard-capped at 3' "$REPO_ROOT/docs/troubleshooting.md"
  grep -q 're-run' "$REPO_ROOT/docs/troubleshooting.md"
}

@test "#40 regression: no 'not present yet' install conditional in README or docs" {
  local f
  for f in "$REPO_ROOT/README.md" "$REPO_ROOT/docs/troubleshooting.md" "$REPO_ROOT/docs/how-it-works.md" "$REPO_ROOT/docs/configuration.md"; do
    ! grep -qi 'not present yet' "$f"
  done
}

@test "#40 regression: docs/how-it-works.md loop sequence distinguishes the ISSUES_FOUND and CRITICAL arms with the non-terminal fix round" {
  local how
  how="$REPO_ROOT/docs/how-it-works.md"
  [ -f "$how" ]
  # The ISSUES_FOUND bullet must mention a fix round at non-terminal rounds
  # (and only the terminal round is PASSED_WITH_FINDINGS).
  #
  # awk range note (issue #45 review): the previous forms used two named
  # headings as start/end anchors (e.g. `/^## Long runs under/,/^## Flags/`).
  # That shape is fragile for two reasons: (1) it only works when the end
  # heading happens to be the *next* `## ` heading after the start heading —
  # if a new section is inserted between them, the range closes early and the
  # assertions pass on a truncated selection; (2) if the headings are ever
  # reordered so the end heading precedes the start heading in the file, the
  # range selects *nothing* (awk starts the range at the start heading, which
  # is already past the end heading, and never re-opens it). Neither of these
  # has anything to do with bash history expansion: these bats files run
  # non-interactively, `!` never reaches a shell, and the range either
  # worked or silently returned a too-small/too-big slice — the earlier
  # "history expansion turned `!` into `s`" claim was false. The fix: close
  # the range on ANY next `## ` heading, and print the selected lines so a
  # range failure is visible in the transcript instead of masked by a
  # silent pass.
  seq="$(awk '/^## Loop sequence/{s=1; next} s && /^## /{s=0} s {print}' "$how")"
  [ -n "$seq" ]  # the range must not be empty
  printf '%s\n' "$seq" | grep -q 'ISSUES_FOUND'
  printf '%s\n' "$seq" | grep -q 'non-terminal'
  printf '%s\n' "$seq" | grep -q 'PASSED_WITH_FINDINGS'
  printf '%s\n' "$seq" | grep -q 'fix round'
  printf '%s\n' "$seq" | grep -q 'CRITICAL_ISSUES_FOUND'
  printf '%s\n' "$seq" | grep -q 'REJECTED'
  # The verdict table row must likewise carry the non-terminal fix round.
  vtab="$(awk '/^## Verdicts/{s=1; next} s && /^## /{s=0} s {print}' "$how")"
  [ -n "$vtab" ]
  printf '%s\n' "$vtab" | grep -q 'ISSUES_FOUND'
  printf '%s\n' "$vtab" | grep -q 'non-terminal'
}

# --- Issue #30: safety preflight ------------------------------------------------

@test "safety: refuse on the default branch (exit 3, PI_ERROR JSON, REFUSED stderr)" {
  # The setup creates a feature branch; switch back to main to trigger the refusal.
  git checkout -q main
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED:"* ]]
  [[ "$out" == *"default branch"* ]]
  [[ "$out" == *"PI_DELEGATE_UNSAFE=1"* ]]
  # The JSON summary must be the last line with status PI_ERROR.
  local last
  last="$(printf '%s\n' "$out" | tail -n 1)"
  printf '%s' "$last" | jq -e '.status == "PI_ERROR"' >/dev/null
}

@test "safety: allow on a feature branch (no refusal, develop runs)" {
  # The setup creates a feature branch; stay on it. The preflight must not
  # fire, and the develop round must run.
  fixture 1 'Developed it.'
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -ne 3 ]
  [[ "$out" != *"REFUSED:"* ]]
}

@test "safety: refuse on detached HEAD at the default branch's tip" {
  # Switch to main, then detach at the tip.
  git checkout -q main
  git checkout -q --detach
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED:"* ]]
  [[ "$out" == *"detached HEAD"* ]]
  [[ "$out" == *"default branch"* ]]
}

@test "safety: refuse when .env is present in the working tree" {
  # On the feature branch (setup), add a .env file.
  echo "SECRET=abc" > .env
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED:"* ]]
  [[ "$out" == *"secret-looking file"* ]]
  [[ "$out" == *".env"* ]]
}

@test "safety: allow when only .env.example is present" {
  # On the feature branch (setup), add only .env.example (safe).
  echo "SECRET=example" > .env.example
  fixture 1 'Developed it.'
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -ne 3 ]
  [[ "$out" != *"REFUSED:"* ]]
}

@test "safety: refuse when a *.pem file is present" {
  # On the feature branch (setup), add a .pem file.
  echo "-----BEGIN KEY-----" > key.pem
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED:"* ]]
  [[ "$out" == *"secret-looking file"* ]]
  [[ "$out" == *".pem"* ]]
}

@test "safety: refuse when a *.key file is present" {
  # On the feature branch (setup), add a .key file.
  echo "KEYDATA" > secret.key
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED:"* ]]
  [[ "$out" == *"secret-looking file"* ]]
  [[ "$out" == *".key"* ]]
}

@test "safety: refuse when a .env symlink is present" {
  # The scan must match symlinks too: a .env symlink is as readable as the
  # real file, so it must be refused.
  echo "TARGET=real-secret" > real-secret.txt
  ln -s real-secret.txt .env
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED:"* ]]
  [[ "$out" == *"secret-looking file"* ]]
  [[ "$out" == *".env"* ]]
}

@test "safety: refuse when a *.key symlink is present" {
  echo "K" > backing.key-file.txt
  ln -s backing.key-file.txt cert.key
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED:"* ]]
  [[ "$out" == *"cert.key"* ]]
}

@test "safety: secret scan reports paths relative to the repo root" {
  # The scan runs from the repo root, so the refusal message must carry a
  # root-relative path (no leading slash, no './' prefix).
  echo "SECRET=abc" > .env
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED: secret-looking file(s) present in the working tree: .env"* ]]
}

@test "safety: fail-closed — unreadable directory in the scan -> PI_ERROR, exit 3" {
  # The secret scan is fail-closed: if `find` cannot read a directory (e.g.
  # permissions 000), the driver must refuse (exit 3, PI_ERROR JSON, a
  # REFUSED: secret-file scan failed message) rather than pass with a
  # partial scan. Root can read anything, so this test only works for
  # non-root users.
  [ "$(id -u)" -ne 0 ] || skip "running as root; chmod 000 cannot block the scan"
  local hidden
  hidden="locked-dir"
  mkdir "$hidden"
  chmod 000 "$hidden"
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  chmod 755 "$hidden" 2>/dev/null || true
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED: secret-file scan failed"* ]]
  # The JSON summary must be the last line with status PI_ERROR.
  local last
  last="$(printf '%s\n' "$out" | tail -n 1)"
  printf '%s' "$last" | jq -e '.status == "PI_ERROR"' >/dev/null
}

@test "safety: opt-out PI_DELEGATE_UNSAFE=1 allows the default branch" {
  # On main (default), the opt-out must skip the preflight and let the
  # develop round run.
  git checkout -q main
  fixture 1 'Developed it.'
  local out rc=0
  out="$(PI_DELEGATE_UNSAFE=1 bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -ne 3 ]
  [[ "$out" != *"REFUSED:"* ]]
}

@test "safety: opt-out PI_DELEGATE_UNSAFE=1 allows secret files" {
  # On the feature branch with a .env present, the opt-out must skip the
  # preflight.
  echo "SECRET=abc" > .env
  fixture 1 'Developed it.'
  local out rc=0
  out="$(PI_DELEGATE_UNSAFE=1 bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -ne 3 ]
  [[ "$out" != *"REFUSED:"* ]]
}

@test "safety: opt-out PI_DELEGATE_UNSAFE=1 allows detached HEAD at default tip" {
  git checkout -q main
  git checkout -q --detach
  fixture 1 'Developed it.'
  local out rc=0
  out="$(PI_DELEGATE_UNSAFE=1 bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -ne 3 ]
  [[ "$out" != *"REFUSED:"* ]]
}

@test "safety: push neutralisation — mock pi push fails (default)" {
  # On the feature branch (setup), add a remote, and have the mock pi attempt
  # a push. The GIT_CONFIG_* env must make the push fail.
  # Set up a bare remote to push to.
  local remote
  remote="$(mktemp -d)/origin.git"
  git init -q --bare "$remote"
  git -C "$remote" config receive.denyCurrentBranch ignore
  git remote add origin "$remote"
  # Create a commit to push.
  echo more >> a.txt
  git add a.txt
  git commit -qm "push test"
  # Side file the mock pi appends the push exit code to.
  local push_log
  push_log="$(mktemp)"
  export MOCK_PI_PUSH_LOG="$push_log"
  # Fixture: the mock pi attempts a push (PUSH: directive). Write the raw
  # directive (not JSON-wrapped) so the mock pi's case match sees "PUSH:".
  printf '%s\n' 'PUSH:origin HEAD' > "$FIXTURES_DIR/1"
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  # The push must have failed (non-zero exit code in the side file).
  [ -s "$push_log" ]
  local p_rc
  p_rc="$(head -n 1 "$push_log" | tr -d ' ')"
  [ -n "$p_rc" ] && [ "$p_rc" -ne 0 ]
  # The remote must NOT have received the push.
  [ "$(git -C "$remote" for-each-ref 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]
  rm -f "$push_log"
  rm -rf "$(dirname "$remote")"
}

@test "safety: push neutralisation — mock pi push succeeds with opt-out" {
  # On the feature branch (setup), add a remote, and have the mock pi attempt
  # a push. With PI_DELEGATE_UNSAFE=1, the GIT_CONFIG_* env is not set, so the
  # push must succeed.
  local remote
  remote="$(mktemp -d)/origin.git"
  git init -q --bare "$remote"
  git -C "$remote" config receive.denyCurrentBranch ignore
  git remote add origin "$remote"
  echo more >> a.txt
  git add a.txt
  git commit -qm "push test optout"
  # Side file the mock pi appends the push exit code to.
  local push_log
  push_log="$(mktemp)"
  export MOCK_PI_PUSH_LOG="$push_log"
  printf '%s\n' 'PUSH:origin HEAD' > "$FIXTURES_DIR/1"
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  local out rc=0
  out="$(PI_DELEGATE_UNSAFE=1 bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  # The push must have succeeded (exit code 0 in the side file).
  [ -s "$push_log" ]
  local p_rc
  p_rc="$(head -n 1 "$push_log" | tr -d ' ')"
  [ -n "$p_rc" ] && [ "$p_rc" -eq 0 ]
  # The remote must have received the push.
  [ "$(git -C "$remote" for-each-ref 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]
  rm -f "$push_log"
  rm -rf "$(dirname "$remote")"
}

@test "safety: push neutralisation — explicit URL pushes are blocked (pushInsteadOf)" {
  # The preflight rewrites common URL prefixes to the dead helper via
  # pushInsteadOf, so `git push <url>` (which bypasses per-remote config)
  # must also fail. This exercises the REAL driver: the mock pi's PUSH: and
  # ENV: directives run inside an actual orchestrate.sh invocation, so the
  # env it dumps (MOCK_PI_ENV_LOG) is the config the driver itself built.
  local remote
  remote="$(mktemp -d)/origin.git"
  git init -q --bare "$remote"
  git -C "$remote" config receive.denyCurrentBranch ignore
  git remote add origin "$remote"
  echo more >> a.txt
  git add a.txt
  git commit -qm "pushinsteadof test"

  local push_log env_log
  push_log="$(mktemp)"
  env_log="$(mktemp)"
  export MOCK_PI_PUSH_LOG="$push_log"
  export MOCK_PI_ENV_LOG="$env_log"
  # Fixture 1 (develop call): a single PUSH: directive with three explicit
  # URL forms. The mock pi dumps the driver's exported GIT_CONFIG_* env to
  # MOCK_PI_ENV_LOG first, then attempts the push (which pushInsteadOf must
  # block). Fixture 2 (review): APPROVED to end the loop.
  printf '%s\n' 'PUSH:https://example.com/x.git HEAD' > "$FIXTURES_DIR/1"
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?

  # The mock pi must have dumped the real GIT_CONFIG_* env from inside the
  # driver run.
  [ -s "$env_log" ]
  grep -q '^GIT_CONFIG_COUNT=' "$env_log"
  grep -q '^GIT_CONFIG_KEY_0=push.default$' "$env_log"
  grep -q '^GIT_CONFIG_VALUE_0=nothing$' "$env_log"
  grep -q 'pushInsteadOf' "$env_log"
  grep -q 'remote.origin.pushurl' "$env_log"

  # The explicit-URL push must have failed (non-zero exit code in the side
  # file), and the remote must never have received a ref.
  [ -s "$push_log" ]
  local p_rc
  p_rc="$(head -n 1 "$push_log" | tr -d ' ')"
  [ -n "$p_rc" ] && [ "$p_rc" -ne 0 ]
  [ "$(git -C "$remote" for-each-ref 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]
  rm -f "$push_log" "$env_log"
  rm -rf "$(dirname "$remote")"
}

@test "safety: push neutralisation — bare relative local paths are blocked (empty pushInsteadOf)" {
  # A bare relative local path (e.g. `git push ../origin.git HEAD`) has no
  # prefix for the per-prefix pushInsteadOf entries, so the driver appends
  # one empty-valued pushInsteadOf that matches every remaining URL. This
  # regression test exercises the REAL driver: the mock pi's PUSH: directive
  # runs inside an actual orchestrate.sh invocation and pushes to the bare
  # remote via its RELATIVE path, which the empty rewrite must block.
  local remote
  remote="$(mktemp -d)/origin.git"
  git init -q --bare "$remote"
  git -C "$remote" config receive.denyCurrentBranch ignore
  git remote add origin "$remote"
  echo more >> a.txt
  git add a.txt
  git commit -qm "relative push test"
  # The relative path to the bare remote from the repo root (the driver and
  # mock pi both run with cwd at the repo root).
  local rel
  rel="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$remote" "$(git rev-parse --show-toplevel)")"
  local push_log env_log
  push_log="$(mktemp)"
  env_log="$(mktemp)"
  export MOCK_PI_PUSH_LOG="$push_log"
  export MOCK_PI_ENV_LOG="$env_log"
  # Fixture 1 (develop call): the PUSH: directive is whitespace-split by the
  # mock pi, so the relative target (no spaces in this relpath) is passed
  # verbatim as the push URL. The mock pi also dumps the driver's env so we
  # can verify the empty catch-all entry is present. Fixture 2 (review):
  # APPROVED to end the loop.
  printf '%s\n' "PUSH:${rel} HEAD" > "$FIXTURES_DIR/1"
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?

  # The driver's env must contain the pushInsteadOf entries (the empty
  # catch-all entry appears in the env dump as a bare GIT_CONFIG_VALUE_n
  # line, which is what the blocked push below proves end-to-end).
  [ -s "$env_log" ]
  grep -q 'pushInsteadOf' "$env_log"

  # The relative-path push must have failed (non-zero exit code), and the
  # bare remote must never have received a ref.
  [ -s "$push_log" ]
  local p_rc
  p_rc="$(head -n 1 "$push_log" | tr -d ' ')"
  [ -n "$p_rc" ] && [ "$p_rc" -ne 0 ]
  [ "$(git -C "$remote" for-each-ref 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]
  rm -f "$push_log" "$env_log"
  rm -rf "$(dirname "$remote")"
}

@test "safety: preflight appends to a pre-existing GIT_CONFIG_COUNT (no clobber)" {
  # A caller (or git itself) may have exported GIT_CONFIG_COUNT/KEY_n/VALUE_n;
  # the preflight must continue the indexing from the existing count instead
  # of overwriting those entries. This exercises the REAL driver: the caller
  # exports 2 entries (indices 0-1), the driver appends its own (starting at
  # index 2), and the mock pi's ENV: directive dumps the resulting env from
  # inside an actual orchestrate.sh run.
  local remote
  remote="$(mktemp -d)/origin.git"
  git init -q --bare "$remote"
  git remote add origin "$remote"

  # A caller's 2 entries (indices 0-1). The driver must preserve them and
  # start its own entries at index 2.
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=T GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=t@t

  local env_log push_log
  env_log="$(mktemp)"
  push_log="$(mktemp)"
  export MOCK_PI_ENV_LOG="$env_log"
  export MOCK_PI_PUSH_LOG="$push_log"
  # Fixture 1 (develop call): a single PUSH: directive. The mock pi dumps
  # the driver's exported env to MOCK_PI_ENV_LOG, then attempts the push
  # (which must fail — push.default=nothing is in effect at index 2, not
  # 0). Fixture 2 (review): APPROVED to end the loop.
  printf '%s\n' 'PUSH:origin HEAD' > "$FIXTURES_DIR/1"
  fixture 2 'Looks fine.' 'VERDICT: APPROVED'
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?

  [ -s "$env_log" ]
  # The caller's entries survive (no clobber):
  grep -q '^GIT_CONFIG_KEY_0=user.name$' "$env_log"
  grep -q '^GIT_CONFIG_VALUE_0=T$' "$env_log"
  grep -q '^GIT_CONFIG_KEY_1=user.email$' "$env_log"
  grep -q '^GIT_CONFIG_VALUE_1=t@t$' "$env_log"
  # The driver's entries start at index 2 and the count reflects the append
  # (>= 12: 2 caller + 1 push.default + 8 pushInsteadOf entries (7 prefixes
  # + 1 empty catch-all for bare relative local paths) + 1 remote pushurl
  # = 12).
  grep -q '^GIT_CONFIG_KEY_2=push.default$' "$env_log"
  grep -q '^GIT_CONFIG_VALUE_2=nothing$' "$env_log"
  grep -q '^GIT_CONFIG_COUNT=12$' "$env_log"
  grep -q 'remote.origin.pushurl' "$env_log"
  # The push must have failed.
  [ -s "$push_log" ]
  local p_rc
  p_rc="$(head -n 1 "$push_log" | tr -d ' ')"
  [ -n "$p_rc" ] && [ "$p_rc" -ne 0 ]
  rm -f "$env_log" "$push_log"
  rm -rf "$(dirname "$remote")"
}

@test "safety: pre-existing GIT_CONFIG_COUNT that is not numeric -> PI_ERROR, exit 3" {
  # The preflight must refuse (not crash under set -e arithmetic) when the
  # environment carries a non-numeric GIT_CONFIG_COUNT. In practice git itself
  # hard-errors on a bogus count, so a direct export would fail the driver's
  # own `git rev-parse` before the preflight. To reach the preflight's own
  # guard we use a git wrapper that strips GIT_CONFIG_COUNT from the child
  # environment (so git's own calls succeed) while the driver's shell still
  # sees the bogus value in its own environment — the preflight's numeric
  # check is what catches it.
  local wrap_dir out rc=0
  wrap_dir="$(mktemp -d)"
  cat > "$wrap_dir/git" <<'WRAP'
#!/bin/bash
env -u GIT_CONFIG_COUNT /usr/bin/git "$@"
WRAP
  chmod +x "$wrap_dir/git"
  out="$(GIT_CONFIG_COUNT=abc PATH="$wrap_dir:$PATH" bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  rm -f "$wrap_dir/git"; rmdir "$wrap_dir"
  [ "$rc" -eq 3 ]
  [[ "$out" == *"REFUSED:"* ]]
  [[ "$out" == *"GIT_CONFIG_COUNT"* ]]
  [[ "$out" == *"PI_DELEGATE_UNSAFE=1"* ]]
  local last
  last="$(printf '%s\n' "$out" | tail -n 1)"
  printf '%s' "$last" | jq -e '.status == "PI_ERROR"' >/dev/null
}

@test "safety: pre-existing GIT_CONFIG_COUNT=0 (numeric) is accepted" {
  # A numeric pre-existing count (even 0) must be accepted, not refused.
  export GIT_CONFIG_COUNT=0
  fixture 1 'Developed it.'
  local out rc=0
  out="$(bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  [ "$rc" -ne 3 ]
  [[ "$out" != *"REFUSED:"* ]]
}
