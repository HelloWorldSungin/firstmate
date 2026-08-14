#!/usr/bin/env bash
# Behavioral regressions for bin/fm-trigger-validation.sh.
#
# firstmate ends the ready-to-validate wait by triggering validation, so it owns
# the `resolved:` line that closes it (issue #136). These tests pin that the
# trigger script closes exactly that block, leaves a design `paused:` handoff and
# any keyed decision untouched, and writes no close line when the send failed or
# nothing is open - all read through the public open-decision fold rather than
# status-file bytes.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRIGGER="$ROOT/bin/fm-trigger-validation.sh"
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-trigger-validation)

# open-decision fold of a status file, read through the public classifier.
open_decisions() {  # <status-file>
  bash -c '. "$1"; status_open_decisions "$2"' _ "$CLASSIFY" "$1"
}

# Build a fake firstmate home with an empty state dir and return its path.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# Drop a fake fm-send at <path> that logs its args to $SEND_LOG and exits $SEND_RC
# (default 0). Lets a test assert the trigger message was relayed and drive the
# send-failure path without a real backend.
make_fake_send() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SEND_LOG:-/dev/null}"
exit "${SEND_RC:-0}"
SH
  chmod +x "$1"
}

# --- the fix: a ship ready-to-validate block is closed by the trigger --------
#
# Would fail if the script stopped appending the `resolved:` line, appended it on
# the wrong key so the fold still showed the default block, or never sent the
# trigger at all.
test_ship_ready_to_validate_block_closed_by_trigger() {
  local home fake_send send_log
  home=$(make_home ship)
  fake_send="$home/fakebin/fm-send.sh"
  mkdir -p "$(dirname "$fake_send")"
  make_fake_send "$fake_send"
  send_log="$home/send.log"
  fm_write_meta "$home/state/sample-ship.meta" \
    "window=firstmate:fm-sample-ship" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  cat > "$home/state/sample-ship.status" <<'EOF'
working: implementing the fix
blocked: implemented and committed, ready to validate
EOF

  SEND_LOG="$send_log" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_SEND_BIN="$fake_send" \
    "$TRIGGER" sample-ship /no-mistakes

  # The trigger message reached the worker.
  assert_grep '/no-mistakes' "$send_log" "trigger message was not relayed to the worker"
  # The ready-to-validate block is durably closed in the fold.
  [ -z "$(open_decisions "$home/state/sample-ship.status")" ] \
    || fail "ready-to-validate block stayed open after the trigger"
  # And only firstmate wrote the close line, once.
  local n
  n=$(grep -c '^resolved: firstmate triggered validation' "$home/state/sample-ship.status" || true)
  [ "$n" -eq 1 ] || fail "expected exactly one firstmate resolved line, found $n"
  pass "trigger closes the ship ready-to-validate block and relays the message"
}

# --- a design paused handoff opens no decision, so nothing is closed ---------
#
# Would fail if the script appended a spurious `resolved:` for a task that never
# opened a decision - which would be harmless to the fold but misleading noise.
test_design_paused_handoff_left_untouched() {
  local home fake_send
  home=$(make_home design)
  fake_send="$home/fakebin/fm-send.sh"
  mkdir -p "$(dirname "$fake_send")"
  make_fake_send "$fake_send"
  fm_write_meta "$home/state/sample-design.meta" \
    "window=firstmate:fm-sample-design" \
    "harness=claude" \
    "kind=design" \
    "mode=no-mistakes"
  cat > "$home/state/sample-design.status" <<'EOF'
working: drafting the ADR
paused: ADR complete and committed, ready to validate
EOF

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_SEND_BIN="$fake_send" \
    "$TRIGGER" sample-design /no-mistakes

  [ -z "$(open_decisions "$home/state/sample-design.status")" ] \
    || fail "a paused design handoff opened a phantom decision"
  assert_no_grep '^resolved:' "$home/state/sample-design.status" \
    "a design paused handoff that opened no decision got a spurious close line"
  pass "design paused handoff opens no decision and is left untouched"
}

# --- a keyed decision the worker still owes is not silently dropped ----------
#
# Would fail if the close line used a wildcard or the fold treated any later verb
# as superseding an open decision - the silent-drop failure mode the issue rules
# out, and the reason the fix must not weaken the fold.
test_keyed_decision_survives_default_unblock() {
  local home fake_send open
  home=$(make_home keyed)
  fake_send="$home/fakebin/fm-send.sh"
  mkdir -p "$(dirname "$fake_send")"
  make_fake_send "$fake_send"
  fm_write_meta "$home/state/sample-keyed.meta" \
    "window=firstmate:fm-sample-keyed" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  cat > "$home/state/sample-keyed.status" <<'EOF'
needs-decision [key=api-shape]: choose REST or GraphQL
blocked: implemented and committed, ready to validate
EOF

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_SEND_BIN="$fake_send" \
    "$TRIGGER" sample-keyed /no-mistakes

  open=$(open_decisions "$home/state/sample-keyed.status")
  printf '%s\n' "$open" | grep -q "$(printf 'api-shape\tneeds-decision\t')" \
    || fail "the keyed api-shape decision was silently dropped by the unblock"
  printf '%s\n' "$open" | grep -q "$(printf 'default\tblocked\t')" \
    && fail "the default ready-to-validate block was not closed"
  pass "the default block is closed while a keyed decision stays open"
}

# --- a failed or unconfirmed send leaves the block open ---------------------
#
# Would fail if the script appended the close line before confirming delivery,
# which would record "firstmate ended the wait" when the worker never received
# the trigger.
test_send_failure_leaves_block_open() {
  local home fake_send rc
  home=$(make_home sendfail)
  fake_send="$home/fakebin/fm-send.sh"
  mkdir -p "$(dirname "$fake_send")"
  make_fake_send "$fake_send"
  fm_write_meta "$home/state/sample-sendfail.meta" \
    "window=firstmate:fm-sample-sendfail" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  cat > "$home/state/sample-sendfail.status" <<'EOF'
blocked: implemented and committed, ready to validate
EOF

  SEND_RC=3 \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_SEND_BIN="$fake_send" \
    "$TRIGGER" sample-sendfail /no-mistakes
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failed send did not propagate non-zero from the trigger"
  [ -n "$(open_decisions "$home/state/sample-sendfail.status")" ] \
    || fail "the block was closed even though the trigger was never delivered"
  assert_no_grep '^resolved:' "$home/state/sample-sendfail.status" \
    "a close line was written despite a failed send"
  pass "a failed send leaves the ready-to-validate block open"
}

# --- refuses an unknown task and a missing home -----------------------------
#
# Would fail if the script operated on an unrecorded id or without an explicit
# home, both of which would let a close line land on the wrong status file.
test_refuses_unknown_task_and_missing_home() {
  local home fake_send rc
  home=$(make_home refuses)
  fake_send="$home/fakebin/fm-send.sh"
  mkdir -p "$(dirname "$fake_send")"
  make_fake_send "$fake_send"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_SEND_BIN="$fake_send" \
    "$TRIGGER" never-recorded /no-mistakes >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "trigger accepted a task with no recorded metadata"

  FM_STATE_OVERRIDE="$home/state" FM_SEND_BIN="$fake_send" \
    "$TRIGGER" sample /no-mistakes >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "trigger ran without an explicit FM_HOME"
  pass "trigger refuses an unknown task and a missing home"
}

test_ship_ready_to_validate_block_closed_by_trigger
test_design_paused_handoff_left_untouched
test_keyed_decision_survives_default_unblock
test_send_failure_leaves_block_open
test_refuses_unknown_task_and_missing_home

printf '\nall fm-trigger-validation tests passed\n'
