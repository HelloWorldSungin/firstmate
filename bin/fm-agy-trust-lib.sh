#!/usr/bin/env bash
# bin/fm-agy-trust-lib.sh - manage agy's (Antigravity CLI) global workspace-trust
# list so a firstmate-launched agy crewmate can start unattended, and clean the
# entry up at teardown. Sourced by bin/fm-spawn.sh (add before launch, roll back
# on abort) and bin/fm-teardown.sh (remove after landing).
#
# WHY: agy gates an interactive launch behind a per-workspace trust modal, and
# --dangerously-skip-permissions does NOT cover it (verified,
# data/cursor-agy-verify/report.md point 4). Trust lives in agy's SINGLE global
# settings file under "trustedWorkspaces", an array of EXACT absolute paths -
# prefix match does not count, so a trusted /home/x does not trust
# /home/x/worktree. firstmate therefore adds the exact crew-worktree path before
# launch and removes it at teardown.
#
# That settings file is SHARED with the captain's own direct agy use and with
# every other firstmate home, so every mutation is deliberately careful:
#   - OWNERSHIP-AWARE: fm_agy_trust_add reports created vs preexisting (via
#     FM_AGY_TRUST_ADDED), so firstmate removes ONLY an entry it actually added
#     and never deletes a path the captain had already trusted for reuse. The
#     spawn/teardown callers persist that ownership durably (state/<id>.agy-trust)
#     and roll back on abort.
#   - LOCKED with the repository's ownership-and-liveness lock (fm_lock_*): a
#     stale lock is reclaimed only when its holder PID is provably dead, so a slow
#     mutator's LIVE lock is never stolen, and only the acquiring process releases.
#   - ATOMIC - written to a sibling temp file and mv'd into place.
#   - FAIL-CLOSED - a settings file that is not valid JSON is left UNTOUCHED
#     rather than clobbered, and a missing file is created minimally only for add.
#
# FM_AGY_SETTINGS_OVERRIDE points the whole thing at a test file; the real path
# is $HOME/.gemini/antigravity-cli/settings.json.

# The ownership-and-liveness lock lives in bin/fm-wake-lib.sh. fm-spawn already
# sources it; fm-teardown (and standalone tests) may not, so pull it in on demand.
# Source it only when present: it always sits next to this file in a real bin/,
# but a curated test stub that sources this library without exercising the trust
# functions (e.g. a non-agy teardown) may omit it, and a missing optional lock
# backend must not abort the sourcing script. The lock is only ever invoked for
# agy tasks, whose full firstmate environment always has fm-wake-lib.sh.
if ! command -v fm_lock_try_acquire >/dev/null 2>&1; then
  __fm_agy_wake_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
  if [ -f "$__fm_agy_wake_lib" ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$__fm_agy_wake_lib"
  fi
  unset __fm_agy_wake_lib
fi

# fm_agy_settings_path: the agy global settings file this home should mutate.
fm_agy_settings_path() {
  if [ -n "${FM_AGY_SETTINGS_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_AGY_SETTINGS_OVERRIDE"
  else
    printf '%s\n' "${HOME:-}/.gemini/antigravity-cli/settings.json"
  fi
}

# fm_agy_trust_lock_acquire: bounded wait on the ownership-aware lock. Returns 1
# if the lock cannot be acquired within the budget (the live holder never yields);
# the caller then fails closed rather than forcing the mutation.
fm_agy_trust_lock_acquire() {  # <lockdir>
  local lock=$1 tries=0
  while [ "$tries" -lt 200 ]; do
    fm_lock_try_acquire "$lock" && return 0
    sleep 0.1
    tries=$((tries + 1))
  done
  return 1
}

fm_agy_trust_lock_release() {  # <lockdir>
  fm_lock_release "$1"
}

# fm_agy_trust_add <abs-path>: trust <abs-path> before an agy launch.
# On success sets FM_AGY_TRUST_ADDED to `created` (firstmate added the entry) or
# `preexisting` (the path was already trusted - firstmate must NOT own or later
# remove it). Returns non-zero (FM_AGY_TRUST_ADDED empty) on any error.
fm_agy_trust_add() {  # <abs-path>
  # FM_AGY_TRUST_ADDED is the created-vs-preexisting ownership signal consumed by
  # the caller (fm-spawn), not within this library.
  # shellcheck disable=SC2034
  FM_AGY_TRUST_ADDED=
  local path=$1 file lock tmp rc=0 already
  command -v jq >/dev/null 2>&1 || { echo "warning: jq unavailable; cannot add agy workspace trust for $path" >&2; return 1; }
  case "$path" in
    /*) : ;;
    *) echo "warning: agy workspace trust needs an absolute path, got '$path'" >&2; return 1 ;;
  esac
  file=$(fm_agy_settings_path)
  [ -n "$file" ] || return 1
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  lock="$file.fm-trust.lock"
  fm_agy_trust_lock_acquire "$lock" || { echo "warning: could not lock agy settings to add workspace trust for $path" >&2; return 1; }
  if [ -e "$file" ]; then
    if ! jq -e . "$file" >/dev/null 2>&1; then
      echo "warning: agy settings at $file is not valid JSON; leaving it untouched (workspace trust add skipped for $path)" >&2
      fm_agy_trust_lock_release "$lock"
      return 1
    fi
    already=$(jq -r --arg p "$path" '((.trustedWorkspaces // []) | index($p)) != null' "$file" 2>/dev/null)
    if [ "$already" = true ]; then
      # The captain (or a prior run) already trusts this exact path: firstmate
      # does not own it and must not later remove it.
      FM_AGY_TRUST_ADDED=preexisting
      fm_agy_trust_lock_release "$lock"
      return 0
    fi
    tmp=$(mktemp "$file.fm-trust.XXXXXX" 2>/dev/null) || { fm_agy_trust_lock_release "$lock"; return 1; }
    jq --arg p "$path" '.trustedWorkspaces = ((.trustedWorkspaces // []) | map(select(. != $p)) + [$p])' "$file" > "$tmp" 2>/dev/null || rc=1
  else
    tmp=$(mktemp "$file.fm-trust.XXXXXX" 2>/dev/null) || { fm_agy_trust_lock_release "$lock"; return 1; }
    jq -n --arg p "$path" '{trustedWorkspaces: [$p]}' > "$tmp" 2>/dev/null || rc=1
  fi
  if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
    mv -f "$tmp" "$file" || rc=1
  else
    rc=1
  fi
  [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null || true
  fm_agy_trust_lock_release "$lock"
  # shellcheck disable=SC2034  # FM_AGY_TRUST_ADDED is read by the caller (fm-spawn)
  [ "$rc" -eq 0 ] && FM_AGY_TRUST_ADDED=created
  return "$rc"
}

# fm_agy_trust_rollback <abs-path> <marker>: undo a firstmate-CREATED trust grant
# after a failed spawn. It is the exact logic fm-spawn's abort trap runs, factored
# out so it is unit-testable. On clean removal the leaked entry is gone and the
# ownership <marker> is deleted (return 0). On removal FAILURE (unparseable or
# locked settings) the firstmate-owned entry is still present, so it PRESERVES
# retry evidence by (re)writing <marker> with <abs-path> - even when the marker
# was never written (a marker-write failure after seeding) - and returns 1, so the
# caller can warn and a later cleanup can deterministically retry.
fm_agy_trust_rollback() {  # <abs-path> <marker>
  local path=$1 marker=$2
  if fm_agy_trust_remove "$path"; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  printf '%s' "$path" > "$marker" 2>/dev/null || true
  return 1
}

# fm_agy_trust_remove <abs-path>: drop <abs-path> at teardown (or spawn-abort
# rollback). Idempotent: a missing file or absent entry is a no-op success.
# Returns non-zero only on a real failure (jq missing, unparseable settings, lock
# contention, write failure) so the caller can treat it as an incomplete teardown
# and retry.
fm_agy_trust_remove() {  # <abs-path>
  local path=$1 file lock tmp rc=0
  command -v jq >/dev/null 2>&1 || { echo "warning: jq unavailable; cannot remove agy workspace trust for $path" >&2; return 1; }
  case "$path" in
    /*) : ;;
    *) echo "warning: agy workspace trust needs an absolute path, got '$path'" >&2; return 1 ;;
  esac
  file=$(fm_agy_settings_path)
  [ -n "$file" ] || return 1
  [ -e "$file" ] || return 0
  lock="$file.fm-trust.lock"
  fm_agy_trust_lock_acquire "$lock" || { echo "warning: could not lock agy settings to remove workspace trust for $path" >&2; return 1; }
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "warning: agy settings at $file is not valid JSON; leaving it untouched (workspace trust remove skipped for $path)" >&2
    fm_agy_trust_lock_release "$lock"
    return 1
  fi
  tmp=$(mktemp "$file.fm-trust.XXXXXX" 2>/dev/null) || { fm_agy_trust_lock_release "$lock"; return 1; }
  jq --arg p "$path" 'if (.trustedWorkspaces | type) == "array" then .trustedWorkspaces |= map(select(. != $p)) else . end' "$file" > "$tmp" 2>/dev/null || rc=1
  if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
    mv -f "$tmp" "$file" || rc=1
  else
    rc=1
  fi
  [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null || true
  fm_agy_trust_lock_release "$lock"
  return "$rc"
}
