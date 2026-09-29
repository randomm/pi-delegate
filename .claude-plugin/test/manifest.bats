#!/usr/bin/env bats
# Manifest-validation tests for .claude-plugin/marketplace.json and
# .claude-plugin/plugin.json (issue #44).
#
# The real manifests ARE the fixtures: these tests assert both files exist,
# parse as JSON, and carry the contract Claude Code needs
# (marketplace: name / owner.name / plugins[] each with name + source;
# plugin: name matching the marketplace entry). They also pin the
# no-`version`-field rule — a relative-path source ("./") updates by commit
# SHA, and a version pin would block auto-updates.
#
# This suite replaces the CI jq step (per the PM decision on #44,
# .github/workflows is a protected path and the existing CI already runs
# every *.bats file via `find . -name '*.bats'`). jq is required on the
# runner; the existing BATS suites already use it.
#
# No claude CLI needed: jq alone validates JSON structure. The one-off
# manual install check (marketplace add + install from a local clone) is
# recorded in the PR.

setup() {
  # Resolve files relative to the repo root (this file lives at
  # .claude-plugin/test/) so the suite works from any cwd. Relative plugin
  # sources are resolved from the marketplace root = repo root.
  local test_dir
  test_dir=$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)
  REPO_ROOT="$(cd "$test_dir/../.." && pwd)"
  MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
  PLUGIN="$REPO_ROOT/.claude-plugin/plugin.json"
  command -v jq >/dev/null 2>&1 || { echo "setup: jq is required but not on PATH" >&2; return 1; }
}

# --- Existence guards (fail loudly if a manifest is ever deleted) ---

@test "marketplace.json exists and is valid JSON" {
  [ -f "$MARKETPLACE" ]
  jq -e . "$MARKETPLACE" >/dev/null
}

@test "plugin.json exists and is valid JSON" {
  [ -f "$PLUGIN" ]
  jq -e . "$PLUGIN" >/dev/null
}

# --- marketplace.json required keys ---

@test "marketplace.json has a non-empty top-level name" {
  # Reject missing/null/non-string names: (null|type) is "null", so a
  # missing key or non-string value fails the type check, and the empty
  # string fails the second clause.
  jq -e '(.name | type) == "string" and .name != ""' "$MARKETPLACE" >/dev/null
}

# The name check must also REJECT bad manifests — the real file can only
# prove the positive path, so use temp fixtures (one per case).
_mk_name_fixture() {
  jq '.name = '$1'' "$MARKETPLACE" > "$BATS_TEST_TMPDIR/marketplace.json"
}

@test "marketplace name check rejects a missing or null name" {
  # A missing key is dropped; an explicit null sets null — both must fail.
  _mk_name_fixture 'null'
  ! jq -e '(.name | type) == "string" and .name != ""' "$BATS_TEST_TMPDIR/marketplace.json" >/dev/null
  jq 'del(.name)' "$BATS_TEST_TMPDIR/marketplace.json" > "$BATS_TEST_TMPDIR/marketplace-missing.json"
  ! jq -e '(.name | type) == "string" and .name != ""' "$BATS_TEST_TMPDIR/marketplace-missing.json" >/dev/null
}

@test "marketplace name check rejects a non-string name" {
  _mk_name_fixture '42'
  ! jq -e '(.name | type) == "string" and .name != ""' "$BATS_TEST_TMPDIR/marketplace.json" >/dev/null
}

@test "marketplace name check rejects an empty-string name" {
  _mk_name_fixture '""'
  ! jq -e '(.name | type) == "string" and .name != ""' "$BATS_TEST_TMPDIR/marketplace.json" >/dev/null
}

@test "marketplace name check accepts a valid non-empty string name" {
  _mk_name_fixture '"pi-delegate"'
  jq -e '(.name | type) == "string" and .name != ""' "$BATS_TEST_TMPDIR/marketplace.json" >/dev/null
}

@test "marketplace.json has owner.name (non-empty)" {
  [ "$(jq -r '.owner.name // empty' "$MARKETPLACE")" != "" ]
}

@test "marketplace.json has a non-empty plugins array" {
  [ "$(jq '.plugins | type' "$MARKETPLACE")" = '"array"' ]
  [ "$(jq '.plugins | length' "$MARKETPLACE")" -ge 1 ]
}

@test "marketplace.json: every plugin entry has name and source" {
  local count bad
  count=$(jq '.plugins | length' "$MARKETPLACE")
  bad=$(jq '[.plugins[] | select((.name|type) != "string" or .name == "" or (.source|type) != "string" or .source == "")] | length' "$MARKETPLACE")
  [ "$bad" = "0" ]
  [ "$count" -ge 1 ]
}

@test "marketplace.json: plugins[0].source is the same-repo './'" {
  [ "$(jq -r '.plugins[0].source' "$MARKETPLACE")" = "./" ]
}

@test "marketplace.json: every plugin source is a safe relative path and its dir exists" {
  # A relative source must be plain: no ".." escapes, no absolute paths, no
  # URL schemes. It must point at a real directory in the repo that contains
  # the plugin's skills (the whole point of the marketplace entry).
  local n src
  n=$(jq '.plugins | length' "$MARKETPLACE")
  for ((i = 0; i < n; i++)); do
    src=$(jq -r ".plugins[$i].source" "$MARKETPLACE")
    case "$src" in
      *".."*|/*|*"://"*) false ;;
    esac
    # A relative source ("./") resolves from the marketplace root (repo root).
    # cd into it instead of [ -d ] on the joined string: "./" after trailing-/
    # normalization is the one form a bare [ -d ] on the joined path string
    # cannot express portably.
    ( cd "$REPO_ROOT" && cd "$src" && cd "skills" )
  done
}

@test "marketplace.json: name is not in the reserved set" {
  # npm, pip, uv, cargo, github, gh are reserved marketplace names in any
  # casing (Claude Code marketplace-reference, "Reserved names").
  local lname
  lname=$(printf '%s' "$(jq -r '.name' "$MARKETPLACE")" | tr '[:upper:]' '[:lower:]')
  case "$lname" in
    npm|pip|uv|cargo|github|gh) false ;;
  esac
  true
}

@test "marketplace.json carries no version key anywhere" {
  # A version field would block commit-SHA-based updates for a relative
  # source — none at the top level, none on any plugin entry.
  [ "$(jq 'has("version")' "$MARKETPLACE")" = "false" ]
  [ "$(jq '[.plugins[] | select(has("version"))] | length' "$MARKETPLACE")" = "0" ]
}

# --- plugin.json required keys ---

@test "plugin.json has a non-empty name" {
  [ "$(jq -r '.name // empty' "$PLUGIN")" != "" ]
}

@test "plugin.json carries no version key" {
  [ "$(jq 'has("version")' "$PLUGIN")" = "false" ]
}

# --- Cross-file consistency ---

@test "plugin name equals the marketplace's plugins[0].name" {
  [ "$(jq -r '.name' "$PLUGIN")" = "$(jq -r '.plugins[0].name' "$MARKETPLACE")" ]
}

@test "the install target is pi-delegate@pi-delegate" {
  # The documented install command is `claude plugin install pi-delegate@pi-delegate`;
  # pin both halves so a rename in either manifest breaks the suite.
  [ "$(jq -r '.name' "$MARKETPLACE")" = "pi-delegate" ]
  [ "$(jq -r '.name' "$PLUGIN")" = "pi-delegate" ]
}
