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
#   (h) the board is inert without configuration, idempotent with it, never
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
#       token file is refused rather than followed, an absent token, an empty
#       one, an unsupported forge, and a refused credential are four different
#       reported facts, comment discovery survives a host that clamps its page
#       size below the limit asked for and reports a list it cannot walk instead
#       of posting a second comment, a dry run renders before any credential is
#       resolved, every forge failure warns and exits 0, and the github path
#       never reads a forge token or invokes curl at all
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
mkdir -p "$STORE/comments"
LOG="$STORE/calls.log"
FAIL=" ${FM_FAKE_GH_FAIL:-} "

fail_with() {  # <token> <message>
  case "$FAIL" in
    *" $1 "*|*" all "*)
      if [ -n "${FM_FAKE_GH_SCOPE_ERROR:-}" ]; then
        echo "gh: Your token has not been granted the required scopes: 'project'" >&2
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    graphql) GRAPHQL=1 ;;
    --paginate) ;;
    --method) METHOD=$2; shift ;;
    --jq) JQFILTER=$2; shift ;;
    -F|-f)
      case "$2" in
        query=*) QUERY=${2#query=} ;;
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

if [ "$GRAPHQL" = 1 ]; then
  printf '%s\n' "$QUERY" >> "$STORE/graphql.log"
  case "$QUERY" in
    *updateProjectV2ItemFieldValue*)
      fail_with graphql-status "board status update refused"
      printf 'status\n' >> "$LOG"
      printf 'set\n' >> "$STORE/board-status"
      emit '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_1"}}}}'
      exit 0
      ;;
    *addProjectV2ItemById*)
      fail_with graphql-add "board membership refused"
      printf 'add\n' >> "$LOG"
      # The real mutation returns the EXISTING item for content already on the
      # board, so the same content always answers with the same item id.
      touch "$STORE/board-items"
      grep -qxF "$FM_FAKE_GH_LAST_CONTENT" "$STORE/board-items" 2>/dev/null \
        || printf '%s\n' "$FM_FAKE_GH_LAST_CONTENT" >> "$STORE/board-items"
      emit "{\"data\":{\"addProjectV2ItemById\":{\"item\":{\"id\":\"PVTI_$FM_FAKE_GH_LAST_CONTENT\"}}}}"
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
    *projectV2*)
      fail_with graphql-board "board lookup refused"
      printf 'board\n' >> "$LOG"
      root=user
      case "$QUERY" in *organization\(*) root=organization ;; esac
      if [ -n "${FM_FAKE_GH_NO_STATUS_FIELD:-}" ]; then
        field=null
      elif [ -n "${FM_FAKE_GH_STATUS_OPTIONS:-}" ]; then
        field=$(printf '%s' "$FM_FAKE_GH_STATUS_OPTIONS" | jq -R 'split(",") | {id:"F_status", options:[to_entries[] | {id:("o"+(.key|tostring)), name:.value}]}')
      else
        field='{"id":"F_status","options":[{"id":"o1","name":"Todo"},{"id":"o2","name":"In Progress"},{"id":"o3","name":"In review"},{"id":"o4","name":"Done"}]}'
      fi
      emit "{\"data\":{\"$root\":{\"projectV2\":{\"id\":\"PVT_1\",\"title\":\"Fleet\",\"field\":$field}}}}"
      exit 0
      ;;
    *issue*)
      fail_with graphql-issue "issue lookup refused"
      printf 'issue\n' >> "$LOG"
      if [ -n "${FM_FAKE_GH_MISSING_ISSUE:-}" ]; then
        emit '{"data":{"repository":{"issue":null}}}'
      else
        emit '{"data":{"repository":{"issue":{"id":"I_42"}}}}'
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
echo "fake gh: unrecognized endpoint '$ENDPOINT'" >&2
exit 1
SH
  chmod +x "$1/gh"
}

# The board's add mutation needs to know which content it was handed, and the
# fake cannot read the -f fields the real client sends as JSON. A tiny wrapper
# exports the last issue id the fake resolved, which is enough for the store.
FAKE_CONTENT_DEFAULT=I_42

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
    FM_FAKE_GH_LAST_CONTENT="$FAKE_CONTENT_DEFAULT" \
    PATH="$dir/fakebin:$PATH" \
    "$COMMENT" status task-1 "$@" 2>&1
}

run_board() {  # <case-dir> [args...]
  local dir=$1
  shift
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GH_STORE="$dir/store" \
    FM_FAKE_GH_LAST_CONTENT="$FAKE_CONTENT_DEFAULT" \
    PATH="$dir/fakebin:$PATH" \
    "$BOARD" "$@" 2>&1
}

run_milestone() {  # <case-dir> [args...]
  local dir=$1
  shift
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_GH_STORE="$dir/store" \
    FM_FAKE_GH_LAST_CONTENT="$FAKE_CONTENT_DEFAULT" \
    PATH="$dir/fakebin:$PATH" \
    "$MILESTONE" task-1 "$@" 2>&1
}

comment_count() {  # <case-dir>
  find "$1/store/comments" -name '*.body' 2>/dev/null | wc -l | tr -d ' '
}

firstmate_comment() {  # <case-dir> -> the one firstmate-owned comment body
  grep -rl 'firstmate-status-comment' "$1/store/comments" 2>/dev/null | head -n 1
}

log_count() {  # <case-dir> <token>
  grep -c "^$2" "$1/store/calls.log" 2>/dev/null || true
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

# --- (f) scope: only where a write credential genuinely exists ---------------

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
    # test stands in for such an instance.
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
    FM_FAKE_GH_LAST_CONTENT="$FAKE_CONTENT_DEFAULT" PATH="$dir/fakebin:$PATH" \
    "$COMMENT" status task-1 --milestone dispatched 2>&1) \
    || fail "the github milestone failed with a forge token present: $out"
  assert_contains "$out" "created: $ISSUE_URL" "the github comment was not created"
  assert_absent "$dir/curl-args" "the github path invoked curl"
  assert_absent "$dir/curl-stdin" "the github path passed a credential to curl"
  pass "a github work item keeps riding gh alone, with forge tokens never read"
}

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
    FM_FAKE_GH_LAST_CONTENT="$FAKE_CONTENT_DEFAULT" \
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
    FM_FAKE_GH_FAIL=all FM_FAKE_GH_LAST_CONTENT="$FAKE_CONTENT_DEFAULT" \
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
test_gitea_loose_token_is_refused_before_any_call
test_gitea_refused_credential_is_named
test_gitea_forge_failures_warn_and_exit_zero
test_gitlab_work_item_reports_no_adapter_not_a_credential_gap
test_github_write_back_ignores_forge_tokens_and_curl
test_gitea_comment_discovery_survives_a_clamped_page_size
test_gitea_an_unwalkable_comment_list_is_reported_and_nothing_is_written
test_gitea_symlinked_token_is_refused_before_any_call
test_gitea_dry_run_renders_without_a_credential_or_a_call
test_gitea_milestone_fanout_updates_the_comment
test_the_board_is_inert_without_configuration
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
test_the_shared_contracts_have_exactly_one_owner
test_the_forge_library_exports_only_its_named_operations
