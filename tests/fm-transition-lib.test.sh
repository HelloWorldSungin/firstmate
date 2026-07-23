#!/usr/bin/env bash
# tests/fm-transition-lib.test.sh - unit tests for the shared, backend-neutral
# normalized-transition shape and the single-owner status->action policy table
# (bin/fm-transition-lib.sh). Pure functions, no backend required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-transition-lib.sh
. "$ROOT/bin/fm-transition-lib.sh"

# --- record construction + accessors ----------------------------------------

REC=$(fm_transition_record "wG:pQ" "wG" "" "blocked" "claude")
[ "$(fm_transition_pane_id "$REC")" = "wG:pQ" ] || fail "pane_id accessor wrong: $REC"
[ "$(fm_transition_workspace_id "$REC")" = "wG" ] || fail "workspace_id accessor wrong: $REC"
[ "$(fm_transition_from_status "$REC")" = "" ] || fail "from_status should be empty: $REC"
[ "$(fm_transition_to_status "$REC")" = "blocked" ] || fail "to_status accessor wrong: $REC"
[ "$(fm_transition_agent "$REC")" = "claude" ] || fail "agent accessor wrong: $REC"
pass "fm_transition_record builds a 5-field record and every accessor reads its field"

# The record is exactly TAB-separated (five fields, four tabs).
TABS=$(printf '%s' "$REC" | tr -cd '\t' | wc -c | tr -d '[:space:]')
[ "$TABS" = "4" ] || fail "record must have exactly 4 TAB separators, got $TABS"
pass "fm_transition_record uses a single TAB between each of the five fields"

# A field containing a stray TAB/newline is scrubbed to spaces so the record
# never desyncs into more than five fields.
DIRTY=$(fm_transition_record "wG:pQ" "wG" "" "blocked" $'multi\tline\nagent')
DIRTY_TABS=$(printf '%s' "$DIRTY" | tr -cd '\t' | wc -c | tr -d '[:space:]')
[ "$DIRTY_TABS" = "4" ] || fail "a field with a stray TAB must not add columns, got $DIRTY_TABS tabs"
[ "$(fm_transition_to_status "$DIRTY")" = "blocked" ] || fail "stray-field scrub desynced to_status: $DIRTY"
pass "fm_transition_record scrubs TAB/newline out of fields so the record stays exactly five columns"

# Empty optional fields are allowed (herdr leaves workspace/agent empty on the
# reconcile path).
REC2=$(fm_transition_record "w1:p3" "" "" "working" "")
[ "$(fm_transition_pane_id "$REC2")" = "w1:p3" ] || fail "pane_id wrong with empty optionals: $REC2"
[ "$(fm_transition_to_status "$REC2")" = "working" ] || fail "to_status wrong with empty optionals: $REC2"
pass "fm_transition_record tolerates empty workspace/from/agent fields"

# --- the single-owner policy table ------------------------------------------

[ "$(fm_transition_policy blocked)" = "actionable" ] || fail "blocked must be actionable"
[ "$(fm_transition_policy working)" = "absorb" ] || fail "working must be absorb"
[ "$(fm_transition_policy idle)" = "defer" ] || fail "idle must be defer"
[ "$(fm_transition_policy "done")" = "defer" ] || fail "done must be defer"
[ "$(fm_transition_policy unknown)" = "fallback" ] || fail "unknown must be fallback"
[ "$(fm_transition_policy "")" = "fallback" ] || fail "empty status must be fallback"
[ "$(fm_transition_policy some-future-status)" = "fallback" ] || fail "an unrecognized status must be fallback"
pass "fm_transition_policy is the single-owner status->action table (blocked=actionable, working=absorb, idle/done=defer, else=fallback)"

# --- native cursor/agy turn-end completion (debounced, identity-gated) -------

# nc <expected-harness> <native-identity> <status> <prev> prints
# "<rc> <newstate>" so a test can assert both the signal decision
# (rc 0 = signal now) and the recorded state.
nc() {
  local out rc
  out=$(fm_transition_native_completion "$1" "$2" "$3" "$4"); rc=$?
  printf '%s %s' "$rc" "$out"
}

# A non-cursor/agy harness never signals and records no state (no-op).
[ "$(nc claude claude idle 'idle|0')" = "1 " ] || fail "non-cursor/agy harness must never signal a native completion"
[ "$(nc grok grok 'done' 'done|0')" = "1 " ] || fail "grok must never signal a native completion"
pass "fm_transition_native_completion is a no-op for non-cursor/agy harnesses"

# A recorded cursor/agy task whose pane now reports another native agent never
# signals. The mismatch also clears old debounce state, so restoring the expected
# adapter still requires two fresh settled polls.
[ "$(nc cursor claude idle 'idle|0')" = "1 unknown|0" ] || fail "a cursor task relaunched as claude must not signal"
[ "$(nc agy cursor 'done' 'done|0')" = "1 unknown|0" ] || fail "an agy task reporting native cursor must not signal"
[ "$(nc cursor cursor idle 'unknown|0')" = "1 idle|0" ] || fail "the expected native identity must re-arm on its first settled poll"
[ "$(nc cursor cursor idle 'idle|0')" = "0 idle|1" ] || fail "the expected native identity should signal only after a second settled poll"
pass "native completion requires the live identity to match the recorded cursor/agy harness"

# Debounce: a working->idle edge ARMS (no signal); the SECOND consecutive settled
# idle/done poll signals exactly once; further idle polls do not re-signal.
[ "$(nc cursor cursor working '')" = "1 working|0" ] || fail "working must arm to working|0 with no signal"
[ "$(nc cursor cursor idle 'working|0')" = "1 idle|0" ] || fail "first idle after working must ARM (idle|0), not signal"
[ "$(nc cursor cursor idle 'idle|0')" = "0 idle|1" ] || fail "second consecutive idle must SIGNAL once (idle|1)"
[ "$(nc cursor cursor idle 'idle|1')" = "1 idle|1" ] || fail "an already-signaled idle must not re-signal"
[ "$(nc cursor cursor 'done' 'idle|1')" = "1 done|1" ] || fail "done after a signaled idle must not re-signal"
pass "native completion debounces: arms on the first settled poll, signals once on the second"

# A working (or blocked) edge RE-ARMS so the next turn signals afresh.
[ "$(nc agy agy working 'idle|1')" = "1 working|0" ] || fail "working must re-arm (working|0)"
[ "$(nc agy agy idle 'working|0')" = "1 idle|0" ] || fail "idle after re-arm must ARM again"
[ "$(nc agy agy idle 'idle|0')" = "0 idle|1" ] || fail "second idle after re-arm must SIGNAL again"
[ "$(nc agy agy blocked 'idle|1')" = "1 blocked|0" ] || fail "blocked (a human-wait) must re-arm, not signal a completion"
pass "native completion re-arms on a working/blocked edge so each turn signals once"

# done is treated identically to idle as a settled turn-end.
[ "$(nc agy agy 'done' 'done|0')" = "0 done|1" ] || fail "two consecutive done polls must signal"
# An unknown/unreadable status holds the signaled flag and never signals.
[ "$(nc cursor cursor unknown 'idle|1')" = "1 unknown|1" ] || fail "unknown must hold signaled=1 and not signal"
[ "$(nc cursor cursor unknown 'idle|0')" = "1 unknown|0" ] || fail "unknown must hold signaled=0 and not signal"
# A fresh (no prior state) idle arms, then signals on the next idle - so a turn
# already complete when the watcher first sees it is still caught.
[ "$(nc cursor cursor idle '')" = "1 idle|0" ] || fail "a first-seen idle (no prior state) must ARM"
[ "$(nc cursor cursor idle 'idle|0')" = "0 idle|1" ] || fail "the next idle then signals even without observing the working phase"
pass "native completion handles done, unknown, and a first-seen-idle turn correctly"

echo "# fm-transition-lib.test.sh: all assertions passed"
