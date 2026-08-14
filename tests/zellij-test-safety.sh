#!/usr/bin/env bash
# tests/zellij-test-safety.sh - shared hard guard against a real-zellij test's
# cleanup ever touching the machine's real "firstmate" session (the default
# session name bin/backends/zellij.sh uses for actual firstmate task tabs) or
# running a fleet-wide destructive command. Mirrors
# tests/herdr-test-safety.sh's guard, adapted to zellij's session model and
# the safety rule this task was given directly (never `kill-all-sessions`,
# the same discipline PR #199 established for herdr after two live-fleet
# kills - see tests/herdr-test-safety.sh's incident note).
#
# Zellij's own risk shape differs from herdr's: there is no ambient
# `server stop`-style command that silently resolves to "whatever session is
# currently running" - `zellij kill-session <name>` and
# `zellij delete-session <name>` both take an explicit, required name. So the
# realistic failure mode here is not env-var-routing unreliability (herdr's
# root cause) but a test accidentally reusing (and then killing) the real
# "firstmate" session name, or a caller reaching for the fleet-wide
# `kill-all-sessions`/`delete-all-sessions` commands. This guard defends
# against both: it refuses to touch a session unless the caller can name it
# explicitly, that name is NOT "firstmate" (the real default), and it is
# currently listed as a session this test itself is responsible for.
#
# Fails CLOSED: any ambiguity (an empty name, the literal default name, a
# failed/empty session list, a name that does not resolve) refuses rather
# than proceeding, because the cost of a false refusal (a leaked test
# session, cleaned up by hand later) is trivially recoverable, while the cost
# of a false negative (deleting the real session) is not.
set -u

# zellij_refuse_if_unsafe: 0 (SAFE to proceed) only if <name> is non-empty,
# is NOT the literal "firstmate" default session name, and IS currently
# listed as an active zellij session. 1 (REFUSE) on anything else.
zellij_test_session_state() {  # <name>
  local name=$1 sessions rc
  [ -n "$name" ] || { echo "zellij safety guard: refusing - empty session name" >&2; return 1; }
  if [ "$name" = firstmate ]; then
    echo "zellij safety guard: refusing - name is literally 'firstmate' (the real default session a live fleet may use)" >&2
    return 1
  fi
  if sessions=$(zellij list-sessions --short --no-formatting 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 1 ] && [ "$sessions" = "No active zellij sessions found." ]; then
      printf 'absent\n'
      return 0
    fi
    echo "zellij safety guard: refusing - session inventory is unreadable: ${sessions:-<no output>}" >&2
    return 1
  fi
  if [ -z "$sessions" ]; then
    echo "zellij safety guard: refusing - successful session inventory was empty" >&2
    return 1
  fi
  if printf '%s\n' "$sessions" | grep -qxF "$name"; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}

zellij_refuse_if_unsafe() {  # <name>
  local name=$1 state
  state=$(zellij_test_session_state "$name") || return 1
  if [ "$state" != present ]; then
    echo "zellij safety guard: refusing - session '$name' not found in 'zellij list-sessions'" >&2
    return 1
  fi
  return 0
}

# zellij_safe_delete: the ONLY sanctioned way for a test to tear down an
# isolated session it created. Validates the explicit session name and state, then
# uses the explicit-by-name `delete-session --force` form (kills if running,
# then deletes in one call) - NEVER `kill-all-sessions` or
# `delete-all-sessions` - and confirms the session is absent afterward.
# A session already confirmed absent is an idempotent success; inventory,
# delete, and post-delete verification failures propagate to the caller.
zellij_safe_delete() {  # <name>
  local name=$1 state
  state=$(zellij_test_session_state "$name") || return 1
  [ "$state" = present ] || return 0
  zellij delete-session "$name" --force >/dev/null 2>&1 || return 1
  state=$(zellij_test_session_state "$name") || return 1
  if [ "$state" != absent ]; then
    echo "zellij safety guard: session '$name' still exists after delete" >&2
    return 1
  fi
  return 0
}
