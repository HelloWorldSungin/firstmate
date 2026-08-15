#!/usr/bin/env bash
# Tests for bin/fm-brief-repo-lib.sh - the home-root clone detection.
#
# The firstmate repo's clone is the home root itself rather than a directory
# under projects/. Detecting that fact must be structural (git object DB
# equality), not prose-based (registry entry's English phrase), because the
# latter silently fails when the registry entry is reworded.
#
# The same structural check also fixes the path-style project parameter in
# bin/fm-issue-ref.sh: when --project is a path that matches the home root,
# the lookup resolves to the firstmate repo's registry name by the same
# structural signal.
#
# Each test states what would have to break in the real world for it to fail.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="${ROOT:?}"

# All the tests below need a fixture home that is structurally a firstmate
# checkout. A linked worktree of a temporary repository shares its git object
# DB with that repository, so the structural check passes without registering
# a worktree against the repository under test. The firstmate script under test
# reads FM_ROOT for the comparison target and FM_HOME for the home, so the test
# exercises the real lookup path with both set to distinct fixture paths.
TMP_ROOT=$(fm_test_tmproot fm-brief-repo-lib)
FIXTURE_ROOT="$TMP_ROOT/firstmate"
FM_HOME_DIR="$TMP_ROOT/home"
fm_git_worktree "$FIXTURE_ROOT" "$FM_HOME_DIR" fixture-home 2>/dev/null || {
  fail "could not create a firstmate worktree for the test fixture"
}
mkdir -p "$FM_HOME_DIR/data"

# Write a registry under the fixture home. The argument is the registry body;
# the test passes the registry content directly so each case owns its own
# prose and there is no chance of stale state leaking between tests.
write_registry() {
  local body=$1
  printf '%s\n' "$body" > "$FM_HOME_DIR/data/projects.md"
}

# check_candidate <name> returns 0 when the home root is a candidate for
# the given name, with the fixture home's environment wired up and the
# library sourced inside a subshell so the function is fresh each call.
check_candidate() {  # <name>
  (
    set -u
    FM_ROOT="$FIXTURE_ROOT"
    FM_HOME="$FM_HOME_DIR"
    DATA="$FM_HOME/data"
    export FM_ROOT FM_HOME DATA
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-scope-lib.sh"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-brief-repo-lib.sh"
    fm_brief_repo_home_root_is_candidate "$1"
  )
}

# tally/runner: each individual test function returns 0 on pass and 1 on
# fail. The framework's `fail` helper exits the whole process, which we
# do not want here - we want every test to run so the report shows the
# whole picture. err_exit prints "not ok" and returns 1 so the runner can
# tally without aborting.
err_exit() {
  printf 'not ok - %s\n' "$1" >&2
  return 1
}

# --- structural-detection tests --------------------------------------------

test_home_root_is_candidate_for_firstmate_when_prose_is_reworded() {
  write_registry "- firstmate [no-mistakes +yolo tracker=github:github.com/HelloWorldSungin/firstmate] - firstmate: the home root is the firstmate repo's checkout. (added 2026-01-01)"
  if check_candidate firstmate; then
    pass "the home root is a candidate for firstmate when the registry prose is reworded (structural check works)"
  else
    err_exit "the home root is not a candidate for firstmate despite the prose reword (structural check missing)"
  fi
}

test_home_root_is_candidate_for_firstmate_when_prose_is_minimal() {
  write_registry "- firstmate [no-mistakes +yolo tracker=github:github.com/HelloWorldSungin/firstmate] - firstmate (added 2026-01-01)"
  if check_candidate firstmate; then
    pass "the home root is a candidate for firstmate with the minimal registry entry"
  else
    err_exit "the home root is not a candidate for firstmate despite the structural truth"
  fi
}

test_home_root_is_not_candidate_for_other_names() {
  write_registry "- dotfiles [no-mistakes +yolo tracker=none] - personal dotfiles (added 2026-01-01)"
  if check_candidate dotfiles; then
    err_exit "the home root was a candidate for dotfiles, which is not the home-root clone"
  else
    pass "the home root is not a candidate for non-firstmate names"
  fi
}

test_home_root_is_candidate_for_firstmate_when_prose_uses_different_words() {
  write_registry "- firstmate [no-mistakes +yolo tracker=github:github.com/HelloWorldSungin/firstmate] - the captain's fleet manager; lives above rather than in projects. (added 2026-01-01)"
  if check_candidate firstmate; then
    pass "the home root is a candidate for firstmate regardless of the prose's English"
  else
    err_exit "the candidate check still keys off registry prose"
  fi
}

# --- path-style project parameter test (symptom 2) -------------------------

test_issue_ref_resolves_path_to_firstmate_entry() {
  write_registry "- firstmate [no-mistakes +yolo tracker=github:github.com/HelloWorldSungin/firstmate] - firstmate (added 2026-01-01)"
  local out rc
  set +e
  out=$(FM_ROOT_OVERRIDE="$FIXTURE_ROOT" FM_HOME="$FM_HOME_DIR" \
    "$ROOT/bin/fm-issue-ref.sh" --project "$FM_HOME_DIR" 104 --format brief 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    err_exit "fm-issue-ref.sh --project <home-root-path> 104 refused: $out"
    return 1
  fi
  if [ "$out" != "github:https://github.com/HelloWorldSungin/firstmate/issues/104" ]; then
    err_exit "fm-issue-ref.sh --project <home-root-path> 104 resolved to the wrong identity: $out"
    return 1
  fi
  pass "fm-issue-ref.sh --project <home-root-path> resolves to the firstmate registry entry"
}

test_issue_ref_does_not_resolve_unrelated_path() {
  write_registry "- dotfiles [no-mistakes +yolo tracker=github:github.com/HelloWorldSungin/dotfiles] - dotfiles (added 2026-01-01)"
  local out rc
  set +e
  out=$(FM_ROOT_OVERRIDE="$FIXTURE_ROOT" FM_HOME="$FM_HOME_DIR" \
    "$ROOT/bin/fm-issue-ref.sh" --project "/tmp/some-unrelated-path" '#5' 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    err_exit "fm-issue-ref.sh --project <unrelated-path> '#5' resolved where it should refuse: $out"
    return 1
  fi
  pass "fm-issue-ref.sh --project <unrelated-path> still refuses bare references"
}

FAILED=0
PASSED=0
run_test() {
  local fn=$1
  if "$fn"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
}

run_test test_home_root_is_candidate_for_firstmate_when_prose_is_reworded
run_test test_home_root_is_candidate_for_firstmate_when_prose_is_minimal
run_test test_home_root_is_not_candidate_for_other_names
run_test test_home_root_is_candidate_for_firstmate_when_prose_uses_different_words
run_test test_issue_ref_resolves_path_to_firstmate_entry
run_test test_issue_ref_does_not_resolve_unrelated_path

if [ "$FAILED" -eq 0 ]; then
  printf '\nall fm-brief-repo-lib tests passed\n'
else
  printf '\n%d fm-brief-repo-lib test(s) FAILED\n' "$FAILED" >&2
  exit 1
fi
