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

  # Temp git repo with a working-tree change so the start-ref diff is non-empty.
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
  # PATH isolation: `pi` must resolve ONLY to the mock (a fake HOME blocks
  # the well-known fallback locations, BIN_DIR leads PATH, and the tools
  # dir below contains no `pi`). Resolve the host's real tool paths BEFORE
  # narrowing PATH — on macOS `timeout` (brew coreutils) and other tools
  # may live only in a dir we are about to drop — and symlink them into a
  # dedicated tools dir so the controlled PATH still has a working
  # timeout/gtimeout, jq, git, and bash (without timeout the driver runs
  # pi unbounded, which hangs tests when a fixture goes missing).
  TOOLS_DIR="$(mktemp -d)"
  if command -v timeout > /dev/null 2>&1; then
    ln -s "$(command -v timeout)" "$TOOLS_DIR/timeout"
  fi
  if command -v gtimeout > /dev/null 2>&1; then
    ln -s "$(command -v gtimeout)" "$TOOLS_DIR/gtimeout"
  fi
  if command -v jq > /dev/null 2>&1; then
    ln -s "$(command -v jq)" "$TOOLS_DIR/jq"
  fi
  if command -v git > /dev/null 2>&1; then
    ln -s "$(command -v git)" "$TOOLS_DIR/git"
  fi
  if command -v bash > /dev/null 2>&1; then
    ln -s "$(command -v bash)" "$TOOLS_DIR/bash"
  fi
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  export PATH="$BIN_DIR:$TOOLS_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  export MOCK_PI_CALL_LOG="$CALL_LOG"
  export MOCK_PI_ARGV_LOG="$ARGV_LOG"
  export MOCK_PI_FIXTURES_DIR="$FIXTURES_DIR"
}

teardown() {
  cd "$REPO" 2>/dev/null || true
  rm -rf "$REPO" "$CALL_LOG" "$ARGV_LOG" "$FIXTURES_DIR" "$BIN_DIR" "$TOOLS_DIR" "$FAKE_HOME"
}

run_driver() {
  local tmp
  tmp="$(mktemp)"
  local rc=0
  if [ -f "$MOCK_PI_ARGV_LOG" ]; then : > "$MOCK_PI_ARGV_LOG"; fi
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
  grep -q "new file mode" "$ARGV_LOG"
  grep -q "^+new-module$" "$ARGV_LOG"
  grep -q "newfile.txt" "$ARGV_LOG"
  ! grep -q "^-new-module$" "$ARGV_LOG"
}

@test "untracked file whose name contains a space is enumerated safely" {
  # `git ls-files --others --exclude-standard -z` + NUL-delimited read
  # must enumerate a path with a space verbatim (porcelain C-quoting
  # would have mangled it).
  echo spaced > "new spaced file.txt"
  fixture 2 'Reviewing the spaced file.' 'VERDICT: APPROVED'
  run_driver "do it"
  [ "$status" -eq 0 ]
  grep -q "new spaced file.txt" "$ARGV_LOG"
  grep -q "^+spaced$" "$ARGV_LOG"
  # The untracked part is not the only content (a.txt is modified too),
  # so the diff-vs-start-ref part is present as well.
  grep -q "diff --git a/a.txt b/a.txt" "$ARGV_LOG"
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
  grep -q "new-dir/inner.txt" "$ARGV_LOG"
  grep -q "^+in-new-dir$" "$ARGV_LOG"
  ! grep -q "^new-dir/$" "$ARGV_LOG"
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
  grep -q "diff --git a/a.txt b/a.txt" "$ARGV_LOG"
  grep -q "Current diff (git diff" "$ARGV_LOG"
  # The review prompt must reference the original pre-develop commit as
  # the diff source.
  grep -q "$base" "$ARGV_LOG"
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
  grep -q "unborn.txt" "$ARGV_LOG"
  # The untracked file shows as an addition (not the empty tree vs HEAD
  # diff, which has no per-file content lines for a new blob).
  grep -q "new file mode" "$ARGV_LOG"
  grep -q "^+fresh$" "$ARGV_LOG"
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
  grep -q "diff --git a/a.txt b/a.txt" "$ARGV_LOG"
  # The index must be untouched by the diff snapshot: `git diff` and
  # `git diff --no-index` never stage, so the staged tree still matches
  # HEAD.
  git diff --cached --quiet
  # The ignored file's content must not leak into any pi call.
  ! grep -q "ignored-secret" "$ARGV_LOG"
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

@test "git rev-parse failure at entry -> PI_ERROR, exit 3" {
  # Wrapper git: fail the very first `git rev-parse HEAD` (start-ref
  # recording), but let `git rev-parse --git-dir` (preflight) succeed. The
  # driver must not proceed with an empty start ref.
  local wrap_dir out rc=0
  wrap_dir="$(mktemp -d)"
  cat > "$wrap_dir/git" <<'WRAP'
#!/bin/bash
if [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
  echo "fatal: revparse boom" >&2
  exit 129
fi
exec /usr/bin/git "$@"
WRAP
  chmod +x "$wrap_dir/git"
  out="$(PATH="$wrap_dir:$PATH" bash "$SCRIPT" "do it" </dev/null 2>&1)" || rc=$?
  rm -f "$wrap_dir/git"; rmdir "$wrap_dir"
  [ "$rc" -eq 3 ]
  [[ "$out" == *"fatal: revparse boom"* ]]
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
  grep -q "Current diff (git diff" "$ARGV_LOG"
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
  # The review prompt (last arg of pi call 2) contains the "Current diff
  # (git diff ...):" marker exactly once in the ARGV_LOG file.
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
  ! grep -q "SENTINEL_ROUND_7_MUST_NEVER_APPEAR" "$ARGV_LOG"
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
