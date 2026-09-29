#!/usr/bin/env bash
# setup-run.sh — fresh clone at BASE_SHA into a run directory, feature branch,
# push disabled. Part of the benchmark harness (docs/benchmark.md §setup).
#
# Usage:
#   bench/setup-run.sh <task-id> <arm> <run#>
#
# Environment:
#   BENCH_OUT   Output root (default: /tmp/pi-bench). Must be OUTSIDE any
#               git repo — the clone is disposable and all run captures
#               (pi logs, claude json, etc.) land here.
#
# Output layout:
#   $BENCH_OUT/<task>/<arm>/<run>/
#     repo/          fresh clone at BASE_SHA, on branch bench/<arm>/<run#>
#     setup.json     setup metadata (written by this script)
#     claude/        (created by run-arm.sh)
#     pi-*           (created by the pi shim / run-arm.sh)
#
# Exit codes:
#   0  success
#   1  task not found / missing task.env fields
#   2  clone or checkout failed
#   3  secret-file scan found .env/*.pem/*.key in the clone (refuse to run)
#
# Safety:
#   - The clone's push URL is disabled (push.default=nothing + an explicit
#     pushurl rewrite on the origin remote) so neither arm can push.
#     (pushInsteadOf rewrite keys like `url.https://.pushInsteadOf` are
#     rejected by git; the explicit pushurl is sufficient.)
#   - A secret-file scan (.env, .env.*, *.pem, *.key) runs before setup
#     completes; if any are present the script refuses (exit 3). This
#     mirrors the safety preflight in skills/pi-oneshot/SKILL.md.

set -euo pipefail
# shellcheck disable=SC2034  # SCRIPT_DIR is used by lib.sh source path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

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
# After require_task_fields, REPO, BASE_SHA, FIX_COMMIT, TEST_CMD are set.

run_dir="$(arm_run_dir "$task_id" "$arm" "$run_num")"
repo_dir="$run_dir/repo"

# --- Remove any prior run directory (idempotent re-run) ---------------------
if [ -e "$repo_dir" ]; then
  echo "setup-run: $repo_dir exists — removing for a fresh clone" >&2
  rm -rf "$repo_dir"
fi

# --- Clone at BASE_SHA -------------------------------------------------------
# A full clone is used (not a shallow one) so that `git log` works if an
# agent needs it, and the working tree is checked out at BASE_SHA.
echo "setup-run: cloning $REPO at $BASE_SHA → $repo_dir" >&2
if ! git clone -q "$REPO" "$repo_dir" 2>"$run_dir/clone-err.log"; then
  echo "setup-run: git clone failed; see $run_dir/clone-err.log" >&2
  exit 2
fi

cd "$repo_dir"
if ! git checkout -q -b "bench/${arm}/${run_num}" "$BASE_SHA" 2>>"$run_dir/clone-err.log"; then
  echo "setup-run: git checkout $BASE_SHA failed; see $run_dir/clone-err.log" >&2
  exit 2
fi

# --- Push disabled -----------------------------------------------------------
# push.default=nothing: `git push` with no args pushes nothing.
# An explicit pushurl on the origin remote (rewritten to a dead URL) means
# `git push origin <anything>` also fails. (A pushInsteadOf rewrite would be
# stronger, but git rejects keys of the form `url.<value>.pushInsteadOf`
# where <value> contains `//`; the explicit pushurl is sufficient here.)
git config push.default nothing
# Belt and braces: explicit pushurl on the origin remote (this alone
# prevents `git push` from reaching the real origin URL).
git config remote.origin.pushurl pi-delegate-push-disabled://dead

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

# --- Record setup metadata ----------------------------------------------------
setup_sha="$(git rev-parse HEAD)"
branch_name="$(git symbolic-ref --short HEAD)"

jq -cn \
  --arg task "$task_id" \
  --arg arm "$arm" \
  --argjson run "$run_num" \
  --arg repo "$REPO" \
  --arg base_sha "$BASE_SHA" \
  --arg fix_commit "$FIX_COMMIT" \
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
