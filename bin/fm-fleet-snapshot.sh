#!/usr/bin/env bash
# fm-fleet-snapshot.sh - read-only structured fleet snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# The command is read-only: it does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, or write reports.
#
# Top-level fields:
#   schema: stable schema id.
#   generated: UTC observation time for this fresh command execution.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records.
#     Structured rows preserve captain-hold metadata such as hold_kind and
#     hold_reason when tasks-axi emits it. They also carry normalized current_role,
#     requires_child_metadata, blocked_by_ids, unresolved_blocker_ids, and
#     captain_actionable fields. Repeated blocker tokens remain ordered; a blocker
#     resolves only when its structured record is Done, and missing ids stay open.
#     since_age_seconds ages the row's `since` date, which tasks-axi writes when
#     the row is CREATED and never rewrites on hold, so it measures how long the
#     item has been raised and not how long a hold has stood. The backlog records
#     a LOCAL date with no clock time, so the age runs from that day's local
#     midnight: it is an upper bound at day granularity, null when no readable
#     date is present.
#   tasks[]: one row per state/<id>.meta, sorted by id. The rows are read
#     concurrently, FM_SNAPSHOT_TASK_JOBS (default 8) at a time, because the
#     per-task current_state read below dominates this command's cost and grows
#     with the fleet. Every enumerated id appears exactly once: an id whose
#     reader produced nothing readable is reconciled back in as a degraded row
#     reporting current_state "unknown" with source "row-unavailable", because a
#     task missing from tasks[] reads as a fleet that does not have it. An id for
#     which not even that row can be built fails the whole command by name.
#     current_state is parsed from bin/fm-crew-state.sh <id> and preserves
#     state, source, detail, and raw line separately. That call is bounded at
#     FM_SNAPSHOT_TASK_TIMEOUT seconds (default 8) through bin/fm-timeout-lib.sh,
#     which escalates to SIGKILL so a child ignoring SIGTERM cannot outlive the
#     bound; a task whose read ran past it reports state "unknown" with source
#     "timeout", and one for which no bounded runner could start at all reports
#     source "not-attempted" rather than claiming a timeout it never reached. So
#     one slow task costs its own row rather than the whole snapshot.
#     The child's own no-mistakes lookup is bounded at
#     FM_SNAPSHOT_TASK_TIMEOUT minus 3 seconds (floor 1), derived from the outer
#     bound so it stays strictly inside it and fm-crew-state.sh's degraded replay
#     stays reachable from here.
#     model and effort are the dispatch record from state/<id>.meta - what was
#     REQUESTED. model_verification is bin/fm-model-verify.sh's verdict on what
#     actually RAN: {verdict,recorded,actual[],source,detail}. The two are
#     deliberately separate keys: `model` stays the plain recorded string every
#     other consumer reads, and the verdict never overwrites the record it
#     judges. `match` means a model was read and compared; `mismatch`,
#     `unverifiable`, `unstarted`, and `unarmed` all need attention, and
#     `pending`/`unpinned` are explicitly no-verdict rather than a pass.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state. Its last_event_at and last_event_age_seconds report WHEN
#     that event landed, from the log's mtime, so a renderer can age a task
#     without reparsing the log.
#     spawn_age_seconds ages the `spawned_at` epoch bin/fm-spawn.sh stamps into
#     state/<id>.meta, so it reports how long ago the task was DISPATCHED. It is
#     read from that recorded value and never from the meta file's mtime, which
#     firstmate's own later writes to the record reset; it is what lets a
#     renderer bound a task that has neither reported nor emitted a turn-boundary wake.
#     Null when no readable stamp is present.
#     paths.turn_ended ages state/<id>.turn-ended, the harness-neutral
#     turn-boundary wake marker and the same file bin/fm-watch.sh ages to bound
#     how long a busy pane may go with no such wake. It stays a notification and
#     an activity timestamp, never current state or terminal attestation, and an
#     absent marker is reported absent rather than as an age.
#     pr carries the parsed provider/host/path/number identity, the recorded
#     head, and the normalized review/check/mergeability observation cached by
#     bin/fm-pr-status.sh, with its age and freshness. This command never calls
#     a forge: an unrefreshed task reports state "unknown" with source "absent".
#     work_items is the task's durable forge- and host-agnostic work-item
#     reference list from data/<id>/work-items.json, empty when it has none.
#     card is the computed column, action, rank, and inspectable signals for a
#     board renderer; see card_precedence below.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib.sh's authoritative status_open_decisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     hints.last_event_declared_wait reports whether the newest status line
#     DECLARES its own quiet - a paused: external wait or a captain-held transfer -
#     judged by fm-classify-lib.sh's status_is_paused_or_captain_held, the same
#     vocabulary the watcher applies. It is the one place that judgement is made
#     for renderers, so no consumer has to reimplement the token list to tell a
#     task that went quiet from one that said it would be quiet, or an agent
#     exited on purpose by the park procedure from a worker that died.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
#   main_inventory: {valid,reason,orphan_in_flight[],unstructured_current_count} -
#     main-home current-inventory checks shared with secondmate_home_summary_json
#     (orphan structured in-flight ids with no state/<id>.meta, and unstructured
#     current backlog rows). Does not invent live tasks; meta remains truth for
#     workers. Bearings maps failures into omitted[] disclosure (and a Charted
#     Next gate line) rather than silent empty Underway.
#   secondmate_current: {records[],total,shown,truncated} - bounded current summaries
#     for registered secondmates, selected from validated structured state inside
#     each home with explicit provenance, freshness, endpoint evidence, and unknown
#     failure reasons. Parent status and bounded terminal evidence are historical,
#     untrusted supplements only and never override readable structured-home facts.
#     Each structured-home record carries active_children, decisions_open, holds,
#     queued, landed, endpoints, counts, and omitted. Actionable captain holds
#     appear in decisions_open; blocked captain holds remain queued with metadata.
#   secondmate_landed: {records[],truncated[],unreadable[],partial[]} - the
#     compatibility landed-work roll-up derived from secondmate_current. Readable
#     structured homes with an unknown current classification are partial, not
#     unreadable, and retain independently trustworthy structured surfaces.
#   secondmate_guidance: return-channel action note for renderers and bearings.
#   card_precedence: the ordered column ladder every tasks[].card is resolved
#     against, highest-priority first. Exactly one column wins per task, and the
#     rank is its 1-based position in this list.
#   supervision: {watcher,afk} - the watcher liveness beacon's age against the
#     shared grace window from bin/fm-supervision-lib.sh, that library's
#     quiet_allowance_seconds (how long a live worker may stay quiet before the
#     quiet is worth inspecting), and this home's durable away-mode flag with
#     its age.
#   history: durable completion history (schema fm-outcome-history.v1) built from
#     data/<id>/outcome.json manifests by bin/fm-outcome-lib.sh, newest first.
#     A task stays here after teardown removes its volatile records and after its
#     Done backlog entry is pruned. Unreadable manifests are disclosed in
#     history.malformed rather than dropped. FM_SNAPSHOT_HISTORY (default 40)
#     bounds the record count.
#
# Compatibility: JSON is the primary machine-readable surface.
# Every field above is additive within `fm-fleet-snapshot.v1`: an existing v1
# consumer that reads only the fields it knows keeps working unchanged.
# Human views must render this output instead of parsing state files again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"
SNAPSHOT_NOW=${FM_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ -n "${FM_SNAPSHOT_NOW_EPOCH:-}" ]; then
  SNAPSHOT_EPOCH=$FM_SNAPSHOT_NOW_EPOCH
else
  SNAPSHOT_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date -u -d "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date +%s)
fi
case "$SNAPSHOT_EPOCH" in ''|*[!0-9]*) SNAPSHOT_EPOCH=$(date +%s) ;; esac

# Cross-home bounds are explicit so one broken or unexpectedly large home cannot
# hang or explode the parent snapshot.
FM_SNAPSHOT_SECONDMATES=${FM_SNAPSHOT_SECONDMATES:-20}
FM_SNAPSHOT_SECONDMATE_TIMEOUT=${FM_SNAPSHOT_SECONDMATE_TIMEOUT:-8}
FM_SNAPSHOT_SECONDMATE_MAX_BYTES=${FM_SNAPSHOT_SECONDMATE_MAX_BYTES:-262144}
FM_SNAPSHOT_SECONDMATE_CHILDREN=${FM_SNAPSHOT_SECONDMATE_CHILDREN:-20}
FM_SNAPSHOT_SECONDMATE_QUEUED=${FM_SNAPSHOT_SECONDMATE_QUEUED:-20}
FM_SNAPSHOT_SECONDMATE_DECISIONS=${FM_SNAPSHOT_SECONDMATE_DECISIONS:-20}
FM_SNAPSHOT_TERMINAL_LINES=${FM_SNAPSHOT_TERMINAL_LINES:-8}
FM_SNAPSHOT_TERMINAL_BYTES=${FM_SNAPSHOT_TERMINAL_BYTES:-4096}
FM_SNAPSHOT_TERMINAL_TIMEOUT=${FM_SNAPSHOT_TERMINAL_TIMEOUT:-2}
FM_SNAPSHOT_PARENT_ACTIVITY_LINES=${FM_SNAPSHOT_PARENT_ACTIVITY_LINES:-256}
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES=${FM_SNAPSHOT_PARENT_ACTIVITY_BYTES:-65536}
FM_SNAPSHOT_PARENT_ACTIVITIES=${FM_SNAPSHOT_PARENT_ACTIVITIES:-20}
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=${FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT:-2}
FM_SNAPSHOT_REGISTRY_LINES=${FM_SNAPSHOT_REGISTRY_LINES:-256}
FM_SNAPSHOT_REGISTRY_BYTES=${FM_SNAPSHOT_REGISTRY_BYTES:-65536}
FM_SNAPSHOT_REGISTRY_RECORDS=${FM_SNAPSHOT_REGISTRY_RECORDS:-40}
FM_SNAPSHOT_REGISTRY_TIMEOUT=${FM_SNAPSHOT_REGISTRY_TIMEOUT:-2}
FM_SNAPSHOT_HISTORY=${FM_SNAPSHOT_HISTORY:-40}
# Per-task read bounds. The tasks[] projection is one independent read per
# state/<id>.meta, so it runs FM_SNAPSHOT_TASK_JOBS of them at a time and bounds
# each task's current-state call at FM_SNAPSHOT_TASK_TIMEOUT seconds; both
# defaults are derived from measured cost in
# docs/verification/dashboard-fleet-health.md.
FM_SNAPSHOT_TASK_JOBS=${FM_SNAPSHOT_TASK_JOBS:-8}
FM_SNAPSHOT_TASK_TIMEOUT=${FM_SNAPSHOT_TASK_TIMEOUT:-8}
validate_positive_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      printf 'fm-fleet-snapshot: %s must be a positive integer\n' "$1" >&2
      exit 2
      ;;
  esac
}
case "$FM_SNAPSHOT_SECONDMATES" in
  ''|*[!0-9]*)
    echo "fm-fleet-snapshot: FM_SNAPSHOT_SECONDMATES must be a non-negative integer" >&2
    exit 2
    ;;
esac
case "$FM_SNAPSHOT_HISTORY" in
  ''|*[!0-9]*)
    echo "fm-fleet-snapshot: FM_SNAPSHOT_HISTORY must be a non-negative integer" >&2
    exit 2
    ;;
esac
validate_positive_bound FM_SNAPSHOT_SECONDMATE_TIMEOUT "$FM_SNAPSHOT_SECONDMATE_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_MAX_BYTES "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_CHILDREN "$FM_SNAPSHOT_SECONDMATE_CHILDREN"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_QUEUED "$FM_SNAPSHOT_SECONDMATE_QUEUED"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_DECISIONS "$FM_SNAPSHOT_SECONDMATE_DECISIONS"
validate_positive_bound FM_SNAPSHOT_TERMINAL_LINES "$FM_SNAPSHOT_TERMINAL_LINES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_BYTES "$FM_SNAPSHOT_TERMINAL_BYTES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_TIMEOUT "$FM_SNAPSHOT_TERMINAL_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_LINES "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_BYTES "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITIES "$FM_SNAPSHOT_PARENT_ACTIVITIES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_REGISTRY_LINES "$FM_SNAPSHOT_REGISTRY_LINES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_BYTES "$FM_SNAPSHOT_REGISTRY_BYTES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_RECORDS "$FM_SNAPSHOT_REGISTRY_RECORDS"
validate_positive_bound FM_SNAPSHOT_REGISTRY_TIMEOUT "$FM_SNAPSHOT_REGISTRY_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_TASK_JOBS "$FM_SNAPSHOT_TASK_JOBS"
validate_positive_bound FM_SNAPSHOT_TASK_TIMEOUT "$FM_SNAPSHOT_TASK_TIMEOUT"
# The outer per-task bound must leave room for a strictly smaller inner one, and
# 1 does not: the smallest bound fm_run_timed will honor is also 1, so at an
# outer bound of 1 the two are equal and the inner lookup can never expire
# first. That is refused here rather than silently clamped, because a caller who
# asked for a 1-second per-task bound asked for something this command cannot
# deliver, and quietly giving them a different arrangement is how the two bounds
# came to disagree in the first place.
if [ "$FM_SNAPSHOT_TASK_TIMEOUT" -lt 2 ]; then
  printf 'fm-fleet-snapshot: FM_SNAPSHOT_TASK_TIMEOUT must be at least 2, so the inner lookup bound can sit strictly inside it\n' >&2
  exit 2
fi
# The bound fm-crew-state.sh applies to its own no-mistakes lookup while this
# command is the caller, DERIVED from the outer bound above rather than written
# as a second independent number so the two cannot silently invert when someone
# retunes the outer one. It has to sit strictly below the outer bound: crew-state
# answers a failed lookup with a bounded `run-step-degraded` replay, and if the
# outer bound fires first that designed answer is unreachable from here, so a
# saturated daemon costs a task its whole reading rather than degrading it. The
# 3 seconds of headroom cover crew-state's non-lookup work, measured well under a
# second on this fleet in docs/verification/dashboard-fleet-health.md. With the
# outer bound refused below 2 above, the floor of 1 here is always strictly
# inside it.
FM_SNAPSHOT_TASK_NM_TIMEOUT=$(( FM_SNAPSHOT_TASK_TIMEOUT - 3 ))
[ "$FM_SNAPSHOT_TASK_NM_TIMEOUT" -ge 1 ] || FM_SNAPSHOT_TASK_NM_TIMEOUT=1

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"  # validate_secondmate_home: shared seeded-home boundary checks
# shellcheck source=bin/fm-outcome-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-outcome-lib.sh"  # durable manifest, work-item, and PR-status contracts
# shellcheck source=bin/fm-supervision-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-supervision-lib.sh"  # fm_sup_grace_seconds, fm_sup_busy_turn_max_seconds: shared supervision windows
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"  # fm_pr_url_parse: shared forge identity parsing
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the owner of bounded external execution

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh --json
       fm-fleet-snapshot.sh --secondmate-home-summary

Print a read-only structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.

--secondmate-home-summary emits the bounded structured summary used after a
validated registered-home handoff. It is local-only, skips nested secondmate
aggregation, and marks inventory contradictions or unavailable child state invalid.
Its invalidity object names the normalized failure kind and affected ids.
Actionable tasks-axi captain holds appear as decisions_open and stay visible in
queued with hold_reason, hold_kind, and plural blocker fields for downstream
projections. A captain hold is actionable only when every blocker is Done.
Per-task reads run FM_SNAPSHOT_TASK_JOBS (default 8) at a time and each task's
current-state read is bounded by FM_SNAPSHOT_TASK_TIMEOUT (default 8 seconds),
with the child's own no-mistakes lookup bounded 3 seconds inside that;
a task whose read did not finish reports current_state unknown with source
"timeout" rather than costing the whole snapshot, one that could not be started
reports "not-attempted", and one whose whole row could not be built is still
listed with source "row-unavailable".
Cross-home reads use FM_SNAPSHOT_SECONDMATES (default 20, 0 lifts the count
bound), FM_SNAPSHOT_SECONDMATE_TIMEOUT, and FM_SNAPSHOT_SECONDMATE_MAX_BYTES.
Terminal contradiction evidence uses
FM_SNAPSHOT_TERMINAL_LINES, FM_SNAPSHOT_TERMINAL_BYTES, and
FM_SNAPSHOT_TERMINAL_TIMEOUT and never becomes canonical current state.
Parent activity evidence uses FM_SNAPSHOT_PARENT_ACTIVITY_LINES,
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES, FM_SNAPSHOT_PARENT_ACTIVITIES, and
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT, with truncation disclosed in the result.
The registered secondmate table uses FM_SNAPSHOT_REGISTRY_LINES,
FM_SNAPSHOT_REGISTRY_BYTES, FM_SNAPSHOT_REGISTRY_RECORDS, and
FM_SNAPSHOT_REGISTRY_TIMEOUT, with unavailability and truncation disclosed.
EOF
}

OUTPUT_MODE=json
case "${1:---json}" in
  --json) ;;
  --secondmate-home-summary) OUTPUT_MODE=secondmate-home-summary ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-snapshot: jq not found" >&2; exit 1; }

# Scratch space for the concurrent per-task readers in task_json_lines. It holds
# one file per task and never outlives this command; nothing under the
# operational home is written, which keeps this command read-only.
SNAPSHOT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-snapshot.XXXXXX") || {
  echo "fm-fleet-snapshot: could not create a scratch directory" >&2
  exit 1
}
trap 'rm -rf -- "$SNAPSHOT_TMP"' EXIT
trap 'rm -rf -- "$SNAPSHOT_TMP"; trap - EXIT; exit 143' HUP INT TERM

# jq payload convention, applied by every call site below that binds a JSON
# document whose size grows with the fleet (backlog, task inventory, secondmate
# summaries, aggregation accumulators).
# Such a document is bound with `--slurpfile <name>_doc <(printf '%s' "$x")` and
# unwrapped in the filter by `doc($<name>_doc) as $<name>`, never with --argjson.
# Reason: Linux caps a SINGLE argv string at MAX_ARG_STRLEN (32 pages = 131072
# bytes), independently of the much larger total ARG_MAX, so --argjson makes
# execve fail with E2BIG ("Argument list too long") once one payload crosses that
# ceiling - which a working fleet's backlog JSON already does. Reading the payload
# from a stream removes the ceiling without touching the filters' data model.
# `doc` also keeps the previous fail-closed behavior of --argjson: an empty or
# missing payload aborts the filter instead of silently projecting a null.
# Scalars, single paths, and per-record documents bounded by this script's
# FM_SNAPSHOT_* read bounds stay on --arg/--argjson: they cannot grow with the
# fleet, and argv keeps them adjacent to the names they bind.

bool_json() {
  if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi
}

path_present_json() {  # <path>
  local present=0
  [ -e "$1" ] && present=1
  jq -n --arg path "$1" --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present}'
}

meta_value() {  # <meta-file> <key>
  fm_meta_get "$1" "$2"
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

# model_verify_json: bin/fm-model-verify.sh's verdict for one task - whether the
# model the worker ACTUALLY ran on matches the model recorded for it at dispatch.
# The helper owns the whole contract; this only carries its structured answer.
# An unreadable or absent answer becomes an explicit `unverifiable` verdict, so a
# broken verifier can never render as a clean one.
model_verify_json() {  # <id>
  local id=$1 raw
  raw=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-model-verify.sh" "$id" --json 2>/dev/null || true
  )
  if [ -n "$raw" ] && printf '%s' "$raw" | jq -e '.verdict' >/dev/null 2>&1; then
    printf '%s' "$raw"
    return 0
  fi
  jq -n --arg id "$id" \
    '{id:$id,verdict:"unverifiable",recorded:null,actual:[],source:"none",
      detail:"model verification produced no readable answer"}'
}

# The reconciled current state for one task, bounded.
#
# This is the single most expensive read in the snapshot: fm-crew-state.sh asks
# the no-mistakes daemon for the task's run, reads its worktree, and reads the
# backend's busy verdict. It bounds its own no-mistakes call, but a saturated
# daemon still makes the whole call the tail of this command's runtime, so the
# call gets a deadline here as well. Exceeding it reports an explicit `timeout`
# source rather than a silent `none`: a reading this command could not take is
# not the same fact as a task that has no state to read, and a renderer must be
# able to tell them apart instead of drawing both as nothing.
#
# The bound comes from bin/fm-timeout-lib.sh, the declared owner of bounded
# external execution, and not from this file's own run_timed below: only
# fm_run_timed escalates to SIGKILL after the polite signal, and a bound that a
# wedged child can outlive by ignoring SIGTERM is the failure this deadline
# exists to prevent. Its exit codes are reported as that owner defines them -
# 124 or 137 means the bound elapsed, while 125 means no bounded runner could
# start, so the read was never attempted and must not claim a timeout it never
# reached.
crew_state_json() {  # <id>
  local id=$1 raw rest state source detail sep rc=0
  raw=$(
    fm_run_timed "$FM_SNAPSHOT_TASK_TIMEOUT" env \
      FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      FM_CREW_STATE_NM_TIMEOUT="$FM_SNAPSHOT_TASK_NM_TIMEOUT" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null
  ) || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    jq -n --arg secs "$FM_SNAPSHOT_TASK_TIMEOUT" \
      '{state:"unknown",source:"timeout",
        detail:("the current state could not be read within " + $secs + "s"),
        raw:""}'
    return 0
  fi
  if [ "$rc" -eq 125 ]; then
    jq -n '{state:"unknown",source:"not-attempted",
            detail:"no bounded runner was available, so the current-state read was never attempted",
            raw:""}'
    return 0
  fi
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" --arg detail "$detail" \
    '{state:$state,source:$source,detail:$detail,raw:$raw}'
}

# Seconds between a file's mtime and this snapshot's observation time, or empty
# when the path is missing or its mtime is unreadable. Never negative: a clock
# skew that puts a record in the future reports 0 rather than a nonsense age.
path_age_seconds() {  # <path>
  local m age
  [ -e "$1" ] || return 0
  m=$(fm_sup_stat_mtime "$1") || return 0
  [ -n "$m" ] || return 0
  case "$m" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( SNAPSHOT_EPOCH - m ))
  [ "$age" -lt 0 ] && age=0
  printf '%s' "$age"
}

# How long ago this task was dispatched, from the `spawned_at` epoch
# bin/fm-spawn.sh stamps into state/<id>.meta.
#
# The VALUE is read, never the file's mtime, because the two mean different
# things. state/<id>.meta is rewritten after dispatch by firstmate's own routine
# actions - bin/fm-pr-check.sh rebuilds it when it records a PR,
# bin/fm-promote.sh rewrites it on a kind flip, bin/fm-decision-hold.sh appends
# to it - so the file's mtime means "when anything last touched this record" and
# would silently reset a task's clock the moment a PR check was armed on it.
# Every one of those writers preserves the spawned_at LINE, so the stamped epoch
# stays what it says it is.
#
# bin/fm-watch.sh's busy_turn_over_age does age the meta FILE, and that is not
# the same use and must not be changed to match this: it is bounding how long a
# BUSY PANE may go with no turn-boundary wake, it owns that choice, and a file
# touched by an operator action is a defensible floor for that question.
#
# The clock-skew convention is path_age_seconds' above: never negative, 0 for a
# record stamped ahead of the observation. A record with no readable stamp has
# no spawn clock and prints nothing.
spawn_age_seconds() {  # <meta-file>
  local stamped age
  stamped=$(meta_value "$1" spawned_at) || return 0
  case "$stamped" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( SNAPSHOT_EPOCH - stamped ))
  [ "$age" -lt 0 ] && age=0
  printf '%s' "$age"
}

status_event_json() {  # <status-log>
  local log=$1 present=0 raw='' verb='' note='' at='' age=''
  if [ -f "$log" ]; then
    present=1
    raw=$(last_nonempty_line "$log" || true)
    verb=$(status_line_verb "$raw")
    note=$(status_line_note "$raw")
    at=$(fm_outcome_path_iso "$log")
    age=$(path_age_seconds "$log")
  fi
  jq -n \
    --arg path "$log" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --arg at "$at" \
    --arg age "$age" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"event_history",
      last_event:{state:$verb,note:$note,raw:$raw},
      last_event_at:(if $at == "" then null else $at end),
      last_event_age_seconds:(if $age == "" then null else ($age | tonumber) end)}'
}

# When this task's runtime last emitted a turn-boundary wake.
#
# state/<id>.turn-ended is the harness-neutral marker written by verified
# turn-end producers and cursor/agy's debounced native-idle detector, and
# bin/fm-watch.sh already ages exactly this file to bound how long a busy pane
# may go with no turn-boundary wake (busy_turn_over_age). It stays what that
# owner says it is - a wake NOTIFICATION and an activity timestamp, never
# current-state truth or terminal attestation - and this record carries only its age so
# a renderer can tell a task that has been quiet from one that has been idle.
# An absent marker is reported as absent rather than as an age, because a task
# whose runtime has emitted no turn-boundary wake and one whose harness never
# touches the marker have the same projection, and neither is evidence of a stall.
turn_marker_json() {  # <turn-ended-path>
  local marker=$1 present=0 at='' age=''
  if [ -e "$marker" ]; then
    present=1
    at=$(fm_outcome_path_iso "$marker")
    age=$(path_age_seconds "$marker")
  fi
  jq -n \
    --arg path "$marker" \
    --arg at "$at" \
    --arg age "$age" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"turn_boundary",
      last_turn_at:(if $at == "" then null else $at end),
      last_turn_age_seconds:(if $age == "" then null else ($age | tonumber) end)}'
}

# The parsed forge identity for a recorded PR URL. Unparseable or absent leaves
# every part null while the raw url field keeps whatever was recorded.
pr_identity_json() {  # <pr-url>
  local url=$1
  if [ -z "$url" ] || ! fm_pr_url_parse "$url"; then
    jq -n '{provider:null,host:null,path:null,number:null}'
    return 0
  fi
  jq -n --arg provider "$FM_PR_PROVIDER" --arg host "$FM_PR_HOST" \
    --arg path "$FM_PR_PATH" --arg number "$FM_PR_NUMBER" \
    '{provider:$provider,host:$host,path:$path,
      number:(if $number == "" then null else ($number | tonumber) end)}'
}

first_pr_url_in_file() {  # <file>
  [ -f "$1" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$1" 2>/dev/null | head -1
}

# Epoch of midnight LOCAL time on a calendar date, empty when the date is not a
# real one. BSD date takes -j -f, GNU date takes -d.
day_start_epoch() {  # <YYYY-MM-DD>
  date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null \
    || date -d "$1 00:00:00" +%s 2>/dev/null \
    || return 1
}

# Local-midnight instant for every calendar date a backlog names, keyed by the
# date as written. tasks-axi writes `since` as a LOCAL date, so the day it names
# begins at local midnight; jq's strptime|mktime reads a date as UTC and would
# put the day start up to a whole offset away from the one the writer meant.
# Resolving the instant here also gives each date its own offset, which a single
# observation-time offset would get wrong across a daylight-saving change.
backlog_day_starts_json() {  # <backlog-path>
  local day epoch pairs=''
  while IFS= read -r day; do
    epoch=$(day_start_epoch "$day") || continue
    pairs+="$day $epoch"$'\n'
  done < <(grep -Eo '[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}' "$1" 2>/dev/null | sort -u)
  printf '%s' "$pairs" \
    | jq -Rn '[inputs | split(" ") | {key:.[0],value:(.[1] | tonumber)}] | from_entries'
}

backlog_json() {  # [<backlog-path>] - defaults to this home's $BACKLOG
  local backlog=${1:-$BACKLOG}
  if [ ! -f "$backlog" ]; then
    jq -n --arg path "$backlog" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$backlog" --arg now_epoch "$SNAPSHOT_EPOCH" \
    --argjson day_starts "$(backlog_day_starts_json "$backlog")" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    # Seconds since the START of the local day a row records in its `since`
    # metadata, taken from the $day_starts map the caller resolved in the local
    # timezone tasks-axi wrote that date in. A backlog row carries a date and no
    # clock time, so this is an upper bound at day granularity rather than a
    # precise elapsed time. A value the map does not hold was never a readable
    # calendar date, so it stays null rather than becoming a fabricated zero.
    # Never negative: a row dated ahead of this observation reports 0, the same
    # convention path_age_seconds uses for a file whose mtime is in the future.
    def since_age($date):
      if $date == null or $date == "" then null
      else ($day_starts[$date] // null) as $start
        | if $start == null then null
          else (($now_epoch | tonumber) - $start) as $age
            | (if $age < 0 then 0 else $age end)
          end
      end;
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
'"$FM_OUTCOME_BACKLOG_TITLE_JQ"'
    def blocked_by_ids($rest):
      [ $rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0] ]
      | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             hold_reason:metadata($rest; "hold"),
             hold_kind:metadata($rest; "hold-kind"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_by_ids:blocked_by_ids($rest),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             since_age_seconds:since_age(metadata_word($rest; "since")),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       # A non-empty line that begins with whitespace is a continuation of the
       # previous record, structured OR unstructured. Multi-line free-form
       # notes in In flight or Queued are a supported shape, and the previous
       # rule attached continuation lines only to structured parents, which
       # meant a 3-line free-form note became one parent plus two spurious
       # "unstructured current backlog row" records. A signal that is always
       # red for any real backlog carries no information, so the rule now
       # matches the same indentation heuristic Markdown renderers do: indent
       # means continuation, not a new record.
       elif ((.records | length) > 0 and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | .records as $records
    | (reduce ($records[] | select(.structured)) as $record ({};
         .[$record.id] = ((.[$record.id] // true) and ($record.state == "done")))) as $resolved_ids
    | .records |= map(
        if .structured then
          . as $record
          | .unresolved_blocker_ids = [
              $record.blocked_by_ids[] as $blocker
              | select($resolved_ids[$blocker] != true)
              | $blocker
            ]
          | .current_role =
              (if .state == "in_flight" and .hold_reason != null and .hold_kind != null then "held"
               elif .state == "in_flight" and .kind == "program" then "program"
               elif .state == "in_flight" then "worker"
               elif .state == "queued" then "queued"
               else "done" end)
          | .requires_child_metadata = (.current_role == "worker")
          | .captain_actionable =
              (.state == "queued" and .kind == "captain" and .hold_kind == "captain"
               and .hold_reason != null and (.unresolved_blocker_ids | length) == 0)
        else . end)
    | del(.section,.order)
  ' < "$backlog"
}

# One task's row of the tasks[] projection, printed as a single JSON object.
#
# Every read here is scoped to this one task, which is what lets
# task_json_lines below run several of them at once.
#
# Passing `degraded` as the second argument builds the SAME row shape without
# the reads that can fail - the crew-state and model-verify subprocesses, the
# work-item document, and the endpoint probe - filling each with the explicit
# unknown for its field. task_json_lines uses it to reconcile a task whose own
# reader produced nothing readable, so a row that could not be built is still a
# row. It is deliberately the same function rather than a second hand-written
# object: two copies of the row shape is exactly what drifts. The cheap local
# file reads stay, because none of them is a plausible cause of a reader dying
# and the values they fill - the spawn stamp above all - are what let a renderer
# age a row it otherwise knows nothing about.
task_json_one() {  # <meta-path> [degraded]
  local meta=$1 degraded=${2:-}
  local spawn_age
  local id kind harness model effort mode yolo project worktree home projects backend target status_log report_path
  local remote_host remote_root remote_state remote_rc remote_home_present
  local pr pr_source event_json current_json model_json endpoint_exists agent_alive meta_json status_json report_json worktree_json home_json
  local last_event_raw last_event_declared_wait current_state current_source pending_decision blocked_event report_present=0 pr_from_status
  local open_decisions_tsv open_decisions_json
  local pr_head pr_identity pr_status pr_status_path pr_status_at pr_status_age work_items_json
  local turn_marker turn_json

  id=$(basename "$meta" .meta)
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  harness=$(meta_value "$meta" harness)
  model=$(meta_value "$meta" model)
  effort=$(meta_value "$meta" effort)
  mode=$(meta_value "$meta" mode)
  yolo=$(meta_value "$meta" yolo)
  project=$(meta_value "$meta" project)
  worktree=$(meta_value "$meta" worktree)
  home=$(meta_value "$meta" home)
  projects=$(meta_value "$meta" projects)
  remote_host=$(meta_value "$meta" remote_host)
  remote_root=$(meta_value "$meta" remote_root)
  remote_home_present=null
  if [ -n "$remote_host" ]; then
    backend=$(meta_value "$meta" remote_backend)
    [ -n "$backend" ] || backend=unknown
    target=$(meta_value "$meta" remote_target)
  else
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
  fi
  status_log="$STATE/$id.status"
  turn_marker="$STATE/$id.turn-ended"
  report_path="$DATA/$id/report.md"
  pr=$(meta_value "$meta" pr)
  pr_source=meta
  if [ -z "$pr" ]; then
    pr_from_status=$(first_pr_url_in_file "$status_log" || true)
    pr=$pr_from_status
    pr_source=status_event
  fi
  if [ -z "$pr" ]; then
    pr_source=absent
  fi
  pr_head=$(meta_value "$meta" pr_head)
  fm_outcome_sha_valid "$pr_head" || pr_head=
  pr_identity=$(pr_identity_json "$pr")
  # Cached only: this command stays offline, so an unrefreshed PR reports
  # state "unknown" with source "absent" rather than blocking on a forge.
  pr_status=$(fm_outcome_pr_status_read "$STATE" "$id" "$pr")
  pr_status_path=$(fm_outcome_pr_status_path "$STATE" "$id")
  pr_status_at=$(printf '%s' "$pr_status" | jq -r '.observed_at // ""')
  if [ -n "$pr_status_at" ]; then
    pr_status_age=$(path_age_seconds "$pr_status_path")
  else
    pr_status_age=
  fi
  if [ "$degraded" = degraded ]; then
    work_items_json='[]'
  else
    work_items_json=$(fm_outcome_work_items_read "$DATA" "$id" | jq -c '.references')
  fi

  if [ "$degraded" = degraded ]; then
    current_json=$(jq -n '{state:"unknown",source:"row-unavailable",
      detail:"the row for this task could not be built, so no current state was read",
      raw:""}')
  else
    current_json=$(crew_state_json "$id")
  fi
  if [ "$degraded" = degraded ]; then
    model_json='{"verdict":"unverifiable","recorded":null,"actual":[],"source":"none","detail":"the row for this task could not be built, so no model verification was attempted"}'
  elif [ "$OUTPUT_MODE" = secondmate-home-summary ]; then
    model_json='{"verdict":"not_checked","recorded":null,"actual":[],"source":"none","detail":"not included in bounded secondmate home summaries"}'
  else
    model_json=$(model_verify_json "$id")
  fi
  event_json=$(status_event_json "$status_log")
  last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
  # Whether the newest event DECLARES its own quiet, judged by the same
  # fm-classify-lib.sh vocabulary the watcher uses so the dashboard and
  # supervision cannot drift apart on what a declared wait is. A renderer
  # reading elapsed time alone cannot tell "gone quiet" from "said it would
  # be quiet"; this is the field that lets it.
  if status_is_paused_or_captain_held "$last_event_raw"; then
    last_event_declared_wait=1
  else
    last_event_declared_wait=0
  fi
  current_state=$(printf '%s' "$current_json" | jq -r '.state // ""')
  current_source=$(printf '%s' "$current_json" | jq -r '.source // ""')

  # Durable keyed open-decision set: fold the WHOLE status stream
  # (fm-classify-lib.sh's status_open_decisions) so a later unrelated event can
  # never mask a still-open captain decision. The set is derived purely from the
  # keyed fold - never from report bodies or decision-like prose - and then
  # reconciled against the crew LIFECYCLE, which only clears a stale decision the
  # crew has provably moved past. Two lifecycle signals clear it, neither of which
  # reads any report content:
  #   - a live activity read (run-step or busy pane) that is working/done, so a
  #     crew that resumed past a gate is not still reported as parked; and
  #   - a TERMINAL done/failed state on a single-owner task (scout, design, or ship), whose
  #     deliverable is its report or PR, so a COMPLETED scout surfaces only as a
  #     report POINTER, never as a reopened pending decision.
  # Secondmates are excluded from lifecycle clearing: they are persistent and
  # multiplex many concerns onto one stream, so activity on one concern must
  # never clear another concern's keyed decision. A parked/blocked state, or a
  # non-authoritative status-log/none read on a still-live task, keeps the fold's
  # open decision surfacing. `run-step-degraded` is deliberately absent from the
  # live-activity sources: it is a remembered step the reader could not
  # re-confirm, which is enough to keep a crew provably working for wedge triage
  # but never enough to clear a captain decision.
  open_decisions_tsv=$(status_open_decisions "$status_log")
  if [ "$kind" != secondmate ] && \
     { { { [ "$current_source" = run-step ] || [ "$current_source" = pane ]; } \
         && [ "$current_state" != parked ] && [ "$current_state" != blocked ]; } \
       || { [ "$current_state" = "done" ] || [ "$current_state" = "failed" ]; }; }; then
    open_decisions_tsv=""
  fi
  open_decisions_json=$(printf '%s' "$open_decisions_tsv" | jq -R -s '
    [ splits("\n") | select(length > 0)
      | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
      | select(. != null) ]')
  pending_decision=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "needs-decision") then 1 else 0 end')
  blocked_event=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "blocked") then 1 else 0 end')

  endpoint_exists=null
  agent_alive=not_checked
  if [ "$degraded" = degraded ]; then
    # `not_checked` is a statement that the check was deliberately skipped and
    # nothing is wrong; this row cannot make that statement, so it says unknown.
    agent_alive=unknown
  elif [ -n "$remote_host" ]; then
    if remote_state=$(run_timed "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" \
      "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
      remote_rc=0
    else
      remote_rc=$?
    fi
    if [ "$remote_rc" -eq 0 ]; then
      remote_home_present=true
      remote_state=$(printf '%s\n' "$remote_state" | tail -1)
      case "$remote_state" in
        alive) endpoint_exists=true; agent_alive=alive ;;
        dead) endpoint_exists=true; agent_alive=dead ;;
        missing) endpoint_exists=false; agent_alive=dead ;;
        *) endpoint_exists=null; agent_alive=unknown ;;
      esac
    else
      endpoint_exists=null
      agent_alive=unknown
    fi
  else
    if [ -n "$target" ]; then
      if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
        endpoint_exists=true
      else
        endpoint_exists=false
      fi
    fi
    if [ "$kind" = secondmate ] && [ -n "$target" ]; then
      agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
    fi
  fi

  [ -f "$report_path" ] && report_present=1 || report_present=0
  spawn_age=$(spawn_age_seconds "$meta")
  meta_json=$(path_present_json "$meta")
  status_json=$event_json
  turn_json=$(turn_marker_json "$turn_marker")
  report_json=$(path_present_json "$report_path")
  if [ -n "$worktree" ]; then worktree_json=$(path_present_json "$worktree"); else worktree_json=$(jq -n '{path:null,present:false}'); fi
  if [ -n "$home" ] && [ -n "$remote_host" ]; then
    home_json=$(jq -n --arg path "$home" --argjson present "$remote_home_present" '{path:$path,present:$present}')
  elif [ -n "$home" ]; then
    home_json=$(path_present_json "$home")
  else
    home_json=$(jq -n '{path:null,present:false}')
  fi

  jq -n \
    --arg id "$id" \
    --arg kind "$kind" \
    --arg harness "$harness" \
    --arg model "$model" \
    --arg effort "$effort" \
    --arg mode "$mode" \
    --arg yolo "$yolo" \
    --arg project "$project" \
    --arg worktree "$worktree" \
    --arg home "$home" \
    --arg projects "$projects" \
    --arg backend "$backend" \
    --arg target "$target" \
    --arg remote_host "$remote_host" \
    --arg remote_root "$remote_root" \
    --arg pr "$pr" \
    --arg pr_source "$pr_source" \
    --arg pr_head "$pr_head" \
    --arg pr_status_age "$pr_status_age" \
    --argjson pr_identity "$pr_identity" \
    --argjson pr_status "$pr_status" \
    --argjson work_items "$work_items_json" \
    --arg agent_alive "$agent_alive" \
    --arg observed_at "$SNAPSHOT_NOW" \
    --arg spawn_age "$spawn_age" \
    --arg last_event_raw "$last_event_raw" \
    --argjson current_state "$current_json" \
    --argjson model_verification "$model_json" \
    --argjson meta_path "$meta_json" \
    --argjson status_log "$status_json" \
    --argjson turn_ended "$turn_json" \
    --argjson report "$report_json" \
    --argjson worktree_path "$worktree_json" \
    --argjson home_path "$home_json" \
    --argjson endpoint_exists "$endpoint_exists" \
    --argjson open_decisions "$open_decisions_json" \
    --argjson pending_decision "$(bool_json "$pending_decision")" \
    --argjson blocked_event "$(bool_json "$blocked_event")" \
    --argjson report_present "$(bool_json "$report_present")" \
    --argjson last_event_declared_wait "$(bool_json "$last_event_declared_wait")" \
    '
    # Card precedence: the FIRST matching rung wins, so overlapping signals
    # resolve to exactly one column. An open decision outranks everything
    # because it is unanswered work for firstmate or the captain even when a
    # PR is already open; a blocker outranks a failure because the worker is
    # still there and asking; a failure outranks an open PR because the PR is
    # not the live problem; and an open PR outranks done because a task that
    # reported "PR checks green" has not landed until that PR is merged.
    def card($kind; $state; $pending; $blocked; $pr_recorded; $pr_merged):
      if $pending then
        {rank:1,column:"needs_decision",action:"decide",
         reason:"an open decision is waiting on firstmate or the captain"}
      elif $blocked then
        {rank:2,column:"blocked",action:"unblock",
         reason:"the worker reported a blocker it cannot clear itself"}
      elif $state == "parked" then
        {rank:3,column:"parked",action:"respond_to_gate",
         reason:"validation is parked at a gate awaiting a response"}
      elif $state == "failed" then
        {rank:4,column:"failed",action:"investigate",
         reason:"the task reported a failure"}
      elif $pr_recorded and ($pr_merged | not) then
        {rank:5,column:"review",action:"review_pr",
         reason:"a pull request is recorded and not confirmed merged"}
      elif $state == "done" then
        {rank:6,column:"done",action:"close_out",
         reason:"the task reported completion with nothing left open"}
      elif $state == "paused" then
        {rank:7,column:"waiting",action:"recheck",
         reason:"a declared external wait expected to clear on its own"}
      elif $state == "working" then
        {rank:8,column:"active",action:"supervise",
         reason:"the worker is working"}
      elif $kind == "secondmate" then
        {rank:9,column:"secondmate",action:"route_work",
         reason:"a persistent secondmate with no higher-priority task signal"}
      else
        {rank:10,column:"idle",action:"inspect",
         reason:"no current signal"}
      end;
    {
      id:$id,
      kind:$kind,
      harness:($harness // ""),
      model:($model // ""),
      effort:($effort // ""),
      mode:($mode // ""),
      yolo:($yolo // ""),
      project:($project // ""),
      backend:$backend,
      remote:(if $remote_host == "" then null else {host:$remote_host,root:$remote_root} end),
      paths:{
        meta:$meta_path,
        status_log:$status_log,
        turn_ended:$turn_ended,
        worktree:$worktree_path,
        home:$home_path,
        report:$report
      },
      secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
      spawn_age_seconds:($spawn_age | if . == "" then null else tonumber end),
      current_state:($current_state + {observed_at:$observed_at,freshness:"fresh"}),
      model_verification:($model_verification | del(.id) | . + {observed_at:$observed_at}),
      endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive,
        status:(if $endpoint_exists == false then "absent"
                elif $agent_alive == "alive" or $agent_alive == "dead" then $agent_alive
                else "unknown" end),
        observed_at:$observed_at,freshness:"fresh"},
      pr:({url:($pr | if . == "" then null else . end),
           source:$pr_source,
           head:($pr_head | if . == "" then null else . end),
           status:$pr_status,
           status_age_seconds:($pr_status_age | if . == "" then null else tonumber end),
           status_freshness:(if $pr_status.observed_at == null then "absent" else "cached" end)}
          + $pr_identity),
      work_items:$work_items,
      hints:{
        pending_decision:$pending_decision,
        blocked_event:$blocked_event,
        open_decisions:$open_decisions,
        scout_report_present:$report_present,
        last_event_text:$last_event_raw,
        last_event_declared_wait:$last_event_declared_wait
      },
      card:(card($kind;
                 $current_state.state;
                 $pending_decision;
                 $blocked_event;
                 ($pr != "");
                 ($pr_status.state == "merged"))
            + {signals:{pending_decision:$pending_decision,
                        blocked_event:$blocked_event,
                        current_state:$current_state.state,
                        pr_recorded:($pr != ""),
                        pr_merged:($pr_status.state == "merged")}}),
      actions:(
        if $kind == "secondmate" then
          {send:"bin/fm-send.sh fm-\($id) \u0027<request>\u0027",
           watch:"read status/doc return channel; do not routinely fm-peek a secondmate for answers",
           return_channel_note:"Secondmate answers come back through status/doc paths after a marked fm-send request."}
        else
          {watch:"bin/fm-peek.sh fm-\($id)",
           steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
           return_channel_note:null}
        end)
    }'
}

# The tasks[] projection, sorted by id.
#
# Each state/<id>.meta is an independent read, and the dominant cost of this
# whole command is one bounded fm-crew-state.sh call per task. Run one after
# another, that cost grows with how much work is in flight - so the fleet view
# got slowest at exactly the moment it was most wanted, and past the deadline
# its callers give it. The readers therefore run FM_SNAPSHOT_TASK_JOBS at a
# time, which turns the command's runtime into roughly the cost of its slowest
# single task rather than the sum of all of them.
#
# Each reader writes its own file rather than a shared stream, so no two tasks'
# JSON can interleave, and the ordering below comes from the sort rather than
# from the order the readers happen to finish in. Background readers do not
# inherit this shell's EXIT trap, so none of them can remove the scratch
# directory the others are still writing into.
# The rows the concurrent readers actually produced, as one sorted JSON array.
#
# One jq for the whole fleet is the point: a per-file parse would reintroduce
# the per-task serial cost this projection was rebuilt to remove. A file that
# landed truncated fails that single slurp outright, so that case - and only
# that case - falls back to parsing each file on its own, which salvages the
# rows that are fine instead of discarding every one of them. Both paths simply
# omit an id they cannot read; the caller reconciles what is missing.
task_rows_produced() {  # <workdir>
  local workdir=$1 rows='' file row
  if rows=$(cat "$workdir"/*.json 2>/dev/null | jq -s 'sort_by(.id)' 2>/dev/null) \
    && [ -n "$rows" ]; then
    printf '%s' "$rows"
    return 0
  fi
  rows=''
  for file in "$workdir"/*.json; do
    [ -s "$file" ] || continue
    row=$(jq -c . "$file" 2>/dev/null) || continue
    rows+="$row"$'\n'
  done
  printf '%s' "$rows" | jq -s 'sort_by(.id)'
}

task_json_lines() {
  local meta id pid workdir row rows='' produced missing
  local -a pids=() ids=()
  workdir="$SNAPSHOT_TMP/tasks"
  mkdir -p "$workdir" || return 1
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    ids+=("$id")
    task_json_one "$meta" > "$workdir/$id.json" &
    pids+=("$!")
    # Bounded fan-out, oldest first: the window refills as soon as the reader
    # that has been running longest finishes, so one slow task delays only
    # itself instead of holding a whole batch at a barrier.
    while [ "${#pids[@]}" -ge "$FM_SNAPSHOT_TASK_JOBS" ]; do
      wait "${pids[0]}" 2>/dev/null || true
      pids=("${pids[@]:1}")
    done
  done
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] || continue
    wait "$pid" 2>/dev/null || true
  done
  # Reconcile the ids this function launched a reader for against the rows those
  # readers actually produced. Slurping the files alone would silently skip an
  # empty or unparseable one, and a task missing from tasks[] reads as a fleet
  # that does not have it - strictly worse than an unknown row, because a
  # reading that could not be taken must render as unknown and never as a pass.
  #
  # The comparison is a set difference computed in the one jq that already
  # slurps the rows, NOT a parse per task: this function exists to stop per-task
  # cost growing with the fleet, and a jq process per row would put that cost
  # straight back into the collector where it is purely serial. A healthy
  # snapshot therefore spends exactly one jq here however large the fleet is,
  # and a process per failed task only when one actually failed.
  produced=$(task_rows_produced "$workdir")
  missing=$(printf '%s\n' "${ids[@]:-}" | jq -R -r -s \
    --slurpfile produced_doc <(printf '%s' "$produced") '
      (($produced_doc[0] // []) | map(.id)) as $have
      | [ splits("\n") | select(length > 0) ] - $have
      | .[]')
  if [ -z "$missing" ]; then
    printf '%s' "$produced"
    return 0
  fi
  # An id with nothing readable gets task_json_one's degraded row, built here in
  # this process rather than through the scratch file whose write may be exactly
  # what failed. If even that cannot be produced the whole snapshot fails loudly
  # naming the id, the same refusal the history read makes rather than publish a
  # document it knows is incomplete.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    row=$(task_json_one "$STATE/$id.meta" degraded | jq -c . 2>/dev/null) || row=''
    if [ -z "$row" ]; then
      printf 'fm-fleet-snapshot: no readable task row for %s\n' "$id" >&2
      return 1
    fi
    rows+="$row"$'\n'
  done <<EOF
$missing
EOF
  printf '%s' "$rows" | jq -s \
    --slurpfile produced_doc <(printf '%s' "$produced") \
    '(($produced_doc[0] // []) + .) | sort_by(.id)'
}

# Main-home current-inventory validity: same orphan / unstructured-current checks
# used by secondmate_home_summary_json, without inventing live task rows.
# Meta inventory remains the sole source of live workers; this object only
# discloses backlog↔task inconsistency for renderers (Bearings omitted/gates).
main_inventory_json() {  # <backlog-json> <tasks-json>
  jq -n \
    --slurpfile backlog_doc <(printf '%s' "$1") \
    --slurpfile tasks_doc <(printf '%s' "$2") '
    def doc($v): ($v[0] // error("fm-fleet-snapshot: empty jq payload"));
    doc($backlog_doc) as $backlog
    | doc($tasks_doc) as $tasks
    | ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]?
         | select(.state == "in_flight" and .structured and .requires_child_metadata) ]) as $owned_in_flight
    | ([ $owned_in_flight[]
         | select(.id as $id | [$tasks[].id] | index($id) | not)
         | .id ]) as $orphan_in_flight
    | (($unstructured_current | length) == 0
       and ($orphan_in_flight | length) == 0) as $valid
    | (if ($unstructured_current | length) > 0 then "unstructured current backlog row"
       elif ($orphan_in_flight | length) > 0 then "in-flight backlog item has no child metadata"
       else null end) as $reason
    | {
        valid:$valid,
        reason:$reason,
        orphan_in_flight:$orphan_in_flight,
        unstructured_current_count:($unstructured_current | length)
      }'
}

# Project one home's canonical structured inventory into the bounded shape a
# validated parent read needs.
# This mode never reads parent events or terminal text and never aggregates
# nested secondmates.
secondmate_home_summary_json() {  # <backlog-json> <tasks-json>
  jq -n \
    --arg generated "$SNAPSHOT_NOW" \
    --arg home "$FM_HOME" \
    --argjson child_n "$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
    --argjson queued_n "$FM_SNAPSHOT_SECONDMATE_QUEUED" \
    --argjson decisions_n "$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
    --argjson landed_n "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" \
    --slurpfile backlog_doc <(printf '%s' "$1") \
    --slurpfile tasks_doc <(printf '%s' "$2") '
    def doc($v): ($v[0] // error("fm-fleet-snapshot: empty jq payload"));
    def trunc($n):
      tostring | gsub("\\s+"; " ")
      | if length > $n then .[:$n] + "…" else . end;
    doc($backlog_doc) as $backlog
    | doc($tasks_doc) as $tasks
    | ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]? | select(.state == "in_flight" and .structured) ]) as $owned_in_flight
    | ([ $backlog.records[]?
         | select(.structured and
             (.state == "queued" or
              (.state == "in_flight" and .current_role == "held"
               and (.id as $id
                    | any($tasks[]; .id == $id and .current_state.state == "working") | not)))) ]) as $queued_all
    | ([ $queued_all[]
         | select(.captain_actionable == true)
         | {id,key:.id,verb:"captain-hold",summary:(.title | trunc(160)),
            reason:(.hold_reason | trunc(160)),source:"backlog"} ]) as $captain_holds_all
    | ([ $backlog.records[]? | select(.state == "done" and .structured and .kind != "captain")
         | {id:(.id | trunc(120)),title:(.title | trunc(120)),
            pr_url:((.pr_url // null) | if . == null then null else trunc(500) end),
            report_path:((.report_path // null) | if . == null then null else trunc(500) end),
            local_note:((.local_note // null) | if . == null then null else trunc(120) end),completion} ]
       | sort_by([(.completion.date // ""), .id]) | reverse) as $landed_all
    | ([ $tasks[] | select(.current_state.state == "unknown") ]) as $unknown_children
    | ([ $owned_in_flight[]
         | select(.requires_child_metadata)
         | select(.id as $id | [$tasks[].id] | index($id) | not) ]) as $orphan_in_flight
    | ([ $tasks[]
         | select(.id as $id | [$owned_in_flight[].id] | index($id) | not)
         | {id,state:.current_state.state} ]) as $unowned_children
    | ([ $owned_in_flight[] as $work
         | $tasks[]
         | select(.id == $work.id and (.current_state.state == "done" or .current_state.state == "failed"))
         | {id,state:.current_state.state} ]) as $terminal_in_flight
    | ([if $backlog.present != true then
          {kind:"missing_backlog",ids:[],reason:"missing structured backlog"}
        else empty end,
        if ($unstructured_current | length) > 0 then
          {kind:"unstructured_current",ids:[],reason:"unstructured current backlog row"}
        else empty end,
        if ($orphan_in_flight | length) > 0 then
          {kind:"orphan_in_flight",ids:($orphan_in_flight | map(.id)),
           reason:("in-flight backlog item has no child metadata: " + ($orphan_in_flight | map(.id) | join(", ")))}
        else empty end,
        if ($unowned_children | length) > 0 then
          {kind:"unowned_current",ids:($unowned_children | map(.id)),
           reason:("live child state has no in-flight backlog item: " +
                   ($unowned_children | map(.id + "=" + .state) | join(", ")))}
        else empty end,
        if ($terminal_in_flight | length) > 0 then
          {kind:"terminal_in_flight",ids:($terminal_in_flight | map(.id)),
           reason:("in-flight backlog item has terminal child state: " +
                   ($terminal_in_flight | map(.id + "=" + .state) | join(", ")))}
        else empty end]) as $strict_invalidities
    | ([ $owned_in_flight[] as $work
         | select($work.current_role != "program")
         | $tasks[]
         | select(.id == $work.id and .current_state.state == "working")
         | {id,kind,state:.current_state.state,source:.current_state.source,
            doing:((.current_state.detail // "") | trunc(120))} ]) as $active_all
    | ($captain_holds_all
       + ([ $tasks[] as $t | ($t.hints.open_decisions // [])[]
            | {id:$t.id,key,verb,summary:(.summary | trunc(160)),reason:null,source:"status"} ])) as $decisions_all
    | ([ $queued_all[]
         | select((.unresolved_blocker_ids | length) > 0 or (.hold_reason != null and .hold_kind != null))
         | {id:(.id | trunc(120)),title:(.title | trunc(90)),
            blocked_by:((.unresolved_blocker_ids | join(",")) | if . == "" then null else trunc(120) end),
            blocked_by_ids:(.blocked_by_ids | map(trunc(120))),
            unresolved_blocker_ids:(.unresolved_blocker_ids | map(trunc(120))),
            reason:((.hold_reason // .blocked_reason // "blocked") | trunc(120)),source:"backlog"} ]
       + [ $owned_in_flight[] as $work
           | $tasks[]
           | select(.id == $work.id and (.current_state.state == "parked" or .current_state.state == "paused" or .current_state.state == "blocked"))
           | select(($work.hold_reason != null and $work.hold_kind != null) | not)
           | {id,title:((.backlog.title // .id) | trunc(90)),blocked_by:null,
              blocked_by_ids:[],unresolved_blocker_ids:[],
              reason:((.current_state.detail // .current_state.state) | trunc(120)),source:"child-state"} ]) as $holds_all
    | ($backlog.present == true
       and ($unstructured_current | length) == 0
       and ($unknown_children | length) == 0
       and ($orphan_in_flight | length) == 0
       and ($unowned_children | length) == 0
       and ($terminal_in_flight | length) == 0) as $valid
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0].reason
       elif ($unknown_children | length) > 0 then
         "child current state unavailable: " + ($unknown_children | map(.id) | join(", "))
       else null end) as $reason
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0] | del(.reason)
       elif ($unknown_children | length) > 0 then {kind:"child_current_unavailable",ids:($unknown_children | map(.id))}
       else {kind:null,ids:[]} end) as $invalidity
    | (if $valid | not then "unknown"
       elif any($decisions_all[]; .verb == "needs-decision" or .verb == "captain-hold") then "captain_decision"
       elif ($active_all | length) > 0 then "active_child_work"
       elif ($holds_all | length) > 0 then "externally_held"
       else "no_active_work" end) as $state
    | {
        schema:"fm-secondmate-home-summary.v1",
        generated:$generated,
        home:$home,
        valid:$valid,
        reason:$reason,
        invalidity:$invalidity,
        state:$state,
        active_children:$active_all[:$child_n],
        decisions_open:$decisions_all[:$decisions_n],
        holds:$holds_all[:$queued_n],
        queued:([$queued_all[] | {id:(.id | trunc(120)),title:(.title | trunc(120)),
          blocked_by:((.blocked_by // null) | if . == null then null else trunc(120) end),
          blocked_by_ids:((.blocked_by_ids // []) | map(trunc(120))),
          unresolved_blocker_ids:((.unresolved_blocker_ids // []) | map(trunc(120))),
          blocked_reason:((.blocked_reason // null) | if . == null then null else trunc(160) end),
          hold_reason:((.hold_reason // null) | if . == null then null else trunc(160) end),
          hold_kind:((.hold_kind // null) | if . == null then null else trunc(40) end),
          captain_actionable:(.captain_actionable // false),
          repo:((.repo // null) | if . == null then null else trunc(120) end),
          kind:((.kind // null) | if . == null then null else trunc(40) end)}][:$queued_n]),
        landed:(if $landed_n == 0 then $landed_all else $landed_all[:$landed_n] end),
        endpoints:([$tasks[] | {id,state:.current_state.state,source:.current_state.source,
          endpoint:(.endpoint + {target:((.endpoint.target // null) | if . == null then null else trunc(240) end)})}][:$child_n]),
        counts:{
          active_children:($active_all | length),
          decisions_open:($decisions_all | length),
          holds:($holds_all | length),
          queued:($queued_all | length),
          landed:($landed_all | length),
          endpoints:($tasks | length)
        },
        omitted:[
          (if ($active_all | length) > $child_n then {surface:"active_children",count:(($active_all | length) - $child_n)} else empty end),
          (if ($decisions_all | length) > $decisions_n then {surface:"decisions_open",count:(($decisions_all | length) - $decisions_n)} else empty end),
          (if ($queued_all | length) > $queued_n then {surface:"queued",count:(($queued_all | length) - $queued_n)} else empty end),
          (if ($tasks | length) > $child_n then {surface:"endpoints",count:(($tasks | length) - $child_n)} else empty end),
          (if $landed_n > 0 and ($landed_all | length) > $landed_n then {surface:"landed",count:(($landed_all | length) - $landed_n)} else empty end)
        ]
      }'
}

# Current registered-secondmate aggregation.
# The validated home summary is canonical.
# Parent status and bounded terminal capture remain untrusted supplemental evidence
# with explicit provenance, and can only produce a contradiction or unknown fallback.
FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=${FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME:-10}
case "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" in ''|*[!0-9]*) FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=10 ;; esac

# This script's older local bound, kept for the cross-home, terminal, registry,
# and parent-activity reads that already call it. bin/fm-timeout-lib.sh is the
# declared owner of bounded execution and crew_state_json above uses it, but
# fm_run_timed reports an elapsed bound as 124 OR 137 where this one reports
# only 124, so moving these call sites means revisiting exit-code handling at
# each of them. That is its own change rather than one riding along with the
# per-task bound.
run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 124
  fi
}

# GNU stat treats -f as a filesystem-report command, so a BSD-first fallback can
# pollute arithmetic input before failing. Select the platform syntax once.
if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
  SNAPSHOT_STAT_STYLE=bsd
  file_mtime_epoch() { stat -f '%m' "$1" 2>/dev/null || true; }
  file_mode_octal() { stat -f '%Lp' "$1" 2>/dev/null || true; }
else
  SNAPSHOT_STAT_STYLE=gnu
  file_mtime_epoch() { stat -c '%Y' "$1" 2>/dev/null || true; }
  file_mode_octal() { stat -c '%a' "$1" 2>/dev/null || true; }
fi

registry_secondmates_json() {
  local reg="$DATA/secondmates.md" out rc reason mode script parse_filter output_filter
  if [ ! -f "$reg" ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      '{present:false,available:true,complete:true,reason:null,provenance:"registered-table",path:$path,freshness:{status:"fresh",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  mode=$(file_mode_octal "$reg")
  if [ -z "$mode" ] || [ $((8#$mode & 0444)) -eq 0 ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      --arg reason "registered secondmate table is unreadable" \
      '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    f=$1
    max_lines=$2
    max_bytes=$3
    max_records=$4
    path=$5
    observed=$6
    parse_filter=$7
    output_filter=$8
    content=$(LC_ALL=C head -c "$((max_bytes + 1))" "$f" || exit 3; printf "\036") || exit 3
    content=${content%$'\036'}
    bytes=$(printf "%s" "$content" | LC_ALL=C wc -c | tr -d " ")
    byte_truncated=false
    if [ "$bytes" -gt "$max_bytes" ]; then
      byte_truncated=true
      content=$(printf "%s" "$content" | LC_ALL=C head -c "$max_bytes")
      complete=${content%$'\n'*}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines=0
    fi
    line_truncated=false
    if [ "$lines" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C head -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | jq -Rn "$parse_filter") || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    records_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then records_truncated=true; fi
    printf "%s" "$records" | jq \
      --arg path "$path" --arg observed "$observed" \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson records_truncated "$records_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" "$output_filter"
BASH
  )
  parse_filter=$(cat <<'JQ'
      [ inputs
        | select(startswith("- "))
        | (capture("^- (?<id>[^[:space:]]+)")?) as $id
        | select($id != null)
        | ([capture("^.*\\(host:[[:space:]]*(?<host>[^;)]*);[[:space:]]*root:[[:space:]]*(?<root>[^;)]*);[[:space:]]*home:[[:space:]]*(?<home>[^;)]*);[[:space:]]*scope:[[:space:]]*.*;[[:space:]]*projects:[[:space:]]*[^;)]*;[[:space:]]*added[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\\)[[:space:]]*$")?][0] // null) as $remote
        | ([capture("^.*\\(home:[[:space:]]*(?<home>[^;)]*);[[:space:]]*scope:[[:space:]]*.*;[[:space:]]*projects:[[:space:]]*[^;)]*;[[:space:]]*added[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\\)[[:space:]]*$")?][0] // null) as $local
        | ($local // $remote) as $route
        | (($local == null) and ($remote != null)) as $is_remote
        | {id:$id.id,home:($route.home // null),host:(if $is_remote then $remote.host else null end),root:(if $is_remote then $remote.root else null end),
           remote:$is_remote,registered:true,
           registry_error:(if $route == null or ($route.home | length) == 0 then "registry entry has no home" else null end)} ]
      | group_by(.id)
      | map(if length > 1 then .[0] + {registry_error:"duplicate secondmate id in registry"} else .[0] end)
JQ
  )
  output_filter=$(cat <<'JQ'
      {present:true,available:true,reason:null,provenance:"registered-table",path:$path,
       freshness:{status:"fresh",observed_at:$observed},
       records:(if length > $max_records then .[:$max_records] else . end),
       input_truncated:($byte_truncated or $line_truncated),records_truncated:$records_truncated,
       complete:(($byte_truncated or $line_truncated or $records_truncated) | not),
       reasons:[
         (if $byte_truncated then "byte_limit" else empty end),
         (if $line_truncated then "line_limit" else empty end),
         (if $records_truncated then "record_limit" else empty end)
       ],lines_in_window:$lines_in_window,records_in_window:$records_in_window}
JQ
  )
  out=$(run_timed "$FM_SNAPSHOT_REGISTRY_TIMEOUT" bash -c "$script" \
    fm-secondmate-registry "$reg" "$FM_SNAPSHOT_REGISTRY_LINES" \
    "$FM_SNAPSHOT_REGISTRY_BYTES" "$FM_SNAPSHOT_REGISTRY_RECORDS" "$reg" "$SNAPSHOT_NOW" \
    "$parse_filter" "$output_filter" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    .available == true and (.records | type) == "array"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="registered secondmate table read timed out" \
    || reason="registered secondmate table is unreadable"
  jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
    '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

bounded_parent_activities_json() {  # <status-file>
  local f=$1 out rc reason script
  if [ ! -f "$f" ]; then
    jq -n '{records:[],available:true,input_truncated:false,retained_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    classify=$1
    f=$2
    max_lines=$3
    max_bytes=$4
    max_records=$5
    stat_style=$6
    . "$classify"
    if [ "$stat_style" = bsd ]; then
      size=$(stat -f "%z" "$f" 2>/dev/null) || exit 3
    else
      size=$(stat -c "%s" "$f" 2>/dev/null) || exit 3
    fi
    content=$(LC_ALL=C tail -c "$max_bytes" "$f") || exit 3
    byte_truncated=false
    if [ "$size" -gt "$max_bytes" ]; then
      byte_truncated=true
      complete=${content#*$'\n'}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines_in_chunk=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines_in_chunk=0
    fi
    line_truncated=false
    if [ "$lines_in_chunk" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C tail -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | status_open_activities - \
      | jq -R -s '[splits("\n") | select(length > 0)
          | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
          | select(. != null)]') || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    retained_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then retained_truncated=true; fi
    printf "%s" "$records" | jq \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson retained_truncated "$retained_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" '
        {records:(if length > $max_records then .[-$max_records:] else . end),
         available:true,
         input_truncated:($byte_truncated or $line_truncated),
         retained_truncated:$retained_truncated,
         reasons:[
           (if $byte_truncated then "byte_limit" else empty end),
           (if $line_truncated then "line_limit" else empty end),
           (if $retained_truncated then "activity_limit" else empty end)
         ],
         lines_in_window:$lines_in_window,
         records_in_window:$records_in_window}'
BASH
  )
  out=$(run_timed "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT" bash -c "$script" \
    fm-parent-activities "$SCRIPT_DIR/fm-classify-lib.sh" "$f" \
    "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES" "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES" \
    "$FM_SNAPSHOT_PARENT_ACTIVITIES" "$SNAPSHOT_STAT_STYLE" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    (.records | type) == "array" and (.available | type) == "boolean"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="timeout" || reason="read_failed"
  jq -n --arg reason "$reason" \
    '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

terminal_evidence_json() {  # <parent-task-json> <event-note> <evidence-contradicts>
  local task=$1 note=$2 evidence_contradicts=$3 backend target exists expected out rc clean bytes lines seen=false contradiction=false reason='' remote_host
  backend=$(printf '%s' "$task" | jq -r '.backend // ""')
  target=$(printf '%s' "$task" | jq -r '.endpoint.target // ""')
  exists=$(printf '%s' "$task" | jq -r '.endpoint.exists // "unknown"')
  remote_host=$(printf '%s' "$task" | jq -r '.remote.host // ""')
  if [ -n "$remote_host" ]; then
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "remote terminal evidence is not collected by the primary" \
      '{provenance:"remote-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  expected=$(printf '%s' "$task" | jq -r '"fm-" + (.id // "")')
  if [ -z "$target" ] || [ "$exists" = false ]; then
    [ "$exists" = false ] && reason="recorded endpoint is absent" || reason="no recorded endpoint"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  # shellcheck disable=SC2016 # Positional parameters expand inside the child bash, not here.
  out=$(run_timed "$FM_SNAPSHOT_TERMINAL_TIMEOUT" bash -c \
    '. "$1"; fm_backend_capture "$2" "$3" "$4" "$5" | LC_ALL=C head -c "$6"; rc=${PIPESTATUS[0]}; [ "$rc" -eq 141 ] && rc=0; exit "$rc"' \
    fm-terminal-capture "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$FM_SNAPSHOT_TERMINAL_LINES" "$expected" "$FM_SNAPSHOT_TERMINAL_BYTES" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 124 ] && reason="terminal capture timed out" || reason="terminal capture unavailable"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  clean=$(printf '%s' "$out" | tail -n "$FM_SNAPSHOT_TERMINAL_LINES" | LC_ALL=C head -c "$FM_SNAPSHOT_TERMINAL_BYTES")
  if command -v perl >/dev/null 2>&1; then
    clean=$(printf '%s' "$clean" | perl -pe 's/\e\[[0-?]*[ -\/]*[@-~]//g; s/[^\x09\x0A\x0D\x20-\x7E]//g')
  else
    clean=$(printf '%s' "$clean" | LC_ALL=C tr -cd '\11\12\15\40-\176')
  fi
  bytes=$(printf '%s' "$clean" | LC_ALL=C wc -c | tr -d ' ')
  if [ -n "$clean" ]; then
    lines=$(printf '%s\n' "$clean" | wc -l | tr -d ' ')
  else
    lines=0
  fi
  if [ -n "$note" ]; then
    case "$clean" in *"$note"*) seen=true ;; esac
  fi
  if [ "$seen" = true ] && [ "$evidence_contradicts" = true ]; then contradiction=true; fi
  jq -n \
    --arg observed "$SNAPSHOT_NOW" \
    --argjson lines "$lines" \
    --argjson bytes "$bytes" \
    --argjson seen "$seen" \
    --argjson contradiction "$contradiction" \
    '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:true,observed_at:$observed,freshness:"fresh",reason:null,lines:$lines,bytes:$bytes,event_note_seen:$seen,contradiction:$contradiction}'
}

parent_evidence_reconciliation_json() {  # <summary-json> <activities-json> <decisions-json>
  jq -n \
    --slurpfile summary_doc <(printf '%s' "$1") \
    --argjson activities "$2" --argjson decisions "$3" '
    def doc($v): ($v[0] // error("fm-fleet-snapshot: empty jq payload"));
    def keyed: . != null and . != "" and . != "default";
    def result($e; $matches; $complete; $surface):
      $e + {
        verdict:(if ($e.key | keyed | not) then "inconclusive"
                 elif ($matches | length) > 0 then "corroborates"
                 elif $complete then "contradicts"
                 else "inconclusive" end),
        compared_to:$surface,
        matched:(if ($e.key | keyed) then ($matches[0] // null) else null end)
      };
    doc($summary_doc) as $summary
    | ([ $activities[] as $e
       | if $e.verb == "working" then
           ([ $summary.active_children[]
              | select(if ($e.key | keyed) then .id == $e.key else true end)
              | {surface:"active_children",id,key:null,verb:"working"}]) as $matches
           | result($e; $matches;
               $summary.counts.active_children == ($summary.active_children | length);
               "active_children")
         elif $e.verb == "paused" then
           ([ $summary.holds[]
              | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
              | {surface:"holds",id,key:(.blocked_by // null),verb:"paused"}]) as $matches
           | result($e; $matches;
               $summary.counts.holds == ($summary.holds | length);
               "holds")
         else
           $e + {verdict:"inconclusive",compared_to:null,matched:null}
         end ]) as $activity_results
    | ([ $decisions[] as $e
         | if $e.verb == "needs-decision" then
             ([ $summary.decisions_open[]
                | select(.verb == "needs-decision")
                | select(if ($e.key | keyed) then .key == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]) as $matches
             | result($e; $matches;
                 $summary.counts.decisions_open == ($summary.decisions_open | length);
                 "decisions_open")
           elif $e.verb == "blocked" then
             ([ $summary.decisions_open[]
                | select(.verb == "blocked")
                | select(if ($e.key | keyed) then .key == $e.key or .id == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]
              + [ $summary.holds[]
                  | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
                  | {surface:"holds",id,key:(.blocked_by // null),verb:"blocked"}]) as $matches
             | result($e; $matches;
                 ($summary.counts.decisions_open == ($summary.decisions_open | length)
                  and $summary.counts.holds == ($summary.holds | length));
                 "decisions_open_or_holds")
           else
             $e + {verdict:"inconclusive",compared_to:null,matched:null}
           end ]) as $decision_results
    | {provenance:"parent-status-keyed-fold",trust:"untrusted-supplement",
       activities:$activity_results,decisions:$decision_results,
       contradiction:any(($activity_results + $decision_results)[]; .verdict == "contradicts"),
       inconclusive:any(($activity_results + $decision_results)[]; .verdict == "inconclusive")}'
}

secondmate_current_json() {  # <parent-tasks-json>
  local tasks=$1 registry union rows total_registered total shown truncated
  local row id home host remote registered registry_error task status_file event_raw event_note event_epoch event_age
  local activity_scan activities decisions reconciliation provenance freshness reason summary summary_rc summary_bytes summary_valid summary_reason summary_invalidity state current_reason terminal terminal_contradiction contradiction
  local records='[]' seen_homes=''
  registry=$(registry_secondmates_json) || return 1
  union=$(jq -n \
    --slurpfile registry_doc <(printf '%s' "$registry") \
    --slurpfile tasks_doc <(printf '%s' "$tasks") '
    def doc($v): ($v[0] // error("fm-fleet-snapshot: empty jq payload"));
    doc($registry_doc) as $registry
    | doc($tasks_doc) as $tasks
    | ($registry.records // []) as $registered
    | (($registered | map(.id)) // []) as $registered_ids
    | ([ $registered[] as $r
         | $r + {parent_task:([$tasks[] | select(.id == $r.id)][0] // null)} ]
       + [ $tasks[] | select(.kind == "secondmate") as $t
           | select(($registered_ids | index($t.id)) == null)
           | {id:$t.id,home:($t.paths.home.path // null),
              registered:(if $registry.complete == true then false else null end),
              registry_error:(if $registry.complete == true
                              then "secondmate metadata is not registered"
                              else "secondmate registration is unknown because the registry read is incomplete or unavailable" end),
              parent_task:$t} ])
    | sort_by(.id)
    | {registry:$registry,records:.}') || return 1
  total_registered=$(printf '%s' "$union" | jq '[.records[] | select(.registered)] | length')
  total=$(printf '%s' "$union" | jq '.records | length')
  rows=$(printf '%s' "$union" | jq -c --argjson cap "$FM_SNAPSHOT_SECONDMATES" '(if $cap == 0 then .records else .records[:$cap] end)[]')
  shown=$(printf '%s\n' "$rows" | grep -c . || true)
  truncated=$((total - shown))

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id')
    home=$(printf '%s' "$row" | jq -r '.home // ""')
    host=$(printf '%s' "$row" | jq -r '.host // ""')
    remote=$(printf '%s' "$row" | jq -r '.remote // false')
    registered=$(printf '%s' "$row" | jq -r '.registered')
    registry_error=$(printf '%s' "$row" | jq -r '.registry_error // ""')
    task=$(printf '%s' "$row" | jq -c '.parent_task // {}')
    status_file=$(printf '%s' "$task" | jq -r '.paths.status_log.path // ""')
    event_raw=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.raw // ""')
    event_note=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.note // ""')
    activity_scan=$(bounded_parent_activities_json "$status_file")
    activities=$(printf '%s' "$activity_scan" | jq -c '.records')
    decisions=$(printf '%s' "$task" | jq -c '.hints.open_decisions // []')
    event_epoch=$(file_mtime_epoch "$status_file")
    event_age=null
    if [ -n "$event_epoch" ]; then
      event_age=$((SNAPSHOT_EPOCH - event_epoch))
      [ "$event_age" -lt 0 ] && event_age=0
    fi

    reason=$registry_error
    summary='{}'
    summary_valid=false
    if [ -z "$reason" ] && [ -z "$home" ]; then reason="no recorded secondmate home"; fi
    if [ -z "$reason" ]; then
      case "$home" in
        /*) : ;;
        *) reason="invalid home: registered path is not absolute" ;;
      esac
    fi
    if [ -z "$reason" ]; then
      if [ "$remote" = true ]; then
        [ -n "$host" ] || reason="invalid remote route: missing SSH host"
        case " $seen_homes " in
          *" $host:$home "*) reason="invalid home: duplicate resolved remote route" ;;
          *) seen_homes="$seen_homes $host:$home" ;;
        esac
      elif ! validate_secondmate_home "$id" "$home" 2>/dev/null; then
        reason="invalid home: $VALIDATION_ERROR"
      else
        home=$VALIDATED_HOME
        case " $seen_homes " in
          *" local:$home "*) reason="invalid home: duplicate resolved home route" ;;
          *) seen_homes="$seen_homes local:$home" ;;
        esac
      fi
    fi
    if [ -z "$reason" ]; then
      if [ "$remote" = true ]; then
        summary=$(run_timed "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" \
          "$SCRIPT_DIR/fm-on.sh" "$id" fm-fleet-snapshot.sh --secondmate-home-summary < /dev/null 2>/dev/null)
        summary_rc=$?
      else
        summary=$(run_timed "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" env \
          FM_ROOT_OVERRIDE="$FM_ROOT" \
          FM_HOME="$home" \
          FM_STATE_OVERRIDE="$home/state" \
          FM_DATA_OVERRIDE="$home/data" \
          FM_CONFIG_OVERRIDE="$home/config" \
          FM_PROJECTS_OVERRIDE="$home/projects" \
          FM_SNAPSHOT_NOW="$SNAPSHOT_NOW" \
          FM_SNAPSHOT_NOW_EPOCH="$SNAPSHOT_EPOCH" \
          FM_SNAPSHOT_SECONDMATE_CHILDREN="$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
          FM_SNAPSHOT_SECONDMATE_QUEUED="$FM_SNAPSHOT_SECONDMATE_QUEUED" \
          FM_SNAPSHOT_SECONDMATE_DECISIONS="$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
          FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME="$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" \
          "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary 2>/dev/null)
        summary_rc=$?
      fi
      if [ "$summary_rc" -ne 0 ]; then
        [ "$summary_rc" -eq 124 ] && reason="structured home snapshot timed out" || reason="structured home snapshot failed"
      else
        summary_bytes=$(printf '%s' "$summary" | LC_ALL=C wc -c | tr -d ' ')
        if [ "$summary_bytes" -gt "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES" ]; then
          reason="structured home snapshot exceeded byte limit"
        elif ! printf '%s' "$summary" | jq -e --arg home "$home" --arg generated "$SNAPSHOT_NOW" --argjson remote "$remote" '
          .schema == "fm-secondmate-home-summary.v1" and .home == $home
          and (($remote == true) or .generated == $generated)
          and (.valid | type) == "boolean" and (.state | type) == "string"
          and (.invalidity | type) == "object" and (.invalidity.ids | type) == "array"
          and (.active_children | type) == "array" and (.decisions_open | type) == "array"
          and (.holds | type) == "array" and (.queued | type) == "array"
          and (.landed | type) == "array" and (.endpoints | type) == "array"
          and (.counts | type) == "object" and (.omitted | type) == "array"
        ' >/dev/null 2>&1; then
          reason="structured home snapshot was malformed or stale"
        else
          summary_valid=$(printf '%s' "$summary" | jq -r '.valid')
          if [ "$summary_valid" != true ]; then
            summary_reason=$(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')
            summary_invalidity=$(printf '%s' "$summary" | jq -r '.invalidity.kind // "unknown"')
            if [ "$summary_invalidity" != child_current_unavailable ]; then
              reason="structured home state invalid: $summary_reason"
            fi
          fi
        fi
      fi
    fi

    if [ -z "$reason" ]; then
      state=$(printf '%s' "$summary" | jq -r '.state')
      current_reason=
      if [ "$summary_valid" != true ]; then
        current_reason="structured home state invalid: $(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')"
      fi
      reconciliation=$(parent_evidence_reconciliation_json "$summary" "$activities" "$decisions")
      contradiction=$(printf '%s' "$reconciliation" | jq -r '.contradiction')
      terminal_contradiction=$(printf '%s' "$reconciliation" | jq -r --arg note "$event_note" '
        any(.activities[]; .verdict == "contradicts" and .summary == $note)')
      if [ "$terminal_contradiction" = true ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" true)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no useful contradiction check",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      if printf '%s' "$terminal" | jq -e '.contradiction == true' >/dev/null; then contradiction=true; fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg host "$host" --argjson remote "$remote" --arg state "$state" --arg current_reason "$current_reason" --arg observed "$SNAPSHOT_NOW" \
        --argjson registered "$registered" --argjson summary_valid "$summary_valid" --argjson decisions "$decisions" \
        --slurpfile summary_doc <(printf '%s' "$summary") \
        --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson reconciliation "$reconciliation" --argjson terminal "$terminal" --argjson contradiction "$contradiction" \
        --arg event_raw "$event_raw" --arg event_note "$event_note" --argjson event_age "$event_age" '
        def doc($v): ($v[0] // error("fm-fleet-snapshot: empty jq payload"));
        doc($summary_doc) as $summary
        | {id:$id,home:$home,host:($host | if . == "" then null else . end),remote:$remote,registered:$registered,
         current:{state:$state,reason:($current_reason | if . == "" then null else . end)},invalidity:$summary.invalidity,
         provenance:{selected:"structured-home",structured_home:$home,summary_valid:$summary_valid,
           trust:(if $summary_valid then "complete" else "partial-structured" end),parent_event_role:"historical-only"},
         freshness:{status:"fresh",observed_at:$observed,age_seconds:0},
         active_children:$summary.active_children,
         decisions_open:$summary.decisions_open,holds:$summary.holds,queued:$summary.queued,
         landed:$summary.landed,endpoints:$summary.endpoints,counts:$summary.counts,omitted:$summary.omitted,
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan,reconciliation:$reconciliation},
         terminal_evidence:$terminal,contradiction:$contradiction}')
    else
      if [ -n "$event_raw" ]; then
        provenance='parent-event-fallback'
        freshness=historical-event
      else
        provenance=unknown
        freshness=unknown
      fi
      if [ -n "$event_raw" ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" false)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no parent event to compare",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg host "$host" --argjson remote "$remote" --arg reason "$reason" --arg observed "$SNAPSHOT_NOW" \
        --arg provenance "$provenance" --arg freshness "$freshness" --arg event_raw "$event_raw" --arg event_note "$event_note" \
        --argjson registered "$registered" --argjson event_age "$event_age" --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson decisions "$decisions" --argjson terminal "$terminal" '
        {id:$id,home:($home | if . == "" then null else . end),host:($host | if . == "" then null else . end),remote:$remote,registered:$registered,
         current:{state:"unknown",reason:$reason},invalidity:null,
         provenance:{selected:$provenance,structured_home:($home | if . == "" then null else . end),parent_event_role:"fallback-only-not-current"},
         freshness:{status:$freshness,observed_at:$observed,age_seconds:$event_age},
         active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[],
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan},
         terminal_evidence:$terminal,contradiction:false}')
    fi
    records=$(jq -n \
      --slurpfile records_doc <(printf '%s' "$records") \
      --slurpfile record_doc <(printf '%s' "$record") '
      def doc($v): ($v[0] // error("fm-fleet-snapshot: empty jq payload"));
      doc($records_doc) + [doc($record_doc)]')
  done <<EOF
$rows
EOF
  jq -n \
    --slurpfile registry_doc <(printf '%s' "$union" | jq '.registry') \
    --slurpfile records_doc <(printf '%s' "$records") \
    --argjson total_registered "$total_registered" \
    --argjson total "$total" \
    --argjson shown "$shown" \
    --argjson truncated "$truncated" \
    'def doc($v): ($v[0] // error("fm-fleet-snapshot: empty jq payload"));
     doc($registry_doc) as $registry
     | doc($records_doc) as $records
     | {registry:$registry,records:$records,total_registered:$total_registered,total:$total,shown:$shown,truncated:$truncated}'
}

secondmate_landed_from_current_json() {  # <secondmate-current-json>
  jq -n --slurpfile current_doc <(printf '%s' "$1") '
    def doc($v): ($v[0] // error("fm-fleet-snapshot: empty jq payload"));
    doc($current_doc) as $current
    | {records:[ $current.records[]
      | select(.provenance.selected == "structured-home") as $mate
      | $mate.landed[]
      | . + {home:$mate.home,home_id:$mate.id}],
     truncated:[ $current.records[]
       | select(.provenance.selected == "structured-home" and (.counts.landed > (.landed | length)))
       | .home],
     unreadable:[ $current.records[]
       | select(.current.state == "unknown" and .provenance.selected != "structured-home")
       | .home // ("<" + .id + ": unavailable>")],
     partial:[ $current.records[]
       | select(.current.state == "unknown" and .provenance.selected == "structured-home")
       | .home // ("<" + .id + ": partial>")]}
    | .records |= sort_by([(.completion.date // ""), .id]) | .records |= reverse'
}

scout_report_lines() {
  local report id
  if [ ! -d "$DATA" ]; then
    jq -n '[]'
    return 0
  fi
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
    | sort \
    | while IFS= read -r report; do
      id=$(basename "$(dirname "$report")")
      jq -n --arg id "$id" --arg path "$report" '{id:$id,path:$path}'
    done \
    | jq -s 'sort_by(.id)'
}

# Watcher liveness and away mode, from the same beacon and grace window
# bin/fm-guard.sh and the supervision scripts use, so a renderer never invents a
# second staleness rule.
supervision_json() {
  local beat="$STATE/.last-watcher-beat" afk="$STATE/.afk"
  local grace quiet beat_at='' beat_age='' afk_at='' afk_age=''
  local beat_present=0 afk_present=0 stale=1
  # bin/fm-supervision-lib.sh owns the grace window; the beacon is stale once its
  # age reaches it, measured against this snapshot's own observation time so the
  # reported age and the reported verdict always agree.
  grace=$(fm_sup_grace_seconds)
  # The same library owns how long a live worker may stay quiet before that
  # quiet is worth inspecting. Publishing it here is what lets a renderer judge
  # a task's activity on supervision's own window instead of a constant of its
  # own, exactly as grace_seconds already does for the beacon.
  quiet=$(fm_sup_busy_turn_max_seconds)
  if [ -e "$beat" ]; then
    beat_present=1
    beat_at=$(fm_outcome_path_iso "$beat")
    beat_age=$(path_age_seconds "$beat")
    [ -n "$beat_age" ] && [ "$beat_age" -lt "$grace" ] && stale=0
  fi
  if [ -e "$afk" ]; then
    afk_present=1
    afk_at=$(fm_outcome_path_iso "$afk")
    afk_age=$(path_age_seconds "$afk")
  fi
  jq -n \
    --arg beat_path "$beat" \
    --arg beat_at "$beat_at" \
    --arg beat_age "$beat_age" \
    --arg afk_path "$afk" \
    --arg afk_at "$afk_at" \
    --arg afk_age "$afk_age" \
    --argjson beat_present "$(bool_json "$beat_present")" \
    --argjson afk_present "$(bool_json "$afk_present")" \
    --argjson stale "$(bool_json "$stale")" \
    --argjson grace "$grace" \
    --argjson quiet "$quiet" \
    'def num($v): if $v == "" then null else ($v | tonumber) end;
     def blank($v): if $v == "" then null else $v end;
     (num($beat_age)) as $age
     | {watcher:{beacon_path:$beat_path,
                 present:$beat_present,
                 observed_at:blank($beat_at),
                 age_seconds:$age,
                 grace_seconds:$grace,
                 quiet_allowance_seconds:$quiet,
                 stale:$stale},
        afk:{path:$afk_path,
             active:$afk_present,
             since:blank($afk_at),
             age_seconds:num($afk_age)}}'
}

BACKLOG_JSON=$(backlog_json) || { echo "fm-fleet-snapshot: backlog read failed" >&2; exit 1; }
TASKS_JSON=$(task_json_lines) || { echo "fm-fleet-snapshot: task snapshot failed" >&2; exit 1; }

if [ "$OUTPUT_MODE" = secondmate-home-summary ]; then
  secondmate_home_summary_json "$BACKLOG_JSON" "$TASKS_JSON" \
    || { echo "fm-fleet-snapshot: secondmate home summary failed" >&2; exit 1; }
  exit 0
fi

SCOUT_REPORTS_JSON=$(scout_report_lines)
MAIN_INVENTORY_JSON=$(main_inventory_json "$BACKLOG_JSON" "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: main inventory summary failed" >&2; exit 1; }
SECONDMATE_CURRENT_JSON=$(secondmate_current_json "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: registered secondmate aggregation failed" >&2; exit 1; }
SECONDMATE_LANDED_JSON=$(secondmate_landed_from_current_json "$SECONDMATE_CURRENT_JSON") \
  || { echo "fm-fleet-snapshot: secondmate landed projection failed" >&2; exit 1; }
SUPERVISION_JSON=$(supervision_json) \
  || { echo "fm-fleet-snapshot: supervision summary failed" >&2; exit 1; }
HISTORY_JSON=$(fm_outcome_history_json "$DATA" "$FM_SNAPSHOT_HISTORY") \
  || { echo "fm-fleet-snapshot: durable history read failed" >&2; exit 1; }

jq -n \
  --arg generated "$SNAPSHOT_NOW" \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  --slurpfile backlog_doc <(printf '%s' "$BACKLOG_JSON") \
  --slurpfile tasks_doc <(printf '%s' "$TASKS_JSON") \
  --slurpfile main_inventory_doc <(printf '%s' "$MAIN_INVENTORY_JSON") \
  --slurpfile scout_reports_doc <(printf '%s' "$SCOUT_REPORTS_JSON") \
  --slurpfile secondmate_current_doc <(printf '%s' "$SECONDMATE_CURRENT_JSON") \
  --slurpfile secondmate_landed_doc <(printf '%s' "$SECONDMATE_LANDED_JSON") \
  --slurpfile supervision_doc <(printf '%s' "$SUPERVISION_JSON") \
  --slurpfile history_doc <(printf '%s' "$HISTORY_JSON") \
  'def doc($v): ($v[0] // error("fm-fleet-snapshot: empty jq payload"));
   doc($backlog_doc) as $backlog
   | doc($tasks_doc) as $tasks
   | doc($main_inventory_doc) as $main_inventory
   | doc($scout_reports_doc) as $scout_reports
   | doc($secondmate_current_doc) as $secondmate_current
   | doc($secondmate_landed_doc) as $secondmate_landed
   | doc($supervision_doc) as $supervision
   | doc($history_doc) as $history
   | def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v1",
     generated:$generated,
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:$backlog,
     tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
     main_inventory:$main_inventory,
     scout_reports:($scout_reports | map(. + {kind:report_kind(.id)})),
     secondmate_current:$secondmate_current,
     secondmate_landed:$secondmate_landed,
     card_precedence:["needs_decision","blocked","parked","failed","review",
                      "done","waiting","active","secondmate","idle"],
     supervision:$supervision,
     history:$history,
     secondmate_guidance:{
       note:"For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority."
     }
   }'
