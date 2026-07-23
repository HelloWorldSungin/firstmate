#!/usr/bin/env bash
# Shared, backend-neutral agent-state transition shape and supervision policy.
#
# This library owns TWO contracts, deliberately backend-independent so any
# push-capable session backend (herdr today, others later) reuses them instead
# of re-deriving a private, per-status escalation hack:
#
#   1. The NORMALIZED TRANSITION RECORD - the ONE shape every backend's event
#      stream is normalized into before any policy runs. A single TAB-separated
#      line:
#          <pane_id>\t<workspace_id>\t<from_status>\t<to_status>\t<agent>
#      Only `to_status` is authoritative for the policy below; the other fields
#      are identity/telemetry and MAY be empty when a backend cannot supply
#      them. `from_status` in particular is empty for backends whose event
#      carries only the new status (herdr's `pane.agent_status_changed` does
#      not report the previous status, and its stream is edge-triggered, so
#      each `to_status` IS itself a fresh edge); it exists in the shape for
#      backends that DO report the prior state and for future edge diagnostics.
#      Statuses use the shared agent-state vocabulary
#      (idle|working|blocked|done|unknown), the same enum herdr's `agent get`
#      and `pane.agent_status_changed` report.
#
#   2. The STATUS -> ACTION POLICY TABLE (fm_transition_policy) - the SINGLE
#      OWNER of the mapping from a normalized `to_status` to the supervision
#      action a consumer must take. Every consumer READS this table; no
#      consumer re-encodes the mapping. Adding or changing a status's action is
#      a one-line edit here, and it changes every backend at once.
#
# The split is what keeps the escalation general rather than a herdr blocked
# hack: a backend contributes only a wire->record normalizer and a stream
# reader; the shape and the policy are shared. See bin/backends/herdr.sh
# (fm_backend_herdr_wait_transition) for the herdr producer and bin/fm-watch.sh
# (the watcher's event-wait splice) for the consumer.

# Field separator for the normalized record. A literal TAB; every field is
# scrubbed of TAB/newline by the producer so the record is exactly five fields.
FM_TRANSITION_FIELD_SEP=$'\t'

# fm_transition_record: THE constructor for a normalized transition record.
# Both a backend's stream normalizer and its level-reconcile read MUST build
# records through this one function, so the record's field order and separator
# have a single owner. Fields are TAB/newline-scrubbed here.
fm_transition_record() {  # <pane_id> <workspace_id> <from_status> <to_status> <agent>
  local pane_id ws from to agent
  pane_id=$(fm_transition_clean_field "${1:-}")
  ws=$(fm_transition_clean_field "${2:-}")
  from=$(fm_transition_clean_field "${3:-}")
  to=$(fm_transition_clean_field "${4:-}")
  agent=$(fm_transition_clean_field "${5:-}")
  printf '%s\t%s\t%s\t%s\t%s' "$pane_id" "$ws" "$from" "$to" "$agent"
}

# fm_transition_clean_field: collapse any TAB/CR/LF in a field value to spaces
# so a stray control char can never desync the fixed five-field record.
fm_transition_clean_field() {  # <value>
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '
}

# Field accessors (1-based), so consumers never hardcode the column layout.
fm_transition_field() {  # <record> <n>
  printf '%s' "$1" | cut -d"$FM_TRANSITION_FIELD_SEP" -f"$2"
}

fm_transition_pane_id()      { fm_transition_field "$1" 1; }
fm_transition_workspace_id() { fm_transition_field "$1" 2; }
fm_transition_from_status()  { fm_transition_field "$1" 3; }
fm_transition_to_status()    { fm_transition_field "$1" 4; }
fm_transition_agent()        { fm_transition_field "$1" 5; }

# fm_transition_policy: THE single-owner status -> supervision-action table.
# Given a normalized `to_status`, print exactly one action token:
#
#   actionable - escalate to the supervisor IMMEDIATELY (a fresh edge here is a
#                durable wake now). `blocked` is the only immediately-actionable
#                status today: herdr reports it precisely when a harness is
#                waiting on the human (a permission/trust dialog, an interactive
#                menu, a wedged prompt) - the cases that write no status file
#                and otherwise sit until the stale-pane wedge timer.
#   absorb     - do NOT wake, but CLEAR this pane's per-pane escalation dedupe
#                marker so a later `->blocked` edge re-escalates. `working`
#                (a crew resumed/started a turn) is the clearing edge.
#   defer      - do NOTHING on the fast path; leave it to the existing
#                status/turn-end completion semantics and the poll backstop.
#                `idle`/`done` blip transiently between tool calls, so
#                fast-pathing them would be a false-positive firehose - they are
#                already covered by the debounced signal/stale machinery.
#   fallback   - the status is unknown/unrecognized: fall back to polling for
#                this pane (the permanent fail-closed backstop), taking no fast
#                action from an ambiguous read.
#
# Consumers act on `actionable`, mutate dedupe state on `absorb`, and ignore
# `defer`/`fallback` on the fast path. Subscribing to ALL statuses (not just
# `blocked`) is deliberate: `working`/`idle`/`done` carry the dedupe-clear and
# reconnect/level-reconcile state; only THIS policy makes `blocked` the sole
# immediate action.
fm_transition_policy() {  # <to_status> -> actionable|absorb|defer|fallback
  case "$1" in
    blocked) printf 'actionable' ;;
    working) printf 'absorb' ;;
    idle|done) printf 'defer' ;;
    *) printf 'fallback' ;;
  esac
}

# fm_transition_native_completion: the debounced, native-identity-gated turn-end
# decision for the crew-only, herdr-only cursor/agy adapters.
#
# WHY THIS EXISTS: those CLIs install no turn-end hook and write no status file,
# and the shared policy above correctly DEFERS `idle`/`done` because for the
# general fleet those states blip transiently between tool calls. But cursor and
# agy signal a completed turn ONLY through their native `idle`/`done` state, and
# the content-hash stale backstop is unreliable for a repainting CLI. So the
# watcher's poll loop runs this decision per cursor/agy herdr window and, when it
# says signal, touches the task's `state/<id>.turn-ended` - the same completion
# signal every other harness's hook writes, handled by the existing scan/wake
# path with no change to the shared policy or the event stream.
#
# It is NOT a blanket "idle/done is actionable" rule (the very firehose the policy
# avoids): it is gated to cursor/agy AND debounced. A signal fires only on the
# SECOND consecutive settled `idle`/`done` poll (so an idle shorter than a poll
# interval - a real inter-tool blip - never signals), and only ONCE per idle
# period; a `working` or `blocked` edge re-arms it for the next turn.
#
# Pure and side-effect-free so it is unit-testable: given the expected harness,
# the live native identity and status read together, and the PREVIOUS recorded
# "<status>|<signaled>" state, it PRINTS the new state and RETURNS 0 iff a
# turn-end should be signaled now (1 otherwise). A non-cursor/agy expected
# harness always returns 1 and echoes an empty state. A live identity mismatch
# returns a re-armed unknown state so stale debounce state cannot signal if the
# expected adapter later reappears.
fm_transition_native_completion() {  # <expected_harness> <native_identity> <status> <prev_state> -> new state; 0 iff signal
  local harness=$1 native_identity=$2 status=$3 prev=$4 prev_status prev_signaled
  case "$harness" in
    cursor|agy) ;;
    *) printf ''; return 1 ;;
  esac
  if [ "$native_identity" != "$harness" ]; then
    printf 'unknown|0'
    return 1
  fi
  prev_status=${prev%%|*}
  case "$prev" in
    *'|'*) prev_signaled=${prev#*|} ;;
    *) prev_signaled=0 ;;
  esac
  [ "$prev_signaled" = 1 ] || prev_signaled=0
  case "$status" in
    working|blocked)
      # An active turn, or a human-wait already escalated by the event stream:
      # re-arm so the next completion signals afresh.
      printf '%s|0' "$status"
      return 1
      ;;
    idle|done)
      case "$prev_status" in
        idle|done)
          if [ "$prev_signaled" = 1 ]; then
            printf '%s|1' "$status"
            return 1
          fi
          # Second consecutive settled poll: a real turn-end, signal once.
          printf '%s|1' "$status"
          return 0
          ;;
        *)
          # First settled poll after a working/unknown edge: arm, do not signal.
          printf '%s|0' "$status"
          return 1
          ;;
      esac
      ;;
    *)
      # Unknown/unreadable: hold the signaled flag, record the status.
      printf '%s|%s' "$status" "$prev_signaled"
      return 1
      ;;
  esac
}
