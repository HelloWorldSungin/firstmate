#!/usr/bin/env bash
# Unit tests for bin/fm-agy-trust-lib.sh - agy's global workspace-trust list,
# pre-seeded before an agy crew launch and removed at teardown. The file is
# shared with the captain's own agy use, so the contract under test is: locked,
# additive/idempotent, atomic, and fail-closed on a settings file it cannot parse.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-agy-trust-lib.sh
. "$ROOT/bin/fm-agy-trust-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the agy trust lib)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-agy-trust)
CASE_N=0

new_settings() {  # [initial-json] -> exports FM_AGY_SETTINGS_OVERRIDE
  local dir initial=${1:-}
  CASE_N=$((CASE_N + 1))
  dir="$TMP_ROOT/case-$CASE_N"
  mkdir -p "$dir"
  export FM_AGY_SETTINGS_OVERRIDE="$dir/settings.json"
  [ -z "$initial" ] || printf '%s' "$initial" > "$FM_AGY_SETTINGS_OVERRIDE"
}

test_add_creates_minimal_file() {
  new_settings
  fm_agy_trust_add /home/cap/wt-a || fail "add to a missing file should succeed"
  assert_present "$FM_AGY_SETTINGS_OVERRIDE" "add did not create the settings file"
  [ "$(jq -c '.trustedWorkspaces' "$FM_AGY_SETTINGS_OVERRIDE")" = '["/home/cap/wt-a"]' ] \
    || fail "minimal file did not contain exactly the added path"
  [ "$FM_AGY_TRUST_ADDED" = created ] || fail "creating a fresh entry must report FM_AGY_TRUST_ADDED=created"
  pass "add creates a minimal settings file with the exact path and reports created"
}

test_add_reports_created_vs_preexisting() {
  # Ownership signal (B3): a NEW entry is 'created' (firstmate owns it and may
  # remove it), an already-trusted exact path is 'preexisting' (the captain owns
  # it - firstmate must never modify or later remove it).
  new_settings '{"trustedWorkspaces":["/home/cap/pretrusted"]}'
  fm_agy_trust_add /home/cap/pretrusted || fail "add of a preexisting path should succeed"
  [ "$FM_AGY_TRUST_ADDED" = preexisting ] || fail "an already-trusted path must report preexisting"
  [ "$(jq -c '.trustedWorkspaces' "$FM_AGY_SETTINGS_OVERRIDE")" = '["/home/cap/pretrusted"]' ] \
    || fail "a preexisting add must leave the captain's settings byte-unchanged"
  fm_agy_trust_add /home/cap/new || fail "add of a new path should succeed"
  [ "$FM_AGY_TRUST_ADDED" = created ] || fail "a new path must report created"
  pass "add reports created for a new entry and preexisting for an already-trusted path"
}

test_add_preserves_other_paths_and_keys() {
  new_settings '{"trustedWorkspaces":["/home/cap"],"otherKey":{"x":1}}'
  fm_agy_trust_add /home/cap/wt-b || fail "add should succeed"
  [ "$(jq -c '.trustedWorkspaces' "$FM_AGY_SETTINGS_OVERRIDE")" = '["/home/cap","/home/cap/wt-b"]' ] \
    || fail "add did not append while preserving the existing trusted path"
  [ "$(jq -c '.otherKey' "$FM_AGY_SETTINGS_OVERRIDE")" = '{"x":1}' ] \
    || fail "add clobbered an unrelated settings key"
  pass "add preserves other trusted paths and unrelated settings keys"
}

test_add_is_idempotent() {
  new_settings '{"trustedWorkspaces":["/home/cap"]}'
  fm_agy_trust_add /home/cap/wt-c || fail "first add should succeed"
  fm_agy_trust_add /home/cap/wt-c || fail "second add should succeed"
  [ "$(jq -c '.trustedWorkspaces' "$FM_AGY_SETTINGS_OVERRIDE")" = '["/home/cap","/home/cap/wt-c"]' ] \
    || fail "re-adding the same path must not duplicate it"
  pass "add is idempotent (no duplicate entries)"
}

test_remove_drops_only_the_exact_path() {
  new_settings '{"trustedWorkspaces":["/home/cap","/home/cap/wt-d"],"otherKey":1}'
  fm_agy_trust_remove /home/cap/wt-d || fail "remove should succeed"
  [ "$(jq -c '.trustedWorkspaces' "$FM_AGY_SETTINGS_OVERRIDE")" = '["/home/cap"]' ] \
    || fail "remove did not drop exactly the target path"
  [ "$(jq -c '.otherKey' "$FM_AGY_SETTINGS_OVERRIDE")" = '1' ] \
    || fail "remove clobbered an unrelated settings key"
  pass "remove drops only the exact path and preserves the rest"
}

test_remove_missing_path_is_noop() {
  new_settings '{"trustedWorkspaces":["/home/cap"]}'
  fm_agy_trust_remove /home/cap/never || fail "removing an absent path should be a no-op success"
  [ "$(jq -c '.trustedWorkspaces' "$FM_AGY_SETTINGS_OVERRIDE")" = '["/home/cap"]' ] \
    || fail "removing an absent path changed the list"
  pass "remove of an absent path is a no-op"
}

test_remove_missing_file_is_noop() {
  new_settings
  rm -f "$FM_AGY_SETTINGS_OVERRIDE"
  fm_agy_trust_remove /home/cap/wt || fail "removing from a missing file must succeed as a no-op"
  assert_absent "$FM_AGY_SETTINGS_OVERRIDE" "remove must not create the settings file"
  pass "remove against a missing settings file is a no-op"
}

test_malformed_file_left_untouched() {
  new_settings 'this is not json {'
  if fm_agy_trust_add /home/cap/wt 2>/dev/null; then
    fail "add must fail closed on an unparseable settings file"
  fi
  [ "$(cat "$FM_AGY_SETTINGS_OVERRIDE")" = 'this is not json {' ] \
    || fail "add clobbered an unparseable settings file instead of leaving it untouched"
  pass "an unparseable settings file is left untouched (fail closed)"
}

test_relative_path_refused() {
  new_settings '{"trustedWorkspaces":[]}'
  if fm_agy_trust_add relative/path 2>/dev/null; then
    fail "add must refuse a non-absolute path (agy trust is exact absolute-path match)"
  fi
  pass "a relative path is refused"
}

test_preexisting_path_is_left_untouched() {
  # When the exact path is already present (even oddly duplicated), the ownership
  # short-circuit reports preexisting and does NOT rewrite the captain's file:
  # firstmate does not own that entry and must not mutate it.
  new_settings '{"trustedWorkspaces":["/home/cap/wt-e","/home/cap/wt-e","/home/cap"],"k":1}'
  local before
  before=$(cat "$FM_AGY_SETTINGS_OVERRIDE")
  fm_agy_trust_add /home/cap/wt-e || fail "add should succeed"
  [ "$FM_AGY_TRUST_ADDED" = preexisting ] || fail "a present path must report preexisting"
  [ "$(cat "$FM_AGY_SETTINGS_OVERRIDE")" = "$before" ] \
    || fail "a preexisting add must not modify the captain's settings file"
  pass "a preexisting path is detected and the settings file is left untouched"
}

test_parallel_mutation_preserves_valid_json() {
  # S1: concurrent adds/removes must never corrupt the shared file or lose an
  # entry (the lock serializes read-modify-write atomically).
  new_settings '{"trustedWorkspaces":[]}'
  local i pids=()
  for i in $(seq 1 24); do
    ( fm_agy_trust_add "/home/cap/p$i" >/dev/null 2>&1 ) &
    pids+=("$!")
  done
  # Interleave some removes of a churn path that others re-add.
  for i in $(seq 1 6); do
    ( fm_agy_trust_add /home/cap/churn >/dev/null 2>&1; fm_agy_trust_remove /home/cap/churn >/dev/null 2>&1 ) &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i"; done
  jq -e . "$FM_AGY_SETTINGS_OVERRIDE" >/dev/null 2>&1 \
    || fail "parallel mutation corrupted the settings JSON"
  for i in $(seq 1 24); do
    jq -e --arg p "/home/cap/p$i" '(.trustedWorkspaces // []) | index($p)' "$FM_AGY_SETTINGS_OVERRIDE" >/dev/null 2>&1 \
      || fail "parallel add lost entry /home/cap/p$i"
  done
  pass "parallel add/remove keeps the settings file valid and loses no entry"
}

test_live_lock_is_not_stolen() {
  # B4: the ownership-and-liveness lock must NEVER steal a LIVE holder's lock, even
  # when the holder has held it well past any age threshold (the old age-only
  # breaker stole at 10s). Deterministic: a background holder keeps the lock for
  # 12s; a probe well past 10s must fail to acquire, and only after the holder
  # exits does acquisition succeed.
  new_settings '{"trustedWorkspaces":[]}'
  local lock="$FM_AGY_SETTINGS_OVERRIDE.fm-trust.lock"
  ( fm_lock_try_acquire "$lock" && sleep 12 ) &
  local holder=$!
  sleep 0.5
  fm_lock_try_acquire "$lock" 2>/dev/null && { fm_lock_release "$lock"; kill "$holder" 2>/dev/null; fail "acquired a freshly-held live lock"; }
  sleep 10.5   # now >10s into the live hold - the old breaker would have stolen it
  if fm_lock_try_acquire "$lock" 2>/dev/null; then
    fm_lock_release "$lock"; kill "$holder" 2>/dev/null
    fail "stole a LIVE lock after 10s (age-only breaker regression)"
  fi
  wait "$holder"   # holder exits (releases via its own EXIT? no - it just dies), lock now stale/dead
  # A dead holder's lock is reclaimable, so acquisition now succeeds.
  fm_lock_try_acquire "$lock" 2>/dev/null || fail "could not reclaim a DEAD holder's lock"
  fm_lock_release "$lock"
  pass "a live lock is never stolen (even past 10s); a dead holder's lock is reclaimed"
}

test_add_creates_minimal_file
test_add_reports_created_vs_preexisting
test_add_preserves_other_paths_and_keys
test_add_is_idempotent
test_remove_drops_only_the_exact_path
test_remove_missing_path_is_noop
test_remove_missing_file_is_noop
test_malformed_file_left_untouched
test_relative_path_refused
test_preexisting_path_is_left_untouched
test_parallel_mutation_preserves_valid_json
test_live_lock_is_not_stolen

echo "# all fm-agy-trust-lib tests passed"
