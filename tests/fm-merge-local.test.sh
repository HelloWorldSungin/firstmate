#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

test_recorded_continued_branch_lands_locally() {
  local case_dir project wt branch before after out
  case_dir="$TMP_ROOT/continued"
  project="$case_dir/project"
  wt="$case_dir/wt"
  branch=feature/existing-local
  mkdir -p "$case_dir/state" "$project"
  git init -q "$project"
  git -C "$project" symbolic-ref HEAD refs/heads/main
  printf 'base\n' > "$project/base.txt"
  git -C "$project" add base.txt
  git -C "$project" commit -qm base
  git -C "$project" worktree add -q -b "$branch" "$wt" main
  printf 'continued\n' > "$wt/continued.txt"
  git -C "$wt" add continued.txt
  git -C "$wt" commit -qm continued
  before=$(git -C "$project" rev-parse main)
  after=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "project=$project" "mode=local-only" "branch=$branch"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1 2> "$case_dir/stderr")

  [ "$(git -C "$project" rev-parse main)" = "$after" ] \
    || fail "local landing ignored the recorded continued branch"
  [ "$before" != "$after" ] || fail "continued branch fixture did not advance main"
  assert_contains "$out" "merged $branch into local main" \
    "local landing did not report the recorded branch"
  pass "fm-merge-local lands the recorded continued branch"
}

test_recorded_continued_branch_lands_locally
printf '\nall fm-merge-local tests passed\n'
