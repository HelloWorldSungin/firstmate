#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reconciles attributable no-mistakes run
# evidence, the bounded record used only after a lookup failure, and pane busy
# state before consulting the possibly-stale log.
#
# The deterministic reconciliation lives entirely here - bounded run-step / pane /
# log reads, one run-step cache update, and fixed mapping logic, with no heuristics
# and no LLM. Output is one stable, parseable, token-tight line firstmate can read
# every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown|abandoned> · source: <run-step|run-step-degraded|run-attribution|completion-attestation|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta. For a ship or design task,
#      branch= in that task record is the authoritative task branch: fm-spawn
#      copies it from fm-brief's exact firstmate-task-branch marker, while
#      fm-promote writes it alongside the promotion's exact branch instruction.
#      The worktree's ambient branch is only observed evidence, never task
#      identity. A named ambient branch that differs from the recorded branch is
#      an attribution fault, not permission to inspect that branch's run or fall
#      back to the status log. Legacy task records have no reliable task branch;
#      if a run is found through their ambient branch, that run is likewise
#      surfaced as unattributable rather than guessed from the task id.
#   2. Matching no-mistakes run for this crew's branch AND attributable code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history). It also matches in two cases the pipeline's own
#      commits create, both narrowed to the run that is demonstrably current:
#      an ACTIVELY-EXECUTING run whose head the tip has advanced past (it
#      authored that advance), and a LIVE run answered for this branch whose head
#      is not an object in this worktree at all (the pipeline owns the branch and
#      commits in a copy this worktree has never fetched). Local work that
#      advanced past a parked or terminal run head, a rewritten or diverged tip,
#      and an unresolvable sha read out of the historical runs listing all still
#      invalidate attribution. nm_head_attributable owns the exact rule.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#      Only a terminal pass whose own `ci` step completed observed the forge.
#      A skipped, absent, or incomplete ci step therefore reports the local
#      pipeline passing rather than naming a merge. A declared pause or
#      captain-held line recorded after any terminal run-step verdict (done or
#      failed) is newer information than that verdict and is reported as that
#      wait, except a forge-observed merge (outcome=passed with ci completed),
#      where the wait is deterministically stale and done stays authoritative.
#      See nm_ci_step_skipped for why the explicit skipped verdict refuses to claim a
#      forge outcome rather than going and reading one.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. An inconclusive run lookup may replay this crew's recent observed step as
#      `run-step-degraded`, but only after endpoint liveness and an exact busy
#      verdict and only inside the configured age bound. A replayed
#      `working` step runs the same worker-liveness cross-check as a live
#      working verdict, so a record written before the worker died cannot
#      re-emit `working` for the rest of the degrade window (issue #111).
#   5. A completed lookup with no run for this crew (pre-validation, or kind=scout)
#      falls back to the recorded backend's pane busy state, then the status log's
#      last line only when its verb maps to a recognized run-state. Decision-only
#      events such as `resolved` never become current state or detail.
#   6. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#   7. Worker-liveness cross-check, applied lazily and only to a plain
#      `working` verdict (run-step and busy-pane alike): the no-mistakes
#      daemon can keep advancing a run after the worker has exited cleanly,
#      so a plain `working` is no longer sufficient on its own (issue #105).
#      The run reaches its next gate and parks forever while the task keeps
#      reporting healthy validation, because nobody is left to answer the
#      next gate or read the next synchronous return. Cross-check
#      fm_backend_agent_state (the recovery-grade classifier the secondmate
#      liveness sweep reuses) and apply it to both paths. A confident `dead`
#      or `missing` agent surfaces as the new actionable state `abandoned`
#      (the run is advancing with nobody driving it); an `ambiguous` or
#      `unreadable` read downgrades to `unknown` rather than resolving
#      either way - a liveness read that cannot complete is never `alive`
#      and never `dead`. An `unverified` backend has no recovery classifier,
#      so the verdict keeps its current shape there (no new unanswered
#      check). The check is computed only on a `working` verdict, so
#      `done`/`failed`/`parked` (which need no worker or already surface)
#      and secondmates (which read their state from the status log) pay
#      nothing for it. The same mapping is applied when a degraded replay
#      would re-emit `working`; working_after_liveness is the single owner.
#
# A run LOOKUP FAILURE is not a run ABSENCE. The bounded no-mistakes call
# propagates timeout, execution, and no-bounding-mechanism failures so only a
# failed lookup can replay the last known run step; a completed lookup that found
# no run falls through to the pane and log sources.
#
# Writes exactly one thing: state/<id>.run-step, the last known run-step record
# and its status-log position (runstep_record_write below is the only writer).
# Every other read is side-effect free. Always exits 0 on a successful
# read regardless of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
# How long a recorded run-step stays usable as the degraded answer after the run
# lookup starts failing. This is the bound that keeps the degrade from becoming a
# worse bug than the one it fixes: a permanently broken no-mistakes daemon would
# otherwise let every idle crew claim it is still validating forever, and a real
# wedge would never surface again. Past this age the record is ignored and the
# crew falls through to the pane/log sources exactly as it does today. 0 disables
# the degrade entirely, restoring the strict "cannot re-confirm it, do not claim
# it" reading for a home that wants it.
FM_CREW_STATE_DEGRADED_MAX_AGE=${FM_CREW_STATE_DEGRADED_MAX_AGE:-900}
case "$FM_CREW_STATE_DEGRADED_MAX_AGE" in ''|*[!0-9]*) FM_CREW_STATE_DEGRADED_MAX_AGE=900 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
TASK_BRANCH=$(meta_value branch)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
[ -n "$KIND" ] || KIND=ship
tracked_output_kind() {
  [ "$KIND" = ship ] || [ "$KIND" = design ]
}

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, its physical line number, and the file metadata
# that bounds that read.
if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
  log_file_state() {
    stat -f '%m %z' "$LOG" 2>/dev/null || printf '0 0'
  }
else
  log_file_state() {
    stat -c '%Y %s' "$LOG" 2>/dev/null || printf '0 0'
  }
fi
log_snapshot() {
  local before after payload attempt=0
  while [ "$attempt" -lt 2 ]; do
    before=$(log_file_state)
    payload=$(awk 'NF { position = NR; line = $0 } END { printf "%s\t%s", position + 0, line }' \
      "$LOG" 2>/dev/null || true)
    after=$(log_file_state)
    if [ "$before" = "$after" ]; then
      printf '%s\t%s\t%s' "${before%% *}" "${before#* }" "$payload"
      return 0
    fi
    attempt=$(( attempt + 1 ))
  done
  return 1
}
apply_log_snapshot() {  # <snapshot>
  local snapshot=${1:-} rest
  LOG_MTIME=0
  LOG_POSITION=0
  LOG_LINE=""
  case "$snapshot" in
    *$'\t'*$'\t'*$'\t'*)
      LOG_MTIME=${snapshot%%$'\t'*}
      rest=${snapshot#*$'\t'}
      rest=${rest#*$'\t'}
      LOG_POSITION=${rest%%$'\t'*}
      LOG_LINE=${rest#*$'\t'}
      ;;
  esac
  LOG_VERB=$(status_line_verb "$LOG_LINE")
}
refresh_log_snapshot() {
  local snapshot
  snapshot=$(log_snapshot) || return 0
  apply_log_snapshot "$snapshot"
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_SNAPSHOT=$(log_snapshot || true)
apply_log_snapshot "$LOG_SNAPSHOT"

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_busy_verdict: the crew's semantic busy state from the one contract
# owner (bin/fm-busy-lib.sh), as "<busy|idle|unknown> <source>". A converted
# adapter answers from its own lifecycle record; Grok answers from its
# isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
# when no record exists, but its native `idle` is NOT, because agent.get
# reports generation state (idle while a crew blocks on its own long-running
# foreground tool call) rather than turn state.
crew_busy_verdict() {  # <target>
  local tail40=''
  case "$HARNESS" in
    grok*) tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40='' ;;
  esac
  fm_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40"
}

# Worker-liveness cross-check (issue #105). A PURE read of the recovery-grade
# agent classifier (fm_backend_agent_state, the same classifier the secondmate
# liveness sweep reuses), captured into WORKER_STATE only where a plain
# `working` verdict is about to be emitted. It runs at most once per
# invocation because the run-step and busy-pane paths are mutually exclusive
# (the run-step path emits and exits first), and it is never reached by the
# paths that do not produce a plain working verdict: a secondmate reads its
# state from the status log and skips both, a terminal run-step needs no
# worker, and the bulk session-start digest never calls this script at all (it
# does its own cheap per-task presence check), so a fleet-wide sweep pays
# nothing for this cross-check.
#
# The verdict's `working` source is no longer sufficient on its own: the
# no-mistakes daemon keeps advancing a run after the worker has exited cleanly,
# so a `working · run-step` verdict with a confidently dead or missing agent is
# the bug being fixed. A liveness read that cannot complete is `unknown`, never
# `alive` and never `dead`; an unverified backend has no recovery classifier, so
# the verdict keeps its current shape there (no new unanswered check).
#
# FM_FAKE_AGENT_STATE is the test seam: tests set it to drive the verdict
# without going through the recovery-grade classifier (whose real tmux/ps
# surface is pinned in tests/fm-tmux-agent-liveness.test.sh). Default in tests
# is `alive` so the existing `working` semantics stay unchanged.
worker_liveness_state() {  # -> alive|dead|missing|ambiguous|unreadable|unverified
  local state
  if [ -n "${FM_FAKE_AGENT_STATE:-}" ]; then
    state=$FM_FAKE_AGENT_STATE
  elif [ -z "$BACKEND_TARGET" ] || [ -z "$TASK_BACKEND" ]; then
    state=unverified
  else
    case "$TASK_BACKEND" in
      tmux|herdr)
        state=$(fm_backend_agent_state "$TASK_BACKEND" "$BACKEND_TARGET" 2>/dev/null) || state=unreadable
        ;;
      *) state=unverified ;;
    esac
  fi
  # The vocabulary is closed here, not at the call sites: an empty answer from a
  # classifier that returned without printing, or a token added to the contract
  # later, is a read that did not complete and reports `unreadable`.
  case "$state" in
    alive|dead|missing|ambiguous|unreadable|unverified) printf '%s' "$state" ;;
    *) printf 'unreadable' ;;
  esac
}

# Apply the worker-liveness cross-check to a plain working verdict.
# Prints "<state>\t<detail-suffix>". The suffix is empty when the verdict is
# unchanged. Live run-step, busy-pane, and degraded replay of a working record
# all go through here so the mapping cannot drift across those three sites
# (issues #105 and #111). Callers must parse both fields from one invocation:
# a command substitution would otherwise lose the detail in a subshell.
working_after_liveness() {
  local state note=""
  WORKER_STATE=$(worker_liveness_state)
  case "$WORKER_STATE" in
    alive|unverified) state=working ;;
    dead|missing)
      state=abandoned
      note="${SEP}worker gone ($WORKER_STATE)"
      ;;
    *)
      state=unknown
      note="${SEP}agent liveness $WORKER_STATE"
      ;;
  esac
  printf '%s\t%s' "$state" "$note"
}

# --- last known run-step record ---------------------------------------------
# state/<id>.run-step: one line,
# "<epoch>\t<state>\t<detail>\t<run-id>\t<run-alias>\t<status-position>\t<merge-observed>\tv3", atomically
# replaced on every successful run-derived verdict. It orders a later declared
# wait against that verdict and lets a lookup FAILURE answer
# "still validating, lookup unavailable" instead of "unknown", without ever
# inventing evidence: nothing is degraded for a crew that was never seen
# validating in the first place, so a crew that genuinely stopped before any run
# has no record to fall back on and still surfaces as a wedge suspect.
RUNSTEP_RECORD="$STATE/$ID.run-step"

# Record a run-derived verdict. Never fails the read: a state dir that is
# read-only or already torn down just leaves the previous record in place.
runstep_record_write() {  # <state> <detail> [run-id] [run-alias] [merge-observed] [status-position]
  local tmp flat record_position
  case "$1" in working|parked|done|failed|abandoned) ;; *) return 0 ;; esac
  [ -d "$STATE" ] || return 0
  flat=$(printf '%s' "${2:-}" | tr '\t\n' '  ')
  record_position=${6:-$LOG_POSITION}
  case "$record_position" in ''|*[!0-9]*) return 0 ;; esac
  tmp="$RUNSTEP_RECORD.$$.tmp"
  if printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tv3\n' \
    "$(date +%s)" "$1" "$flat" "${3:--}" "${4:--}" "$record_position" \
    "${5:-0}" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$RUNSTEP_RECORD" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

runstep_record_clear() {
  rm -f "$RUNSTEP_RECORD" 2>/dev/null || true
}

runstep_record_emit() {  # <state> <source> <detail> [run-id] [run-alias] [merge-observed]
  runstep_record_write "$1" "${3:-}" "${4:--}" "${5:--}" "${6:-0}"
  emit "$1" "$2" "${3:-}"
}

runstep_record_load() {
  local f1 f2 f3 f4 f5 f6 f7 f8
  RECORD_TS=""
  RECORD_STATE=""
  RECORD_DETAIL=""
  RECORD_RUN_ID=""
  RECORD_RUN_ALIAS=""
  RECORD_POSITION=""
  RECORD_MERGE_OBSERVED=0
  RECORD_VERSION=""
  [ -f "$RUNSTEP_RECORD" ] || return 1
  IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 f7 f8 < "$RUNSTEP_RECORD" 2>/dev/null || return 1
  RECORD_TS=$f1
  RECORD_STATE=$f2
  RECORD_DETAIL=$f3
  if [ "$f8" = v3 ]; then
    RECORD_RUN_ID=$f4
    RECORD_RUN_ALIAS=$f5
    RECORD_POSITION=$f6
    RECORD_MERGE_OBSERVED=$f7
    RECORD_VERSION=$f8
  elif [ "$f6" = v2 ]; then
    RECORD_RUN_ALIAS=$f4
    RECORD_POSITION=$f5
    RECORD_VERSION=$f6
  fi
  return 0
}

# Print "<state>\t<detail>\t<age-seconds>" for a record still inside the
# freshness bound; return 1 for a missing, malformed, or expired record.
runstep_record_read() {
  local now age
  runstep_record_load || return 1
  case "${RECORD_TS:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${RECORD_STATE:-}" in working|parked|done|failed|abandoned) ;; *) return 1 ;; esac
  if { [ "$RECORD_STATE" = "done" ] || [ "$RECORD_STATE" = failed ]; } \
    && status_is_paused_or_captain_held "$LOG_LINE"; then
    [ "$RECORD_VERSION" = v3 ] || return 1
    case "${RECORD_POSITION:-}" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$RECORD_STATE" != "done" ] \
      || [ "$RECORD_MERGE_OBSERVED" != 1 ]; then
      [ "$LOG_POSITION" -le "$RECORD_POSITION" ] || return 1
    fi
  fi
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( now - RECORD_TS ))
  [ "$age" -ge 0 ] || return 1
  [ "$age" -lt "$FM_CREW_STATE_DEGRADED_MAX_AGE" ] || return 1
  printf '%s\t%s\t%s' "$RECORD_STATE" "${RECORD_DETAIL:-}" "$age"
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --
# trim, strip_quotes, the bounded nm_run call, nm_field's TOON parse, and the
# branch+head attribution rule below are thin wrappers over the ONE owner in
# bin/fm-nm-run-lib.sh, shared with fm-teardown.sh's pre-teardown run abort.

trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
# Preserve the bounded call's exit status so lookup failure remains distinct
# from a completed lookup that found no attributable run.
nm_run() {  # <args...>
  fm_nm_run_checked "$WT" "$NM_TIMEOUT" "$@"
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  fm_nm_field "$RUN_OUT" "$1"
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

# Status column of a steps[] row, or empty when the run output has no such row.
# The table is TOON, one row per step: "    <step>,<status>,<findings>,<ms>".
nm_step_status() {  # <step-name>
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E "^[[:space:]]*$1,[^,]+,[^,]*," | head -1)
  [ -n "$row" ] || return 0
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

# 0 when the ci step was explicitly skipped, proving the run never observed the forge.
# no-mistakes SKIPS the `pr` and `ci` steps on a project whose forge provider it
# does not recognize - any non-GitHub forge, a self-hosted Gitea for example - so
# the pipeline legitimately reaches outcome=passed on purely LOCAL evidence:
# review, tests, lint, docs and a push, with no pull request opened, no checks
# read, and no merge observed. The terminal `passed` detail is otherwise a fixed
# string that names a merge, so for such a run it asserts a forge outcome nothing
# ever checked - the same class of wrong claim as reporting checks green without
# reading them, and observed live on 2026-08-04 reporting three Gitea PRs merged
# while all three sat open awaiting a human.
#
# Keyed on the `ci` step ALONE, which is the step that observes the terminal
# forge state. Verified against the pipeline's own logs: the pr step CREATES the
# pull request ("creating pull request..." then "created pull request: <url>"),
# while it is ci that watches it to a terminal state ("all CI checks passed -
# still monitoring until merged or closed", ending in "PR has been merged!").
# An unrecognized provider skips both together, which is why the live case had
# both skipped, but `no-mistakes --skip <steps>` can skip them independently - and
# a pr-ran/ci-skipped run observed no more of the forge's verdict than one where
# neither ran. So ci,skipped is by itself sufficient proof that outcome=passed
# never saw a forge outcome, and requiring pr to be skipped too would be narrower
# than the invariant this guards. The converse stays untouched: where ci ran, the
# merge really was observed, whether or not this pipeline opened the PR.
#
# Deliberately a PURE READ of the run output already captured. Teaching this
# verdict to observe the forge itself was the richer option and was rejected:
# fm-crew-state.sh runs on ordinary supervision polls, so it would put a network
# call and a credential read on a hot path, and every forge answer it cached
# would be one more thing that can be stale in a way the caller cannot see. Not
# claiming what was never checked is the whole correction; where the forge HAS
# been observed - the GitHub path, where the ci step actually runs - the
# merged/closed label is unchanged and still earned.
nm_ci_step_skipped() {
  [ "$(nm_step_status ci)" = skipped ]
}

# The ci step's own status, but only while it is mid-flight: an earlier terminal
# row says nothing about what the run is doing now. One owner of the steps[] row
# parse (nm_step_status) rather than a second regex over the same table.
nm_ci_step_status() {
  local s
  s=$(nm_step_status ci)
  case "$s" in running|fixing) printf '%s' "$s" ;; esac
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# A PURE PARSER over a listing the caller already captured. The call itself is
# made by the caller so a listing that could not be fetched is classified as a
# lookup failure there; parsing an empty string here would otherwise report the
# same "no run for this branch" as a listing that genuinely lacks the branch.
nm_runs_row_for_branch() {  # <branch> <runs-listing>
  local branch=$1 out=${2:-} row st rest br sha relation
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    sha=${rest%% *}
    if [ "$br" = "$branch" ]; then
      relation=$(nm_head_relation "$sha")
      case "$relation" in
        equal|run-ahead) printf 'attributable\t%s\t%s' "$st" "$sha" ;;
        unresolved)
          case "$st" in
            running) printf 'inconclusive\t%s\t%s' "$st" "$sha" ;;
            *)       printf 'rejected\t%s\t%s' "$st" "$sha" ;;
          esac
          ;;
        *)              printf 'rejected\t%s\t%s' "$st" "$sha" ;;
      esac
      return 0
    fi
  done <<< "$out"
  return 0
}

# A detached worktree is normal before a just-spawned ship or design worker creates its recorded
# branch and throughout a scout's scratch phase. A named worktree branch is only
# observed placement. The task record's branch= is the tracked-output identity used for
# every run lookup and must agree before the worktree can supply run evidence.
WORKTREE_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if tracked_output_kind && [ -n "$TASK_BRANCH" ] && [ -n "$WORKTREE_BRANCH" ] \
   && [ "$WORKTREE_BRANCH" != "$TASK_BRANCH" ]; then
  runstep_record_clear
  emit unknown run-attribution "task branch mismatch: recorded $TASK_BRANCH, worktree has $WORKTREE_BRANCH"
fi

# Legacy metadata did not record branch=. Its ambient branch may be used only to
# discover whether a run exists that must be surfaced as unattributable. It never
# becomes task identity, and a completed lookup with no run retains the historical
# pane/status-log behavior.
# Past this point the two agree by construction: a named worktree branch that
# differs from a recorded one already emitted the fault above, so LOOKUP_BRANCH
# is the recorded identity whenever there is one and the ambient name otherwise.
LOOKUP_BRANCH=$TASK_BRANCH
[ -n "$LOOKUP_BRANCH" ] || LOOKUP_BRANCH=$WORKTREE_BRANCH

# How a run's recorded head <sha> relates to this worktree's HEAD. The shared
# implementation in bin/fm-nm-run-lib.sh is the one owner of this relationship
# for both current axi status and coarse historical runs-list evidence. It prints:
#   equal       the run head IS the worktree HEAD
#   run-ahead   worktree HEAD is an ancestor of the run head - pipeline fix
#               commits advanced the run tip past what this worktree has read
#   run-behind  the run head is a strict ancestor of the worktree HEAD - the tip
#               advanced past the sha this run recorded
#   unresolved  the sha is not an object in this worktree at all, so no
#               relationship can be computed (the pipeline is committing in a
#               copy this worktree has never fetched from)
#   missing     no sha to judge, or this worktree has no readable HEAD
#   diverged    resolvable but on neither side of the worktree HEAD - a
#               rewritten branch tip
nm_head_relation() {  # <sha>
  fm_nm_head_relation "$WT" "$1"
}

# 0 when a run recorded at <sha> may be attributed to this worktree's current
# code. Branch match is a precondition (caller). <authoring> is 1 only while the
# run sits in an actively-executing step - the states in which the pipeline
# commits its OWN fixes. <branch-scoped> is 1 only for an answer the CLI gave for
# THIS worktree's current branch, never for a row read out of the historical
# runs listing.
#
# `run-behind` is the fix-round case. When a review finding is answered
# `--action fix`, the pipeline commits that fix and the branch tip advances past
# the sha the run recorded; rejecting the row outright made the run that was
# CURRENTLY authoring those commits stop matching its own worktree, and the crew
# read as unknown for the rest of the fix round. An actively-executing run is the
# author of that advance and keeps attribution. A PARKED run is by definition
# waiting on a response and commits nothing, so a tip that advanced past it is
# local work outside the run and must still invalidate - as must a terminal run.
#
# `unresolved` is the pipeline-owned case, and is NOT the same evidence as a
# rewritten tip. While the pipeline owns the branch it commits in its own copy,
# so the head it reports is simply an object this worktree has never fetched;
# refusing it made a crew parked at a live fix_review gate read as having no run
# at all. Only a LIVE run answered for THIS branch earns that benefit: the
# historical runs listing has no notion of "current", so an unresolvable sha
# there stays rejected, and a terminal run's unseen head is evidence of nothing.
# `missing` and `diverged` are always rejected - an absent sha cannot bind, and a
# resolvable sha on neither side of HEAD is a genuinely rewritten branch.
nm_head_attributable() {  # <sha> <authoring:0|1> <branch-scoped-live:0|1>
  fm_nm_head_attributable "$WT" "$1" "${2:-0}" "${3:-0}"
}

run_identity_for_head() {  # <sha>
  local head=$1 canonical
  case "$head" in ''|*[!0-9a-fA-F]*) canonical=$head ;;
    *) canonical=$(git -C "$WT" rev-parse --verify "$head^{commit}" 2>/dev/null) || canonical=$head ;;
  esac
  printf '%s:%s' "$LOOKUP_BRANCH" "$canonical"
}

run_started_after_log_line() {  # <run-id>
  local run_id=${1:-}
  case "$LOG_MTIME" in ''|*[!0-9]*) return 1 ;; esac
  awk -v run_id="$run_id" -v log_mtime="$LOG_MTIME" '
    BEGIN {
      alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
      if (length(run_id) != 26) exit 1
      value = 0
      for (i = 1; i <= 10; i++) {
        digit = index(alphabet, toupper(substr(run_id, i, 1))) - 1
        if (digit < 0) exit 1
        value = value * 32 + digit
      }
      if (int(value / 1000) >= log_mtime) exit 0
      exit 1
    }
  '
}

# 1 when the `axi status` run in $RUN_OUT is in an actively-executing step and so
# able to author pipeline fix commits; 0 for a parked, terminal, or unrecognized
# run. A run parked at a gate reports a plain `running` status in some shapes, so
# the gate markers are checked before the status word.
nm_run_is_authoring() {
  local outcome status
  outcome=$(strip_quotes "$(nm_field outcome)")
  [ -z "$outcome" ] || { printf '0'; return; }
  if printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*awaiting_agent:'; then
    printf '0'; return
  fi
  if nm_has_gate; then printf '0'; return; fi
  status=$(strip_quotes "$(nm_field status)")
  case "$status" in
    awaiting_approval|fix_review) printf '0' ;;
    running|fixing|ci)            printf '1' ;;
    *)                            printf '0' ;;
  esac
}

# 1 when the `axi status` run in $RUN_OUT has not reached a terminal result, so
# it is still this branch's current run whether it is executing or parked at a
# gate. Broader than nm_run_is_authoring on purpose: a run parked at fix_review
# commits nothing right now but is emphatically still live.
nm_run_is_live() {
  local outcome status
  outcome=$(strip_quotes "$(nm_field outcome)")
  [ -z "$outcome" ] || { printf '0'; return; }
  status=$(strip_quotes "$(nm_field status)")
  case "$status" in completed|failed|cancelled) printf '0' ;; *) printf '1' ;; esac
}

# 0 if the axi-status run's head field is attributable to this worktree. The
# caller has already established this answer is for the crew's own branch, which
# is what makes it branch-scoped for the pipeline-owned rule above.
nm_run_head_matches_worktree() {
  nm_head_attributable "$(strip_quotes "$(nm_field head)")" \
    "$(nm_run_is_authoring)" "$(nm_run_is_live)"
}

nm_run_invalidates_record() {
  local relation
  [ "$(nm_run_is_live)" = 0 ] && return 0
  relation=$(nm_head_relation "$(strip_quotes "$(nm_field head)")")
  case "$relation" in
    run-behind|diverged) return 0 ;;
    *) return 1 ;;
  esac
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
COARSE_HEAD=""
COARSE_EVIDENCE=""
# A degraded reason means the current lookup could not establish presence or
# absence for this exact branch. A genuine absence still falls through to the
# pane and status-log sources and clears any recorded run-step.
LOOKUP_DEGRADED_REASON=""
LOOKUP_COMPLETED=0
RUN_ATTRIBUTION_FAULT=""
lookup_coarse_run() {
  local runs_out runs_rc
  runs_out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  runs_rc=$?
  if [ "$runs_rc" != 0 ] || [ -z "$runs_out" ]; then
    LOOKUP_DEGRADED_REASON="run lookup unavailable"
    return
  fi
  COARSE_ROW=$(nm_runs_row_for_branch "$LOOKUP_BRANCH" "$runs_out")
  IFS=$'\t' read -r COARSE_EVIDENCE COARSE_STATUS COARSE_HEAD <<< "$COARSE_ROW"
  case "$COARSE_EVIDENCE" in
    attributable)
      LOOKUP_COMPLETED=1
      if [ -n "$TASK_BRANCH" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      else
        RUN_ATTRIBUTION_FAULT="run on $LOOKUP_BRANCH is unattributable: task branch not recorded"
      fi
      ;;
    inconclusive)
      LOOKUP_DEGRADED_REASON="run head unavailable in worktree"
      ;;
    *)
      LOOKUP_COMPLETED=1
      ;;
  esac
}
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
# A conventional fm/<task-id> task at detached HEAD has not created its branch
# yet, so it still skips the lookup. A task whose recorded branch differs from
# that conventional name is an existing-branch continuation: detached HEAD is
# its expected placement, and the runs listing can bind branch plus commit
# identity without asking branch-scoped `axi status` from a detached checkout.
if tracked_output_kind && [ -n "$WORKTREE_BRANCH" ] && [ -n "$LOOKUP_BRANCH" ] \
   && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  nm_rc=$?
  # Empty stdout is a failure, not an absence: `axi status` answers a branch with
  # no run of its own with some OTHER branch's run as informational display (the
  # cross-branch case the coarse fallback below exists for), so it has no
  # "nothing to report" empty answer to confuse this with.
  if [ "$nm_rc" != 0 ] || [ -z "$RUN_OUT" ]; then
    RUN_OUT=""
    LOOKUP_DEGRADED_REASON="run lookup unavailable"
  else
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$LOOKUP_BRANCH" ]; then
      if nm_run_head_matches_worktree; then
        LOOKUP_COMPLETED=1
        if [ -n "$TASK_BRANCH" ]; then
          HAVE_RUN=1
        else
          RUN_ATTRIBUTION_FAULT="run on $run_branch is unattributable: task branch not recorded"
        fi
      elif nm_run_invalidates_record; then
        runstep_record_clear
      fi
    fi
    if [ "$HAVE_RUN" = 0 ] && [ -z "$RUN_ATTRIBUTION_FAULT" ]; then
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately reached only when the primary call ANSWERED: a timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      lookup_coarse_run
    fi
  fi
elif tracked_output_kind && [ -z "$WORKTREE_BRANCH" ] \
   && [ -n "$TASK_BRANCH" ] && [ "$TASK_BRANCH" != "fm/$ID" ] \
   && command -v no-mistakes >/dev/null 2>&1; then
  lookup_coarse_run
fi

if [ -n "$RUN_ATTRIBUTION_FAULT" ]; then
  runstep_record_clear
  emit unknown run-attribution "$RUN_ATTRIBUTION_FAULT"
fi

if [ "$LOOKUP_COMPLETED" = 1 ] && [ "$HAVE_RUN" = 0 ]; then
  runstep_record_clear
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  RUN_ID="-"
  RUN_ALIAS="-"
  MERGE_OBSERVED=0
  if [ "$RUN_SOURCE" = coarse ]; then
    RUN_ID="-"
    RUN_ALIAS=$(run_identity_for_head "$COARSE_HEAD")
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
    runstep_record_load || true
    if [ "$RECORD_VERSION" = v3 ] \
      && [ "$RECORD_RUN_ALIAS" = "$RUN_ALIAS" ]; then
      if [ "$RUN_STATE" = "done" ] \
        && [ "$RECORD_MERGE_OBSERVED" = 1 ]; then
        MERGE_OBSERVED=1
      fi
    fi
  else
    RUN_ID=$(strip_quotes "$(nm_field id)")
    [ -n "$RUN_ID" ] || RUN_ID="-"
    RUN_ALIAS=$(run_identity_for_head "$(strip_quotes "$(nm_field head)")")
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)
          RUN_STATE="done"
          if [ "$(nm_step_status ci)" = completed ]; then
            MERGE_OBSERVED=1
            RUN_DETAIL="run passed: PR merged/closed"
          elif nm_ci_step_skipped; then
            RUN_DETAIL="local pipeline passed (ci step skipped - forge state not observed)"
          else
            RUN_DETAIL="local pipeline passed (ci step not completed - forge state not observed)"
          fi
          ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  refresh_log_snapshot

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      runstep_record_emit "done" status-log \
        "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR" \
        "$RUN_ID" "$RUN_ALIAS" "$MERGE_OBSERVED"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      runstep_record_emit "done" status-log \
        "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR" \
        "$RUN_ID" "$RUN_ALIAS" "$MERGE_OBSERVED"
    fi
  fi

  # Terminal run-step verdicts describe the pipeline's last observed gate
  # outcome, not what the crew is waiting on now. A declared pause or
  # captain-held line recorded after that terminal state is newer information -
  # the finish is exactly what prompted the park. Honor it unless the run
  # genuinely observed a forge merge (outcome=passed with ci completed), where
  # any wait over it is deterministically stale.
  terminal_done_is_observed_merge() {
    [ "$RUN_STATE" = "done" ] && [ "$MERGE_OBSERVED" = 1 ]
  }
  declared_wait_follows_terminal_record() {
    runstep_record_load || return 0
    case "${RECORD_TS:-}" in ''|*[!0-9]*) return 0 ;; esac
    [ "$RECORD_VERSION" = v3 ] || return 0
    case "${RECORD_POSITION:-}" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$RUN_ID" != "-" ] && [ "$RECORD_RUN_ID" != "-" ]; then
      if [ "$RECORD_RUN_ID" != "$RUN_ID" ]; then
        run_started_after_log_line "$RUN_ID" && return 1
        return 0
      fi
    else
      [ "$RECORD_RUN_ALIAS" = "$RUN_ALIAS" ] || return 0
    fi
    [ "$LOG_POSITION" -gt "$RECORD_POSITION" ]
  }
  if { [ "$RUN_STATE" = "done" ] || [ "$RUN_STATE" = failed ]; } \
    && status_is_paused_or_captain_held "$LOG_LINE" \
    && declared_wait_follows_terminal_record \
    && ! terminal_done_is_observed_merge; then
    WAIT_BOUNDARY_POSITION=$(( LOG_POSITION > 0 ? LOG_POSITION - 1 : 0 ))
    runstep_record_write "$RUN_STATE" "$RUN_DETAIL" \
      "$RUN_ID" "$RUN_ALIAS" "$MERGE_OBSERVED" "$WAIT_BOUNDARY_POSITION"
    emit paused status-log "$(status_line_note "$LOG_LINE")${SEP}$RUN_DETAIL"
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  # Worker-liveness cross-check (issue #105). Run-step alone is no longer
  # sufficient evidence of a working task: the no-mistakes daemon can keep
  # advancing a run after the worker has exited cleanly, and the next gate,
  # the next synchronous tool return, and the next push/pr/ci step all need
  # a worker that is not there. Apply the liveness cross-check computed once
  # at the top. Only `working` is downgraded: `done`, `failed`, and `parked`
  # either do not need a worker or already surface (parked falls through to
  # the status-log fallback path). A liveness read that cannot complete is
  # `unknown`, never `alive` and never `dead`; an unverified backend has no
  # recovery classifier so the verdict keeps its current shape there.
  if [ "$RUN_STATE" = working ]; then
    IFS=$'\t' read -r RUN_STATE liveness_note <<< "$(working_after_liveness)"
    RUN_DETAIL="$RUN_DETAIL$liveness_note"
  fi

  # Remember this verdict so a later lookup that cannot complete degrades to it
  # instead of collapsing to unknown. Recorded from the authoritative run-step
  # path only, so nothing but a genuinely observed run is ever replayed.
  # `abandoned` is now a recorded state, so a later lookup failure degrades to
  # the same actionable verdict instead of replaying a stale `working` answer.
  runstep_record_emit "$RUN_STATE" run-step "$RUN_DETAIL" \
    "$RUN_ID" "$RUN_ALIAS" "$MERGE_OBSERVED"
fi

# --- fallback: no run attributed to this crew ------------------------------
if [ "$KIND" = scout ] && [ "$(meta_value decisions_reviewed)" = 1 ]; then
  emit "done" completion-attestation "unresolved-decision inventory reviewed"
fi

# The run-step path above already handled any crew with an attributed run,
# regardless of pane liveness, so a finished-but-pane-closed crew never reaches
# here. Down here either the lookup completed and found no run, or it could not
# complete at all; in both cases there is no live run to consult, so a
# dead/unreadable target means the crew is gone: report unknown rather than
# trusting a possibly-stale status log - or a remembered run-step - as the
# current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown - deferred rather than emitted here
# only so the degraded run-step below can answer first; it still outranks the
# status-log fallback exactly as before.
BUSY_STATE=""
BUSY_VERDICT=""
if [ "$KIND" != secondmate ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy)
      # The harness's own busy record says the worker is processing a turn.
      # Apply the same worker-liveness cross-check the run-step path uses:
      # a stale busy record after a clean worker exit is the same false
      # reassurance issue #105 is fixing, so the same downgrade applies.
      busy_detail="harness busy (${BUSY_VERDICT#* })"
      IFS=$'\t' read -r busy_state liveness_note <<< "$(working_after_liveness)"
      emit "$busy_state" pane "$busy_detail$liveness_note"
      ;;
    idle) BUSY_STATE=idle ;;
    *)    BUSY_STATE=unknown ;;
  esac
fi

# The run lookup is inconclusive, and this crew has a recent run-step on record:
# report that last known step, degraded, rather than unknown. Bounded by
# FM_CREW_STATE_DEGRADED_MAX_AGE so a permanently unreachable daemon stops
# absorbing wedge suspicion instead of hiding it forever, and never reached at
# all on a completed lookup that simply found no run.
#
# Placement is the safety property. It sits BELOW the endpoint checks and the
# exact busy verdict, so live positive evidence - a gone endpoint proving the
# crew stopped, or a busy harness proving it is working right now - always
# outranks a remembered step. It sits ABOVE the unreadable-harness and
# status-log fallbacks, which is the whole point: an observed run-step, even one
# that could not be re-confirmed this poll, is better current-state evidence
# than an append-only event log. A replayed working step still goes through
# working_after_liveness, because a record written while the worker was alive
# is not evidence that the worker is still there (issue #111).
if [ -n "$LOOKUP_DEGRADED_REASON" ]; then
  if DEGRADED=$(runstep_record_read); then
    IFS=$'\t' read -r deg_state deg_detail deg_age <<< "$DEGRADED"
    deg_line=$LOOKUP_DEGRADED_REASON
    [ -n "$deg_detail" ] && deg_line="$deg_detail${SEP}$deg_line"
    if [ "$deg_state" = working ]; then
      IFS=$'\t' read -r deg_state liveness_note <<< "$(working_after_liveness)"
      deg_line="$deg_line$liveness_note"
    fi
    emit "$deg_state" run-step-degraded "$deg_line (last known ${deg_age}s ago)"
  fi
fi

if [ "$BUSY_STATE" = unknown ]; then
  emit unknown pane "harness state unavailable ($BUSY_VERDICT)"
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
