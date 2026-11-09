#!/usr/bin/env bats
# Escape probes for the Linux bwrap recipe in docs/configuration.md (issue
# #95). The recipe under test is EXTRACTED FROM THE DOC at run time — the
# doc's own claim is what gets checked, so rewriting the recipe in the doc
# turns these probes red instead of letting a fixture drift from it.
#
# A mock pi (no real pi, no network, no model spend) runs the probe list
# inside the wrapper. Assertions are made on the HOST, because with
# `--tmpfs "$HOME"` and `--tmpfs /tmp` an in-sandbox write "succeeds" and
# simply never lands: host-side absence is the checkable claim.
#
# Fixtures live under /var/tmp, NOT under /tmp or $HOME: the recipe masks
# both, so a fixture placed there would vanish and a probe would pass for
# the wrong reason.
#
# bwrap-dependent probes skip with a reason where the host cannot sandbox
# (bubblewrap not installed, or unprivileged user namespaces restricted).
# That is the accepted behaviour on the project's CI runner; skipping is
# never silently a pass of the claim itself.

setup() {
  local test_dir root
  test_dir=$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)
  root=$(cd "$test_dir/../../.." && pwd)
  DOC="$root/docs/configuration.md"
  RUN="$root/skills/delegate/run.sh"

  FIX="$(mktemp -d /var/tmp/pi-delegate-95.XXXXXX)"
  [ -n "$FIX" ] || { echo "setup: could not create the /var/tmp fixture dir" >&2; return 1; }
  BIN="$FIX/bin"
  CLONE="$FIX/clone"
  OTHER="$FIX/other"
  FAKEHOME="$FIX/home"
  mkdir -p "$BIN" "$CLONE" "$FAKEHOME/.ssh" "$FAKEHOME/.config/gh" \
    "$FAKEHOME/.pi/agent" "$FAKEHOME/.cache"

  # The Linux recipe is taken verbatim from the doc's fenced block (the one
  # after the **Linux** marker). Extraction failure leaves it empty, which
  # makes the anti-drift test red rather than quietly skipping.
  awk '
    /^\*\*Linux\*\*/ {f = 1}
    f && /^```sh$/  {inb = 1; next}
    inb && /^```$/  {exit}
    inb             {print}
  ' "$DOC" > "$FIX/sandbox"
  chmod +x "$FIX/sandbox"

  # Mock pi: records that it ran (inside the sandbox) and executes the
  # probe list named by PD_PROBE. Writes go to $PWD — the clone, the one
  # writable place the recipe binds — so the host can read them afterwards.
  cat > "$BIN/pi" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$PWD/.stub-argv"
cat > "$PWD/.stub-stdin"
if [ -n "$STUB_SETSID" ]; then
  # A bash-tool child that leaves the run's session: the timeout's group
  # kill cannot reach it, only the PI_DELEGATE_RUN reaper can.
  setsid sh -c "echo \$\$ > \"\$PWD/.stub-child\"; exec sleep 300" >/dev/null 2>&1 &
fi
[ -z "$PD_PROBE" ] || sh "$PD_PROBE"
echo "pi says done"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$BIN/pi"
  export PATH="$BIN:$PATH"

  # The delegated clone: feature branch, one commit, two remotes plus an
  # explicit-URL push target — all bare repos INSIDE the writable bind, so
  # only git-level neutralisation can block them (a read-only FS proving it
  # can block writes would assert nothing about push).
  git init -q -b feat "$CLONE"
  git -C "$CLONE" config user.email t@t.t
  git -C "$CLONE" config user.name t
  echo base > "$CLONE/a.txt"
  git -C "$CLONE" add a.txt
  git -C "$CLONE" commit -qm init
  git init -q --bare "$CLONE/upstream.git"
  git init -q --bare "$CLONE/second.git"
  git init -q --bare "$CLONE/url-target.git"
  git -C "$CLONE" remote add origin "$CLONE/upstream.git"
  git -C "$CLONE" remote add second "$CLONE/second.git"

  # The owner's main checkout the escaped pi walked into: a second git repo
  # outside the clone, read-only for the sandboxed pi.
  git init -q -b main "$OTHER"
  git -C "$OTHER" config user.email t@t.t
  git -C "$OTHER" config user.name t
  echo precious > "$OTHER/b.txt"
  git -C "$OTHER" add b.txt
  git -C "$OTHER" commit -qm init

  # Secrets the wrapper must hide. $HOME is pointed at this dir for the
  # sandboxed runs, so the real home is never touched.
  printf 'PROBE95SECRET-ssh\n' > "$FAKEHOME/.ssh/id_rsa"
  printf 'PROBE95SECRET-gh\n' > "$FAKEHOME/.config/gh/hosts.yml"
  printf 'PROBE95SECRET-creds\n' > "$FAKEHOME/.git-credentials"
  printf 'PROBE95SECRET-netrc\n' > "$FAKEHOME/.netrc"

  # Probe scripts: generated at runtime (no committed *.sh fixture for CI
  # to check, and none that could drift from the doc).
  cat > "$FIX/probe-lib.sh" <<'LIB'
res() { printf '%s=%s\n' "$1" "$2" >> "$PWD/.probe-results"; }
LIB
  cat > "$FIX/probe1.sh" <<'P1'
. "$PD_LIB"
echo leak > "$HOME/outside-home" 2>/dev/null; res write_home_rc "$?"
echo leak > "$PD_OTHER/outside-other" 2>/dev/null; res write_other_rc "$?"
echo leak > /etc/pi-delegate-probe95 2>/dev/null; res write_etc_rc "$?"
P1
  cat > "$FIX/probe2.sh" <<'P2'
. "$PD_LIB"
git -C "$PD_OTHER" checkout -b pi-delegate-escape >/dev/null 2>&1; res branch_rc "$?"
git -C "$PD_OTHER" -c user.email=t@t.t -c user.name=t commit --allow-empty -m escape >/dev/null 2>&1; res commit_rc "$?"
P2
  cat > "$FIX/probe3.sh" <<'P3'
. "$PD_LIB"
: > "$PWD/.probe-secrets"
for f in .ssh/id_rsa .config/gh/hosts.yml .git-credentials .netrc; do
  cat "$HOME/$f" >> "$PWD/.probe-secrets" 2>/dev/null || true
done
res secrets_probe_done ok
P3
  cat > "$FIX/probe4.sh" <<'P4'
. "$PD_LIB"
git push "$PD_URLTARGET" HEAD >/dev/null 2>&1; res push_url_rc "$?"
git push origin HEAD >/dev/null 2>&1; res push_origin_rc "$?"
git push second HEAD >/dev/null 2>&1; res push_second_rc "$?"
P4
  cat > "$FIX/probe6.sh" <<'P6'
. "$PD_LIB"
echo probe95 > /tmp/pi-delegate-probe95-tmpfs 2>/dev/null; res tmp_rc "$?"
P6

  export PD_LIB="$FIX/probe-lib.sh"
  export PD_OTHER="$OTHER"
  export PD_URLTARGET="$CLONE/url-target.git"
  cd "$CLONE" || return 1
}

teardown() {
  [ -n "${FIX:-}" ] || return 0
  pkill -f "$BIN/pi" 2>/dev/null || true
  if [ -f "$CLONE/.stub-child" ]; then
    kill -KILL "$(cat "$CLONE/.stub-child")" 2>/dev/null || true
  fi
  rm -rf "$FIX"
}

# Skip unless the host can actually build the documented sandbox: bwrap
# installed, and unprivileged user namespaces usable. On Ubuntu 24.04 the
# second check fails with "setting up uid map: Permission denied" while
# bwrap is absent everywhere unless installed — both skip, neither fails.
require_bwrap() {
  command -v bwrap >/dev/null 2>&1 \
    || skip "bwrap (bubblewrap) is not installed — the Linux recipe cannot be exercised here"
  bwrap --ro-bind / / --dev /dev --proc /proc -- true >/dev/null 2>&1 \
    || skip "bwrap cannot create a sandbox — unprivileged user namespaces are restricted (on Ubuntu 24.04: kernel.apparmor_restrict_unprivileged_userns=1)"
}

# One detached run.sh call, pi under the doc-extracted wrapper. Fails loudly
# (never vacuously) when the mock pi did not actually run inside the wrapper.
sandbox_probe() {
  rm -f "$CLONE/.stub-argv" "$CLONE/.stub-stdin" "$CLONE/.probe-results" "$CLONE/.probe-secrets"
  run env HOME="$FAKEHOME" PI_DELEGATE_WRAP="$FIX/sandbox" PD_PROBE="$1" \
    bash "$RUN" <<< "sandbox probe"
  [[ "$output" == *"EXIT CODE: 0"* ]] || { printf 'run.sh output:\n%s\n' "$output" >&2; return 1; }
  [ -s "$CLONE/.stub-argv" ] || { echo "the mock pi never ran inside the wrapper" >&2; return 1; }
  [ -s "$CLONE/.probe-results" ] || { echo "the probe list did not run" >&2; return 1; }
}

# --- harness / anti-drift ---------------------------------------------------

@test "the recipe under test is the Linux block of docs/configuration.md, shape intact" {
  [ -s "$FIX/sandbox" ] || { echo "no \`\`\`sh block found after the **Linux** marker in $DOC" >&2; return 1; }
  grep -q '^exec bwrap ' "$FIX/sandbox"
  grep -q -- '--ro-bind / /' "$FIX/sandbox"
  grep -q -- '--tmpfs /tmp' "$FIX/sandbox"
  grep -q -- '--tmpfs "$HOME"' "$FIX/sandbox"
  grep -q -- '--bind "$PI_DELEGATE_RUN"' "$FIX/sandbox"
  grep -q -- '--die-with-parent' "$FIX/sandbox"
  grep -q -- '--unshare-pid' "$FIX/sandbox"
}

@test "the doc keeps the not-a-security-boundary caveat and points at this probe suite" {
  grep -q 'not a security boundary' "$DOC"
  grep -q 'sandbox-probes.bats' "$DOC"
}

# --- the probe list from the issue ------------------------------------------

@test "probe 1: writes outside the clone never appear on the host" {
  require_bwrap
  sandbox_probe "$FIX/probe1.sh"
  grep -q '^write_home_rc=' "$CLONE/.probe-results"
  [ ! -e "$FAKEHOME/outside-home" ]
  [ ! -e "$OTHER/outside-other" ]
  [ ! -e /etc/pi-delegate-probe95 ]
}

@test "probe 2: cd to another checkout cannot create a branch or a commit (read-only FS)" {
  require_bwrap
  sandbox_probe "$FIX/probe2.sh"
  grep -q '^branch_rc=' "$CLONE/.probe-results"
  run git -C "$OTHER" branch --list pi-delegate-escape
  [ -z "${output// /}" ]
  [ "$(git -C "$OTHER" rev-list --count HEAD)" -eq 1 ]
}

@test "probe 3: reading ~/.ssh, ~/.config/gh, ~/.git-credentials and ~/.netrc yields nothing" {
  require_bwrap
  # The fixture really planted something to hide — otherwise this is vacuous.
  grep -q PROBE95SECRET "$FAKEHOME/.ssh/id_rsa"
  grep -q PROBE95SECRET "$FAKEHOME/.config/gh/hosts.yml"
  grep -q PROBE95SECRET "$FAKEHOME/.git-credentials"
  grep -q PROBE95SECRET "$FAKEHOME/.netrc"
  sandbox_probe "$FIX/probe3.sh"
  [ -e "$CLONE/.probe-secrets" ]
  run grep -c PROBE95SECRET "$CLONE/.probe-secrets"
  [ "$output" = "0" ]
}

@test "probe 4: push fails for an explicit URL and for every remote, and the bare targets stay empty" {
  require_bwrap
  sandbox_probe "$FIX/probe4.sh"
  local f
  for f in push_url_rc push_origin_rc push_second_rc; do
    grep -Eq "^$f=[1-9]" "$CLONE/.probe-results"
  done
  local d
  for d in upstream.git second.git url-target.git; do
    [ -z "$(git --git-dir="$CLONE/$d" for-each-ref)" ]
  done
}

@test "probe 5: a setsid'd child outliving the call is reaped" {
  [ -d /proc/self ] || skip "the PI_DELEGATE_RUN reaper scan needs /proc (Linux)"
  command -v setsid >/dev/null 2>&1 || skip "setsid is not available"
  rm -f "$CLONE/.stub-child"
  run env STUB_SETSID=1 bash "$RUN" <<< "reaper probe"
  [[ "$output" == *"EXIT CODE: 0"* ]]
  local child
  child="$(cat "$CLONE/.stub-child")"
  [ -n "$child" ]
  for _ in $(seq 1 50); do
    kill -0 "$child" 2>/dev/null || return 0
    sleep 0.1
  done
  echo "the setsid child $child outlived the call — the reaper missed it" >&2
  return 1
}

@test "probe 6: writes to /tmp land in the private tmpfs, not on the host" {
  require_bwrap
  rm -f /tmp/pi-delegate-probe95-tmpfs
  sandbox_probe "$FIX/probe6.sh"
  # Inside the sandbox the write had to succeed (rc=0); on the host the
  # file must not exist. Only that pair proves a private tmpfs — a failed
  # write would also leave the host clean.
  grep -q '^tmp_rc=0$' "$CLONE/.probe-results"
  [ ! -e /tmp/pi-delegate-probe95-tmpfs ]
}

@test "probe 7: the wrapper fails closed when bwrap is missing — pi never runs unwrapped" {
  # run.sh only checks the FIRST word of PI_DELEGATE_WRAP is executable;
  # the inner bwrap of the recipe is unchecked, so pin what happens when it
  # cannot be exec'd: the payload must not run.
  sed 's/^exec bwrap /exec pi-delegate-no-such-bwrap-95 /' "$FIX/sandbox" > "$FIX/sandbox-nobwrap"
  chmod +x "$FIX/sandbox-nobwrap"
  rm -f "$CLONE/.stub-argv"
  run env HOME="$FAKEHOME" PI_DELEGATE_WRAP="$FIX/sandbox-nobwrap" bash "$RUN" <<< "fail-closed probe"
  [ ! -e "$CLONE/.stub-argv" ]
  [[ "$output" != *"pi says done"* ]]
  local rc
  rc="$(printf '%s\n' "$output" | sed -n 's/^EXIT CODE: \([0-9]*\).*/\1/p')"
  [ -n "$rc" ]
  [ "$rc" -ne 0 ]
}
