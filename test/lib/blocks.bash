#!/usr/bin/env bash
# Shared extraction helpers for the skill doc-drift BATS suites.
#
# Sourced by:
#   skills/pi-review-loop/test/orchestrate.bats
#   skills/pi-oneshot/test/pi-oneshot.bats
#
# Both suites need the same two shapes: (1) the text of a section of a
# markdown file (from one heading/anchor to the next heading of the same
# level or higher), and (2) the Nth ```bash fenced block within it. These
# helpers centralise the awk pipelines so a change to one file's layout
# surfaces in ONE place, and so the two suites can't drift apart.
#
# strip_heredoc_wrapper <text-stdin>
#   The skill blocks are wrapped for the Claude Code Bash tool in a quoted
#   `bash <<'PI_DELEGATE_BLOCK'` heredoc (the caller's shell may be zsh,
#   which cannot run bash-specific blocks such as `set -m`). For
#   extraction, lint (bash -n / shellcheck) and functional tests the wrapper
#   lines are noise, so they are stripped here: the `bash <<...` opening
#   line, the closing delimiter line, and any line that merely quotes a
#   task file (`$(cat <...>)`) that the wrapper made possible — the
#   functional tests substitute their own task text or files.
strip_heredoc_wrapper() {
  # The wrapper lines themselves are dropped. Inside the wrapper, a line
  # that reads the task file (`$(cat <the task file from the call above>)`)
  # is caller-supplied content (substituted literally at use time): it is
  # rewritten to `$(cat "$TASK_FILE")` — an anchored, exact-literal match,
  # never a greedy pattern — which is valid bash in its own right and what
  # the functional tests substitute their own file into.
  awk '
    /^bash <<[^ ]*$/ { inblk = 1; next }
    inblk && /^PI_DELEGATE_[A-Z]+$/ { inblk = 0; next }
    inblk && /\$\(cat / { gsub(/\$\(cat <the task file from the call above>\)/, "$(cat \"$TASK_FILE\")"); print; next }
    { print }
  '
}

# section_block_prefix <file> <prefix> <n>
#   Like section_block but the anchor is a line PREFIX (index() match),
#   so callers avoid full-line quoting issues (backticks in the anchor).
#   The prefix must be unique within the file.
section_block_prefix() {
  local file="$1" prefix="$2" n="${3:-1}" out
  out="$(awk -v a="$prefix" -v n="$n" '
    index($0, a) > 0 { s = 1; next }
    s && /^##(#[^#]|[^# ])/ { s = 0 }
    s && /^```bash$/ { c++; f = (c == n); next }
    s && f && /^```$/ { f = 0 }
    s && f { print }
  ' "$file" | strip_heredoc_wrapper)"
  [ -n "$out" ] || {
    echo "section_block_prefix: no \`\`\`bash block #$n after prefix '$prefix' in $file" >&2
    return 1
  }
  printf '%s\n' "$out"
  return 0
}

# section_block <file> <anchor> <n>
#   Print the text of the <n>th (default 1) ```bash fenced block inside the
#   section anchored at <anchor>. <anchor> is the FULL line that marks the
#   start of the section (e.g. "## Invocation" or "### Long runs under ...").
#   The section ends at the next line that starts with "##" or "###" (any
#   heading of the same level or higher). The anchor line itself is skipped.
#   The bash heredoc wrapper lines are stripped (see strip_heredoc_wrapper)
#   so the extracted block is the executable body. Returns 0 and prints the
#   block on success; returns 1 (with a message on stderr) when the anchor
#   is not found or the requested block is missing — a doc-drift failure,
#   not a silent empty result.
section_block() {
  local file="$1" anchor="$2" n="${3:-1}" out
  out="$(awk -v a="$anchor" -v n="$n" '
    $0 == a { s = 1; next }
    s && /^##(#[^#]|[^# ])/ { s = 0 }
    s && /^```bash$/ { c++; f = (c == n); next }
    s && f && /^```$/ { f = 0 }
    s && f { print }
  ' "$file" | strip_heredoc_wrapper)"
  [ -n "$out" ] || {
    echo "section_block: no \`\`\`bash block #$n found after anchor '$anchor' in $file" >&2
    return 1
  }
  printf '%s\n' "$out"
  return 0
}

# section_text <file> <anchor>
#   Print the prose of the section anchored at <anchor> (no fenced-block
#   filter). Returns 1 when the anchor is not found.
section_text() {
  local file="$1" anchor="$2" out
  out="$(awk -v a="$anchor" '
    $0 == a { s = 1; next }
    s && /^##(#[^#]|[^# ])/ { s = 0 }
    s { print }
  ' "$file")"
  [ -n "$out" ] || {
    echo "section_text: anchor '$anchor' not found (or section empty) in $file" >&2
    return 1
  }
  printf '%s\n' "$out"
  return 0
}
