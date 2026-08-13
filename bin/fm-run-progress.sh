#!/usr/bin/env bash
# fm-run-progress.sh - is a crew's validation run MOVING, or is it stranded?
#
# bin/fm-crew-state.sh answers "does this crew have an active run", which is not
# the same question. A run reporting `running` can be healthy (a review or test
# step legitimately working for ten to eighteen minutes while emitting one
# opening line) or dead on its feet (a test step stranded on that opening line
# with a live but idle agent; a `ci` step that orphaned and left the run
# reporting `running` for days). Supervision needs to tell those apart before it
# either raises a wedge alarm on a healthy parked worker or swallows a real one,
# so `status: running` is deliberately NOT accepted here as evidence of health -
# only observed PROGRESS is.
#
# The evidence is the pipeline's own, from `no-mistakes axi status`:
#
#   active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
#     test,running,7m9s,"7m4s ago: log: I'll start by reading the change.","2698359",starting
#
# `last_activity` carries how long ago the step last logged anything, and the
# pipeline prefixes it with `quiet` once that exceeds its own
# `step_quiet_warning` (10m by default). A step that has never logged has no
# such age, so its silence is exactly how long it has been active - `active_for`
# is the fallback, which is what makes the orphaned-`ci` case measurable.
#
# Usage:
#   fm-run-progress.sh <task-id>
#
# Prints exactly one line, always exits 0 on a successful read (exit 2 only on a
# usage error):
#
#   progress: progressing · <detail>   an actively-executing step reported
#                                      activity inside the stranded bound
#   progress: stranded · <detail>      every actively-executing step has been
#                                      silent for at least the stranded bound
#   progress: none · <detail>          no evidence either way
#
# `none` is the answer for a crew with no metadata, no worktree, no no-mistakes,
# a lookup that could not complete, no attributed run, a run parked at a gate or
# already terminal, and any output this cannot parse. It carries NO claim about
# the crew, which is why every consumer must treat it as "no proof of progress"
# and behave exactly as it did before consulting this script. Only
# `progressing` may ever quiet an alarm.
#
# This script writes nothing and never touches the crew, its run, or its
# worktree.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-run-progress.sh <task-id>" >&2; exit 2; }

# --- the threshold that separates slow from stranded ------------------------
#
# FM_RUN_STRANDED_SILENCE_SECS is how long an actively-executing pipeline step
# may report NO activity before firstmate stops treating the run as evidence
# that its worker is healthy. It is the whole judgement this script exists to
# make, so it is a named value with its reasoning attached rather than a
# constant buried in a comparison. Move it deliberately:
#
#   * The pipeline's own `step_quiet_warning` is 10m, and axi status prefixes
#     `last_activity` with `quiet` past it. That marker is deliberately a
#     WARNING, not a verdict - no-mistakes' own guidance calls it "a liveness
#     clue, not permission to cancel" - because review and test steps routinely
#     emit one opening line and then work silently for ten to eighteen minutes.
#     Escalating at the pipeline's warning would re-raise the false alarms this
#     bound exists to stop.
#   * 30 minutes is three times that warning and comfortably past the longest
#     healthy silence observed (18m). It is also the point at which a real
#     stranded test step - nineteen minutes on its opening line with a live but
#     idle agent, 2026-08-05 - was judged stranded and aborted, so the bound
#     matches the call an operator already makes by hand.
#   * A `ci` step that orphans and leaves a run reporting `running` for days
#     clears this bound by a wide margin and still alarms.
#
# Raising it delays a real wedge alarm by the same amount; lowering it toward
# 10m starts alarming on healthy silent steps again.
FM_RUN_STRANDED_SILENCE_SECS=${FM_RUN_STRANDED_SILENCE_SECS:-1800}
case "$FM_RUN_STRANDED_SILENCE_SECS" in ''|*[!0-9]*) FM_RUN_STRANDED_SILENCE_SECS=1800 ;; esac

# Bound on the `axi status` read, for the same reason bin/fm-crew-state.sh
# bounds its own: a saturated daemon must cost one timeout, not a stuck watcher.
NM_TIMEOUT=${FM_RUN_PROGRESS_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac

SEP=' · '

emit() {  # <class> [detail]
  local line="progress: $1"
  [ -n "${2:-}" ] && line="$line${SEP}$2"
  printf '%s\n' "$line"
  exit 0
}

# --- crew resolution --------------------------------------------------------

META="$STATE/$ID.meta"
[ -f "$META" ] || emit none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship

# Only a ship or design task drives a no-mistakes validation of its own
# worktree; a scout or secondmate has no run to be progressing, and asking
# costs a bounded call for a guaranteed answer.
case "$KIND" in
  ship|design) ;;
  *) emit none "kind=$KIND runs no validation" ;;
esac
[ -n "$WT" ] && [ -d "$WT" ] || emit none "worktree gone (torn down?)"
command -v no-mistakes >/dev/null 2>&1 || emit none "no-mistakes not installed"

# --- bounded read -----------------------------------------------------------
# Bounded through bin/fm-timeout-lib.sh, the declared single owner of bounded
# external command execution, rather than a third hand-rolled copy of the
# ladder. That matters for correctness, not tidiness: the owner carries a perl
# arm, and a stock macOS host ships neither timeout nor gtimeout, so a
# two-rung ladder would answer `none` on every call there - leaving this whole
# gate inert on a first-class platform while bin/fm-crew-state.sh read the same
# run fine through its own perl arm.
#
# fm_run_timed's documented 125 means no bounded runner could start, so nothing
# was executed: with no way to bound the call at all, do not make it. Every
# other failure is a read that did not complete. Both are NO EVIDENCE, which is
# `none` and leaves the alarm exactly as it was - never a hold.
RUN_OUT=$( ( cd "$WT" && fm_run_timed "$NM_TIMEOUT" no-mistakes axi status ) 2>/dev/null )
READ_RC=$?
[ "$READ_RC" != 125 ] || emit none "no way to bound the status read"
[ -n "$RUN_OUT" ] || emit none "status read did not complete"

# The answer must be about THIS crew's branch. `axi status` answers a branch
# with no run of its own by displaying some other branch's run, and that run's
# active steps say nothing about this worktree.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
RUN_BRANCH=$(printf '%s\n' "$RUN_OUT" | sed -n 's/^[[:space:]]*branch:[[:space:]]*\(.*\)/\1/p' | head -1)
RUN_BRANCH=${RUN_BRANCH%\"}; RUN_BRANCH=${RUN_BRANCH#\"}
RUN_BRANCH=${RUN_BRANCH%"${RUN_BRANCH##*[![:space:]]}"}
if [ -z "$CREW_BRANCH" ] || [ -z "$RUN_BRANCH" ] || [ "$CREW_BRANCH" != "$RUN_BRANCH" ]; then
  emit none "no run attributed to this crew's branch"
fi

# --- duration parsing -------------------------------------------------------

# Whole seconds in a compact Go-style duration ("45s", "7m9s", "1h2m", "3d4h",
# "900ms"). Prints nothing and returns 1 for anything else, which callers treat
# as no evidence rather than as zero.
duration_secs() {  # <text>
  local t=$1 total=0 num unit rest
  [ -n "$t" ] || return 1
  # Sub-second durations round to zero rather than mis-parsing "900ms" as
  # minutes-then-seconds.
  case "$t" in
    *ms) num=${t%ms}
         case "$num" in ''|*[!0-9]*) return 1 ;; esac
         printf '0'; return 0 ;;
  esac
  while [ -n "$t" ]; do
    num=""
    while :; do
      case "$t" in
        [0-9]*) num="$num${t%"${t#?}"}"; t=${t#?} ;;
        *) break ;;
      esac
    done
    [ -n "$num" ] || return 1
    unit=${t%"${t#?}"}
    rest=${t#?}
    case "$unit" in
      d) total=$(( total + num * 86400 )) ;;
      h) total=$(( total + num * 3600 )) ;;
      m) total=$(( total + num * 60 )) ;;
      s) total=$(( total + num )) ;;
      *) return 1 ;;
    esac
    t=$rest
  done
  printf '%s' "$total"
}

# --- active_steps table -----------------------------------------------------

# Split one TOON table row into fields, one per line, honoring double-quoted
# fields that may themselves contain commas (`last_activity` routinely does).
split_row() {  # <row>
  local row=$1 len i ch cur='' inq=0
  len=${#row}
  i=0
  while [ "$i" -lt "$len" ]; do
    ch=${row:i:1}
    if [ "$inq" = 1 ]; then
      if [ "$ch" = '"' ]; then inq=0; else cur="$cur$ch"; fi
    elif [ "$ch" = '"' ]; then
      inq=1
    elif [ "$ch" = ',' ]; then
      printf '%s\n' "$cur"; cur=''
    else
      cur="$cur$ch"
    fi
    i=$(( i + 1 ))
  done
  printf '%s\n' "$cur"
}

# 1-based position of <name> in a comma-separated TOON field list, or nothing.
field_index() {  # <field-list> <name>
  local list=$1 name=$2 i=1 f
  while [ -n "$list" ]; do
    case "$list" in
      *,*) f=${list%%,*}; list=${list#*,} ;;
      *)   f=$list; list='' ;;
    esac
    [ "$f" = "$name" ] && { printf '%s' "$i"; return 0; }
    i=$(( i + 1 ))
  done
  return 1
}

HEADER=$(printf '%s\n' "$RUN_OUT" | grep -nE '^[[:space:]]*active_steps\[[0-9]+\]\{[^}]*\}:' | head -1)
[ -n "$HEADER" ] || emit none "no actively-executing step (run parked, terminal, or between steps)"
HEADER_LINE=${HEADER%%:*}
HEADER_TEXT=${HEADER#*:}
ROW_COUNT=$(printf '%s' "$HEADER_TEXT" | sed -n 's/^[[:space:]]*active_steps\[\([0-9]*\)\].*/\1/p')
FIELDS=$(printf '%s' "$HEADER_TEXT" | sed -n 's/^[^{]*{\([^}]*\)}.*/\1/p')
case "$ROW_COUNT" in ''|*[!0-9]*) emit none "unreadable active_steps header" ;; esac
[ "$ROW_COUNT" -gt 0 ] || emit none "no actively-executing step (run parked, terminal, or between steps)"

I_STEP=$(field_index "$FIELDS" step) || emit none "active_steps header has no step field"
I_STATUS=$(field_index "$FIELDS" status) || emit none "active_steps header has no status field"
I_ACTIVE=$(field_index "$FIELDS" active_for) || emit none "active_steps header has no active_for field"
I_LAST=$(field_index "$FIELDS" last_activity) || emit none "active_steps header has no last_activity field"

# The declared row count is what bounds the table: the rows that follow the
# header are exactly the next $ROW_COUNT lines, so a sibling key underneath can
# never be read as a row.
ROWS=$(printf '%s\n' "$RUN_OUT" | sed -n "$(( HEADER_LINE + 1 )),$(( HEADER_LINE + ROW_COUNT ))p")

BEST_SILENCE=""
BEST_DETAIL=""
WORST_SILENCE=""
WORST_DETAIL=""

while IFS= read -r row; do
  [ -n "$row" ] || continue
  fields=$(split_row "$row")
  n=0; step=""; status=""; active_for=""; last_activity=""; silence=""; phrase=""; detail=""; la=""
  while IFS= read -r fval; do
    n=$(( n + 1 ))
    # Field values arrive already unquoted; only the leading/trailing spaces of
    # the row's own layout need trimming.
    fval=${fval#"${fval%%[![:space:]]*}"}
    fval=${fval%"${fval##*[![:space:]]}"}
    [ "$n" = "$I_STEP" ] && step=$fval
    [ "$n" = "$I_STATUS" ] && status=$fval
    [ "$n" = "$I_ACTIVE" ] && active_for=$fval
    [ "$n" = "$I_LAST" ] && last_activity=$fval
  done <<EOF
$fields
EOF

  # Only a step that is actually EXECUTING can be progressing. A gate row is a
  # run waiting on its worker, which is the opposite of evidence that the
  # worker is alive.
  case "$status" in running|fixing|ci) ;; *) continue ;; esac

  # `quiet <dur> ago: ...` is the pipeline's own past-step_quiet_warning
  # rendering of the same field; the age it carries is what matters here, not
  # the marker.
  la=$last_activity
  case "$la" in quiet\ *) la=${la#quiet } ;; esac
  silence=""
  phrase=""
  case "$la" in
    *' ago'*)
      silence=$(duration_secs "${la%% ago*}") || silence=""
      [ -n "$silence" ] && phrase="last activity ${la%% ago*} ago"
      ;;
  esac
  # A step that has never logged has no activity age at all, so the time it has
  # been silent is exactly how long it has been active. This is the reading
  # that makes an orphaned step measurable instead of invisible.
  if [ -z "$silence" ]; then
    silence=$(duration_secs "$active_for") || silence=""
    [ -n "$silence" ] && phrase="no activity in $active_for"
  fi
  [ -n "$silence" ] || continue

  detail="$step $status, $phrase"
  if [ -z "$BEST_SILENCE" ] || [ "$silence" -lt "$BEST_SILENCE" ]; then
    BEST_SILENCE=$silence; BEST_DETAIL=$detail
  fi
  if [ -z "$WORST_SILENCE" ] || [ "$silence" -gt "$WORST_SILENCE" ]; then
    WORST_SILENCE=$silence; WORST_DETAIL=$detail
  fi
done <<EOF
$ROWS
EOF

[ -n "$BEST_SILENCE" ] || emit none "no readable activity on any executing step"

# Any executing step that moved recently proves the run as a whole is moving,
# so the SHORTEST silence decides; the longest is what gets named when nothing
# moved, because that is the step to look at.
if [ "$BEST_SILENCE" -lt "$FM_RUN_STRANDED_SILENCE_SECS" ]; then
  emit progressing "$BEST_DETAIL (silent ${BEST_SILENCE}s, bound ${FM_RUN_STRANDED_SILENCE_SECS}s)"
fi
emit stranded "$WORST_DETAIL (silent ${WORST_SILENCE}s, past the ${FM_RUN_STRANDED_SILENCE_SECS}s bound)"
