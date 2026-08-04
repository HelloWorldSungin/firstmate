#!/usr/bin/env bash
# Record one lifecycle milestone against a task's work item, on every surface
# firstmate keeps true.
#
# Usage: fm-work-item-milestone.sh <task-id> --milestone <token>
#                                            [--note <text> | --note-file <path>]
#                                            [--dry-run]
#
# There is ONE lifecycle vocabulary and this is where it fans out, so the living
# status comment and the captain's project board can never drift into two
# different opinions about where a task stands:
#
#   bin/fm-issue-comment.sh   the living status comment on the work item
#   bin/fm-project-board.sh   board membership and the board's Status field
#
# Milestones: dispatched implemented validated in-review landed blocked stopped
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
# Each surface fails open on its own: an unreachable, unauthenticated, or
# rate-limited GitHub warns on stderr and this command still exits 0, so a
# milestone can never block or fail dispatch, validation, merge, or cleanup. One
# surface failing never stops the other from being updated. A non-zero exit means
# the CALLER passed something invalid.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

MILESTONE=
DRY_RUN=0
COMMENT_ARGS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      milestone) MILESTONE=$a ;;
    esac
    COMMENT_ARGS+=("$a")
    want_value=
    continue
  fi
  case "$a" in
    --milestone) want_value=milestone; COMMENT_ARGS+=("$a") ;;
    --milestone=*) MILESTONE=${a#--milestone=}; COMMENT_ARGS+=("$a") ;;
    --dry-run) DRY_RUN=1; COMMENT_ARGS+=("$a") ;;
    *) COMMENT_ARGS+=("$a") ;;
  esac
done
[ -n "$MILESTONE" ] || { echo "error: --milestone is required" >&2; exit 1; }

# The comment owner validates the shared vocabulary and the note's content, so a
# usage error surfaces from there rather than being duplicated here.
"$SCRIPT_DIR/fm-issue-comment.sh" status "$ID" "${COMMENT_ARGS[@]}" || exit $?

board_args=(sync --task "$ID" --milestone "$MILESTONE")
[ "$DRY_RUN" -eq 0 ] || board_args+=(--dry-run)
"$SCRIPT_DIR/fm-project-board.sh" "${board_args[@]}" || exit $?
exit 0
