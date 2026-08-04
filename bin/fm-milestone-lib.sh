#!/usr/bin/env bash
# fm-milestone-lib.sh - the single owner of the work-item lifecycle vocabulary.
#
# One vocabulary drives every surface firstmate keeps true, so the living status
# comment (bin/fm-issue-comment.sh), the captain's project board
# (bin/fm-project-board.sh), and the fan-out that records a milestone on both
# (bin/fm-work-item-milestone.sh) cannot hold different opinions about which
# tokens exist. A token any one of them did not know used to be a usage error
# raised from whichever surface happened to run first, which is how a documented
# milestone became unreachable through the fan-out.
#
# fm_milestone_label <token> prints the phase label a reader sees and fails on an
# unknown token, which is also how a caller's milestone argument is validated.
# FM_MILESTONE_LABELS is those labels in the same order, for reading back a
# timeline this code published.
#
# What each surface DOES with a milestone stays with that surface: the board's
# milestone-to-status-option mapping is the board's business, and the comment's
# rendering is the comment's.
#
# No side effects on source. set -u / set -e safe.

# shellcheck disable=SC2034  # Read by sourcing scripts, which shellcheck cannot see.
FM_MILESTONE_TOKENS='queued dispatched implemented validated in-review landed blocked stopped'

fm_milestone_label() {  # <token> -> prints the rendered phase label
  case "$1" in
    queued) printf 'queued\n' ;;
    dispatched) printf 'dispatched\n' ;;
    implemented) printf 'implementation committed\n' ;;
    validated) printf 'validated\n' ;;
    in-review) printf 'in review\n' ;;
    landed) printf 'landed\n' ;;
    blocked) printf 'blocked\n' ;;
    stopped) printf 'stopped\n' ;;
    *) return 1 ;;
  esac
}

# The rendered labels, in the same order, alternated for a regular expression.
# shellcheck disable=SC2034  # Read by sourcing scripts, which shellcheck cannot see.
FM_MILESTONE_LABELS='queued|dispatched|implementation committed|validated|in review|landed|blocked|stopped'
