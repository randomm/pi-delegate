#!/usr/bin/env bash
# setup-run.sh — fetch ONLY BASE_SHA into a run directory (no full clone),
# create the feature branch, disable push, run the task's SETUP_CMD, and
# write setup.json. Part of the benchmark harness
# (docs/benchmark.md §setup, §contamination-guard, §safe-execution).
#
# Usage:
#   bench/setup-run.sh <task-id> <arm> <run#>
#
# Environment:
#   BENCH_OUT   Output root (default: /tmp/pi-bench). Must be OUTSIDE any
#               git repo — the fetched tree is disposable and all run
#               captures (pi logs, claude json, etc.) land here.
#
# Output layout:
#   $BENCH_OUT/<task>/<arm>/<run>/
#     repo/          repo containing ONLY the BASE_SHA commit: no refs,
#                    no tags, no other reachable commits (contamination
#                    guard), on branch bench/<arm>/<run#>
#     setup.json     setup metadata (written by this script)
#     setup-cmd.log  SETUP_CMD stdout/stderr
#     claude/        (created by run-arm.sh)
#     pi-*           (created by the pi shim / run-arm.sh)
#
# Exit codes:
#   0  success
#   1  task not found / missing task.env fields
#   2  fetch or checkout failed, contamination guard failed, or SETUP_CMD failed
#   3  secret-file scan found .env/*.pem/*.key in the tree (refuse to run)
#
# Safety:
#   - Contamination guard (docs/benchmark.md §contamination-guard): the run
#     repo is built with `git init` + `git fetch --depth=1 <REPO>
#     <BASE_SHA>` and NOTHING else is fetched. No refs, no tags, no remote
#     left behind. The FIX_SHA commit object never exists in the run repo,
#     so `git log` can only ever show the single BASE commit — the agent
#     cannot discover the historical fix by inspecting git history.
#   - Safe execution (docs/benchmark.md §safe-execution): every git/uv/
#     pytest command is wrapped in `timeout` and runs with
#     GIT_TERMINAL_PROMPT=0 EDITOR=true VISUAL=true PAGER=cat GIT_PAGER=cat
#     so nothing can hang on a credential prompt, an editor, or a pager.
#   - The push URL is disabled (push.default=nothing; no remote remains)
#     so neither arm can push.
#   - A secret-file scan (.env, .env.*, *.pem, *.key) runs before setup
#     completes; if any are present the script refuses (exit 3). This
#     mirrors the safety preflight in skills/pi-oneshot/SKILL.md.

set -euo pipefail
# shellcheck disable=SC2034  # SCRIPT_DIR is used by lib.sh source path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Safe-execution env (docs/benchmark.md §safe-execution): no credential
# prompts, no editor (would hang with no TTY), no pager.
export GIT_TERMINAL_PROMPT=0 EDITOR=true VISUAL=true PAGER=cat GIT_PAGER=cat

usage() {
  echo "Usage: $0 <task-id> <arm> <run#>" >&2
  echo "  task-id  name of a task under $TASKS_DIR" >&2
  echo "  arm      A | B" >&2
  echo "  run#     positive integer (1-based)" >&2
  exit 1
}

[ "${#}" -eq 3 ] || usage
task_id="$1"
arm="$2"
run_num="$3"

case "$arm" in
  A|B) ;;
  *) echo "arm must be A or B (got '$arm')" >&2; exit 1 ;;
esac
if ! [[ "$run_num" =~ ^[0-9]+$ ]] || [ "$run_num" -lt 1 ]; then
  echo "run# must be a positive integer (got '$run_num')" >&2
  exit 1
fi

# --- Load task definition ---------------------------------------------------
require_task_fields "$task_id" || exit 1
# After require_task_fields, REPO, BASE_SHA, FIX_COMMIT (or FIX_SHA),
# TEST_CMD are set. SETUP_CMD is optional (not required for the harness).

run_dir="$(arm_run_dir "$task_id" "$arm" "$run_num")"
repo_dir="$run_dir/repo"

# --- Remove any prior run directory (idempotent re-run) ---------------------
if [ -e "$repo_dir" ]; then
  echo "setup-run: $repo_dir exists — removing for a fresh fetch" >&2
  rm -rf "$repo_dir"
fi

# --- Fetch ONLY BASE_SHA (contamination guard) -------------------------------
# Instead of `git clone` (which would pull every branch, tag, and commit),
# build the repo with `git init` + `git fetch --depth=1 <REPO> <BASE_SHA>`:
# the run repo's object database contains exactly one commit (BASE_SHA) and
# its trees/blobs. No refs, no tags, no other commits. The FIX_SHA commit
# object never enters this repo, so the agent cannot inspect git history to
# find the historical fix. (docs/benchmark.md §contamination-guard)
echo "setup-run: fetching $REPO at $BASE_SHA → $repo_dir" >&2
if ! git init -q -b "bench/${arm}/${run_num}" "$repo_dir" 2>"$run_dir/fetch-err.log"; then
  echo "setup-run: git init failed; see $run_dir/fetch-err.log" >&2
  exit 2
fi
if ! timeout 300 git -C "$repo_dir" fetch -q --depth=1 "$REPO" "$BASE_SHA" 2>>"$run_dir/fetch-err.log"; then
  echo "setup-run: git fetch $BASE_SHA failed; see $run_dir/fetch-err.log" >&2
  exit 2
fi
# Belt and braces: `git fetch <url> <sha>` should not persist a remote, but
# if one leaked in (e.g. via a git config override), remove it so the agent
# cannot re-fetch.
if timeout 30 git -C "$repo_dir" remote 2>/dev/null | grep -q .; then
  git -C "$repo_dir" remote remove origin 2>/dev/null || true
fi
if ! timeout 120 git -C "$repo_dir" checkout -q -b "bench/${arm}/${run_num}" FETCH_HEAD 2>>"$run_dir/fetch-err.log"; then
  echo "setup-run: git checkout $BASE_SHA failed; see $run_dir/fetch-err.log" >&2
  exit 2
fi

# --- Contamination guard (verify) -------------------------------------------
# Exactly one commit may be reachable after the fetch. If more leaked in,
# fail loudly rather than silently contaminating the run.
commit_count="$(timeout 30 git -C "$repo_dir" rev-list --count HEAD 2>/dev/null)" || commit_count="?"
if [ "$commit_count" != "1" ]; then
  echo "setup-run: CONTAMINATION GUARD FAILED — expected 1 commit, got '$commit_count'" >&2
  exit 2
fi
# No remote may remain after the one-shot fetch (final check).
if timeout 30 git -C "$repo_dir" remote 2>/dev/null | grep -q .; then
  echo "setup-run: CONTAMINATION GUARD FAILED — remote(s) remain after fetch" >&2
  exit 2
fi

# --- Push disabled -----------------------------------------------------------
# push.default=nothing: `git push` with no args pushes nothing. No remote
# is configured, so `git push <remote>` has nothing to reach anyway.
git -C "$repo_dir" config push.default nothing
# Belt and braces: explicit dead pushurl (no remote exists, but the config
# key is harmless and satisfies any push-URL inspection).
git -C "$repo_dir" config remote.origin.pushurl pi-delegate-push-disabled://dead

# --- Secret-file scan ---------------------------------------------------------
# Mirrors the safety preflight: refuse if .env, .env.*, *.pem, or *.key
# is present anywhere in the tree (regular files or symlinks).
# Fail-closed: any non-zero find exit is a refusal.
scan_err_file="$run_dir/secret-scan-err.tmp"
scan_file="$run_dir/secret-scan.tmp"
if ! find "$repo_dir" -not -path "$repo_dir/.git" -not -path "$repo_dir/.git/*" \
    \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \) \
    \( -type f -o -type l \) > "$scan_file" 2> "$scan_err_file"; then
  echo "setup-run: secret-file scan failed: $(cat "$scan_err_file")" >&2
  rm -f "$scan_err_file" "$scan_file"
  exit 3
fi
secrets_found=""
shown=0
while IFS= read -r sf; do
  sf="${sf#"$repo_dir"/}"
  case "$sf" in *.example|*.sample|*.template) continue ;; esac
  if [ -z "$secrets_found" ]; then secrets_found="$sf"; else secrets_found="$secrets_found, $sf"; fi
  shown=$((shown + 1))
  [ "$shown" -ge 5 ] && break
done < "$scan_file"
rm -f "$scan_file"
if [ -n "$secrets_found" ]; then
  echo "setup-run: REFUSED — secret-looking file(s) in clone: $secrets_found" >&2
  exit 3
fi

# --- Run the task's SETUP_CMD (venv + deps) -----------------------------------
# SETUP_CMD is run in the repo directory (so `$PWD`-relative paths in the
# command resolve against the run repo). Bounded by timeout 600; safe-env
# is already exported above.
if [ -n "${SETUP_CMD:-}" ]; then
  echo "setup-run: running SETUP_CMD in $repo_dir" >&2
  setup_log="$run_dir/setup-cmd.log"
  ( cd "$repo_dir" && timeout 600 bash -c "$SETUP_CMD" ) > "$setup_log" 2>&1
  setup_rc=$?
  if [ "$setup_rc" -ne 0 ]; then
    echo "setup-run: SETUP_CMD failed (exit $setup_rc); see $setup_log" >&2
    exit 2
  fi
  echo "setup-run: SETUP_CMD OK" >&2
fi

# --- Record setup metadata ----------------------------------------------------
setup_sha="$(timeout 30 git -C "$repo_dir" rev-parse HEAD)"
branch_name="$(timeout 30 git -C "$repo_dir" symbolic-ref --short HEAD)"

jq -cn \
  --arg task "$task_id" \
  --arg arm "$arm" \
  --argjson run "$run_num" \
  --arg repo "$REPO" \
  --arg base_sha "$BASE_SHA" \
  --arg fix_commit "${FIX_SHA:-${FIX_COMMIT:-}}" \
  --arg test_cmd "$TEST_CMD" \
  --arg clone_sha "$setup_sha" \
  --arg branch "$branch_name" \
  --arg run_dir "$run_dir" \
  --arg setup_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{task:$task, arm:$arm, run:$run, repo:$repo, base_sha:$base_sha,
    fix_commit:$fix_commit, test_cmd:$test_cmd, clone_sha:$clone_sha,
    branch:$branch, run_dir:$run_dir, setup_at:$setup_at}' \
  > "$run_dir/setup.json"

echo "setup-run: OK  task=$task_id arm=$arm run=$run_num branch=$branch_name" >&2
echo "$run_dir"
