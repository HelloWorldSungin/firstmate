#!/usr/bin/env bash
# The captain's GitHub Projects board, kept true.
#
# Usage: fm-project-board.sh sync --task <task-id> --milestone <token> [--dry-run]
#        fm-project-board.sh sync --issue <url> [--milestone <token>] [--dry-run]
#        fm-project-board.sh show [--dry-run]
#
# The board is the captain's visualization of current status across individual
# works and across epics. It is a second surface over the same issues, not a
# second source of truth: its status is driven by the SAME milestone vocabulary
# that drives the living status comment (bin/fm-issue-comment.sh), so the two
# surfaces cannot disagree about where a task stands.
#
# This script is the single owner of everything firstmate writes to that board.
#
# OWNERSHIP MEANS KEEPING IT TRUE, NOT RESHAPING IT. Nothing here creates,
# renames, or deletes a view, a filter, a field, or a status option, and nothing
# removes an item. It adds membership and sets the Status field of items it
# added, and that is the whole of its write surface. When the board's Status
# field has no option matching a milestone, it says so and leaves the status
# alone rather than inventing an option; adding one is an additive structural
# change and therefore the captain's call, made deliberately and visibly.
#
# MEMBERSHIP AND EPICS. Every work item firstmate tracks belongs on the board,
# because an issue missing from it makes the board lie by omission. When a story
# has a parent issue, that parent is ensured as a board member too, so the
# captain can read the epic level through the parent/sub-issue relationship
# GitHub already models. No epic status is computed here: rolling story states up
# into an epic's status is its own design question, and GitHub's native sub-issue
# progress already answers the common form of it without a parallel scheme.
#
# INERT UNTIL CONFIGURED. Without config/project-board this script does nothing
# at all and contacts no host, so a home that has no board is unaffected. The
# file holds one line, the board URL:
#   https://github.com/orgs/<org>/projects/<n>
#   https://github.com/users/<login>/projects/<n>
#
# CREDENTIAL. Projects v2 is GraphQL-only and gh-axi does not implement it - its
# command surface is issue, pr, run, release, repo, label, secret, and variable -
# so this is a deliberate exception to the usual prefer-gh-axi rule and uses
# `gh api graphql` directly. The token additionally needs the `project` scope,
# which the ordinary `repo` scope does not imply; without it the board simply
# reports that and every task proceeds untouched.
#
# FAIL OPEN. A board that is unreachable, unauthorized, rate-limited, or missing
# prints one "warning:" line on stderr and exits 0. It can never block or fail
# dispatch, validation, merge, or cleanup. A non-zero exit means the CALLER
# passed something invalid, never that GitHub misbehaved.
#
# IDEMPOTENCY. Membership is added through addProjectV2ItemById, which returns
# the existing item when the content is already on the board, so a repeated sync
# cannot produce a second card. The item id that mutation returns is the same id
# the status update targets, so both halves of a sync address one card.
#
# CONTENT. Nothing fleet-private is ever written: this script sends only an issue
# node id and a status option id that already exist on GitHub. There is no
# free-text field to leak into.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BOARD_CONFIG="$CONFIG/project-board"
CALL_TIMEOUT=${FM_PROJECT_BOARD_TIMEOUT:-15}
case "$CALL_TIMEOUT" in
  ''|*[!0-9]*|0) CALL_TIMEOUT=15 ;;
esac

# shellcheck source=bin/fm-issue-lib.sh
. "$SCRIPT_DIR/fm-issue-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

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

MILESTONE_TOKENS='queued dispatched implemented validated in-review landed blocked stopped'

# --- arguments --------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
COMMAND=${1:-}
case "$COMMAND" in
  sync|show) shift ;;
  *) usage >&2; exit 1 ;;
esac

TASK=
ISSUE_ARG=
MILESTONE=
DRY_RUN=0
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
    --dry-run) DRY_RUN=1 ;;
    *) echo "error: unknown argument $a" >&2; exit 1 ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

if [ "$COMMAND" = show ]; then
  [ -z "$TASK" ] && [ -z "$ISSUE_ARG" ] && [ -z "$MILESTONE" ] \
    || { echo "error: show reports the configured board and takes no target" >&2; exit 1; }
else
  [ -n "$TASK" ] || [ -n "$ISSUE_ARG" ] \
    || { echo "error: sync requires --task <task-id> or --issue <url>" >&2; exit 1; }
  [ -z "$TASK" ] || [ -z "$ISSUE_ARG" ] \
    || { echo "error: --task and --issue are mutually exclusive" >&2; exit 1; }
  if [ -n "$TASK" ]; then
    [ -n "$MILESTONE" ] || { echo "error: --task requires --milestone (one of: $MILESTONE_TOKENS)" >&2; exit 1; }
    case "$TASK" in
      ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 1 ;;
    esac
  fi
  if [ -n "$MILESTONE" ] && ! status_candidates "$MILESTONE" >/dev/null; then
    echo "error: --milestone must be one of: $MILESTONE_TOKENS (got '$MILESTONE')" >&2
    exit 1
  fi
fi

# --- configured board -------------------------------------------------------

if [ ! -f "$BOARD_CONFIG" ] || [ -L "$BOARD_CONFIG" ]; then
  # No board configured is the ordinary case for a home that has none, so it is
  # silent: nothing is wrong and nothing was skipped.
  exit 0
fi
BOARD_URL=$(head -n 1 "$BOARD_CONFIG" | tr -d '\r')
BOARD_URL=${BOARD_URL%"${BOARD_URL##*[![:space:]]}"}
BOARD_OWNER_TYPE=
BOARD_OWNER=
BOARD_NUMBER=
board_url_parse() {  # <url>
  local pattern
  pattern='^https://github\.com/(orgs|users)/([A-Za-z0-9._-]{1,64})/projects/([1-9][0-9]{0,9})$'
  [[ "$1" =~ $pattern ]] || return 1
  case "${BASH_REMATCH[1]}" in
    orgs) BOARD_OWNER_TYPE=organization ;;
    users) BOARD_OWNER_TYPE=user ;;
  esac
  BOARD_OWNER=${BASH_REMATCH[2]}
  BOARD_NUMBER=${BASH_REMATCH[3]}
}
if ! board_url_parse "$BOARD_URL"; then
  warn "config/project-board must hold one board URL of the form https://github.com/orgs/<org>/projects/<n> or https://github.com/users/<login>/projects/<n>"
  exit 0
fi

# --- target issue -----------------------------------------------------------

ISSUE_URL=
ISSUE_OWNER=
ISSUE_REPO=
ISSUE_NUMBER=
if [ -n "$ISSUE_ARG" ]; then
  if ! fm_issue_url_parse "$ISSUE_ARG" github || [ "$FM_ISSUE_FORGE" != github ]; then
    echo "error: --issue requires a canonical GitHub issue URL" >&2
    exit 1
  fi
elif [ -n "$TASK" ]; then
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
if [ "$COMMAND" = sync ]; then
  if [ "$FM_ISSUE_FORGE" != github ] || [ "$FM_ISSUE_HOST" != github.com ]; then
    notice "$FM_ISSUE_URL lives on $FM_ISSUE_FORGE host $FM_ISSUE_HOST, and a GitHub project can only hold GitHub items"
    exit 0
  fi
  ISSUE_URL=$FM_ISSUE_URL
  ISSUE_OWNER=$FM_ISSUE_OWNER
  ISSUE_REPO=$FM_ISSUE_REPO
  ISSUE_NUMBER=$FM_ISSUE_NUMBER
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'board: %s\n' "$BOARD_URL"
  if [ "$COMMAND" = sync ]; then
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
  fi
  exit 0
fi

command -v gh >/dev/null 2>&1 || { warn "gh is not installed, so $BOARD_URL cannot be reached"; exit 0; }

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-project-board.XXXXXX") || {
  warn "could not create a temporary working directory"
  exit 0
}
trap 'rm -rf -- "$WORKDIR"' EXIT

GQL_REASON=
gql() {  # <output-file> <jq> <query> [-F name=value]...
  local out=$1 filter=$2 query=$3 rc=0
  shift 3
  fm_run_timed "$CALL_TIMEOUT" gh api graphql -f query="$query" "$@" --jq "$filter" \
    > "$out" 2>"$WORKDIR/err" || rc=$?
  case "$rc" in
    0) return 0 ;;
    124|137) GQL_REASON="GitHub did not answer within ${CALL_TIMEOUT}s" ;;
    125) GQL_REASON="no bounded timeout runner could start, so nothing was sent" ;;
    *)
      if grep -qi 'scope\|INSUFFICIENT_SCOPES\|Resource not accessible' "$WORKDIR/err" 2>/dev/null; then
        GQL_REASON="the GitHub token is missing the 'project' scope that Projects boards require"
      else
        GQL_REASON="GitHub rejected the request (the board may be missing, or the credential may lack access)"
      fi
      ;;
  esac
  return 1
}

# A user board and an organization board are the same query under a different
# root field, and GraphQL has no way to pick a root field by variable, so the one
# placeholder is substituted from the two values board_url_parse can produce.
# shellcheck disable=SC2016  # $login/$owner/$project and friends are GraphQL variables sent verbatim; shell expansion here would break the query.
BOARD_QUERY='query($login:String!,$number:Int!){
  OWNER_ROOT(login:$login){
    projectV2(number:$number){
      id
      title
      field(name:"Status"){ ... on ProjectV2SingleSelectField { id options { id name } } }
    }
  }
}'
BOARD_QUERY=${BOARD_QUERY/OWNER_ROOT/$BOARD_OWNER_TYPE}
BOARD_FILTER=".data.$BOARD_OWNER_TYPE.projectV2 | \"project \" + .id, \"title \" + .title, \"field \" + (.field.id // \"\"), (.field.options[]? | \"option \" + .id + \" \" + .name)"

if ! gql "$WORKDIR/board" "$BOARD_FILTER" "$BOARD_QUERY" \
  -f "login=$BOARD_OWNER" -F "number=$BOARD_NUMBER"; then
  warn "could not read $BOARD_URL: $GQL_REASON"
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
# GQL_REASON, which a command substitution's subshell would discard.
MEMBER_ITEM_ID=
ensure_member() {  # <owner> <repo> <number>
  local owner=$1 repo=$2 number=$3 content_id
  MEMBER_ITEM_ID=
  # shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
  gql "$WORKDIR/issue" '.data.repository.issue.id // empty' \
    'query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ issue(number:$number){ id } } }' \
    -f "owner=$owner" -f "name=$repo" -F "number=$number" || return 1
  content_id=$(head -n 1 "$WORKDIR/issue")
  [ -n "$content_id" ] || { GQL_REASON="the issue does not exist or is not readable"; return 1; }
  # addProjectV2ItemById returns the EXISTING item when the content is already on
  # the board, so this is the idempotent membership call rather than a blind add.
  # shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
  gql "$WORKDIR/item" '.data.addProjectV2ItemById.item.id // empty' \
    'mutation($project:ID!,$content:ID!){ addProjectV2ItemById(input:{projectId:$project,contentId:$content}){ item { id } } }' \
    -f "project=$PROJECT_ID" -f "content=$content_id" || return 1
  MEMBER_ITEM_ID=$(head -n 1 "$WORKDIR/item")
  [ -n "$MEMBER_ITEM_ID" ] || { GQL_REASON="GitHub returned no board item"; return 1; }
}

if ! ensure_member "$ISSUE_OWNER" "$ISSUE_REPO" "$ISSUE_NUMBER"; then
  warn "could not put $ISSUE_URL on $BOARD_URL: $GQL_REASON"
  exit 0
fi
ITEM_ID=$MEMBER_ITEM_ID

# The epic is ensured through the parent relationship GitHub already models, so
# the captain reads epic progress from native sub-issue rollup rather than from a
# field firstmate invented. A forge that does not expose the relationship is not
# a failure: the story card is already correct without it.
# shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
if gql "$WORKDIR/parent" \
  '.data.repository.issue.parent | select(. != null) | "\(.repository.owner.login) \(.repository.name) \(.number)"' \
  'query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ issue(number:$number){ parent { number repository { name owner { login } } } } } }' \
  -f "owner=$ISSUE_OWNER" -f "name=$ISSUE_REPO" -F "number=$ISSUE_NUMBER"; then
  PARENT_LINE=$(head -n 1 "$WORKDIR/parent")
  if [ -n "$PARENT_LINE" ]; then
    # shellcheck disable=SC2086  # the three fields are GitHub-validated identifiers
    set -- $PARENT_LINE
    ensure_member "$1" "$2" "$3" \
      || echo "warning: $ISSUE_URL is on $BOARD_URL but its epic could not be added: $GQL_REASON" >&2
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

OPTION_ID=
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  OPTION_ID=$(awk -v want="$candidate" '
    $1 == "option" {
      id = $2
      name = $0
      sub(/^option [^ ]+ /, "", name)
      if (tolower(name) == want) { print id; exit }
    }' "$WORKDIR/board")
  [ -z "$OPTION_ID" ] || break
done <<EOF
$CANDIDATES
EOF

if [ -z "$OPTION_ID" ]; then
  # Adding an option is an additive structural change to the captain's board, so
  # it is reported rather than performed.
  echo "warning: $ISSUE_URL is on $BOARD_URL, but its Status field has no option matching milestone '$MILESTONE'; the status was left unchanged" >&2
  exit 0
fi

# shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
if gql "$WORKDIR/status" '.data.updateProjectV2ItemFieldValue.projectV2Item.id // empty' \
  'mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){ updateProjectV2ItemFieldValue(input:{projectId:$project,itemId:$item,fieldId:$field,value:{singleSelectOptionId:$option}}){ projectV2Item { id } } }' \
  -f "project=$PROJECT_ID" -f "item=$ITEM_ID" -f "field=$STATUS_FIELD_ID" -f "option=$OPTION_ID"; then
  printf 'board: %s tracks %s\n' "$BOARD_URL" "$ISSUE_URL"
  exit 0
fi
echo "warning: $ISSUE_URL is on $BOARD_URL, but its status could not be set: $GQL_REASON" >&2
exit 0
