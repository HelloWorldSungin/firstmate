#!/usr/bin/env bash
# Record one lifecycle milestone against a task's work item, on every surface
# firstmate keeps true.
#
# Usage: fm-work-item-milestone.sh <task-id> --milestone <token>
#                                            [--note <text> | --note-file <path>]
#                                            [--dry-run]
#
# There is ONE lifecycle vocabulary, owned by bin/fm-milestone-lib.sh, and this
# is where it fans out, so the living status comment and the captain's project
# board can never drift into two different opinions about where a task stands:
#
#   bin/fm-issue-comment.sh   the living status comment on the work item
#   bin/fm-project-board.sh   board membership and the board's Status field
#
# Milestones: queued dispatched implemented validated in-review landed blocked
#             stopped
#   queued      the work item is accepted and waiting for a worker
#   dispatched  the task is under way
#   implemented the change is committed and about to be validated
#   validated   validation finished (the note carries the outcome)
#   in-review   the PR is open and waiting on its merge authority
#   landed      the PR is merged
#   blocked     work has stopped pending something outside the task
#   stopped     work was abandoned or superseded
#
# bin/fm-spawn.sh, bin/fm-pr-check.sh, and bin/fm-pr-merge.sh call this for
# dispatched, in-review, and landed themselves, so the milestones that matter
# most never depend on anyone remembering. Firstmate posts the rest as the work
# moves, with a note written for a human reading the issue.
#
# BOUNDED AS ONE OPERATION. Every surface bounds its own calls, but a caller runs
# THIS command, so the bound that matters is the one on the whole fan-out:
# FM_WORK_ITEM_MILESTONE_TIMEOUT seconds (default 40), of which the comment
# surface may spend at most half and the board surface gets the rest. That is
# what keeps decoration from adding minutes to a dispatch or a merge on a
# black-holing network, where per-call bounds alone would simply add up. Each
# share is handed down as FM_WRITE_BACK_BUDGET so the surface spends it across
# its own calls and reports its own outcome; the bound around it is only a
# backstop for a surface stuck somewhere other than a forge call.
#
# INDEPENDENT SURFACES. Every argument is validated HERE, before either surface
# runs, so a caller's mistake is one usage error with nothing written rather than
# one surface refusing and taking the other down with it. After that, neither
# surface's exit status can stop or fail the other, or this command: each failure
# is a warning on stderr and the fan-out still exits 0, so a milestone can never
# block or fail dispatch, validation, merge, or cleanup. A non-zero exit means
# the CALLER passed something invalid.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-milestone-lib.sh
. "$SCRIPT_DIR/fm-milestone-lib.sh"

BUDGET=${FM_WORK_ITEM_MILESTONE_TIMEOUT:-40}
case "$BUDGET" in
  ''|*[!0-9]*|0) BUDGET=40 ;;
esac

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -ge 1 ] || { usage >&2; exit 1; }
ID=$1
shift
case "$ID" in
  ''|-*) usage >&2; exit 1 ;;
esac

note_file_valid() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ] && return 0
  echo "error: --note-file must be a regular file" >&2
  return 1
}

MILESTONE=
DRY_RUN=0
COMMENT_ARGS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      milestone) MILESTONE=$a ;;
      note-file) note_file_valid "$a" || exit 1 ;;
    esac
    COMMENT_ARGS+=("--$want_value" "$a")
    want_value=
    continue
  fi
  case "$a" in
    --milestone|--note|--note-file) want_value=${a#--} ;;
    --milestone=*) MILESTONE=${a#--milestone=}; COMMENT_ARGS+=("$a") ;;
    --note=*) COMMENT_ARGS+=("$a") ;;
    --note-file=*) note_file_valid "${a#--note-file=}" || exit 1; COMMENT_ARGS+=("$a") ;;
    --dry-run) DRY_RUN=1; COMMENT_ARGS+=("$a") ;;
    *) echo "error: unknown argument $a" >&2; exit 1 ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ -n "$MILESTONE" ] || { echo "error: --milestone is required (one of: $FM_MILESTONE_TOKENS)" >&2; exit 1; }
fm_milestone_label "$MILESTONE" >/dev/null \
  || { echo "error: --milestone must be one of: $FM_MILESTONE_TOKENS (got '$MILESTONE')" >&2; exit 1; }

# Every surface runs under its own share of the one budget and reports its own
# outcome. Nothing here returns non-zero: by this point the arguments are valid,
# so anything that goes wrong is a forge failing, which is decoration failing.
#
# The share is handed DOWN as FM_WRITE_BACK_BUDGET so the surface spends it
# across its own calls and exits cleanly with its own warning. The bound around
# it is a backstop with a couple of seconds of grace for the case that budget
# cannot cover: a surface wedged somewhere other than a forge call.
SURFACE_GRACE=2
run_surface() {  # <label> <seconds> <command...>
  local label=$1 seconds=$2 rc=0
  shift 2
  [ "$seconds" -ge 1 ] || seconds=1
  export FM_WRITE_BACK_BUDGET=$seconds
  fm_run_timed "$(( seconds + SURFACE_GRACE ))" "$@" || rc=$?
  case "$rc" in
    0) ;;
    124|137)
      printf 'warning: %s did not finish within its share of the %ss milestone budget, so it may not show this milestone\n' \
        "$label" "$BUDGET" >&2
      ;;
    125)
      # No bounded runner exists on this machine, so nothing ran at all. Each
      # surface bounds its own forge calls through the same library and reports
      # the same absence, so running it directly cannot hang either.
      rc=0
      "$@" || rc=$?
      [ "$rc" -eq 0 ] \
        || printf 'warning: %s could not be updated (exit %s)\n' "$label" "$rc" >&2
      ;;
    *)
      printf 'warning: %s could not be updated (exit %s)\n' "$label" "$rc" >&2
      ;;
  esac
  return 0
}

SECONDS=0
# Half the budget is reserved for the board so a slow tracker cannot starve it;
# whatever the comment surface leaves unspent goes to the board as well.
run_surface 'the work item status comment' "$(( BUDGET / 2 ))" \
  "$SCRIPT_DIR/fm-issue-comment.sh" status "$ID" "${COMMENT_ARGS[@]}"

board_args=(sync --task "$ID" --milestone "$MILESTONE")
[ "$DRY_RUN" -eq 0 ] || board_args+=(--dry-run)
run_surface 'the project board' "$(( BUDGET - SECONDS ))" \
  "$SCRIPT_DIR/fm-project-board.sh" "${board_args[@]}"
exit 0
