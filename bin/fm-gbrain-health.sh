#!/usr/bin/env bash
# fm-gbrain-health.sh - read-only GBrain health snapshot for the dashboard.
#
# The dashboard health strip and the GBrain panel need one consistent answer
# to "what does this home's brain look like right now?". This command is that
# answer. It is presence-gated, fail-closed, bounded by a hard timeout, and
# returns one JSON object whose every value is a fact about THIS home's brain
# as observed within that budget. A slow, stopped, or unconfigured brain is
# reported as such; it is never reported as healthy.
#
# Usage:
#   fm-gbrain-health.sh [--json] [--timeout <seconds>]
#
# Options:
#   --json        emit one fm-gbrain-health.v1 object (default; kept for
#                 symmetry with other fleet commands that accept it).
#   --timeout     seconds allowed for the whole read (default: 15, max: 60).
#                 Every bounded step inside this command - each reachability
#                 probe and the capture-status read - draws from that one
#                 budget and never takes more than what is left of it, so no
#                 combination of hangs can burn the dashboard poll deadline.
#
# Output schema fm-gbrain-health.v1:
#   generated               observation time this command ran
#   home                    FM_HOME the probes ran against
#   configured              true if config/gbrain.json validates
#   version                 the pinned GBrain release recorded in docs, or null
#                           when this home has no docs/gbrain.md
#   index                   {state, detail} where state is one of ok | absent
#                           | unknown. ok means the PGLite directory exists;
#                           absent means this home has not initialized a brain
#                           and is a normal state.
#   capture                 {enabled, archived, pending, failed, unreadable,
#                           truncated, last_capture_at, last_error, detail,
#                           audit} from the durable outbox and receipts, not
#                           from anything GBrain keeps. The last_capture_at is
#                           the captured_at of the most recent captured
#                           document, or null. truncated counts stored bodies
#                           cut at the capture cap. enabled is false when no
#                           brain is configured OR when this home's index has
#                           not been bootstrapped yet; detail names which of the
#                           two it is, and the counts are reported either way.
#                           audit is {state, stored, active, missing, observed,
#                           detail} replayed from the durable record the
#                           stored-versus-served audit last wrote, where state
#                           is one of ok | gap | inconclusive | unknown. It is
#                           REPLAYED, never measured here: this command runs on
#                           every dashboard poll and the audit opens the index,
#                           so measuring it here would put a repeated index read
#                           behind a poll that must stay cheap. unknown means no
#                           audit has run in this home yet, and observed is how
#                           old the answer is.
#   retrieval               {state, embedding, reranker, main_brain} where
#                           state is the worst of the three probes below.
#                           embedding/reranker/main_brain are each {state,
#                           model, endpoint, detail} where state is one of
#                           ok | degraded | absent | unconfigured | unknown.
#                           A degraded embedding or reranker means a search
#                           will fall back to a worse ordering; a degraded
#                           main brain means the read-only share is not
#                           answering right now. Local retrieval is unaffected
#                           by hosted-synthesis degradation.
#   synthesis               {state, model, endpoint, detail} where state is
#                           one of ok | degraded | unconfigured | unknown.
#                           Hosted synthesis is the optional "think" command;
#                           it being degraded means search still works.
#   maintenance             {state, detail} where state is one of ready
#                           | upgrading | reindexing | unknown. Surfaced from
#                           FM_GBRAIN_MAINTENANCE_STATE when the operator has
#                           set it, never inferred.
#
# A home without a brain reports configured: false, index.state: absent, and
# every retrieval/synthesis field as absent/unconfigured. The dashboard can
# then render "no brain" without coupling itself to whether one will ever
# exist.
#
# Credentials are never read. This command does not mint tokens and does not
# open the credential files; reachability is probed with the same public
# model-listing endpoint bin/fm-gbrain.sh check uses.
#
# docs/gbrain-scoping.md and docs/gbrain.md own the contract this reads from;
# bin/fm-gbrain.sh and bin/fm-gbrain-capture.sh own the underlying commands.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-gbrain-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-gbrain-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

SCHEMA=fm-gbrain-health.v1
TIMEOUT=15
TIMEOUT_MAX=60

usage() { awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }
die() { printf 'fm-gbrain-health: %s\n' "$1" >&2; exit 1; }
warn() { printf 'fm-gbrain-health: %s\n' "$1" >&2; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"
}

require_tool jq

# --- argument parsing -------------------------------------------------------

# Each arm consumes exactly the tokens it read, so a two-token flag cannot eat
# the one behind it and every remaining token is still classified by the arms
# below - an unknown flag after --timeout dies rather than being skipped.
while [ $# -gt 0 ]; do
  case $1 in
    --json) shift ;;
    --timeout)
      [ $# -ge 2 ] || die "--timeout requires a value"
      case $2 in '' | *[!0-9]*) die "--timeout requires a positive integer" ;; esac
      [ "$2" -gt 0 ] || die "--timeout requires a positive integer"
      [ "$2" -le "$TIMEOUT_MAX" ] || die "--timeout must not exceed $TIMEOUT_MAX"
      TIMEOUT=$2; shift 2 ;;
    -h | --help | help) usage; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
done

GENERATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SHARED=$(fm_gbrain_shared_path "$FM_HOME")
LOCAL=$(fm_gbrain_local_path "$FM_HOME")

# --- configuration presence -------------------------------------------------

# A home that has never configured a brain reports configured: false. That is
# the normal state of a fleet that has not adopted GBrain, so the dashboard
# renders "no brain configured" instead of a fault. validate_shared returns
# success when the file is absent, which is the right behaviour for a wrapper
# like recall that wants to keep going; the dashboard wants a louder answer.
if [ -e "$SHARED" ] && fm_gbrain_validate_shared "$SHARED" && fm_gbrain_validate_local "$LOCAL"; then
  CONFIGURED=true
else
  CONFIGURED=false
fi

# The pinned version lives in docs/gbrain.md and is rendered as the operator
# reference for the installed release; this is what the dashboard quotes. A
# home without the doc (e.g. a worktree checkout) gets version: null, never a
# guess from a running executable. fm_gbrain_documented_pin owns that read;
# bin/fm-gbrain-pin-check.sh is what catches the record going stale.
fm_gbrain_documented_pin "$FM_ROOT" || true
VERSION=${FM_GBRAIN_PIN:-null}

# --- brain paths and index presence -----------------------------------------

INDEX_STATE=unknown
INDEX_DETAIL=
if [ "$CONFIGURED" = true ] && fm_gbrain_resolve_paths "$FM_HOME"; then
  if [ -d "$FM_GBRAIN_PGLITE" ]; then
    INDEX_STATE=ok
    INDEX_DETAIL=$FM_GBRAIN_PGLITE
  else
    INDEX_STATE=absent
    INDEX_DETAIL="this home has no initialized brain at $FM_GBRAIN_PGLITE"
  fi
elif [ "$CONFIGURED" = false ]; then
  INDEX_STATE=absent
  INDEX_DETAIL="no brain configured"
fi

# --- the shared probe budget ------------------------------------------------
#
# Every bounded step in this command draws from one budget: the four
# reachability probes and the capture-status read. Steps run sequentially;
# parallel curls with their own forks would burn more of the budget than the
# probes themselves need.
#
# A step with peers still to run takes budget_slice(): its nominal share, or
# whatever is left if that is less, so one hang cannot starve the steps behind
# it. The LAST step takes budget_remaining() instead - nothing follows it, so
# capping it at a nominal share would leave the tail of the budget unspent
# while the step most likely to need it (the capture read is the only one whose
# cost grows with the size of the outbox) is refused. Either way the sum of
# every step is bounded by --timeout, so no combination of hangs can push this
# command out of the dashboard's poll window.
#
# BUDGET_STEPS counts all five, not just the probes, so four hanging probes
# still leave the capture read the share that was reserved for it.

BUDGET_STEPS=5
BUDGET_STARTED=$(date +%s)
BUDGET_SLICE=$(( TIMEOUT / BUDGET_STEPS ))
[ "$BUDGET_SLICE" -lt 1 ] && BUDGET_SLICE=1

budget_remaining() {  # -> echoes the seconds left before the deadline
  local remaining
  remaining=$(( TIMEOUT - ( $(date +%s) - BUDGET_STARTED ) ))
  [ "$remaining" -lt 1 ] && remaining=1
  printf '%s\n' "$remaining"
}

budget_slice() {  # -> echoes the seconds a step with peers behind it may spend
  local remaining
  remaining=$(budget_remaining)
  if [ "$BUDGET_SLICE" -le "$remaining" ]; then
    printf '%s\n' "$BUDGET_SLICE"
  else
    printf '%s\n' "$remaining"
  fi
}

# --- reachability probes ----------------------------------------------------
#
# A probe that hangs past its slice is treated as degraded, with the endpoint
# it could not reach named in the detail.

probe_url() {  # <url> <slice-seconds> -> 0 reachable
  local url=$1 slice=$2
  fm_run_timed "$slice" curl -sS -o /dev/null -m "$slice" "${url%/}/models" >/dev/null 2>&1
}

embedding_state() {  # <json> -> echoes row
  if [ "$CONFIGURED" != true ]; then
    jq -cn --arg model "" --arg url "" '{state: "unconfigured", model: $model, endpoint: $url, detail: "no embedding endpoint configured"}'
    return 0
  fi
  local model url slice
  model=$(fm_gbrain_json_str "$SHARED" '.local.embedding_model')
  url=$(fm_gbrain_json_str "$SHARED" '.local.embedding_base_url')
  if [ -z "$url" ]; then
    jq -cn --arg model "$model" --arg url "" '{state: "unconfigured", model: $model, endpoint: $url, detail: "no embedding endpoint configured"}'
    return 0
  fi
  slice=$(budget_slice)
  if probe_url "$url" "$slice"; then
    jq -cn --arg model "$model" --arg url "$url" '{state: "ok", model: $model, endpoint: $url, detail: $url}'
  else
    jq -cn --arg model "$model" --arg url "$url" '{state: "degraded", model: $model, endpoint: $url, detail: ("no answer at " + $url + "; embedding and hybrid search are unavailable until it returns")}'
  fi
}

reranker_state() {  # <json> -> echoes row
  if [ "$CONFIGURED" != true ]; then
    jq -cn --arg model "" --arg url "" '{state: "unconfigured", model: $model, endpoint: $url, detail: "no reranker endpoint configured"}'
    return 0
  fi
  local model url slice
  model=$(fm_gbrain_json_str "$SHARED" '.local.reranker_model')
  url=$(fm_gbrain_json_str "$SHARED" '.local.reranker_base_url')
  if [ -z "$url" ]; then
    jq -cn --arg model "$model" --arg url "" '{state: "unconfigured", model: $model, endpoint: $url, detail: "no reranker endpoint configured"}'
    return 0
  fi
  slice=$(budget_slice)
  if probe_url "$url" "$slice"; then
    jq -cn --arg model "$model" --arg url "$url" '{state: "ok", model: $model, endpoint: $url, detail: $url}'
  else
    jq -cn --arg model "$model" --arg url "$url" '{state: "degraded", model: $model, endpoint: $url, detail: ("no answer at " + $url + "; search falls back to non-reranked ordering")}'
  fi
}

main_brain_state() {  # -> echoes row
  if [ "$CONFIGURED" != true ]; then
    jq -cn '{state: "unconfigured", model: null, endpoint: null, detail: "no main brain configured"}'
    return 0
  fi
  local mcp client_id slice state detail
  mcp=$(fm_gbrain_json_str "$SHARED" '.main_brain.mcp_url')
  client_id=$(fm_gbrain_json_str "$LOCAL" '.client_id')
  if [ -z "$mcp" ]; then
    jq -cn '{state: "absent", model: null, endpoint: null, detail: "this fleet has not configured a shared main brain"}'
    return 0
  fi
  if fm_gbrain_is_main_brain_owner "$FM_HOME"; then
    jq -cn --arg url "$mcp" '{state: "ok", model: null, endpoint: $url, detail: "this home owns the main brain and reads its own index directly"}'
    return 0
  fi
  if [ -z "$client_id" ]; then
    jq -cn --arg url "$mcp" '{state: "absent", model: null, endpoint: $url, detail: "this home holds no read-only client for the main brain"}'
    return 0
  fi
  # Probe the main brain's MCP endpoint: a main brain that grants tokens but
  # does not answer search right now reports degraded, which is what search
  # would see.
  slice=$(budget_slice)
  if probe_url "$mcp" "$slice"; then
    state=ok
    detail="read-only token issued for $mcp"
  else
    state=degraded
    detail="no answer at $mcp; this home's own search is unaffected"
  fi
  jq -cn --arg s "$state" --arg url "$mcp" --arg d "$detail" \
    '{state: $s, model: null, endpoint: $url, detail: $d}'
}

# The hosted-synthesis provider is independent of local retrieval. Its
# presence is decided by config (a key under config/gbrain-secrets/ that this
# command never opens), and its reachability is the model's listing endpoint.
# This split is what lets search keep working when synthesis is unavailable.
synthesis_state() {  # -> echoes row
  if [ "$CONFIGURED" != true ]; then
    jq -cn '{state: "unconfigured", model: null, endpoint: null, detail: "no hosted synthesis provider configured"}'
    return 0
  fi
  local model url secret_name state detail slice
  model=$(fm_gbrain_json_str "$SHARED" '.think.model')
  url=$(fm_gbrain_json_str "$SHARED" '.think.base_url')
  secret_name=$(fm_gbrain_json_str "$SHARED" '.think.secret')
  if [ -z "$url" ] || [ -z "$secret_name" ]; then
    jq -cn --arg model "$model" --arg url "$url" \
      '{state: "unconfigured", model: $model, endpoint: $url, detail: "no hosted synthesis provider configured"}'
    return 0
  fi
  slice=$(budget_slice)
  if probe_url "$url" "$slice"; then
    state=ok
    detail=$url
  else
    state=degraded
    detail="no answer at $url; synthesis is unavailable and local search is unaffected"
  fi
  jq -cn --arg s "$state" --arg model "$model" --arg url "$url" --arg d "$detail" \
    '{state: $s, model: $model, endpoint: $url, detail: $d}'
}

# The retrieval verdict is the worst of its three components. None of them
# being present is fine (state absent); any one being degraded is degraded.
retrieval_overall() {  # <embedding> <reranker> <main_brain> -> echoes row
  jq -n --slurpfile e <(printf '%s' "$1") --slurpfile r <(printf '%s' "$2") --slurpfile m <(printf '%s' "$3") '
    ([$e[0], $r[0], $m[0]] | map(.state) | unique) as $states
    | (if any($states[]; . == "degraded") then "degraded"
       elif any($states[]; . == "unknown") then "unknown"
       elif any($states[]; . == "ok") then "ok"
       else "absent" end) as $state
    | {state: $state, embedding: $e[0], reranker: $r[0], main_brain: $m[0]}
  '
}

# --- capture status from the durable outbox --------------------------------
#
# The outbox is the durable record of capture; it survives teardown, GBrain
# restarts, and process exits. fm-gbrain-capture.sh status is the single owner
# of the count semantics.

# The stored-versus-served verdict, replayed from the record the audit wrote.
# It is never measured here: this runs on every dashboard poll, and opening the
# index once per poll to re-derive an answer that changes on a sweep interval
# would put a repeated index read behind a poll that has to stay cheap. A record
# that is absent, unreadable, or of an unrecognized schema all mean the same
# thing to a reader - nothing has been compared - so all three say so rather
# than reporting a zero gap nobody measured.
capture_audit() {  # -> echoes row
  local path doc
  path="${FM_STATE_OVERRIDE:-$FM_HOME/state}/.gbrain-audit"
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    jq -cn '{state: "unknown", stored: null, active: null, missing: null, observed: null,
             detail: "no captured-versus-served audit has run in this home yet"}'
    return 0
  fi
  doc=$(cat "$path" 2>/dev/null) || doc=""
  if ! printf '%s' "$doc" | jq -e '.schema == "fm-gbrain-capture-audit.v1"' >/dev/null 2>&1; then
    jq -cn '{state: "unknown", stored: null, active: null, missing: null, observed: null,
             detail: "the captured-versus-served audit record could not be read"}'
    return 0
  fi
  printf '%s' "$doc" | jq -c '{state: .state, stored: .stored, active: .active,
    missing: .missing, observed: .generated, detail: .detail}'
}

capture_state() {  # -> echoes row
  local out captured_at last_error pending failed archived unreadable truncated enabled detail audit
  audit=$(capture_audit)
  if [ "$CONFIGURED" != true ]; then
    jq -cn --argjson audit "$audit" '{enabled: false, archived: 0, pending: 0, failed: 0, unreadable: 0, truncated: 0, last_capture_at: null, last_error: null, detail: "no brain configured", audit: $audit}'
    return 0
  fi
  # Capture is off on a configured home whose index has not been bootstrapped.
  # That is a normal state rather than a fault, and it is a different one from
  # "no brain configured", so it says so itself instead of leaving a reader to
  # guess from enabled: false alone.
  enabled=$([ "$INDEX_STATE" = "ok" ] && echo true || echo false)
  detail=
  [ "$enabled" = true ] || detail="the local index at $FM_HOME is not bootstrapped, so captured documents wait in the durable outbox"
  if ! out=$(fm_run_timed "$(budget_remaining)" "$SCRIPT_DIR/fm-gbrain-capture.sh" status --json 2>/dev/null); then
    jq -cn --argjson e "$enabled" --arg d "$detail" --argjson audit "$audit" '{enabled: $e, archived: 0, pending: 0, failed: 0, unreadable: 0, truncated: 0, last_capture_at: null, last_error: "capture status could not be read", detail: (if $d == "" then null else $d end), audit: $audit}'
    return 0
  fi
  if ! printf '%s' "$out" | jq -e '.schema == "fm-gbrain-capture-status.v1"' >/dev/null 2>&1; then
    jq -cn --argjson e "$enabled" --arg d "$detail" --argjson audit "$audit" '{enabled: $e, archived: 0, pending: 0, failed: 0, unreadable: 0, truncated: 0, last_capture_at: null, last_error: "capture status schema is unsupported", detail: (if $d == "" then null else $d end), audit: $audit}'
    return 0
  fi
  archived=$(printf '%s' "$out" | jq '.totals.archived // 0')
  pending=$(printf '%s' "$out" | jq '.totals.pending // 0')
  failed=$(printf '%s' "$out" | jq '.totals.failed // 0')
  unreadable=$(printf '%s' "$out" | jq '.totals.unreadable // 0')
  truncated=$(printf '%s' "$out" | jq '.totals.truncated // 0')
  captured_at=$(printf '%s' "$out" | jq -r '
    [ .documents[] | select(.status == "captured") | .captured_at ]
    | max // null
  ')
  # The last error is the freshest failed or unreadable document's last_error,
  # if any. A pending or archived record without an error has nothing to say.
  last_error=$(printf '%s' "$out" | jq -r '
    [ .documents[]
      | select(.status == "failed" or .status == "unreadable")
      | .last_error // empty
    ] | first // null
  ')
  jq -cn --argjson e "$enabled" --argjson a "$archived" --argjson p "$pending" --argjson f "$failed" \
    --argjson u "$unreadable" --argjson t "$truncated" --arg at "$captured_at" --arg er "$last_error" \
    --arg d "$detail" --argjson audit "$audit" \
    '{enabled: $e, archived: $a, pending: $p, failed: $f, unreadable: $u, truncated: $t,
      last_capture_at: (if $at == "" or $at == "null" then null else $at end),
      last_error: (if $er == "" or $er == "null" then null else $er end),
      detail: (if $d == "" then null else $d end),
      audit: $audit}'
}

# --- maintenance state ------------------------------------------------------
#
# The operator announces an upgrade or reindex with FM_GBRAIN_MAINTENANCE_STATE.
# This command never infers it, so a real run reads a green brain without ever
# suspecting one was paused mid-upgrade; the operator's announcement is the
# only signal that has the timing to be true.

maintenance_state() {  # -> echoes row
  local state=${FM_GBRAIN_MAINTENANCE_STATE:-}
  local detail=${FM_GBRAIN_MAINTENANCE_DETAIL:-}
  case "$state" in
    '' | ready) jq -cn --arg d "${detail:-}" '{state: "ready", detail: (if $d == "" then null else $d end)}' ;;
    upgrading | reindexing) jq -cn --arg s "$state" --arg d "$detail" '{state: $s, detail: (if $d == "" then null else $d end)}' ;;
    *) jq -cn --arg d "$detail" '{state: "unknown", detail: (if $d == "" then "FM_GBRAIN_MAINTENANCE_STATE is set to an unrecognized value" else $d end)}' ;;
  esac
}

# --- assemble and print ------------------------------------------------------

EMBEDDING_ROW=$(embedding_state)
RERANKER_ROW=$(reranker_state)
MAIN_BRAIN_ROW=$(main_brain_state)
RETRIEVAL_ROW=$(retrieval_overall "$EMBEDDING_ROW" "$RERANKER_ROW" "$MAIN_BRAIN_ROW")
SYNTHESIS_ROW=$(synthesis_state)
CAPTURE_ROW=$(capture_state)
MAINTENANCE_ROW=$(maintenance_state)

jq -n \
  --arg schema "$SCHEMA" \
  --arg generated "$GENERATED" \
  --arg home "$FM_HOME" \
  --argjson configured "$CONFIGURED" \
  --arg version "$VERSION" \
  --arg index_state "$INDEX_STATE" \
  --arg index_detail "$INDEX_DETAIL" \
  --argjson retrieval "$RETRIEVAL_ROW" \
  --argjson synthesis "$SYNTHESIS_ROW" \
  --argjson capture "$CAPTURE_ROW" \
  --argjson maintenance "$MAINTENANCE_ROW" \
  '{
    schema: $schema,
    generated: $generated,
    home: $home,
    configured: $configured,
    version: (if $version == "" or $version == "null" then null else $version end),
    index: {state: $index_state, detail: $index_detail},
    retrieval: $retrieval,
    synthesis: $synthesis,
    capture: $capture,
    maintenance: $maintenance
  }'