#!/usr/bin/env bash
# Regression coverage for .github/workflows/no-mistakes-required.yml.
#
# Prevents GitHub issue 98's defect: intermediate PR body edits on unchanged
# commits creating orphan failed check runs that permanently linger on green PRs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-timeout-lib.sh is the single owner of a bounded call. The wait-loop
# case below reads a fixture that only a re-fetching helper drains, so a helper
# that stopped re-fetching would otherwise leave this suite blocked instead of
# reporting the regression.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

# python3 is optional in this repo's toolchain - bin/fm-bootstrap.sh does not
# install it - so the cases that drive the live-body helper skip rather than
# fail without it. The cases that assert shell behavior alone still run, which
# is why this is per-case rather than the top-of-file exit other suites use.
require_python3() {
  command -v python3 >/dev/null 2>&1 && return 0
  echo "skip: python3 not found (optional interpreter, not installed by bin/fm-bootstrap.sh)"
  return 1
}

# A background fixture here blocks on a peer only the process under test
# supplies: a FIFO writer waits for the next fetch, a stub server waits for the
# next request. A regression that stops supplying it parks the fixture holding
# this script's inherited stdout, so each case stops what it started as soon as
# the process under test has finished with it - before any assertion that could
# exit the script. tests/lib.sh's EXIT sweep remains the backstop, not the plan.
FM_TEST_FIXTURE_PIDS=()

track_fixture() {  # <pid>
  FM_TEST_FIXTURE_PIDS+=("$1")
}

stop_fixtures() {
  local pid waited
  for pid in "${FM_TEST_FIXTURE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    waited=0
    while [ "$waited" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 0.05
      waited=$((waited + 1))
    done
    ! kill -0 "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  FM_TEST_FIXTURE_PIDS=()
}

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
HELPER_PATH=.github/scripts/nm-required-refresh-event-body.py
PINNED_ACTION=kunchenguid/no-mistakes/.github/actions/require-no-mistakes@32d396ac0f29135daf7fcb9964aba9d5f4e796d6
OLD_HEAD=40795826e3ed81e347eb9cd0ffd604cad12ea014
NEW_HEAD=6d2304c0d5a84707b1cca0963802e806f0b946bc
MERGE_SHA=b7c0f4d18a6e5c93f2a1d0b8e7c6a5f4d3b2a1c0

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
  require_python3 || return 0
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
  require_python3 || return 0
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

# Test 7: The helper keeps re-fetching until the live attestation binds the
# triggering head, which is the whole reason a synchronize run can see the body
# the pipeline writes after the push it is judging.
# What would have to break for this test to fail:
# The helper returns the first body it reads, or stops re-fetching while its
# wait budget remains, so a synchronize run settles on the pre-push attestation.
test_refresh_waits_for_the_pipeline_body_write() {
  require_python3 || return 0
  local tmp event live rc=0
  tmp=$(fm_test_tmproot fm-nm-required-refresh-wait)
  event="$tmp/event.json"
  live="$tmp/live-body"
  write_event "$event" "$(attestation_body "$OLD_HEAD")" "$NEW_HEAD"

  # A FIFO hands each open exactly one queued body, so the first fetch can only
  # see the pre-push attestation and the matching one is reachable only by
  # re-fetching. The gap between the two writes keeps the second one from
  # joining the first fetch's read, which would concatenate both bodies into a
  # single fetch and hide the re-fetch this case exists to prove.
  mkfifo "$live" || fail "could not create the sequenced live-body fixture"
  {
    attestation_body "$OLD_HEAD" > "$live"
    sleep 0.5
    attestation_body "$NEW_HEAD" > "$live"
  } &
  track_fixture $!

  fm_run_timed 30 python3 "$REFRESH_SCRIPT" \
    --event-path "$event" \
    --body-file "$live" \
    --expected-head "$NEW_HEAD" \
    --timeout-sec 20 \
    --interval-sec 0 || rc=$?
  stop_fixtures
  [ "$rc" -eq 0 ] || \
    fail "refresh helper never reached the later live body (exit $rc)"

  python3 -c '
import json, sys
event = json.load(open(sys.argv[1], encoding="utf-8"))
body = event["pull_request"]["body"]
if sys.argv[2] not in body:
    raise SystemExit("the helper stopped on the first body instead of waiting for the matching one")
if sys.argv[3] in body:
    raise SystemExit("the pre-push attestation survived into the refreshed body")
' "$event" "$NEW_HEAD" "$OLD_HEAD" || fail "refresh helper did not wait for the attestation to bind the triggering head"

  pass "refresh helper re-fetches until the live attestation binds the triggering head"
}

# Test 8: A live body that carries the no-mistakes signature but no attestation
# at all still waits. This is the boundary the early return must not cross: the
# pipeline writes the signature before it writes the attestation, so treating a
# missing attestation as "nothing to wait for" would abandon exactly the PR this
# change exists to carry.
# What would have to break for this test to fail:
# The wait is skipped whenever attestation_head() is empty, or signature
# presence is used as the bind test instead of the attestation head.
test_refresh_waits_when_the_signature_has_no_attestation_yet() {
  require_python3 || return 0
  local tmp event live rc=0
  tmp=$(fm_test_tmproot fm-nm-required-refresh-signature-only)
  event="$tmp/event.json"
  live="$tmp/live-body"
  write_event "$event" "$(attestation_body "$OLD_HEAD")" "$NEW_HEAD"

  mkfifo "$live" || fail "could not create the sequenced live-body fixture"
  {
    printf '%s\n' "$SIGNATURE" > "$live"
    sleep 0.5
    attestation_body "$NEW_HEAD" > "$live"
  } &
  track_fixture $!

  fm_run_timed 30 python3 "$REFRESH_SCRIPT" \
    --event-path "$event" \
    --body-file "$live" \
    --expected-head "$NEW_HEAD" \
    --timeout-sec 20 \
    --interval-sec 0 || rc=$?
  stop_fixtures
  [ "$rc" -eq 0 ] || \
    fail "refresh helper abandoned a signed body whose attestation had not been written yet (exit $rc)"

  python3 -c '
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))["pull_request"]["body"]
if sys.argv[2] not in body:
    raise SystemExit("the helper settled on the signature-only body instead of waiting for the attestation")
' "$event" "$NEW_HEAD" || fail "refresh helper did not wait through a signature-only live body"

  pass "a signed live body with no attestation yet still waits for the attestation to bind"
}

# Test 9: A live body carrying neither the attestation comment nor the
# no-mistakes signature is judged immediately.
# What would have to break for this test to fail:
# A hand-opened PR burns the whole wait budget before the pinned action can say
# "not raised through no-mistakes", because polling is entered for a body no
# amount of waiting can bind.
test_refresh_does_not_wait_on_a_hand_written_body() {
  require_python3 || return 0
  local tmp event live rc=0
  tmp=$(fm_test_tmproot fm-nm-required-refresh-handwritten)
  event="$tmp/event.json"
  live="$tmp/live-body"
  write_event "$event" "$(attestation_body "$OLD_HEAD")" "$NEW_HEAD"

  # Exactly one body is queued on the FIFO, so a second fetch has nothing to
  # pair with and blocks until the outer bound kills it. That turns "polled
  # again" into a failure rather than into a slow pass, without asserting on
  # elapsed wall time.
  mkfifo "$live" || fail "could not create the sequenced live-body fixture"
  printf '%s\n' "please merge this" > "$live" &
  track_fixture $!

  fm_run_timed 30 python3 "$REFRESH_SCRIPT" \
    --event-path "$event" \
    --body-file "$live" \
    --expected-head "$NEW_HEAD" \
    --timeout-sec 120 \
    --interval-sec 0 || rc=$?
  stop_fixtures
  [ "$rc" -eq 0 ] || \
    fail "refresh helper polled for an attestation a hand-written body can never grow (exit $rc)"

  python3 -c '
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))["pull_request"]["body"]
if "please merge this" not in body:
    raise SystemExit("the hand-written live body was not written through for the action to reject")
' "$event" || fail "refresh helper did not hand the hand-written live body to the pinned action"

  pass "a live body with neither no-mistakes marker is judged without polling"
}

# Test 10: An unreachable live-body API leaves the webhook snapshot in the event
# payload instead of failing the step.
# What would have to break for this test to fail:
# A transient api.github.com failure on an otherwise compliant PR aborts the
# helper, so "PR must be raised via no-mistakes" reports failure without the
# pinned action ever reaching a compliance verdict.
test_refresh_degrades_when_the_live_body_is_unreachable() {
  require_python3 || return 0
  local tmp event out rc=0
  tmp=$(fm_test_tmproot fm-nm-required-refresh-unreachable)
  event="$tmp/event.json"
  out="$tmp/helper.out"
  write_event "$event" "$(attestation_body "$OLD_HEAD")" "$NEW_HEAD"

  # Port 1 on the loopback interface refuses immediately, so this is the real
  # transport failure the helper must survive and not a wait on the network.
  # The outer bound must stay well above the helper's own 30s urlopen timeout:
  # on a host that DROPs loopback port 1 instead of refusing it, connect()
  # hangs until that timeout, and an outer bound at or near 30s would race it
  # and report the helper as having failed the check when it had not yet been
  # given the chance to degrade. This is headroom over an observed inner
  # deadline, not a flake bound to shave back.
  GITHUB_TOKEN=stub-token GITHUB_REPOSITORY="HelloWorldSungin/firstmate" \
    GITHUB_GRAPHQL_URL="http://127.0.0.1:1/graphql" \
    fm_run_timed 90 python3 "$REFRESH_SCRIPT" \
      --event-path "$event" \
      --expected-head "$NEW_HEAD" \
      --timeout-sec 0 \
      --interval-sec 0 > "$out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || \
    fail "an unreachable live body failed the required check (exit $rc): $(cat "$out")"

  python3 -c '
import json, sys
event = json.load(open(sys.argv[1], encoding="utf-8"))
if sys.argv[2] not in event["pull_request"]["body"]:
    raise SystemExit("the webhook snapshot was replaced despite an unreachable live body")
if event["pull_request"]["head"]["sha"] != sys.argv[3]:
    raise SystemExit("the triggering head was rewritten")
' "$event" "$OLD_HEAD" "$NEW_HEAD" || fail "the degraded helper did not leave the webhook snapshot intact"

  pass "an unreachable live body leaves the webhook snapshot for the pinned action to judge"
}

# A stub that answers the way GitHub's GraphQL endpoint does: it serves the
# body only for a credentialed request that identifies this pull request and
# selects the body field, and answers with `errors` otherwise. The response
# plan is one token per request it will serve ("data", "502", or "close", which
# accepts the request and drops the connection without answering), so a case can
# model an endpoint that succeeds and then fails without racing a teardown.
write_graphql_stub() {  # <dir>
  cat > "$1/graphql-stub.py" <<'PY'
#!/usr/bin/env python3
"""Serve a planned sequence of GitHub-shaped GraphQL answers."""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, body_file, log_file = sys.argv[1], sys.argv[2], sys.argv[3]
plan = sys.argv[4].split(",")
with open(body_file, encoding="utf-8") as handle:
    live_body = handle.read()
EXPECTED_VARIABLES = {"o": "HelloWorldSungin", "n": "firstmate", "p": 254}
served = []


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        request = json.loads(self.rfile.read(length).decode("utf-8"))
        with open(log_file, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(request) + "\n")
        mode = plan[len(served)] if len(served) < len(plan) else plan[-1]
        served.append(mode)
        if mode == "close":
            self.close_connection = True
            return
        if mode == "502":
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        query = "".join((request.get("query") or "").split())
        if not (self.headers.get("Authorization") or "").startswith("Bearer "):
            answer = {"errors": [{"message": "Bad credentials"}]}
        elif request.get("variables") != EXPECTED_VARIABLES:
            answer = {"errors": [{"message": "Could not resolve to a PullRequest"}]}
        elif "pullRequest(number:$p){body}" not in query:
            answer = {"errors": [{"message": "Field doesn't exist on type 'PullRequest'"}]}
        else:
            answer = {"data": {"repository": {"pullRequest": {"body": live_body}}}}
        encoded = json.dumps(answer).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".partial", "w", encoding="utf-8") as handle:
    handle.write(str(server.server_port))
os.rename(port_file + ".partial", port_file)
for _ in plan:
    server.handle_request()
server.server_close()
PY
}

start_graphql_stub() {  # <dir> <response plan>
  local dir=$1 plan=$2 waits=200
  python3 "$dir/graphql-stub.py" "$dir/port" "$dir/live-body" "$dir/requests.log" "$plan" &
  track_fixture $!
  while [ ! -s "$dir/port" ] && [ "$waits" -gt 0 ]; do
    sleep 0.05
    waits=$((waits - 1))
  done
  [ -s "$dir/port" ] && return 0
  stop_fixtures
  fail "the GraphQL stub never published a port"
}

# Test 11: A successful live fetch over the GraphQL transport lands the live
# body in the event payload. Every other helper case supplies --body-file,
# which returns before the request is ever built, so without this the whole
# production fetch path is unexercised - and since a failed fetch now degrades
# silently to the webhook snapshot, a broken request would leave this suite
# green while the required check kept failing.
# What would have to break for this test to fail:
# The request stops identifying the pull request, drops its bearer credential,
# or stops selecting the body field, so GitHub answers with errors and the
# helper degrades to the snapshot instead of refreshing it.
test_refresh_loads_the_live_body_over_graphql() {
  require_python3 || return 0
  local tmp event waits rc=0
  tmp=$(fm_test_tmproot fm-nm-required-refresh-graphql)
  event="$tmp/event.json"
  write_event "$event" "$(attestation_body "$OLD_HEAD")" "$NEW_HEAD"
  attestation_body "$NEW_HEAD" > "$tmp/live-body"

  write_graphql_stub "$tmp"
  start_graphql_stub "$tmp" data

  GITHUB_TOKEN=stub-token GITHUB_REPOSITORY="HelloWorldSungin/firstmate" \
    GITHUB_GRAPHQL_URL="http://127.0.0.1:$(cat "$tmp/port")/graphql" \
    fm_run_timed 90 python3 "$REFRESH_SCRIPT" \
      --event-path "$event" \
      --expected-head "$NEW_HEAD" \
      --timeout-sec 0 \
      --interval-sec 0 > "$tmp/helper.out" 2>&1 || rc=$?
  stop_fixtures
  [ "$rc" -eq 0 ] || fail "the live GraphQL fetch failed (exit $rc): $(cat "$tmp/helper.out")"

  assert_present "$tmp/requests.log" "the helper never reached the GraphQL endpoint"
  python3 -c '
import json, sys
event = json.load(open(sys.argv[1], encoding="utf-8"))
body = event["pull_request"]["body"]
if sys.argv[2] not in body:
    raise SystemExit("the live GraphQL body did not reach the event payload")
if sys.argv[3] in body:
    raise SystemExit("the webhook snapshot survived a successful live fetch")
if event["pull_request"]["head"]["sha"] != sys.argv[2]:
    raise SystemExit("the triggering head was rewritten")
' "$event" "$NEW_HEAD" "$OLD_HEAD" || \
    fail "a successful live fetch did not replace the webhook snapshot: $(cat "$tmp/helper.out")"

  pass "a successful live GraphQL fetch lands the live body in the event payload"
}

# Test 12: A fetch that fails after an earlier one succeeded still writes the
# last body through, but says so. Without the warning the operator sees the
# same "attestation head_sha does not match" text issue #258 was filed over,
# with nothing to distinguish a budget that was genuinely exhausted from a wait
# an API error cut short seconds in.
# What would have to break for this test to fail:
# The aborted-wait branch falls through silently and the run reports a clean
# refresh over a body the helper had not finished waiting on.
test_refresh_warns_when_an_api_failure_cuts_the_wait_short() {
  require_python3 || return 0
  local tmp event rc=0
  tmp=$(fm_test_tmproot fm-nm-required-refresh-aborted-wait)
  event="$tmp/event.json"
  write_event "$event" "truncated webhook snapshot" "$NEW_HEAD"
  attestation_body "$OLD_HEAD" > "$tmp/live-body"

  # The first fetch returns a signed body still bound to the previous head, so
  # the helper keeps waiting; the second gets a 502, which is the transient the
  # full 120s budget is meant to ride out.
  write_graphql_stub "$tmp"
  start_graphql_stub "$tmp" data,502

  GITHUB_TOKEN=stub-token GITHUB_REPOSITORY="HelloWorldSungin/firstmate" \
    GITHUB_GRAPHQL_URL="http://127.0.0.1:$(cat "$tmp/port")/graphql" \
    fm_run_timed 90 python3 "$REFRESH_SCRIPT" \
      --event-path "$event" \
      --expected-head "$NEW_HEAD" \
      --timeout-sec 120 \
      --interval-sec 0 > "$tmp/helper.out" 2>&1 || rc=$?
  stop_fixtures
  [ "$rc" -eq 0 ] || \
    fail "a mid-wait API failure reddened the required check (exit $rc): $(cat "$tmp/helper.out")"

  assert_grep "::warning::" "$tmp/helper.out" \
    "a wait cut short by an API failure must be annotated, not reported as a clean refresh"
  python3 -c '
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))["pull_request"]["body"]
if sys.argv[2] not in body:
    raise SystemExit("the last body read was not written through for the action to judge")
if "truncated webhook snapshot" in body:
    raise SystemExit("the webhook snapshot survived a fetch that had already succeeded once")
' "$event" "$OLD_HEAD" || fail "the aborted wait did not keep the last live body"

  pass "an API failure mid-wait annotates the run instead of reporting a clean refresh"
}

# Test 13: A transport that accepts the request and then drops the connection
# degrades to the webhook snapshot. urllib wraps only the errors raised while
# sending into URLError, so a response that never arrives surfaces as
# http.client.RemoteDisconnected instead - an ordinary GitHub transient that
# must not red a required merge gate.
# What would have to break for this test to fail:
# The degrade narrows back to the send-side errors, so a reset mid-response
# aborts the helper with a traceback, the step fails under set -eu, and "PR
# must be raised via no-mistakes" reports failure with no verdict at all -
# strictly worse than the snapshot verdict this change replaced.
test_refresh_degrades_when_the_response_never_arrives() {
  require_python3 || return 0
  local tmp event rc=0
  tmp=$(fm_test_tmproot fm-nm-required-refresh-dropped)
  event="$tmp/event.json"
  write_event "$event" "$(attestation_body "$OLD_HEAD")" "$NEW_HEAD"
  attestation_body "$NEW_HEAD" > "$tmp/live-body"

  write_graphql_stub "$tmp"
  start_graphql_stub "$tmp" close

  GITHUB_TOKEN=stub-token GITHUB_REPOSITORY="HelloWorldSungin/firstmate" \
    GITHUB_GRAPHQL_URL="http://127.0.0.1:$(cat "$tmp/port")/graphql" \
    fm_run_timed 90 python3 "$REFRESH_SCRIPT" \
      --event-path "$event" \
      --expected-head "$NEW_HEAD" \
      --timeout-sec 0 \
      --interval-sec 0 > "$tmp/helper.out" 2>&1 || rc=$?
  stop_fixtures
  [ "$rc" -eq 0 ] || \
    fail "a dropped response reddened the required check (exit $rc): $(cat "$tmp/helper.out")"

  assert_grep "::warning::" "$tmp/helper.out" \
    "a dropped response must be annotated as a degrade rather than abort the helper"
  python3 -c '
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))["pull_request"]["body"]
if sys.argv[2] not in body:
    raise SystemExit("the webhook snapshot was replaced despite a response that never arrived")
if sys.argv[3] in body:
    raise SystemExit("a body the transport never delivered reached the event payload")
' "$event" "$OLD_HEAD" "$NEW_HEAD" || fail "the degraded helper did not leave the webhook snapshot intact"

  pass "a response the transport drops mid-flight degrades to the webhook snapshot"
}

# Normalize the workflow into a job -> ordered-steps model, so the required
# check's shape is asserted as meaning rather than as file text. The parser
# refuses anything outside the block-YAML subset these workflows use, so it can
# never silently model a construct it does not understand.
workflow_model_json() {  # <dir>: writes <dir>/model.json
  local dir=$1
  cat > "$dir/gha-model.py" <<'PY'
#!/usr/bin/env python3
"""Print a GitHub Actions workflow as a normalized JSON document."""

import json
import re
import sys

KEY_RE = re.compile(r"^(?P<key>[A-Za-z_][A-Za-z0-9_.-]*):(?:\s+(?P<value>.*))?$")
BLOCK_STYLES = ("|", "|-", "|+", ">", ">-", ">+")


class Workflow:
    def __init__(self, text):
        self.lines = text.split("\n")

    def indent(self, i):
        line = self.lines[i]
        return len(line) - len(line.lstrip(" "))

    def next_significant(self, i):
        while i < len(self.lines):
            stripped = self.lines[i].strip()
            if stripped and not stripped.startswith("#"):
                return i
            i += 1
        return len(self.lines)

    def scalar(self, raw):
        raw = raw.strip()
        if raw[:1] not in ("'", '"'):
            cut = raw.find(" #")
            if cut >= 0:
                raw = raw[:cut].rstrip()
        if len(raw) > 1 and raw[0] == raw[-1] and raw[0] in "'\"":
            return raw[1:-1]
        if raw.startswith("[") and raw.endswith("]"):
            inner = raw[1:-1].strip()
            return [self.scalar(part) for part in inner.split(",")] if inner else []
        return raw

    def block_scalar(self, i, key_indent, style):
        collected = []
        while i < len(self.lines):
            if self.lines[i].strip() == "":
                collected.append("")
                i += 1
                continue
            if self.indent(i) <= key_indent:
                break
            collected.append(self.lines[i])
            i += 1
        while collected and collected[-1] == "":
            collected.pop()
        pad = min(
            (len(line) - len(line.lstrip(" ")) for line in collected if line.strip()),
            default=0,
        )
        dedented = [line[pad:] if line.strip() else "" for line in collected]
        return (" " if style.startswith(">") else "\n").join(dedented), i

    def node(self, i, parent_indent):
        i = self.next_significant(i)
        if i >= len(self.lines) or self.indent(i) <= parent_indent:
            return None, i
        indent = self.indent(i)
        if self.lines[i][indent:].startswith("- "):
            return self.sequence(i, indent)
        return self.mapping(i, indent)

    def mapping(self, i, indent):
        out = {}
        while True:
            i = self.next_significant(i)
            if i >= len(self.lines) or self.indent(i) != indent:
                break
            match = KEY_RE.match(self.lines[i][indent:])
            if not match:
                break
            raw = (match.group("value") or "").strip()
            i += 1
            if raw in BLOCK_STYLES:
                value, i = self.block_scalar(i, indent, raw)
            elif raw == "":
                value, i = self.node(i, indent)
            else:
                value = self.scalar(raw)
            out[match.group("key")] = value
        return out, i

    def sequence(self, i, indent):
        items = []
        while True:
            i = self.next_significant(i)
            if i >= len(self.lines) or self.indent(i) != indent:
                break
            rest = self.lines[i][indent:]
            if not rest.startswith("- "):
                break
            self.lines[i] = " " * (indent + 2) + rest[2:]
            if KEY_RE.match(self.lines[i][indent + 2:]):
                item, i = self.mapping(i, indent + 2)
            else:
                item, i = self.scalar(self.lines[i][indent + 2:]), i + 1
            items.append(item)
        return items, i

    def document(self):
        value, i = self.mapping(0, 0)
        i = self.next_significant(i)
        if i < len(self.lines):
            raise SystemExit(f"unmodeled workflow construct on line {i + 1}: {self.lines[i]!r}")
        return value


with open(sys.argv[1], encoding="utf-8") as handle:
    json.dump(Workflow(handle.read()).document(), sys.stdout, indent=2, sort_keys=True)
PY
  python3 "$dir/gha-model.py" "$WORKFLOW" > "$dir/model.json" || \
    fail "the required-check workflow does not parse as GitHub Actions block YAML"
}

# Test 14: The required check's own job refreshes the live body before the
# pinned action runs, fetches the helper from the merge commit its workflow
# definition came from, declares its wait budget, checks out no repository
# code, and treats an unreachable helper as a degrade to the webhook snapshot
# rather than a failed required check.
# What would have to break for this test to fail:
# The refresh step is dropped, reordered after the pinned action, moved into
# another job, or made to check out code; the shared action is unpinned; the
# helper is fetched at the PR head SHA, which carries it only once that branch
# itself takes main; the wait budget drifts back to the helper's defaults; or
# an unreachable helper fails the step and so reds "PR must be raised via
# no-mistakes" with no compliance verdict at all.
test_workflow_refreshes_live_body_before_pinned_action() {
  require_python3 || return 0
  local tmp fakebin event live step
  assert_present "$WORKFLOW" "workflow file must exist"
  assert_present "$REFRESH_SCRIPT" "live-body refresh helper must exist"
  tmp=$(fm_test_tmproot fm-nm-required-workflow)
  workflow_model_json "$tmp"

  # The expected env values are GitHub Actions expressions the workflow must
  # carry verbatim, not shell parameters for this suite to expand.
  # shellcheck disable=SC2016
  python3 -c '
import json, sys
model = json.load(open(sys.argv[1], encoding="utf-8"))
helper, pin = sys.argv[2], sys.argv[3]
jobs = {name: (body.get("steps") or []) for name, body in (model.get("jobs") or {}).items()}
if not jobs:
    raise SystemExit("the workflow declares no jobs")
for name, steps in jobs.items():
    for step in steps:
        if (step.get("uses") or "").startswith("actions/checkout"):
            raise SystemExit(f"job {name} checks out repository code on the required check")
owners = [name for name, steps in jobs.items() if any(s.get("uses") == pin for s in steps)]
if len(owners) != 1:
    raise SystemExit(f"exactly one job must run the pinned action, found {owners}")
steps = jobs[owners[0]]
verify = next(i for i, s in enumerate(steps) if s.get("uses") == pin)
refresh = [i for i, s in enumerate(steps) if helper in (s.get("run") or "")]
if not refresh:
    raise SystemExit(f"job {owners[0]} runs the pinned action with no live-body refresh step")
if max(refresh) >= verify:
    raise SystemExit("the live-body refresh must run before the pinned action in that same job")
env = steps[refresh[0]].get("env") or {}
if env.get("NM_REQUIRED_EXPECTED_HEAD") != "${{ github.event.pull_request.head.sha }}":
    raise SystemExit(f"the refresh step must judge the triggering head, got {env!r}")
if env.get("NM_REQUIRED_SCRIPT_REF") != "${{ github.sha }}":
    raise SystemExit(
        "the helper must be fetched from the pull-request merge commit, which "
        "carries the copy on the base branch; a PR head ref carries it only "
        f"once that branch itself takes main, got {env!r}"
    )
if (env.get("NM_REQUIRED_BODY_TIMEOUT_SEC"), env.get("NM_REQUIRED_BODY_INTERVAL_SEC")) != ("120", "8"):
    raise SystemExit(
        "the wait budget belongs in the workflow, not in the helper defaults: "
        f"expected 120s at an 8s interval, got {env!r}"
    )
if (model.get("permissions") or {}).get("pull-requests") != "read":
    raise SystemExit("the workflow must grant pull-requests: read to read the live body")
open(sys.argv[4], "w", encoding="utf-8").write(steps[refresh[0]]["run"])
' "$tmp/model.json" "$HELPER_PATH" "$PINNED_ACTION" "$tmp/refresh-step.sh" || \
    fail "the required check does not refresh the live body ahead of the pinned action"

  fakebin="$tmp/fakebin"
  mkdir -p "$fakebin" "$tmp/runner"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ -z "${CURL_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$CURL_URL_LOG"
[ "${CURL_EXIT:-0}" -eq 0 ] || exit "${CURL_EXIT}"
cp "${CURL_SERVE_FILE:?}" "$out"
SH
  chmod +x "$fakebin/curl"

  step="$tmp/refresh-step.sh"
  event="$tmp/event.json"
  live="$tmp/live-body"
  attestation_body "$NEW_HEAD" > "$live"
  write_event "$event" "$(attestation_body "$OLD_HEAD")" "$NEW_HEAD"

  PATH="$fakebin:$PATH" CURL_SERVE_FILE="$REFRESH_SCRIPT" \
    CURL_URL_LOG="$tmp/curl-url.log" RUNNER_TEMP="$tmp/runner" \
    GITHUB_API_URL="https://api.github.invalid" GITHUB_TOKEN=stub-token \
    GITHUB_REPOSITORY="HelloWorldSungin/firstmate" \
    NM_REQUIRED_SCRIPT_REF="$MERGE_SHA" GITHUB_EVENT_PATH="$event" \
    NM_REQUIRED_EXPECTED_HEAD="$NEW_HEAD" NM_REQUIRED_BODY_FILE="$live" \
    NM_REQUIRED_BODY_TIMEOUT_SEC=0 NM_REQUIRED_BODY_INTERVAL_SEC=0 \
    bash "$step" > "$tmp/reachable.out" 2>&1 || \
    fail "the refresh step failed with a reachable helper: $(cat "$tmp/reachable.out")"

  assert_grep "?ref=$MERGE_SHA" "$tmp/curl-url.log" \
    "the step must fetch the helper at the ref its workflow definition came from"
  python3 -c '
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))["pull_request"]["body"]
if sys.argv[2] not in body:
    raise SystemExit("the executed step left the webhook snapshot in the event payload")
' "$event" "$NEW_HEAD" || fail "the executed refresh step did not load the live body"

  write_event "$event" "$(attestation_body "$OLD_HEAD")" "$NEW_HEAD"
  PATH="$fakebin:$PATH" CURL_SERVE_FILE="$REFRESH_SCRIPT" CURL_EXIT=22 \
    RUNNER_TEMP="$tmp/runner" GITHUB_API_URL="https://api.github.invalid" \
    GITHUB_TOKEN=stub-token GITHUB_REPOSITORY="HelloWorldSungin/firstmate" \
    NM_REQUIRED_SCRIPT_REF="$MERGE_SHA" GITHUB_EVENT_PATH="$event" \
    NM_REQUIRED_EXPECTED_HEAD="$NEW_HEAD" NM_REQUIRED_BODY_FILE="$live" \
    NM_REQUIRED_BODY_TIMEOUT_SEC=0 NM_REQUIRED_BODY_INTERVAL_SEC=0 \
    bash "$step" > "$tmp/unreachable.out" 2>&1 || \
    fail "an unreachable helper reddened the required check instead of degrading: $(cat "$tmp/unreachable.out")"

  python3 -c '
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))["pull_request"]["body"]
if sys.argv[2] not in body:
    raise SystemExit("an unreachable helper must leave the webhook snapshot for the action to judge")
' "$event" "$OLD_HEAD" || fail "the degraded step did not leave the webhook snapshot intact"

  pass "the required check refreshes the live body before the pinned action and degrades instead of reddening"
}

# Test 15: Verify that PRs opened without no-mistakes remain strictly blocked.
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
  test_refresh_waits_for_the_pipeline_body_write
  test_refresh_waits_when_the_signature_has_no_attestation_yet
  test_refresh_does_not_wait_on_a_hand_written_body
  test_refresh_degrades_when_the_live_body_is_unreachable
  test_refresh_loads_the_live_body_over_graphql
  test_refresh_warns_when_an_api_failure_cuts_the_wait_short
  test_refresh_degrades_when_the_response_never_arrives
  test_workflow_refreshes_live_body_before_pinned_action
  test_manual_pr_without_signature_remains_blocked
}

main "$@"
printf '\nall fm-no-mistakes-required-gate tests passed\n'
