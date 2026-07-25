#!/usr/bin/env bash
# Behavior tests for the Claude-backed design context telemetry and hard ceiling.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTEXT="$ROOT/bin/fm-design-context.sh"
TMP_ROOT=$(fm_test_tmproot fm-design-context)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
TRANSCRIPT="$TMP_ROOT/session.jsonl"
mkdir -p "$STATE"

run_turn_end() { # <id> <limit> <payload>
  local id=$1 limit=$2 payload=$3
  printf '%s\n' "$payload" | \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FM_DESIGN_CONTEXT_HARD_LIMIT="$limit" \
      "$CONTEXT" turn-end "$id" "$STATE/$id.turn-ended"
}

show_context() { # <id> <limit>
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DESIGN_CONTEXT_HARD_LIMIT="$2" "$CONTEXT" show "$1"
}

test_pending_before_first_stop() {
  local out
  out=$(show_context design-pending 110000)
  [ "$out" = "context=pending/110000 turns=0 ceiling=0 telemetry=pending" ] \
    || fail "pre-first-turn telemetry was not a safe pending value: $out"
  pass "design context reports pending before the first Stop hook"
}

test_tracks_latest_context_and_unique_turns() {
  local id=design-track out
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","requestId":"req-1","isSidechain":false,"message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":5}}}
{"type":"assistant","requestId":"req-1","isSidechain":false,"message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":7}}}
{"type":"assistant","requestId":"side","isSidechain":true,"message":{"usage":{"input_tokens":999}}}
{"type":"assistant","requestId":"req-2","isSidechain":false,"message":{"usage":{"input_tokens":20,"cache_creation_input_tokens":40,"cache_read_input_tokens":60,"output_tokens":8}}}
EOF
  run_turn_end "$id" 200 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  out=$(show_context "$id" 200)
  [ "$out" = "context=128/200 turns=2 ceiling=0 telemetry=available" ] \
    || fail "context metrics were wrong: $out"
  assert_present "$STATE/$id.turn-ended" "context helper did not preserve the turn-end wake"
  assert_absent "$STATE/$id.status" "below-ceiling telemetry emitted a noisy status event"
  pass "design context tracks the latest main-chain position and unique session turns"
}

test_hard_ceiling_blocks_once() {
  local id=design-ceiling out
  run_turn_end "$id" 120 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  out=$(show_context "$id" 120)
  [ "$out" = "context=128/120 turns=2 ceiling=1 telemetry=available" ] \
    || fail "hard ceiling was not recorded: $out"
  assert_grep "blocked [key=context-ceiling]" "$STATE/$id.status" \
    "hard ceiling did not wake firstmate with a keyed blocker"
  run_turn_end "$id" 120 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  [ "$(grep -cF '[key=context-ceiling]' "$STATE/$id.status")" -eq 1 ] \
    || fail "repeated Stop hooks duplicated the hard-ceiling blocker"
  printf 'resolved [key=context-ceiling]: fresh design context launched\n' >> "$STATE/$id.status"
  run_turn_end "$id" 120 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  [ "$(grep -cF 'blocked [key=context-ceiling]' "$STATE/$id.status")" -eq 2 ] \
    || fail "a later design context could not reopen the hard-ceiling blocker"
  pass "design hard ceiling fails closed exactly once"
}

test_missing_telemetry_blocks_once() {
  local id=design-missing out
  run_turn_end "$id" 120 '{"transcript_path":"/missing/design-transcript.jsonl"}'
  out=$(show_context "$id" 120)
  [ "$out" = "context=unknown/120 turns=unknown ceiling=1 telemetry=unavailable" ] \
    || fail "missing transcript did not fail closed: $out"
  assert_grep "blocked [key=context-telemetry]" "$STATE/$id.status" \
    "missing transcript did not create a supervisor-actionable blocker"
  run_turn_end "$id" 120 '{}'
  [ "$(grep -cF '[key=context-telemetry]' "$STATE/$id.status")" -eq 1 ] \
    || fail "repeated telemetry failures duplicated the blocker"
  pass "unavailable design telemetry fails closed exactly once"
}

# The Stop hook replaces the plain `touch <turn-end>` wake, so a helper failure
# must never cost firstmate the turn-end backstop it used to get for free.
test_wake_survives_helper_failure() {
  local id=design-wake status
  set +e
  printf '{}\n' | FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DESIGN_CONTEXT_HARD_LIMIT=not-a-number \
    "$CONTEXT" turn-end "$id" "$STATE/$id.turn-ended" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 1 "$status" "a malformed hard limit should still fail the helper"
  assert_present "$STATE/$id.turn-ended" \
    "a failing telemetry helper swallowed the turn-end wake"
  assert_absent "$STATE/$id.design-context" \
    "a rejected hard limit still wrote context telemetry"
  pass "the turn-end wake survives a telemetry helper failure"
}

# The Stop hook fires after the worker's LAST turn too, including the one that
# appended `done:`. A backstop blocker landing after a terminal event has no
# consumer, and it reopens the decision fold (origin_open_decisions only clears
# on a terminal LAST line), so teardown would refuse a task that already passed
# its own completion gate.
test_runtime_appends_nothing_after_a_terminal_event() {
  local id=design-terminal out last
  for last in \
    'done: ADR docs/adr/0007-x.md; PR https://example.invalid/pr/7 checks green; decisions: two' \
    'done: ADR docs/adr/0007-x.md; PR https://example.invalid/pr/7; decisions: two' \
    'done: ADR docs/adr/0007-x.md; ready in branch fm/design-terminal; decisions: two' \
    'failed: could not reach an ADR'; do
    printf '%s\n' "$last" > "$STATE/$id.status"
    run_turn_end "$id" 120 "{\"transcript_path\":\"$TRANSCRIPT\"}"
    assert_no_grep "blocked [key=context-ceiling]" "$STATE/$id.status" \
      "the ceiling backstop reopened the decision fold after: $last"
    run_turn_end "$id" 120 '{"transcript_path":"/missing/design-transcript.jsonl"}'
    assert_no_grep "blocked [key=context-telemetry]" "$STATE/$id.status" \
      "the telemetry backstop reopened the decision fold after: $last"
  done

  printf 'done: ADR docs/adr/0007-x.md; PR https://example.invalid/pr/7 checks green; decisions: two\n' \
    > "$STATE/$id.status"
  run_turn_end "$id" 120 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  out=$(show_context "$id" 120)
  [ "$out" = "context=128/120 turns=2 ceiling=1 telemetry=available" ] \
    || fail "a terminal event should still refresh telemetry: $out"
  pass "the runtime appends no status event after a final delivery event"
}

# In no-mistakes mode the design brief has the worker append a pre-validation
# `done: ADR {path}; decisions: ...` and THEN drive the whole review, fix, push,
# PR, and CI phase. That phase is the longest and most token-heavy stretch of the
# session, so treating its opening done as terminal would silently disable the
# mechanical pacing backstop exactly where the intent requires it most.
test_pre_validation_done_still_paces_the_worker() {
  local id=design-prevalidation
  printf 'done: ADR docs/adr/0007-x.md; decisions: chose the evented reader\n' \
    > "$STATE/$id.status"
  run_turn_end "$id" 120 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  assert_grep "blocked [key=context-ceiling]" "$STATE/$id.status" \
    "the ceiling backstop went silent during the no-mistakes phase"

  printf 'done: ADR docs/adr/0007-x.md; decisions: chose the evented reader\n' \
    > "$STATE/$id.status"
  run_turn_end "$id" 120 '{"transcript_path":"/missing/design-transcript.jsonl"}'
  assert_grep "blocked [key=context-telemetry]" "$STATE/$id.status" \
    "the telemetry backstop went silent during the no-mistakes phase"
  run_turn_end "$id" 120 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  assert_grep "resolved [key=context-telemetry]" "$STATE/$id.status" \
    "the runtime could not close its own key during the no-mistakes phase"
  pass "a pre-validation done keeps both backstops live through validation"
}

runtime_treats_as_terminal() { # <id> <status-line>
  printf '%s\n' "$2" > "$STATE/$1.status"
  run_turn_end "$1" 120 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  ! grep -qF 'blocked [key=context-ceiling]' "$STATE/$1.status"
}

# The runtime recognizes a final delivery event by the marker its mode's done
# template carries, so the predicate and bin/fm-brief.sh's design templates are
# one contract split across two files. Drive the real scaffolds rather than
# restating their wording here: a reworded template must fail this test instead
# of silently disabling the pacing backstop for that delivery mode.
test_terminal_predicate_tracks_the_brief_templates() {
  local home proj id brief templates count i line
  home="$TMP_ROOT/brief-coupling"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF

  for proj in nm-proj direct-proj local-proj; do
    id="coupling-$proj"
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      "$ROOT/bin/fm-brief.sh" "$id" "$proj" --design >/dev/null 2>&1 \
      || fail "design brief failed to scaffold for $proj"
    brief="$home/data/$id/brief.md"
    templates=$(grep -o '`done: [^`]*`' "$brief" | tr -d '`' \
      | sed -e 's|{path}|docs/adr/0007-x.md|g' \
            -e 's|{url}|https://example.invalid/pr/7|g' \
            -e 's|{concise summary}|two|g')
    [ -n "$templates" ] || fail "the $proj design brief declares no done template"
    count=$(printf '%s\n' "$templates" | wc -l | tr -d ' ')
    i=0
    while IFS= read -r line; do
      i=$((i + 1))
      if [ "$i" -eq "$count" ]; then
        runtime_treats_as_terminal "$id-t$i" "$line" \
          || fail "$proj final done template is not terminal to the runtime: $line"
      else
        ! runtime_treats_as_terminal "$id-t$i" "$line" \
          || fail "$proj pre-validation done template silenced the backstop: $line"
      fi
    done <<EOF
$templates
EOF
  done
  pass "the runtime terminal predicate matches every design brief done template"
}

# The worker never opens context-telemetry, so no worker-side closure rule
# reaches it. The runtime owns the key and must close it when the condition it
# reported clears, or a transient unreadable transcript wedges the task behind
# its own decision gate for the rest of the session.
test_recovered_telemetry_closes_its_own_key() {
  local id=design-recover
  run_turn_end "$id" 200 '{"transcript_path":"/missing/design-transcript.jsonl"}'
  assert_grep "blocked [key=context-telemetry]" "$STATE/$id.status" \
    "an unreadable transcript did not open the telemetry blocker"
  run_turn_end "$id" 200 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  assert_grep "resolved [key=context-telemetry]" "$STATE/$id.status" \
    "recovered telemetry left its own blocker open"
  [ "$(tail -1 "$STATE/$id.status" | cut -d' ' -f1)" = resolved ] \
    || fail "the telemetry closure was not the latest event for the key"
  run_turn_end "$id" 200 "{\"transcript_path\":\"$TRANSCRIPT\"}"
  [ "$(grep -cF 'resolved [key=context-telemetry]' "$STATE/$id.status")" -eq 1 ] \
    || fail "a healthy turn kept re-closing an already-closed telemetry key"
  pass "recovered design telemetry closes the key the runtime opened"
}

# A Claude hook timeout terminates the helper with SIGTERM, and bash runs no
# EXIT trap for an untrapped signal. The wake must survive that path too, or the
# jq pass this helper added over the whole transcript can cost a turn-end wake
# the plain `touch` hook could never lose.
test_wake_survives_signal_termination() {
  local id=design-signal fakebin marker release pid status i
  fakebin=$(fm_fakebin "$TMP_ROOT/signal")
  marker="$TMP_ROOT/signal/jq-entered"
  release="$TMP_ROOT/signal/jq-release"
  rm -f "$marker" "$release"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
printf 'entered\n' > "$marker"
i=0
while [ ! -f "$release" ] && [ "\$i" -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done
exit 1
SH
  chmod +x "$fakebin/jq"

  printf '{}\n' | PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DESIGN_CONTEXT_HARD_LIMIT=120 \
    "$CONTEXT" turn-end "$id" "$STATE/$id.turn-ended" >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ ! -f "$marker" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$marker" ] || { kill "$pid" 2>/dev/null || true; fail "helper never reached its transcript read"; }

  kill -TERM "$pid" 2>/dev/null || fail "could not signal the running helper"
  : > "$release"
  set +e
  wait "$pid"
  status=$?
  set -e
  expect_code 143 "$status" "the helper did not exit through its signal wake"
  assert_present "$STATE/$id.turn-ended" \
    "SIGTERM during a transcript read swallowed the turn-end wake"
  pass "the turn-end wake survives signal termination"
}

test_reset_requires_handoff_and_returns_to_pending() {
  local id=design-reset out status
  set +e
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DESIGN_CONTEXT_HARD_LIMIT=120 "$CONTEXT" reset "$id" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 1 "$status" "context reset without a handoff should fail"

  mkdir -p "$HOME_DIR/data/$id"
  printf '# Handoff\n' > "$HOME_DIR/data/$id/handoff.md"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DESIGN_CONTEXT_HARD_LIMIT=120 "$CONTEXT" reset "$id"
  out=$(show_context "$id" 120)
  [ "$out" = "context=pending/120 turns=0 ceiling=0 telemetry=pending" ] \
    || fail "handoff reset did not return context telemetry to pending: $out"
  pass "design context resets only after a durable handoff"
}

test_pending_before_first_stop
test_tracks_latest_context_and_unique_turns
test_hard_ceiling_blocks_once
test_missing_telemetry_blocks_once
test_wake_survives_helper_failure
test_runtime_appends_nothing_after_a_terminal_event
test_pre_validation_done_still_paces_the_worker
test_terminal_predicate_tracks_the_brief_templates
test_recovered_telemetry_closes_its_own_key
test_wake_survives_signal_termination
test_reset_requires_handoff_and_returns_to_pending
