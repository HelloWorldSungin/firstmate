#!/usr/bin/env bash
# tests/fm-endpoint-binding-migrate.test.sh - regression tests for the one-shot
# endpoint-binding migration (bin/fm-endpoint-binding-migrate.sh).
#
# The migration exists because fm_backend_validate_task_endpoint requires an
# `endpoint_task_id=` binding before a non-tmux endpoint may be cleaned up, and
# nothing wrote that field into records already on disk. The central regression
# these tests pin: a pre-change herdr record must still be refused by cleanup
# validation BEFORE the migration and must be accepted AFTER it - and only when
# the recorded endpoint was verified live to carry that task's own label. Every
# unverifiable, mismatched, or gone endpoint must be refused and left byte-
# unchanged, because a binding written without proof recreates the exact hazard
# the validation was added to prevent.
#
# Herdr is faked here (canned `tab list` / `pane list` responses plus real jq),
# mirroring tests/fm-backend-herdr.test.sh's fake-CLI convention.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

MIGRATE="$ROOT/bin/fm-endpoint-binding-migrate.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-binding-migrate)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

# make_home: a private home with state/, a fake `herdr` whose `tab list` and
# `pane list` responses come from files the test writes, and fake tmux/treehouse
# so an accidental runtime call is observable rather than real.
make_home() {  # <name> -> echoes home dir
  local name=$1 dir fb
  dir="$TMP_ROOT/$name"
  fb="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/worktree" "$dir/project" "$fb"
  : > "$dir/runtime.log"
  printf '{"result":{"tabs":[]}}\n' > "$dir/tabs.json"
  printf '{"result":{"panes":[]}}\n' > "$dir/panes.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'herdr'
  for a in "$@"; do printf ' <%s>' "$a"; done
  printf '\n'
} >> "${FM_RUNTIME_LOG:?}"
if [ "${1:-}" = status ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
if [ "${FM_FAKE_HERDR_FAIL:-0}" = 1 ]; then
  exit 1
fi
case "${1:-}:${2:-}" in
  tab:list) cat "${FM_FAKE_HERDR_TABS:?}" ;;
  pane:list) cat "${FM_FAKE_HERDR_PANES:?}" ;;
  *) printf '{"result":{}}\n' ;;
esac
exit 0
SH
  for stub in tmux treehouse; do
    cat > "$fb/$stub" <<SH
#!/usr/bin/env bash
printf '$stub' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
exit 0
SH
  done
  chmod +x "$fb/herdr" "$fb/tmux" "$fb/treehouse"
  printf '%s\n' "$dir"
}

# set_live_herdr_tab: model one live tab <tab_id> labelled <label> owning pane
# <pane_id>, as `tab list` and `pane list` would report it.
set_live_herdr_tab() {  # <home> <tab_id> <label> <pane_id>
  local dir=$1 tab=$2 label=$3 pane=$4
  jq -n --arg t "$tab" --arg l "$label" '{result:{tabs:[{tab_id:$t,label:$l}]}}' > "$dir/tabs.json"
  jq -n --arg t "$tab" --arg p "$pane" '{result:{panes:[{tab_id:$t,pane_id:$p}]}}' > "$dir/panes.json"
}

set_no_live_herdr_tabs() {  # <home>
  printf '{"result":{"tabs":[]}}\n' > "$1/tabs.json"
  printf '{"result":{"panes":[]}}\n' > "$1/panes.json"
}

# write_legacy_herdr_meta: a task record exactly as it was written before
# `endpoint_task_id=` existed - every other field present, the binding absent.
write_legacy_herdr_meta() {  # <home> <id>
  local dir=$1 id=$2
  fm_write_meta "$dir/state/$id.meta" \
    "window=lab:p1" \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    "harness=claude" \
    "kind=ship" \
    "backend=herdr" \
    "herdr_session=lab" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=t1" \
    "herdr_pane_id=p1"
}

run_migrate() {  # <home> [args...]
  local dir=$1
  shift
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" \
  FM_FAKE_HERDR_TABS="$dir/tabs.json" FM_FAKE_HERDR_PANES="$dir/panes.json" \
  FM_FAKE_HERDR_FAIL="${FM_FAKE_HERDR_FAIL:-0}" \
  PATH="$dir/fakebin:$PATH" \
    "$MIGRATE" "$@"
}

validates() {  # <home> <id>
  fm_backend_validate_task_endpoint "$1/state/$2.meta" "$2" >/dev/null 2>&1
}

# --- the central regression -------------------------------------------------

test_pre_change_record_is_uncleanable_before_and_cleanable_after() {
  local dir id=legacy-herdr-task out before after
  dir=$(make_home regression)
  write_legacy_herdr_meta "$dir" "$id"
  set_live_herdr_tab "$dir" t1 "fm-$id" p1

  # Before: cleanup validation refuses the record, and real teardown reports the
  # exact legacy-binding refusal without touching the task's state.
  ! validates "$dir" "$id" || fail "pre-change herdr record validated before the migration"
  set +e
  out=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$id" --force 2>&1)
  set -e
  assert_contains "$out" "lacks an exact task binding" \
    "teardown did not report the legacy Herdr binding refusal before the migration"
  assert_present "$dir/state/$id.meta" "teardown changed the record while refusing it"

  before=$(cat "$dir/state/$id.meta")
  : > "$dir/runtime.log"
  out=$(run_migrate "$dir")
  assert_contains "$out" "BOOTSTRAP_INFO: endpoint binding migration: task $id (herdr) bound" \
    "migration did not report binding the verified legacy record"

  # After: the record carries exactly one binding, keeps every original line,
  # and cleanup validation now accepts it.
  after=$(cat "$dir/state/$id.meta")
  [ "$(grep -c '^endpoint_task_id=' "$dir/state/$id.meta")" = 1 ] \
    || fail "migration did not write exactly one endpoint binding"
  [ "$(grep '^endpoint_task_id=' "$dir/state/$id.meta")" = "endpoint_task_id=$id" ] \
    || fail "migration wrote the wrong endpoint binding"
  [ "$after" = "$before"$'\n'"endpoint_task_id=$id" ] \
    || fail "migration altered the record beyond appending its binding"
  validates "$dir" "$id" || fail "migrated herdr record is still refused by cleanup validation"

  pass "fm-endpoint-binding-migrate: a pre-change herdr record is refused before the migration and cleanable after it"
}

# --- refusals: an unproven endpoint is never bound --------------------------

assert_refused_unchanged() {  # <home> <id> <reason-fragment> <description>
  local dir=$1 id=$2 fragment=$3 description=$4 before out
  before=$(cat "$dir/state/$id.meta")
  out=$(run_migrate "$dir")
  assert_contains "$out" "ENDPOINT_BINDING_MIGRATION: task $id (herdr):" \
    "$description: no refusal was reported"
  assert_contains "$out" "$fragment" "$description: wrong refusal reason"
  assert_not_contains "$out" "BOOTSTRAP_INFO" "$description: reported a binding it must not have written"
  [ "$(cat "$dir/state/$id.meta")" = "$before" ] || fail "$description: the record was modified"
  ! validates "$dir" "$id" || fail "$description: the record became cleanable without proof"
}

test_unverifiable_endpoints_refuse_rather_than_bind() {
  local dir id=legacy-herdr-task

  # The recorded tab is live but carries another task's label: the opaque id was
  # reused, which is precisely the hazard the binding check exists to stop.
  dir=$(make_home mislabelled)
  write_legacy_herdr_meta "$dir" "$id"
  set_live_herdr_tab "$dir" t1 fm-some-other-task p1
  assert_refused_unchanged "$dir" "$id" "does not carry this task's label" "mislabelled tab"

  # The tab is correctly labelled but no longer owns the recorded pane.
  dir=$(make_home pane-drift)
  write_legacy_herdr_meta "$dir" "$id"
  set_live_herdr_tab "$dir" t1 "fm-$id" p9
  assert_refused_unchanged "$dir" "$id" "no longer the labelled tab's own pane" "pane drift"

  # The runtime cannot be read at all: unreachable is not proof of ownership.
  dir=$(make_home unreachable)
  write_legacy_herdr_meta "$dir" "$id"
  set_live_herdr_tab "$dir" t1 "fm-$id" p1
  FM_FAKE_HERDR_FAIL=1 assert_refused_unchanged "$dir" "$id" "could not be read" "unreadable runtime"

  pass "fm-endpoint-binding-migrate: mislabelled, drifted, and unreadable endpoints refuse and leave the record unchanged"
}

test_already_gone_task_is_handled_without_error() {
  local dir id=legacy-herdr-task before out rc
  dir=$(make_home gone)
  write_legacy_herdr_meta "$dir" "$id"
  set_no_live_herdr_tabs "$dir"
  before=$(cat "$dir/state/$id.meta")

  set +e
  out=$(run_migrate "$dir")
  rc=$?
  set -e
  expect_code 0 "$rc" "a gone endpoint must not fail the migration"
  assert_contains "$out" "is gone; absence does not prove the record owned it" \
    "a gone endpoint was not reported as gone"
  [ "$(cat "$dir/state/$id.meta")" = "$before" ] || fail "a gone endpoint's record was modified"
  ! validates "$dir" "$id" || fail "a gone endpoint was bound without proof of ownership"

  pass "fm-endpoint-binding-migrate: an already-gone endpoint is reported without error and never bound"
}

test_missing_state_and_empty_home_are_handled_without_error() {
  local dir out rc
  dir=$(make_home empty)
  set +e
  out=$(run_migrate "$dir")
  rc=$?
  set -e
  expect_code 0 "$rc" "an empty state directory must not fail the migration"
  [ -z "$out" ] || fail "an empty state directory produced output: $out"

  rm -rf "$dir/state"
  set +e
  out=$(run_migrate "$dir")
  rc=$?
  set -e
  expect_code 0 "$rc" "a missing state directory must not fail the migration"
  [ -z "$out" ] || fail "a missing state directory produced output: $out"

  pass "fm-endpoint-binding-migrate: an empty or missing state directory is silent and successful"
}

# --- records the migration must not touch -----------------------------------

test_records_outside_the_migration_are_left_alone() {
  local dir out bound=bound-task tmux_id=tmux-task ambiguous=ambiguous-task
  dir=$(make_home untouched)

  # An existing correct binding.
  fm_write_meta "$dir/state/$bound.meta" \
    "window=lab:p1" "endpoint_task_id=$bound" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=herdr" \
    "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=t1" "herdr_pane_id=p1"
  # A legacy tmux record: self-identifying by window name, so never a candidate.
  fm_write_meta "$dir/state/$tmux_id.meta" \
    "window=firstmate:fm-$tmux_id" "worktree=$dir/worktree" "project=$dir/project"
  # An ambiguous binding belongs to cleanup validation, not to this migration.
  fm_write_meta "$dir/state/$ambiguous.meta" \
    "window=lab:p1" "endpoint_task_id=$ambiguous" "endpoint_task_id=$ambiguous" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=herdr" \
    "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=t1" "herdr_pane_id=p1"

  local before_bound before_tmux before_ambiguous
  before_bound=$(cat "$dir/state/$bound.meta")
  before_tmux=$(cat "$dir/state/$tmux_id.meta")
  before_ambiguous=$(cat "$dir/state/$ambiguous.meta")

  out=$(run_migrate "$dir")
  [ -z "$out" ] || fail "the migration reported on records it must ignore: $out"
  [ ! -s "$dir/runtime.log" ] || fail "the migration ran a runtime command for records it must ignore: $(cat "$dir/runtime.log")"
  [ "$(cat "$dir/state/$bound.meta")" = "$before_bound" ] || fail "an existing correct binding was modified"
  [ "$(cat "$dir/state/$tmux_id.meta")" = "$before_tmux" ] || fail "a legacy tmux record was modified"
  [ "$(cat "$dir/state/$ambiguous.meta")" = "$before_ambiguous" ] || fail "an ambiguously bound record was modified"
  validates "$dir" "$bound" || fail "an existing correct binding stopped validating"
  validates "$dir" "$tmux_id" || fail "a legacy tmux record stopped validating"

  pass "fm-endpoint-binding-migrate: already-bound, tmux, and ambiguously bound records are ignored without a runtime call"
}

test_dry_run_decides_without_writing() {
  local dir id=legacy-herdr-task before out
  dir=$(make_home dry-run)
  write_legacy_herdr_meta "$dir" "$id"
  set_live_herdr_tab "$dir" t1 "fm-$id" p1
  before=$(cat "$dir/state/$id.meta")

  out=$(run_migrate "$dir" --dry-run)
  assert_contains "$out" "would be bound after live task-label verification" \
    "--dry-run did not report the decision it would make"
  [ "$(cat "$dir/state/$id.meta")" = "$before" ] || fail "--dry-run modified the record"
  ! validates "$dir" "$id" || fail "--dry-run made the record cleanable"

  pass "fm-endpoint-binding-migrate: --dry-run reports its decision and writes nothing"
}

test_pre_change_record_is_uncleanable_before_and_cleanable_after
test_unverifiable_endpoints_refuse_rather_than_bind
test_already_gone_task_is_handled_without_error
test_missing_state_and_empty_home_are_handled_without_error
test_records_outside_the_migration_are_left_alone
test_dry_run_decides_without_writing
