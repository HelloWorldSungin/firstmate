#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and first-sighting stale paths are
# absorb-only-when-provably-working: a wake is absorbed only when the crew shows
# POSITIVE evidence it is still working (a current or bounded-degraded
# no-mistakes run step, or a backend busy signal), and surfaced otherwise, so a
# crew that finishes (or stops and waits) without a current working signal is
# never silently swallowed. A declared external-wait pause is the separate idle
# absorb case and re-surfaces only on its long bounded cadence. A repaint-only
# repeat of an already-surfaced keyed open-decision set is also absorbed, but a
# confidently dead parked agent still enters the wedge timer. The initial no-verb
# status signal still surfaces in normal mode, while a declared wait, either a
# paused: external wait or verified captain-held transfer, uses a long bounded
# re-surface cadence.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          current or bounded-degraded run step, or a busy pane,
#                          outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge. An unchanged keyed
#                          open-decision set is deduped across pane repaint, unless
#                          the backend confidently reports the parked agent dead and
#                          routes it through the wedge timer. Only when none of these
#                          absorb classes applies does the log's last line decide,
#                          and a captain-held recheck names who owns the wait:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason - UNLESS its validation run is
#                          demonstrably progressing, which holds the escalation
#                          and restarts the timer, since a crew parked on a
#                          moving run is quiet by design. That hold needs
#                          positive evidence: no run, a run parked at a gate, a
#                          stranded step, an unreadable status, or a confidently
#                          dead agent cannot earn it. For a surviving declared
#                          wait, the no-evidence class instead returns to that
#                          wait's recheck cadence; a stranded run or dead agent
#                          still escalates, and the former names the stopped step.
#                          Consecutive holds are capped
#                          (FM_RUN_PROGRESS_HOLD_MAX, below), past which the
#                          pane escalates however healthy its run looks. At
#                          FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active. A pane whose own task
#                          worktree was written during the quiet window is
#                          deferred rather than escalated (wedge_defer_writing),
#                          because files appearing there are liveness the pane and
#                          the run step cannot show; that deferral still
#                          re-surfaces once per PAUSE_RESURFACE_SECS, and a pane
#                          that writes nothing keeps the unchanged schedule.
#                          A genuinely busy pane
#                          (window_is_busy true) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS with no turn-boundary wake
#                          (state/<id>.turn-ended, or the spawn record before any
#                          such wake arrives). Past that bound, a declared
#                          external wait or verified captain-held transfer uses
#                          the long pause recheck cadence; every other pane goes
#                          through the same wedge timer and surfaces with the
#                          identical "stale: ..." reason, escalation count, and
#                          demand-deep-inspection marker, for human inspection
#                          only - never an automatic interrupt, signal, or
#                          restart of the worker or its tool process.
#   stale: <window> (unread firstmate instruction: ...)
#                          the steering-inbox ladder spent its delivery-attempt
#                          budget on an idle pane without an acknowledgement
#   stale: <window> (steering-inbox ladder bookkeeping unwritable: ...)
#                          an unhandled record's ladder cannot advance; quiet
#                          successful attempts never wake firstmate
#                          (bin/fm-task-inbox-lib.sh owns the ladder policy)
#   check: <script>: <out> authenticated check output, always actionable
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
#   check: inactive-outcome bounded poll-loop reconciliation found a suspicious
#                          inactive terminal outcome that still lacks its durable
#                          upstream receipt
#   check: secondmate wake-loop stalled: mate=<id> row=<seq> age=<seconds>s
#                          the oldest valid row in an endpoint-recorded local
#                          secondmate home's durable wake queue exceeded
#                          FM_SECONDMATE_WAKE_STALL_SECS; observation is read-only
#                          and one parent receipt suppresses repeats for that row
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# The shared transition owner is a canonical lint root itself. Stop duplicate
# source-graph expansion here: following its backend graph from this large
# runtime can exceed the bounded CI lint worker while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-push-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Single owner of durable merge-outcome publication, shared with
# bin/fm-pr-merge.sh so self and poll origins use the same role-routed outcome.
# The watcher still owns immediate delivery of its actionable poll result and
# poll retirement.
# This library is a canonical lint root in its own right, and it reaches the
# wake queue, PR identity, and secondmate parent libraries. Keep it an analysis
# boundary here for the same reason as the transition and inbox owners above and
# below: following its graph from this large runtime exceeds the bounded CI lint
# worker while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# fm_sup_busy_turn_max_seconds: the shared tolerated-quiet window below.
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# Steering-inbox loss detection: bin/fm-task-inbox-lib.sh owns the record,
# doorbell, and re-ring ladder contracts; this watcher only supplies the busy
# gate and the wake emission (inbox_steer_check below).
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_DOWNTIME_MARKER="$STATE/.watcher-down"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
# The size:mtime signal signature and .seen-* marker format are owned by
# bin/fm-wake-lib.sh (fm_wake_signal_sig, fm_wake_signal_seen_path), shared
# with the drain's annotation staleness check and this home's own bookkeeping
# writers' guarded self-announced append.

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy state is decided by the semantic contract in bin/fm-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only).
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / first-sighting stale path is absorb-only-when-provably-working: such a wake
# is absorbed ONLY while the crew shows positive evidence it is still working
# (a current or bounded-degraded no-mistakes run step, or a busy pane, via
# crew_is_provably_working over fm-crew-state.sh); a crew that stopped its turn
# with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a
# first-sighting stale pane whose crew is not provably working, a
# provably-working stale past the threshold, or anything unknown) is written to
# the durable queue and exits, which is what wakes the LLM through the
# background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale or dead parked-decision repeat escalates as a possible wedge
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go with no turn-boundary wake: once its task's
# state/<id>.turn-ended marker (or, before any such wake arrives, the task's
# spawn record) is this old, busy_turn_over_age routes the pane through
# busy_turn_bound_check, which hands a crossed bound to the same
# STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale - so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only, never an
# automatic interrupt, signal, or restart - unless the crew declared the wait
# itself, which takes the long pause cadence instead. A turn-boundary wake touches
# turn-ended and resets the age. Set generously above any legitimate interval
# between such wakes, including long tool calls, builds, or test runs.
# bin/fm-supervision-lib.sh owns the window and its FM_BUSY_TURN_MAX_SECS
# override, because the dashboard's Task activity signal reads the same one out
# of the fleet snapshot rather than inventing a second tolerance for quiet.
BUSY_TURN_MAX_SECS=$(fm_sup_busy_turn_max_seconds)
# A local secondmate's foreign queue is checked on every poll, but only after this
# bounded age can it produce a parent notification.
SECONDMATE_WAKE_STALL_SECS=${FM_SECONDMATE_WAKE_STALL_SECS:-60}
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated, whether or not its agent is still
# alive at its prompt (pause_state_class owns why).
# A captain-held crew, which declared nothing itself, uses the same bounded
# cadence once its agent has confidently exited, while a live or ambiguously read
# agent still surfaces once.
# These cases re-surface once for a recheck every pause_resurface_window (the
# shared owner in fm-classify-lib.sh, which resolves FM_PAUSE_RESURFACE_SECS and
# widens the window per unchanged recheck) - far longer than the wedge threshold,
# but finite so a forgotten hold cannot rot invisibly.
# Authoritative current state outranks the declared wait, so a crew that declared
# one and then STARTED a validation run is tracked by the wedge timer instead. The
# declaration is not discarded there: it is what wedge_timer_check falls back to
# when the run yields no progress evidence either way, so following the brief and
# declaring the wait can never cost a crew an alarm it would not otherwise get.
PAUSE_RESURFACE_SECS=$(pause_resurface_window 0)
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

hash_pane() {
  _fm_surface_digest
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working, through
# the semantic busy-state contract (bin/fm-busy-lib.sh). Only an exact busy
# verdict returns 0: idle, unknown, and dead all return 1, so a converted
# adapter whose semantic state is missing, malformed, stale, or unverified is
# treated as not-provably-working and surfaces rather than being absorbed.
# <tail40> is the same bounded capture already read for hashing and is
# consumed only by the Grok-scoped fallback inside the contract.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 task meta verdict
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -n "$task" ] && [ -f "$meta" ]; then
    verdict=$(fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  else
    verdict=$(fm_busy_classify "$(window_backend "$w")" "$w" "$(window_harness "$w")" \
      "${task:-unknown}" "$STATE" "$tail40")
  fi
  [ "${verdict%% *}" = busy ]
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_harness() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

# maybe_native_turnend: the crew-only, herdr-only cursor/agy turn-end wake path.
# Those CLIs install no turn-end hook and write no status file, and the shared
# transition policy deliberately DEFERS their native idle/done (it blips between
# tool calls for the general fleet). So the poll loop reads their NATIVE agent
# state and, via the debounced native-identity-gated decision in
# fm-transition-lib.sh, touches state/<id>.turn-ended as a wake notification,
# which scan_signals already turns into a wake without treating it as current
# state.
# Gated strictly to a cursor/agy herdr
# crew window, so every other task's behavior is byte-unchanged. The per-pane
# ".nativeturnend-<key>" file carries the debounce state ("<status>|<signaled>");
# fm-teardown removes it with the rest of the task's watcher state.
maybe_native_turnend() {  # <window> <task> <key>
  local w=$1 task=$2 key=$3 backend harness native_pair native_identity status prev newstate tf sfile
  [ -n "$task" ] || return 0
  backend=$(window_backend "$w")
  [ "$backend" = herdr ] || return 0
  harness=$(window_harness "$w")
  case "$harness" in
    cursor|agy) ;;
    *) return 0 ;;
  esac
  fm_backend_source herdr || return 0
  fm_backend_herdr_parse_target "$w" || return 0
  native_pair=$(fm_backend_herdr_agent_identity_raw \
    "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" 2>/dev/null || true)
  native_identity=${native_pair%%$'\t'*}
  case "$native_pair" in
    *$'\t'*) status=${native_pair#*$'\t'} ;;
    *) status=unknown ;;
  esac
  [ -n "$status" ] || status=unknown
  sfile="$STATE/.nativeturnend-$key"
  prev=$(cat "$sfile" 2>/dev/null || true)
  if newstate=$(fm_transition_native_completion \
    "$harness" "$native_identity" "$status" "$prev"); then
    tf="$STATE/$task.turn-ended"
    : > "$tf" 2>/dev/null || touch "$tf" 2>/dev/null || true
    triage_log "native turn-end ($harness $status): $w"
  fi
  printf '%s' "$newstate" > "$sfile" 2>/dev/null || true
  return 0
}

# The ONE derivation of a window's per-window marker key: `:`, `/` and `.` become
# `_` so a window name is usable as a filename suffix. Every per-window file the
# watcher keeps is named by it (.hash-, .count-, .stale-, .stale-since-,
# .wedge-escalations-, .paused-*, .writing-*), and live homes hold those markers on
# disk under the current format, so the format lives here alone: a second copy is
# how a future change to it silently orphans a window's markers instead of clearing
# them. The helpers below take the derived key rather than re-deriving it, so one
# poll of one window derives it once.
window_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

# Steering-inbox loss detection, one cheap check per recorded window per poll.
# Quiet when healthy: an absent, empty, or handled inbox costs one directory
# glob and produces nothing. When the ladder (fm_task_inbox_due_action, the
# policy owner) reports a due action, a busy pane just waits - the record is
# durable and the worker will reach a turn boundary - an idle pane gets one
# delivery attempt, and a spent attempt budget surfaces as an ordinary stale
# wake for stuck-crewmate-recovery. If the attempt's ladder write fails while
# its record remains unhandled, that unwritable state surfaces through the same
# stale path instead of silently re-ringing forever; acknowledgement or teardown
# still makes the race quiet. The attempt is data-plane typing or a
# composer-protected skip, never a wake, so normal retries keep the watcher
# blocking. Runs for secondmates
# too: their pane-staleness exemption is about quiet panes being healthy,
# while an unacknowledged instruction past the ladder is a stuck steer.
inbox_steer_check() {  # <window> <task>
  local w=$1 task=$2 action verb rec count tail40 reason ring_rc
  action=$(fm_task_inbox_due_action "$STATE" "$task") || return 0
  verb=${action%% *}
  [ "$verb" != quiet ] || return 0
  rec=${action#* }
  count=
  case "$verb" in
    escalate)
      count=${rec##* }
      rec=${rec% *}
      ;;
  esac
  tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || tail40=
  if window_is_busy "$w" "$tail40"; then
    return 0
  fi
  case "$verb" in
    ring)
      ring_rc=0
      fm_task_inbox_ring "$(window_backend "$w")" "$w" "$rec" "$(window_label "$w")" "$(window_harness "$w")" || ring_rc=$?
      if ! fm_task_inbox_record_ring "$STATE" "$task" "$rec"; then
        if [ ! -f "$rec" ]; then
          fm_task_inbox_due_action "$STATE" "$task" >/dev/null || true
          return 0
        fi
        if [ -d "${rec%/*}" ]; then
          reason="stale: $w (steering-inbox ladder bookkeeping unwritable: ${rec%/*}/.ring-state cannot be written while $rec stays unhandled; the doorbell cannot advance toward escalation - inspect the inbox directory)"
          fm_wake_append stale "$w" "$reason" || exit 1
          wake "$reason"
        fi
      fi
      triage_log "steer-inbox delivery attempt: $task ${rec##*/} result=$ring_rc"
      ;;
    escalate)
      reason="stale: $w (unread firstmate instruction: $rec still unhandled after $count doorbell delivery attempts with an idle pane; inspect the worker)"
      if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
        fm_task_inbox_due_action "$STATE" "$task" >/dev/null || true
        return 0
      fi
      fm_wake_append stale "$w" "$reason" || exit 1
      if ! fm_task_inbox_record_escalated "$STATE" "$task" "$rec"; then
        echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
        exit 1
      fi
      wake "$reason"
      ;;
  esac
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Print the oldest structurally valid row in a local secondmate's foreign queue.
# This is a read-only observation: the receiving home owns acknowledgement and
# this parent never changes the row or the foreign queue.
secondmate_oldest_queue_row() {  # <queue-path>
  local queue=$1
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  awk -F '\t' '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (!found || $2 < seq) {
        found = 1
        seq = $2
        row = $0
      }
    }
    END { if (found) print row }
  ' "$queue" 2>/dev/null || true
}

# Surface one durable parent check for one unchanged foreign row after its
# bounded age. The primary marker and queued-key check make repeated watcher
# cycles converge without a notification storm, while an empty queue removes
# only this home's marker so a later row can be observed.
secondmate_wake_stall_tick() {
  local now=$(( $(date +%s) )) threshold=$SECONDMATE_WAKE_STALL_SECS
  local meta task kind remote_host home queue row epoch seq row_key marker receipt receipt_dir notify_key queued age reason
  case "$threshold" in ''|*[!0-9]*|0) threshold=60 ;; esac
  # Endpoint metadata admits this queue-loop check; secondmate-liveness owns registered mates whose endpoint is missing or dead.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] || continue
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ -z "$remote_host" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    home=$(fm_meta_get "$meta" home)
    [ -n "$home" ] || continue
    [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || continue
    [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)" = "$task" ] || continue
    queue="$home/state/.wake-queue"
    row=$(secondmate_oldest_queue_row "$queue")
    marker="$STATE/.secondmate-wake-stall-$task"
    receipt_dir="$STATE/.secondmate-wake-stall-receipts/$task"
    if [ -z "$row" ]; then
      rm -f "$marker"
      if [ -e "$receipt_dir" ] || [ -L "$receipt_dir" ]; then
        [ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || return 1
        rm -rf -- "$receipt_dir" || return 1
      fi
      continue
    fi
    IFS=$(printf '\t') read -r epoch seq _row_kind _row_key _row_payload <<EOF
$row
EOF
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    age=$((now - epoch))
    [ "$age" -ge "$threshold" ] || continue
    row_key="$epoch-$seq"
    receipt="$receipt_dir/$row_key"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    fi
    [ "$(cat "$marker" 2>/dev/null || true)" = "$row_key" ] && continue
    [ "$(cat "$receipt" 2>/dev/null || true)" = "$row_key" ] && continue
    notify_key="secondmate-wake-loop-$task-$row_key"
    reason="check: secondmate wake-loop stalled: mate=$task row=$seq age=${age}s"
    queued=$(fm_wake_queued_keys check)
    if ! printf '%s\n' "$queued" | grep -Fx "$notify_key" >/dev/null 2>&1; then
      fm_wake_append check "$notify_key" "$reason" || return 1
    fi
    fm_wake_secondmate_stall_receipt_write "$task" "$row_key" || return 1
    fm_wake_secondmate_stall_marker_write "$task" "$row_key" || return 1
    wake "$reason"
  done
  return 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Cap on CONSECUTIVE run-progress holds for one pane (.wedge-holds-<key>), and
# the principle it enforces: RUN PROGRESS IS EVIDENCE ABOUT THE RUN, NOT ABOUT
# THE WORKER. They are different subjects. A moving pipeline licenses a DELAY in
# alarming, never permanent silence - because the failure permanent silence
# would hide is a hung worker whose pipeline finishes fine and then nobody
# drives the next gate, which is silent, indefinite, and worse than the noise
# the hold exists to cut. So past this cap the pane escalates REGARDLESS of how
# healthy its run looks, carrying the progress detail so the alarm still reads
# as "this run is still moving, but this pane has been silent the whole capped
# window" rather than as an indistinguishable dead pane.
#
# Why 15, stated the same way FM_RUN_STRANDED_SILENCE_SECS states its own bound:
#
#   * Each hold buys one STALE_ESCALATE_SECS window (240s default), so 15 caps
#     held silence at one hour - and then the count resets and the cadence
#     repeats, making this a bounded REPEATING check-in rather than a one-shot
#     that goes quiet forever. That is the shape the declared-pause re-surface
#     cadence in this file already uses.
#   * One hour is deliberately the SAME scale firstmate already accepts
#     elsewhere for a live-but-quiet endpoint: BUSY_TURN_MAX_SECS is 3600 (how
#     long a busy pane may go with no turn-boundary wake) and FM_PAUSE_RESURFACE_SECS
#     is 3600 (how long a declared wait stays quiet before a recheck). Reusing
#     that hour keeps ONE fleet-wide answer to "how long may a live endpoint
#     stay silent before somebody looks" instead of inventing a third.
#   * Measured against this repo's own no-mistakes run history rather than
#     assumed: across 191 review and 183 test steps, review runs 11m at the
#     median and test 6m, so an ordinary run never reaches the cap. The tail
#     does - 9 review steps and 33 ci steps have passed 60m, the longest review
#     117m - and each of those costs one check-in per hour that names the step
#     still moving, so it reads as "still moving", not as a false alarm.
#
# Raising it widens the blind window for a hung worker by the same amount;
# lowering it re-introduces routine noise on long healthy steps.
FM_RUN_PROGRESS_HOLD_MAX=${FM_RUN_PROGRESS_HOLD_MAX:-15}
case "$FM_RUN_PROGRESS_HOLD_MAX" in ''|*[!0-9]*) FM_RUN_PROGRESS_HOLD_MAX=15 ;; esac

# This pane's validation-run progress class, through the shared run-progress
# policy in fm-classify-lib.sh (crew_wedge_progress); this resolves the task from the
# watcher's own plumbing and receives the endpoint liveness verdict already
# resolved at the escalation decision.
#
# The read costs a bounded no-mistakes call, which is exactly why it lives HERE
# and not in the poll loop above: it runs once per would-be alarm (at most once
# per STALE_ESCALATE_SECS per pane), while the poll path runs every FM_POLL
# seconds and must stay cheap - the same reason the wedge timer never re-reads
# crew state.
wedge_run_progress() {  # <window> <agent-state>
  local win=$1 agent=${2:-unknown} task
  task=$(window_to_task "$win" "$STATE")
  [ -n "$task" ] || { printf 'none'; return; }
  crew_wedge_progress "$task" "$agent"
}

# One bounded re-surface for a pane the watcher is deliberately absorbing, so no
# absorb can rot invisibly. <age> is how long the current absorb has held and
# <throttle> is the per-window marker whose mtime records the last re-surface, so
# once past PAUSE_RESURFACE_SECS the pane wakes once per window rather than every
# poll. Shared by the declared-pause absorb and the worktree-write deferral so the
# two cadences cannot drift apart; each caller owns its own marker and reason.
# Returns without waking while either the absorb or the throttle is inside the
# window; wake() itself exits the cycle, exactly as it does inline.
resurface_absorbed() {  # <window> <throttle-marker> <age> <reason>
  local win=$1 throttle=$2 age=$3 reason=$4
  [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] || return 0
  [ "$(age_of "$throttle")" -ge "$PAUSE_RESURFACE_SECS" ] || return 0   # 999999 when no prior re-surface
  fm_wake_append stale "$win" "$reason" || exit 1
  date +%s > "$throttle"
  wake "$reason"
}

# Defer ONE wedge escalation for a pane that went quiet while its own task
# worktree is demonstrably still being written (crew_worktree_written_since in
# fm-classify-lib.sh). The pane and the run step both say nothing is happening;
# the worktree says otherwise, and files appearing in it is the harder signal to
# fake, so the escalation is deferred rather than fired. Deliberately a DEFERRAL,
# not a cancellation: the idle timer restarts, so the next window probes again,
# and a .writing-since-<key> marker ages the whole deferral chain so the pane
# still re-surfaces once every PAUSE_RESURFACE_SECS through the shared
# resurface_absorbed above - literally the same bounded cadence a declared pause
# uses, throttled by its own .writing-resurfaced-<key> marker - and a crew whose
# worktree churns without real progress cannot stay invisible. The escalation
# counter is left alone: it is neither advanced (this is not an escalation) nor
# reset (a later genuine escalation must still carry the demand-deep-inspection
# history it had already earned).
wedge_defer_writing() {  # <window> <since-file> <triage-label> <idle-age>
  local win=$1 since_file=$2 label=$3 age=$4 key wsf wage
  key=$(window_key "$win")
  wsf="$STATE/.writing-since-$key"
  [ -e "$wsf" ] || date +%s > "$wsf"
  wage=$(age_of "$wsf")
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.writing-resurfaced-$key" "$wage" \
    "stale: $win (idle ${age}s, writing its worktree for ${wage}s, rechecked on a long cadence not a wedge; confirm the writes are real progress)"
  triage_log "absorbed $label (worktree written since the idle window opened, idle ${age}s): $win"
}

# Drop a window's write-deferral chain wherever its stale bookkeeping resets, so
# the bounded re-surface cadence is measured from the CURRENT quiet stretch and a
# long-finished one cannot make the next deferral resurface immediately.
clear_write_tracking() {  # <window-key>
  local key=$1
  rm -f "$STATE/.writing-since-$key" "$STATE/.writing-resurfaced-$key"
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
#
# One gate stands between the elapsed timer and the alarm: a crew whose
# validation run is demonstrably PROGRESSING is quiet by design (review and
# test steps routinely emit one opening line and then work silently for ten to
# eighteen minutes), so it holds instead of escalating and restarts the timer,
# putting the next look one full window away rather than one poll away. It is
# a suppressor that needs positive evidence: an absent, parked, stranded, or
# unreadable run cannot earn the hold. For a crew without a declared wait those
# answers leave the path byte-identical to what it was, while the declared-wait
# caller may route a no-evidence answer back to that wait's recheck cadence; a
# stranded run still escalates and names the step that stopped.
#
# The delay a hold buys is bounded twice over, and both bounds matter. A crew
# that wedges immediately after a single hold waits one more STALE_ESCALATE_SECS
# window before its escalation, because the restarted timer re-asks. And
# consecutive holds are capped at FM_RUN_PROGRESS_HOLD_MAX, past which the pane
# escalates however healthy its run looks, because run progress is evidence
# about the RUN and not about the WORKER: an alive-but-hung worker whose
# pipeline keeps advancing would otherwise be silenced for the run's whole
# remaining length. So the worst case is a bounded delay that then repeats as a
# check-in cadence - never a lost alarm - and in exchange a healthy parked crew
# stops spending an escalation every window.
#
# This is also the escalation point for a busy pane past BUSY_TURN_MAX_SECS, and
# the hold applies there DELIBERATELY: that bound exists to catch a hung
# FOREGROUND call, and a crew driving `no-mistakes axi run` in the foreground is
# exactly such a call - busy for the whole pipeline with no turn-boundary wake. It
# is the same healthy worker as the stale case; whether its pane reads busy or
# stale is only an artifact of whether its harness backgrounded the pipeline
# call, so holding for one and not the other would be arbitrary. The cap matters
# more there, not less, because a busy pane has already waited a full
# BUSY_TURN_MAX_SECS hour before its first escalation.
#
# The optional <pane-hash> is the crew's own statement
# that this pane is idle ON PURPOSE - a paused: external wait or a captain-held
# transfer - and they change exactly ONE outcome: the no-evidence one. Run
# progress is evidence about the RUN, and a declared wait is evidence about the
# WORKER, so the two answer different halves of "is this pane wedged", and the
# alarm needs a reason to fire, not merely the absence of one. With a declared
# wait on record, a progress class of `none` - no run attributed, a read that
# could not complete, a run between steps - is no evidence at ALL, and the crew
# has already explained the silence, so the pane falls back to the declared-wait
# re-surface cadence (handle_paused_stale: a long, backing-off recheck that
# still cannot rot invisibly) instead of a 240s wedge alarm. This is the policy
# bin/fm-supervise-daemon.sh's own stale recheck already applies to a declared
# pause, so the two supervisors now agree rather than penalising exactly the
# crew that followed its brief and declared the wait.
#
# Both alarms that rest on POSITIVE evidence survive untouched, which is what
# keeps a genuinely stranded crew loud: a `stranded` run still escalates naming
# the step that stopped, and a confidently DEAD agent still escalates however
# well its run is moving (its run can keep advancing with nobody left to answer
# the next gate - that is the one shape a declared wait must never hide).
#
# Returns 2, and only 2, when it handed the pane to the declared-wait cadence, so
# the caller can leave that cadence's own markers and triage line alone; every
# other outcome returns 0.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> <hold-count-file> <task> [<pane-hash>]
  local win=$1 since_file=$2 label=$3 escalation_file=$4 holds_file=$5
  local task=$6 wait_hash=${7:-}
  local since age n reason progress detail holds agent
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      # Publish the repaired timer only after its old write-deferral chain is
      # gone, so observers cannot mistake a new idle window for the old chain.
      clear_write_tracking "$(window_key "$win")"
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        agent=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent=unknown
        progress=$(wedge_run_progress "$win" "$agent")
        detail=""
        case "$progress" in
          progressing*)
            holds=$(cat "$holds_file" 2>/dev/null || echo 0)
            case "$holds" in ''|*[!0-9]*) holds=0 ;; esac
            if [ "$holds" -lt "$FM_RUN_PROGRESS_HOLD_MAX" ]; then
              # Restart the timer rather than clearing it: the next look is then a
              # full window away instead of one poll away, so a healthy parked
              # crew costs one bounded read per window, not one per poll.
              holds=$(( holds + 1 ))
              echo "$holds" > "$holds_file"
              date +%s > "$since_file"
              triage_log "held $label wedge escalation ($progress, idle ${age}s, hold $holds/$FM_RUN_PROGRESS_HOLD_MAX): $win"
              return 0
            fi
            # Past the cap. Alarm anyway, but say WHY it still looks healthy, so
            # the supervisor can read "the run is moving, this pane is not"
            # straight off the wake instead of mistaking it for a dead pane.
            detail=", validation run still progressing but this pane has been silent for $holds held windows"
            [ -n "$(run_progress_detail "$progress")" ] \
              && detail="$detail: $(run_progress_detail "$progress")"
            ;;
          stranded*)
            detail=", validation run stranded"
            [ -n "$(run_progress_detail "$progress")" ] \
              && detail="$detail: $(run_progress_detail "$progress")"
            ;;
          *)
            # No evidence either way. With a declared wait on record and an agent
            # that is not confidently dead, the crew has already explained this
            # silence, so recheck it on the declared-wait cadence instead of
            # alarming. The endpoint verdict was read once at this escalation
            # decision, so the per-poll path stays as cheap as it was and a
            # confident dead verdict cannot be lost to a second backend read.
            if [ -n "$wait_hash" ] && [ "$agent" != dead ]; then
              triage_log "deferred $label wedge escalation to the declared-wait recheck ($progress, idle ${age}s): $win"
              handle_paused_stale "$win" "$task" "$wait_hash"
              return 2
            fi
            if crew_worktree_written_since "$task" "$STATE" "$since_file"; then
              wedge_defer_writing "$win" "$since_file" "$label" "$age"
              return 0
            fi
            ;;
        esac
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n$detail)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n$detail, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        # The hold streak ends with the alarm, so the cap becomes a repeating
        # check-in cadence. The ESCALATION count deliberately survives: a forced
        # escalation is a real escalation and must keep counting toward
        # demand-deep-inspection.
        rm -f "$since_file" "$holds_file"
        clear_write_tracking "$(window_key "$win")"
        wake "$reason"
      fi
      ;;
  esac
}

# busy_turn_over_age: 0 iff <task>'s latest turn-boundary wake marker is at least
# BUSY_TURN_MAX_SECS old. Ages the per-task turn-ended marker, the harness-neutral
# wake written by a verified turn-end producer or the cursor/agy native-idle
# detector; before any such wake arrives, ages the task's spawn record so a
# fresh task gets a bound. The caller checks that the pane is busy and routes a
# crossed bound through busy_turn_bound_check, never anything that touches the
# worker itself.
busy_turn_over_age() {  # <task>
  local task=$1 f
  f="$STATE/$task.turn-ended"
  [ -e "$f" ] || f="$STATE/$task.meta"
  [ "$(age_of "$f")" -ge "$BUSY_TURN_MAX_SECS" ]
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# pause re-surface window for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
#
# Each re-surface that finds the SAME wait still declared widens the next window
# (pause_resurface_window, the shared owner of the backoff, counting the streak
# in .paused-streak-<key>): a wait nobody can act on yet - a captain-owned merge
# decision, an upstream release - otherwise costs a supervisor the identical
# recheck at the identical rate for as long as it lasts. The recheck still
# happens, so a forgotten hold cannot rot invisibly; it just stops nagging. The
# widening is earned by one wait and dies with it: the streak record carries the
# status line that declared the wait, so replacing that line with a DIFFERENT
# declared wait resets the streak and drops the re-surface throttle, and the new
# wait is rechecked at the base window off its own status write.
# The recheck names WHICH human the declared wait is on, because that is the whole
# point of a recheck the captain reads: an external dependency for paused:, and the
# captain themself for a verified hold. Only the captain-held verb takes the second
# wording; a caller that reached the bounded cadence off pause tracking alone, with
# no declaring verb left on the log, keeps the external-wait wording it always had.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age detail reason rf rf_age wait_line streak_file resurface_window
  key=$(window_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.wedge-holds-$key"
  clear_write_tracking "$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  wait_line=$(last_status_line "$statusf")
  streak_file="$STATE/.paused-streak-$key"
  if pause_streak_sync "$streak_file" "$wait_line"; then
    rm -f "$rf"
  fi
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  resurface_window=$(pause_resurface_window "$(pause_streak_count "$streak_file")")
  if status_is_captain_held "$wait_line"; then
    detail="captain-held, awaiting the captain"
    reason="stale: $win (captain-held ${age}s, awaiting the captain - verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold)"
  else
    detail="paused, awaiting external"
    reason="stale: $win (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
  fi
  if [ "$age" -ge "$resurface_window" ] && [ "$rf_age" -ge "$resurface_window" ]; then
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    pause_streak_bump "$streak_file" "$wait_line"
    wake "$reason"
  fi
  triage_log "absorbed stale ($detail, age ${age}s): $win"
}

# Apply the busy-pane completed-turn bound to a window whose bound has already
# crossed, honoring the worker's OWN declared external wait. Prints/queues
# nothing itself; it only chooses which absorber owns the crossed bound.
# 0 when the declared-pause cadence took the pane, 1 when the wedge timer did.
#
# A busy pane past BUSY_TURN_MAX_SECS is normally a wedge suspect because a hung
# foreground call can hide behind a busy signature. A `paused:` declaration or
# verified captain-held transfer instead identifies that live foreground call as
# the expected external wait. The caller has already confirmed liveness through
# the busy verdict, so this exception does not suppress undeclared wedges or
# alter the separate non-busy classification. handle_paused_stale keeps the
# exception bounded by re-surfacing it once per PAUSE_RESURFACE_SECS. Away mode
# remains daemon-owned and receives the undecorated wake identity for its own
# classification.
busy_turn_bound_check() {  # <window> <task> <hash> <since-file> <escalation-file> <hold-count-file>
  local win=$1 task=$2 h=$3 since_file=$4 escalation_file=$5 holds_file=$6
  if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
    handle_paused_stale "$win" "$task" "$h"
    return 0
  fi
  wedge_timer_check "$win" "$since_file" "busy (no completed turn)" "$escalation_file" "$holds_file" "$task"
  return 1
}

clear_pause_state() {  # <window-key>
  local key=$1
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key" \
    "$STATE/.paused-streak-$key"
}

clear_pause_tracking() {  # <window-key>
  local key=$1
  clear_pause_state "$key"
  clear_write_tracking "$key"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" \
    "$STATE/.wedge-holds-$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
#
# A DECLARED pause (paused:, the verb the generated brief tells every crew to
# append before it parks) is the crew's own statement that this pane is idle on
# purpose, and it is honoured on its own. Agent liveness must NOT gate it: on
# every verified harness "append paused: and stop" means end the turn, so the
# agent is still sitting at its prompt, and requiring a confidently dead agent
# made the designed pause cadence unreachable for exactly the crew the brief
# creates - it wedge-surfaced every few minutes for as long as the wait lasted.
# Liveness keeps its RECOVERY job below and everywhere else; it just no longer
# decides whether the declaration counts.
#
# A captain-held transfer is not the crew declaring anything, so it keeps the
# original rule: only a confidently dead ordinary crew may recover paused
# classification after fm-crew-state has fallen back to stopped or unknown. A
# crew that declared no wait at all never reaches past the first branch, so a
# genuine wedge still escalates on the unchanged cadence.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive declared_pause kind
  key=$(window_key "$win")
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if status_is_paused "$last"; then declared_pause=0; else declared_pause=1; fi
  kind=$(window_kind "$win")
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$declared_pause" -ne 0 ] && [ "$kind" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$declared_pause" -ne 0 ] && [ "$kind" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  if [ "$class" = none ] && { [ "$declared_pause" -eq 0 ] || [ "${agent_alive:-unknown}" = dead ] || [ "$kind" = secondmate ]; }; then
    class=paused
  fi
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

# 0 when a parked crew has stopped responding: its recorded endpoint no longer
# carries a live agent. Only the confident `dead` verdict counts (an ambiguous,
# unreadable, or unverified backend read stays absorbed), so suppressing the
# repeat surface above never costs wedge detection for a parked crew that dies.
parked_agent_is_dead() {  # <window>
  local win=$1 state
  state=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || return 1
  [ "$state" = dead ]
}

# Read the status line BEFORE queueing anything. This used to queue the wake
# first and only then discover the declared pause, which is how a brief-compliant
# parked crew still got a bare "stale: <window>" every few minutes: the pause was
# recognised one step too late to suppress the wake it had just queued, and the
# .paused-* markers it stamped afterwards left no streak record, so the designed
# widening cadence never ran. A declared pause is now routed to its owner,
# handle_paused_stale, which advances the same stale suppressor and owns the
# backoff. A captain-held transfer still surfaces here, because it is not the
# crew's own declaration that the pane is idle on purpose.
surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(window_key "$win")
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused "$last"; then
    handle_paused_stale "$win" "$task" "$h"
    return
  fi
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-holds-$key"
  clear_write_tracking "$key"
  if status_is_paused_or_captain_held "$last"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    clear_pause_state "$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(fm_wake_signal_sig "$f") || continue
    [ -n "$sig" ] || continue
    sf=$(fm_wake_signal_seen_path "$STATE" "$f")
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

# Deliver a durably queued process-event result to firstmate. Publication is
# owned by bin/fm-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake firstmate, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason
  PROCEVENT_SURFACED=
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  while IFS= read -r key; do
    case "$key" in procevent:*) ;; *) continue ;; esac
    [ -e "$(procevent_surfaced_marker "$key")" ] && continue
    PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
  done < <(fm_wake_queued_keys_locked check)
  if [ -z "$PROCEVENT_SURFACED" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason="check: process-event result captured:$PROCEVENT_SURFACED"
  # shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
  FM_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  # Re-arm the burst-safe stop handler installed at startup, never a bare
  # 'exit 1': a second stop signal during the EXIT trap must stay disarmed.
  trap watcher_stop_signal HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# fm-push-transition-lib.sh because push and poll paths must write one format.
# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    mark_surfaced "$f"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# interruptible_sleep: wait <seconds> without swallowing this watcher's own stop
# signal. Bash defers a trapped signal until the running FOREGROUND command
# finishes, so a blind `sleep "$POLL"` left the watcher deaf to TERM/HUP/INT for
# the remainder of the interval - exit latency tracked FM_POLL exactly, 14.53s
# at the 15s default. Every path that stops this home's watcher (fm-watch-arm.sh's
# HUP/TERM teardown, its --restart stop-then-relaunch, and its bounded 5s wait for
# the old watcher to exit) paid that latency, and the default 15s poll exceeds that
# restart budget outright, so a restart forked a second watcher while the first was
# still alive holding the lock. Backgrounding the sleep and waiting on the named
# child keeps the same wait budget while letting the trap run the moment the signal
# lands. Tracked so the EXIT path can reap the child instead of orphaning it for
# the rest of the interval. Cadence, wake classification, and the heartbeat beacon
# are unchanged, so wedge detection is unaffected. Measurements and the herdr
# push-path limit below: docs/verification/supervision.md.
INTERRUPTIBLE_SLEEP_PID=
interruptible_sleep() {
  sleep "$1" &
  INTERRUPTIBLE_SLEEP_PID=$!
  wait "$INTERRUPTIBLE_SLEEP_PID" 2>/dev/null || true
  INTERRUPTIBLE_SLEEP_PID=
}

interruptible_sleep_stop() {
  [ -n "$INTERRUPTIBLE_SLEEP_PID" ] || return 0
  kill -TERM "$INTERRUPTIBLE_SLEEP_PID" 2>/dev/null || true
  wait "$INTERRUPTIBLE_SLEEP_PID" 2>/dev/null || true
  INTERRUPTIBLE_SLEEP_PID=
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it waits POLL on
# the interruptible poll path with the same cadence. The poll loop above still
# runs every cycle, so this only ever SHORTENS latency; it can never drop an
# escalation (the poll loop is the permanent fail-closed backstop). This
# preserves the single live supervision cycle: the reader is a short-lived
# subprocess of THIS watcher, not a second watcher, so every
# guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    interruptible_sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    interruptible_sleep "$POLL"
    return
  fi

  # Known limit: unlike the interruptible_sleep budgets above, this reader wait is
  # a foreground command substitution, so a push-capable home stays up to POLL deaf
  # to its own stop signal. It is left alone deliberately: the reader owns a fifo
  # dir and a child reader process that it removes on its own return path, so
  # interrupting it here would leak both on every stop. Fixing it needs reader-side
  # teardown, not a second background wrapper.
  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      interruptible_sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
WATCHER_RECOVERY_PENDING=0
if [ -n "${FM_LOCK_RECOVERED_PID:-}" ]; then
  WATCHER_RECOVERY_PENDING=1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" != 1 ]; then
  if ! fm_recovery_marker_reopen_announced "$WATCHER_DOWNTIME_MARKER"; then
    echo "watcher: recovery state could not be reopened safely; retaining stale lock evidence" >&2
    exit 1
  fi
fi
if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
  echo "watcher: recovery state could not be consumed safely; retaining stale lock evidence" >&2
  exit 1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
  WATCHER_RECOVERY_PENDING=0
elif [ "$FM_RECOVERY_MARKER_ACTION" = recover ]; then
  WATCHER_RECOVERY_PENDING=1
fi
watcher_cleanup() {
  # Disarm stop signals for the whole cleanup, covering exits the stop handler
  # did not initiate (self-eviction, error exits): a stop signal landing while
  # this EXIT trap runs would re-enter its own trap and exit immediately, and
  # bash never resumes an aborted EXIT trap, so the lock release below would be
  # skipped and the singleton lock left on disk naming a dead pid (issue #160).
  trap '' HUP INT TERM
  local cleanup_status=0 owns_lock=0 transition=release-lock
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "${WATCHER_PID:-}" ]; then
    owns_lock=1
    if [ "${WATCHER_RECOVERY_PENDING:-0}" -eq 1 ] \
      && [ "${FM_WATCH_DELIVERED_REASON:-}" = "check: rearm-resurface" ]; then
      transition=release-lock-existing
    fi
  fi
  interruptible_sleep_stop
  fm_active_check_stop || cleanup_status=1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  if [ "$owns_lock" -eq 1 ] \
    && ! fm_recovery_transition "$WATCHER_DOWNTIME_MARKER" "$transition" "$WATCH_LOCK" downtime; then
    echo "watcher: recovery state could not be persisted; retaining stale lock evidence" >&2
    cleanup_status=1
  fi
  return "$cleanup_status"
}
# The stop handler must disarm before exiting, not just exit: real senders
# deliver stop signals in bursts (coreutils timeout signals the process group
# and then re-signals from its own handler), and the second signal otherwise
# lands inside watcher_cleanup and aborts it as described above. Stop signals
# are therefore ignored while cleanup runs. Its normal work is bounded child
# reaping plus lock release; if that work wedges, SIGKILL is the escape hatch.
watcher_stop_signal() {
  trap '' HUP INT TERM
  exit 1
}
trap watcher_cleanup EXIT
trap watcher_stop_signal HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
# shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
FM_WATCH_DELIVERY_PID=$WATCHER_PID
FM_WATCH_DELIVERY_IDENTITY=$(fm_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$FM_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

# Shared by both the first-notification and already-notified paths below so
# the retirement sequence (bin/fm-pr-lib.sh) is stated once.
retire_merged_pr_poll() {  # <id>
  local id=$1
  if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" merged; then
    fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
      || triage_log "merged PR poll retirement remains recoverable for $id"
  else
    triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
  fi
}

resurface_after_downtime() {
  # Handling successors already have a predecessor-delivered wake on the way.
  # Re-announcing from this cycle is what turned a lost handshake into an
  # unbounded recovery loop; stay in the poll loop and supervise instead.
  if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
    return 0
  fi
  if [ "$WATCHER_RECOVERY_PENDING" -ne 1 ]; then
    if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
      echo "watcher: recovery state could not be consumed safely" >&2
      exit 1
    fi
    [ "$FM_RECOVERY_MARKER_ACTION" = recover ] || return 0
  fi
  wake "check: rearm-resurface"
}

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # A live secondmate endpoint does not prove that its own wake loop is alive.
  # Observe the foreign queue before the rest of this cycle so an aged row wakes
  # the parent without consuming or rewriting the receiving home's record.
  secondmate_wake_stall_tick || {
    echo "watcher: secondmate wake-loop observation failed" >&2
    exit 1
  }

  # Process-to-event liveness repair. This never discovers a result by polling:
  # each registered source has its own child blocking on that source, and this
  # only republishes results already captured durably and restarts a source
  # whose owner is gone. It is a no-op with nothing registered.
  if [ -d "$STATE/procevent" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi
  # Then deliver any queued-but-unsurfaced result, including one a runner
  # published while this watcher was between cycles.
  procevent_surface_queued

  # A process-event result carries richer adapter-owned wake context than the
  # generic recovery reason, so give that owner first refusal.
  resurface_after_downtime

  # The existing poll loop also owns the bounded inactive-outcome cadence.
  # This is mechanical and silent unless a durable terminal-outcome obligation
  # was created, so quiet cycles never wake firstmate or consume model tokens.
  inactive_out=
  if inactive_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-inactive-reconcile.sh" scan 2>/dev/null); then
    if [ -n "$inactive_out" ]; then
      wake "check: inactive-outcome"
    fi
  else
    triage_log "inactive-outcome reconciliation unavailable"
  fi

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          merge_outcome_rc=0
          fm_merge_outcome_report "$FM_HOME" "$STATE" "$id" "$url" poll \
            || merge_outcome_rc=$?
          if [ "$merge_outcome_rc" -ne 0 ]; then
            triage_log "merge outcome for $id could not be recorded (rc=$merge_outcome_rc)"
            exit 1
          fi
          retire_merged_pr_poll "$id"
          touch "$STATE/.last-check"
          if [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ]; then
            triage_log "absorbed duplicate merged PR poll result for $id"
            continue
          fi
          wake "$reason"
        fi
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    interruptible_sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    # Steering-inbox loss detection runs before the secondmate stale
    # exemption below, because a mate's steers land in an inbox too.
    [ -z "$task" ] || inbox_steer_check "$w" "$task"
    key=$(window_key "$w")
    # cursor/agy native turn-end: runs before the capture-and-hash backstop below
    # (and before the secondmate skip) so a settled cursor/agy native-idle edge wakes
    # firstmate from its NATIVE idle/done state even when the content hash never
    # settles. A no-op for every non-cursor/agy window.
    maybe_native_turnend "$w" "$task" "$key"
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$key"
    fi
    # An idle secondmate endpoint is healthy by design, so a mate is admitted to
    # the pane-stale path ONLY to serve a declared wait's bounded re-surface -
    # the same declarations pause_state_class reconciles below, which is why this
    # gate reads the shared predicate rather than the pause verb alone. Narrowing
    # it to `paused` would leave a mate's captain hold rotting invisibly: the
    # clear above already spares its pause tracking, but nothing would ever
    # re-surface it.
    if [ "$kind" = secondmate ] && ! status_is_paused_or_captain_held "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    whf="$STATE/.wedge-holds-$key"   # consecutive run-progress holds, capped by FM_RUN_PROGRESS_HOLD_MAX
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    if window_is_busy "$w" "$tail40"; then busy_now=0; else busy_now=1; fi
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$key" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give a working current or bounded-degraded
          # run/busy pane (the same authoritative source fm-crew-state.sh itself
          # already prioritizes over the log) a chance to override before
          # trusting the log.
          #
          # Key this one-shot on the complete open-decision set, not volatile
          # pane bytes. mark_surfaced reconciles this marker for every surfaced
          # status, while a confidently dead parked agent still advances the
          # shared wedge timer below. docs/architecture.md owns the full wake
          # contract.
          did=$(open_decision_id "$task")
          dsf="$STATE/.stale-decision-$key"
          [ -n "$did" ] || rm -f "$dsf"
          if [ -n "$did" ] && [ "$(cat "$dsf" 2>/dev/null || true)" = "$did" ]; then
            printf '%s' "$h" > "$sf"
            if parked_agent_is_dead "$w"; then
              wedge_timer_check "$w" "$ssf" "stale (parked on an open decision, agent gone)" "$ewf" "$whf" "$task"
            else
              rm -f "$ssf" "$ewf" "$whf"
              triage_log "absorbed stale (open decision already surfaced): $w"
            fi
          elif [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              rm -f "$whf"
              clear_write_tracking "$key"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf" "$whf"
              clear_write_tracking "$key"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf" "$whf" "$task"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait (honoured whether or not
          #     its agent is still alive at its prompt), or a captain hold is paired
          #     with a confidently dead agent, so absorb on the long pause
          #     re-surface cadence instead of wedge-escalating;
          #   - none: no running pipeline, no exact busy verdict, no admitted declared wait.
          #     Surface immediately so firstmate inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$key"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                # Distinct from the repeat-poll line below on purpose: THIS poll
                # absorbed and started the wedge timer, that one absorbed and
                # ADVANCED an already-running timer toward an escalation. Logging
                # both as one line is what let a stream of "absorbed" entries sit
                # in the triage log beside arriving escalations for two days,
                # reading as the mechanism working while it was not.
                triage_log "absorbed non-terminal stale (provably working, wedge timer started): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) printf '%s' "$h" > "$sf"
                         # Authoritative working state outranks the declaration for
                         # TRACKING - the wedge timer, not the pause cadence, owns
                         # this pane - but the declaration is passed through, so a
                         # no-evidence verdict at the alarm rechecks on the wait's
                         # own cadence instead of alarming. A stranded run or a
                         # confidently dead agent still escalates.
                         #
                         # The pause markers are deliberately left standing: they
                         # carry the re-surface throttle and backoff streak the
                         # fallback needs, and clearing them here would restart that
                         # backoff on every poll, turning one declared wait into a
                         # recheck every wedge window. They die with the declaration
                         # itself, through the status reconciliation at the top of
                         # this loop, which is the one event that means the wait is
                         # genuinely over.
                         wedge_rc=0
                         wedge_timer_check "$w" "$ssf" \
                           "non-terminal stale (provably working after a declared wait)" \
                           "$ewf" "$whf" "$task" "$h" || wedge_rc=$?
                         # A deferral is handle_paused_stale's event and carries its
                         # own triage line; only the timer's own poll logs here.
                         [ "$wedge_rc" -eq 2 ] \
                           || triage_log "absorbed non-terminal stale (provably working after a declared wait, wedge timer advanced): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" "$whf" "$task"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no turn-boundary
        # wake - then route it through busy_turn_bound_check, which hands the
        # crossed bound to the same wedge timer unless the crew declared the
        # wait itself.
        paused_bound=1
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
          busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" "$whf" && paused_bound=0
        else
          rm -f "$ssf" "$ewf" "$whf"
          clear_write_tracking "$key"
        fi
        # A busy pane normally means real work resumed, so stale pause bookkeeping
        # is cleared - but not in the same poll the declared-pause cadence just
        # recorded it, or the re-surface throttle it depends on would be erased and
        # the pause would re-surface every poll instead of once per long cadence.
        if [ "$paused_bound" -ne 0 ] && [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$key"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      paused_bound=1
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
        busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" "$whf" && paused_bound=0
      else
        rm -f "$ssf" "$ewf" "$whf"
        clear_write_tracking "$key"
      fi
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && [ "$busy_now" -ne 0 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$key" ;;
        esac
      elif [ "$paused_bound" -ne 0 ] && [ -e "$pf" ]; then
        # Same rule as the stable-hash branch: never clear pause bookkeeping the
        # declared-pause cadence recorded on this very poll.
        clear_pause_tracking "$key"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
