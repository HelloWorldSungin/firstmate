#!/usr/bin/env bash
# Behavior tests for the legacy run-attribution transition.
#
# These tests pin the only accepted migration proof, the refusal of inference,
# detect-only immutability, and startup discovery through fm-bootstrap.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRANSITION="$ROOT/bin/fm-run-attribution-legacy-transition.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-run-attribution-legacy-transition)
GOOD_HEAD=1111111111111111111111111111111111111111
OTHER_HEAD=2222222222222222222222222222222222222222
fm_git_identity fmtest fmtest@example.invalid

make_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/fakebin"
  printf '%s\n' manual > "$dir/config/backlog-backend"
  : > "$dir/gh.log"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_GH_LOG:?}"
[ -z "${FM_FAKE_META_REWRITE:-}" ] || printf 'status_concurrent=changed\n' >> "$FM_FAKE_META_REWRITE"
case "$*" in
  *repos/o/r/pulls/1*) printf 'fm/proven-task\t%s\n' "${FM_FAKE_GOOD_HEAD:?}" ;;
  *repos/o/r/pulls/2*) printf 'fm/mismatch-task\t%s\n' "${FM_FAKE_OTHER_HEAD:?}" ;;
  *repos/o/r/pulls/3*) exit 1 ;;
  *repos/o/r/pulls/9*)
    sleep "${FM_FAKE_GH_SLEEP:-0}"
    printf 'fm/slow-lookup\t%s\n' "${FM_FAKE_GOOD_HEAD:?}"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  printf '%s\n' "$dir"
}

make_worktree_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

write_legacy_meta() {  # <home> <id> <worktree> [extra lines...]
  local home=$1 id=$2 worktree=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" \
    "window=fm:fm-$id" \
    "worktree=$worktree" \
    "project=$worktree" \
    "kind=ship" \
    "mode=no-mistakes" \
    "harness=claude" \
    "$@"
}

run_transition() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_GH_LOG="$home/gh.log" FM_FAKE_GOOD_HEAD="$GOOD_HEAD" FM_FAKE_OTHER_HEAD="$OTHER_HEAD" \
    PATH="$home/fakebin:$PATH" "$TRANSITION" "$@"
}

# The exact downstream contract a published branch= must not break: the parser
# every PR poll artifact check and the legacy PR-check migration run on the same
# task metadata.
meta_pr_identity_parses() {  # <meta>
  bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_metadata_identity_parse "$2"' _ "$ROOT" "$1"
}

meta_line_number() {  # <meta> <key>
  grep -n "^$2=" "$1" | head -1 | cut -d: -f1
}

# Fails if migration uses ambient placement instead of the recorded PR plus its
# matching recorded/current head, or if publication does not persist that proof.
test_matching_pr_head_is_the_only_migration_proof() {
  local home wt before out after
  home=$(make_home proven)
  wt="$home/wt"
  make_worktree_on_branch "$wt" fm/reallocated-ambient
  write_legacy_meta "$home" proven-task "$wt" \
    'pr=https://github.com/o/r/pull/1' "pr_head=$GOOD_HEAD"
  before=$(cat "$home/state/proven-task.meta")

  out=$(run_transition "$home")
  assert_contains "$out" \
    "BOOTSTRAP_INFO: run attribution transition: task proven-task recorded branch fm/proven-task from matching GitHub PR head" \
    "matching PR-head proof did not migrate the legacy record"
  assert_not_contains "$out" 'RUN_ATTRIBUTION:' \
    "a proven migrated record was still diagnosed as unreadable"
  after=$(cat "$home/state/proven-task.meta")
  [ "$(grep -v '^branch=' "$home/state/proven-task.meta")" = "$before" ] \
    || fail "migration changed more than the proven branch binding"
  [ "$(grep -c '^branch=fm/proven-task$' "$home/state/proven-task.meta")" = 1 ] \
    || fail "migration did not record exactly one proven branch line"
  assert_not_contains "$after" 'branch=fm/reallocated-ambient' \
    "migration copied the pooled worktree's ambient branch"
  [ "$(git -C "$wt" symbolic-ref --short HEAD)" = fm/reallocated-ambient ] \
    || fail "test setup lost the deliberately conflicting ambient branch"

  out=$(run_transition "$home")
  [ -z "$out" ] || fail "an already transitioned record was not idempotently silent: $out"
  pass "legacy run attribution migrates only from a matching recorded GitHub PR head"
}

# Fails if branch= is published after the trailing pr=/pr_head= identity block,
# which would make fm_pr_metadata_identity_parse reject the record, disarm its
# merge poll, and let the next locked session quarantine the poll for good.
test_published_branch_preserves_pr_identity_ordering() {
  local home meta branch_line pr_line
  home=$(make_home ordering)
  mkdir -p "$home/wt"
  write_legacy_meta "$home" proven-task "$home/wt" \
    'pr=https://github.com/o/r/pull/1' "pr_head=$GOOD_HEAD"
  meta="$home/state/proven-task.meta"
  meta_pr_identity_parses "$meta" || fail "test setup started from an unparsable PR identity"

  run_transition "$home" >/dev/null
  grep -q '^branch=fm/proven-task$' "$meta" || fail "test setup did not migrate the provable record"

  meta_pr_identity_parses "$meta" \
    || fail "published branch= invalidated the record's PR identity"
  branch_line=$(meta_line_number "$meta" branch)
  pr_line=$(meta_line_number "$meta" pr)
  [ "$branch_line" -lt "$pr_line" ] \
    || fail "branch= was published at line $branch_line, after pr= at line $pr_line"
  [ "$(tail -n 2 "$meta")" = "pr=https://github.com/o/r/pull/1"$'\n'"pr_head=$GOOD_HEAD" ] \
    || fail "migration displaced the canonical trailing PR identity block"
  pass "published branch identity keeps the canonical trailing PR identity block last"
}

# Fails if the sweep spends one lookup timeout per candidate instead of one
# whole-run budget, which would put a hung forge on the session-start critical
# path once per legacy PR-bearing task, every session.
test_sweep_budget_bounds_every_candidate_together() {
  local home id out lookups before_a before_b before_c
  home=$(make_home sweep-budget)
  for id in slow-a slow-b slow-c; do
    mkdir -p "$home/$id-wt"
    write_legacy_meta "$home" "$id" "$home/$id-wt" \
      'pr=https://github.com/o/r/pull/9' "pr_head=$GOOD_HEAD"
  done
  before_a=$(cat "$home/state/slow-a.meta")
  before_b=$(cat "$home/state/slow-b.meta")
  before_c=$(cat "$home/state/slow-c.meta")

  out=$(FM_RUN_ATTRIBUTION_MIGRATION_BUDGET=2 FM_RUN_ATTRIBUTION_MIGRATION_TIMEOUT=10 \
    FM_FAKE_GH_SLEEP=5 run_transition "$home")

  lookups=$(grep -c . "$home/gh.log" || true)
  [ "$lookups" -lt 3 ] \
    || fail "every candidate paid its own lookup timeout: $lookups forge lookups for 3 candidates"
  for id in slow-a slow-b slow-c; do
    assert_contains "$out" "RUN_ATTRIBUTION: task $id: legacy no-mistakes metadata has no proven branch=" \
      "$id was not left diagnosed after the sweep budget was spent"
  done
  assert_not_contains "$out" 'BOOTSTRAP_INFO:' \
    "a candidate migrated from a lookup the sweep budget did not allow"
  [ "$(cat "$home/state/slow-a.meta")" = "$before_a" ] \
    || fail "a budget-bounded lookup changed the legacy record"
  [ "$(cat "$home/state/slow-b.meta")" = "$before_b" ] \
    || fail "an unattempted candidate changed the legacy record"
  [ "$(cat "$home/state/slow-c.meta")" = "$before_c" ] \
    || fail "an unattempted candidate changed the legacy record"
  pass "one sweep budget bounds every candidate lookup and leaves each diagnosed"
}

# Fails if a task-id naming match, ambient branch, work item, stale PR-head
# snapshot, failed lookup, or unsupported forge starts authorizing branch=.
test_unproven_records_remain_byte_identical_and_visible() {
  local home wt before_no_proof before_mismatch before_failed before_gitlab out
  home=$(make_home refused)

  wt="$home/no-proof-wt"
  make_worktree_on_branch "$wt" fm/no-proof
  write_legacy_meta "$home" no-proof "$wt" \
    'work_item=github:https://github.com/o/r/issues/9'
  write_legacy_meta "$home" mismatch-task "$home/mismatch-wt" \
    'pr=https://github.com/o/r/pull/2' "pr_head=$GOOD_HEAD"
  write_legacy_meta "$home" failed-lookup "$home/failed-wt" \
    'pr=https://github.com/o/r/pull/3' "pr_head=$GOOD_HEAD"
  write_legacy_meta "$home" gitlab-task "$home/gitlab-wt" \
    'pr=https://gitlab.example.com/g/r/-/merge_requests/4' "pr_head=$GOOD_HEAD"
  mkdir -p "$home/mismatch-wt" "$home/failed-wt" "$home/gitlab-wt"

  before_no_proof=$(cat "$home/state/no-proof.meta")
  before_mismatch=$(cat "$home/state/mismatch-task.meta")
  before_failed=$(cat "$home/state/failed-lookup.meta")
  before_gitlab=$(cat "$home/state/gitlab-task.meta")
  out=$(run_transition "$home")

  for id in no-proof mismatch-task failed-lookup gitlab-task; do
    assert_contains "$out" \
      "RUN_ATTRIBUTION: task $id: legacy no-mistakes metadata has no proven branch=; any run is unattributable until task cleanup" \
      "$id was not named as an unreadable legacy task"
  done
  [ "$(cat "$home/state/no-proof.meta")" = "$before_no_proof" ] \
    || fail "ambient branch plus work item changed the legacy record"
  [ "$(cat "$home/state/mismatch-task.meta")" = "$before_mismatch" ] \
    || fail "a stale recorded PR head changed the legacy record"
  [ "$(cat "$home/state/failed-lookup.meta")" = "$before_failed" ] \
    || fail "a failed proof lookup changed the legacy record"
  [ "$(cat "$home/state/gitlab-task.meta")" = "$before_gitlab" ] \
    || fail "an unsupported forge changed the legacy record"
  assert_not_contains "$out" 'BOOTSTRAP_INFO:' \
    "an unproven record was reported as migrated"
  pass "unproven legacy records stay unchanged and are all named by the diagnostic"
}

# Fails if an API lookup can overwrite a concurrent metadata update or publish
# branch identity against bytes other than the exact record it verified.
test_concurrent_metadata_change_refuses_publication() {
  local home before after out
  home=$(make_home concurrent)
  mkdir -p "$home/wt"
  write_legacy_meta "$home" proven-task "$home/wt" \
    'pr=https://github.com/o/r/pull/1' "pr_head=$GOOD_HEAD"
  before=$(cat "$home/state/proven-task.meta")

  out=$(FM_FAKE_META_REWRITE="$home/state/proven-task.meta" run_transition "$home")
  assert_contains "$out" 'RUN_ATTRIBUTION: task proven-task:' \
    "a concurrently changed record was not left diagnosed"
  assert_not_contains "$out" 'BOOTSTRAP_INFO:' \
    "a concurrently changed record was reported as migrated"
  after=$(cat "$home/state/proven-task.meta")
  [ "$after" = "$before"$'\n''status_concurrent=changed' ] \
    || fail "transition overwrote or altered the concurrent metadata change"
  assert_not_contains "$after" 'branch=' \
    "transition published branch identity after concurrent metadata change"
  pass "concurrent metadata changes refuse legacy branch publication"
}

# Fails if a read-only session contacts the forge, writes a provable candidate,
# or omits that candidate from its startup warning.
test_detect_only_names_provable_candidate_without_mutating() {
  local home before out
  home=$(make_home detect-only)
  mkdir -p "$home/wt"
  write_legacy_meta "$home" proven-task "$home/wt" \
    'pr=https://github.com/o/r/pull/1' "pr_head=$GOOD_HEAD"
  before=$(cat "$home/state/proven-task.meta")

  out=$(run_transition "$home" --detect-only)
  assert_contains "$out" 'RUN_ATTRIBUTION: task proven-task:' \
    "detect-only mode did not expose the unreadable task"
  [ "$(cat "$home/state/proven-task.meta")" = "$before" ] \
    || fail "detect-only mode changed task metadata"
  [ ! -s "$home/gh.log" ] || fail "detect-only mode contacted GitHub: $(cat "$home/gh.log")"
  pass "detect-only transition is read-only and still names every affected task"
}

# Fails if the sweep widens past live no-mistakes ships and starts naming or
# rewriting records the transition does not own - scouts, direct-PR and
# local-only ships, torn-down tasks, and modern branch-bearing tasks - which
# would bury the real diagnostic under fleet-wide noise every session.
test_out_of_scope_records_stay_silent() {
  local home id out before_modern
  home=$(make_home out-of-scope)
  mkdir -p "$home/scout-wt" "$home/direct-wt" "$home/local-wt" "$home/modern-wt" "$home/legacy-wt"

  fm_write_meta "$home/state/scout-task.meta" \
    'window=fm:fm-scout-task' "worktree=$home/scout-wt" "project=$home/scout-wt" \
    'kind=scout' 'mode=no-mistakes' 'harness=claude'
  write_legacy_meta "$home" direct-task "$home/direct-wt"
  sed -i 's/^mode=no-mistakes$/mode=direct-PR/' "$home/state/direct-task.meta"
  write_legacy_meta "$home" local-task "$home/local-wt"
  sed -i 's/^mode=no-mistakes$/mode=local-only/' "$home/state/local-task.meta"
  write_legacy_meta "$home" modern-task "$home/modern-wt" 'branch=fm/modern-task'
  # Torn down: the record outlived its worktree, so cleanup owns it, not this sweep.
  write_legacy_meta "$home" torndown-task "$home/gone-wt"
  # Control: proves the sweep actually ran over this state directory.
  write_legacy_meta "$home" legacy-task "$home/legacy-wt"
  before_modern=$(cat "$home/state/modern-task.meta")

  out=$(run_transition "$home")
  assert_contains "$out" 'RUN_ATTRIBUTION: task legacy-task:' \
    "the control legacy ship was not diagnosed, so this case proves nothing"
  for id in scout-task direct-task local-task modern-task torndown-task; do
    assert_not_contains "$out" "task $id" \
      "$id is out of scope for the transition but was reported"
  done
  [ "$(cat "$home/state/modern-task.meta")" = "$before_modern" ] \
    || fail "the sweep rewrote a modern branch-bearing record"
  [ ! -s "$home/gh.log" ] || fail "an out-of-scope record contacted GitHub: $(cat "$home/gh.log")"
  pass "only live no-mistakes ships without branch identity enter the transition"
}

# Fails if session bootstrap stops invoking the read-only transition detector,
# which would return updated homes to silent fleet-wide blindness.
test_bootstrap_surfaces_transition_diagnostic() {
  local home out
  home=$(make_home bootstrap)
  mkdir -p "$home/wt"
  write_legacy_meta "$home" startup-visible "$home/wt"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_GH_LOG="$home/gh.log" \
    FM_FAKE_GOOD_HEAD="$GOOD_HEAD" FM_FAKE_OTHER_HEAD="$OTHER_HEAD" \
    PATH="$home/fakebin:$PATH" "$BOOTSTRAP" 2>&1)
  assert_contains "$out" \
    'RUN_ATTRIBUTION: task startup-visible: legacy no-mistakes metadata has no proven branch=; any run is unattributable until task cleanup' \
    "bootstrap did not relay the legacy run-attribution diagnostic"
  pass "session bootstrap names legacy tasks whose runs cannot be attributed"
}

# Fails if the locked (mutating) bootstrap sweep stops running the transition,
# which would silently drop both the proven migration and the operator
# diagnostic from every ordinary locked session while detect-only stayed green.
test_locked_bootstrap_runs_the_transition_and_diagnoses_the_rest() {
  local home wt out before
  home=$(make_home locked-bootstrap)
  wt="$home/proven-wt"
  make_worktree_on_branch "$wt" fm/reallocated-ambient
  write_legacy_meta "$home" proven-task "$wt" \
    'pr=https://github.com/o/r/pull/1' "pr_head=$GOOD_HEAD"
  mkdir -p "$home/plain-wt"
  write_legacy_meta "$home" startup-visible "$home/plain-wt"
  before=$(cat "$home/state/startup-visible.meta")

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
    FM_FAKE_GH_LOG="$home/gh.log" FM_FAKE_GOOD_HEAD="$GOOD_HEAD" \
    FM_FAKE_OTHER_HEAD="$OTHER_HEAD" \
    PATH="$home/fakebin:$PATH" "$BOOTSTRAP" 2>&1)

  assert_contains "$out" \
    'BOOTSTRAP_INFO: run attribution transition: task proven-task recorded branch fm/proven-task from matching GitHub PR head' \
    "locked bootstrap did not run the proven legacy migration"
  grep -q '^branch=fm/proven-task$' "$home/state/proven-task.meta" \
    || fail "locked bootstrap did not persist the proven branch binding"
  meta_pr_identity_parses "$home/state/proven-task.meta" \
    || fail "locked bootstrap published a branch that broke the record's PR identity"
  assert_contains "$out" \
    'RUN_ATTRIBUTION: task startup-visible: legacy no-mistakes metadata has no proven branch=; any run is unattributable until task cleanup' \
    "locked bootstrap did not name the task that stays unattributable"
  [ "$(cat "$home/state/startup-visible.meta")" = "$before" ] \
    || fail "locked bootstrap changed a record it could not prove"
  pass "locked session bootstrap migrates the proven record and diagnoses the rest"
}

test_matching_pr_head_is_the_only_migration_proof
test_published_branch_preserves_pr_identity_ordering
test_sweep_budget_bounds_every_candidate_together
test_unproven_records_remain_byte_identical_and_visible
test_concurrent_metadata_change_refuses_publication
test_detect_only_names_provable_candidate_without_mutating
test_out_of_scope_records_stay_silent
test_bootstrap_surfaces_transition_diagnostic
test_locked_bootstrap_runs_the_transition_and_diagnoses_the_rest

echo "all legacy run-attribution transition tests passed"
