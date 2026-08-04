#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) an open recorded issue is closed after merge and linked to the PR
#   (j) an already-closed recorded issue is left alone
#   (k) issue-close failure reports the merge as successful and exits zero
#   (l) a task with no recorded issue makes no issue API calls
#   (m) issue-state verification failure reports the merge as successful
#   (n) a successful close request that leaves the issue open warns
#   (o) malformed or duplicate recorded issue metadata warns without API calls
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_open_then_closed() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "issue view")
    count_file="$FM_TEST_GH_AXI_LOG.issue-views"
    count=0
    [ -f "$count_file" ] && count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'issue:\n  state: open\n'
    else
      printf 'issue:\n  state: closed\n'
    fi
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_closed() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "issue view") printf 'issue:\n  state: closed\n' ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_close_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "issue view") printf 'issue:\n  state: open\n' ;;
  "issue close") echo 'error: issue close failed' >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "issue view") echo 'error: issue view failed' >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_stays_open() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "issue view") printf 'issue:\n  state: open\n' ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_open_recorded_issue_is_closed_after_merge() {
  local case_dir url
  case_dir=$(make_case issue-open)
  url=https://github.com/example/repo/pull/31
  printf 'issue=42\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_open_then_closed "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "issue-open: merge reconciliation failed"

  grep -qxF "issue close 42 --repo example/repo --reason completed --comment Closed after merge of $url." "$case_dir/gh-axi.log" \
    || fail "issue-open: recorded issue was not closed with the merged PR URL"
  [ "$(grep -c '^issue view 42 --repo example/repo --full$' "$case_dir/gh-axi.log")" -eq 2 ] \
    || fail "issue-open: issue state was not verified before and after closing"
  pass "fm-pr-merge closes an open recorded issue and verifies the close"
}

test_already_closed_recorded_issue_is_left_alone() {
  local case_dir
  case_dir=$(make_case issue-closed)
  printf 'issue=43\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_closed "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "issue-closed: merge reconciliation failed"

  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "issue-closed: already-closed issue received a redundant close call"
  grep -qxF 'issue view 43 --repo example/repo --full' "$case_dir/gh-axi.log" \
    || fail "issue-closed: recorded issue was not verified"
  pass "fm-pr-merge leaves an already-closed recorded issue alone"
}

test_issue_close_failure_keeps_merge_success_unambiguous() {
  local case_dir rc
  case_dir=$(make_case issue-close-fails)
  printf 'issue=44\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_close_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "issue-close-fails: a completed merge must remain successful"
  assert_grep 'warning: PR merge succeeded: https://github.com/example/repo/pull/33' "$case_dir/stderr" \
    "issue-close-fails: warning did not make the successful merge explicit"
  assert_grep 'could not close example/repo#44' "$case_dir/stderr" \
    "issue-close-fails: warning did not identify the failed bookkeeping"
  pass "fm-pr-merge reports issue-close failure without making a completed merge retryable"
}

test_no_recorded_issue_makes_no_issue_calls() {
  local case_dir
  case_dir=$(make_case no-issue)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "no-issue: merge failed"

  assert_no_grep 'issue ' "$case_dir/gh-axi.log" \
    "no-issue: merge path made an issue API call without recorded issue metadata"
  grep -qxF 'pr merge 34 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "no-issue: ordinary merge invocation changed"
  pass "fm-pr-merge preserves the ordinary path when no issue is recorded"
}

test_issue_verification_failure_keeps_merge_success_unambiguous() {
  local case_dir rc
  case_dir=$(make_case issue-view-fails)
  printf 'issue=45\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "issue-view-fails: a completed merge must remain successful"
  assert_grep 'warning: PR merge succeeded: https://github.com/example/repo/pull/35' "$case_dir/stderr" \
    "issue-view-fails: warning did not make the successful merge explicit"
  assert_grep 'could not verify example/repo#45' "$case_dir/stderr" \
    "issue-view-fails: warning did not identify the failed verification"
  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "issue-view-fails: close was attempted without verifying the issue state"
  pass "fm-pr-merge reports issue verification failure without making a completed merge retryable"
}

test_issue_still_open_after_close_request_warns() {
  local case_dir rc
  case_dir=$(make_case issue-stays-open)
  printf 'issue=46\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_stays_open "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/36 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "issue-stays-open: a completed merge must remain successful"
  [ "$(grep -c '^issue view 46 --repo example/repo --full$' "$case_dir/gh-axi.log")" -eq 2 ] \
    || fail "issue-stays-open: issue state was not checked before and after closing"
  assert_grep 'example/repo#46 is still not closed after the close request' "$case_dir/stderr" \
    "issue-stays-open: post-close verification failure was not loud"
  pass "fm-pr-merge warns when an issue remains open after a successful close request"
}

test_invalid_recorded_issue_metadata_warns_without_issue_calls() {
  local case_dir rc name expected
  for name in malformed duplicate; do
    case_dir=$(make_case "issue-metadata-$name")
    case "$name" in
      malformed)
        printf 'issue=abc\n' >> "$case_dir/state/task-x1.meta"
        expected='recorded issue identity is malformed'
        ;;
      duplicate)
        printf 'issue=47\nissue=48\n' >> "$case_dir/state/task-x1.meta"
        expected='task metadata has multiple recorded issues'
        ;;
    esac
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    : > "$case_dir/gh-axi.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/37 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" "issue-metadata-$name: a completed merge must remain successful"
    assert_grep "$expected" "$case_dir/stderr" \
      "issue-metadata-$name: invalid metadata warning was not explicit"
    assert_no_grep 'issue ' "$case_dir/gh-axi.log" \
      "issue-metadata-$name: issue API was called with invalid metadata"
  done
  pass "fm-pr-merge warns on malformed or duplicate recorded issue metadata without making API calls"
}

# The linkage bug this guards: before work_item= records existed, the only
# recorded identity was a bare number, so the close was addressed to whichever
# repository the PR landed in. A project mirrored on one host with its issues
# tracked in another repository had its bookkeeping sent to the wrong tracker.
# The PR here lands in example/repo while the work item declares
# HelloWorldSungin/ark-robinhood, so a regression re-addressing the close to the
# PR's repository fails on both assertions below.
test_work_item_closes_in_its_declared_repository_not_the_pr_repository() {
  local case_dir url
  case_dir=$(make_case work-item-declared)
  url=https://github.com/example/repo/pull/51
  printf 'work_item=declared|github|https://github.com/HelloWorldSungin/ark-robinhood/issues/42\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_open_then_closed "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "work-item-declared: merge reconciliation failed"

  grep -qxF "issue close 42 --repo HelloWorldSungin/ark-robinhood --reason completed --comment Closed after merge of $url." \
    "$case_dir/gh-axi.log" \
    || fail "work-item-declared: the work item was not closed in its own declared repository"
  assert_no_grep '--repo example/repo --reason' "$case_dir/gh-axi.log" \
    "work-item-declared: the close was addressed to the PR's repository instead of the declared tracker"
  [ "$(grep -c '^issue view 42 --repo HelloWorldSungin/ark-robinhood --full$' "$case_dir/gh-axi.log")" -eq 2 ] \
    || fail "work-item-declared: issue state was not verified in the declared repository before and after closing"
  pass "fm-pr-merge closes a work item in its declared repository, not the PR's"
}

# A work item on a forge firstmate does not write back to must leave the merge
# successful and the link intact, and must not be silently retargeted at GitHub.
test_non_github_work_item_is_reported_not_closed() {
  local case_dir rc
  case_dir=$(make_case work-item-gitea)
  printf 'work_item=declared|gitea|https://gitea.example.com/DuckKingOri/BZ-SIM/issues/7\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "work-item-gitea: a completed merge must remain successful"
  assert_grep 'lives on gitea' "$case_dir/stderr" \
    "work-item-gitea: the unsupported write-back was not reported"
  assert_grep 'https://gitea.example.com/DuckKingOri/BZ-SIM/issues/7' "$case_dir/stderr" \
    "work-item-gitea: the warning did not carry the plain link"
  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "work-item-gitea: a non-GitHub work item reached the GitHub close path"
  pass "fm-pr-merge reports a non-GitHub work item instead of closing it"
}

test_self_hosted_github_work_item_is_reported_not_closed() {
  local case_dir rc
  case_dir=$(make_case work-item-self-hosted-github)
  printf 'work_item=declared|github|https://ghe.example.com/o/r/issues/5\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "work-item-self-hosted-github: a completed merge must remain successful"
  assert_grep 'GitHub host ghe.example.com' "$case_dir/stderr" \
    "work-item-self-hosted-github: the unsupported host was not reported"
  assert_grep 'https://ghe.example.com/o/r/issues/5' "$case_dir/stderr" \
    "work-item-self-hosted-github: the warning did not preserve the work-item link"
  assert_no_grep '^issue ' "$case_dir/gh-axi.log" \
    "work-item-self-hosted-github: the self-hosted issue was retargeted at github.com"
  pass "fm-pr-merge reports a self-hosted GitHub work item without retargeting it"
}

test_invalid_or_multiple_work_items_warn_without_issue_calls() {
  local case_dir rc name expected
  for name in malformed multiple; do
    case_dir=$(make_case "work-item-$name")
    case "$name" in
      malformed)
        printf 'work_item=declared|github|not-a-url\n' >> "$case_dir/state/task-x1.meta"
        expected='recorded work item is malformed'
        ;;
      multiple)
        printf 'work_item=declared|github|https://github.com/a/b/issues/1\n' \
          >> "$case_dir/state/task-x1.meta"
        printf 'work_item=declared|github|https://github.com/c/d/issues/2\n' \
          >> "$case_dir/state/task-x1.meta"
        expected='records several work items'
        ;;
    esac
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
    : > "$case_dir/gh-axi.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" "work-item-$name: a completed merge must remain successful"
    assert_grep "$expected" "$case_dir/stderr" \
      "work-item-$name: the warning was not explicit"
    assert_no_grep 'issue ' "$case_dir/gh-axi.log" \
      "work-item-$name: the issue API was called despite unusable work-item metadata"
  done
  pass "fm-pr-merge warns on malformed or multiple work items without making API calls"
}

# A work_item= record carries a whole tracker identity and a legacy issue= line
# carries none, so the record must win whenever both are present.
test_work_item_record_wins_over_legacy_issue_line() {
  local case_dir url
  case_dir=$(make_case work-item-precedence)
  url=https://github.com/example/repo/pull/54
  printf 'issue=99\n' >> "$case_dir/state/task-x1.meta"
  printf 'work_item=declared|github|https://github.com/HelloWorldSungin/ark-robinhood/issues/42\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_open_then_closed "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "work-item-precedence: merge reconciliation failed"

  grep -qxF "issue close 42 --repo HelloWorldSungin/ark-robinhood --reason completed --comment Closed after merge of $url." \
    "$case_dir/gh-axi.log" \
    || fail "work-item-precedence: the declared work item was not the close target"
  assert_no_grep 'issue close 99' "$case_dir/gh-axi.log" \
    "work-item-precedence: the legacy bare number was closed instead of the declared work item"
  pass "fm-pr-merge prefers a declared work item over a legacy bare issue number"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_open_recorded_issue_is_closed_after_merge
test_already_closed_recorded_issue_is_left_alone
test_issue_close_failure_keeps_merge_success_unambiguous
test_no_recorded_issue_makes_no_issue_calls
test_issue_verification_failure_keeps_merge_success_unambiguous
test_issue_still_open_after_close_request_warns
test_invalid_recorded_issue_metadata_warns_without_issue_calls
test_work_item_closes_in_its_declared_repository_not_the_pr_repository
test_non_github_work_item_is_reported_not_closed
test_self_hosted_github_work_item_is_reported_not_closed
test_invalid_or_multiple_work_items_warn_without_issue_calls
test_work_item_record_wins_over_legacy_issue_line
