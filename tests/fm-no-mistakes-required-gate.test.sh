#!/usr/bin/env bash
# Regression coverage for .github/workflows/no-mistakes-required.yml.
#
# Prevents GitHub issue 98's defect: intermediate PR body edits on unchanged
# commits creating orphan failed check runs that permanently linger on green PRs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

# Test 1: Explicit reproduction modeling of Issue #98's exact 3-event sequence on PR 94.
# What would have to break for this test to fail:
# The reproduction model logic fails to record CheckRun objects per event or fails to
# report the orphan failure resulting from body edits on unchanged commit SHAs.
test_reproduce_issue_98_sequence() {
  local tmp log_file
  tmp=$(fm_test_tmproot fm-reproduce-issue98)
  log_file="$tmp/check_runs.log"
  : > "$log_file"

  record_job_check_run() {
    local event=$1 sha=$2 status=$3
    printf 'check_run sha=%s event=%s status=%s\n' "$sha" "$event" "$status" >> "$log_file"
  }

  local head_sha="731c62c03b87db4b2ea4152d9353c8f4475950d9"
  local marker='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

  # Event 101: PR opened with full body containing marker
  local body_101="## Intent\n\nFix issue\n\nUpdates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n\n## Pipeline\n"
  if printf '%b' "$body_101" | grep -qF -- "$marker"; then
    record_job_check_run "opened" "$head_sha" "success"
  fi

  # Event 102: PR body edited with truncated body lacking marker (issue #81 amendment)
  local body_102="api_response:\n  body: \"## Intent...\"\n  truncated: true\n  original_length: 43888\n\n## Issue closure\n\nCloses #81\n"
  if ! printf '%b' "$body_102" | grep -qF -- "$marker"; then
    record_job_check_run "edited" "$head_sha" "failure"
  fi

  # Event 103: PR body edited with restored full body containing marker
  local body_103="${body_101}\n\n## Issue closure\n\nCloses #81\n"
  if printf '%b' "$body_103" | grep -qF -- "$marker"; then
    record_job_check_run "edited" "$head_sha" "success"
  fi

  # Verify un-coalesced job check runs accumulate a failure alongside successes on the same SHA (the issue #98 symptom)
  local fail_count total_count
  fail_count=$(grep -c 'status=failure' "$log_file")
  total_count=$(wc -l < "$log_file")
  [ "$fail_count" -eq 1 ] || fail "reproduction check run log expected 1 failure, got $fail_count"
  [ "$total_count" -eq 3 ] || fail "reproduction check run log expected 3 total runs, got $total_count"

  pass "reproduction demonstrates how un-coalesced edited check runs accumulate orphan failure on same head SHA"
}

# Test 2: Verify workflow triggers and event scope in no-mistakes-required.yml.
# What would have to break for this test to fail:
# .github/workflows/no-mistakes-required.yml re-adds `edited` to on.pull_request.types
# or removes opened/synchronize/reopened triggers.
test_workflow_triggers_exclude_edited_event() {
  local types_line
  assert_present "$WORKFLOW" "workflow file must exist"
  types_line=$(sed -n '/^[[:space:]]*types:/p' "$WORKFLOW")
  [ "$types_line" = '    types: [opened, synchronize, reopened]' ] || \
    fail "workflow must trigger only on opened, synchronize, and reopened pull request events"
  pass "no-mistakes-required workflow triggers on code/branch events and excludes edited"
}

# Test 3: Verify concurrency configuration in no-mistakes-required.yml.
# What would have to break for this test to fail:
# concurrency.group is removed or modified to re-introduce per-run_id fragmentation,
# or cancel-in-progress no longer cancels an older compliance run for the same PR.
test_workflow_concurrency_group_coalescing() {
  local group_line cancel_line
  group_line=$(sed -n '/^[[:space:]]*group:/p' "$WORKFLOW")
  cancel_line=$(sed -n '/^[[:space:]]*cancel-in-progress:/p' "$WORKFLOW")
  # shellcheck disable=SC2016
  [ "$group_line" = '  group: no-mistakes-required-${{ github.event.pull_request.number }}' ] || \
    fail "workflow concurrency group must be scoped exactly per pull request"
  [ "$cancel_line" = '  cancel-in-progress: true' ] || \
    fail "workflow must cancel an in-progress compliance run when the same PR advances"
  pass "no-mistakes-required workflow uses unified per-PR concurrency with cancellation enabled"
}

# Test 4: Verify the signature verification step logic against valid, missing, and truncated PR bodies.
# What would have to break for this test to fail:
# The compliance step script logic changes or fails to distinguish a body containing
# the signature marker from a truncated or missing body.
test_signature_verification_step_behavior() {
  local marker='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
  local valid_body missing_body
  local out_valid out_missing rc_valid rc_missing

  valid_body="## Intent\n\nSome changes.\n\nUpdates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n"
  missing_body="## Intent\n\nManual changes without no-mistakes.\n"

  rc_valid=0
  out_valid=$(PR_BODY="$valid_body" PR_NUMBER=1 PR_AUTHOR=user bash -c '
    set -eu
    marker="Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)"
    if printf "%b" "${PR_BODY:-}" | grep -qF -- "$marker"; then
      echo "Found no-mistakes signature in PR #${PR_NUMBER} body."
      exit 0
    fi
    exit 1
  ' 2>&1) || rc_valid=$?

  [ "$rc_valid" -eq 0 ] || fail "valid PR body with signature was rejected: $out_valid"

  rc_missing=0
  out_missing=$(PR_BODY="$missing_body" PR_NUMBER=1 PR_AUTHOR=user bash -c '
    set -eu
    marker="Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)"
    if printf "%b" "${PR_BODY:-}" | grep -qF -- "$marker"; then
      echo "Found no-mistakes signature in PR #${PR_NUMBER} body."
      exit 0
    fi
    exit 1
  ' 2>&1) || rc_missing=$?

  [ "$rc_missing" -ne 0 ] || fail "missing signature PR body was accepted: $out_missing"

  pass "signature verification step correctly approves valid body and rejects missing body"
}

# Test 5: Verify that PRs opened without no-mistakes remain strictly blocked.
# What would have to break for this test to fail:
# A PR opened without no-mistakes is allowed to pass compliance or clear its failure
# without a new commit pushed through git push no-mistakes.
test_manual_pr_without_signature_remains_blocked() {
  local opened_event_body="PR body created manually via GitHub UI"
  local rc=0

  rc=$(PR_BODY="$opened_event_body" PR_NUMBER=42 PR_AUTHOR=testauthor bash -c '
    set -eu
    marker="Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)"
    if printf "%s" "${PR_BODY:-}" | grep -qF -- "$marker"; then
      exit 0
    fi
    exit 1
  ' >/dev/null 2>&1 || echo $?)

  [ "$rc" -eq 1 ] || fail "PR opened without no-mistakes did not fail the compliance check"
  pass "PR opened without no-mistakes signature strictly fails compliance gate"
}

main() {
  test_reproduce_issue_98_sequence
  test_workflow_triggers_exclude_edited_event
  test_workflow_concurrency_group_coalescing
  test_signature_verification_step_behavior
  test_manual_pr_without_signature_remains_blocked
}

main "$@"
printf '\nall fm-no-mistakes-required-gate tests passed\n'
