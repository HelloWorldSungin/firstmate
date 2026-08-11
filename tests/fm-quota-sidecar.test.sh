#!/usr/bin/env bash
# Behavior tests for fm-quota-sidecar.sh's safety boundary: only fresh,
# successful observations expose current windows, while stale, failed, missing,
# malformed, and clock-skewed sources remain explicit UNKNOWN evidence without
# failing intake, and a dropped configuration override is never silent.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-quota-sidecar.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-sidecar-tests)

iso_at() { # <offset-seconds-from-now>
  jq -rn --argjson now "$(date -u +%s)" --argjson offset "$1" '($now + $offset) | todate'
}

FRESH_AT=$(iso_at 0)
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

write_raw_record() { # <directory> <provider>, document on stdin
  local directory=$1 provider=$2
  mkdir -p "$directory"
  cat > "$directory/$provider.json"
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
rm -f "$fresh_dir/cursor.json"
pass "missing and unparseable provider files remain UNKNOWN without breaking intake"

# The producer runs on another host, so both clocks drift in both directions.
# The reader tolerates a bounded drift around the valid age interval and names
# anything larger, rather than either trusting a future stamp or reporting a
# healthy producer as unusable for one second of skew.
skew_dir="$TMP_ROOT/skew"
write_record "$skew_dir" cerebras "$(iso_at 120)" "$(iso_at 120)" ok 71
ahead=$(run_reader "$skew_dir" cerebras) || fail "producer-ahead drift exited nonzero"
[ "$(jq -r '.clock_skew_tolerance_seconds' <<<"$ahead")" = 300 ] || fail "the applied skew tolerance was not disclosed"
[ "$(jq -r '.providers[0].evidence_status' <<<"$ahead")" = CURRENT ] || fail "producer-ahead drift inside the tolerance was not CURRENT"
[ "$(jq -r '.providers[0].captured_age_seconds < 0' <<<"$ahead")" = true ] || fail "the observed negative age was not preserved"
[ "$(jq -r '.providers[0].last_attempt_age_seconds < 0' <<<"$ahead")" = true ] || fail "the observed negative attempt age was not preserved"

write_record "$skew_dir" cerebras "$(iso_at 900)" "$(iso_at 900)" ok 71
far_ahead=$(run_reader "$skew_dir" cerebras) || fail "beyond-tolerance skew exited nonzero"
[ "$(jq -r '.providers[0].evidence_status' <<<"$far_ahead")" = UNKNOWN ] || fail "a far-future timestamp was not UNKNOWN"
[ "$(jq -r '.providers[0].reason' <<<"$far_ahead")" = clock_skew ] || fail "beyond-tolerance skew was not named as clock skew"
[ "$(jq -r '.providers[0] | has("windows")' <<<"$far_ahead")" = false ] || fail "skewed numbers were presented as current windows"
[ "$(jq -r '.providers[0].last_known_windows[0].percent_remaining' <<<"$far_ahead")" = 71 ] || fail "skewed last-known window was not retained"

write_record "$skew_dir" cerebras "$(iso_at -200)" "$(iso_at -200)" ok 71
behind=$(run_reader "$skew_dir" cerebras) || fail "producer-behind drift exited nonzero"
[ "$(jq -r '.providers[0].evidence_status' <<<"$behind")" = CURRENT ] || fail "producer-behind drift inside the tolerance was not CURRENT"

write_record "$skew_dir" cerebras "$(iso_at -500)" "$(iso_at -500)" ok 71
far_behind=$(run_reader "$skew_dir" cerebras) || fail "beyond-tolerance age exited nonzero"
[ "$(jq -r '.providers[0].reason' <<<"$far_behind")" = stale ] || fail "an age past the window plus tolerance was not stale"
pass "clock drift is tolerated symmetrically to a bound and named explicitly past it"

mixed_dir="$TMP_ROOT/mixed"
write_record "$mixed_dir" minimax "$FRESH_AT" "$FRESH_AT" ok 90
write_record "$mixed_dir" zai "$STALE_AT" "$STALE_AT" ok 10
mixed=$(run_reader "$mixed_dir") || fail "mixed-directory discovery exited nonzero"
[ "$(jq -r '.providers | length' <<<"$mixed")" = 2 ] || fail "discovery did not read both published providers"
[ "$(jq -r '.evidence_status' <<<"$mixed")" = PARTIAL ] || fail "a current-plus-unknown aggregate was not PARTIAL"
[ "$(jq -r '[.providers[] | select(.evidence_status == "CURRENT")] | length' <<<"$mixed")" = 1 ] || fail "PARTIAL did not come from exactly one current provider"
[ "$(jq -r 'has("reason")' <<<"$mixed")" = false ] || fail "a non-empty aggregate carried an empty-case reason"
pass "the aggregate reports PARTIAL when only some providers are current"

# docs/configuration.md owns these producer constraints; the reader enforces
# every one of them rather than guessing at a non-conforming document.
contract_dir="$TMP_ROOT/contract"
offset_at=${FRESH_AT%Z}+00:00
write_raw_record "$contract_dir" offsetzone <<JSON
{
  "schema": "fm-quota-sidecar.v1",
  "provider": "offsetzone",
  "captured_at": "$offset_at",
  "last_attempt_at": "$offset_at",
  "status": "ok",
  "windows": [{"id": "session", "percent_remaining": 50, "resets_at": null}]
}
JSON
offset=$(run_reader "$contract_dir" offsetzone) || fail "offset-timestamp document exited nonzero"
[ "$(jq -r '.providers[0].reason' <<<"$offset")" = invalid_schema ] || fail "a numeric UTC offset was accepted for a Z-suffixed timestamp"

write_raw_record "$contract_dir" spacedwindow <<JSON
{
  "schema": "fm-quota-sidecar.v1",
  "provider": "spacedwindow",
  "captured_at": "$FRESH_AT",
  "last_attempt_at": "$FRESH_AT",
  "status": "ok",
  "windows": [{"id": "5h window", "percent_remaining": 50, "resets_at": null}]
}
JSON
spaced=$(run_reader "$contract_dir" spacedwindow) || fail "unsafe window id document exited nonzero"
[ "$(jq -r '.providers[0].reason' <<<"$spaced")" = invalid_schema ] || fail "a window id outside the documented form was accepted"

write_raw_record "$contract_dir" nowindows <<JSON
{
  "schema": "fm-quota-sidecar.v1",
  "provider": "nowindows",
  "captured_at": "$FRESH_AT",
  "last_attempt_at": "$FRESH_AT",
  "status": "ok",
  "windows": []
}
JSON
empty_windows=$(run_reader "$contract_dir" nowindows) || fail "windowless document exited nonzero"
[ "$(jq -r '.providers[0].evidence_status' <<<"$empty_windows")" = UNKNOWN ] || fail "a document with no observation behind it was not UNKNOWN"
pass "documents outside the owned producer contract stay UNKNOWN rather than partially usable"

# An override the operator set deliberately must never be dropped in silence,
# and both entry points have to agree about what a positive count of seconds is.
override_status=0
override_message=$(FM_QUOTA_SIDECAR_DIR="$fresh_dir" FM_QUOTA_SIDECAR_FRESHNESS_SECONDS=1h "$SCRIPT" minimax 2>&1) \
  || override_status=$?
[ "$override_status" = 2 ] || fail "a non-integer freshness environment override was not rejected: $override_message"
case "$override_message" in
  *FM_QUOTA_SIDECAR_FRESHNESS_SECONDS*) ;;
  *) fail "the rejected environment override did not name its source: $override_message" ;;
esac

override_status=0
FM_QUOTA_SIDECAR_DIR="$fresh_dir" FM_QUOTA_SIDECAR_FRESHNESS_SECONDS=0 "$SCRIPT" minimax >/dev/null 2>&1 \
  || override_status=$?
[ "$override_status" = 2 ] || fail "a zero freshness environment override was not rejected"

override_status=0
FM_QUOTA_SIDECAR_DIR="$fresh_dir" "$SCRIPT" --freshness-seconds 0 minimax >/dev/null 2>&1 || override_status=$?
[ "$override_status" = 2 ] || fail "a zero freshness command-line override was not rejected"

padded=$(FM_QUOTA_SIDECAR_DIR="$fresh_dir" FM_QUOTA_SIDECAR_FRESHNESS_SECONDS=010800 "$SCRIPT" minimax) \
  || fail "a leading-zero freshness override was rejected"
[ "$(jq -r '.freshness_seconds' <<<"$padded")" = 10800 ] || fail "a leading-zero override was not read as decimal seconds"
pass "invalid freshness overrides are rejected at both entry points and leading zeros are decimal"
