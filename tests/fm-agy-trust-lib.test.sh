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
  pass "add creates a minimal settings file with the exact path"
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

test_add_dedups_a_preexisting_duplicate() {
  # A settings file that already listed the path twice should collapse to one on
  # the next add (map(select) removes all copies before appending one).
  new_settings '{"trustedWorkspaces":["/home/cap/wt-e","/home/cap/wt-e","/home/cap"]}'
  fm_agy_trust_add /home/cap/wt-e || fail "add should succeed"
  [ "$(jq -c '.trustedWorkspaces' "$FM_AGY_SETTINGS_OVERRIDE")" = '["/home/cap","/home/cap/wt-e"]' ] \
    || fail "add did not collapse pre-existing duplicates to a single trailing entry"
  pass "add collapses pre-existing duplicate entries"
}

test_add_creates_minimal_file
test_add_preserves_other_paths_and_keys
test_add_is_idempotent
test_remove_drops_only_the_exact_path
test_remove_missing_path_is_noop
test_remove_missing_file_is_noop
test_malformed_file_left_untouched
test_relative_path_refused
test_add_dedups_a_preexisting_duplicate

echo "# all fm-agy-trust-lib tests passed"
