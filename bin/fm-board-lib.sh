#!/usr/bin/env bash
# fm-board-lib.sh - the single owner of GitHub Projects board identity and of
# every request firstmate sends to a board.
#
# Sourced, never executed. bin/fm-project-board.sh is its only caller today; the
# split exists so board identity and the board wire surface each have one owner
# that a reader can check in full, rather than being spread through a command
# script that also decides policy.
#
# BOARD IDENTITY. Two different facts name a board, and each has exactly one
# owner:
#   - Which board a PROJECT's work belongs on is declared in data/projects.md, as
#     a board= token inside the same bracket annotation that already carries
#     tracker= (docs/configuration.md owns the schema). fm_board_registry_board
#     reads it.
#   - Which board this HOME falls back to for a project that declares nothing is
#     config/project-board, read by the caller. That fallback drives lifecycle
#     sync only, and never the fleet-wide reconciliation sweep, so a sweep can
#     only ever reach a board somebody named for that project by hand.
# board=none declares that a project has no board, which is distinct from an
# absent token meaning undeclared; the first skips even when a home default
# exists, the second falls back to it.
#
# THE WHOLE WIRE SURFACE IS HERE, AND WRITES ARE TWO OPERATIONS. Reads are
# fm_board_read, fm_board_issue_id, fm_board_issue_parent, fm_board_items_page,
# and fm_board_tracker_issues_page. Writes are fm_board_item_add and
# fm_board_item_status_set, and that is the complete list: membership, and the
# Status field's single-select value on an item. Nothing here can create,
# rename, or delete a view, filter, field, status option, or item, because no
# function that does so exists and no caller is offered a way to name a mutation
# of its own - the transport is private. Adding an option would be the
# destructive one: updateProjectV2Field replaces a single-select field's WHOLE
# option set and reassigns every option id, which detaches every item already
# using them, so a missing option is reported and left for the captain.
#
# CREDENTIAL AND TOOLING. Projects v2 is GraphQL-only and gh-axi does not
# implement it - its command surface is issue, pr, run, release, repo, label,
# secret, and variable - so this is a deliberate, documented exception to the
# usual prefer-gh-axi rule and uses `gh api graphql` directly. The token
# additionally needs the `project` scope, which `repo` does not imply.
#
# FAIL OPEN. Every function returns non-zero with a reason in
# FM_BOARD_GQL_REASON rather than exiting, so a caller can warn and exit 0. A
# board that is unreachable, unauthorized, rate-limited, or missing can never
# block or fail dispatch, validation, merge, or cleanup.
#
# CALLER CONTRACT. Set FM_BOARD_WORKDIR to a private temporary directory and
# FM_BOARD_TIMEOUT to the per-call bound in seconds before calling anything.
# fm-timeout-lib.sh must already be sourced; each call takes the smaller of its
# own bound and whatever is left of FM_WRITE_BACK_BUDGET.
#
# No side effects on source. set -u / set -e safe.

# These globals are this library's published output: sourcing scripts read them
# after a parse or a call, so shellcheck cannot see their consumers.
# shellcheck disable=SC2034
FM_BOARD_GQL_REASON=
FM_BOARD_OWNER_TYPE=
FM_BOARD_OWNER=
FM_BOARD_NUMBER=

# --- board identity ---------------------------------------------------------

# Parse a board URL into FM_BOARD_OWNER_TYPE / FM_BOARD_OWNER / FM_BOARD_NUMBER.
fm_board_url_parse() {  # <url>
  local pattern
  FM_BOARD_OWNER_TYPE=
  FM_BOARD_OWNER=
  FM_BOARD_NUMBER=
  pattern='^https://github\.com/(orgs|users)/([A-Za-z0-9._-]{1,64})/projects/([1-9][0-9]{0,9})$'
  [[ "${1-}" =~ $pattern ]] || return 1
  case "${BASH_REMATCH[1]}" in
    orgs) FM_BOARD_OWNER_TYPE=organization ;;
    users) FM_BOARD_OWNER_TYPE=user ;;
  esac
  FM_BOARD_OWNER=${BASH_REMATCH[2]}
  FM_BOARD_NUMBER=${BASH_REMATCH[3]}
}

# THE ONE OWNER OF HOW A REPOSITORY IDENTITY IS COMPARED. GitHub resolves an
# owner/repo pair case-insensitively and answers in ITS canonical casing - asking
# it for `helloworldsungin/FIRSTMATE` returns `HelloWorldSungin/firstmate` - so
# `Foo/Bar` and `foo/bar` name one repository rather than two, while a captain
# typing a tracker= or board= token into data/projects.md spells it however they
# like. Any identity firstmate matches against another is therefore normalized
# through this one function, at the point its key is built.
#
# It is a single owner on purpose rather than a fold repeated at each comparison:
# byte-exact matching was the root cause of two separate defects - every issue
# looking absent from its board, and a project's declared board being lost so
# lifecycle sync wrote to the home fallback instead - and fixing them separately
# is what would let a third path diverge from the other two later.
fm_board_identity_key() {  # <identity>
  printf '%s\n' "${1-}" | tr '[:upper:]' '[:lower:]'
}

# Print every registry entry's declaration as "<project> <board> <tracker>",
# with "-" standing in for an absent token and "!" for a malformed one. One
# parser reads both tokens because they are two tokens of the same annotation,
# and a caller that has the pair can route a tracker to its board without a
# second pass over the file.
#
# Two board= tokens in one entry are malformed for the same reason a typo is: an
# entry naming two boards has not said which one is authoritative, and taking
# whichever was written first would write to a board the captain did not mean.
fm_board_registry_scan() {  # <registry-file>
  local registry=${1-}
  [ -f "$registry" ] && [ ! -L "$registry" ] || return 1
  awk '
    $1 == "-" && $2 != "" {
      name = $2
      board = "-"; tracker = "-"
      if ($3 ~ /^\[/) {
        s = ""
        for (i = 3; i <= NF; i++) { s = s (s == "" ? "" : " ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s)
        k = split(s, a, " ")
        bc = 0; tc = 0
        for (j = 1; j <= k; j++) {
          if (a[j] ~ /^board=/)   { bc++; if (bc == 1) { board = a[j];   sub(/^board=/, "", board) } }
          if (a[j] ~ /^tracker=/) { tc++; if (tc == 1) { tracker = a[j]; sub(/^tracker=/, "", tracker) } }
        }
        if (bc > 1) board = "!"
        if (tc > 1) tracker = "!"
        if (bc == 1 && board == "") board = "!"
        if (tc == 1 && tracker == "") tracker = "!"
      }
      print name, board, tracker
    }
  ' "$registry"
}

# Print a project's board declaration - a board URL, or "none" - and return 0.
# Return 1 when the project is absent or declares no board, and 2 with a
# one-line detail phrase when the declaration is malformed, so a typo is
# reported rather than read as "undeclared" and silently resolved to the home
# default.
fm_board_registry_board() {  # <registry-file> <project>
  local registry=${1-} project=${2-} token
  token=$(fm_board_registry_scan "$registry" 2>/dev/null \
    | awk -v n="$project" '$1 == n { print $2; exit }') || return 1
  [ -n "$token" ] || return 1
  case "$token" in
    -) return 1 ;;
    '!')
      printf 'more than one board= token in one entry, or one with an empty value; exactly one is required\n'
      return 2
      ;;
    none) printf 'none\n'; return 0 ;;
  esac
  if ! fm_board_url_parse "$token"; then
    printf 'board=%s is not https://github.com/orgs/<org>/projects/<n>, https://github.com/users/<login>/projects/<n>, or none\n' "$token"
    return 2
  fi
  printf '%s\n' "$token"
}

# Print the board a tracker declaration routes to, by finding the registry entry
# that declares that exact tracker. This is how lifecycle sync resolves a board
# from an issue URL alone: the issue names its tracker, the registry names that
# tracker's project, and the project names its board.
#
# Return 1 when no entry declares the tracker or the matching entry declares no
# board, and 2 with a detail phrase when the match is ambiguous or malformed.
# Several entries agreeing on one board is not ambiguity; disagreeing is.
#
# The tracker spec is matched through fm_board_identity_key rather than
# byte-exactly, for the reason stated there: the key on this side is built from
# an issue URL recorded verbatim, and the registry side is however the captain
# typed it, so one capital letter would otherwise lose the project's declared
# board and let the home fallback answer for it - including for a project that
# declared board=none, which must never be given a board at all.
fm_board_registry_board_for_tracker() {  # <registry-file> <tracker-spec>
  local registry=${1-} tracker=${2-} key boards board declared
  [ -n "$tracker" ] && [ "$tracker" != none ] || return 1
  key=$(fm_board_identity_key "$tracker")
  boards=$(fm_board_registry_scan "$registry" 2>/dev/null \
    | while read -r _ board declared; do
        [ "$board" != - ] || continue
        [ "$(fm_board_identity_key "$declared")" = "$key" ] || continue
        printf '%s\n' "$board"
      done | LC_ALL=C sort -u) || return 1
  [ -n "$boards" ] || return 1
  if [ "$(printf '%s\n' "$boards" | wc -l | tr -d ' ')" -ne 1 ]; then
    printf 'several projects declare tracker=%s with different boards (%s), so no one board owns it\n' \
      "$tracker" "$(printf '%s' "$boards" | tr '\n' ' ')"
    return 2
  fi
  case "$boards" in
    '!')
      printf 'the entry declaring tracker=%s has a malformed board= token\n' "$tracker"
      return 2
      ;;
    none) printf 'none\n'; return 0 ;;
  esac
  if ! fm_board_url_parse "$boards"; then
    printf 'board=%s is not a board URL or none\n' "$boards"
    return 2
  fi
  printf '%s\n' "$boards"
}

# --- the wire surface -------------------------------------------------------

# Private. No caller is offered a way to name a query, mutation, or variable of
# its own: every request this repository can send to a board is one of the named
# operations below, which is what makes that list an allowlist by construction
# rather than by convention.
_fm_board_gql() {  # <output-file> <jq> <query> [-f name=value]...
  local out=$1 filter=$2 query=$3 rc=0 bound workdir=${FM_BOARD_WORKDIR:?fm-board-lib needs FM_BOARD_WORKDIR}
  shift 3
  # Each call takes the smaller of its own bound and whatever is left of the
  # overall budget a caller set, so the caller finishes and reports rather than
  # being killed part-way through by the bound around it.
  bound=$(fm_call_bound "${FM_BOARD_TIMEOUT:-15}")
  if [ "$bound" -le 0 ]; then
    FM_BOARD_GQL_REASON="the write-back budget was already spent, so nothing was sent"
    return 1
  fi
  fm_run_timed "$bound" gh api graphql -f query="$query" "$@" --jq "$filter" \
    > "$out" 2>"$workdir/err" || rc=$?
  case "$rc" in
    0) return 0 ;;
    124|137) FM_BOARD_GQL_REASON="GitHub did not answer within ${bound}s" ;;
    125) FM_BOARD_GQL_REASON="no bounded timeout runner could start, so nothing was sent" ;;
    *)
      if grep -qi 'scope\|INSUFFICIENT_SCOPES\|Resource not accessible' "$workdir/err" 2>/dev/null; then
        FM_BOARD_GQL_REASON="the GitHub token is missing the 'project' scope that Projects boards require"
      elif grep -qi 'rate limit\|secondary rate\|abuse detection' "$workdir/err" 2>/dev/null; then
        FM_BOARD_GQL_REASON="GitHub is rate-limiting this credential, so nothing was written"
      else
        FM_BOARD_GQL_REASON="GitHub rejected the request (the board may be missing, or the credential may lack access)"
      fi
      ;;
  esac
  return 1
}

# Read the board's id, title, and Status field. Writes "project <id>",
# "title <text>", "field <id>", and one "option <id> <name>" line per configured
# status option into <output-file>.
#
# A user board and an organization board are the same query under a different
# root field, and GraphQL has no way to pick a root field by variable, so the one
# placeholder is substituted from the two values fm_board_url_parse can produce.
fm_board_read() {  # <output-file> <owner-type> <owner> <number>
  local out=$1 root=$2 owner=$3 number=$4 query filter
  # shellcheck disable=SC2016  # $login/$number are GraphQL variables sent verbatim; shell expansion here would break the query.
  query='query($login:String!,$number:Int!){
  OWNER_ROOT(login:$login){
    projectV2(number:$number){
      id
      title
      field(name:"Status"){ ... on ProjectV2SingleSelectField { id options { id name } } }
    }
  }
}'
  query=${query/OWNER_ROOT/$root}
  filter=".data.$root.projectV2 | \"project \" + .id, \"title \" + .title, \"field \" + (.field.id // \"\"), (.field.options[]? | \"option \" + .id + \" \" + .name)"
  _fm_board_gql "$out" "$filter" "$query" -f "login=$owner" -F "number=$number"
}

# Print an issue's node id, which is the content id a board item addresses.
fm_board_issue_id() {  # <output-file> <owner> <repo> <number>
  # shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
  _fm_board_gql "$1" '.data.repository.issue.id // empty' \
    'query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ issue(number:$number){ id } } }' \
    -f "owner=$2" -f "name=$3" -F "number=$4"
}

# Print "<owner> <repo> <number>" for an issue's parent, or nothing when it has
# none. A forge that does not expose the relationship is not a failure.
fm_board_issue_parent() {  # <output-file> <owner> <repo> <number>
  # shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
  _fm_board_gql "$1" \
    '.data.repository.issue.parent | select(. != null) | "\(.repository.owner.login) \(.repository.name) \(.number)"' \
    'query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ issue(number:$number){ parent { number repository { name owner { login } } } } } }' \
    -f "owner=$2" -f "name=$3" -F "number=$4"
}

# Read one page of board items. Writes "cursor <end> <hasNext>" and one
# "item <item-id> <owner>/<repo>#<number> <status-name>" line per ISSUE item;
# the status name is last because it is the only field that may contain spaces,
# and "-" stands in for an item with no status set.
#
# Items whose content is a pull request or a draft are deliberately absent from
# the output: reconciliation reasons about issues, and an item this sweep cannot
# see is an item it cannot touch.
fm_board_items_page() {  # <output-file> <project-id> [after-cursor]
  local out=$1 project=$2 after=${3-} query filter
  # shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
  query='query($project:ID!,$after:String){
  node(id:$project){
    ... on ProjectV2 {
      items(first:100, after:$after){
        pageInfo{ hasNextPage endCursor }
        nodes{
          id
          content{ __typename ... on Issue { number repository { name owner { login } } } }
          fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue { name } }
        }
      }
    }
  }
}'
  filter='.data.node.items | ("cursor " + (.pageInfo.endCursor // "-") + " " + (if .pageInfo.hasNextPage then "more" else "end" end)), (.nodes[]? | select(.content.__typename == "Issue") | "item " + .id + " " + .content.repository.owner.login + "/" + .content.repository.name + "#" + (.content.number|tostring) + " " + (.fieldValueByName.name // "-"))'
  if [ -n "$after" ]; then
    _fm_board_gql "$out" "$filter" "$query" -f "project=$project" -f "after=$after"
  else
    _fm_board_gql "$out" "$filter" "$query" -f "project=$project"
  fi
}

# Read one page of a repository's ISSUES. Writes "cursor <end> <hasNext>" and one
# "issue <number> <OPEN|CLOSED>" line per issue.
#
# This connection carries issues alone. That matters more than it looks: a
# repository's REST open_issues_count INCLUDES pull requests, and firstmate used
# it on 2026-08-04 to conclude an ArkNode-AI issue was missing from its board and
# was wrong - membership was already complete at 76 of 76. Reconciliation is
# against this listing, never against that count.
fm_board_tracker_issues_page() {  # <output-file> <owner> <repo> [after-cursor]
  local out=$1 owner=$2 repo=$3 after=${4-} query filter
  # shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
  query='query($owner:String!,$name:String!,$after:String){
  repository(owner:$owner,name:$name){
    issues(first:100, after:$after, orderBy:{field:CREATED_AT,direction:ASC}){
      pageInfo{ hasNextPage endCursor }
      nodes{ number state }
    }
  }
}'
  filter='.data.repository.issues | ("cursor " + (.pageInfo.endCursor // "-") + " " + (if .pageInfo.hasNextPage then "more" else "end" end)), (.nodes[]? | "issue " + (.number|tostring) + " " + .state)'
  if [ -n "$after" ]; then
    _fm_board_gql "$out" "$filter" "$query" -f "owner=$owner" -f "name=$repo" -f "after=$after"
  else
    _fm_board_gql "$out" "$filter" "$query" -f "owner=$owner" -f "name=$repo"
  fi
}

# WRITE 1 of 2. Ensure an issue is a board member and print the item's id.
# addProjectV2ItemById returns the EXISTING item when the content is already on
# the board, so this is the idempotent membership call rather than a blind add:
# a repeated sweep cannot produce a second card.
fm_board_item_add() {  # <output-file> <project-id> <content-id>
  # shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
  _fm_board_gql "$1" '.data.addProjectV2ItemById.item.id // empty' \
    'mutation($project:ID!,$content:ID!){ addProjectV2ItemById(input:{projectId:$project,contentId:$content}){ item { id } } }' \
    -f "project=$2" -f "content=$3"
}

# WRITE 2 of 2. Set one item's Status to an option that ALREADY EXISTS on the
# field. There is no counterpart that creates an option, clears a value, or
# touches any other field, and that is the whole of what firstmate can write to
# a board.
fm_board_item_status_set() {  # <output-file> <project-id> <item-id> <field-id> <option-id>
  # shellcheck disable=SC2016  # GraphQL variables, sent verbatim.
  _fm_board_gql "$1" '.data.updateProjectV2ItemFieldValue.projectV2Item.id // empty' \
    'mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){ updateProjectV2ItemFieldValue(input:{projectId:$project,itemId:$item,fieldId:$field,value:{singleSelectOptionId:$option}}){ projectV2Item { id } } }' \
    -f "project=$2" -f "item=$3" -f "field=$4" -f "option=$5"
}
