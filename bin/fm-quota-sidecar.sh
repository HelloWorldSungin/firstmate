#!/usr/bin/env bash
# fm-quota-sidecar.sh - read host-published LLM quota without mistaking stale
# observations for current capacity.
#
# This reader enforces the freshness and degradation policy owned by
# .agents/skills/quota-array-dispatch/SKILL.md. It is additive evidence only:
# quota-axi remains authoritative for every provider it covers, and this script
# never merges, caches, ranks, or recommends routes.
#
# The default freshness window is two hours (7200 seconds). The shortest
# currently published subscription windows reset in about five hours, so two
# hours keeps a CURRENT observation below half of that shortest cadence while
# tolerating brief collector, network, and share interruptions. Longer weekly
# and monthly windows make that limit conservative, and a sleeping laptop
# degrades to UNKNOWN after two hours instead of presenting an old high number
# as healthy. Override it explicitly with FM_QUOTA_SIDECAR_FRESHNESS_SECONDS or
# --freshness-seconds when another deployment has a justified collection/reset
# cadence. Both entry points reject a value that is not a positive count of
# seconds rather than falling back to the default, so a dropped override is
# never silent; a leading-zero value is read as decimal, never as octal.
#
# The producer publishes from another host, so the two clocks drift in both
# directions and an observed age is never exact. The valid age interval is 0
# through the freshness window, and a 300-second tolerance applies symmetrically
# around it. A producer clock ahead of this host makes an age negative, and a
# producer clock behind it inflates the age past the window; an age inside the
# widened band is clamped to the nearest valid endpoint for classification only,
# so a negative age can never pass the freshness test on its own sign. An age
# below the negative tolerance is UNKNOWN with the explicit `clock_skew` reason
# rather than a generic degradation, and an age past the window plus tolerance
# is UNKNOWN with `stale`. Both emitted ages stay exactly as observed, including
# a negative one, so the direction and size of the drift stays inspectable.
#
# Input defaults to $HOME/shared/quota/<provider>.json and may be overridden by
# FM_QUOTA_SIDECAR_DIR or --dir. With provider arguments, missing providers are
# emitted as UNKNOWN. With no provider arguments, every non-resource-fork JSON
# file in the directory is read once. A missing/unmounted directory, malformed
# file, wrong schema, stale observation, clock skew, or producer error is
# UNKNOWN and exits 0.
#
# Output is one fm-quota-sidecar-reader.v1 JSON document whose envelope carries
# `schema`, the `freshness_seconds` and `clock_skew_tolerance_seconds` actually
# applied, an aggregate `evidence_status`, the `providers` array, and - only
# when no provider was read at all - a top-level `reason` of `missing_directory`
# or `no_provider_files`. The aggregate is CURRENT when every provider record is
# CURRENT, PARTIAL when at least one is CURRENT and at least one is UNKNOWN, and
# UNKNOWN when no record is CURRENT or the array is empty; PARTIAL and UNKNOWN
# both mean the aggregate cannot stand in for a per-provider read. CURRENT
# records expose `windows`; UNKNOWN records expose the same safe projection only
# as `last_known_windows`. The projection deliberately excludes labels, source,
# notes, errors, and every unknown field, so file content that is not required
# for quota accounting can never disclose a credential.
#
# Usage:
#   fm-quota-sidecar.sh [--dir PATH] [--freshness-seconds N] [provider ...]
#
# Environment:
#   FM_QUOTA_SIDECAR_DIR                 input directory
#   FM_QUOTA_SIDECAR_FRESHNESS_SECONDS   positive integer; default 7200
set -u

usage() {
  sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"
}

die_usage() {
  printf 'fm-quota-sidecar: %s\n' "$1" >&2
  printf 'usage: fm-quota-sidecar.sh [--dir PATH] [--freshness-seconds N] [provider ...]\n' >&2
  exit 2
}

DIRECTORY=${FM_QUOTA_SIDECAR_DIR:-"$HOME/shared/quota"}
SKEW_TOLERANCE=300
FRESHNESS=7200
FRESHNESS_ORIGIN=default
if [ -n "${FM_QUOTA_SIDECAR_FRESHNESS_SECONDS+x}" ]; then
  FRESHNESS=$FM_QUOTA_SIDECAR_FRESHNESS_SECONDS
  FRESHNESS_ORIGIN=FM_QUOTA_SIDECAR_FRESHNESS_SECONDS
fi

PROVIDERS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dir)
      [ "$#" -ge 2 ] || die_usage "--dir requires a path"
      DIRECTORY=$2
      shift 2
      ;;
    --dir=*)
      DIRECTORY=${1#*=}
      shift
      ;;
    --freshness-seconds)
      [ "$#" -ge 2 ] || die_usage "--freshness-seconds requires a positive integer"
      FRESHNESS=$2
      FRESHNESS_ORIGIN=--freshness-seconds
      shift 2
      ;;
    --freshness-seconds=*)
      FRESHNESS=${1#*=}
      FRESHNESS_ORIGIN=--freshness-seconds
      shift
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        PROVIDERS+=("$1")
        shift
      done
      ;;
    -*) die_usage "unknown option: $1" ;;
    *)
      PROVIDERS+=("$1")
      shift
      ;;
  esac
done

[ -n "$DIRECTORY" ] || die_usage "the sidecar directory must not be empty"

# Read a positive count of seconds as decimal, so 010800 is 10800 rather than an
# octal reading or a silently discarded override.
positive_seconds() { # <value>
  local value=$1 leading_zeros
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  leading_zeros=${value%%[!0]*}
  value=${value#"$leading_zeros"}
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

FRESHNESS_INPUT=$FRESHNESS
FRESHNESS=$(positive_seconds "$FRESHNESS_INPUT") \
  || die_usage "freshness seconds from $FRESHNESS_ORIGIN must be a positive integer: '$FRESHNESS_INPUT'"

command -v jq >/dev/null 2>&1 || {
  printf 'fm-quota-sidecar: jq is required\n' >&2
  exit 127
}

validate_provider() {
  case "$1" in
    ''|._*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

for provider in "${PROVIDERS[@]+"${PROVIDERS[@]}"}"; do
  validate_provider "$provider" || die_usage "invalid provider id: $provider"
done

# With no explicit provider list, discover the producer files without treating
# macOS AppleDouble resource forks as quota providers.
if [ "${#PROVIDERS[@]}" -eq 0 ] && [ -d "$DIRECTORY" ]; then
  shopt -s nullglob
  for file in "$DIRECTORY"/*.json; do
    provider=${file##*/}
    provider=${provider%.json}
    validate_provider "$provider" || continue
    PROVIDERS+=("$provider")
  done
  shopt -u nullglob
fi

NOW=$(date +%s)
case "$NOW" in
  ''|*[!0-9]*)
    printf 'fm-quota-sidecar: system clock is unavailable\n' >&2
    exit 1
    ;;
esac

emit_unknown() { # <provider> <reason>
  jq -cn --arg provider "$1" --arg reason "$2" '{
    provider: $provider,
    evidence_status: "UNKNOWN",
    reason: $reason,
    source_status: "unknown",
    captured_at: null,
    captured_age_seconds: null,
    last_attempt_at: null,
    last_attempt_age_seconds: null,
    last_known_windows: []
  }'
}

valid_document() { # <provider>, document on stdin
  jq -e --arg provider "$1" '
    def iso_epoch:
      if type != "string" or (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") | not)
      then null
      else try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null
      end;
    type == "object" and
    .schema == "fm-quota-sidecar.v1" and
    .provider == $provider and
    (.captured_at | iso_epoch) != null and
    (.last_attempt_at | iso_epoch) != null and
    (.status == "ok" or .status == "error") and
    (.windows | type) == "array" and
    (.windows | length) > 0 and
    all(.windows[];
      (.id | type) == "string" and
      (.id | test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")) and
      (.percent_remaining | type) == "number" and
      .percent_remaining >= 0 and .percent_remaining <= 100 and
      (.resets_at == null or (.resets_at | iso_epoch) != null)
    )
  ' >/dev/null 2>&1
}

emit_document() { # <provider>, validated document on stdin
  jq -c --arg provider "$1" --argjson now "$NOW" --argjson freshness "$FRESHNESS" \
    --argjson skew "$SKEW_TOLERANCE" '
    def iso_epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def safe_windows: map({id, percent_remaining, resets_at});
    (.captured_at | iso_epoch) as $captured_epoch |
    (.last_attempt_at | iso_epoch) as $attempt_epoch |
    ($now - $captured_epoch | floor) as $captured_age |
    ($now - $attempt_epoch | floor) as $attempt_age |
    ([$captured_age, $attempt_age] | min) as $newest_age |
    ([$captured_age, $attempt_age] | max) as $oldest_age |
    (if .status == "error" then ["UNKNOWN", "source_error"]
     elif $newest_age < (0 - $skew) then ["UNKNOWN", "clock_skew"]
     elif $attempt_epoch < $captured_epoch then ["UNKNOWN", "invalid_timestamp_order"]
     elif $oldest_age > ($freshness + $skew) then ["UNKNOWN", "stale"]
     else ["CURRENT", "fresh"]
     end) as $classification |
    {
      provider: $provider,
      evidence_status: $classification[0],
      reason: $classification[1],
      source_status: .status,
      captured_at,
      captured_age_seconds: $captured_age,
      last_attempt_at,
      last_attempt_age_seconds: $attempt_age
    } +
    if $classification[0] == "CURRENT"
    then {windows: (.windows | safe_windows)}
    else {last_known_windows: (.windows | safe_windows)}
    end
  '
}

emit_providers() {
  local provider file document
  for provider in "${PROVIDERS[@]+"${PROVIDERS[@]}"}"; do
    file="$DIRECTORY/$provider.json"
    if [ ! -d "$DIRECTORY" ]; then
      emit_unknown "$provider" missing_directory
    elif [ ! -f "$file" ]; then
      emit_unknown "$provider" missing_provider
    elif ! document=$(<"$file"); then
      emit_unknown "$provider" unreadable
    elif ! jq -e . <<<"$document" >/dev/null 2>&1; then
      emit_unknown "$provider" invalid_json
    elif ! valid_document "$provider" <<<"$document"; then
      emit_unknown "$provider" invalid_schema
    else
      emit_document "$provider" <<<"$document"
    fi
  done
}

EMPTY_REASON=none
if [ "${#PROVIDERS[@]}" -eq 0 ]; then
  if [ -d "$DIRECTORY" ]; then
    EMPTY_REASON=no_provider_files
  else
    EMPTY_REASON=missing_directory
  fi
fi

emit_providers | jq -s \
  --argjson freshness "$FRESHNESS" \
  --argjson skew "$SKEW_TOLERANCE" \
  --arg empty_reason "$EMPTY_REASON" '
    {
      schema: "fm-quota-sidecar-reader.v1",
      freshness_seconds: $freshness,
      clock_skew_tolerance_seconds: $skew,
      evidence_status:
        (if length == 0 then "UNKNOWN"
         elif all(.[]; .evidence_status == "CURRENT") then "CURRENT"
         elif any(.[]; .evidence_status == "CURRENT") then "PARTIAL"
         else "UNKNOWN"
         end),
      providers: .
    } + if length == 0 then {reason: $empty_reason} else {} end
  '
exit 0
