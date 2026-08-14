#!/usr/bin/env bash
# tests/cmux-test-safety.sh - shared hard guard against a real-cmux test's
# cleanup ever touching a workspace that is not one the test itself just
# created. Mirrors tests/herdr-test-safety.sh's/tests/zellij-test-safety.sh's
# guard, adapted to cmux's shape: unlike herdr/zellij, cmux has no isolated,
# throwaway SESSION a test can spin up and tear down on its own - there is
# just "the app", the SAME real running instance the captain uses day to day.
# So the safety rule here is not about avoiding the wrong session name; it is
# about never closing a workspace this test did not itself create, and never
# enumerating-and-closing.
#
# Fails CLOSED: any ambiguity (an empty id, a plain label without the fm-test-
# prefix, a live workspace whose title does not match the scoped title for
# what the test expects) refuses rather than proceeding, because the cost of a
# false refusal (a leaked test workspace, cleaned up by hand later) is recoverable,
# while the cost of a false negative (closing a workspace that is not the
# test's own) is not - especially here, where that workspace could belong to
# the captain's own live work.
set -u

# cmux_refuse_if_unsafe: 0 (SAFE to proceed) only if <workspace_id> is
# non-empty, <want_label> carries the fm-test- prefix, and the workspace is
# CURRENTLY LISTED with the scoped title for <want_label>. 1 (REFUSE) on
# anything else. Requires bin/backends/cmux.sh already sourced.
cmux_test_workspace_state() {  # <workspace_id> <want_label>
  local wsid=$1 want_label=$2 want_title inventory title
  [ -n "$wsid" ] || { echo "cmux safety guard: refusing - empty workspace id" >&2; return 1; }
  case "$want_label" in
    fm-test-*) : ;;
    *) echo "cmux safety guard: refusing - label '$want_label' does not carry the fm-test- prefix" >&2; return 1 ;;
  esac
  want_title=$(fm_backend_cmux_scoped_title "$want_label")
  inventory=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null) || {
    echo "cmux safety guard: refusing - workspace inventory is unreadable" >&2
    return 1
  }
  title=$(printf '%s' "$inventory" | jq -er --arg id "$wsid" '
    if (.workspaces | type) != "array" then error("invalid workspace inventory")
    else [.workspaces[] | select(.id == $id) | .title]
      | if length == 0 then ""
        elif length == 1 and (.[0] | type) == "string" then .[0]
        else error("ambiguous workspace inventory")
        end
    end
  ' 2>/dev/null) || {
    echo "cmux safety guard: refusing - workspace inventory is invalid or ambiguous" >&2
    return 1
  }
  if [ -z "$title" ]; then
    printf 'absent\n'
    return 0
  fi
  if [ "$title" != "$want_title" ]; then
    echo "cmux safety guard: refusing - workspace $wsid title '${title:-<not found>}' does not match expected '$want_title'" >&2
    return 1
  fi
  printf 'present\n'
}

cmux_refuse_if_unsafe() {  # <workspace_id> <want_label>
  local state
  state=$(cmux_test_workspace_state "$1" "$2") || return 1
  if [ "$state" != present ]; then
    echo "cmux safety guard: refusing - workspace $1 not found" >&2
    return 1
  fi
  return 0
}

# cmux_safe_close_workspace: the ONLY sanctioned way for a test to tear down
# a workspace it created. Validates its scoped ownership and state, then closes
# the whole workspace (never a bulk/enumerate-based close), and confirms it is
# absent afterward. A workspace already confirmed absent is an idempotent
# success; inventory, guard, close, and post-close verification failures
# propagate to the caller.
cmux_safe_close_workspace() {  # <workspace_id> <want_label>
  local state
  state=$(cmux_test_workspace_state "$1" "$2") || return 1
  [ "$state" = present ] || return 0
  fm_backend_cmux_cli close-workspace --workspace "$1" >/dev/null 2>&1 || return 1
  state=$(cmux_test_workspace_state "$1" "$2") || return 1
  if [ "$state" != absent ]; then
    echo "cmux safety guard: workspace $1 still exists after close" >&2
    return 1
  fi
  return 0
}
