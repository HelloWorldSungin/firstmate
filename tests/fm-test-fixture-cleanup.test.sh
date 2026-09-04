#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_descendants /
# fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
#
# Process cleanup is covered too: a fixture that backgrounds a long-lived
# daemon must not leave it orphaned when the owning shell exits.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

# Fails if fm_test_cleanup stops killing descendant processes on normal exit.
# This catches regressions where the EXIT trap fires but only removes dirs.
test_fixture_processes_reaped_after_normal_exit() {
  local child_out child_dir leaked_pid
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-proc-exit)
    printf "%s\n" "$d"
    sleep 3600 > "$d/sleep.log" 2>&1 &
    printf "pid:%s\n" "$!"
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  leaked_pid=$(printf '%s\n' "$child_out" | sed -n 's/^pid://p')
  # A missing pid is a failure, not a skip: without it the process assertion
  # below would be vacuous and the test would still report ok.
  [ -n "$leaked_pid" ] || fail "the fixture owner never published its background process's pid"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  if kill -0 "$leaked_pid" 2>/dev/null; then
    fail "a background process started by the fixture owner outlived its normal exit"
  fi
  pass "fm_test_cleanup reaps background processes on normal exit"
}

# Fails if SIGTERM teardown kills the fixture root but not its descendant
# processes. The signal path is separate from the normal EXIT path, so a
# regression can hide in one but not the other.
test_fixture_processes_reaped_after_sigterm() {
  local harness dirfile child_dir leaked_pid pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-proc-sigterm-harness)
  dirfile="$harness/child-info"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-proc-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    sleep 3600 > "$d/sleep.log" 2>&1 &
    printf "pid:%s\n" "$!" >> "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  # Waiting on the pid line, not on a non-empty file: the fixture root is
  # published first, so a poll that stopped at `-s` could signal the child
  # before it had forked the background process this case exists to chase.
  while [ "$tries" -lt 100 ]; do
    grep -q '^pid:' "$dirfile" 2>/dev/null && break
    sleep 0.05
    tries=$((tries + 1))
  done
  grep -q '^pid:' "$dirfile" 2>/dev/null ||
    fail "the child never published its fixture info before the wait timed out"
  child_dir=$(sed -n '1p' "$dirfile")
  leaked_pid=$(sed -n 's/^pid://p' "$dirfile")
  [ -n "$leaked_pid" ] || fail "the child published an empty background process pid"
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  if kill -0 "$leaked_pid" 2>/dev/null; then
    fail "a background process started by the fixture owner outlived SIGTERM to its owner"
  fi
  pass "fm_test_cleanup reaps background processes on SIGTERM"
}

# The sweep enumerates candidates from a process table that is already stale by
# the time it signals - most reliably because the `$(...)` used to capture the
# child list is itself a short-lived child of the sweeping shell. Signalling is
# therefore gated on the candidate still being a live child of the parent it was
# enumerated under; without that gate a recycled PID belonging to an unrelated
# host process is a valid target.
test_descendant_guard_admits_only_live_children() {
  local victim
  sleep 30 &
  victim=$!
  fm_test_pid_has_parent "$victim" "$$" ||
    fail "the descendant guard rejected a live child of the current shell"
  if fm_test_pid_has_parent "$victim" 1; then
    fail "the descendant guard accepted a live process that is not a child of the given parent"
  fi
  kill "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  if fm_test_pid_has_parent "$victim" "$$"; then
    fail "the descendant guard accepted a pid that had already exited"
  fi
  if fm_test_pid_has_parent "" "$$" || fm_test_pid_has_parent "not-a-pid" "$$"; then
    fail "the descendant guard accepted a non-numeric pid"
  fi
  pass "the descendant sweep signals only live children of the expected parent"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_fixture_processes_reaped_after_normal_exit
test_fixture_processes_reaped_after_sigterm
test_descendant_guard_admits_only_live_children
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree

printf '\nall fm-test-fixture-cleanup tests passed\n'
