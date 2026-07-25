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
test_reset_requires_handoff_and_returns_to_pending
