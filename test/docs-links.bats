#!/usr/bin/env bats
# Relative-link checker (issue #45): every relative markdown link in
# README.md and docs/*.md must resolve to an existing in-tree file (images
# included). External URLs (http://, https://, mailto: and other schemes),
# absolute paths, and pure in-page anchors are skipped by design.
#
# Anchor handling (issue #45 review): the `#fragment` is stripped BEFORE
# classification, so `file.md#anchor` links validate their file part; only
# pure in-page anchors (`#...` with no file part) are skipped. The anchor
# slug itself is not resolved (GitHub's slugification is not emulated).

setup() {
  local test_dir root
  test_dir=$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)
  root=$(cd "$test_dir/.." && pwd)
  REPO_ROOT="$root"
  [ -f "$REPO_ROOT/README.md" ] || { echo "setup: missing README.md" >&2; return 1; }
}

check_file_links() {
  # $1 = path to a markdown file, relative to the repo root
  local rel="$1"
  local base_dir line stripped
  base_dir="$REPO_ROOT/$(dirname "$rel")"
  while IFS= read -r line; do
    # $line is the raw match: `path` or `path#frag` (with the `](` prefix
    # already stripped by the producer sed) plus the trailing `)`.
    # Strip the trailing `)` first, then strip any in-page anchor fragment,
    # so `file.md#anchor` links are validated by their file part.
    stripped="$(printf '%s' "$line" | sed -E 's/\)$//; s/#.*//')"
    [ -n "$stripped" ] || continue  # pure in-page anchor (`#...`) — skip
    case "$stripped" in
      http:*|https:*|mailto:*|/*) continue ;;  # external / absolute — skip
    esac
    [ -e "$base_dir/$stripped" ] || { echo "BROKEN: $rel -> $line"; return 1; }
  done < <(grep -Eo '\]\([^)]+\)' "$REPO_ROOT/$rel" | sed -E 's/^\]\(//')
  return 0
}

@test "all relative links in README.md resolve to existing files" {
  check_file_links "README.md"
}

@test "all relative links in docs/*.md resolve to existing files (images included)" {
  local f rc=0
  for f in "$REPO_ROOT"/docs/*.md; do
    check_file_links "docs/$(basename "$f")" || rc=1
  done
  [ "$rc" -eq 0 ]
}
