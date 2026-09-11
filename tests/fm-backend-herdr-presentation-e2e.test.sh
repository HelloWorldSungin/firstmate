#!/usr/bin/env bash
# Real-Herdr presentation, focus, negative-path and concurrency coverage.
# Uses a fresh fixture independent of the multi-home/recovery entrypoint.
set -u

# shellcheck source=tests/herdr-presentation-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-presentation-fixture.sh"
presentation_fixture_setup
presentation_fixture_seed_project presentation-anchor

assert_cleanup_focus_preserved() {  # <line-count> <pane-id> <expected-focus>
  local start=$1 pane_id=$2 expected=$3
  sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v pane="$pane_id" -v expected="$expected" '
    $1 == "pane-close" && $4 == pane {
      saw_close = 1
      if ($2 != expected) { bad = 1 }
      else if ($3 == expected) { preserved = 1 }
      else { drift = $3 }
      next
    }
    saw_close && drift != "" && $1 == "tab-focus" && $2 == drift && $3 == expected {
      preserved = 1
    }
    END { exit(bad || (saw_close && !preserved) ? 1 : 0) }
  ' || fail "projected pane close did not preserve or restore the exact active workspace and tab"
  if lab pane get "$pane_id" >/dev/null 2>&1; then
    fail "projected cleanup left exact pane $pane_id alive"
  fi
}

finish_concurrent_expected_abort() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || fail "post-create abort fixture $id unexpectedly succeeded"
  if grep -F "task set is locked" "$err" >/dev/null 2>&1; then
    if spawn_task "$id" "$HOME_DIR" "$PROJECT_DIR" > "$out" 2> "$err"; then
      fail "post-create abort fixture $id unexpectedly succeeded after task-set publication completed"
    fi
  fi
}

finish_concurrent_teardown() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || return 0
  if ! grep -F "session presentation lock is contended" "$err" >/dev/null 2>&1 \
     && ! grep -F "another Treehouse slot allocation or return is in progress" "$err" >/dev/null 2>&1; then
    fail "projected teardown $id failed unexpectedly: $(cat "$err")"
  fi
  teardown_task "$id" "$HOME_DIR" > "$out" 2> "$err" \
    || fail "projected teardown $id retry failed after presentation cleanup completed: $(cat "$err")"
}

normalize_meta() {  # <meta>
  sed -E \
    -e 's|^window=.*$|window=<herdr-container-id>|' \
    -e 's|^herdr_workspace_id=.*$|herdr_workspace_id=<herdr-container-id>|' \
    -e 's|^herdr_tab_id=.*$|herdr_tab_id=<herdr-container-id>|' \
    -e 's|^herdr_pane_id=.*$|herdr_pane_id=<herdr-container-id>|' \
    -e 's|^spawned_at=.*$|spawned_at=<dispatch-identity>|' \
    -e 's|^model_evidence_before=.*$|model_evidence_before=<dispatch-identity>|' \
    -e 's|^spawn_gen=.*$|spawn_gen=<spawn-incarnation>|' \
    "$1"
}

assert_no_ordering_lifecycle_calls_since() {  # <line-count> <case-name>
  local start=$1 name=$2 calls
  calls=$(sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$calls" | grep -E $'^(workspace\t(close|rename)|tab\tclose|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$name introduced a workspace/tab/session lifecycle or label mutation call"
  fi
}

write_ship_brief "$HOME_DIR" shape 'Projection E2E fixture.'
write_ship_brief "$HOME_DIR" order-a 'Projection ordering fixture A.'
write_ship_brief "$HOME_DIR" order-b 'Projection ordering fixture B.'
write_ship_brief "$HOME_DIR" order-fail 'Projection ordering failure fixture.'
write_ship_brief "$HOME_DIR" active-seeded 'Projection active seeded fixture.'
write_ship_brief "$HOME_DIR" abort-a 'Projection abort fixture A.'
write_ship_brief "$HOME_DIR" abort-b 'Projection abort fixture B.'
write_ship_brief "$HOME_DIR" lock-contended 'Projection lock contention fixture.'
write_ship_brief "$HOME_DIR" default-on 'Projection default-on fixture.'

# The same task id and project run once opted out and once projected, so
# Treehouse commands and metadata can be compared after normalizing endpoint
# IDs and the deliberately fresh per-spawn incarnation.
: > "$TREEHOUSE_CALL_LOG"
OFF_HERDR_START=$(log_line_count)
OFF_MOVE_START=$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/off.out" 2> "$EVIDENCE_ROOT/off.err" \
  || fail "opted-out spawn failed: $(cat "$EVIDENCE_ROOT/off.err")"
OFF_HERDR_END=$(log_line_count)
OFF_META="$TMP_ROOT/off.meta"
cp "$HOME_DIR/state/shape.meta" "$OFF_META"
OFF_WT=$(remember_meta_worktree "$OFF_META")
cp "$TREEHOUSE_CALL_LOG" "$EVIDENCE_ROOT/off-treehouse.log"
[ "$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')" = "$OFF_MOVE_START" ] \
  || fail "opted-out spawn invoked the presentation-only workspace mover"
OFF_HERDR_CALLS=$(sed -n "$((OFF_HERDR_START + 1)),${OFF_HERDR_END}p" "$HERDR_CALL_LOG")
if printf '%s\n' "$OFF_HERDR_CALLS" | grep -E $'^(api\tschema|session\tlist)' >/dev/null 2>&1; then
  fail "opted-out spawn added presentation-ordering capability or socket calls"
fi
pass "real Herdr lab: an opted-out spawn retains the Stage 1 Herdr command sequence with zero ordering calls"
teardown_task shape "$HOME_DIR" > "$EVIDENCE_ROOT/off-teardown.out" 2> "$EVIDENCE_ROOT/off-teardown.err" \
  || fail "opted-out teardown failed: $(cat "$EVIDENCE_ROOT/off-teardown.err")"

# A home that configured nothing at all follows the version floor: it is
# projected on a release at or above it, and takes the ordinary flat layout with
# one naming warning below it. The only difference from the opted-out spawn
# above is the removed file, so this case is the floor's live end-user proof on
# whichever Herdr this lab is running.
rm -f "$HOME_DIR/config/herdr-presentation-spaces"
FLOOR_STATUS=$(lab status --json) || fail 'could not read the lab release for the presentation floor'
FLOOR_VERSION=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.version else .client.version end')
FLOOR_PROTOCOL=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.protocol else .client.protocol end')
FLOOR_VERDICT=$(bash -c '
  . "$0/bin/backends/herdr.sh"
  status=0
  fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
  printf "%s\n" "$status"
' "$ROOT" "$FLOOR_PROTOCOL" "$FLOOR_VERSION")
[ "$FLOOR_VERDICT" = 0 ] || [ "$FLOOR_VERDICT" = 1 ] \
  || fail "herdr $FLOOR_VERSION protocol $FLOOR_PROTOCOL could not be classified against the presentation floor"
spawn_task default-on "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/default-on.out" 2> "$EVIDENCE_ROOT/default-on.err" \
  || fail "default-on spawn failed: $(cat "$EVIDENCE_ROOT/default-on.err")"
DEFAULT_ON_META="$HOME_DIR/state/default-on.meta"
remember_meta_worktree "$DEFAULT_ON_META" >/dev/null
DEFAULT_ON_JOURNAL="$HOME_DIR/state/default-on.herdr-presentation"
DEFAULT_ON_WSID=$(grep '^herdr_workspace_id=' "$DEFAULT_ON_META" | cut -d= -f2-)
if [ "$FLOOR_VERDICT" = 0 ]; then
  [ -f "$DEFAULT_ON_JOURNAL" ] \
    || fail "an unconfigured home did not publish a presentation journal on supported herdr $FLOOR_VERSION"
  DEFAULT_ON_TOKEN=$(grep '^projection_id=' "$DEFAULT_ON_JOURNAL" | cut -d= -f2-)
  [ -n "$DEFAULT_ON_WSID" ] && [ "$DEFAULT_ON_WSID" != "$FIRSTMATE_WSID" ] \
    || fail "an unconfigured home reused the flat firstmate workspace instead of projecting"
  DEFAULT_ON_LABEL=$(lab workspace get "$DEFAULT_ON_WSID" | jq -r '.result.workspace.label // empty')
  [ "$DEFAULT_ON_LABEL" = "└ default-on · p:$DEFAULT_ON_TOKEN" ] \
    || fail "default-on projection used an unexpected workspace label: $DEFAULT_ON_LABEL"
  pass "real Herdr lab: a home that configured nothing is projected by default on herdr $FLOOR_VERSION"
else
  [ ! -e "$DEFAULT_ON_JOURNAL" ] \
    || fail "an unconfigured home published a presentation journal on below-floor herdr $FLOOR_VERSION"
  [ "$DEFAULT_ON_WSID" = "$FIRSTMATE_WSID" ] \
    || fail "an unconfigured home did not land in the flat firstmate workspace on below-floor herdr $FLOOR_VERSION (got '${DEFAULT_ON_WSID:-<empty>}')"
  grep -q "$FLOOR_VERSION" "$EVIDENCE_ROOT/default-on.err" \
    || fail "the below-floor fallback did not name herdr $FLOOR_VERSION: $(cat "$EVIDENCE_ROOT/default-on.err")"
  pass "real Herdr lab: a home that configured nothing falls back flat on below-floor herdr $FLOOR_VERSION with one naming warning"
fi
teardown_task default-on "$HOME_DIR" > "$EVIDENCE_ROOT/default-on-teardown.out" 2> "$EVIDENCE_ROOT/default-on-teardown.err" \
  || fail "default-on teardown failed: $(cat "$EVIDENCE_ROOT/default-on-teardown.err")"
if [ "$FLOOR_VERDICT" = 0 ] && lab workspace get "$DEFAULT_ON_WSID" >/dev/null 2>&1; then
  fail "default-on teardown left its disposable workspace behind"
fi
# The ordering scenarios below read the whole move log cumulatively against the
# projected workspaces that are still live, so this retired one starts them clean.
: > "$MOVE_CALL_LOG"

presentation_fixture_seed_parents
SECOND_ORDER_BEFORE=$(printf '%s\n%s\n' "$SECOND_ONE_WSID" "$SECOND_TWO_WSID")

: > "$TREEHOUSE_CALL_LOG"
# The historical presence-based opt-in was an empty file; it must still project,
# so no home that had already enabled the projection is turned off by the default.
: > "$HOME_DIR/config/herdr-presentation-spaces"
SHAPE_FOCUS_AUDIT_START=$(focus_audit_line_count)
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/on.out" 2> "$EVIDENCE_ROOT/on.err" \
  || fail "projected spawn failed: $(cat "$EVIDENCE_ROOT/on.err")"
assert_focus_is "$CAPTAIN_FOCUS" "projected spawn"
assert_raw_presentation_mutations_preserved_since "$SHAPE_FOCUS_AUDIT_START" "projected spawn"
ON_META="$TMP_ROOT/on.meta"
cp "$HOME_DIR/state/shape.meta" "$ON_META"
ON_WT=$(remember_meta_worktree "$ON_META")
cmp -s "$EVIDENCE_ROOT/off-treehouse.log" "$TREEHOUSE_CALL_LOG" \
  || fail "Treehouse command sequence changed between opted-out and projected spawns"
JOURNAL="$HOME_DIR/state/shape.herdr-presentation"
[ -f "$JOURNAL" ] || fail "projected spawn did not publish its presentation journal"
TOKEN=$(grep '^projection_id=' "$JOURNAL" | cut -d= -f2-)
[ "${#TOKEN}" -eq 22 ] || fail "projection id is not the compact 22-character encoding of 128 bits"
PROJECTED_WSID=$(grep '^herdr_workspace_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_TAB=$(grep '^herdr_tab_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_PANE=$(grep '^herdr_pane_id=' "$ON_META" | cut -d= -f2-)
PROJECTED_INFO=$(lab workspace get "$PROJECTED_WSID") || fail "could not inspect the projected workspace"
PROJECTED_LABEL=$(printf '%s' "$PROJECTED_INFO" | jq -r '.result.workspace.label // empty')
[ "$PROJECTED_LABEL" = "└ shape · p:$TOKEN" ] \
  || fail "projected workspace label did not use the corner format with full token: $PROJECTED_LABEL"
PROJECTED_TABS=$(lab tab list --workspace "$PROJECTED_WSID")
PROJECTED_PANES=$(lab pane list --workspace "$PROJECTED_WSID")
[ "$(printf '%s' "$PROJECTED_TABS" | jq -r '.result.tabs | length')" = 1 ] \
  || fail "projected workspace retained a seeded or placeholder tab"
[ "$(printf '%s' "$PROJECTED_PANES" | jq -r '.result.panes | length')" = 1 ] \
  || fail "projected workspace did not contain exactly one task pane"
printf '%s' "$PROJECTED_TABS" | jq -e --arg tab "$PROJECTED_TAB" \
  '.result.tabs[0].tab_id == $tab and .result.tabs[0].label == "fm-shape"' >/dev/null 2>&1 \
  || fail "projected workspace's only tab was not the normal fm-shape task tab"
printf '%s' "$PROJECTED_PANES" | jq -e --arg pane "$PROJECTED_PANE" \
  '.result.panes[0].pane_id == $pane' >/dev/null 2>&1 \
  || fail "projected workspace's only pane was not the exact recorded task pane"
SECOND_TWO_INFO=$(lab workspace get "$SECOND_TWO_WSID") || fail "focused secondmate disappeared during projected create"
[ "$(printf '%s' "$SECOND_TWO_INFO" | jq -r '.result.workspace.focused')" = true ] \
  || fail "projected create or workspace.move stole focus from the captain's current space"
pass "real Herdr lab: every projected create, task-tab create, seeded prune, and move preserves active workspace and tab"

mkdir -p "$ACTIVE_SEEDED_CONTROL"
printf '%s\n' requested > "$ACTIVE_SEEDED_CONTROL/stage"
ACTIVE_SEEDED_START=$(log_line_count)
ACTIVE_SEEDED_FOCUS_START=$(focus_audit_line_count)
if spawn_task active-seeded "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/active-seeded.out" 2> "$EVIDENCE_ROOT/active-seeded.err"; then
  fail "active seeded-tab projection should refuse the prune"
fi
grep -F "target is the captain's active tab" "$EVIDENCE_ROOT/active-seeded.err" >/dev/null 2>&1 \
  || fail "active seeded-tab projection did not report its exact refusal"
ACTIVE_SEEDED_WSID=$(cat "$ACTIVE_SEEDED_CONTROL/workspace")
ACTIVE_SEEDED_TAB=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-tab")
ACTIVE_SEEDED_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane")
ACTIVE_SEEDED_TASK_PANE=$(cat "$ACTIVE_SEEDED_CONTROL/task-pane")
ACTIVE_SEEDED_FOCUS="$ACTIVE_SEEDED_WSID/$ACTIVE_SEEDED_TAB"
assert_focus_is "$ACTIVE_SEEDED_FOCUS" "active seeded-tab prune refusal"
assert_raw_presentation_mutations_preserved_since "$ACTIVE_SEEDED_FOCUS_START" "active seeded-tab prune refusal"
lab pane get "$ACTIVE_SEEDED_PANE" >/dev/null 2>&1 \
  || fail "active seeded-tab refusal removed the exact seeded pane"
if lab pane get "$ACTIVE_SEEDED_TASK_PANE" >/dev/null 2>&1; then
  fail "active seeded-tab failure did not abort-clean the non-active task pane"
fi
sed -n "$((ACTIVE_SEEDED_FOCUS_START + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v focus="$ACTIVE_SEEDED_FOCUS" -v pane="$ACTIVE_SEEDED_PANE" '
  $1 == "seeded-prune-refusal" && $2 == focus && $3 == focus && $4 == pane { found = 1 }
  END { exit(found ? 0 : 1) }
' || fail "guarded lab did not observe exact focus across the active seeded-tab refusal"
if sed -n "$((ACTIVE_SEEDED_START + 1)),\$p" "$HERDR_CALL_LOG" | grep -F $'pane\tclose\t'"$ACTIVE_SEEDED_PANE" >/dev/null 2>&1; then
  fail "active seeded-tab refusal closed the exact active pane"
fi
lab tab focus "$SECOND_TWO_TAB" >/dev/null || fail "could not restore the captured captain tab after the active seeded-tab fixture"
assert_focus_is "$CAPTAIN_FOCUS" "active seeded-tab fixture restoration"
rm -rf "$ACTIVE_SEEDED_CONTROL"
ACTIVE_SEEDED_CLEANUP_FOCUS_START=$(focus_audit_line_count)
ACTIVE_SEEDED_LOCK=$(session_presentation_lock_path) \
  || fail "could not resolve the session presentation lock for active-seeded cleanup"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" bash -c '
  . "$0/bin/fm-wake-lib.sh"
  . "$0/bin/backends/herdr.sh"
  lock=$1
  fm_lock_acquire_wait "$lock"
  fm_backend_herdr_projection_cleanup_exact "$2" "$3" "$4"
  fm_lock_release "$lock"
' "$ROOT" "$ACTIVE_SEEDED_LOCK" "$HERDR_LAB_SESSION" "$ACTIVE_SEEDED_TASK_PANE" "$ACTIVE_SEEDED_PANE"
assert_focus_is "$CAPTAIN_FOCUS" "active seeded-tab fixture cleanup"
assert_cleanup_focus_preserved "$ACTIVE_SEEDED_CLEANUP_FOCUS_START" "$ACTIVE_SEEDED_PANE" "$CAPTAIN_FOCUS"
rm -f "$HOME_DIR/state/active-seeded.herdr-presentation"
pass "real Herdr lab: active seeded-tab pruning refuses the exact pane and preserves exact focus"

LOCK_CONTENTION_READY="$TMP_ROOT/lock-contention-ready"
LOCK_CONTENTION_RELEASE="$TMP_ROOT/lock-contention-release"
LOCK_CONTENTION_PATH=$(session_presentation_lock_path) \
  || fail "could not resolve the session presentation lock for contention"
ROOT="$ROOT" READY="$LOCK_CONTENTION_READY" RELEASE="$LOCK_CONTENTION_RELEASE" \
  LOCK="$LOCK_CONTENTION_PATH" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  while [ ! -e "$RELEASE" ]; do sleep 0.05; done
  fm_lock_release "$LOCK"
' &
LOCK_CONTENTION_OWNER_PID=$!
while [ ! -e "$LOCK_CONTENTION_READY" ] && kill -0 "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null; do sleep 0.01; done
[ -e "$LOCK_CONTENTION_READY" ] || fail "could not hold the guarded lab presentation lock"
LOCK_CONTENTION_START=$(log_line_count)
LOCK_CONTENTION_FOCUS_START=$(focus_audit_line_count)
LOCK_CONTENTION_MOVE_START=$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')
if spawn_task lock-contended "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/lock-contended.out" 2> "$EVIDENCE_ROOT/lock-contended.err"; then
  LOCK_CONTENTION_STATUS=0
else
  LOCK_CONTENTION_STATUS=$?
fi
: > "$LOCK_CONTENTION_RELEASE"
wait "$LOCK_CONTENTION_OWNER_PID" || fail "guarded lab presentation lock owner failed"
LOCK_CONTENTION_OWNER_PID=
[ "$LOCK_CONTENTION_STATUS" -eq 0 ] \
  || fail "bounded presentation lock contention did not fall back to a successful flat spawn: $(cat "$EVIDENCE_ROOT/lock-contended.err")"
grep -F "presentation focus lock unavailable; using the ordinary flat layout without projection" "$EVIDENCE_ROOT/lock-contended.err" >/dev/null 2>&1 \
  || fail "bounded presentation lock contention did not warn about flat fallback"
LOCK_CONTENTION_META="$HOME_DIR/state/lock-contended.meta"
remember_meta_worktree "$LOCK_CONTENTION_META" >/dev/null
LOCK_CONTENTION_WSID=$(grep '^herdr_workspace_id=' "$LOCK_CONTENTION_META" | cut -d= -f2-)
[ "$LOCK_CONTENTION_WSID" = "$FIRSTMATE_WSID" ] \
  || fail "bounded lock contention did not use the ordinary flat firstmate workspace"
[ ! -e "$HOME_DIR/state/lock-contended.herdr-presentation" ] \
  || fail "bounded lock contention published a projection journal"
LOCK_CONTENTION_CALLS=$(sed -n "$((LOCK_CONTENTION_START + 1)),\$p" "$HERDR_CALL_LOG")
# session list is required to resolve the shared session lock path before the
# bounded acquire attempt; it must not unlock projection create or move.
if printf '%s\n' "$LOCK_CONTENTION_CALLS" | grep -E $'^(workspace\tcreate|pane\tclose|api\tschema)' >/dev/null 2>&1; then
  fail "bounded lock contention performed an unlocked projection mutation or ordering capability call"
fi
[ "$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')" = "$LOCK_CONTENTION_MOVE_START" ] \
  || fail "bounded lock contention invoked workspace.move"
assert_focus_is "$CAPTAIN_FOCUS" "bounded presentation lock flat fallback"
assert_raw_presentation_mutations_preserved_since "$LOCK_CONTENTION_FOCUS_START" "bounded presentation lock flat fallback"
teardown_task lock-contended "$HOME_DIR" > "$EVIDENCE_ROOT/lock-contended-teardown.out" 2> "$EVIDENCE_ROOT/lock-contended-teardown.err" \
  || fail "flat lock-contention fixture teardown failed"
assert_focus_is "$CAPTAIN_FOCUS" "bounded presentation lock flat fallback teardown"
pass "real Herdr lab: bounded lock contention warns and falls back flat without projection or focus drift"
PROJECTION_ORDER_START=$(log_line_count)

[ "$OFF_WT" = "$ON_WT" ] || fail "Treehouse did not reuse the same fixture worktree, so byte comparison is inconclusive"
normalize_meta "$OFF_META" > "$TMP_ROOT/off.meta.normalized"
normalize_meta "$ON_META" > "$TMP_ROOT/on.meta.normalized"
cmp -s "$TMP_ROOT/off.meta.normalized" "$TMP_ROOT/on.meta.normalized" \
  || fail "metadata changed beyond Herdr container IDs between opted-out and projected paths"

# Two real primary spawns begin concurrently.
# The fresh-spawn task-set lock may fail closed for one while the other
# publishes, in which case retry it only after the lock owner has completed.
# Their final relative order must match Herdr's actual serialized create order,
# rather than a task-name or priority guess.
CONCURRENT_FOCUS_AUDIT_START=$(focus_audit_line_count)
spawn_task order-a "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/order-a.out" 2> "$EVIDENCE_ROOT/order-a.err" &
ORDER_A_PID=$!
spawn_task order-b "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/order-b.out" 2> "$EVIDENCE_ROOT/order-b.err" &
ORDER_B_PID=$!
if wait "$ORDER_A_PID"; then ORDER_A_STATUS=0; else ORDER_A_STATUS=$?; fi
if wait "$ORDER_B_PID"; then ORDER_B_STATUS=0; else ORDER_B_STATUS=$?; fi
finish_concurrent_spawn order-a "$ORDER_A_STATUS" "$EVIDENCE_ROOT/order-a.out" "$EVIDENCE_ROOT/order-a.err"
finish_concurrent_spawn order-b "$ORDER_B_STATUS" "$EVIDENCE_ROOT/order-b.out" "$EVIDENCE_ROOT/order-b.err"
assert_focus_is "$CAPTAIN_FOCUS" "concurrent projected spawns"
assert_raw_presentation_mutations_preserved_since "$CONCURRENT_FOCUS_AUDIT_START" "concurrent projected spawns"
ORDER_A_META="$HOME_DIR/state/order-a.meta"
ORDER_B_META="$HOME_DIR/state/order-b.meta"
remember_meta_worktree "$ORDER_A_META" >/dev/null
remember_meta_worktree "$ORDER_B_META" >/dev/null

ORDER_LIST=$(lab workspace list) || fail "could not inspect concurrent presentation ordering"
CREATED_LABELS=$(projection_labels_from_log "$PROJECTION_ORDER_START")
EXPECTED_LABELS=$(printf 'firstmate\n%s\n%s\n2ndmate-alpha\n2ndmate-bravo' "$PROJECTED_LABEL" "$CREATED_LABELS")
ACTUAL_LABELS=$(printf '%s' "$ORDER_LIST" | jq -r '.result.workspaces[].label')
[ "$ACTUAL_LABELS" = "$EXPECTED_LABELS" ] || fail "workspace order was not firstmate, stable primary block, secondmates: $ACTUAL_LABELS"
PRIMARY_IDS=$(printf '%s' "$ORDER_LIST" | jq -r '
  .result.workspaces[]
  | select((.label | startswith("└ ")) or (.label | startswith("firstmate/")))
  | .workspace_id
')
MOVE_TARGETS=$(cut -f2 "$MOVE_CALL_LOG")
[ "$MOVE_TARGETS" = "$PRIMARY_IDS" ] \
  || fail "workspace.move targeted something other than each exact current projected-create id"
MOVE_INDEXES=$(cut -f3 "$MOVE_CALL_LOG")
[ "$MOVE_INDEXES" = $'1\n2\n3' ] \
  || fail "concurrent primary workers did not append stably to the contiguous block: $MOVE_INDEXES"
SECOND_ORDER_AFTER=$(printf '%s' "$ORDER_LIST" | jq -r '.result.workspaces[] | select(.label | startswith("2ndmate-")) | .workspace_id')
[ "$SECOND_ORDER_AFTER" = "$SECOND_ORDER_BEFORE" ] \
  || fail "primary workspace ordering changed secondmate relative order"
[ "$(lab workspace get "$SECOND_TWO_WSID" | jq -r '.result.workspace.focused')" = true ] \
  || fail "concurrent primary workspace ordering stole focus"
assert_no_ordering_lifecycle_calls_since "$PROJECTION_ORDER_START" "successful presentation ordering"
pass "real Herdr lab: concurrent primary workers form one stable contiguous block without active workspace/tab drift"

# Force only the raw move transport to fail after a safe projected create.
# The spawn must remain successful in Herdr's default appended order, with its
# exact task pane alive and no ordering-triggered cleanup.
FAIL_MOVER="$TMP_ROOT/fail-workspace-mover"
cat > "$FAIL_MOVER" <<'SH'
#!/usr/bin/env bash
exit 9
SH
chmod +x "$FAIL_MOVER"
FAIL_START=$(log_line_count)
FAIL_FOCUS_AUDIT_START=$(focus_audit_line_count)
FM_BACKEND_HERDR_WORKSPACE_MOVER="$FAIL_MOVER" \
  spawn_task order-fail "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/order-fail.out" 2> "$EVIDENCE_ROOT/order-fail.err" \
  || fail "move-failure projected spawn should still succeed: $(cat "$EVIDENCE_ROOT/order-fail.err")"
assert_focus_is "$CAPTAIN_FOCUS" "failed presentation ordering"
assert_raw_presentation_mutations_preserved_since "$FAIL_FOCUS_AUDIT_START" "failed presentation ordering"
grep -F "workspace move failed or had an ambiguous response" "$EVIDENCE_ROOT/order-fail.err" >/dev/null 2>&1 \
  || fail "forced workspace.move failure did not report only the best-effort warning"
ORDER_FAIL_META="$HOME_DIR/state/order-fail.meta"
remember_meta_worktree "$ORDER_FAIL_META" >/dev/null
ORDER_FAIL_WSID=$(grep '^herdr_workspace_id=' "$ORDER_FAIL_META" | cut -d= -f2-)
ORDER_FAIL_PANE=$(grep '^herdr_pane_id=' "$ORDER_FAIL_META" | cut -d= -f2-)
FAIL_LIST=$(lab workspace list) || fail "could not inspect the move-failure fallback"
[ "$(printf '%s' "$FAIL_LIST" | jq -r '.result.workspaces[-1].workspace_id')" = "$ORDER_FAIL_WSID" ] \
  || fail "workspace.move failure did not leave the safe worker in Herdr's default appended order"
lab pane get "$ORDER_FAIL_PANE" >/dev/null 2>&1 \
  || fail "workspace.move failure cleaned up the safely-created task pane"
FAIL_CLOSED_PANES=$(sed -n "$((FAIL_START + 1)),\$p" "$HERDR_CALL_LOG" | awk -F '\t' '$1 == "pane" && $2 == "close" { print $3 }')
[ "$(printf '%s\n' "$FAIL_CLOSED_PANES" | awk 'NF { n += 1 } END { print n + 0 }')" = 1 ] \
  || fail "move-failure spawn performed a pane close beyond the normal seeded-pane prune"
[ "$FAIL_CLOSED_PANES" != "$ORDER_FAIL_PANE" ] \
  || fail "move-failure spawn closed its exact task pane"
assert_no_ordering_lifecycle_calls_since "$FAIL_START" "failed presentation ordering"
pass "real Herdr lab: forced workspace.move failure leaves a successful worker in default order with a warning and no cleanup"

mkdir -p "$POST_CREATE_ABORT_CONTROL"
ABORT_START=$(log_line_count)
ABORT_FOCUS_START=$(focus_audit_line_count)
spawn_task abort-a "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/abort-a.out" 2> "$EVIDENCE_ROOT/abort-a.err" &
ABORT_A_PID=$!
spawn_task abort-b "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/abort-b.out" 2> "$EVIDENCE_ROOT/abort-b.err" &
ABORT_B_PID=$!
if wait "$ABORT_A_PID"; then ABORT_A_STATUS=0; else ABORT_A_STATUS=$?; fi
if wait "$ABORT_B_PID"; then ABORT_B_STATUS=0; else ABORT_B_STATUS=$?; fi
finish_concurrent_expected_abort abort-a "$ABORT_A_STATUS" "$EVIDENCE_ROOT/abort-a.out" "$EVIDENCE_ROOT/abort-a.err"
finish_concurrent_expected_abort abort-b "$ABORT_B_STATUS" "$EVIDENCE_ROOT/abort-b.out" "$EVIDENCE_ROOT/abort-b.err"
# The forced foreground_cwd is a plain non-git directory, which the discovery
# poll now screens out on every read rather than adopting, so the armed failure
# arrives as the poll's own deadline refusal naming that path.
grep -F "did not enter an isolated worktree" "$EVIDENCE_ROOT/abort-a.err" >/dev/null 2>&1 \
  || fail "post-create abort fixture A did not reach the armed validation failure"
grep -F "did not enter an isolated worktree" "$EVIDENCE_ROOT/abort-b.err" >/dev/null 2>&1 \
  || fail "post-create abort fixture B did not reach the armed validation failure"
ABORT_A_PANE=$(cat "$POST_CREATE_ABORT_CONTROL/abort-a/task-pane")
ABORT_B_PANE=$(cat "$POST_CREATE_ABORT_CONTROL/abort-b/task-pane")
ABORT_SEQUENCE=$(sed -n "$((ABORT_FOCUS_START + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v a="$ABORT_A_PANE" -v b="$ABORT_B_PANE" '
  $1 == "workspace-create" && $4 ~ /^└ abort-a · p:/ { print "create-a" }
  $1 == "workspace-create" && $4 ~ /^└ abort-b · p:/ { print "create-b" }
  $1 == "pane-close" && $4 == a { print "close-a" }
  $1 == "pane-close" && $4 == b { print "close-b" }
')
case "$ABORT_SEQUENCE" in
  $'create-a\nclose-a\ncreate-b\nclose-b'|$'create-b\nclose-b\ncreate-a\nclose-a') ;;
  *) fail "concurrent post-create abort cleanup interleaved outside the presentation lock: $ABORT_SEQUENCE" ;;
esac
ABORT_UNRESTORED=$(sed -n "$((ABORT_FOCUS_START + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v a="$ABORT_A_PANE" -v b="$ABORT_B_PANE" '
  ($1 == "workspace-create" || $1 == "tab-create" || $1 == "workspace-move" || ($1 == "pane-close" && $4 != a && $4 != b)) && $2 != $3 { print }
')
[ -z "$ABORT_UNRESTORED" ] \
  || fail "post-create abort create, prune, or move changed exact focus: $ABORT_UNRESTORED"
assert_focus_is "$CAPTAIN_FOCUS" "concurrent post-create abort cleanup"
assert_cleanup_focus_preserved "$ABORT_FOCUS_START" "$ABORT_A_PANE" "$CAPTAIN_FOCUS"
assert_cleanup_focus_preserved "$ABORT_FOCUS_START" "$ABORT_B_PANE" "$CAPTAIN_FOCUS"
assert_no_ordering_lifecycle_calls_since "$ABORT_START" "concurrent post-create abort cleanup"
for ABORT_PANE in "$ABORT_A_PANE" "$ABORT_B_PANE"; do
  if lab pane get "$ABORT_PANE" >/dev/null 2>&1; then
    fail "serialized post-create abort cleanup left exact task pane $ABORT_PANE alive"
  fi
done
[ ! -e "$HOME_DIR/state/abort-a.meta" ] && [ ! -e "$HOME_DIR/state/abort-b.meta" ] \
  || fail "post-create abort fixtures published task metadata before launch"
rm -rf "$POST_CREATE_ABORT_CONTROL"
rm -f "$HOME_DIR/state/abort-a.herdr-presentation" "$HOME_DIR/state/abort-b.herdr-presentation"
pass "real Herdr lab: concurrent post-create abort cleanup stays serialized with exact focus restoration"

SHAPE_CLEANUP_AUDIT_START=$(focus_audit_line_count)
teardown_task shape "$HOME_DIR" > "$EVIDENCE_ROOT/on-teardown.out" 2> "$EVIDENCE_ROOT/on-teardown.err" \
  || fail "projected teardown failed: $(cat "$EVIDENCE_ROOT/on-teardown.err")"
assert_focus_is "$CAPTAIN_FOCUS" "projected teardown"
assert_cleanup_focus_preserved "$SHAPE_CLEANUP_AUDIT_START" "$PROJECTED_PANE" "$CAPTAIN_FOCUS"
pass "real Herdr lab: Treehouse commands and metadata shape are byte-identical except for endpoint IDs and spawn incarnation"
if lab workspace get "$PROJECTED_WSID" >/dev/null 2>&1; then
  fail "closing the exact projected task pane did not remove its last-tab workspace"
fi
lab pane get "$SECOND_TWO_PANE" >/dev/null 2>&1 \
  || fail "projected teardown affected the focused secondmate workspace"
[ ! -e "$JOURNAL" ] || fail "confirmed projected teardown did not retire its presentation journal"
pass "real Herdr lab: exact task-pane close removes the projected workspace with no unrestored wrong-focus interval"

teardown_task order-a "$HOME_DIR" > "$EVIDENCE_ROOT/order-a-teardown.out" 2> "$EVIDENCE_ROOT/order-a-teardown.err" &
ORDER_A_TEARDOWN_PID=$!
teardown_task order-b "$HOME_DIR" > "$EVIDENCE_ROOT/order-b-teardown.out" 2> "$EVIDENCE_ROOT/order-b-teardown.err" &
ORDER_B_TEARDOWN_PID=$!
if wait "$ORDER_A_TEARDOWN_PID"; then ORDER_A_TEARDOWN_STATUS=0; else ORDER_A_TEARDOWN_STATUS=$?; fi
if wait "$ORDER_B_TEARDOWN_PID"; then ORDER_B_TEARDOWN_STATUS=0; else ORDER_B_TEARDOWN_STATUS=$?; fi
finish_concurrent_teardown order-a "$ORDER_A_TEARDOWN_STATUS" "$EVIDENCE_ROOT/order-a-teardown.out" "$EVIDENCE_ROOT/order-a-teardown.err"
finish_concurrent_teardown order-b "$ORDER_B_TEARDOWN_STATUS" "$EVIDENCE_ROOT/order-b-teardown.out" "$EVIDENCE_ROOT/order-b-teardown.err"
assert_focus_is "$CAPTAIN_FOCUS" "concurrent projected teardowns"
teardown_task order-fail "$HOME_DIR" > "$EVIDENCE_ROOT/order-fail-teardown.out" 2> "$EVIDENCE_ROOT/order-fail-teardown.err" \
  || fail "projected ordering failure fixture teardown failed"
assert_focus_is "$CAPTAIN_FOCUS" "failed-order projection teardown"
pass "real Herdr lab: concurrent projected cleanup is serialized and leaves active workspace/tab unchanged"

# Repeat full two-worker create, order, and cleanup waves.
# This exercises the focus guard after the original regression sequence and
# proves the shared presentation lock keeps concurrent operations composable.
for ROUND in 1 2 3; do
  mkdir -p "$HOME_DIR/data/focus-$ROUND-a" "$HOME_DIR/data/focus-$ROUND-b"
  write_ship_brief "$HOME_DIR" "focus-$ROUND-a" "Projection focus wave $ROUND fixture A."
  write_ship_brief "$HOME_DIR" "focus-$ROUND-b" "Projection focus wave $ROUND fixture B."
  WAVE_LOG_START=$(log_line_count)
  WAVE_FOCUS_START=$(focus_audit_line_count)
  spawn_task "focus-$ROUND-a" "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/focus-$ROUND-a.out" 2> "$EVIDENCE_ROOT/focus-$ROUND-a.err" &
  WAVE_A_PID=$!
  spawn_task "focus-$ROUND-b" "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/focus-$ROUND-b.out" 2> "$EVIDENCE_ROOT/focus-$ROUND-b.err" &
  WAVE_B_PID=$!
  if wait "$WAVE_A_PID"; then WAVE_A_STATUS=0; else WAVE_A_STATUS=$?; fi
  if wait "$WAVE_B_PID"; then WAVE_B_STATUS=0; else WAVE_B_STATUS=$?; fi
  finish_concurrent_spawn "focus-$ROUND-a" "$WAVE_A_STATUS" "$EVIDENCE_ROOT/focus-$ROUND-a.out" "$EVIDENCE_ROOT/focus-$ROUND-a.err"
  finish_concurrent_spawn "focus-$ROUND-b" "$WAVE_B_STATUS" "$EVIDENCE_ROOT/focus-$ROUND-b.out" "$EVIDENCE_ROOT/focus-$ROUND-b.err"
  remember_meta_worktree "$HOME_DIR/state/focus-$ROUND-a.meta" >/dev/null
  remember_meta_worktree "$HOME_DIR/state/focus-$ROUND-b.meta" >/dev/null
  assert_focus_is "$CAPTAIN_FOCUS" "focus wave $ROUND concurrent spawns"
  assert_raw_presentation_mutations_preserved_since "$WAVE_FOCUS_START" "focus wave $ROUND concurrent spawns"
  WAVE_LABELS=$(projection_labels_from_log "$WAVE_LOG_START")
  WAVE_EXPECTED=$(printf 'firstmate\n%s\n2ndmate-alpha\n2ndmate-bravo' "$WAVE_LABELS")
  WAVE_ACTUAL=$(lab workspace list | jq -r '.result.workspaces[] | select(.label == "firstmate" or (.label | startswith("└ ")) or (.label | startswith("2ndmate-"))) | .label')
  [ "$WAVE_ACTUAL" = "$WAVE_EXPECTED" ] \
    || fail "focus wave $ROUND lost stable contiguous ordering: $WAVE_ACTUAL"
  WAVE_SECOND_ORDER=$(lab workspace list | jq -r '.result.workspaces[] | select(.label | startswith("2ndmate-")) | .workspace_id')
  [ "$WAVE_SECOND_ORDER" = "$SECOND_ORDER_BEFORE" ] \
    || fail "focus wave $ROUND changed secondmate relative order"

  teardown_task "focus-$ROUND-a" "$HOME_DIR" > "$EVIDENCE_ROOT/focus-$ROUND-a-teardown.out" 2> "$EVIDENCE_ROOT/focus-$ROUND-a-teardown.err" &
  WAVE_A_TEARDOWN_PID=$!
  teardown_task "focus-$ROUND-b" "$HOME_DIR" > "$EVIDENCE_ROOT/focus-$ROUND-b-teardown.out" 2> "$EVIDENCE_ROOT/focus-$ROUND-b-teardown.err" &
  WAVE_B_TEARDOWN_PID=$!
  if wait "$WAVE_A_TEARDOWN_PID"; then WAVE_A_TEARDOWN_STATUS=0; else WAVE_A_TEARDOWN_STATUS=$?; fi
  if wait "$WAVE_B_TEARDOWN_PID"; then WAVE_B_TEARDOWN_STATUS=0; else WAVE_B_TEARDOWN_STATUS=$?; fi
  finish_concurrent_teardown "focus-$ROUND-a" "$WAVE_A_TEARDOWN_STATUS" "$EVIDENCE_ROOT/focus-$ROUND-a-teardown.out" "$EVIDENCE_ROOT/focus-$ROUND-a-teardown.err"
  finish_concurrent_teardown "focus-$ROUND-b" "$WAVE_B_TEARDOWN_STATUS" "$EVIDENCE_ROOT/focus-$ROUND-b-teardown.out" "$EVIDENCE_ROOT/focus-$ROUND-b-teardown.err"
  assert_focus_is "$CAPTAIN_FOCUS" "focus wave $ROUND concurrent teardowns"
  WAVE_REMAINING=$(lab workspace list | jq -r '.result.workspaces[].label')
  [ "$WAVE_REMAINING" = $'firstmate\n2ndmate-alpha\n2ndmate-bravo' ] \
    || fail "focus wave $ROUND cleanup left a projected workspace behind: $WAVE_REMAINING"
done
pass "real Herdr lab: three repeated concurrent create/order/cleanup waves have zero active workspace or tab drift"


# This suite owns its anchor and retires it before ending its own lab.
teardown_task "$ANCHOR_ID" "$HOME_DIR" > "$EVIDENCE_ROOT/td-anchor.out" 2> "$EVIDENCE_ROOT/td-anchor.err" \
  || fail "presentation anchor teardown failed: $(cat "$EVIDENCE_ROOT/td-anchor.err")"
[ ! -e "$ANCHOR_META" ] || fail "presentation anchor retained a task record"
presentation_fixture_finish fm-backend-herdr-presentation-e2e
