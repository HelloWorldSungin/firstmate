#!/usr/bin/env bash
# Behavior tests for fm-quota-sidecar.sh's safety boundary: only fresh,
# successful observations expose current windows, while stale, failed, missing,
# and malformed sources remain explicit UNKNOWN evidence without failing intake.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-quota-sidecar.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-sidecar-tests)
FRESH_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STALE_AT=2000-01-01T00:00:00Z
SECRET_SENTINEL='sk-secret-must-not-be-rendered'

write_record() { # <directory> <provider> <captured-at> <attempt-at> <status> <remaining>
  local directory=$1 provider=$2 captured=$3 attempted=$4 status=$5 remaining=$6
  mkdir -p "$directory"
  jq -n \
    --arg provider "$provider" \
    --arg captured "$captured" \
    --arg attempted "$attempted" \
    --arg status "$status" \
    --arg secret "$SECRET_SENTINEL" \
    --argjson remaining "$remaining" '{
      schema: "fm-quota-sidecar.v1",
      provider: $provider,
      captured_at: $captured,
      last_attempt_at: $attempted,
      status: $status,
      source: $secret,
      error: $secret,
      windows: [{
        id: "session",
        label: $secret,
        percent_remaining: $remaining,
        resets_at: null,
        credential: $secret
      }]
    }' > "$directory/$provider.json"
}

run_reader() { # <directory> [provider ...]
  local directory=$1
  shift
  FM_QUOTA_SIDECAR_DIR="$directory" \
    FM_QUOTA_SIDECAR_FRESHNESS_SECONDS=60 \
    "$SCRIPT" "$@"
}

fresh_dir="$TMP_ROOT/fresh"
write_record "$fresh_dir" minimax "$FRESH_AT" "$FRESH_AT" ok 97
fresh=$(run_reader "$fresh_dir" minimax) || fail "fresh sidecar read exited nonzero"
[ "$(jq -r '.evidence_status' <<<"$fresh")" = CURRENT ] || fail "fresh aggregate was not CURRENT"
[ "$(jq -r '.providers[0].evidence_status' <<<"$fresh")" = CURRENT ] || fail "fresh provider was not CURRENT"
[ "$(jq -r '.providers[0].windows[0].percent_remaining' <<<"$fresh")" = 97 ] || fail "fresh window was not emitted"
[ "$(jq -r '.providers[0].captured_age_seconds | type' <<<"$fresh")" = number ] || fail "fresh captured age was not numeric"
[ "$(jq -r '.providers[0].last_attempt_age_seconds | type' <<<"$fresh")" = number ] || fail "fresh attempt age was not numeric"
[ "$(jq -r '.providers[0] | has("last_known_windows")' <<<"$fresh")" = false ] || fail "fresh record was mislabeled last-known"
case "$fresh" in
  *"$SECRET_SENTINEL"*) fail "fresh projection disclosed an unapproved source field" ;;
esac
pass "fresh successful records expose current windows and both ages"

stale_dir="$TMP_ROOT/stale"
write_record "$stale_dir" zai "$STALE_AT" "$STALE_AT" ok 99
stale=$(run_reader "$stale_dir" zai) || fail "stale sidecar read exited nonzero"
[ "$(jq -r '.providers[0].evidence_status' <<<"$stale")" = UNKNOWN ] || fail "stale record was not UNKNOWN"
[ "$(jq -r '.providers[0].reason' <<<"$stale")" = stale ] || fail "stale record did not name its reason"
[ "$(jq -r '.providers[0] | has("windows")' <<<"$stale")" = false ] || fail "stale numbers were presented as current windows"
[ "$(jq -r '.providers[0].last_known_windows[0].percent_remaining' <<<"$stale")" = 99 ] || fail "stale last-known window was not retained"
pass "stale records retain diagnostic numbers only as UNKNOWN last-known windows"

error_dir="$TMP_ROOT/error"
write_record "$error_dir" opencode-go "$FRESH_AT" "$FRESH_AT" error 88
error=$(run_reader "$error_dir" opencode-go) || fail "error sidecar read exited nonzero"
[ "$(jq -r '.providers[0].evidence_status' <<<"$error")" = UNKNOWN ] || fail "producer error was not UNKNOWN"
[ "$(jq -r '.providers[0].reason' <<<"$error")" = source_error ] || fail "producer error did not name its reason"
[ "$(jq -r '.providers[0] | has("windows")' <<<"$error")" = false ] || fail "failed producer numbers were presented as current windows"
[ "$(jq -r '.providers[0].last_known_windows[0].percent_remaining' <<<"$error")" = 88 ] || fail "failed producer's last-known window was not retained"
case "$error" in
  *"$SECRET_SENTINEL"*) fail "error projection disclosed producer error or source content" ;;
esac
pass "producer errors retain diagnostic numbers without presenting current quota"

missing_dir="$TMP_ROOT/not-mounted"
missing=$(run_reader "$missing_dir" cursor) || fail "missing directory exited nonzero"
[ "$(jq -r '.evidence_status' <<<"$missing")" = UNKNOWN ] || fail "missing directory aggregate was not UNKNOWN"
[ "$(jq -r '.providers[0].reason' <<<"$missing")" = missing_directory ] || fail "missing directory reason was not explicit"
[ "$(jq -r '.providers[0].last_known_windows | length' <<<"$missing")" = 0 ] || fail "missing directory fabricated windows"
empty_missing=$(run_reader "$missing_dir") || fail "unmounted share without provider arguments exited nonzero"
[ "$(jq -r '.evidence_status' <<<"$empty_missing")" = UNKNOWN ] || fail "unmounted share without providers was not UNKNOWN"
[ "$(jq -r '.reason' <<<"$empty_missing")" = missing_directory ] || fail "unmounted share aggregate reason was not explicit"
pass "an unmounted sidecar share degrades cleanly to UNKNOWN"

missing_provider=$(run_reader "$fresh_dir" cursor) || fail "missing provider exited nonzero"
[ "$(jq -r '.providers[0].reason' <<<"$missing_provider")" = missing_provider ] || fail "missing provider was not explicit UNKNOWN"
printf '{not-json\n' > "$fresh_dir/cursor.json"
invalid=$(run_reader "$fresh_dir" cursor) || fail "unparseable provider exited nonzero"
[ "$(jq -r '.providers[0].reason' <<<"$invalid")" = invalid_json ] || fail "unparseable provider was not explicit UNKNOWN"
pass "missing and unparseable provider files remain UNKNOWN without breaking intake"
