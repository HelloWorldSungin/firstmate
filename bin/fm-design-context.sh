#!/usr/bin/env bash
# Maintain fail-closed context telemetry for a Claude-backed design crewmate.
#
# The design profile's instructions own pacing judgment: the worker reports the
# current context position and session depth with supervisor-actionable status
# events, and firstmate decides when to request a handoff.
# This helper is only the structural backstop under that live contract.
# A Claude Stop hook passes its JSON payload on stdin after every completed turn.
# The helper reads the recorded transcript, atomically refreshes
# state/<id>.design-context, wakes firstmate through the ordinary turn-end file,
# and emits one blocked event when telemetry is unavailable or the hard ceiling
# has been reached.
# It never decides whether the work quality has degraded and never authorizes a
# worker to continue merely because the ceiling has not been reached.
#
# Usage:
#   fm-design-context.sh turn-end <task-id> <turn-end-path>
#   fm-design-context.sh show <task-id>
#   fm-design-context.sh reset <task-id>
#
# The turn-end wake is unconditional: it is armed before any other work, so a
# failure anywhere in this helper degrades to missing telemetry, never to a
# design crewmate that finishes a turn without waking firstmate.
#
# FM_DESIGN_CONTEXT_HARD_LIMIT overrides the 110000-token default for tests or a
# future evidence-backed adapter revision.
set -eu

if [ "${1:-}" = turn-end ] && [ "$#" -eq 3 ]; then
  FM_DESIGN_TURNEND=$3
  trap 'touch "$FM_DESIGN_TURNEND" 2>/dev/null || true' EXIT
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
HARD_LIMIT=${FM_DESIGN_CONTEXT_HARD_LIMIT:-110000}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

fail() {
  printf 'fm-design-context: %s\n' "$*" >&2
  exit 1
}

validate_limit() {
  case "$HARD_LIMIT" in
    ''|*[!0-9]*) fail "hard limit must be a positive integer" ;;
  esac
  [ "$HARD_LIMIT" -gt 0 ] || fail "hard limit must be a positive integer"
}

status_once() { # <id> <key> <message>
  local id=$1 key=$2 message=$3 status="$STATE/$1.status" last
  last=$(grep -F "[key=$key]" "$status" 2>/dev/null | tail -1 || true)
  case "$last" in
    '') ;;
    resolved*) ;;
    *) return 0 ;;
  esac
  printf 'blocked [key=%s]: %s\n' "$key" "$message" >> "$status"
}

write_unavailable() { # <id> <reason>
  local id=$1 reason=$2 sidecar="$STATE/$1.design-context" tmp
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.${id}.design-context.XXXXXX")
  {
    printf 'telemetry=unavailable\n'
    printf 'context_tokens=unknown\n'
    printf 'session_turns=unknown\n'
    printf 'hard_limit=%s\n' "$HARD_LIMIT"
    printf 'ceiling=1\n'
  } > "$tmp"
  mv "$tmp" "$sidecar"
  status_once "$id" context-telemetry \
    "design context telemetry unavailable ($reason); create the profile handoff before relaunch"
}

turn_end() { # <task-id>
  local id=$1 payload transcript metrics request_id tokens turns ceiling
  local sidecar="$STATE/$1.design-context" tmp

  payload=$(cat)
  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  if [ -z "$transcript" ] || [ "${transcript#/}" = "$transcript" ] || [ ! -f "$transcript" ]; then
    write_unavailable "$id" "missing readable Claude transcript"
    return 0
  fi

  metrics=$(
    jq -r '
      select(
        .type == "assistant"
        and ((.isSidechain // false) == false)
        and ((.message.usage | type) == "object")
      )
      | [
          (.requestId // .message.id // "unknown"),
          (
            (.message.usage.input_tokens // 0)
            + (.message.usage.cache_creation_input_tokens // 0)
            + (.message.usage.cache_read_input_tokens // 0)
            + (.message.usage.output_tokens // 0)
          )
        ]
      | @tsv
    ' "$transcript" 2>/dev/null \
      | awk -F '\t' '
          !seen[$1]++ { turns++ }
          { request_id=$1; tokens=$2 }
          END {
            if (turns > 0 && request_id != "" && tokens ~ /^[0-9]+$/) {
              print request_id "\t" tokens "\t" turns
            }
          }
        '
  )
  if [ -z "$metrics" ]; then
    write_unavailable "$id" "no main-chain usage records in Claude transcript"
    return 0
  fi

  IFS=$'\t' read -r request_id tokens turns <<EOF
$metrics
EOF
  ceiling=0
  [ "$tokens" -lt "$HARD_LIMIT" ] || ceiling=1
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.${id}.design-context.XXXXXX")
  {
    printf 'telemetry=available\n'
    printf 'context_tokens=%s\n' "$tokens"
    printf 'session_turns=%s\n' "$turns"
    printf 'hard_limit=%s\n' "$HARD_LIMIT"
    printf 'ceiling=%s\n' "$ceiling"
    printf 'request_id=%s\n' "$request_id"
  } > "$tmp"
  mv "$tmp" "$sidecar"

  if [ "$ceiling" -eq 1 ]; then
    status_once "$id" context-ceiling \
      "hard design context ceiling reached at $tokens/$HARD_LIMIT tokens after $turns turns; create the profile handoff before relaunch"
  fi
}

show_context() { # <task-id>
  local id=$1 sidecar="$STATE/$1.design-context"
  local telemetry context turns limit ceiling
  if [ ! -f "$sidecar" ]; then
    printf 'context=pending/%s turns=0 ceiling=0 telemetry=pending\n' "$HARD_LIMIT"
    return 0
  fi
  telemetry=$(sed -n 's/^telemetry=//p' "$sidecar" | tail -1)
  context=$(sed -n 's/^context_tokens=//p' "$sidecar" | tail -1)
  turns=$(sed -n 's/^session_turns=//p' "$sidecar" | tail -1)
  limit=$(sed -n 's/^hard_limit=//p' "$sidecar" | tail -1)
  ceiling=$(sed -n 's/^ceiling=//p' "$sidecar" | tail -1)
  printf 'context=%s/%s turns=%s ceiling=%s telemetry=%s\n' \
    "$context" "$limit" "$turns" "$ceiling" "$telemetry"
}

reset_context() { # <task-id>
  local id=$1 handoff="$DATA/$1/handoff.md" sidecar="$STATE/$1.design-context" tmp
  [ -f "$handoff" ] || fail "refusing reset without design handoff at $handoff"
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.${id}.design-context.XXXXXX")
  {
    printf 'telemetry=pending\n'
    printf 'context_tokens=pending\n'
    printf 'session_turns=0\n'
    printf 'hard_limit=%s\n' "$HARD_LIMIT"
    printf 'ceiling=0\n'
  } > "$tmp"
  mv "$tmp" "$sidecar"
}

[ "$#" -ge 2 ] || fail "usage: fm-design-context.sh turn-end <task-id> <turn-end-path> | show <task-id> | reset <task-id>"
command=$1
id=$2
fm_task_id_path_safe "$id" || fail "invalid task id"
validate_limit

case "$command" in
  turn-end)
    [ "$#" -eq 3 ] || fail "turn-end requires <task-id> <turn-end-path>"
    turn_end "$id"
    ;;
  show)
    [ "$#" -eq 2 ] || fail "show requires only <task-id>"
    show_context "$id"
    ;;
  reset)
    [ "$#" -eq 2 ] || fail "reset requires only <task-id>"
    reset_context "$id"
    ;;
  *)
    fail "unknown command: $command"
    ;;
esac
