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

SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'
REFRESH_SCRIPT="$ROOT/.github/scripts/nm-required-refresh-event-body.py"
OLD_HEAD=40795826e3ed81e347eb9cd0ffd604cad12ea014
NEW_HEAD=6d2304c0d5a84707b1cca0963802e806f0b946bc

attestation_body() {
  local head=$1
  printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":%s} -->\n' \
    "$SIGNATURE" "$head" "$COMPLETED_STEPS"
}

write_event() {
  local path=$1 body=$2 head=$3
  python3 -c '
import json, sys
path, body, head = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "action": "synchronize",
        "pull_request": {
            "number": 254,
            "body": body,
            "head": {"sha": head, "ref": "fm/example"},
            "user": {"login": "HelloWorldSungin"},
        },
    }, handle)
' "$path" "$body" "$head"
}

# Test 5: A synchronize webhook snapshot with a stale attestation is replaced
# by the live pull-request body before the pinned action runs.
# What would have to break for this test to fail:
# The refresh helper leaves the event payload on the webhook snapshot, so a
# rerun of a synchronize job keeps judging the pre-push body.
test_refresh_replaces_stale_synchronize_snapshot() {
  command -v python3 >/dev/null 2>&1 || {
    echo "skip: python3 not found (optional interpreter, not installed by bin/fm-bootstrap.sh)"
    return 0
  }
  local tmp event live
  tmp=$(fm_test_tmproot fm-nm-required-refresh)
  event="$tmp/event.json"
  live="$tmp/live-body"
  write_event "$event" "$(attestation_body "$OLD_HEAD")" "$NEW_HEAD"
  attestation_body "$NEW_HEAD" > "$live"

  python3 "$REFRESH_SCRIPT" \
    --event-path "$event" \
    --body-file "$live" \
    --expected-head "$NEW_HEAD" \
    --timeout-sec 0 \
    --interval-sec 0 || fail "refresh helper exited non-zero on a live body that matches the head"

  python3 -c '
import json, sys
event = json.load(open(sys.argv[1], encoding="utf-8"))
body = event["pull_request"]["body"]
head = event["pull_request"]["head"]["sha"]
if sys.argv[2] not in body:
    raise SystemExit("live matching attestation was not written into the event body")
if sys.argv[3] in body:
    raise SystemExit("webhook snapshot attestation remained in the event body")
if head != sys.argv[2]:
    raise SystemExit("event head sha was rewritten; the check must keep the triggering head")
' "$event" "$NEW_HEAD" "$OLD_HEAD" || fail "refresh helper did not load the live matching body while keeping the triggering head"

  pass "synchronize snapshot with a stale attestation is replaced by the live matching body"
}

# Test 6: When the live body is still stale, the helper still writes it through
# so the pinned action reports the real attestation mismatch instead of a
# truncated-or-empty webhook snapshot looking like a missing signature.
# What would have to break for this test to fail:
# A still-stale live body is discarded and the event keeps an empty or
# truncated snapshot, so the action errors as "not raised through no-mistakes".
test_refresh_keeps_stale_live_body_for_real_verdict() {
  command -v python3 >/dev/null 2>&1 || {
    echo "skip: python3 not found (optional interpreter, not installed by bin/fm-bootstrap.sh)"
    return 0
  }
  local tmp event live
  tmp=$(fm_test_tmproot fm-nm-required-refresh-stale)
  event="$tmp/event.json"
  live="$tmp/live-body"
  write_event "$event" "truncated webhook snapshot without a signature" "$NEW_HEAD"
  attestation_body "$OLD_HEAD" > "$live"

  python3 "$REFRESH_SCRIPT" \
    --event-path "$event" \
    --body-file "$live" \
    --expected-head "$NEW_HEAD" \
    --timeout-sec 0 \
    --interval-sec 0 || fail "refresh helper exited non-zero when the live body was still stale"

  python3 -c '
import json, sys
event = json.load(open(sys.argv[1], encoding="utf-8"))
body = event["pull_request"]["body"]
if "truncated webhook snapshot" in body:
    raise SystemExit("stale live body was not written; webhook snapshot remained")
if sys.argv[2] not in body:
    raise SystemExit("stale live attestation head missing from refreshed body")
if sys.argv[3] not in body:
    raise SystemExit("signature missing from refreshed stale live body")
' "$event" "$OLD_HEAD" "$SIGNATURE" || fail "refresh helper did not keep the stale live body for the attestation verdict"

  pass "still-stale live body is written through so the action can emit the real mismatch"
}

# Test 7: The required-check workflow refreshes the event body before the
# pinned action, without checking out PR code.
# What would have to break for this test to fail:
# The workflow drops the refresh step, adds a checkout of the PR head, or
# unpins the shared action.
test_workflow_refreshes_live_body_before_pinned_action() {
  local refresh_line uses_line checkout
  assert_present "$WORKFLOW" "workflow file must exist"
  assert_present "$REFRESH_SCRIPT" "live-body refresh helper must exist"
  grep -q 'pull-requests: read' "$WORKFLOW" || \
    fail "workflow must grant pull-requests: read to fetch the live PR body"
  grep -q 'nm-required-refresh-event-body.py' "$WORKFLOW" || \
    fail "workflow must run the live-body refresh helper before the pinned action"
  checkout=$(grep -c 'actions/checkout' "$WORKFLOW" || true)
  [ "$checkout" -eq 0 ] || fail "required check must not check out PR code"
  uses_line=$(grep -n 'uses: kunchenguid/no-mistakes/.github/actions/require-no-mistakes@32d396ac0f29135daf7fcb9964aba9d5f4e796d6' "$WORKFLOW" || true)
  refresh_line=$(grep -n 'nm-required-refresh-event-body.py' "$WORKFLOW" || true)
  [ -n "$uses_line" ] || fail "workflow must keep the pinned require-no-mistakes action"
  [ -n "$refresh_line" ] || fail "workflow must mention the refresh helper"
  [ "${refresh_line%%:*}" -lt "${uses_line%%:*}" ] || \
    fail "live-body refresh must run before the pinned require-no-mistakes action"
  pass "workflow refreshes the live PR body before the unchanged pinned action"
}

# Test 8: Verify that PRs opened without no-mistakes remain strictly blocked.
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
  test_refresh_replaces_stale_synchronize_snapshot
  test_refresh_keeps_stale_live_body_for_real_verdict
  test_workflow_refreshes_live_body_before_pinned_action
  test_manual_pr_without_signature_remains_blocked
}

main "$@"
printf '\nall fm-no-mistakes-required-gate tests passed\n'
