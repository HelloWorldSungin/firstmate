#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. Shared fake-toolchain and spawn-world
# builders live in tests/fixtures.sh; wake-queue mocks in wake-helpers.sh;
# secondmate-lifecycle mocks in secondmate-helpers.sh. Suite-specific fakes
# that encode a single test's terminal or lifecycle assumptions still belong
# with the tests that own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh, fixtures.sh) source this library for ROOT/fail/pass, and the
# test that includes them may also source it directly. Re-sourcing must not wipe
# the registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Isolate the dashboard's event instrumentation and its store from the
# developer's own host. Both live OUTSIDE any FM_HOME by design, so neither is
# covered by the FM_*_OVERRIDE isolation every other suite relies on.
#
#   FM_DASHBOARD_EVENTS_CONFIG  bin/fm-spawn.sh and bin/fm-event-emit.sh gate
#     instrumentation on this user-level file, which is the one piece of user
#     config a spawn reads outside the FM_HOME overrides. Left ambient, a host
#     that has run bin/fm-dashboard-instrument.sh enable would make every
#     spawn-driving suite generate different per-task hook files than a clean
#     host, and driving a generated OpenCode plugin would post test task ids
#     into the operator's live store.
#   FM_DASHBOARD_EVENT_DB  the store bin/fm-dashboard-server.mjs opens. Left
#     ambient it resolves under the operator's real state root, keyed by a
#     digest of the fixture home's path - so every run would leave another
#     never-cleaned store directory behind there.
#   FM_DASHBOARD_AUTH_FILE  the dashboard credentials. Left ambient, a developer
#     who has set a dashboard password on this machine would have every fixture
#     server in every suite start authenticated, and each one would fail on the
#     401 its unauthenticated fixture requests get back - a failure with nothing
#     to do with the case under test.
#
# The directory is deliberately never created, so instrumentation is off and no
# store exists; a suite that wants either points the variable at its own
# fixture. This is the second barrier, not the only one: the server is itself
# presence-gated and opens no store without a configured token.
FM_TEST_ISOLATION_ROOT="${TMPDIR:-/tmp}/fm-test-dashboard-isolation.$$"
export FM_DASHBOARD_EVENTS_CONFIG="$FM_TEST_ISOLATION_ROOT/dashboard-events.json"
export FM_DASHBOARD_EVENT_DB="$FM_TEST_ISOLATION_ROOT/events.db"
export FM_DASHBOARD_AUTH_FILE="$FM_TEST_ISOLATION_ROOT/dashboard-auth.json"

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# --- a suite must actually run what it defines -------------------------------
#
# A test that is defined and never invoked reports safety it never checked, and
# it is invisible while it does: the suite still exits 0 and prints nothing about
# it. That has happened here, from red-proof scaffolding left behind in an
# invocation list, so it is enforced rather than reviewed for.
#
# What is compared is what actually RAN against what the shell says is DEFINED,
# never two greps over the file: `pass` records the test it was called from, and
# fm_test_every_defined_test_ran reads the definitions from `declare -F`. A
# renamed function, a commented-out call, and a test that returns before its own
# `pass` are all caught by that, and none of them would be by matching text.
FM_TEST_RAN=

pass() {
  case "${FUNCNAME[1]:-}" in
    test_*) FM_TEST_RAN="$FM_TEST_RAN ${FUNCNAME[1]} " ;;
  esac
  printf 'ok - %s\n' "$1"
}

# Call last, after the invocation list, in any suite that wants the guarantee.
fm_test_every_defined_test_ran() {
  local name missing=
  for name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }' | LC_ALL=C sort); do
    case "$FM_TEST_RAN" in
      *" $name "*) ;;
      *) missing="$missing $name" ;;
    esac
  done
  [ -z "$missing" ] \
    || fail "defined but never ran, so this suite reported green over them:$missing"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT/INT/TERM. That teardown first sweeps the shell's descendant process
# subtree (fm_test_reap_descendants below), so a fixture that backgrounds a
# daemon does not leave it orphaned. A test file that still needs extra teardown
# - a process that escapes the subtree by daemonizing, or one that must be
# stopped in a specific order before its tree is removed, as in
# fm_test_stop_remote_job_worker below - should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.
#
# The call site is almost always `TMP_ROOT=$(fm_test_tmproot prefix)`, which
# forks a subshell to capture stdout. Anything that function does to the
# current shell's state - an array append, a trap - dies with that subshell
# and never reaches the real caller, so registration cannot go through
# in-process state. `$$` is the one thing bash keeps stable across that
# boundary (it always resolves to the invoking shell's PID, not the
# subshell's - see `man bash` on `$$`), so fm_test_tmproot records the
# directory in a `$$`-keyed registry file instead, and the trap that reaps
# that file is armed once, here, at source time - which always runs in the
# real caller, never a subshell.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-cleanup.$$.XXXXXX") || return 1

fm_test_pid_identity() {
  local pid=$1
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

fm_test_cleanup() {
  # Ordered before the directory removal below on purpose: a daemon left alive
  # can write its state back into a tree that is being unlinked, which fails the
  # removal (see fm_test_stop_remote_job_worker for one such supervisor).
  # fm_test_reap_descendants owns what the sweep may signal.
  fm_test_reap_descendants

  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    # A case that hardened a directory to prove a read-only path leaves a tree
    # rm cannot unlink, and an aborted case never gets to restore it. Write
    # permission is restored here so a failing test still cleans up after itself.
    [ -n "$d" ] && chmod -R u+w "$d" 2>/dev/null
    [ -n "$d" ] && rm -rf "$d"
  done
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
  [ -n "${FM_TEST_ISOLATION_ROOT:-}" ] && rm -rf "$FM_TEST_ISOLATION_ROOT"
  return 0
}

# fm_test_reap_descendants: best-effort kill of the entire process subtree
# rooted at the current shell. Test fixtures frequently background long-lived
# daemons (e.g. fm-watch.sh); without this, a fixture that exits without
# explicit teardown leaves those daemons orphaned. Leaves are killed before
# parents so no process is reparented mid-sweep. The current shell is excluded.
fm_test_reap_descendants() {
  local pid
  for pid in $(fm_test_child_pids "$$"); do
    fm_test_kill_tree "$pid" "$$"
  done
}

# fm_test_child_pids <parent> lists the PIDs that were children of <parent> at
# the instant it ran. That is a candidate list, never a licence to signal: the
# `$(...)` a caller captures it with forks a subshell that is itself a child of
# the calling shell, so when <parent> is that shell the list always carries the
# transient subshell's own PID - already exited by the time the caller reads it.
# fm_test_pid_has_parent is what turns a candidate into a target.
fm_test_child_pids() {
  local parent=$1
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$parent" 2>/dev/null || true
  else
    ps -eo pid,ppid= 2>/dev/null \
      | awk -v p="$parent" '$2 == p { print $1 }' \
      || true
  fi
}

# fm_test_pid_has_parent <pid> <parent> is true only while <pid> is still alive
# AND still a direct child of <parent>. Every signal below is gated on it, so a
# candidate that exited between enumeration and the kill is skipped instead of
# signalled - which is what keeps the sweep off an unrelated host process that
# the kernel has since handed that recycled PID to.
fm_test_pid_has_parent() {
  local pid=$1 parent=$2 actual
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  actual=$(LC_ALL=C ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
  [ -n "$actual" ] && [ "$actual" = "$parent" ]
}

fm_test_kill_tree() {
  local pid=$1 parent=$2 child waited
  fm_test_pid_has_parent "$pid" "$parent" || return 0
  for child in $(fm_test_child_pids "$pid"); do
    fm_test_kill_tree "$child" "$pid"
  done
  # Re-verified after the recursion and on every escalation: draining the leaves
  # takes real time, and the target can exit on its own inside that window.
  # Killing leaves before parents is what keeps <parent> alive throughout, so a
  # still-live target that stops matching it has genuinely gone.
  fm_test_pid_has_parent "$pid" "$parent" || return 0
  kill "$pid" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 20 ]; do
    fm_test_pid_has_parent "$pid" "$parent" || return 0
    sleep 0.05 2>/dev/null || true
    waited=$((waited + 1))
  done
  fm_test_pid_has_parent "$pid" "$parent" || return 0
  kill -9 "$pid" 2>/dev/null || true
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$root/.fm-test-fixture" ||
    ! printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"; then
    rm -rf "$root"
    return 1
  fi
  printf '%s\n' "$root"
}

# fm_test_stop_remote_job_worker <remote-job-state-root> stops a remote job
# worker a fixture started and returns only once it is really gone, so a
# following `rm -rf` of the fixture's temp tree cannot race it.
#
# On Linux bin/fm-remote-job-worker.sh runs as a restart supervisor whose
# `--serve` child is the process that publishes worker.pid. Killing that
# recorded pid alone therefore only ends one child: the supervisor survives and
# immediately starts a replacement, which recreates its state root inside the
# fixture's temp tree while the fixture is removing it, and that removal then
# fails with "Directory not empty". So the supervisor is stopped first - and
# only when it is genuinely this worker's parent - which stops its own child
# too. macOS has no such supervisor, and there the recorded pid is the worker.
fm_test_stop_remote_job_worker() {
  local state=$1 pid parent waited=0
  pid=$(cat "$state/worker.pid" 2>/dev/null) || return 0
  case "$pid" in '' | *[!0-9]*) return 0 ;; esac
  parent=$(LC_ALL=C ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
  case "$parent" in '' | *[!0-9]*) parent= ;; esac
  if [ -n "$parent" ]; then
    case "$(LC_ALL=C ps -p "$parent" -o command= 2>/dev/null)" in
      *fm-remote-job-worker.sh*) ;;
      *) parent= ;;
    esac
  fi
  [ -z "$parent" ] || kill "$parent" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  while [ "$waited" -lt 200 ]; do
    if ! kill -0 "$pid" 2>/dev/null &&
      { [ -z "$parent" ] || ! kill -0 "$parent" 2>/dev/null; }; then
      return 0
    fi
    waited=$((waited + 1))
    sleep 0.05
  done
  return 0
}

# --- the operator's own state root ------------------------------------------
#
# The dashboard's agent-event store is the one fleet artifact that lives outside
# every FM_HOME, so a code path that opens it without an explicit path writes
# into the operator's real state root instead of a suite's temp space - and
# leaves it there, keyed by a digest of a temp directory that no longer exists.
# FM_DASHBOARD_EVENT_DB above is the barrier; this is how a suite proves it
# held. Entries already present are recorded rather than required to be absent,
# so the check reports what THIS run created and nothing else.

fm_user_event_store_root() {
  printf '%s/firstmate/dashboard-events\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

fm_user_event_store_snapshot() {
  find "$(fm_user_event_store_root)" -mindepth 1 -maxdepth 1 2>/dev/null \
    | sed 's|.*/||' \
    | sort
}

fm_assert_no_user_event_store_leak() {  # <snapshot-taken-before-the-suite>
  local added
  added=$(comm -13 \
    <(printf '%s\n' "$1" | grep -v '^$' | sort) \
    <(fm_user_event_store_snapshot | grep -v '^$'))
  [ -z "$added" ] || fail "an agent-event store was created outside the suite's temp space, under $(fm_user_event_store_root): $(printf '%s' "$added" | tr '\n' ' ')"
}

trap fm_test_cleanup EXIT
trap 'fm_test_cleanup; exit 130' INT
trap 'fm_test_cleanup; exit 143' TERM

# fm_test_reap_orphans: best-effort sweep for fixture roots left behind by a
# prior run that was killed hard enough to skip the traps above (e.g. a
# SIGKILL timeout). Only removes directories carrying the .fm-test-fixture
# marker fm_test_tmproot writes, so it never touches unrelated fm-* tmp dirs
# from real (non-test) firstmate commands. The marker identifies the owning
# shell across PID reuse, so the same live owner always wins over the age
# fallback for dead or unowned roots.
FM_TEST_ORPHAN_MAX_AGE_SECONDS=${FM_TEST_ORPHAN_MAX_AGE_SECONDS:-3600}

fm_test_reap_orphans() {
  local marker dir mtime now owner_pid owner_identity current_identity
  now=$(date +%s)
  for marker in "${TMPDIR:-/tmp}"/fm-*/.fm-test-fixture; do
    [ -e "$marker" ] || continue
    owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || owner_pid=
    owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || owner_identity=
    case "$owner_pid" in
      '' | *[!0-9]*) ;;
      *)
        current_identity=$(fm_test_pid_identity "$owner_pid" 2>/dev/null) || current_identity=
        if [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
          continue
        fi
        ;;
    esac
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    [ $((now - mtime)) -ge "$FM_TEST_ORPHAN_MAX_AGE_SECONDS" ] || continue
    dir=$(dirname "$marker")
    if [ -d "$dir" ] && [ ! -L "$dir" ]; then
      find "$dir" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    fi
    rm -rf "$dir"
  done
}

# A parent coordinator can reap once before it starts isolated child sections.
# Those children use their own EXIT cleanup and must not spend their bounded
# execution window repeating the same global stale-fixture scan.
if [ "${FM_TEST_SKIP_ORPHAN_REAP:-0}" != 1 ]; then
  fm_test_reap_orphans
fi

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir. fm_fake_version_tool drops a stub for a tool
# whose installed version bootstrap gates, so a fixture cannot be reported as an
# unparseable build simply for answering `--version` with nothing.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_fake_version_tool <fakebin> <tool> <override-env-var> <default-version>
# The stub answers `--version` with <override-env-var> when that variable is set
# and non-empty, and with <default-version> otherwise; every other invocation
# exits 0. A case that needs to drive a version floor exports the variable.
fm_fake_version_tool() {
  local fakebin=$1 tool=$2 override=$3 default=$4
  cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' "\${$override:-$default}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: initialize <repo> with one commit
# and a local bare origin, then add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# fm_test_wait_absent <path> <description> [ceiling_secs]: poll <path> until it
# stops existing, with a [ceiling_secs] ceiling (default 15). The disappearance
# of <path> is the observable event the test is checking, so the wait is bounded
# by that event rather than by a wall-clock bound on the cleanup mechanism
# itself: a genuinely missing cleanup still fails (the ceiling elapses with the
# path still present), and a slow cleanup simply waits its real duration. Use
# this when the assertion is that some side effect has settled, not when the
# assertion is "this finished in N seconds".
fm_test_wait_absent() {
  local path=$1 description=$2 ceiling_secs=${3:-15}
  local remaining_polls=$(( ceiling_secs * 20 ))
  while [ -e "$path" ] && [ "$remaining_polls" -gt 0 ]; do
    sleep 0.05
    remaining_polls=$(( remaining_polls - 1 ))
  done
  [ ! -e "$path" ] || fail "$description (still present after ${ceiling_secs}s ceiling)"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
