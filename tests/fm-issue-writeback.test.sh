#!/usr/bin/env bash
# Tests for tracker write-back: bin/fm-issue-comment.sh, bin/fm-project-board.sh,
# and the bin/fm-work-item-milestone.sh fan-out that keeps them on one vocabulary.
#
# The defect this suite exists to prevent has two halves, and both are silent.
# A tracker that receives a second status comment on every milestone is worse
# than one that receives none, and nobody notices until an issue carries nine of
# them; a forge that is unreachable must never take a task down with it, and
# nobody notices that either until a dispatch fails for a decorative reason.
#
# Matrix:
#   (a) the first milestone creates exactly one comment, carrying the status,
#       the timeline, and nothing fleet-private
#   (b) repeated milestones EDIT that one comment - one create, then updates -
#       and a repeated milestone refreshes its entry instead of duplicating it
#   (c) the comment is found again by its marker among foreign comments, which
#       is what makes a fresh process idempotent
#   (d) a failure partway through a sequence leaves the next update able to find
#       and correct the same comment rather than creating a second
#   (e) every forge failure mode - lookup, read, create, update, absent gh,
#       timeout - warns and still exits 0
#   (f) an out-of-scope work item is reported once and never written to, and a
#       task with no work item is silent
#   (g) a note carrying a credential, an absolute path, a firstmate marker, or a
#       value the task's own record marks private is withheld before anything is
#       published, while the milestone itself still lands
#   (h) the board is inert without configuration - silently, and without being
#       able to fail, whatever target it is handed - idempotent with it, never
#       reshapes the captain's board to fit a milestone, and never touches a
#       field's option set, which would detach every item already using one
#   (i) the fan-out updates both surfaces, one broken surface never stops the
#       other, every milestone in the vocabulary reaches both, and the whole
#       operation is bounded rather than only the calls inside it
#   (j) arming a PR watch and merging the PR record their own milestones on the
#       one comment, and a tracker that refuses them cannot make a completed
#       merge look retryable
#   (k) the vocabulary and the bounded-call contract each keep exactly one
#       owner, because a second copy drifts silently, and the forge library
#       exports its named operations and no general authenticated transport
#   (l) a gitea work item receives the same living comment through the per-host
#       credential: the token travels argv-free and 0600-enforced, a symlinked
#       token file is refused rather than followed, stray whitespace around a
#       token is trimmed rather than misreported as a forge refusal, an absent
#       token, an empty one, an unsupported forge, and a refused credential are
#       four different reported facts, a dry run renders before any credential
#       is resolved, every forge failure warns and exits 0, and the github path
#       never reads a forge token or invokes curl at all
#   (n) the fleet-wide drift sweep reads a project's board from the registry,
#       adds only missing membership - including onto a board holding no items
#       at all, which is the board a new declaration is pointed at first - moves
#       a closed issue to Done and an open one out of it, invents no finer
#       state, removes nothing a human added, writes no field but Status,
#       reconciles against a real issue listing rather than a
#       pull-request-inflated count, walks every page, reports a missing option
#       instead of creating one, bounds and announces its own truncation at the
#       same point a dry run rehearses - including a budget spent while reading
#       or writing, announced as truncation and never as one more broken board,
#       down to the last row of a plan, with no failure inside the loop silent -
#       never mistakes a listing that could not say where it stopped for one
#       that ended, is not disabled by a malformed home fallback it never reads,
#       resolves a project's declared board however the registry spells the
#       repository, and fails open on every board failure mode
#   (o) the sweep walks a FLEET rather than one project: one broken board never
#       stops it reaching the next, one change limit is shared across all of
#       them, and a truncated run names the entries it did not reach and resumes
#       there next time instead of starving the registry's tail
#   (m) no lookup that could not PROVE there is no status comment ever resolves
#       itself by creating one: discovery walks past a host that clamps its page
#       size below the limit asked for, and both a list longer than the walk and
#       a host that re-serves its first page report the gap and write nothing,
#       because guessing in the create direction is what accumulates a comment
#       per milestone
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMENT="$ROOT/bin/fm-issue-comment.sh"
BOARD="$ROOT/bin/fm-project-board.sh"
MILESTONE="$ROOT/bin/fm-work-item-milestone.sh"
TMP_ROOT=$(fm_test_tmproot fm-issue-writeback)

command -v jq >/dev/null 2>&1 || { echo "1..0 # skip jq is required to fake the GitHub API"; exit 0; }

ISSUE_URL='https://github.com/acme/widget/issues/42'
WORK_ITEM="declared|github|$ISSUE_URL"
PR_TARGET='github:github.com/acme/widget'

# --- a fake `gh` that behaves like the API this code actually calls -----------
#
# It keeps real comment state on disk, so idempotency is observed rather than
# asserted: a second comment would simply appear in the store. Failure injection
# is per operation, because "the lookup failed" and "the update failed" leave the
# tracker in different states and must be handled differently.

write_fake_gh() {  # <fakebin>
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
set -u
STORE=${FM_FAKE_GH_STORE:?fake gh needs FM_FAKE_GH_STORE}
mkdir -p "$STORE/comments" "$STORE/items"
LOG="$STORE/calls.log"
FAIL=" ${FM_FAKE_GH_FAIL:-} "

# A host that answers slowly, so a caller running out of its own whole-operation
# budget mid-call is something a case can OBSERVE rather than assert about.
[ -z "${FM_FAKE_GH_DELAY:-}" ] || sleep "$FM_FAKE_GH_DELAY"

fail_with() {  # <token> <message>
  case "$FAIL" in
    *" $1 "*|*" all "*)
      if [ -n "${FM_FAKE_GH_SCOPE_ERROR:-}" ]; then
        echo "gh: Your token has not been granted the required scopes: 'project'" >&2
      elif [ -n "${FM_FAKE_GH_RATE_LIMIT:-}" ]; then
        echo "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again." >&2
      else
        echo "gh: $2" >&2
      fi
      exit 1
      ;;
  esac
}

[ "${1:-}" = api ] || { echo "fake gh: unsupported command: $*" >&2; exit 1; }
shift
METHOD=GET
JQFILTER=
ENDPOINT=
GRAPHQL=0
QUERY=
V_project=
V_item=
V_field=
V_option=
V_content=
V_owner=
V_name=
V_number=
V_after=
while [ "$#" -gt 0 ]; do
  case "$1" in
    graphql) GRAPHQL=1 ;;
    --paginate) ;;
    --method) METHOD=$2; shift ;;
    --jq) JQFILTER=$2; shift ;;
    -F|-f)
      case "$2" in
        query=*) QUERY=${2#query=} ;;
        project=*) V_project=${2#project=} ;;
        item=*) V_item=${2#item=} ;;
        field=*) V_field=${2#field=} ;;
        option=*) V_option=${2#option=} ;;
        content=*) V_content=${2#content=} ;;
        owner=*) V_owner=${2#owner=} ;;
        name=*) V_name=${2#name=} ;;
        number=*) V_number=${2#number=} ;;
        after=*) V_after=${2#after=} ;;
      esac
      shift
      ;;
    *) ENDPOINT=$1 ;;
  esac
  shift
done

emit() {  # <json>
  if [ -n "$JQFILTER" ]; then
    printf '%s' "$1" | jq -r "$JQFILTER"
  else
    printf '%s\n' "$1"
  fi
}

# The board's Status field, as the captain configured it. Option ids are
# positional so a mutation carrying one can be resolved back to its name, which
# is what lets an item's stored status be observed rather than assumed.
status_field_json() {
  if [ -n "${FM_FAKE_GH_NO_STATUS_FIELD:-}" ]; then
    printf 'null'
  else
    printf '%s' "${FM_FAKE_GH_STATUS_OPTIONS:-Todo,In Progress,In review,Done}" \
      | jq -R 'split(",") | {id:"F_status", options:[to_entries[] | {id:("o"+((.key+1)|tostring)), name:.value}]}'
  fi
}

status_name_for_option() {  # <option-id>
  status_field_json | jq -r --arg id "$1" '.options[]? | select(.id == $id) | .name'
}

item_file() { printf '%s/items/%s\n' "$STORE" "$1"; }

# The boards in this fleet carry more than Status - Ark-Signal has Priority,
# Size, Estimate and Start date - so the fake resolves a mutation's FIELD ID to
# the field it names and writes that one. A caller that addressed another field,
# or cleared one, changes that field in the store, which is what makes "no field
# other than Status is ever written" a check that can actually fail.
field_name_for_id() {  # <field-id>
  case "$1" in
    F_status) printf 'Status' ;;
    F_priority) printf 'Priority' ;;
    F_size) printf 'Size' ;;
    F_estimate) printf 'Estimate' ;;
    F_startdate) printf 'Start date' ;;
    *) printf 'Unknown(%s)' "$1" ;;
  esac
}

item_clear_field() {  # <item-id> <field-name>
  local f tmp
  f=$(item_file "$1")
  tmp="$f.tmp"
  grep -v "^f:$2=" "$f" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$f"
}

# An item is stored as its content reference plus one line per FIELD VALUE, so a
# mutation that touched a field it was never meant to touch is visible in the
# store afterwards rather than only in a call log.
item_write_field() {  # <item-id> <field-name> <value>
  local f tmp
  f=$(item_file "$1")
  tmp="$f.tmp"
  grep -v "^f:$2=" "$f" > "$tmp" 2>/dev/null || true
  printf 'f:%s=%s\n' "$2" "$3" >> "$tmp"
  mv "$tmp" "$f"
}

# Content ids are I_<owner>_<repo>_<number>, so an item created by the add
# mutation carries the content reference the listing must report back.
content_reference() {  # <content-id>
  printf '%s' "$1" | awk -F_ '{ printf "%s/%s#%s", $2, $3, $4 }'
}

items_json() {
  local f iid c st
  for f in "$STORE"/items/*; do
    [ -f "$f" ] || continue
    iid=$(basename "$f")
    c=$(sed -n 's/^content=//p' "$f")
    st=$(sed -n 's/^f:Status=//p' "$f")
    jq -n --arg id "$iid" --arg c "$c" --arg st "$st" '
      ($c | capture("^(?<own>[^/]+)/(?<rep>[^#]+)#(?<num>[0-9]+)$")) as $p |
      {id:$id,
       content:{__typename:"Issue", number:($p.num|tonumber),
                repository:{name:$p.rep, owner:{login:$p.own}}},
       fieldValueByName: (if $st == "" then null else {name:$st} end)}'
  done | jq -s '.'
}

# A fleet has several trackers, so a case can seed one listing per repository and
# fall back to the single shared one when it only ever names a single project.
tracker_json() {
  if [ -f "$STORE/tracker-${V_owner}-${V_name}" ]; then
    jq -R -s 'split("\n") | map(select(length > 0) | split(" ") | {number:(.[0]|tonumber), state:.[1]})' \
      < "$STORE/tracker-${V_owner}-${V_name}"
  elif [ -f "$STORE/tracker" ]; then
    jq -R -s 'split("\n") | map(select(length > 0) | split(" ") | {number:(.[0]|tonumber), state:.[1]})' < "$STORE/tracker"
  else
    printf '[]'
  fi
}

# Emit one page of a connection, honouring a page size a case can shrink so the
# walk over several pages is exercised rather than assumed.
emit_page() {  # <nodes-json> <wrapper-jq>
  local nodes=$1 wrapper=$2 size start total slice more
  size=${FM_FAKE_GH_PAGE_SIZE:-100}
  start=0
  case "$V_after" in
    c*) start=${V_after#c} ;;
  esac
  total=$(printf '%s' "$nodes" | jq 'length')
  slice=$(printf '%s' "$nodes" | jq --argjson s "$start" --argjson n "$size" '.[$s:($s+$n)]')
  if [ $((start + size)) -lt "$total" ]; then more=true; else more=false; fi
  # A page that promises more and then names no cursor to follow is a real
  # answer a host can give, and it is the one a caller must not read as "the
  # listing ended here". Nothing else about the page changes, so the difference
  # between an unfinishable walk and a finished one is the only variable.
  if [ -n "${FM_FAKE_GH_ITEMS_CURSOR_LOST:-}" ] && [ "$wrapper" = items ]; then
    emit "$(jq -n --argjson nodes "$slice" --argjson more "$more" \
      '{pageInfo:{hasNextPage:$more, endCursor:null}, nodes:$nodes} | {data:{node:{items:.}}}')"
    return 0
  fi
  emit "$(jq -n --argjson nodes "$slice" --argjson more "$more" \
    --arg cursor "c$((start + size))" --arg wrapper "$wrapper" \
    '{pageInfo:{hasNextPage:$more, endCursor:$cursor}, nodes:$nodes}' \
    | jq --arg w "$wrapper" 'if $w == "items" then {data:{node:{items:.}}} else {data:{repository:{issues:.}}} end')"
}

if [ "$GRAPHQL" = 1 ]; then
  printf '%s\n' "$QUERY" >> "$STORE/graphql.log"
  # A host that never answers a MUTATION, so a caller's whole-operation budget is
  # spent by that one call rather than by a race with everything before it: set
  # this longer than the budget and the call is always cut off by the caller's
  # own remaining share, whatever the reads took. The query is recorded above
  # BEFORE the wait, so a case can prove the mutation was attempted at all.
  case "$QUERY" in
    mutation*) [ -z "${FM_FAKE_GH_WRITE_DELAY:-}" ] || sleep "$FM_FAKE_GH_WRITE_DELAY" ;;
  esac
  case "$QUERY" in
    *updateProjectV2ItemFieldValue*)
      fail_with graphql-status "board status update refused"
      printf 'status\n' >> "$LOG"
      printf 'set\n' >> "$STORE/board-status"
      if [ -f "$(item_file "$V_item")" ]; then
        FIELD_NAME=$(field_name_for_id "$V_field")
        if [ "$FIELD_NAME" = Status ]; then
          item_write_field "$V_item" Status "$(status_name_for_option "$V_option")"
        else
          item_write_field "$V_item" "$FIELD_NAME" "$V_option"
        fi
      fi
      emit '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_1"}}}}'
      exit 0
      ;;
    *clearProjectV2ItemFieldValue*)
      fail_with graphql-clear "board field clear refused"
      printf 'clear\n' >> "$LOG"
      [ ! -f "$(item_file "$V_item")" ] || item_clear_field "$V_item" "$(field_name_for_id "$V_field")"
      emit '{"data":{"clearProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_1"}}}}'
      exit 0
      ;;
    *addProjectV2ItemById*)
      fail_with graphql-add "board membership refused"
      printf 'add\n' >> "$LOG"
      # The real mutation returns the EXISTING item when the content is already
      # on the board, so the same content always answers with the same item id.
      touch "$STORE/board-items"
      grep -qxF "$V_content" "$STORE/board-items" 2>/dev/null \
        || printf '%s\n' "$V_content" >> "$STORE/board-items"
      if [ ! -f "$(item_file "PVTI_$V_content")" ]; then
        printf 'content=%s\n' "$(content_reference "$V_content")" > "$(item_file "PVTI_$V_content")"
      fi
      emit "{\"data\":{\"addProjectV2ItemById\":{\"item\":{\"id\":\"PVTI_$V_content\"}}}}"
      exit 0
      ;;
    *items\(first:*)
      fail_with graphql-items "board item listing refused"
      printf 'items\n' >> "$LOG"
      emit_page "$(items_json)" items
      exit 0
      ;;
    *issues\(first:*)
      fail_with graphql-issues "tracker issue listing refused"
      printf 'issues\n' >> "$LOG"
      emit_page "$(tracker_json)" issues
      exit 0
      ;;
    *parent*)
      fail_with graphql-parent "parent lookup refused"
      printf 'parent\n' >> "$LOG"
      if [ -n "${FM_FAKE_GH_PARENT:-}" ]; then
        set -- $FM_FAKE_GH_PARENT
        emit "{\"data\":{\"repository\":{\"issue\":{\"parent\":{\"number\":$3,\"repository\":{\"name\":\"$2\",\"owner\":{\"login\":\"$1\"}}}}}}}"
      else
        emit '{"data":{"repository":{"issue":{"parent":null}}}}'
      fi
      exit 0
      ;;
    *projectV2\(*)
      fail_with graphql-board "board lookup refused"
      # One board of several refusing, so a fleet case can prove that one
      # project's broken board never stops the sweep reaching the next. The
      # board's number is logged because the ORDER boards are contacted in is
      # the only observable that says where a walk started.
      printf 'board %s\n' "$V_number" >> "$LOG"
      if [ -n "${FM_FAKE_GH_FAIL_BOARD_NUMBER:-}" ] && [ "$V_number" = "${FM_FAKE_GH_FAIL_BOARD_NUMBER}" ]; then
        echo "gh: that board is unreachable" >&2
        exit 1
      fi
      root=user
      case "$QUERY" in *organization\(*) root=organization ;; esac
      emit "{\"data\":{\"$root\":{\"projectV2\":{\"id\":\"PVT_1\",\"title\":\"Fleet\",\"field\":$(status_field_json)}}}}"
      exit 0
      ;;
    *issue\(*)
      fail_with graphql-issue "issue lookup refused"
      printf 'issue\n' >> "$LOG"
      if [ -n "${FM_FAKE_GH_MISSING_ISSUE:-}" ]; then
        emit '{"data":{"repository":{"issue":null}}}'
      else
        emit "{\"data\":{\"repository\":{\"issue\":{\"id\":\"I_${V_owner}_${V_name}_${V_number}\"}}}}"
      fi
      exit 0
      ;;
  esac
  echo "fake gh: unrecognized graphql query" >&2
  exit 1
fi

case "$ENDPOINT" in
  */issues/comments/*)
    id=${ENDPOINT##*/}
    file="$STORE/comments/$id.body"
    if [ "$METHOD" = PATCH ]; then
      fail_with patch "comment update refused"
      cat > "$file"
      printf 'PATCH %s\n' "$id" >> "$LOG"
      emit '{"id":0}'
      exit 0
    fi
    fail_with read "comment read refused"
    printf 'READ %s\n' "$id" >> "$LOG"
    [ -f "$file" ] || { echo "gh: not found" >&2; exit 1; }
    emit "$(jq -n --rawfile b "$file" '{body:$b}')"
    exit 0
    ;;
  */comments|*/comments\?*)
    if [ "$METHOD" = POST ]; then
      fail_with post "comment creation refused"
      next=$(( $(ls "$STORE/comments" 2>/dev/null | wc -l) + 100 ))
      cat > "$STORE/comments/$next.body"
      printf 'POST %s\n' "$next" >> "$LOG"
      emit '{"id":0}'
      exit 0
    fi
    fail_with list "comment listing refused"
    printf 'LIST %s\n' "$ENDPOINT" >> "$LOG"
    doc=$(
      for f in "$STORE"/comments/*.body; do
        [ -f "$f" ] || continue
        id=$(basename "$f" .body)
        jq -n --rawfile b "$f" --argjson id "$id" '{id:$id, body:$b}'
      done | jq -s '.'
    )
    emit "$doc"
    exit 0
    ;;
esac
# A repository read is the REST route to open_issues_count, which INCLUDES pull
# requests. Nothing here may reconcile against it, so the fake records the call
# and answers with the inflated count a caller would have been misled by.
case "$ENDPOINT" in
  repos/*)
    printf 'REST %s\n' "$ENDPOINT" >> "$LOG"
    emit "{\"open_issues_count\":${FM_FAKE_GH_OPEN_ISSUES_COUNT:-0}}"
    exit 0
    ;;
esac
echo "fake gh: unrecognized endpoint '$ENDPOINT'" >&2
exit 1
SH
  chmod +x "$1/gh"
}

# case_dir <name> [work-item] [pr-target]: a home with one task's metadata and a
# fakebin holding the fake gh. Echoes the case directory.
case_dir() {  # <name> [work-item] [pr-target] [extra-meta...]
  local name=$1 item=${2-$WORK_ITEM} target=${3-$PR_TARGET} dir
  shift 3 2>/dev/null || shift $#
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/config" "$dir/fakebin" "$dir/store/comments"
  write_fake_gh "$dir/fakebin"
  {
    printf 'window=fake:1\n'
    printf 'worktree=%s/worktrees/%s\n' "$dir" "$name"
    printf 'project=%s/projects/widget\n' "$dir"
    printf 'harness=claude\n'
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
    printf 'yolo=off\n'
    [ -z "$item" ] || printf 'work_item=%s\n' "$item"
    [ -z "$target" ] || printf 'pr_target=%s\n' "$target"
  } > "$dir/state/task-1.meta"
  printf '%s\n' "$dir"
}

run_comment() {  # <case-dir> [args...]
  local dir=$1
  shift
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GH_STORE="$dir/store" \
    PATH="$dir/fakebin:$PATH" \
    "$COMMENT" status task-1 "$@" 2>&1
}

run_board() {  # <case-dir> [args...]
  local dir=$1
  shift
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GH_STORE="$dir/store" \
    PATH="$dir/fakebin:$PATH" \
    "$BOARD" "$@" 2>&1
}

run_milestone() {  # <case-dir> [args...]
  local dir=$1
  shift
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GH_STORE="$dir/store" \
    PATH="$dir/fakebin:$PATH" \
    "$MILESTONE" task-1 "$@" 2>&1
}

comment_count() {  # <case-dir>
  find "$1/store/comments" -name '*.body' 2>/dev/null | wc -l | tr -d ' '
}

firstmate_comment() {  # <case-dir> -> the one firstmate-owned comment body
  grep -rl 'firstmate-status-comment' "$1/store/comments" 2>/dev/null | head -n 1
}

# A case where the fake was never reached has no call log at all, which is zero
# calls rather than an unanswerable question, so it counts as zero here.
log_count() {  # <case-dir> <token>
  local n
  n=$(grep -c "^$2" "$1/store/calls.log" 2>/dev/null) || n=${n:-0}
  printf '%s\n' "${n:-0}"
}

# --- (a) one comment, correct content ---------------------------------------

test_first_milestone_creates_one_comment() {
  local dir out body
  dir=$(case_dir first)
  out=$(run_comment "$dir" --milestone dispatched) || fail "dispatched milestone failed: $out"
  assert_contains "$out" "created: $ISSUE_URL" "the first milestone did not report a created comment"
  [ "$(comment_count "$dir")" = 1 ] || fail "expected exactly one comment, found $(comment_count "$dir")"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_contains "$body" '<!-- firstmate-status-comment -->' "the comment carries no locating marker"
  assert_contains "$body" '**Status: dispatched**' "the comment does not state its status"
  assert_contains "$body" '<!-- firstmate-status-timeline -->' "the comment carries no timeline"
  assert_contains "$body" ' - dispatched' "the timeline has no entry for this milestone"
  assert_contains "$body" 'updated in place' "the comment does not tell a reader it is a living comment"
  pass "the first milestone creates exactly one marked, readable status comment"
}

test_the_comment_carries_nothing_fleet_private() {
  local dir body
  dir=$(case_dir private)
  run_comment "$dir" --milestone dispatched >/dev/null || fail "dispatched milestone failed"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_not_contains "$body" 'task-1' "the comment leaked the task id"
  assert_not_contains "$body" "$dir" "the comment leaked a private filesystem path"
  assert_not_contains "$body" 'claude' "the comment leaked the worker runtime"
  assert_not_contains "$body" 'no-mistakes' "the comment leaked the delivery posture"
  assert_not_contains "$body" 'yolo' "the comment leaked the autonomy posture"
  pass "a published status comment carries no task id, path, runtime, or fleet posture"
}

# --- (b) repeated milestones edit one comment -------------------------------

test_repeated_milestones_edit_exactly_one_comment() {
  local dir body entries
  dir=$(case_dir repeat)
  run_comment "$dir" --milestone dispatched >/dev/null || fail "dispatched failed"
  run_comment "$dir" --milestone implemented >/dev/null || fail "implemented failed"
  run_comment "$dir" --milestone in-review >/dev/null || fail "in-review failed"
  run_comment "$dir" --milestone in-review >/dev/null || fail "repeated in-review failed"
  run_comment "$dir" --milestone landed >/dev/null || fail "landed failed"
  [ "$(comment_count "$dir")" = 1 ] \
    || fail "five milestones produced $(comment_count "$dir") comments; they must all edit one"
  [ "$(log_count "$dir" POST)" = 1 ] || fail "expected exactly one comment creation"
  [ "$(log_count "$dir" PATCH)" = 4 ] || fail "expected four in-place updates"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_contains "$body" '**Status: landed**' "the comment does not show the latest status"
  entries=$(grep -c '^- 2[0-9][0-9][0-9]-' <<< "$body")
  [ "$entries" = 4 ] \
    || fail "expected four timeline entries (the repeated milestone refreshing its own), got $entries"
  assert_contains "$body" ' - dispatched' "the timeline lost its first milestone"
  assert_contains "$body" ' - implementation committed' "the timeline lost an intermediate milestone"
  pass "repeated milestones edit one comment and a repeat refreshes its own entry"
}

# --- (c) the marker is what makes a fresh process idempotent -----------------

test_the_comment_is_found_again_among_foreign_comments() {
  local dir out
  dir=$(case_dir foreign)
  printf 'a human wrote this first\n' > "$dir/store/comments/1.body"
  run_comment "$dir" --milestone dispatched >/dev/null || fail "dispatched failed"
  printf 'and a human wrote this after\n' > "$dir/store/comments/2.body"
  out=$(run_comment "$dir" --milestone landed) || fail "landed failed"
  assert_contains "$out" "updated: $ISSUE_URL" "a later milestone did not re-find the comment"
  [ "$(comment_count "$dir")" = 3 ] \
    || fail "expected the two human comments plus one firstmate comment"
  [ "$(log_count "$dir" POST)" = 1 ] || fail "the second milestone posted a second comment"
  assert_grep 'a human wrote this first' "$dir/store/comments/1.body" "a human comment was overwritten"
  assert_grep 'a human wrote this after' "$dir/store/comments/2.body" "a human comment was overwritten"
  # The lookup is one bounded call however many pages it walks, so a busy issue
  # must not spend that bound on round trips and silently stop being updated.
  assert_grep 'per_page=100' "$dir/store/calls.log" \
    "the marker lookup asked for GitHub's default page size, so a busy issue would time out looking for its own comment"
  pass "the marker finds the same comment again among comments firstmate does not own"
}

# --- (d) a failure partway through is recoverable ---------------------------

test_a_failed_update_leaves_the_next_one_able_to_correct_it() {
  local dir out body
  dir=$(case_dir recover)
  run_comment "$dir" --milestone dispatched >/dev/null || fail "dispatched failed"
  out=$(FM_FAKE_GH_FAIL='patch' run_comment "$dir" --milestone implemented) \
    || fail "a failed update must not fail the command"
  assert_contains "$out" 'warning:' "a failed update was silent"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_contains "$body" '**Status: dispatched**' "a failed update corrupted the comment"
  out=$(run_comment "$dir" --milestone in-review) || fail "the recovery update failed"
  assert_contains "$out" "updated: $ISSUE_URL" "the recovery update did not find the comment"
  [ "$(comment_count "$dir")" = 1 ] || fail "recovery created a second comment"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_contains "$body" '**Status: in review**' "the recovery update did not correct the status"
  assert_contains "$body" ' - dispatched' "the recovery update lost the earlier timeline"
  pass "a failure partway through leaves the next update able to find and correct the comment"
}

# --- (e) every forge failure is a warning, never a failure ------------------

test_every_forge_failure_warns_and_exits_zero() {
  local dir out rc mode
  for mode in list read post patch; do
    dir=$(case_dir "failopen-$mode")
    [ "$mode" = list ] || [ "$mode" = post ] \
      || run_comment "$dir" --milestone dispatched >/dev/null || fail "seed failed for $mode"
    set +e
    out=$(FM_FAKE_GH_FAIL=$mode run_comment "$dir" --milestone landed)
    rc=$?
    set -e
    expect_code 0 "$rc" "a '$mode' forge failure must not fail the command"
    assert_contains "$out" 'warning:' "a '$mode' forge failure was silent"
  done
  pass "a failing lookup, read, create, or update warns and still exits 0"
}

# A PATH holding every tool this code needs and nothing else, so "gh is absent"
# is a real absence rather than a stub pretending. A missing tool fails the test
# instead of quietly leaving the case unproven.
minimal_bin() {  # <dir>
  local bin="$1/minimal" tool path
  mkdir -p "$bin"
  for tool in env bash date mktemp cat head grep cut tr awk sed wc rm uname stat basename dirname timeout sha256sum shasum; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$path" "$bin/$tool"
  done
  for tool in env bash date mktemp cat head grep cut tr awk wc rm; do
    [ -x "$bin/$tool" ] || fail "minimal PATH is missing $tool, so the absent-gh case would not be proven"
  done
  [ ! -x "$bin/gh" ] || fail "the minimal PATH must not contain gh"
  printf '%s\n' "$bin"
}

test_absent_gh_and_a_hanging_gh_both_fail_open() {
  local dir out rc bin
  dir=$(case_dir nogh)
  bin=$(minimal_bin "$dir")
  set +e
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_FAKE_GH_STORE="$dir/store" PATH="$bin" \
    "$COMMENT" status task-1 --milestone landed 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "an absent gh must not fail the command"
  assert_contains "$out" 'gh is not installed' "an absent gh was not reported"

  dir=$(case_dir hangingh)
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$dir/fakebin/gh"
  set +e
  out=$(FM_ISSUE_COMMENT_TIMEOUT=1 run_comment "$dir" --milestone landed)
  rc=$?
  set -e
  expect_code 0 "$rc" "a hanging forge must not fail the command"
  assert_contains "$out" 'did not answer within' "a hanging forge was not reported as a timeout"
  pass "an absent client and a hanging forge both warn without failing the task"
}

# --- (f) scope: the task's own recorded work item, in its recorded PR target --

test_out_of_scope_work_items_are_reported_and_never_written() {
  local dir out
  dir=$(case_dir crossforge 'declared|gitea|https://gitea.example.com/o/r/issues/7' 'github:github.com/acme/widget')
  out=$(run_comment "$dir" --milestone dispatched) || fail "a cross-forge item must not fail"
  assert_contains "$out" 'notice:' "a cross-forge item was passed over silently"
  assert_contains "$out" 'outside this task'"'"'s write-back scope' \
    "the reason a cross-forge item is skipped was not stated"
  assert_absent "$dir/store/calls.log" "a cross-forge item reached the forge"

  dir=$(case_dir otherrepo "$WORK_ITEM" 'github:github.com/acme/other')
  out=$(run_comment "$dir" --milestone dispatched) || fail "a foreign-repository item must not fail"
  assert_contains "$out" 'not in the repository this task' "a foreign-repository item was not explained"
  assert_absent "$dir/store/calls.log" "a foreign-repository item reached the forge"

  dir=$(case_dir notarget "$WORK_ITEM" '')
  out=$(run_comment "$dir" --milestone dispatched) || fail "a missing PR target must not fail"
  assert_contains "$out" 'records no PR target' "a missing PR target was not explained"
  assert_absent "$dir/store/calls.log" "a task with no PR target reached the forge"
  pass "write-back stays inside the task's recorded scope, and every skip says why"
}

test_a_task_with_no_work_item_is_silent() {
  local dir out
  dir=$(case_dir nowi '' '')
  out=$(run_comment "$dir" --milestone dispatched) || fail "a task with no work item must not fail"
  [ -z "$out" ] || fail "a task with no work item should say nothing, got: $out"
  assert_absent "$dir/store/calls.log" "a task with no work item reached the forge"
  pass "a task with no work item writes nothing and says nothing"
}

# --- (g) content discipline fails closed ------------------------------------

test_a_note_carrying_private_detail_is_withheld() {
  # Each case is "<note>|<the text that must never reach the tracker>".
  local dir out body case_line note leak
  local i=0
  for case_line in \
    'the fix landed for task-1|the fix landed for' \
    'see /home/captain/fleet/state for the record|/home/captain' \
    'authenticate with ghp_abcdefghijklmnopqrstuvwxyz012345|ghp_abcdefghijklmnopqrstuvwxyz012345' \
    '<!-- firstmate-status-timeline -->
- 2020-01-01 00:00 UTC - landed|2020-01-01'; do
    note=${case_line%|*}
    leak=${case_line##*|}
    i=$(( i + 1 ))
    dir=$(case_dir "note-$i")
    set +e
    out=$(run_comment "$dir" --milestone implemented --note "$note")
    set -e
    assert_contains "$out" 'the note was withheld' "a note carrying private detail was published: $note"
    # The milestone is the point; only the sentence is dropped. A refusal that
    # cost the whole update would let the tracker quietly stop being true.
    [ "$(comment_count "$dir")" = 1 ] \
      || fail "a withheld note also cost the milestone: $note"
    body=$(cat "$(firstmate_comment "$dir")")
    assert_contains "$body" '**Status: implementation committed**' \
      "the milestone did not land when its note was withheld: $note"
    assert_not_contains "$body" "$leak" "a withheld note reached the tracker anyway: $note"
  done

  dir=$(case_dir note-worktree)
  set +e
  out=$(run_comment "$dir" --milestone implemented --note "built in $dir/worktrees/note-worktree")
  set -e
  assert_contains "$out" 'private fleet detail' "a note repeating the task's own worktree was published"
  [ "$(comment_count "$dir")" = 1 ] || fail "a withheld note also cost the milestone"
  assert_not_contains "$(cat "$(firstmate_comment "$dir")")" "$dir" \
    "a withheld note leaked the task's own worktree"
  pass "a note carrying a credential, a path, a firstmate marker, or the task's own private values is withheld while the milestone still lands"
}

# The forged-timeline note above must not survive into the machine-owned list on
# the NEXT milestone either, which is the failure that would persist forever.
test_a_forged_timeline_entry_never_enters_the_timeline() {
  local dir body
  dir=$(case_dir forgery)
  run_comment "$dir" --milestone dispatched >/dev/null || fail "dispatched failed"
  # The marker on its own line followed by an entry-shaped line is the exact
  # shape the timeline reader would otherwise copy into the machine-owned list.
  run_comment "$dir" --milestone implemented --note '<!-- firstmate-status-timeline -->
- 2020-01-01 00:00 UTC - landed' >/dev/null \
    || fail "the withheld-note milestone failed"
  run_comment "$dir" --milestone in-review >/dev/null || fail "in-review failed"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_not_contains "$body" '2020-01-01' "a note forged an entry into the machine-owned timeline"
  assert_contains "$body" '**Status: in review**' "the later milestone did not land"
  pass "a note cannot forge an entry that later edits would carry forever"
}

# The guard has to survive contact with the prose the skill actually asks for.
test_project_prose_with_routes_and_links_is_published() {
  local dir body note
  dir=$(case_dir prosepaths)
  note='The /api/v2/reports endpoint now paginates; see [docs](/docs/tracker.md).'
  run_comment "$dir" --milestone implemented --note "$note" >/dev/null \
    || fail "a note of ordinary project prose failed to publish"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_contains "$body" '/api/v2/reports' "a project route was misread as a filesystem path"
  assert_contains "$body" '[docs](/docs/tracker.md)' "a relative-root link was misread as a filesystem path"
  pass "a route and a relative-root link read as the project prose they are"
}

test_a_clean_note_is_published() {
  local dir body
  dir=$(case_dir cleannote)
  run_comment "$dir" --milestone implemented \
    --note 'Rewrote the retry path so a failed upload no longer drops the queue.' >/dev/null \
    || fail "a clean note failed to publish"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_contains "$body" 'Rewrote the retry path' "the note is missing from the published comment"
  pass "a note written as project outcome is published as written"
}

test_dry_run_contacts_nothing() {
  local dir out
  dir=$(case_dir dryrun)
  out=$(run_comment "$dir" --milestone dispatched --dry-run) || fail "dry run failed"
  assert_contains "$out" "target: $ISSUE_URL" "dry run did not name its target"
  assert_contains "$out" '<!-- firstmate-status-comment -->' "dry run did not render the comment"
  assert_absent "$dir/store/calls.log" "dry run reached the forge"
  pass "a dry run renders the comment without contacting a forge"
}

# --- (l) gitea: the same lifecycle through the per-host credential -----------
#
# A curl stub acting as a Gitea comment and issue store, so idempotency and
# credential handling are observed rather than asserted. It reads stdin ONLY
# when `-K` is present, exactly as real curl takes its config from stdin, and
# it answers the `-o <file>` / `-w %{http_code}` shape the transport uses.

write_fake_gitea_curl() {  # <fakebin>
  cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
set -u
STORE=${FM_FAKE_GITEA_STORE:?fake curl needs FM_FAKE_GITEA_STORE}
mkdir -p "$STORE/comments"
LOG="$STORE/curl-calls.log"
printf '%s\n' "$*" >> "${FM_TEST_CURL_ARGS:-$STORE/curl-args.log}"
FAIL=" ${FM_FAKE_GITEA_FAIL:-} "

METHOD=GET
OUT=/dev/null
DATA=
URL=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -K) cat >> "${FM_TEST_CURL_STDIN:-$STORE/curl-stdin.log}" ;;
    -X) METHOD=$2; shift ;;
    -o) OUT=$2; shift ;;
    --data-binary) DATA=${2#@}; shift ;;
    -H|-w|-m) shift ;;
    https://*) URL=$1 ;;
  esac
  shift
done

case "$FAIL" in
  *" unreachable "*) exit 7 ;;
esac

emit() {  # <http-code> <body>
  printf '%s' "$2" > "$OUT"
  printf '%s' "$1"
  exit 0
}

refuse() {  # <op>
  case "$FAIL" in
    *" $1 "*) emit "${FM_FAKE_GITEA_HTTP:-500}" '{"message":"refused"}' ;;
  esac
}

path=${URL#https://}
path=${path#*/api/v1/repos/}
query=
case "$path" in
  *\?*) query=${path##*\?}; path=${path%%\?*} ;;
esac

case "$path" in
  */issues/comments/*)
    id=${path##*/}
    if [ "$METHOD" = PATCH ]; then
      refuse patch
      jq -r '.body' "$DATA" > "$STORE/comments/$id.body"
      printf 'PATCH %s\n' "$id" >> "$LOG"
      emit 200 "{\"id\":$id}"
    fi
    emit 405 '{}'
    ;;
  */issues/*/comments)
    num=${path##*/issues/}
    num=${num%%/*}
    if [ "$METHOD" = POST ]; then
      refuse post
      next=$(( $(ls "$STORE/comments" 2>/dev/null | wc -l) + 100 ))
      jq -r '.body' "$DATA" > "$STORE/comments/$next.body"
      printf 'POST %s\n' "$next" >> "$LOG"
      emit 201 "{\"id\":$next}"
    fi
    refuse list
    printf 'LIST %s\n' "$query" >> "$LOG"
    page=1
    case "$query" in
      *page=*) page=${query#*page=}; page=${page%%&*} ;;
    esac
    # A real Gitea clamps every list to its own api.MAX_RESPONSE_ITEMS, which
    # may be well below the limit asked for; FM_FAKE_GITEA_PAGE_SIZE is how a
    # test stands in for such an instance. FM_FAKE_GITEA_IGNORE_PAGE stands in
    # for the worse shape: a server that clamps AND ignores the page parameter,
    # re-serving its first page forever.
    [ -z "${FM_FAKE_GITEA_IGNORE_PAGE:-}" ] || page=1
    size=${FM_FAKE_GITEA_PAGE_SIZE:-50}
    doc=$(
      for f in "$STORE"/comments/*.body; do
        [ -f "$f" ] || continue
        id=$(basename "$f" .body)
        jq -n --rawfile b "$f" --argjson id "$id" '{id:$id, body:$b}'
      done | jq -s --argjson p "$page" --argjson s "$size" \
        'sort_by(.id) | .[(($p - 1) * $s):($p * $s)]'
    )
    emit 200 "$doc"
    ;;
  */issues/*)
    num=${path##*/}
    if [ "$METHOD" = PATCH ]; then
      refuse close
      state=$(jq -r '.state' "$DATA")
      printf '%s\n' "$state" > "$STORE/issue-$num.state"
      printf 'CLOSE %s\n' "$num" >> "$LOG"
      emit 201 "{\"state\":\"$state\"}"
    fi
    refuse issue
    printf 'ISSUE %s\n' "$num" >> "$LOG"
    state=open
    [ ! -f "$STORE/issue-$num.state" ] || state=$(cat "$STORE/issue-$num.state")
    emit 200 "{\"state\":\"$state\",\"title\":\"T\"}"
    ;;
esac
emit 404 '{}'
SH
  chmod +x "$1/curl"
}

GITEA_ISSUE_URL='https://gitea.example.com/acme/widget/issues/17'
GITEA_WORK_ITEM="declared|gitea|$GITEA_ISSUE_URL"
GITEA_PR_TARGET='gitea:gitea.example.com/acme/widget'
GITEA_TOKEN_VALUE='gitea-secret-token'

gitea_case_dir() {  # <name> [token-mode|none]
  local name=$1 mode=${2-600} dir
  dir=$(case_dir "$name" "$GITEA_WORK_ITEM" "$GITEA_PR_TARGET")
  write_fake_gitea_curl "$dir/fakebin"
  if [ "$mode" != none ]; then
    mkdir -p "$dir/config/forge-tokens"
    printf '%s\n' "$GITEA_TOKEN_VALUE" > "$dir/config/forge-tokens/gitea.example.com"
    chmod "$mode" "$dir/config/forge-tokens/gitea.example.com"
  fi
  printf '%s\n' "$dir"
}

run_gitea_comment() {  # <case-dir> [args...]
  local dir=$1
  shift
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GITEA_STORE="$dir/store" \
    FM_TEST_CURL_ARGS="$dir/curl-args" FM_TEST_CURL_STDIN="$dir/curl-stdin" \
    PATH="$dir/fakebin:$PATH" \
    "$COMMENT" status task-1 "$@" 2>&1
}

gitea_log_count() {  # <case-dir> <token>
  grep -c "^$2" "$1/store/curl-calls.log" 2>/dev/null || true
}

test_gitea_first_milestone_creates_one_comment_with_the_host_token() {
  local dir out body
  dir=$(gitea_case_dir gitea-first)
  out=$(run_gitea_comment "$dir" --milestone dispatched) || fail "gitea dispatched milestone failed: $out"
  assert_contains "$out" "created: $GITEA_ISSUE_URL" "the first gitea milestone did not report a created comment"
  [ "$(comment_count "$dir")" = 1 ] || fail "expected exactly one gitea comment, found $(comment_count "$dir")"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_contains "$body" '<!-- firstmate-status-comment -->' "the gitea comment carries no locating marker"
  assert_contains "$body" '**Status: dispatched**' "the gitea comment does not state its status"
  assert_contains "$body" '<!-- firstmate-status-timeline -->' "the gitea comment carries no timeline"
  assert_no_grep "$GITEA_TOKEN_VALUE" "$dir/curl-args" \
    "the forge token appeared in curl's process arguments"
  assert_grep "$GITEA_TOKEN_VALUE" "$dir/curl-stdin" \
    "the forge token did not reach curl through its stdin config"
  assert_not_contains "$body" "$GITEA_TOKEN_VALUE" "the forge token leaked into the published comment"
  grep -rqF "$GITEA_TOKEN_VALUE" "$dir/state" 2>/dev/null \
    && fail "the forge token was written into state"
  pass "a gitea work item gets one marked status comment, with the token argv-free throughout"
}

test_gitea_repeated_milestones_edit_one_comment() {
  local dir body
  dir=$(gitea_case_dir gitea-repeat)
  run_gitea_comment "$dir" --milestone dispatched >/dev/null || fail "gitea dispatched failed"
  run_gitea_comment "$dir" --milestone implemented >/dev/null || fail "gitea implemented failed"
  run_gitea_comment "$dir" --milestone landed >/dev/null || fail "gitea landed failed"
  [ "$(comment_count "$dir")" = 1 ] \
    || fail "three gitea milestones produced $(comment_count "$dir") comments; they must all edit one"
  [ "$(gitea_log_count "$dir" POST)" = 1 ] || fail "expected exactly one gitea comment creation"
  [ "$(gitea_log_count "$dir" PATCH)" = 2 ] || fail "expected two in-place gitea updates"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_contains "$body" '**Status: landed**' "the gitea comment does not show the latest status"
  assert_contains "$body" ' - dispatched' "the gitea timeline lost its first milestone"
  pass "repeated gitea milestones edit exactly one comment through the marker"
}

test_gitea_absent_token_reports_no_credential_without_a_call() {
  local dir out
  dir=$(gitea_case_dir gitea-notoken none)
  out=$(run_gitea_comment "$dir" --milestone dispatched) || fail "an absent token must not fail"
  assert_contains "$out" 'notice:' "an absent token was passed over silently"
  assert_contains "$out" 'holds no write credential for gitea.example.com' \
    "an absent token was not reported as the missing credential it is"
  assert_contains "$out" 'config/forge-tokens/gitea.example.com is absent' \
    "the notice does not tell the captain where the credential would go"
  assert_absent "$dir/curl-args" "a task with no credential still contacted the forge"
  pass "an absent gitea token is reported as no credential, and nothing is sent"
}

# "There is no file" and "the file is right there and holds nothing" send the
# captain to different places: one is a credential that was never installed, the
# other one that was installed wrongly or emptied. Reporting the second as the
# first is a false statement about a file the captain can see.
test_gitea_empty_token_is_reported_as_present_not_absent() {
  local dir out
  dir=$(gitea_case_dir gitea-emptytoken none)
  mkdir -p "$dir/config/forge-tokens"
  : > "$dir/config/forge-tokens/gitea.example.com"
  chmod 600 "$dir/config/forge-tokens/gitea.example.com"
  out=$(run_gitea_comment "$dir" --milestone dispatched) || fail "an empty token must not fail"
  assert_contains "$out" 'present but empty' \
    "an empty token file was not reported as the present-but-empty file it is"
  assert_not_contains "$out" 'is absent' \
    "a token file that is right there was reported as absent"
  assert_absent "$dir/curl-args" "a task with an empty credential still contacted the forge"
  pass "a present but empty gitea token is its own reported fact, never 'absent'"
}

# A token saved with a stray space is a local file typo. Sent verbatim it draws
# a 401, which this code correctly words as "the forge refused the credential" -
# and that sends the captain to the token's scopes on the forge for a defect
# that is one character in a file on their own disk.
test_gitea_a_token_saved_with_stray_whitespace_still_authenticates() {
  local dir out
  dir=$(gitea_case_dir gitea-padded none)
  mkdir -p "$dir/config/forge-tokens"
  printf '  %s  \n' "$GITEA_TOKEN_VALUE" > "$dir/config/forge-tokens/gitea.example.com"
  chmod 600 "$dir/config/forge-tokens/gitea.example.com"
  out=$(run_gitea_comment "$dir" --milestone dispatched) \
    || fail "a padded token must not fail the command: $out"
  assert_contains "$out" "created: $GITEA_ISSUE_URL" \
    "a token saved with stray whitespace did not reach the forge as a usable credential"
  assert_grep "Authorization: token $GITEA_TOKEN_VALUE\"" "$dir/curl-stdin" \
    "the padding travelled into the Authorization header, where the forge would answer 401"
  pass "a token file's stray leading or trailing whitespace is trimmed, not misreported as a refusal"
}

test_gitea_loose_token_is_refused_before_any_call() {
  local dir out
  dir=$(gitea_case_dir gitea-loose 644)
  out=$(run_gitea_comment "$dir" --milestone dispatched) || fail "a loose token must not fail the command"
  assert_contains "$out" 'mode 0600' "a world-readable token was not refused with a reason"
  assert_absent "$dir/curl-args" "a refused token was still used against the forge"
  pass "a gitea token stored with loose permissions is refused rather than used"
}

test_gitea_refused_credential_is_named() {
  local dir out rc
  dir=$(gitea_case_dir gitea-403)
  set +e
  out=$(FM_FAKE_GITEA_FAIL=list FM_FAKE_GITEA_HTTP=403 run_gitea_comment "$dir" --milestone dispatched)
  rc=$?
  set -e
  expect_code 0 "$rc" "a refused credential must not fail the command"
  assert_contains "$out" 'warning:' "a refused credential was silent"
  assert_contains "$out" 'HTTP 403' "the refusal did not name the HTTP answer"
  assert_contains "$out" 'refused the credential' "the refusal was not attributed to the credential"
  pass "a credential the forge refuses is reported as exactly that, with the HTTP answer"
}

test_gitea_forge_failures_warn_and_exit_zero() {
  local dir out rc mode
  for mode in unreachable list post patch; do
    dir=$(gitea_case_dir "gitea-fail-$mode")
    [ "$mode" != patch ] || run_gitea_comment "$dir" --milestone dispatched >/dev/null \
      || fail "seed failed for $mode"
    set +e
    out=$(FM_FAKE_GITEA_FAIL=$mode run_gitea_comment "$dir" --milestone landed)
    rc=$?
    set -e
    expect_code 0 "$rc" "a gitea '$mode' failure must not fail the command"
    assert_contains "$out" 'warning:' "a gitea '$mode' failure was silent"
  done

  dir=$(gitea_case_dir gitea-hanging)
  cat > "$dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$dir/fakebin/curl"
  set +e
  out=$(FM_ISSUE_COMMENT_TIMEOUT=1 run_gitea_comment "$dir" --milestone landed)
  rc=$?
  set -e
  expect_code 0 "$rc" "a hanging gitea host must not fail the command"
  assert_contains "$out" 'did not answer within' "a hanging gitea host was not reported as a timeout"
  pass "an unreachable, refusing, or hanging gitea host warns and still exits 0"
}

test_gitlab_work_item_reports_no_adapter_not_a_credential_gap() {
  local dir out
  dir=$(case_dir gitlab-item 'declared|gitlab|https://gitlab.example.com/g/p/-/issues/4' 'gitlab:gitlab.example.com/g/p')
  out=$(run_comment "$dir" --milestone dispatched) || fail "a gitlab item must not fail"
  assert_contains "$out" 'no GitLab write-back adapter yet' \
    "the gitlab gap was not reported as the missing adapter it is"
  assert_not_contains "$out" 'credential' \
    "a missing adapter was misreported as a credential problem"
  assert_absent "$dir/store/calls.log" "a gitlab item reached a forge"
  pass "a gitlab work item is an honest missing adapter, never a credential claim"
}

# The pin that GitHub behaviour is unchanged: the github path must never read a
# forge token or invoke curl, even when both sit right there.
test_github_write_back_ignores_forge_tokens_and_curl() {
  local dir out
  dir=$(case_dir gh-ignores-tokens)
  write_fake_gitea_curl "$dir/fakebin"
  mkdir -p "$dir/config/forge-tokens"
  printf 'github-should-never-be-read\n' > "$dir/config/forge-tokens/github.com"
  chmod 600 "$dir/config/forge-tokens/github.com"
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GH_STORE="$dir/store" \
    FM_FAKE_GITEA_STORE="$dir/store" FM_TEST_CURL_ARGS="$dir/curl-args" \
    FM_TEST_CURL_STDIN="$dir/curl-stdin" \
    PATH="$dir/fakebin:$PATH" \
    "$COMMENT" status task-1 --milestone dispatched 2>&1) \
    || fail "the github milestone failed with a forge token present: $out"
  assert_contains "$out" "created: $ISSUE_URL" "the github comment was not created"
  assert_absent "$dir/curl-args" "the github path invoked curl"
  assert_absent "$dir/curl-stdin" "the github path passed a credential to curl"
  pass "a github work item keeps riding gh alone, with forge tokens never read"
}

# --- (m) a lookup that cannot prove absence never resolves itself by creating -
#
# A forge is free to answer a list with fewer items than the limit asked for:
# Gitea clamps every response to its own api.MAX_RESPONSE_ITEMS. A walk that
# treated a short page as the end of the list would fail to find the living
# comment on such an instance and post a second one on every milestone, which is
# the accumulation this whole design exists to prevent.
test_gitea_comment_discovery_survives_a_clamped_page_size() {
  local dir out i
  dir=$(gitea_case_dir gitea-shortpage)
  mkdir -p "$dir/store/comments"
  for i in 1 2 3; do
    printf 'a neighbour comment %s\n' "$i" > "$dir/store/comments/$i.body"
  done
  run_gitea_comment "$dir" --milestone dispatched >/dev/null \
    || fail "seeding the gitea status comment failed"
  [ "$(comment_count "$dir")" = 4 ] \
    || fail "expected three neighbours plus one status comment, found $(comment_count "$dir")"

  out=$(FM_FAKE_GITEA_PAGE_SIZE=2 run_gitea_comment "$dir" --milestone landed) \
    || fail "a host that clamps its page size must not fail: $out"
  assert_contains "$out" "updated: $GITEA_ISSUE_URL" \
    "the status comment was not found past the first clamped page"
  [ "$(comment_count "$dir")" = 4 ] \
    || fail "a host that clamps its page size received a second status comment"
  assert_contains "$(cat "$(firstmate_comment "$dir")")" '**Status: landed**' \
    "the milestone did not reach the one status comment"
  pass "comment discovery walks past a page shorter than the one it asked for"
}

# The other half of the same guarantee. A list longer than the walk covers is
# not an answer of "there is no status comment yet": posting one on that guess
# is how an issue ends up carrying a second comment, and then a third. So the
# cap is reported and nothing is written, which a captain can act on, rather
# than being silently resolved in the direction that accumulates.
test_gitea_an_unwalkable_comment_list_is_reported_and_nothing_is_written() {
  local dir out rc i
  dir=$(gitea_case_dir gitea-longlist)
  mkdir -p "$dir/store/comments"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf 'a neighbour comment %s\n' "$i" > "$dir/store/comments/$i.body"
  done
  set +e
  out=$(FM_FAKE_GITEA_PAGE_SIZE=1 run_gitea_comment "$dir" --milestone dispatched)
  rc=$?
  set -e
  expect_code 0 "$rc" "an unwalkable comment list must not fail the command"
  assert_contains "$out" 'warning:' "an unwalkable comment list was silent"
  assert_contains "$out" 'longer than the 10 pages' \
    "the warning did not say the comment list outran the lookup"
  [ "$(comment_count "$dir")" = 12 ] \
    || fail "a comment was posted on a guess after the page cap was reached"
  [ "$(gitea_log_count "$dir" LIST)" = 10 ] \
    || fail "expected exactly 10 walked pages, got $(gitea_log_count "$dir" LIST)"
  pass "a comment list longer than the walk is reported, never resolved by posting a second comment"
}

# The third face of the same rule, and the one that hides best. A server that
# clamps its list AND ignores the page parameter answers page 2 with page 1, so
# the walk is right back where it started and can never see the end of the list.
# That is the SAME state as running out of pages - "could not prove absence" -
# and it must take the same branch: warn and write nothing. Resolving it as
# "there is no comment yet" would post one on every single milestone, forever.
test_gitea_a_paginator_that_never_advances_never_produces_a_create() {
  local dir out rc i
  dir=$(gitea_case_dir gitea-ignorepage)
  run_gitea_comment "$dir" --milestone dispatched >/dev/null \
    || fail "seeding the gitea status comment failed"
  # Neighbours with lower ids than the seeded status comment, so the clamped
  # first page holds none of firstmate's own work.
  mkdir -p "$dir/store/comments"
  for i in 1 2 3; do
    printf 'a neighbour comment %s\n' "$i" > "$dir/store/comments/$i.body"
  done
  [ "$(comment_count "$dir")" = 4 ] \
    || fail "expected three neighbours plus one status comment, found $(comment_count "$dir")"

  set +e
  out=$(FM_FAKE_GITEA_IGNORE_PAGE=1 FM_FAKE_GITEA_PAGE_SIZE=2 \
    run_gitea_comment "$dir" --milestone landed)
  rc=$?
  set -e
  expect_code 0 "$rc" "a host that ignores pagination must not fail the command"
  assert_contains "$out" 'warning:' "a walk that could not advance was silent"
  assert_contains "$out" 'same first comment' \
    "the warning did not say the host re-served the page the walk had already seen"
  [ "$(comment_count "$dir")" = 4 ] \
    || fail "a host that ignores pagination received a second status comment"
  [ "$(gitea_log_count "$dir" POST)" = 1 ] \
    || fail "the walk resolved 'cannot prove absence' by posting: $(gitea_log_count "$dir" POST) creations"
  assert_contains "$(cat "$(firstmate_comment "$dir")")" '**Status: dispatched**' \
    "the refused milestone was written to the tracker anyway"
  pass "a paginator that re-serves its first page is reported, and never resolved by a create"
}

# A symlink is refused for the same reason a loose mode is: the 0600 check would
# then describe the link rather than the bytes, and what the link points at can
# be replaced without the credential path ever changing.
test_gitea_symlinked_token_is_refused_before_any_call() {
  local dir out
  dir=$(gitea_case_dir gitea-symlink none)
  mkdir -p "$dir/config/forge-tokens"
  printf '%s\n' "$GITEA_TOKEN_VALUE" > "$dir/token-elsewhere"
  chmod 600 "$dir/token-elsewhere"
  ln -s "$dir/token-elsewhere" "$dir/config/forge-tokens/gitea.example.com"
  out=$(run_gitea_comment "$dir" --milestone dispatched) || fail "a symlinked token must not fail the command"
  assert_contains "$out" 'regular file' "a symlinked token was not refused with a reason"
  assert_not_contains "$out" 'is absent' "a token file that is right there was reported as absent"
  assert_absent "$dir/curl-args" "a symlinked token was still used against the forge"
  pass "a token reached through a symlink is refused rather than followed"
}

# A dry run is what a captain uses to review outward-facing content before any
# credential exists, so it must render on a home holding none. Resolving the
# credential first would turn the one offline command into one more thing that
# needs a token.
test_gitea_dry_run_renders_without_a_credential_or_a_call() {
  local dir out
  dir=$(gitea_case_dir gitea-dryrun none)
  out=$(run_gitea_comment "$dir" --milestone dispatched --dry-run) \
    || fail "a gitea dry run failed: $out"
  assert_contains "$out" "target: $GITEA_ISSUE_URL" "the gitea dry run did not name its target"
  assert_contains "$out" '**Status: dispatched**' "the gitea dry run did not render the comment"
  assert_not_contains "$out" 'credential' "a dry run reported a credential it never needed"
  assert_absent "$dir/curl-args" "a gitea dry run reached the forge"
  pass "a gitea dry run renders offline, before any credential is resolved"
}

test_gitea_milestone_fanout_updates_the_comment() {
  local dir out
  dir=$(gitea_case_dir gitea-fanout)
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GITEA_STORE="$dir/store" \
    FM_TEST_CURL_ARGS="$dir/curl-args" FM_TEST_CURL_STDIN="$dir/curl-stdin" \
    PATH="$dir/fakebin:$PATH" \
    "$MILESTONE" task-1 --milestone landed 2>&1) \
    || fail "the milestone fan-out failed for a gitea work item: $out"
  [ "$(comment_count "$dir")" = 1 ] || fail "the fan-out did not write the gitea status comment"
  assert_contains "$(cat "$(firstmate_comment "$dir")")" '**Status: landed**' \
    "the fan-out milestone did not reach the gitea comment"
  pass "the one milestone fan-out reaches a gitea tracker exactly as it reaches GitHub"
}

# --- (h) the captain's board -------------------------------------------------

board_case() {  # <name> [board-url]
  local dir url=${2-https://github.com/users/captain/projects/7}
  dir=$(case_dir "$1")
  [ -z "$url" ] || printf '%s\n' "$url" > "$dir/config/project-board"
  printf '%s\n' "$dir"
}

test_the_board_is_inert_without_configuration() {
  local dir out
  dir=$(board_case boardless '')
  out=$(run_board "$dir" sync --task task-1 --milestone dispatched) \
    || fail "an unconfigured board must not fail"
  [ -z "$out" ] || fail "an unconfigured board should say nothing, got: $out"
  assert_absent "$dir/store/calls.log" "an unconfigured board contacted GitHub"
  pass "without config/project-board nothing is written and no host is contacted"
}

# A home with no board anywhere is the ordinary case, and today it is EVERY home
# until a captain adds the first board= token. It has to stay completely inert
# there: silent on a work item no GitHub board could hold, and unable to fail at
# all, because a board this home does not have cannot be a reason a milestone
# reports a problem.
test_a_home_with_no_board_is_inert_whatever_it_is_handed() {
  local dir out rc
  dir=$(board_case boardlessgitea '')
  printf 'work_item=declared|gitea|https://git.example.com/acme/widget/issues/7\n' >> "$dir/state/task-1.meta"
  sed -i.bak '/^work_item=declared|github/d' "$dir/state/task-1.meta" && rm -f "$dir/state/task-1.meta.bak"
  out=$(run_board "$dir" sync --task task-1 --milestone dispatched) \
    || fail "a boardless home must not fail on a non-GitHub work item"
  [ -z "$out" ] || fail "a boardless home reported a board it does not have, got: $out"

  rc=0
  out=$(run_board "$dir" sync --issue not-a-url --milestone dispatched) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a boardless home failed the command over a target no board would have read, exit $rc: $out"
  [ -z "$out" ] || fail "a boardless home reported a target it never had a board for, got: $out"
  assert_absent "$dir/store/calls.log" "a boardless home contacted GitHub"

  # The same home once a project declares a board: now the target genuinely
  # matters again, so the checks above cannot be passing because sync went quiet
  # everywhere.
  mkdir -p "$dir/data"
  printf -- '- widget [no-mistakes tracker=github:github.com/acme/widget board=https://github.com/users/captain/projects/7] - fixture (added 2026-08-18)\n' \
    > "$dir/data/projects.md"
  rc=0
  out=$(run_board "$dir" sync --issue not-a-url --milestone dispatched) || rc=$?
  [ "$rc" -ne 0 ] || fail "a home that declares a board accepted a malformed --issue: $out"
  pass "a home with no board anywhere stays silent and cannot fail, whatever target it is handed"
}

test_board_membership_and_status_are_idempotent() {
  local dir out
  dir=$(board_case boardsync)
  out=$(run_board "$dir" sync --task task-1 --milestone dispatched) || fail "board sync failed: $out"
  assert_contains "$out" 'tracks' "the board sync did not report the item"
  out=$(run_board "$dir" sync --task task-1 --milestone in-review) || fail "second board sync failed"
  [ "$(wc -l < "$dir/store/board-items" | tr -d ' ')" = 1 ] \
    || fail "a repeated sync produced more than one board card"
  [ "$(log_count "$dir" add)" = 2 ] || fail "expected one idempotent membership call per sync"
  [ "$(log_count "$dir" status)" = 2 ] || fail "expected the status to be driven on each sync"
  pass "repeated board syncs keep exactly one card and keep driving its status"
}

test_the_board_is_never_reshaped_to_fit_a_milestone() {
  local dir out
  dir=$(board_case boardoptions)
  out=$(FM_FAKE_GH_STATUS_OPTIONS='Todo,Done' run_board "$dir" sync --task task-1 --milestone in-review)
  assert_contains "$out" 'no option matching' "an unmatched milestone was not reported"
  [ "$(wc -l < "$dir/store/board-items" | tr -d ' ')" = 1 ] \
    || fail "membership was lost when the status could not be set"
  [ "$(log_count "$dir" status)" = 0 ] \
    || fail "a milestone with no matching option still wrote a status"

  dir=$(board_case boardnofield)
  out=$(FM_FAKE_GH_NO_STATUS_FIELD=1 run_board "$dir" sync --task task-1 --milestone landed)
  assert_contains "$out" 'no single-select Status field' "a board without a Status field was not reported"
  [ "$(log_count "$dir" add)" = 1 ] || fail "membership was skipped when the board had no Status field"
  pass "a milestone the board has no option for is reported, never invented"
}

test_the_board_ensures_the_parent_epic() {
  local dir
  dir=$(board_case boardparent)
  FM_FAKE_GH_PARENT='acme widget 4' run_board "$dir" sync --task task-1 --milestone dispatched >/dev/null \
    || fail "board sync with a parent failed"
  [ "$(log_count "$dir" add)" = 2 ] \
    || fail "the story's parent epic was not ensured on the board"
  pass "a story's parent epic is put on the board through GitHub's own relationship"
}

# Adding or changing an option on a single-select field replaces the field's
# whole option set and reassigns every option id, which detaches every item using
# them: one added option blanked all twenty statuses on the real board. So the
# board's write surface must stay membership plus a value on an option that
# already exists, whatever milestone it is handed.
test_the_board_never_mutates_the_captains_field_schema() {
  local dir milestone names name log
  dir=$(board_case boardschema)
  for milestone in queued dispatched implemented validated in-review landed blocked stopped; do
    FM_FAKE_GH_STATUS_OPTIONS='Todo,Done' \
      run_board "$dir" sync --task task-1 --milestone "$milestone" >/dev/null \
      || fail "board sync failed for milestone $milestone"
  done
  log="$dir/store/graphql.log"
  assert_present "$log" "the board sync sent no GraphQL at all, so nothing was proven"
  names=$(grep -oE '(add|update|create|delete|clear)ProjectV2[A-Za-z]*' "$log" | sort -u)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      addProjectV2ItemById|updateProjectV2ItemFieldValue) ;;
      *) fail "the board sync called '$name', which is outside membership and setting an existing option" ;;
    esac
  done <<EOF
$names
EOF
  # Without this the allowlist above would pass on a run that mutated nothing
  # because it reached GitHub for nothing.
  assert_contains "$names" 'addProjectV2ItemById' "the board sync never added membership, so nothing was proven"
  assert_contains "$names" 'updateProjectV2ItemFieldValue' "the board sync never set a status, so nothing was proven"
  pass "no milestone can make the board create, change, or delete a field or a status option"
}

test_a_board_failure_is_reported_and_never_fatal() {
  local dir out rc
  dir=$(board_case boardscope)
  set +e
  out=$(FM_FAKE_GH_FAIL=graphql-board FM_FAKE_GH_SCOPE_ERROR=1 \
    run_board "$dir" sync --task task-1 --milestone dispatched)
  rc=$?
  set -e
  expect_code 0 "$rc" "a board failure must not fail the command"
  assert_contains "$out" "'project' scope" "a missing project scope was not named"

  dir=$(board_case boardbadurl 'https://example.com/not-a-board')
  set +e
  out=$(run_board "$dir" sync --task task-1 --milestone dispatched)
  rc=$?
  set -e
  expect_code 0 "$rc" "a malformed board URL must not fail the command"
  assert_contains "$out" 'warning:' "a malformed board URL was silent"
  assert_absent "$dir/store/calls.log" "a malformed board URL still contacted GitHub"
  pass "an unauthorized or misconfigured board reports the reason and stops there"
}

# --- (i) one milestone, both surfaces ---------------------------------------

test_one_milestone_updates_both_surfaces() {
  local dir out
  dir=$(board_case fanout)
  out=$(run_milestone "$dir" --milestone dispatched) || fail "the milestone fan-out failed: $out"
  [ "$(comment_count "$dir")" = 1 ] || fail "the fan-out did not write the status comment"
  [ "$(wc -l < "$dir/store/board-items" | tr -d ' ')" = 1 ] || fail "the fan-out did not update the board"
  pass "one milestone command updates both the tracker comment and the board"
}

test_a_broken_surface_does_not_stop_the_other() {
  local dir out rc
  dir=$(board_case fanout-broken)
  set +e
  out=$(FM_FAKE_GH_FAIL=list run_milestone "$dir" --milestone dispatched)
  rc=$?
  set -e
  expect_code 0 "$rc" "a broken surface must not fail the milestone"
  assert_contains "$out" 'warning:' "the broken surface was silent"
  [ "$(wc -l < "$dir/store/board-items" | tr -d ' ')" = 1 ] \
    || fail "a failing comment surface stopped the board from being updated"
  pass "one unreachable surface never stops the other from being kept true"
}

# Every token the board maps has to survive the fan-out, because a mapping no
# command can reach is a documented behaviour that does not happen.
test_every_milestone_in_the_vocabulary_reaches_both_surfaces() {
  local dir out milestone
  for milestone in queued dispatched implemented validated in-review landed blocked stopped; do
    dir=$(board_case "vocab-$milestone")
    out=$(run_milestone "$dir" --milestone "$milestone") \
      || fail "the fan-out refused milestone '$milestone': $out"
    [ "$(comment_count "$dir")" = 1 ] \
      || fail "milestone '$milestone' did not reach the status comment"
    [ "$(wc -l < "$dir/store/board-items" | tr -d ' ')" = 1 ] \
      || fail "milestone '$milestone' did not reach the board"
  done
  pass "every milestone the board maps is reachable through the one fan-out command"
}

# One surface refusing a caller's argument used to hard-exit before the other ran.
test_a_caller_error_is_caught_before_either_surface_runs() {
  local dir out rc
  dir=$(board_case argcheck)
  set +e
  out=$(run_milestone "$dir" --milestone dispatched --note-file "$dir/does-not-exist")
  rc=$?
  set -e
  expect_code 1 "$rc" "a bad --note-file must be a caller error"
  assert_contains "$out" 'must be a regular file' "a bad --note-file was not explained"
  assert_absent "$dir/store/calls.log" "a caller error still wrote to a surface"
  [ "$(comment_count "$dir")" = 0 ] || fail "a caller error still published a comment"
  pass "an invalid argument is one usage error with nothing written, on either surface"
}

# Each surface bounds its own calls, but a caller runs the fan-out, so the bound
# that matters is the one on the whole operation.
test_the_whole_fanout_is_bounded_not_just_each_call() {
  local dir out rc started elapsed
  dir=$(board_case bounded)
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
sleep 120
SH
  chmod +x "$dir/fakebin/gh"
  started=$SECONDS
  set +e
  out=$(FM_WORK_ITEM_MILESTONE_TIMEOUT=4 run_milestone "$dir" --milestone dispatched)
  rc=$?
  set -e
  elapsed=$(( SECONDS - started ))
  expect_code 0 "$rc" "a black-holing forge must not fail the milestone"
  [ "$elapsed" -le 12 ] \
    || fail "the fan-out took ${elapsed}s against a 4s budget, so only the calls are bounded"
  assert_contains "$out" 'warning:' "a black-holing forge was silent"
  pass "the whole milestone fan-out is bounded, so decoration cannot add minutes to a dispatch or a merge"
}

test_an_unknown_milestone_is_a_usage_error() {
  local out rc dir
  dir=$(case_dir badmilestone)
  set +e
  out=$(run_comment "$dir" --milestone shipped-ish)
  rc=$?
  set -e
  expect_code 1 "$rc" "an unknown milestone must be refused"
  assert_contains "$out" 'must be one of' "an unknown milestone was not explained"
  pass "an unknown milestone is a caller error rather than a silently skipped update"
}

# --- (j) the milestones that must not depend on anyone remembering -----------
#
# A milestone firstmate has to remember to post is one it will eventually forget,
# and the reader of the issue cannot tell a task that stalled from one nobody
# reported on. So the three that matter most are posted by the scripts that
# already perform the step. A merge runs the PR check first, which makes it the
# one command that drives two of them, and therefore the one place a second
# comment would appear if the two call sites did not find each other's work.

test_the_merge_path_posts_its_own_milestones() {
  local dir out rc body
  dir=$(board_case mergepath)
  mkdir -p "$dir/wt" "$dir/projects/widget"
  # `gh api` is the fake GitHub; every other `gh` call fm-pr-check.sh makes
  # answers as the PR-head lookup, and gh-axi records the merge.
  mv "$dir/fakebin/gh" "$dir/fakebin/gh-api-fake"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  exec "$(dirname "$0")/gh-api-fake" "$@"
fi
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefOid*) printf '%s\n' deadbeefcafe ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi"

  set +e
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GH_STORE="$dir/store" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-merge.sh" task-1 https://github.com/acme/widget/pull/9 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "the merge path failed: $out"
  assert_grep 'pr merge 9 --repo acme/widget' "$dir/gh-axi.log" "the PR was never merged"
  [ "$(comment_count "$dir")" = 1 ] \
    || fail "arming and merging produced $(comment_count "$dir") comments instead of one"
  body=$(cat "$(firstmate_comment "$dir")")
  assert_contains "$body" '**Status: landed**' "the merge did not record the landing"
  assert_contains "$body" ' - in review' "arming the PR watch did not record the open PR"
  assert_contains "$body" ' - landed' "the landing is missing from the timeline"
  [ "$(wc -l < "$dir/store/board-items" | tr -d ' ')" = 1 ] \
    || fail "the merge path left more than one board card"
  pass "arming a PR and merging it record themselves on one comment, without anyone remembering to"
}

test_a_refusing_tracker_never_makes_a_completed_merge_look_retryable() {
  local dir out rc
  dir=$(board_case mergepath-refused)
  mkdir -p "$dir/wt" "$dir/projects/widget"
  mv "$dir/fakebin/gh" "$dir/fakebin/gh-api-fake"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  exec "$(dirname "$0")/gh-api-fake" "$@"
fi
exit 0
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi"

  set +e
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GH_STORE="$dir/store" \
    FM_FAKE_GH_FAIL=all \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-merge.sh" task-1 https://github.com/acme/widget/pull/9 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a refusing tracker made a completed merge look retryable"
  assert_grep 'pr merge 9 --repo acme/widget' "$dir/gh-axi.log" \
    "the merge did not happen while the tracker was unreachable"
  assert_contains "$out" 'warning: status comment not updated' \
    "a tracker that refused the merge's milestone said nothing"
  pass "a tracker that refuses a merge's milestone warns and the merge still stands"
}

# --- (k) one owner per shared contract ---------------------------------------
#
# The lifecycle vocabulary and the bounded-call contract were each given a
# library precisely so a second copy could not drift from the first. A surface
# that re-rolls either one reintroduces the defect the extraction removed, and it
# does so invisibly: the duplicate keeps working right up to the day the two
# disagree about which tokens exist or how long a forge may take.

test_the_shared_contracts_have_exactly_one_owner() {
  local script
  for script in fm-issue-comment.sh fm-project-board.sh fm-work-item-milestone.sh; do
    assert_grep 'fm-milestone-lib.sh' "$ROOT/bin/$script" \
      "bin/$script does not take the milestone vocabulary from bin/fm-milestone-lib.sh"
  done
  for script in fm-issue-comment.sh fm-project-board.sh fm-work-item-milestone.sh \
    fm-issue-status.sh; do
    assert_grep 'fm-timeout-lib.sh' "$ROOT/bin/$script" \
      "bin/$script does not take the bounded-call contract from bin/fm-timeout-lib.sh"
    if grep -Eq '^[[:space:]]*(fm_)?run_timed\(\)' "$ROOT/bin/$script"; then
      fail "bin/$script defines its own bounded runner instead of using bin/fm-timeout-lib.sh"
    fi
    if grep -q 'FM_MILESTONE_TOKENS=' "$ROOT/bin/$script"; then
      fail "bin/$script owns a second copy of the vocabulary bin/fm-milestone-lib.sh owns"
    fi
  done
  pass "the vocabulary and the bounded-call contract each have one owner, not a copy per surface"
}

# The functions a library actually exports once sourced, minus the ones its own
# dependencies bring, which is its public surface as a caller experiences it.
forge_lib_exports() {  # <lib>...
  bash -c 'for lib; do . "$lib"; done; compgen -A function' bash "$@" | LC_ALL=C sort
}

# The write allowlist has to hold by CONSTRUCTION, not by every caller behaving.
# A general authenticated transport reachable from outside the library would let
# any future sourcing script take the on-disk credential to any endpoint on the
# host - a branch, a release, a repository setting - which is exactly the reach
# a narrow token is issued to prevent, and it would do so without touching a
# line of the library that documents the opposite. This exercises the library's
# public surface rather than its source text: it sources it and compares the
# names it exports against the allowlist itself.
test_the_forge_library_exports_only_its_named_operations() {
  local base surface added expected
  base=$(forge_lib_exports "$ROOT/bin/fm-timeout-lib.sh")
  surface=$(forge_lib_exports "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-forge-lib.sh")
  added=$(LC_ALL=C comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$surface") \
    | grep -v '^_' || true)
  expected=$(printf '%s\n' \
    fm_forge_scratch_set \
    fm_forge_token_read \
    fm_forge_write_supported \
    fm_gitea_comment_create \
    fm_gitea_comment_update \
    fm_gitea_comments_page \
    fm_gitea_issue_close \
    fm_gitea_issue_read | LC_ALL=C sort)
  if printf '%s\n' "$surface" | grep -qx 'fm_forge_curl'; then
    fail "bin/fm-forge-lib.sh exports a general authenticated transport again; the allowlist is back to a convention"
  fi
  [ "$added" = "$expected" ] || fail "bin/fm-forge-lib.sh's exported surface is no longer its allowlist.
expected:
$expected
got:
$added"
  pass "the forge library exports its named operations and no general transport"
}


# --- (n) fleet-wide board drift reconciliation -------------------------------
#
# The sweep is the most destructive thing in this repository's reach: it writes
# to boards carrying hundreds of items that firstmate never dispatched. So every
# case below observes the STORE the fake keeps, not only the calls made - a
# mutation that touched a field it was never meant to touch shows up as a
# changed field value, which no call-log assertion could catch.

BOARD_URL_FIXTURE='https://github.com/users/captain/projects/7'

sweep_case() {  # <name> [board-token] [tracker-token]
  local name=$1 board=${2-board=$BOARD_URL_FIXTURE} tracker=${3-tracker=github:github.com/acme/widget} dir
  dir=$(case_dir "$name")
  mkdir -p "$dir/data"
  {
    printf '# Projects\n\n'
    printf -- '- widget [no-mistakes +yolo %s %s] - the fixture project (added 2026-08-18)\n' \
      "$tracker" "$board"
  } > "$dir/data/projects.md"
  printf '%s\n' "$dir"
}

# A registry declaring SEVERAL projects, which is the shape the fleet sweep
# exists for and the one sweep_case cannot build: every behaviour that spans
# projects - a broken board not stopping the walk, one change limit shared
# across all of them, a truncation stopping the whole sweep, and where the next
# sweep resumes - is invisible to a fixture with a single entry.
#
# Each project tracks acme/<name> and declares board <n>, so the boards are
# distinguishable in the fake's call log and one of them can refuse on its own.
sweep_multi_case() {  # <name> <project>:<board-number>...
  local name=$1 dir entry project number
  shift
  dir=$(case_dir "$name")
  mkdir -p "$dir/data"
  {
    printf '# Projects\n\n'
    for entry in "$@"; do
      project=${entry%%:*}
      number=${entry##*:}
      printf -- '- %s [no-mistakes +yolo tracker=github:github.com/acme/%s board=https://github.com/users/captain/projects/%s] - fixture (added 2026-08-18)\n' \
        "$project" "$project" "$number"
    done
  } > "$dir/data/projects.md"
  printf '%s\n' "$dir"
}

seed_repo_tracker() {  # <case-dir> <owner> <repo> <"<number> <OPEN|CLOSED>">...
  local dir=$1 owner=$2 repo=$3 line
  shift 3
  : > "$dir/store/tracker-$owner-$repo"
  for line in "$@"; do printf '%s\n' "$line" >> "$dir/store/tracker-$owner-$repo"; done
}

# seed_item <case-dir> <owner> <repo> <number> <status> [<field>=<value>...]
# An empty <status> seeds an item the captain has left with no status set.
seed_item() {
  local dir=$1 owner=$2 repo=$3 num=$4 status=$5 field
  shift 5
  mkdir -p "$dir/store/items"
  {
    printf 'content=%s/%s#%s\n' "$owner" "$repo" "$num"
    [ -z "$status" ] || printf 'f:Status=%s\n' "$status"
    for field in "$@"; do printf 'f:%s\n' "$field"; done
  } > "$dir/store/items/PVTI_I_${owner}_${repo}_${num}"
}

seed_tracker() {  # <case-dir> <"<number> <OPEN|CLOSED>">...
  local dir=$1 line
  shift
  : > "$dir/store/tracker"
  for line in "$@"; do printf '%s\n' "$line" >> "$dir/store/tracker"; done
}

item_status() {  # <case-dir> <owner> <repo> <number>
  sed -n 's/^f:Status=//p' "$1/store/items/PVTI_I_${2}_${3}_${4}" 2>/dev/null
}

item_fields() {  # <case-dir> <owner> <repo> <number>
  grep '^f:' "$1/store/items/PVTI_I_${2}_${3}_${4}" 2>/dev/null | grep -v '^f:Status=' | LC_ALL=C sort
}

test_a_closed_issue_reads_done_and_an_open_one_is_left_alone() {
  local dir out
  dir=$(sweep_case sweepdone)
  seed_tracker "$dir" '1 OPEN' '2 CLOSED' '3 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  seed_item "$dir" acme widget 2 'In Progress'
  seed_item "$dir" acme widget 3 'Done'
  out=$(run_board "$dir" reconcile) || fail "the sweep failed: $out"
  [ "$(item_status "$dir" acme widget 2)" = Done ] \
    || fail "a closed issue left in 'In Progress' was not corrected to Done"
  [ "$(item_status "$dir" acme widget 1)" = Todo ] \
    || fail "an open issue's status was changed, and only a drift into Done should move one"
  [ "$(item_status "$dir" acme widget 3)" = Done ] || fail "a correct item was disturbed"
  [ "$(log_count "$dir" status)" = 1 ] \
    || fail "expected exactly one status write, got $(log_count "$dir" status)"
  assert_contains "$out" '1 status corrected' "the sweep did not report what it corrected"
  pass "a closed issue reads Done without anyone intervening, and an open one is left where it is"
}

test_an_issue_absent_from_its_board_is_added() {
  local dir out
  dir=$(sweep_case sweepadd)
  seed_tracker "$dir" '1 OPEN' '2 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  out=$(run_board "$dir" reconcile) || fail "the sweep failed: $out"
  assert_present "$dir/store/items/PVTI_I_acme_widget_2" "the missing issue was not added to the board"
  [ "$(item_status "$dir" acme widget 2)" = Done ] \
    || fail "an added closed issue was not also given its Done status"
  assert_contains "$out" '1 added' "the sweep did not report the membership it added"
  pass "an issue absent from its board is added, and a closed one lands on Done"
}

# The board a new board= token is pointed at first is EMPTY, and a board holding
# only draft or pull-request cards carries no issue items either. Both are the
# case the membership requirement exists to serve, and both are the case a join
# keyed on record counts rather than on which file a record came from drops
# whole: it would report "0 added" over a board that never populates itself.
test_an_empty_board_is_populated_from_its_tracker() {
  local dir out
  dir=$(sweep_case sweepemptyboard)
  seed_tracker "$dir" '1 OPEN' '2 CLOSED'
  out=$(run_board "$dir" reconcile) || fail "the sweep failed: $out"
  assert_present "$dir/store/items/PVTI_I_acme_widget_1" \
    "an open tracker issue was not added to a board with no items at all"
  assert_present "$dir/store/items/PVTI_I_acme_widget_2" \
    "a closed tracker issue was not added to a board with no items at all"
  [ "$(item_status "$dir" acme widget 2)" = Done ] \
    || fail "a closed issue added to an empty board did not land on Done, got '$(item_status "$dir" acme widget 2)'"
  [ -z "$(item_status "$dir" acme widget 1)" ] \
    || fail "an open issue added to an empty board was given a status the sweep cannot know"
  assert_contains "$out" '2 added' "the sweep did not report the membership it added to an empty board"
  pass "a board with no items at all is populated from its tracker rather than reported complete"
}

test_an_open_issue_never_reads_done() {
  local dir
  dir=$(sweep_case sweepreopen)
  seed_tracker "$dir" '1 OPEN'
  seed_item "$dir" acme widget 1 'Done'
  run_board "$dir" reconcile >/dev/null || fail "the sweep failed"
  [ "$(item_status "$dir" acme widget 1)" = Todo ] \
    || fail "an open issue was left reading Done, got '$(item_status "$dir" acme widget 1)'"
  pass "an open issue that drifted into Done is moved back out"
}

test_a_sweep_with_no_drift_writes_nothing() {
  local dir
  dir=$(sweep_case sweepidem)
  seed_tracker "$dir" '1 OPEN' '2 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  seed_item "$dir" acme widget 2 'In Progress'
  run_board "$dir" reconcile >/dev/null || fail "the first sweep failed"
  : > "$dir/store/calls.log"
  run_board "$dir" reconcile >/dev/null || fail "the second sweep failed"
  [ "$(log_count "$dir" add)" = 0 ] || fail "a re-run added membership that was already there"
  [ "$(log_count "$dir" status)" = 0 ] || fail "a re-run rewrote a status that was already right"
  pass "a re-run with nothing drifted is a no-op, so the sweep is safe to run often"
}

test_a_project_with_no_declared_board_is_unaffected_silently() {
  local dir out
  dir=$(sweep_case sweepnoboard '')
  seed_tracker "$dir" '1 OPEN'
  out=$(run_board "$dir" reconcile) || fail "an undeclared board must not fail"
  [ -z "$out" ] || fail "a project with no declared board should say nothing, got: $out"
  assert_absent "$dir/store/calls.log" "a project with no declared board contacted GitHub"

  # A home default exists, and the sweep still refuses to touch a board nobody
  # declared for this project: the fallback drives lifecycle updates alone.
  dir=$(sweep_case sweepnoboarddefault '')
  printf '%s\n' "$BOARD_URL_FIXTURE" > "$dir/config/project-board"
  seed_tracker "$dir" '1 OPEN'
  out=$(run_board "$dir" reconcile) || fail "the sweep must not fail on the home default"
  assert_absent "$dir/store/calls.log" "the sweep reached a board only the home default named"

  dir=$(sweep_case sweepboardnone 'board=none')
  seed_tracker "$dir" '1 OPEN'
  out=$(run_board "$dir" reconcile) || fail "board=none must not fail"
  assert_absent "$dir/store/calls.log" "a project declaring board=none was still swept"
  pass "a project with no declared board is unaffected, silently, and the home default never feeds the sweep"
}

test_the_sweep_never_removes_an_item_a_human_added() {
  local dir
  dir=$(sweep_case sweepkeep)
  seed_tracker "$dir" '1 OPEN'
  seed_item "$dir" acme widget 1 'Todo'
  seed_item "$dir" acme widget 99 'In Progress'
  seed_item "$dir" other thing 5 'Done'
  run_board "$dir" reconcile >/dev/null || fail "the sweep failed"
  assert_present "$dir/store/items/PVTI_I_acme_widget_99" "an item with no matching tracker issue was removed"
  [ "$(item_status "$dir" acme widget 99)" = 'In Progress' ] \
    || fail "a hand-added item's status was rewritten"
  [ "$(item_status "$dir" other thing 5)" = Done ] \
    || fail "an item from another repository was touched"
  pass "an item a human added by hand is never removed and never rewritten"
}

# The acceptance criterion this proves is the destructive one: the boards in this
# fleet carry Priority, Size, Estimate and Start date, and a sweep that cleared
# one while setting Status would lose the captain's own data with no way back.
test_no_field_other_than_status_is_ever_written() {
  local dir before after
  dir=$(sweep_case sweepfields)
  seed_tracker "$dir" '1 OPEN' '2 CLOSED' '3 CLOSED'
  seed_item "$dir" acme widget 1 'Done' 'Priority=P1' 'Size=M' 'Estimate=3' 'Start date=2026-08-01'
  seed_item "$dir" acme widget 2 'In Progress' 'Priority=P0' 'Size=L' 'Estimate=8' 'Start date=2026-07-14'
  seed_item "$dir" acme widget 3 'Done' 'Priority=P2' 'Size=S' 'Estimate=1' 'Start date=2026-06-30'
  before=$(for n in 1 2 3; do item_fields "$dir" acme widget "$n"; done)
  run_board "$dir" reconcile >/dev/null || fail "the sweep failed"
  after=$(for n in 1 2 3; do item_fields "$dir" acme widget "$n"; done)
  [ "$before" = "$after" ] || fail "the sweep changed a field other than Status.
before:
$before
after:
$after"
  # Without this the comparison above would pass on a sweep that wrote nothing at
  # all and therefore proved nothing.
  [ "$(item_status "$dir" acme widget 1)" = Todo ] && [ "$(item_status "$dir" acme widget 2)" = Done ] \
    || fail "the sweep wrote no status, so the field-preservation check proved nothing"
  pass "Priority, Size, Estimate and Start date survive a sweep that rewrites Status"
}

test_the_sweep_writes_only_membership_and_a_status_value() {
  local dir names name
  dir=$(sweep_case sweepsurface)
  seed_tracker "$dir" '1 OPEN' '2 CLOSED' '3 CLOSED'
  seed_item "$dir" acme widget 1 'Done'
  seed_item "$dir" acme widget 2 'Todo'
  run_board "$dir" reconcile >/dev/null || fail "the sweep failed"
  assert_present "$dir/store/graphql.log" "the sweep sent no GraphQL at all, so nothing was proven"
  names=$(grep -oE '(add|update|create|delete|clear|archive|unarchive)ProjectV2[A-Za-z]*' \
    "$dir/store/graphql.log" | LC_ALL=C sort -u)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      addProjectV2ItemById|updateProjectV2ItemFieldValue) ;;
      *) fail "the sweep called '$name', which is outside membership and setting an existing option" ;;
    esac
  done <<EOF
$names
EOF
  assert_contains "$names" 'addProjectV2ItemById' "the sweep added no membership, so nothing was proven"
  assert_contains "$names" 'updateProjectV2ItemFieldValue' "the sweep set no status, so nothing was proven"
  pass "the sweep's whole write surface is board membership and one Status value"
}

# Each failure mode is checked on its own, because they fail for different
# reasons and a single generic case would let two of the three regress unseen.
test_every_board_failure_mode_leaves_the_fleet_work_unaffected() {
  local dir out rc mode
  for mode in unreachable scope ratelimit; do
    dir=$(sweep_case "sweepfail$mode")
    seed_tracker "$dir" '1 OPEN' '2 CLOSED'
    seed_item "$dir" acme widget 2 'Todo'
    set +e
    case "$mode" in
      unreachable) out=$(FM_FAKE_GH_FAIL=graphql-board run_board "$dir" reconcile) ;;
      scope) out=$(FM_FAKE_GH_FAIL=graphql-board FM_FAKE_GH_SCOPE_ERROR=1 run_board "$dir" reconcile) ;;
      ratelimit) out=$(FM_FAKE_GH_FAIL=graphql-items FM_FAKE_GH_RATE_LIMIT=1 run_board "$dir" reconcile) ;;
    esac
    rc=$?
    set -e
    expect_code 0 "$rc" "a $mode board must not fail the sweep"
    case "$mode" in
      scope) assert_contains "$out" "'project' scope" "a missing project scope was not named" ;;
      ratelimit) assert_contains "$out" 'rate-limiting' "a rate limit was not named" ;;
      *) assert_contains "$out" 'could not read' "an unreachable board was not reported" ;;
    esac
    [ "$(log_count "$dir" status)" = 0 ] || fail "a $mode board still had a status written to it"
    [ "$(log_count "$dir" add)" = 0 ] || fail "a $mode board still had membership written to it"
    [ "$(item_status "$dir" acme widget 2)" = Todo ] || fail "a $mode board's items were changed anyway"

    # The fleet work itself is what must survive: the task's own tracker update
    # still lands after the sweep failed, with nothing left broken behind it.
    out=$(run_milestone "$dir" --milestone dispatched) || fail "a $mode board took the task's own update down with it: $out"
    [ "$(comment_count "$dir")" = 1 ] || fail "a $mode board cost the task its tracker comment"
  done
  pass "an unreachable board, a missing scope, and a rate limit each report and leave the fleet's work untouched"
}

# A repository's REST open_issues_count INCLUDES pull requests. Firstmate used it
# on 2026-08-04 to conclude an ArkNode-AI issue was missing from its board and
# was wrong: membership was already complete at 76 of 76.
test_the_sweep_reconciles_against_issues_not_the_pull_request_inflated_count() {
  local dir
  dir=$(sweep_case sweepcount)
  seed_tracker "$dir" '1 OPEN' '2 OPEN' '3 OPEN'
  seed_item "$dir" acme widget 1 'Todo'
  seed_item "$dir" acme widget 2 'Todo'
  seed_item "$dir" acme widget 3 'Todo'
  FM_FAKE_GH_OPEN_ISSUES_COUNT=5 run_board "$dir" reconcile >/dev/null || fail "the sweep failed"
  [ "$(log_count "$dir" add)" = 0 ] \
    || fail "the sweep invented missing membership from a count that includes pull requests"
  ! grep -q '^REST ' "$dir/store/calls.log" 2>/dev/null \
    || fail "the sweep read a repository's REST counters, which include pull requests"
  pass "membership is reconciled against a real issue listing, never against a pull-request-inflated count"
}

test_the_sweep_walks_every_page_of_a_board_and_a_tracker() {
  local dir
  dir=$(sweep_case sweeppages)
  seed_tracker "$dir" '1 OPEN' '2 OPEN' '3 OPEN' '4 OPEN' '5 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  seed_item "$dir" acme widget 2 'Todo'
  seed_item "$dir" acme widget 3 'Todo'
  seed_item "$dir" acme widget 4 'Todo'
  seed_item "$dir" acme widget 5 'Todo'
  FM_FAKE_GH_PAGE_SIZE=2 run_board "$dir" reconcile >/dev/null || fail "the sweep failed"
  [ "$(item_status "$dir" acme widget 5)" = Done ] \
    || fail "drift on the last page was missed, so the walk stopped early"
  [ "$(log_count "$dir" add)" = 0 ] \
    || fail "items on later pages were treated as missing membership"
  pass "the walk reaches the last page of both listings, so late drift is found and late items are not re-added"
}

# An item listing that stops without saying where it got to looks exactly like a
# board that holds nothing, and the two have opposite consequences: one means
# every tracker issue is missing membership, the other means the sweep cannot
# tell. Reading the first as the second spends the whole change budget re-adding
# items that were already there and reports it as drift it found.
test_an_unfinishable_item_listing_is_not_read_as_an_empty_board() {
  local dir out
  dir=$(sweep_case sweeplostcursor)
  seed_tracker "$dir" '1 CLOSED' '2 OPEN' '3 OPEN'
  seed_item "$dir" acme widget 1 'Todo'
  seed_item "$dir" acme widget 2 'Todo'
  seed_item "$dir" acme widget 3 'Todo'
  out=$(FM_FAKE_GH_PAGE_SIZE=2 FM_FAKE_GH_ITEMS_CURSOR_LOST=1 run_board "$dir" reconcile) \
    || fail "an unfinishable listing must not fail the sweep: $out"
  # The write path fails closed on a partial view: NO writes at all, not merely
  # no membership. Every write the sweep plans is an inference from comparing two
  # listings, and none of those comparisons means anything unless both are whole.
  [ "$(log_count "$dir" add)" = 0 ] \
    || fail "membership was written from a partial view, got $(log_count "$dir" add) adds"
  [ "$(log_count "$dir" status)" = 0 ] \
    || fail "a status was written from a partial view, got $(log_count "$dir" status) writes"
  [ "$(item_status "$dir" acme widget 1)" = Todo ] \
    || fail "the board was changed from a view the sweep could not complete, got '$(item_status "$dir" acme widget 1)'"
  assert_contains "$out" 'stopped without saying where it had got to' \
    "the sweep did not report that it could not tell what the board holds"
  assert_contains "$out" 'planned no changes at all' \
    "the sweep truncated its work without announcing that it planned nothing"
  pass "a listing that cannot say where it stopped plans no writes at all and says so"
}

# The two sides of the join learn the repository's name from different places:
# this fixture's registry says `Acme/Widget`, while the board item's reference is
# assembled from GitHub's own canonical casing, `acme/widget`. GitHub resolves an
# owner/repo pair case-insensitively and answers canonically - asking it for
# `helloworldsungin/FIRSTMATE` returns `HelloWorldSungin/firstmate` - so this is
# an ordinary registry entry, not a typo to reject. Compared byte-exactly, every
# issue looks absent and the sweep re-adds all of them on every run, forever,
# without ever converging. Non-convergence is the property under test, so the
# second run is what makes it meaningful.
test_a_registry_typed_in_another_case_still_matches_and_converges() {
  local dir out
  dir=$(sweep_case sweepcasing 'board=https://github.com/users/captain/projects/7' \
    'tracker=github:github.com/Acme/Widget')
  seed_tracker "$dir" '1 OPEN' '2 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  seed_item "$dir" acme widget 2 'In Progress'
  out=$(run_board "$dir" reconcile) || fail "the sweep failed: $out"
  [ "$(log_count "$dir" add)" = 0 ] \
    || fail "an item already on the board was re-added because the two sides spell the repository differently, got $(log_count "$dir" add) adds"
  [ "$(item_status "$dir" acme widget 2)" = Done ] \
    || fail "drift went uncorrected because the join key did not match, got '$(item_status "$dir" acme widget 2)'"
  # Convergence: with the drift now corrected, a second run must be a no-op.
  : > "$dir/store/calls.log"
  run_board "$dir" reconcile >/dev/null || fail "the second sweep failed"
  [ "$(log_count "$dir" add)" = 0 ] && [ "$(log_count "$dir" status)" = 0 ] \
    || fail "the sweep never converges: a re-run wrote again ($(log_count "$dir" add) adds, $(log_count "$dir" status) status writes)"
  pass "a registry entry spelled in another case matches the board's canonical casing, and the sweep converges"
}
# A sweep that runs out of its whole-operation budget while READING stops just as
# surely as one that runs out while writing, and the reads - the board and both
# listings - are where nearly all of a bounded sweep's time goes. That budget is
# derived from the session-start network stage, so it is a few seconds rather
# than the flat default, and bin/fm-bootstrap.sh drops this script's stderr on
# purpose: a truncation travelling only as a `warning:` line reaches the session
# start as nothing at all, and a sweep that covered no board at all then reads
# exactly like a sweep that found no drift.
test_a_budget_spent_while_reading_truncates_the_sweep_out_loud() {
  local dir out
  dir=$(sweep_case sweepbudgetread)
  seed_tracker "$dir" '1 OPEN' '2 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  # One second of budget against a board that takes two to answer: the board read
  # is cut off, and the budget is gone by the time it returns.
  out=$(FM_WRITE_BACK_BUDGET=1 FM_FAKE_GH_DELAY=2 run_board "$dir" reconcile --quiet) \
    || fail "a spent budget must not fail the sweep: $out"
  assert_contains "$out" 'BOARD_SWEEP:' \
    "a sweep truncated by its budget while reading announced nothing the session start would relay"
  assert_contains "$out" 'whole-operation budget' \
    "the truncation was not named as the budget running out"
  assert_not_contains "$out" 'could not read' \
    "a spent budget was reported as a board this run could not reach, which the relay drops as transient"
  [ "$(log_count "$dir" add)" = 0 ] && [ "$(log_count "$dir" status)" = 0 ] \
    || fail "a sweep with no budget left still wrote to the board"
  pass "a budget spent while reading truncates the sweep out loud, and is never reported as a board failure"
}

# A command must only be stopped by configuration it actually DEPENDS on. The
# sweep resolves every board it touches from a declared board= token and never
# reads config/project-board, and a typo there fails in the worst configuration
# if it stops the sweep anyway: bin/fm-bootstrap.sh drops the warning and has
# already stamped the interval, so the whole fleet goes unreconciled for a full
# interval over a file the sweep does not use.
# The same rule on the WRITE path, and the position that has no second chance to
# state it: the plan's LAST row. A call refused mid-row leaves the plan loop
# through its own tail rather than through the top-of-iteration guard, so unless
# the failure itself is classified the sweep ends with the budget flag unset, the
# registry loop never breaks, and the run reports only what it managed - complete
# coverage, over a correction that was silently dropped. With four declared boards
# the last row of the last board is an ordinary position, not an exotic one.
test_a_budget_spent_while_writing_truncates_the_sweep_out_loud() {
  local dir out
  dir=$(sweep_case sweepbudgetwrite)
  seed_tracker "$dir" '1 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  # WHICH PATH THIS TEST TAKES IS NOT DECIDED BY A RACE. The fake never answers
  # the one planned mutation, so that call is always cut off by whatever share of
  # the budget is left when it starts, and the budget is therefore spent when it
  # returns however long the reads took - the mutation alone consumes the
  # remainder by construction rather than by being slower than something else.
  # The reads must not spend it FIRST, though: that takes the read path and turns
  # this into a second copy of the test above, which would report the write path
  # as covered while never entering it. So the mutation being attempted at all is
  # ASSERTED below rather than assumed, and this goes red if it stops happening.
  out=$(FM_WRITE_BACK_BUDGET=4 FM_FAKE_GH_WRITE_DELAY=9 run_board "$dir" reconcile --quiet) \
    || fail "a spent budget must not fail the sweep: $out"
  assert_grep 'updateProjectV2ItemFieldValue' "$dir/store/graphql.log" \
    "the sweep never attempted the write this test exists to cover: the reads spent the budget first, so this proved nothing about the write path"
  assert_contains "$out" 'BOARD_SWEEP:' \
    "a sweep truncated by its budget on the last row of its plan announced nothing the session start would relay"
  assert_contains "$out" 'whole-operation budget' \
    "the truncation was not named as the budget running out"
  assert_not_contains "$out" 'warning:' \
    "a spent budget was reported as an ordinary board failure, which the relay drops as transient"
  [ "$(item_status "$dir" acme widget 1)" = Todo ] \
    || fail "a status was written by a call the budget refused, got '$(item_status "$dir" acme widget 1)'"
  [ "$(log_count "$dir" status)" = 0 ] \
    || fail "a status write the budget cut off still landed, got $(log_count "$dir" status)"
  pass "a budget spent while writing truncates the sweep out loud, even on the last row of its plan"
}

# No failure inside the plan loop may be silent: a planned membership add that
# resolves to no issue, and an add GitHub answers without an item id, each drop a
# change the sweep had decided to make, and a dropped change that says nothing
# reads afterwards as a board that had no drift.
test_no_failure_inside_the_sweep_goes_unreported() {
  local dir out
  dir=$(sweep_case sweepsilentskip)
  seed_tracker "$dir" '1 OPEN'
  out=$(FM_FAKE_GH_MISSING_ISSUE=1 run_board "$dir" reconcile) \
    || fail "an unresolvable issue must not fail the sweep: $out"
  assert_contains "$out" 'could not add acme/widget#1' \
    "a planned membership add was dropped without a word about why"
  [ "$(log_count "$dir" add)" = 0 ] || fail "an issue that does not resolve was added anyway"
  pass "a planned change dropped inside the sweep says why, rather than reading as no drift"
}

test_a_malformed_home_fallback_does_not_disable_the_fleet_sweep() {
  local dir out
  dir=$(sweep_case sweepbadfallback)
  # The URL a captain gets by copying the board straight out of the browser.
  printf '%s\n' 'https://github.com/orgs/ark/projects/12/views/1' > "$dir/config/project-board"
  seed_tracker "$dir" '1 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  out=$(run_board "$dir" reconcile) || fail "the sweep failed: $out"
  [ "$(item_status "$dir" acme widget 1)" = Done ] \
    || fail "a typo in a fallback the sweep never reads stopped it reconciling a declared board"
  assert_contains "$out" '1 status corrected' "the sweep did not reconcile the declared board"

  # And the commands that DO resolve the fallback still report it and stop.
  out=$(run_board "$dir" show) || fail "show must not fail on a malformed fallback: $out"
  assert_contains "$out" 'config/project-board must hold one board URL' \
    "a command that does resolve the fallback stopped reporting a malformed one"
  pass "a malformed home fallback stops only the commands that resolve it, never the fleet sweep"
}

# Which board a PROJECT's work belongs on is the registry's to name, and
# lifecycle sync finds it by matching the issue's own tracker against the
# registry's tracker= token. The two spellings come from different places - the
# issue URL was recorded verbatim, the token is however the captain typed it - so
# matching byte-exactly loses the declared board on one capital letter and lets
# the home fallback answer for it, which is the same root cause the sweep's join
# was redesigned around. board=none is the sharper case: a casing miss makes the
# project look undeclared, so the fallback resurrects a board for a project that
# declared it has none.
test_sync_resolves_a_declared_board_however_the_registry_is_cased() {
  local dir out
  dir=$(case_dir syncboardcasing)
  mkdir -p "$dir/data"
  printf '%s\n' 'https://github.com/users/captain/projects/9' > "$dir/config/project-board"
  printf -- '- widget [no-mistakes tracker=github:github.com/ACME/Widget board=%s] - fixture (added 2026-08-18)\n' \
    "$BOARD_URL_FIXTURE" > "$dir/data/projects.md"
  out=$(run_board "$dir" sync --task task-1 --milestone dispatched --dry-run) \
    || fail "the sync rehearsal failed: $out"
  assert_contains "$out" "board: $BOARD_URL_FIXTURE" \
    "the project's declared board was lost because the registry spells the repository in another case"
  assert_not_contains "$out" 'projects/9' \
    "the home fallback answered for a project that declares its own board"

  printf -- '- widget [no-mistakes tracker=github:github.com/ACME/Widget board=none] - fixture (added 2026-08-18)\n' \
    > "$dir/data/projects.md"
  out=$(run_board "$dir" sync --task task-1 --milestone dispatched) \
    || fail "board=none must not fail sync: $out"
  [ -z "$out" ] || fail "a project declaring board=none still resolved a board: $out"
  assert_absent "$dir/store/calls.log" "a project declaring board=none contacted GitHub"
  pass "lifecycle sync resolves a project's declared board however the registry spells the repository"
}

# --- the fleet, which is more than one project -------------------------------
#
# Every case above declares a single board, so the loop that makes this a FLEET
# sweep has never been walked more than once. What follows covers the behaviours
# that only exist between projects.

# Fail open is a per-project property, not a per-run one: a board this run cannot
# read costs that project its reconciliation and costs the fleet nothing.
test_one_projects_broken_board_never_stops_the_sweep_reaching_the_next() {
  local dir out
  dir=$(sweep_multi_case sweepmultibroken alpha:7 beta:8)
  seed_repo_tracker "$dir" acme alpha '1 CLOSED'
  seed_repo_tracker "$dir" acme beta '1 CLOSED'
  seed_item "$dir" acme alpha 1 'Todo'
  seed_item "$dir" acme beta 1 'Todo'
  out=$(FM_FAKE_GH_FAIL_BOARD_NUMBER=7 run_board "$dir" reconcile) \
    || fail "a broken board must not fail the sweep: $out"
  assert_contains "$out" 'could not read' "the board this run could not read was not reported"
  [ "$(item_status "$dir" acme alpha 1)" = Todo ] \
    || fail "a project whose board could not be read was reconciled from a view the sweep never had"
  [ "$(item_status "$dir" acme beta 1)" = Done ] \
    || fail "one project's broken board stopped the sweep reaching the next, got '$(item_status "$dir" acme beta 1)'"
  pass "one project's broken board never stops the sweep reaching the next"
}

# The change limit bounds the RUN, not each project in it, because a per-project
# limit would multiply by however many boards the registry happens to declare -
# which is the opposite of a bound.
test_the_change_limit_is_one_budget_across_the_whole_fleet() {
  local dir out
  dir=$(sweep_multi_case sweepmultilimit alpha:7 beta:8)
  seed_repo_tracker "$dir" acme alpha '1 CLOSED' '2 CLOSED'
  seed_repo_tracker "$dir" acme beta '1 CLOSED'
  seed_item "$dir" acme alpha 1 'Todo'
  seed_item "$dir" acme alpha 2 'Todo'
  seed_item "$dir" acme beta 1 'Todo'
  out=$(run_board "$dir" reconcile --limit 2) || fail "the sweep failed: $out"
  [ "$(log_count "$dir" status)" = 2 ] \
    || fail "the change limit was spent per project rather than per run, got $(log_count "$dir" status) writes"
  [ "$(item_status "$dir" acme beta 1)" = Todo ] \
    || fail "the sweep wrote past its shared change limit once it reached the next project"
  assert_contains "$out" 'change limit' "the sweep truncated the whole fleet without saying so"
  pass "one change limit is shared across every project the sweep walks"
}

# THE REGISTRY'S TAIL MUST NOT STARVE. A bounded sweep that always began at the
# first entry would reconcile the same head projects on every session start and
# reach the tail on none of them, while printing a line promising the next sweep
# would pick them up. Two truncated runs in a row are what makes that visible:
# the second must take up where the first stopped, not start over.
test_a_truncated_sweep_reaches_the_registry_tail_on_the_next_run() {
  local dir out
  dir=$(sweep_multi_case sweepmultiresume alpha:7 beta:8)
  seed_repo_tracker "$dir" acme alpha '1 CLOSED' '2 CLOSED'
  seed_repo_tracker "$dir" acme beta '1 CLOSED'
  seed_item "$dir" acme alpha 1 'Todo'
  seed_item "$dir" acme alpha 2 'Todo'
  seed_item "$dir" acme beta 1 'Todo'
  out=$(run_board "$dir" reconcile --limit 1) || fail "the first sweep failed: $out"
  [ "$(item_status "$dir" acme alpha 1)" = Done ] || fail "the first run corrected nothing at all"
  [ "$(item_status "$dir" acme beta 1)" = Todo ] \
    || fail "the first run was not truncated before the tail, so the second run proves nothing"
  out=$(run_board "$dir" reconcile --limit 1) || fail "the second sweep failed: $out"
  [ "$(item_status "$dir" acme beta 1)" = Done ] \
    || fail "the registry's tail is starved: a second truncated run walked from the top again instead of resuming where the first stopped"
  pass "a truncated sweep resumes at the registry's tail rather than walking the head forever"
}

# The same resume point under the bound that cannot converge on its own: the
# change limit costs nothing next run once its writes have landed, but reading a
# board and its tracker costs the same every run, so a budget too small for the
# fleet would starve the tail permanently. A budget already spent before the
# first read makes which entry the run stops on a fixed fact rather than a race.
test_a_budget_truncated_sweep_names_what_it_missed_and_starts_there_next_time() {
  local dir out first
  dir=$(sweep_multi_case sweepmultibudget alpha:7 beta:8)
  seed_repo_tracker "$dir" acme alpha '1 CLOSED'
  seed_repo_tracker "$dir" acme beta '1 CLOSED'
  seed_item "$dir" acme alpha 1 'Todo'
  seed_item "$dir" acme beta 1 'Todo'
  # This run finishes NOTHING - the budget is gone before alpha's first read - so
  # it takes the one exception to "resume at the entry you were cut short in":
  # retrying alpha forever would mean beta is never read at all, so the cursor
  # advances past alpha and alpha waits one pass instead of waiting for ever.
  out=$(FM_WRITE_BACK_BUDGET=0 run_board "$dir" reconcile --quiet) \
    || fail "a spent budget must not fail the sweep: $out"
  assert_contains "$out" 'finished none of alpha, beta' \
    "the truncated run reported drift may remain without naming the entries it left unfinished"
  assert_absent "$dir/store/calls.log" "a sweep with no budget left still contacted a board"
  out=$(run_board "$dir" reconcile --quiet) || fail "the resumed sweep failed: $out"
  first=$(awk '$1 == "board" { print $2; exit }' "$dir/store/calls.log")
  [ "$first" = 8 ] \
    || fail "a run that could finish nothing did not move on, so one unaffordable entry blocks every other one, first board read was '${first:-none}'"
  [ "$(item_status "$dir" acme beta 1)" = Done ] || fail "the resumed sweep did not reconcile the tail it had missed"
  [ "$(item_status "$dir" acme alpha 1)" = Done ] || fail "the resumed sweep did not wrap back to the head"
  pass "a budget-truncated sweep names what it missed, and a run that finished nothing still lets the rest have a turn"
}

# THE RESUME POINT RECORDS WHAT WAS FINISHED, NOT WHAT WAS TOUCHED, and this is
# the case that tells the two apart. A run that reconciles alpha and is then cut
# short inside beta has not reconciled beta, so beta must be the FIRST entry the
# next run attempts. Recording beta instead - the entry merely reached - inverts
# the invariant: the one entry a bounded sweep cannot afford becomes the one
# entry it never retries, which is the starvation this resume point exists to end
# rather than to move one place along.
test_a_sweep_truncated_inside_an_entry_starts_the_next_run_at_that_entry() {
  local dir out first
  dir=$(sweep_multi_case sweepmultifinished alpha:7 beta:8 gamma:9)
  seed_repo_tracker "$dir" acme alpha '1 CLOSED'
  seed_repo_tracker "$dir" acme beta '1 CLOSED'
  seed_repo_tracker "$dir" acme gamma '1 CLOSED'
  seed_item "$dir" acme alpha 1 'Todo'
  seed_item "$dir" acme beta 1 'Todo'
  seed_item "$dir" acme gamma 1 'Todo'
  # One change is exactly alpha's worth, so alpha finishes and the limit stops
  # the run on beta's first row - the entry reached but not reconciled.
  out=$(run_board "$dir" reconcile --limit 1) || fail "the first sweep failed: $out"
  [ "$(item_status "$dir" acme alpha 1)" = Done ] || fail "the first run did not finish alpha"
  [ "$(item_status "$dir" acme beta 1)" = Todo ] \
    || fail "the first run was not cut short inside beta, so this proves nothing"
  assert_contains "$out" 'did not finish beta, gamma' \
    "the run named the wrong entries as unfinished, so it is not counting the entry it stopped in"
  : > "$dir/store/calls.log"
  out=$(run_board "$dir" reconcile --limit 1) || fail "the second sweep failed: $out"
  first=$(awk '$1 == "board" { print $2; exit }' "$dir/store/calls.log")
  [ "$first" = 8 ] \
    || fail "the entry the first run was cut short inside was skipped rather than retried, first board read was '${first:-none}'"
  [ "$(item_status "$dir" acme beta 1)" = Done ] \
    || fail "beta was reconciled on neither run, which is the starvation the resume point exists to end"
  pass "a sweep cut short inside an entry makes that entry the first one the next run attempts"
}

test_a_board_with_no_done_option_is_reported_never_given_one() {
  local dir out
  dir=$(sweep_case sweepnooption)
  seed_tracker "$dir" '1 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  out=$(FM_FAKE_GH_STATUS_OPTIONS='Todo,In Progress' run_board "$dir" reconcile) \
    || fail "a board missing an option must not fail the sweep"
  assert_contains "$out" 'no Done-class Status option' "the missing option was not reported"
  assert_contains "$out" 'add one by hand' "the report did not say the option is the captain's to add"
  [ "$(log_count "$dir" status)" = 0 ] || fail "a status was written with no matching option"
  [ "$(item_status "$dir" acme widget 1)" = Todo ] || fail "the item was changed anyway"
  ! grep -q 'updateProjectV2Field' "$dir/store/graphql.log" \
    || fail "the sweep created a status option, which detaches every item already using one"
  pass "a board with no Done option is reported and left alone, never given one"
}

test_the_change_limit_truncates_loudly() {
  local dir out
  dir=$(sweep_case sweeplimit)
  seed_tracker "$dir" '1 CLOSED' '2 CLOSED' '3 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  seed_item "$dir" acme widget 2 'Todo'
  seed_item "$dir" acme widget 3 'Todo'
  out=$(run_board "$dir" reconcile --limit 1) || fail "the sweep failed"
  [ "$(log_count "$dir" status)" = 1 ] \
    || fail "the change limit did not bound the run, got $(log_count "$dir" status) writes"
  assert_contains "$out" 'change limit' "the sweep truncated its work without saying so"
  pass "the change limit bounds a sweep and says what it left undone"
}

test_a_dry_run_reports_the_drift_and_writes_nothing() {
  local dir out
  dir=$(sweep_case sweepdry)
  seed_tracker "$dir" '1 CLOSED' '2 CLOSED'
  seed_item "$dir" acme widget 1 'Todo'
  out=$(run_board "$dir" reconcile --dry-run) || fail "the dry run failed"
  assert_contains "$out" 'would set Done' "the dry run did not name the status it would correct"
  assert_contains "$out" 'would add' "the dry run did not name the membership it would add"
  [ "$(log_count "$dir" status)" = 0 ] || fail "a dry run wrote a status"
  [ "$(log_count "$dir" add)" = 0 ] || fail "a dry run wrote membership"
  [ "$(item_status "$dir" acme widget 1)" = Todo ] || fail "a dry run changed the board"

  # An issue that is both absent and closed costs the real run two writes, so a
  # dry run must charge two against --limit and stop where the real run stops.
  # A preview that truncates somewhere else is announcing the wrong coverage.
  dir=$(sweep_case sweepdrylimit)
  seed_tracker "$dir" '1 CLOSED' '2 CLOSED' '3 CLOSED'
  out=$(run_board "$dir" reconcile --dry-run --limit 2) || fail "the bounded dry run failed"
  assert_contains "$out" 'change limit' "the bounded dry run truncated without saying so"
  [ "$(printf '%s\n' "$out" | grep -c 'would add')" = 1 ] \
    || fail "a dry run previewed more adds than a 2-change limit allows: $out"
  [ "$(printf '%s\n' "$out" | grep -c 'would set Done')" = 1 ] \
    || fail "a dry run did not charge the Done that follows an add: $out"
  pass "a dry run rehearses the whole sweep, writes nothing, and stops where the real run would"
}

test_the_board_library_exports_only_its_named_operations() {
  local base surface added expected
  base=$(forge_lib_exports "$ROOT/bin/fm-timeout-lib.sh")
  surface=$(forge_lib_exports "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-board-lib.sh")
  added=$(LC_ALL=C comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$surface") \
    | grep -v '^_' || true)
  expected=$(printf '%s\n' \
    fm_board_identity_key \
    fm_board_issue_id \
    fm_board_issue_parent \
    fm_board_item_add \
    fm_board_item_status_set \
    fm_board_items_page \
    fm_board_read \
    fm_board_registry_board \
    fm_board_registry_board_for_tracker \
    fm_board_registry_scan \
    fm_board_tracker_issues_page \
    fm_board_url_parse | LC_ALL=C sort)
  [ "$added" = "$expected" ] || fail "bin/fm-board-lib.sh's exported surface is no longer its allowlist.
expected:
$expected
got:
$added"
  pass "the board library exports its named operations, and its two writes are the whole write surface"
}

test_first_milestone_creates_one_comment
test_the_comment_carries_nothing_fleet_private
test_repeated_milestones_edit_exactly_one_comment
test_the_comment_is_found_again_among_foreign_comments
test_a_failed_update_leaves_the_next_one_able_to_correct_it
test_every_forge_failure_warns_and_exits_zero
test_absent_gh_and_a_hanging_gh_both_fail_open
test_out_of_scope_work_items_are_reported_and_never_written
test_a_task_with_no_work_item_is_silent
test_a_note_carrying_private_detail_is_withheld
test_a_forged_timeline_entry_never_enters_the_timeline
test_project_prose_with_routes_and_links_is_published
test_a_clean_note_is_published
test_dry_run_contacts_nothing
test_gitea_first_milestone_creates_one_comment_with_the_host_token
test_gitea_repeated_milestones_edit_one_comment
test_gitea_absent_token_reports_no_credential_without_a_call
test_gitea_empty_token_is_reported_as_present_not_absent
test_gitea_a_token_saved_with_stray_whitespace_still_authenticates
test_gitea_loose_token_is_refused_before_any_call
test_gitea_refused_credential_is_named
test_gitea_forge_failures_warn_and_exit_zero
test_gitlab_work_item_reports_no_adapter_not_a_credential_gap
test_github_write_back_ignores_forge_tokens_and_curl
test_gitea_comment_discovery_survives_a_clamped_page_size
test_gitea_an_unwalkable_comment_list_is_reported_and_nothing_is_written
test_gitea_a_paginator_that_never_advances_never_produces_a_create
test_gitea_symlinked_token_is_refused_before_any_call
test_gitea_dry_run_renders_without_a_credential_or_a_call
test_gitea_milestone_fanout_updates_the_comment
test_the_board_is_inert_without_configuration
test_a_home_with_no_board_is_inert_whatever_it_is_handed
test_board_membership_and_status_are_idempotent
test_the_board_is_never_reshaped_to_fit_a_milestone
test_the_board_never_mutates_the_captains_field_schema
test_the_board_ensures_the_parent_epic
test_a_board_failure_is_reported_and_never_fatal
test_one_milestone_updates_both_surfaces
test_a_broken_surface_does_not_stop_the_other
test_every_milestone_in_the_vocabulary_reaches_both_surfaces
test_a_caller_error_is_caught_before_either_surface_runs
test_the_whole_fanout_is_bounded_not_just_each_call
test_an_unknown_milestone_is_a_usage_error
test_the_merge_path_posts_its_own_milestones
test_a_refusing_tracker_never_makes_a_completed_merge_look_retryable
test_a_closed_issue_reads_done_and_an_open_one_is_left_alone
test_an_issue_absent_from_its_board_is_added
test_an_empty_board_is_populated_from_its_tracker
test_an_open_issue_never_reads_done
test_a_sweep_with_no_drift_writes_nothing
test_a_project_with_no_declared_board_is_unaffected_silently
test_the_sweep_never_removes_an_item_a_human_added
test_no_field_other_than_status_is_ever_written
test_the_sweep_writes_only_membership_and_a_status_value
test_every_board_failure_mode_leaves_the_fleet_work_unaffected
test_the_sweep_reconciles_against_issues_not_the_pull_request_inflated_count
test_the_sweep_walks_every_page_of_a_board_and_a_tracker
test_an_unfinishable_item_listing_is_not_read_as_an_empty_board
test_a_registry_typed_in_another_case_still_matches_and_converges
test_a_budget_spent_while_reading_truncates_the_sweep_out_loud
test_a_budget_spent_while_writing_truncates_the_sweep_out_loud
test_no_failure_inside_the_sweep_goes_unreported
test_one_projects_broken_board_never_stops_the_sweep_reaching_the_next
test_the_change_limit_is_one_budget_across_the_whole_fleet
test_a_truncated_sweep_reaches_the_registry_tail_on_the_next_run
test_a_sweep_truncated_inside_an_entry_starts_the_next_run_at_that_entry
test_a_budget_truncated_sweep_names_what_it_missed_and_starts_there_next_time
test_a_malformed_home_fallback_does_not_disable_the_fleet_sweep
test_sync_resolves_a_declared_board_however_the_registry_is_cased
test_a_board_with_no_done_option_is_reported_never_given_one
test_the_change_limit_truncates_loudly
test_a_dry_run_reports_the_drift_and_writes_nothing
test_the_board_library_exports_only_its_named_operations
test_the_shared_contracts_have_exactly_one_owner
test_the_forge_library_exports_only_its_named_operations
fm_test_every_defined_test_ran
printf '\nall fm-issue-writeback tests passed\n'
