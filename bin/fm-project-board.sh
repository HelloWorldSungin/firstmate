#!/usr/bin/env bash
# The captain's GitHub Projects boards, kept true.
#
# Usage: fm-project-board.sh sync --task <task-id> --milestone <token> [--dry-run]
#        fm-project-board.sh sync --issue <url> [--milestone <token>] [--dry-run]
#        fm-project-board.sh reconcile [--project <name>] [--limit <n>] [--dry-run] [--quiet]
#        fm-project-board.sh show [--project <name>] [--dry-run]
#
# A board is the captain's visualization of current status across individual
# works and across epics. It is a second surface over the same issues, not a
# second source of truth.
#
# TWO BEHAVIOURS, AND ONLY ONE OF THEM COVERS THE FLEET.
#
# `sync` is the LIFECYCLE update: it moves the item for a task firstmate is
# running as that task progresses, driven by the SAME milestone vocabulary that
# drives the living status comment (bin/fm-issue-comment.sh), so the two surfaces
# cannot disagree about where a task stands. It only ever knows about work
# firstmate dispatched.
#
# `reconcile` is the DRIFT sweep, and it is the one the fleet actually needs.
# Most items on these boards were never firstmate tasks, so no amount of
# lifecycle updating can find their drift: on 2026-08-04 the Ark-Signal board
# carried 222 ArkNode-AI items, 146 of them closed, and three had drifted - two
# closed issues still sitting in `In progress` and one in `Backlog` - all of them
# work firstmate never touched. The sweep reconciles what is knowable for such an
# item and no more: every tracker issue is a board member, a closed issue reads
# `Done`, and an open issue never does. Closed-versus-open is the ONLY truth
# available for work firstmate did not dispatch, so no finer state is invented.
#
# OWNERSHIP MEANS KEEPING A BOARD TRUE, NOT RESHAPING IT. bin/fm-board-lib.sh is
# the single owner of the complete wire surface, and its two write operations -
# board membership, and the Status field's value on an item - are the whole of
# what this script can do to a board. Nothing creates, renames, or deletes a
# view, filter, field, or status option, and nothing removes an item, including
# an item a human added by hand that no tracker issue matches: the sweep leaves
# it exactly where it is.
#
# A FIELD'S OPTION SET IS NEVER TOUCHED, AND THAT IS A HARD SAFETY RULE RATHER
# THAN A MATTER OF TASTE. `updateProjectV2Field` replaces a single-select field's
# WHOLE option set and reassigns every option id, which detaches every item
# already using them: adding one `Blocked` option to the real firstmate board
# blanked the status of all twenty items instantly. So a board whose Status field
# has no option matching the status a milestone or a closed issue calls for is
# REPORTED and left alone, and the option is the captain's to add by hand.
#
# MEMBERSHIP AND EPICS. Every work item firstmate tracks belongs on the board,
# because an issue missing from it makes the board lie by omission. When a story
# has a parent issue, `sync` ensures that parent is a board member too, so the
# captain can read the epic level through the parent/sub-issue relationship
# GitHub already models. No epic status is computed here: rolling story states up
# into an epic's status is its own design question, and GitHub's native sub-issue
# progress already answers the common form of it without a parallel scheme.
#
# WHICH BOARD. bin/fm-board-lib.sh owns board identity and states the rule in
# full: a project declares its own board with a board= token beside tracker= in
# data/projects.md, and config/project-board is this home's fallback for a
# project that declares nothing. `sync` resolves the board from the issue's own
# tracker through that registry and falls back to the home default;
# `reconcile` uses DECLARED boards only, never the fallback, so a fleet-wide
# sweep can only reach a board somebody named for that project by hand.
# A home with neither does nothing at all and contacts no host.
#
# BOUNDED. `sync` is one item and is bounded by FM_PROJECT_BOARD_TIMEOUT seconds
# per call (default 15). `reconcile` reads whole boards and whole trackers, so it
# is additionally bounded as a whole operation by FM_BOARD_SWEEP_TIMEOUT seconds
# (default 240), reads at most FM_BOARD_SWEEP_MAX_PAGES pages of 100 per listing
# (default 20), and performs at most FM_BOARD_SWEEP_MAX_CHANGES writes per run
# (default 50). Every bound that actually truncates something says so on a
# BOARD_SWEEP: line, because a silent cap reads as "everything was covered".
#
# FAIL OPEN. A board that is unreachable, unauthorized, rate-limited, or missing
# prints one "warning:" line on stderr and exits 0. It can never block or fail
# dispatch, validation, merge, or cleanup, and one project's broken board never
# stops the sweep reaching the next one. A non-zero exit means the CALLER passed
# something invalid, never that GitHub misbehaved.
#
# IDEMPOTENCY. Membership is added through addProjectV2ItemById, which returns
# the existing item when the content is already on the board, so a repeated sync
# or sweep cannot produce a second card, and a re-run with nothing drifted writes
# nothing at all.
#
# CONTENT. Nothing fleet-private is ever written: this script sends only node ids
# and status option ids that already exist on GitHub. There is no free-text field
# to leak into.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BOARD_CONFIG="$CONFIG/project-board"
REGISTRY="$DATA/projects.md"
CALL_TIMEOUT=${FM_PROJECT_BOARD_TIMEOUT:-15}
case "$CALL_TIMEOUT" in
  ''|*[!0-9]*|0) CALL_TIMEOUT=15 ;;
esac
SWEEP_TIMEOUT=${FM_BOARD_SWEEP_TIMEOUT:-240}
case "$SWEEP_TIMEOUT" in
  ''|*[!0-9]*|0) SWEEP_TIMEOUT=240 ;;
esac
SWEEP_MAX_PAGES=${FM_BOARD_SWEEP_MAX_PAGES:-20}
case "$SWEEP_MAX_PAGES" in
  ''|*[!0-9]*|0) SWEEP_MAX_PAGES=20 ;;
esac
SWEEP_MAX_CHANGES=${FM_BOARD_SWEEP_MAX_CHANGES:-50}
case "$SWEEP_MAX_CHANGES" in
  ''|*[!0-9]*) SWEEP_MAX_CHANGES=50 ;;
esac

# shellcheck source=bin/fm-issue-lib.sh
. "$SCRIPT_DIR/fm-issue-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-milestone-lib.sh
. "$SCRIPT_DIR/fm-milestone-lib.sh"
# shellcheck source=bin/fm-board-lib.sh
. "$SCRIPT_DIR/fm-board-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

warn() { printf 'warning: project board not updated: %s\n' "$1" >&2; }
notice() { printf 'notice: this work item is not tracked on the project board: %s\n' "$1" >&2; }

# Milestone -> the status this board should show, as an ordered candidate list.
# The first candidate that matches an option the captain actually configured
# wins, matched case-insensitively so "In Progress" and "In progress" are one
# answer. A milestone with no matching option leaves the status untouched.
# The vocabulary itself belongs to bin/fm-milestone-lib.sh; this maps it.
status_candidates() {  # <milestone>
  case "$1" in
    queued) printf 'todo\nto do\nbacklog\nqueued\n' ;;
    dispatched|implemented|validated) printf 'in progress\ndoing\nin development\n' ;;
    blocked) printf 'blocked\nin progress\ndoing\n' ;;
    in-review) printf 'in review\nreview\npr open\nin progress\n' ;;
    landed) printf 'done\ncompleted\nshipped\n' ;;
    stopped) ;;
    *) return 1 ;;
  esac
}

# The two classes the drift sweep reasons in, expressed through the same map so
# a board configured for one surface is configured for both. A closed issue
# belongs in the landed class; an open issue belongs anywhere that is not it, and
# the sweep moves one there only when it has drifted INTO the landed class.
done_class_candidates() { status_candidates landed; }
open_class_candidates() { status_candidates queued; status_candidates dispatched; }

# --- arguments --------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
COMMAND=${1:-}
case "$COMMAND" in
  sync|show|reconcile) shift ;;
  *) usage >&2; exit 1 ;;
esac

TASK=
ISSUE_ARG=
MILESTONE=
PROJECT_ARG=
LIMIT_ARG=
DRY_RUN=0
QUIET=0
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      task) TASK=$a ;;
      issue) ISSUE_ARG=$a ;;
      milestone) MILESTONE=$a ;;
      project) PROJECT_ARG=$a ;;
      limit) LIMIT_ARG=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --task) want_value=task ;;
    --task=*) TASK=${a#--task=} ;;
    --issue) want_value=issue ;;
    --issue=*) ISSUE_ARG=${a#--issue=} ;;
    --milestone) want_value=milestone ;;
    --milestone=*) MILESTONE=${a#--milestone=} ;;
    --project) want_value=project ;;
    --project=*) PROJECT_ARG=${a#--project=} ;;
    --limit) want_value=limit ;;
    --limit=*) LIMIT_ARG=${a#--limit=} ;;
    --dry-run) DRY_RUN=1 ;;
    --quiet) QUIET=1 ;;
    *) echo "error: unknown argument $a" >&2; exit 1 ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

case "$COMMAND" in
  reconcile)
    [ -z "$TASK" ] && [ -z "$ISSUE_ARG" ] && [ -z "$MILESTONE" ] \
      || { echo "error: reconcile sweeps declared boards and takes no task, issue, or milestone" >&2; exit 1; }
    if [ -n "$LIMIT_ARG" ]; then
      case "$LIMIT_ARG" in
        ''|*[!0-9]*) echo "error: --limit must be a whole number of changes" >&2; exit 1 ;;
      esac
      SWEEP_MAX_CHANGES=$LIMIT_ARG
    fi
    ;;
  show)
    [ -z "$TASK" ] && [ -z "$ISSUE_ARG" ] && [ -z "$MILESTONE" ] && [ -z "$LIMIT_ARG" ] \
      || { echo "error: show reports a configured board and takes no target" >&2; exit 1; }
    ;;
  sync)
    [ -z "$PROJECT_ARG" ] && [ -z "$LIMIT_ARG" ] \
      || { echo "error: sync addresses one work item and takes no --project or --limit" >&2; exit 1; }
    [ -n "$TASK" ] || [ -n "$ISSUE_ARG" ] \
      || { echo "error: sync requires --task <task-id> or --issue <url>" >&2; exit 1; }
    [ -z "$TASK" ] || [ -z "$ISSUE_ARG" ] \
      || { echo "error: --task and --issue are mutually exclusive" >&2; exit 1; }
    if [ -n "$TASK" ]; then
      [ -n "$MILESTONE" ] || { echo "error: --task requires --milestone (one of: $FM_MILESTONE_TOKENS)" >&2; exit 1; }
      case "$TASK" in
        ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 1 ;;
      esac
    fi
    if [ -n "$MILESTONE" ] && ! fm_milestone_label "$MILESTONE" >/dev/null; then
      echo "error: --milestone must be one of: $FM_MILESTONE_TOKENS (got '$MILESTONE')" >&2
      exit 1
    fi
    ;;
esac
if [ -n "$PROJECT_ARG" ]; then
  case "$PROJECT_ARG" in
    ''|*[[:space:]]*) echo "error: --project must be one registry project name" >&2; exit 1 ;;
  esac
fi

# --- board identity ---------------------------------------------------------

# The home's fallback board, or empty when this home has none. Read once so
# every command answers the same question the same way.
HOME_BOARD_URL=
if [ -f "$BOARD_CONFIG" ] && [ ! -L "$BOARD_CONFIG" ]; then
  HOME_BOARD_URL=$(head -n 1 "$BOARD_CONFIG" | tr -d '\r')
  HOME_BOARD_URL=${HOME_BOARD_URL%"${HOME_BOARD_URL##*[![:space:]]}"}
  if [ -n "$HOME_BOARD_URL" ] && ! fm_board_url_parse "$HOME_BOARD_URL"; then
    warn "config/project-board must hold one board URL of the form https://github.com/orgs/<org>/projects/<n> or https://github.com/users/<login>/projects/<n>"
    exit 0
  fi
fi

# --- target issue -----------------------------------------------------------

ISSUE_URL=
ISSUE_OWNER=
ISSUE_REPO=
ISSUE_NUMBER=
if [ "$COMMAND" = sync ]; then
  if [ -n "$ISSUE_ARG" ]; then
    if ! fm_issue_url_parse "$ISSUE_ARG" github || [ "$FM_ISSUE_FORGE" != github ]; then
      echo "error: --issue requires a canonical GitHub issue URL" >&2
      exit 1
    fi
  else
    META="$STATE/$TASK.meta"
    if [ ! -f "$META" ] || [ -L "$META" ]; then
      warn "task metadata is unavailable"
      exit 0
    fi
    RECORDS=$(grep '^work_item=' "$META" 2>/dev/null | cut -d= -f2- || true)
    [ -n "$RECORDS" ] || exit 0
    if [ "$(printf '%s\n' "$RECORDS" | wc -l)" -ne 1 ]; then
      notice "the task records several work items, so none of them owns a board card"
      exit 0
    fi
    if ! fm_issue_work_item_parse "$RECORDS"; then
      warn "the recorded work item is malformed"
      exit 0
    fi
  fi
  if [ "$FM_ISSUE_FORGE" != github ] || [ "$FM_ISSUE_HOST" != github.com ]; then
    notice "$FM_ISSUE_URL lives on $FM_ISSUE_FORGE host $FM_ISSUE_HOST, and a GitHub project can only hold GitHub items"
    exit 0
  fi
  ISSUE_URL=$FM_ISSUE_URL
  ISSUE_OWNER=$FM_ISSUE_OWNER
  ISSUE_REPO=$FM_ISSUE_REPO
  ISSUE_NUMBER=$FM_ISSUE_NUMBER
fi

# Resolve the board a target belongs on. Sets BOARD_URL, or leaves it empty when
# the target deliberately has no board.
BOARD_URL=
resolve_declared_board() {  # <lookup-kind> <key>
  local kind=$1 key=$2 declared rc=0
  BOARD_URL=
  if [ "$kind" = project ]; then
    declared=$(fm_board_registry_board "$REGISTRY" "$key") || rc=$?
  else
    declared=$(fm_board_registry_board_for_tracker "$REGISTRY" "$key") || rc=$?
  fi
  case "$rc" in
    0)
      # A project that declares board=none has no board on purpose, and the home
      # fallback must not resurrect one for it.
      [ "$declared" = none ] || BOARD_URL=$declared
      return 0
      ;;
    2)
      warn "data/projects.md declares a board this run cannot use: $declared"
      return 1
      ;;
  esac
  return 3
}

if [ "$COMMAND" = sync ] || [ "$COMMAND" = show ]; then
  RESOLVE_RC=0
  if [ "$COMMAND" = sync ]; then
    resolve_declared_board tracker "github:github.com/$ISSUE_OWNER/$ISSUE_REPO" || RESOLVE_RC=$?
  elif [ -n "$PROJECT_ARG" ]; then
    resolve_declared_board project "$PROJECT_ARG" || RESOLVE_RC=$?
  else
    RESOLVE_RC=3
  fi
  case "$RESOLVE_RC" in
    # A malformed declaration was already reported, and guessing past it would
    # write to a board the captain did not name.
    1) exit 0 ;;
    # An undeclared project falls back to this home's board, which is the whole
    # of what config/project-board still decides.
    3) BOARD_URL=$HOME_BOARD_URL ;;
  esac
  # No board for this target is the ordinary case for a home or a project that
  # has none, so it is silent: nothing is wrong and nothing was skipped.
  [ -n "$BOARD_URL" ] || exit 0
  fm_board_url_parse "$BOARD_URL" || { warn "the resolved board URL is not a board URL: $BOARD_URL"; exit 0; }
fi

if [ "$DRY_RUN" -eq 1 ] && [ "$COMMAND" = sync ]; then
  printf 'board: %s\n' "$BOARD_URL"
  printf 'item: %s\n' "$ISSUE_URL"
  printf 'membership: ensured (with its parent issue, when it has one)\n'
  if [ -n "$MILESTONE" ]; then
    CANDIDATES=$(status_candidates "$MILESTONE")
    if [ -n "$CANDIDATES" ]; then
      printf 'status: first configured option matching %s\n' "$(printf '%s' "$CANDIDATES" | tr '\n' '/' | sed 's:/$::')"
    else
      printf 'status: left unchanged for milestone %s\n' "$MILESTONE"
    fi
  fi
  exit 0
fi

command -v gh >/dev/null 2>&1 || {
  warn "gh is not installed, so ${BOARD_URL:-the declared boards} cannot be reached"
  exit 0
}

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-project-board.XXXXXX") || {
  warn "could not create a temporary working directory"
  exit 0
}
trap 'rm -rf -- "$WORKDIR"' EXIT
# A caller bounds this whole script (bin/fm-work-item-milestone.sh), so being
# terminated mid-call is an ordinary outcome rather than a crash, and it must not
# leave a working directory behind each time it happens.
trap 'rm -rf -- "$WORKDIR"; trap - EXIT; exit 143' HUP INT TERM
FM_BOARD_WORKDIR=$WORKDIR
FM_BOARD_TIMEOUT=$CALL_TIMEOUT

# The first configured option whose name matches one of the candidates, matched
# case-insensitively. Prints nothing when the board configures none of them,
# which is the signal to report the gap rather than create the option.
option_id_for() {  # <board-file> <candidates-on-stdin>
  local board=$1 candidate id
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    id=$(awk -v want="$candidate" '
      $1 == "option" {
        id = $2
        name = $0
        sub(/^option [^ ]+ /, "", name)
        if (tolower(name) == want) { print id; exit }
      }' "$board")
    [ -z "$id" ] || { printf '%s\n' "$id"; return 0; }
  done
  return 1
}

status_in_class() {  # <status-name> <candidates-on-stdin>
  local status candidate
  status=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [ -n "$status" ] && [ "$status" != - ] || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ "$status" != "$candidate" ] || return 0
  done
  return 1
}

# --- reconcile --------------------------------------------------------------

SWEEP_CHANGES=0
SWEEP_TRUNCATED=0

# Read every page of a listing into <output-file>, up to the page cap. Returns 1
# when a page could not be read, and sets PAGES_COMPLETE to 0 when the cap
# stopped the walk before the listing ended, so a partial view is reported rather
# than mistaken for a complete one.
PAGES_COMPLETE=1
read_all_pages() {  # <output-file> <reader> [reader-args...]
  local out=$1 reader=$2
  shift 2
  local cursor='' page=0 line more
  PAGES_COMPLETE=1
  : > "$out"
  while [ "$page" -lt "$SWEEP_MAX_PAGES" ]; do
    "$reader" "$WORKDIR/page" "$@" ${cursor:+"$cursor"} || return 1
    grep -v '^cursor ' "$WORKDIR/page" >> "$out" || true
    line=$(awk '$1 == "cursor" { print; exit }' "$WORKDIR/page")
    [ -n "$line" ] || return 0
    more=${line##* }
    [ "$more" = more ] || return 0
    cursor=$(printf '%s' "$line" | awk '{ print $2 }')
    [ -n "$cursor" ] && [ "$cursor" != - ] || return 0
    page=$((page + 1))
  done
  PAGES_COMPLETE=0
  return 0
}

reconcile_project() {  # <project> <board-url> <owner> <repo>
  local project=$1 board_url=$2 owner=$3 repo=$4
  local project_id status_field added=0 corrected=0 blocked_done=0 blocked_open=0
  local action number state item_id status content_id done_option open_option

  fm_board_url_parse "$board_url" || {
    echo "warning: $project declares a board that is not a board URL: $board_url" >&2
    return 0
  }
  if ! fm_board_read "$WORKDIR/board" "$FM_BOARD_OWNER_TYPE" "$FM_BOARD_OWNER" "$FM_BOARD_NUMBER"; then
    echo "warning: could not read $board_url for $project: $FM_BOARD_GQL_REASON" >&2
    return 0
  fi
  project_id=$(awk '$1 == "project" { print $2; exit }' "$WORKDIR/board")
  status_field=$(awk '$1 == "field" { print $2; exit }' "$WORKDIR/board")
  if [ -z "$project_id" ]; then
    echo "warning: $board_url did not resolve to a project this credential can read" >&2
    return 0
  fi

  if ! read_all_pages "$WORKDIR/items" fm_board_items_page "$project_id"; then
    echo "warning: could not list the items on $board_url: $FM_BOARD_GQL_REASON" >&2
    return 0
  fi
  [ "$PAGES_COMPLETE" -eq 1 ] || {
    echo "BOARD_SWEEP: $project: $board_url has more items than the ${SWEEP_MAX_PAGES}-page cap reads, so this sweep saw only the first $((SWEEP_MAX_PAGES * 100))"
  }
  if ! read_all_pages "$WORKDIR/issues" fm_board_tracker_issues_page "$owner" "$repo"; then
    echo "warning: could not list $owner/$repo's issues for $project: $FM_BOARD_GQL_REASON" >&2
    return 0
  fi
  [ "$PAGES_COMPLETE" -eq 1 ] || {
    echo "BOARD_SWEEP: $project: $owner/$repo has more issues than the ${SWEEP_MAX_PAGES}-page cap reads, so this sweep saw only the first $((SWEEP_MAX_PAGES * 100))"
  }

  # Join the board's items onto the tracker's issues. An item with no matching
  # issue is deliberately absent from the output: a card a human added by hand
  # is never removed, and reconciliation has nothing to say about it.
  awk -v key="$owner/$repo" '
    NR == FNR {
      if ($1 == "item" && index($3, key "#") == 1) {
        n = $3; sub(/.*#/, "", n)
        id[n] = $2
        s = ""
        for (i = 4; i <= NF; i++) s = s (i > 4 ? " " : "") $i
        status[n] = s
      }
      next
    }
    $1 == "issue" {
      if ($2 in id) print "have", $2, $3, id[$2], status[$2]
      else print "add", $2, $3, "-", "-"
    }
  ' "$WORKDIR/items" "$WORKDIR/issues" > "$WORKDIR/plan"

  done_option=$(done_class_candidates | option_id_for "$WORKDIR/board") || done_option=
  open_option=$(open_class_candidates | option_id_for "$WORKDIR/board") || open_option=

  while read -r action number state item_id status <&3; do
    if [ "$SWEEP_CHANGES" -ge "$SWEEP_MAX_CHANGES" ]; then
      SWEEP_TRUNCATED=1
      break
    fi
    if [ "$action" = add ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        printf 'would add: %s/%s#%s to %s\n' "$owner" "$repo" "$number" "$board_url"
        added=$((added + 1))
        SWEEP_CHANGES=$((SWEEP_CHANGES + 1))
        continue
      fi
      if ! fm_board_issue_id "$WORKDIR/issue" "$owner" "$repo" "$number"; then
        echo "warning: could not read $owner/$repo#$number: $FM_BOARD_GQL_REASON" >&2
        continue
      fi
      content_id=$(head -n 1 "$WORKDIR/issue")
      [ -n "$content_id" ] || continue
      if ! fm_board_item_add "$WORKDIR/item" "$project_id" "$content_id"; then
        echo "warning: could not add $owner/$repo#$number to $board_url: $FM_BOARD_GQL_REASON" >&2
        continue
      fi
      item_id=$(head -n 1 "$WORKDIR/item")
      status=-
      added=$((added + 1))
      SWEEP_CHANGES=$((SWEEP_CHANGES + 1))
      [ -n "$item_id" ] || continue
    fi

    # Status is coarse on purpose. A closed issue reads Done; an open issue that
    # has drifted INTO Done is moved back out. An open issue reading anything
    # else - including nothing at all - is left exactly as the captain has it,
    # because closed-versus-open is the only truth available for work firstmate
    # did not dispatch.
    if [ "$state" = CLOSED ]; then
      if status_in_class "$status" < <(done_class_candidates); then
        continue
      fi
      if [ -z "$status_field" ] || [ -z "$done_option" ]; then
        blocked_done=$((blocked_done + 1))
        continue
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        printf 'would set Done: %s/%s#%s on %s\n' "$owner" "$repo" "$number" "$board_url"
      elif fm_board_item_status_set "$WORKDIR/status" "$project_id" "$item_id" "$status_field" "$done_option"; then
        :
      else
        echo "warning: could not set $owner/$repo#$number to Done on $board_url: $FM_BOARD_GQL_REASON" >&2
        continue
      fi
      corrected=$((corrected + 1))
      SWEEP_CHANGES=$((SWEEP_CHANGES + 1))
      continue
    fi

    status_in_class "$status" < <(done_class_candidates) || continue
    if [ -z "$status_field" ] || [ -z "$open_option" ]; then
      blocked_open=$((blocked_open + 1))
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would move out of Done: %s/%s#%s on %s\n' "$owner" "$repo" "$number" "$board_url"
    elif fm_board_item_status_set "$WORKDIR/status" "$project_id" "$item_id" "$status_field" "$open_option"; then
      :
    else
      echo "warning: could not move $owner/$repo#$number out of Done on $board_url: $FM_BOARD_GQL_REASON" >&2
      continue
    fi
    corrected=$((corrected + 1))
    SWEEP_CHANGES=$((SWEEP_CHANGES + 1))
  done 3< "$WORKDIR/plan"

  # A board with no option for a status the sweep needs is REPORTED, never
  # helpfully given one: creating a single-select option rewrites the field's
  # whole option set and blanks every item already using it.
  [ "$blocked_done" -eq 0 ] || echo "BOARD_SWEEP: $project: $blocked_done closed issue(s) on $board_url have no Done-class Status option to move to; add one by hand, because creating one would clear the status of every item on the board"
  [ "$blocked_open" -eq 0 ] || echo "BOARD_SWEEP: $project: $blocked_open open issue(s) read Done on $board_url and there is no open-class Status option to move them to; add one by hand, for the same reason"

  if [ "$added" -gt 0 ] || [ "$corrected" -gt 0 ] || [ "$QUIET" -eq 0 ]; then
    printf 'board: %s %s: %d added, %d status corrected\n' "$project" "$board_url" "$added" "$corrected"
  fi
}

if [ "$COMMAND" = reconcile ]; then
  # The sweep is bounded as one whole operation, not only per call, because a
  # per-call bound alone adds up to minutes across four boards on a slow network.
  [ -n "${FM_WRITE_BACK_BUDGET:-}" ] || FM_WRITE_BACK_BUDGET=$SWEEP_TIMEOUT
  export FM_WRITE_BACK_BUDGET
  if [ ! -f "$REGISTRY" ] || [ -L "$REGISTRY" ]; then
    exit 0
  fi
  SWEPT=0
  while read -r name board tracker <&3; do
    [ -n "$name" ] || continue
    [ -z "$PROJECT_ARG" ] || [ "$PROJECT_ARG" = "$name" ] || continue
    case "$board" in
      -|none) continue ;;
      '!')
        echo "BOARD_SWEEP: $name: its data/projects.md entry declares more than one board=, or one with an empty value, so it was skipped"
        continue
        ;;
    esac
    if ! fm_board_url_parse "$board"; then
      echo "BOARD_SWEEP: $name: board=$board is not a board URL, so it was skipped"
      continue
    fi
    case "$tracker" in
      -|none|'!')
        echo "BOARD_SWEEP: $name declares a board but no usable tracker to reconcile it against, so it was skipped"
        continue
        ;;
    esac
    if ! fm_issue_tracker_parse "$tracker"; then
      echo "BOARD_SWEEP: $name: tracker=$tracker is malformed, so its board was skipped"
      continue
    fi
    if [ "$FM_ISSUE_TRACKER_FORGE" != github ] || [ "$FM_ISSUE_TRACKER_HOST" != github.com ]; then
      echo "BOARD_SWEEP: $name tracks its work on $FM_ISSUE_TRACKER_FORGE host $FM_ISSUE_TRACKER_HOST, and a GitHub project can only hold GitHub items, so its board was skipped"
      continue
    fi
    SWEPT=$((SWEPT + 1))
    reconcile_project "$name" "$board" "${FM_ISSUE_TRACKER_PATH%%/*}" "${FM_ISSUE_TRACKER_PATH#*/}"
    [ "$SWEEP_TRUNCATED" -eq 0 ] || break
  done 3<<EOF
$(fm_board_registry_scan "$REGISTRY")
EOF
  if [ "$SWEEP_TRUNCATED" -eq 1 ]; then
    echo "BOARD_SWEEP: this sweep stopped at its ${SWEEP_MAX_CHANGES}-change limit, so drift may remain; the next sweep continues from where it stopped"
  fi
  if [ -n "$PROJECT_ARG" ] && [ "$SWEPT" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    printf 'board: %s declares no board to reconcile\n' "$PROJECT_ARG"
  fi
  exit 0
fi

# --- the configured board ---------------------------------------------------

if ! fm_board_read "$WORKDIR/board" "$FM_BOARD_OWNER_TYPE" "$FM_BOARD_OWNER" "$FM_BOARD_NUMBER"; then
  warn "could not read $BOARD_URL: $FM_BOARD_GQL_REASON"
  exit 0
fi
PROJECT_ID=$(awk '$1 == "project" { print $2; exit }' "$WORKDIR/board")
PROJECT_TITLE=$(awk '$1 == "title" { sub(/^title /, ""); print; exit }' "$WORKDIR/board")
STATUS_FIELD_ID=$(awk '$1 == "field" { print $2; exit }' "$WORKDIR/board")
if [ -z "$PROJECT_ID" ]; then
  warn "$BOARD_URL did not resolve to a project this credential can read"
  exit 0
fi

if [ "$COMMAND" = show ]; then
  printf 'board: %s\n' "$BOARD_URL"
  printf 'title: %s\n' "$PROJECT_TITLE"
  if [ -n "$STATUS_FIELD_ID" ]; then
    awk '$1 == "option" { $1 = ""; $2 = ""; sub(/^  */, ""); print "status option: " $0 }' "$WORKDIR/board"
  else
    printf 'status option: none (the board has no single-select Status field)\n'
  fi
  exit 0
fi

# --- membership -------------------------------------------------------------

# Sets MEMBER_ITEM_ID rather than printing it: the failure reason travels in
# FM_BOARD_GQL_REASON, which a command substitution's subshell would discard.
MEMBER_ITEM_ID=
ensure_member() {  # <owner> <repo> <number>
  local owner=$1 repo=$2 number=$3 content_id
  MEMBER_ITEM_ID=
  fm_board_issue_id "$WORKDIR/issue" "$owner" "$repo" "$number" || return 1
  content_id=$(head -n 1 "$WORKDIR/issue")
  [ -n "$content_id" ] || { FM_BOARD_GQL_REASON="the issue does not exist or is not readable"; return 1; }
  fm_board_item_add "$WORKDIR/item" "$PROJECT_ID" "$content_id" || return 1
  MEMBER_ITEM_ID=$(head -n 1 "$WORKDIR/item")
  [ -n "$MEMBER_ITEM_ID" ] || { FM_BOARD_GQL_REASON="GitHub returned no board item"; return 1; }
}

if ! ensure_member "$ISSUE_OWNER" "$ISSUE_REPO" "$ISSUE_NUMBER"; then
  warn "could not put $ISSUE_URL on $BOARD_URL: $FM_BOARD_GQL_REASON"
  exit 0
fi
ITEM_ID=$MEMBER_ITEM_ID

# The epic is ensured through the parent relationship GitHub already models, so
# the captain reads epic progress from native sub-issue rollup rather than from a
# field firstmate invented. A forge that does not expose the relationship is not
# a failure: the story card is already correct without it.
if fm_board_issue_parent "$WORKDIR/parent" "$ISSUE_OWNER" "$ISSUE_REPO" "$ISSUE_NUMBER"; then
  PARENT_LINE=$(head -n 1 "$WORKDIR/parent")
  if [ -n "$PARENT_LINE" ]; then
    # shellcheck disable=SC2086  # the three fields are GitHub-validated identifiers
    set -- $PARENT_LINE
    ensure_member "$1" "$2" "$3" \
      || echo "warning: $ISSUE_URL is on $BOARD_URL but its epic could not be added: $FM_BOARD_GQL_REASON" >&2
  fi
fi

# --- status -----------------------------------------------------------------

[ -n "$MILESTONE" ] || { printf 'board: %s tracks %s\n' "$BOARD_URL" "$ISSUE_URL"; exit 0; }
CANDIDATES=$(status_candidates "$MILESTONE")
if [ -z "$CANDIDATES" ]; then
  printf 'board: %s tracks %s (status left unchanged)\n' "$BOARD_URL" "$ISSUE_URL"
  exit 0
fi
if [ -z "$STATUS_FIELD_ID" ]; then
  echo "warning: $ISSUE_URL is on $BOARD_URL, but the board has no single-select Status field to drive" >&2
  exit 0
fi

OPTION_ID=$(printf '%s\n' "$CANDIDATES" | option_id_for "$WORKDIR/board") || OPTION_ID=
if [ -z "$OPTION_ID" ]; then
  # Adding the option would rewrite the field's whole option set and detach every
  # item already using one, so the gap is reported and the board left alone.
  echo "warning: $ISSUE_URL is on $BOARD_URL, but its Status field has no option matching milestone '$MILESTONE'; the status was left unchanged, and the option must be added by hand because creating one would clear the status of every item on the board" >&2
  exit 0
fi

if fm_board_item_status_set "$WORKDIR/status" "$PROJECT_ID" "$ITEM_ID" "$STATUS_FIELD_ID" "$OPTION_ID"; then
  printf 'board: %s tracks %s\n' "$BOARD_URL" "$ISSUE_URL"
  exit 0
fi
echo "warning: $ISSUE_URL is on $BOARD_URL, but its status could not be set: $FM_BOARD_GQL_REASON" >&2
exit 0
