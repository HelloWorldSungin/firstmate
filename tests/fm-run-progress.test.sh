#!/usr/bin/env bash
# tests/fm-run-progress.test.sh - bin/fm-run-progress.sh, the reader that tells a
# validation run which is MOVING from one that has stranded.
#
# The whole point of this reader is that it must not turn into a blanket "there
# is a run, so the crew is fine" suppressor. Both real failure shapes are pinned
# here as first-class cases: a step stranded on its opening line with a live but
# idle agent, and a step that orphaned and left the run reporting `running`
# indefinitely. Both must read `stranded`, and every no-evidence shape must read
# `none`, which is what keeps the alarm behavior downstream unchanged.
#
# The wedge-escalation behavior these classes drive lives in
# fm-watch-triage.test.sh (always-on watcher) and fm-daemon.test.sh (away mode).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROG="$ROOT/bin/fm-run-progress.sh"
TMP_ROOT=$(fm_test_tmproot fm-run-progress-tests)

# A case is a state dir, a real git worktree on a known branch (the reader
# refuses a status answered for some other branch), and a fake `no-mistakes`
# whose `axi status` prints a canned TOON document.
make_case() {  # <name> [branch]
  local name=$1 branch=${2:-fm/task} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/wt"
  git -C "$dir/wt" init -q -b "$branch" 2>/dev/null || {
    git -C "$dir/wt" init -q
    git -C "$dir/wt" checkout -q -b "$branch"
  }
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_AXI_STATUS:-}" ] || exit 1
cat "$FM_FAKE_AXI_STATUS"
SH
  chmod +x "$dir/fakebin/no-mistakes"
  fm_write_meta "$dir/state/task.meta" "window=sess:fm-task" "kind=ship" "worktree=$dir/wt"
  printf '%s\n' "$dir"
}

# Run the reader for the fixture task against <status-toon>.
read_progress() {  # <dir> <status-toon> [env assignments...]
  local dir=$1 toon=$2
  shift 2
  printf '%s' "$toon" > "$dir/axi-status.txt"
  # `env` rather than an assignment prefix: an assignment that arrives through
  # "$@" is expanded too late to be recognized as one.
  env "PATH=$dir/fakebin:$PATH" "FM_STATE_OVERRIDE=$dir/state" \
    "FM_FAKE_AXI_STATUS=$dir/axi-status.txt" "$@" "$PROG" task
}

# The shape `no-mistakes axi status` really prints, verified against a live run
# on 2026-08-05. Field order and the quoted last_activity (which contains commas
# of its own) are part of the contract this parser must survive.
status_toon() {  # <step-status> <active_for> <last_activity>
  cat <<EOF
run:
  id: "01KZ7VXF67A6MP084K49R1G9JY"
  branch: fm/task
  status: running
  head: "2020e749"
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,10
    review,completed,1,2371231
    test,$1,0,0
    ci,pending,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    test,$1,$2,"$3","2698359",starting
branch_sync:
  state: pipeline_owned
EOF
}

# --- progressing ------------------------------------------------------------

test_recent_activity_is_progressing() {
  local dir out
  dir=$(make_case recent-activity)
  out=$(read_progress "$dir" "$(status_toon running 7m9s '7m4s ago: log: reading the change, then the tests.')")
  assert_contains "$out" "progress: progressing" "a step that logged 7m ago was not read as progressing"
  assert_contains "$out" "test running" "the progressing verdict did not name the step"
  pass "an executing step with recent activity reads as progressing"
}

test_quoted_commas_do_not_shift_fields() {
  local dir out
  dir=$(make_case quoted-commas)
  # last_activity routinely contains commas; a naive comma split would read
  # "2698359" as the last_activity and mis-time the whole run.
  out=$(read_progress "$dir" "$(status_toon running 3m0s '2m0s ago: log: first, second, and third checks queued')")
  assert_contains "$out" "progress: progressing" "commas inside the quoted last_activity broke field alignment"
  assert_contains "$out" "last activity 2m0s ago" "the parsed activity age came from the wrong field"
  pass "commas inside a quoted last_activity do not shift the parsed fields"
}

test_just_started_step_is_progressing() {
  local dir out
  dir=$(make_case just-started)
  # A step that has not logged yet has been silent for exactly as long as it has
  # been active, which is seconds - not evidence of a wedge.
  out=$(read_progress "$dir" "$(status_toon running 4s '')")
  assert_contains "$out" "progress: progressing" "a step active for 4s with no log yet was not read as progressing"
  pass "a step that has just started and not logged yet reads as progressing"
}

# --- stranded: the shapes that MUST still alarm ------------------------------

test_stranded_step_past_the_bound() {
  local dir out
  dir=$(make_case stranded-step)
  # The 2026-08-05 incident: a test step nineteen minutes into its opening line
  # with a live but idle agent, correctly aborted at thirty. Past the bound this
  # must read stranded so the wedge alarm still fires.
  out=$(read_progress "$dir" "$(status_toon running 31m2s 'quiet 31m0s ago: log: I will start by understanding the change.')")
  assert_contains "$out" "progress: stranded" "a step silent 31m was not read as stranded"
  assert_contains "$out" "test running" "the stranded verdict did not name the step that stopped"
  pass "an executing step silent past the bound reads as stranded, naming the step"
}

test_pipeline_quiet_marker_is_stripped_not_trusted() {
  local dir out
  dir=$(make_case quiet-marker)
  # The pipeline prefixes last_activity with `quiet` past its own 10m
  # step_quiet_warning. That marker is a liveness clue, not a wedge verdict:
  # review and test steps routinely go 10-18m on one opening line, so a quiet
  # step inside our own bound must still read progressing.
  out=$(read_progress "$dir" "$(status_toon running 14m1s 'quiet 14m0s ago: log: still working through the suite')")
  assert_contains "$out" "progress: progressing" "the pipeline's 10m quiet marker was treated as a wedge verdict"
  assert_contains "$out" "last activity 14m0s ago" "the quiet prefix was not stripped from the parsed age"
  pass "the pipeline's quiet marker is read for its age, not taken as a stranded verdict"
}

test_orphaned_step_that_never_logged_is_stranded() {
  local dir out
  dir=$(make_case orphaned-ci)
  # Firstmate's recorded experience: a `ci` step that orphaned and left the run
  # reporting `running` for DAYS. It has no activity age at all, so the silence
  # is how long it has been active - which is what makes it measurable instead
  # of invisible.
  out=$(read_progress "$dir" "$(status_toon ci 3d4h '')")
  assert_contains "$out" "progress: stranded" "an orphaned step running for days was not read as stranded"
  assert_contains "$out" "no activity in 3d4h" "the stranded verdict did not report the orphaned step's age"
  pass "a step that orphaned and never logged reads as stranded from its own age"
}

test_longest_silence_is_named_when_nothing_moved() {
  local dir out
  dir=$(make_case worst-named)
  out=$(read_progress "$dir" "$(cat <<'EOF'
run:
  branch: fm/task
  status: running
  active_steps[2]{step,status,active_for,last_activity,agent_pid,round}:
    test,running,40m0s,"40m0s ago: log: opening","2698359",starting
    ci,running,3d0h,"","0",starting
branch_sync:
  state: pipeline_owned
EOF
)")
  assert_contains "$out" "progress: stranded" "two stranded steps did not read as stranded"
  assert_contains "$out" "ci running" "the longest-silent step was not the one named"
  pass "when nothing moved, the stranded verdict names the longest-silent step"
}

test_any_moving_step_proves_the_run_is_moving() {
  local dir out
  dir=$(make_case one-moving)
  out=$(read_progress "$dir" "$(cat <<'EOF'
run:
  branch: fm/task
  status: running
  active_steps[2]{step,status,active_for,last_activity,agent_pid,round}:
    test,running,40m0s,"40m0s ago: log: opening","2698359",starting
    lint,running,5m0s,"30s ago: log: checking","2698360",starting
branch_sync:
  state: pipeline_owned
EOF
)")
  assert_contains "$out" "progress: progressing" "a run with one moving step was not read as progressing"
  assert_contains "$out" "lint running" "the progressing verdict did not name the step that moved"
  pass "one executing step that moved recently proves the run as a whole is moving"
}

# --- the named threshold ----------------------------------------------------

test_default_bound_is_1800s_and_is_the_boundary() {
  local dir out
  dir=$(make_case default-bound)
  out=$(read_progress "$dir" "$(status_toon running 29m50s '29m50s ago: log: opening')")
  assert_contains "$out" "progress: progressing" "a 29m50s silence crossed the default 1800s bound"
  assert_contains "$out" "bound 1800s" "the progressing verdict did not state the bound it used"
  out=$(read_progress "$dir" "$(status_toon running 30m10s '30m10s ago: log: opening')")
  assert_contains "$out" "progress: stranded" "a 30m10s silence did not cross the default 1800s bound"
  assert_contains "$out" "past the 1800s bound" "the stranded verdict did not state the bound it crossed"
  pass "the stranded bound defaults to 1800s, states itself, and separates 29m50s from 30m10s"
}

test_bound_is_configurable() {
  local dir out
  dir=$(make_case configurable-bound)
  out=$(read_progress "$dir" "$(status_toon running 12m0s '11m0s ago: log: opening')" \
    FM_RUN_STRANDED_SILENCE_SECS=600)
  assert_contains "$out" "progress: stranded" "a lowered stranded bound was not honored"
  out=$(read_progress "$dir" "$(status_toon running 12m0s '11m0s ago: log: opening')" \
    FM_RUN_STRANDED_SILENCE_SECS=3600)
  assert_contains "$out" "progress: progressing" "a raised stranded bound was not honored"
  out=$(read_progress "$dir" "$(status_toon running 40m0s '40m0s ago: log: opening')" \
    FM_RUN_STRANDED_SILENCE_SECS=not-a-number
  )
  assert_contains "$out" "past the 1800s bound" "a malformed bound did not fall back to the documented default"
  pass "the stranded bound is configurable and falls back to its default when malformed"
}

test_duration_units_are_parsed() {
  local dir out
  dir=$(make_case duration-units)
  out=$(read_progress "$dir" "$(status_toon running 2h0m '2h0m ago: log: opening')")
  assert_contains "$out" "progress: stranded" "an hours duration was not parsed"
  out=$(read_progress "$dir" "$(status_toon running 1d2h '1d2h ago: log: opening')")
  assert_contains "$out" "progress: stranded" "a days duration was not parsed"
  out=$(read_progress "$dir" "$(status_toon running 45s '45s ago: log: opening')")
  assert_contains "$out" "progress: progressing" "a seconds-only duration was not parsed"
  out=$(read_progress "$dir" "$(status_toon running 900ms '900ms ago: log: opening')")
  assert_contains "$out" "progress: progressing" "a sub-second duration was mis-parsed as minutes"
  pass "compact durations in d/h/m/s and ms all parse"
}

# --- none: every shape that carries no evidence -----------------------------

test_no_active_steps_is_none() {
  local dir out
  dir=$(make_case parked-run)
  # A run parked at a gate is waiting on its WORKER, which is the opposite of
  # evidence that the worker is alive - it must never quiet the alarm.
  out=$(read_progress "$dir" "$(cat <<'EOF'
run:
  branch: fm/task
  status: awaiting_approval
  gate:
    step: review
    findings[3]{id,severity}:
      f1,blocking
branch_sync:
  state: pipeline_owned
EOF
)")
  assert_contains "$out" "progress: none" "a run parked at a gate was not read as no-evidence"
  pass "a run parked at a gate carries no progress evidence"
}

test_gate_status_row_is_not_executing() {
  local dir out
  dir=$(make_case gate-row)
  out=$(read_progress "$dir" "$(status_toon fix_review 44m0s '44m0s ago: log: awaiting your response')")
  assert_contains "$out" "progress: none" "a fix_review active step was treated as executing"
  pass "a non-executing active step (a gate) is not progress evidence"
}

test_other_branch_run_is_none() {
  local dir out
  dir=$(make_case other-branch)
  # axi status answers a branch with no run of its own by displaying some OTHER
  # branch's run. Its active steps say nothing about this crew.
  out=$(read_progress "$dir" "$(cat <<'EOF'
run:
  branch: fm/somebody-else
  status: running
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    test,running,10s,"5s ago: log: going","1",starting
branch_sync:
  state: pipeline_owned
EOF
)")
  assert_contains "$out" "progress: none" "another branch's run was read as this crew's progress"
  pass "a status answered for another branch carries no progress evidence"
}

test_missing_evidence_shapes_are_none() {
  local dir out
  dir=$(make_case missing-evidence)

  out=$(FM_STATE_OVERRIDE="$dir/state" "$PROG" nosuchtask)
  assert_contains "$out" "progress: none" "an unknown task was not read as no-evidence"

  fm_write_meta "$dir/state/scout.meta" "window=sess:fm-scout" "kind=scout" "worktree=$dir/wt"
  out=$(FM_STATE_OVERRIDE="$dir/state" "$PROG" scout)
  assert_contains "$out" "progress: none" "a scout task was not read as no-evidence"

  fm_write_meta "$dir/state/gone.meta" "window=sess:fm-gone" "kind=ship" "worktree=$dir/nope"
  out=$(FM_STATE_OVERRIDE="$dir/state" "$PROG" gone)
  assert_contains "$out" "progress: none" "a torn-down worktree was not read as no-evidence"

  # A status read that cannot complete is a lookup FAILURE, never an absence of
  # a run - and never permission to quiet an alarm.
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/fakebin/no-mistakes"
  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" "$PROG" task)
  assert_contains "$out" "progress: none" "a failed status read was not read as no-evidence"

  pass "unknown task, scout, torn-down worktree, and a failed read all carry no evidence"
}

test_unparseable_output_is_none() {
  local dir out
  dir=$(make_case unparseable)
  out=$(read_progress "$dir" "$(cat <<'EOF'
run:
  branch: fm/task
  status: running
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    test,running,not-a-duration,"who knows","1",starting
branch_sync:
  state: pipeline_owned
EOF
)")
  assert_contains "$out" "progress: none" "an unparseable duration was not read as no-evidence"
  pass "an active step whose timings cannot be parsed carries no evidence"
}

test_writes_nothing_and_never_fails_a_read() {
  local dir before after status
  dir=$(make_case side-effect-free)
  before=$(find "$dir/state" -mindepth 1 | sort)
  read_progress "$dir" "$(status_toon running 7m9s '7m4s ago: log: going')" >/dev/null
  status=$?
  after=$(find "$dir/state" -mindepth 1 | sort)
  [ "$status" = 0 ] || fail "a successful read exited $status"
  [ "$before" = "$after" ] || fail "the reader wrote to the state dir: $after"
  "$PROG" >/dev/null 2>&1 && fail "a usage error did not exit non-zero"
  pass "the reader writes nothing, exits 0 on any read, and exits non-zero only on usage"
}

test_recent_activity_is_progressing
test_quoted_commas_do_not_shift_fields
test_just_started_step_is_progressing
test_stranded_step_past_the_bound
test_pipeline_quiet_marker_is_stripped_not_trusted
test_orphaned_step_that_never_logged_is_stranded
test_longest_silence_is_named_when_nothing_moved
test_any_moving_step_proves_the_run_is_moving
test_default_bound_is_1800s_and_is_the_boundary
test_bound_is_configurable
test_duration_units_are_parsed
test_no_active_steps_is_none
test_gate_status_row_is_not_executing
test_other_branch_run_is_none
test_missing_evidence_shapes_are_none
test_unparseable_output_is_none
test_writes_nothing_and_never_fails_a_read
