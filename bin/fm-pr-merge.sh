#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh-axi by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
# Extra GitHub args are forwarded unchanged, including an explicit --merge.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. The verified head is then passed to glab as --sha, so a push that lands
# between that read and the merge fails the merge instead of landing commits
# nothing verified. A recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha on GitLab because the head comes only from the live read.
# After a successful merge, an optional work item recorded in task metadata is
# verified and, when it is open on a forge with a write adapter, closed with a
# comment linking the merged PR. A work_item= record names the tracker the
# project declared and is closed on THAT host and in THAT repository; only the
# legacy bare issue= number falls back to the repository the PR landed in.
# Issue verification, closure, or write-back failures warn while returning
# success, because the already-completed merge must never look retryable.
#
# After the forge command, this script confirms the PR is actually merged before
# reporting it; an auto-merge-queued or unconfirmed request leaves the poll armed
# and records no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed
# merge's destination, normal-case deduplication, and at-least-once recovery.
# A landed merge whose outcome cannot be written is reported loudly rather than
# misreported as a failed merge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CLOSE_TIMEOUT=${FM_ISSUE_CLOSE_TIMEOUT:-10}
case "$CLOSE_TIMEOUT" in
  ''|*[!0-9]*|0) CLOSE_TIMEOUT=10 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-issue-lib.sh
. "$SCRIPT_DIR/fm-issue-lib.sh"
# shellcheck source=bin/fm-forge-lib.sh
. "$SCRIPT_DIR/fm-forge-lib.sh"
# Role partition: merging is MAIN-owned; the Pi supervision branch reports the
# green PR and never merges (contract: bin/fm-lease-lib.sh; no-op in homes
# without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
[ "$PROVIDER" != gitlab ] || reject_head_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 7 ] || [ "$total" -ne 7 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  [ "$pipeline_status" = success ] \
    || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
  [ "$pipeline_sha" = "$live_head" ] \
    || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
}

github_confirm_merged() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    printf 'actionable: GitHub accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    printf 'actionable: GitHub accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

case "$PROVIDER" in
  github)
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
    github_confirm_rc=0
    github_confirm_merged || github_confirm_rc=$?
    [ "$github_confirm_rc" -eq 0 ] || exit 0
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@"
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit 0
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after the forge confirmed the merge landed: set -e exits on a
# refused or failed merge above, and a queued forge merge exits without an
# outcome while its existing poll remains armed.
outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac

# Refresh the cached PR observation so the task's final normalized state reads
# `merged` in the fleet snapshot and in the outcome manifest teardown publishes.
# Best effort by design: the merge already succeeded and must never look
# retryable, so a failed refresh only leaves the previous observation in place.
# The refresh names its own cause on stderr, which is captured and folded into
# this warning: discarding it would leave the operator reading a symptom while
# the one line that says why sits in /dev/null. An empty stderr keeps the plain
# wording rather than a line that trails off after a colon.
if ! REFRESH_ERR=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-pr-status.sh" refresh "$ID" 2>&1 >/dev/null); then
  REFRESH_REASON=$(fm_pr_reason_normalize "$REFRESH_ERR")
  if [ -n "$REFRESH_REASON" ]; then
    echo "warning: PR merge succeeded: $URL; the cached PR state could not be refreshed: $REFRESH_REASON" >&2
  else
    echo "warning: PR merge succeeded: $URL; the cached PR state could not be refreshed" >&2
  fi
fi

# Record the landing on every tracker surface before the close bookkeeping below,
# which has several legitimate early exits. Best effort by design: the merge has
# already happened and must never look retryable, which is also why the fan-out
# bounds itself as one operation rather than only bounding each call inside it.
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-work-item-milestone.sh" "$ID" --milestone landed || true

issue_close_warning() {  # <detail>
  echo "warning: PR merge succeeded: $URL; issue bookkeeping did not complete: $1" >&2
}

github_issue_state() {  # <host> <repo-path> <issue-number>
  local host=$1 repo=$2 issue=$3 output state
  [ "$host" = github.com ] || return 2
  output=$(gh-axi issue view "$issue" --repo "$repo" --full) || return 1
  state=$(printf '%s\n' "$output" | awk '$1 == "state:" { print $2; exit }')
  [ -n "$state" ] || return 1
  printf '%s\n' "$state"
}

github_issue_close() {  # <host> <repo-path> <issue-number>
  local host=$1 repo=$2 issue=$3
  [ "$host" = github.com ] || return 2
  gh-axi issue close "$issue" --repo "$repo" --reason completed \
    --comment "Closed after merge of $URL."
}

# Gitea reads and closes through bin/fm-forge-lib.sh's write allowlist, with
# the credential resolved once below. The close posts the same linking comment
# GitHub's close carries, then sets the issue state.
#
# The state read is called in a command substitution, so FM_FORGE_REASON dies
# with that subshell. It is written to a file instead: a merge-path warning that
# says only "could not verify" collapses an unreachable host, a timeout, a
# deleted issue, and a credential the forge refused into one indistinguishable
# line, and those send the captain to four different places.
gitea_issue_state() {  # <host> <repo-path> <issue-number>
  local host=$1 repo=$2 issue=$3 state
  : > "$CLOSE_WORKDIR/state-reason"
  if ! fm_gitea_issue_read "$CLOSE_TIMEOUT" "$GITEA_TOKEN" "$host" "$repo" "$issue" \
    "$CLOSE_WORKDIR/issue.json"; then
    printf '%s\n' "$FM_FORGE_REASON" > "$CLOSE_WORKDIR/state-reason"
    return 1
  fi
  state=$(jq -r '.state // empty' "$CLOSE_WORKDIR/issue.json" 2>/dev/null) || state=
  case "$state" in
    open|closed) printf '%s\n' "$state" ;;
    *)
      printf '%s\n' "$host returned no readable issue state" > "$CLOSE_WORKDIR/state-reason"
      return 1
      ;;
  esac
}

gitea_issue_close() {  # <host> <repo-path> <issue-number>
  local host=$1 repo=$2 issue=$3
  printf 'Closed after merge of %s.\n' "$URL" > "$CLOSE_WORKDIR/close-comment"
  fm_gitea_comment_create "$CLOSE_TIMEOUT" "$GITEA_TOKEN" "$host" "$repo" "$issue" \
    "$CLOSE_WORKDIR/close-comment" || return 1
  fm_gitea_issue_close "$CLOSE_TIMEOUT" "$GITEA_TOKEN" "$host" "$repo" "$issue"
}

issue_state() {  # <host> <repo-path> <issue-number>
  case "$ISSUE_FORGE" in
    gitea) gitea_issue_state "$@" ;;
    *) github_issue_state "$@" ;;
  esac
}

# The reason the last issue_state failed for, recovered from the subshell it was
# determined in. Empty for GitHub, whose own reporting is unchanged.
issue_state_reason() {
  local reason
  [ -n "$CLOSE_WORKDIR" ] && [ -f "$CLOSE_WORKDIR/state-reason" ] || return 0
  reason=$(cat "$CLOSE_WORKDIR/state-reason" 2>/dev/null) || return 0
  [ -z "$reason" ] || printf ': %s' "$reason"
}

issue_close() {  # <host> <repo-path> <issue-number>
  case "$ISSUE_FORGE" in
    gitea) gitea_issue_close "$@" ;;
    *) github_issue_close "$@" ;;
  esac
}

# Resolve which tracker this task's issue actually lives in. A work_item=
# record carries the whole identity the captain declared for the project, so it
# is authoritative; the legacy bare issue= number carries none and can only mean
# "the repository this PR landed in", which is wrong for any project whose code
# and issues live on different hosts. Preferring the record is what stops a
# mirrored project's bookkeeping going to the wrong forge.
ISSUE_FORGE=github
ISSUE_REPO=
ISSUE_HOST=
ISSUE=
GITEA_TOKEN=
CLOSE_WORKDIR=
WORK_ITEM_COUNT=$(grep -c '^work_item=' "$META" 2>/dev/null || true)
if [ "$WORK_ITEM_COUNT" -gt 1 ]; then
  issue_close_warning "task metadata records several work items; none was closed automatically"
  exit 0
fi
if [ "$WORK_ITEM_COUNT" -eq 1 ]; then
  WORK_ITEM_RECORD=$(grep '^work_item=' "$META" | cut -d= -f2-)
  if ! fm_issue_work_item_parse "$WORK_ITEM_RECORD"; then
    issue_close_warning "recorded work item is malformed"
    exit 0
  fi
  if ! fm_forge_write_supported "$FM_ISSUE_FORGE" "$FM_ISSUE_HOST"; then
    # An honest adapter gap: the merge still succeeded and the work item is
    # still linked, so the close is left to whoever owns that tracker.
    issue_close_warning "the work item lives on $FM_ISSUE_FORGE host $FM_ISSUE_HOST ($FM_ISSUE_URL); $FM_FORGE_REASON, so it was not closed automatically"
    exit 0
  fi
  ISSUE_FORGE="$FM_ISSUE_FORGE"
  ISSUE_HOST="$FM_ISSUE_HOST"
  ISSUE_REPO="$FM_ISSUE_PATH"
  ISSUE="$FM_ISSUE_NUMBER"
  if [ "$ISSUE_FORGE" = gitea ]; then
    command -v curl >/dev/null 2>&1 \
      || { issue_close_warning "curl is not installed, so $FM_ISSUE_URL was not closed automatically"; exit 0; }
    command -v jq >/dev/null 2>&1 \
      || { issue_close_warning "jq is not installed, so $FM_ISSUE_URL was not closed automatically"; exit 0; }
    token_rc=0
    GITEA_TOKEN=$(fm_forge_token_read "$CONFIG" "$ISSUE_HOST") || token_rc=$?
    case "$token_rc" in
      0) ;;
      2)
        issue_close_warning "refusing the token at config/forge-tokens/$ISSUE_HOST: it must be a regular file with mode 0600"
        exit 0
        ;;
      3)
        issue_close_warning "firstmate holds no usable write credential for $ISSUE_HOST (config/forge-tokens/$ISSUE_HOST is present but empty), so $FM_ISSUE_URL was not closed automatically"
        exit 0
        ;;
      *)
        issue_close_warning "firstmate holds no write credential for $ISSUE_HOST (config/forge-tokens/$ISSUE_HOST is absent), so $FM_ISSUE_URL was not closed automatically"
        exit 0
        ;;
    esac
    CLOSE_WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-merge.XXXXXX") \
      || { issue_close_warning "could not create a temporary working directory"; exit 0; }
    trap 'rm -rf -- "$CLOSE_WORKDIR"' EXIT
    # bash runs no EXIT trap for an untrapped fatal signal, and this directory
    # holds a rendered comment payload, so the signal a bounded caller sends must
    # remove it too - the same pairing bin/fm-issue-comment.sh and
    # bin/fm-issue-status.sh use for their own scratch directories.
    trap 'rm -rf -- "$CLOSE_WORKDIR"; trap - EXIT; exit 143' HUP INT TERM
    fm_forge_scratch_set "$CLOSE_WORKDIR"
  fi
else
  ISSUE_LINE_COUNT=$(grep -c '^issue=' "$META" 2>/dev/null || true)
  case "$ISSUE_LINE_COUNT" in
    0) exit 0 ;;
    1) ISSUE=$(grep '^issue=' "$META" | cut -d= -f2-) ;;
    *) issue_close_warning "task metadata has multiple recorded issues"; exit 0 ;;
  esac
  case "$ISSUE" in
    ''|*[!0-9]*) issue_close_warning "recorded issue identity is malformed"; exit 0 ;;
  esac
  if [ "$ISSUE" -le 0 ]; then
    issue_close_warning "recorded issue identity is malformed"
    exit 0
  fi
  ISSUE_HOST=github.com
  ISSUE_REPO="$PR_OWNER/$PR_REPO"
fi

if ! ISSUE_STATE=$(issue_state "$ISSUE_HOST" "$ISSUE_REPO" "$ISSUE"); then
  issue_close_warning "could not verify $ISSUE_REPO#$ISSUE$(issue_state_reason)"
  exit 0
fi
[ "$ISSUE_STATE" = closed ] && exit 0

if ! issue_close "$ISSUE_HOST" "$ISSUE_REPO" "$ISSUE"; then
  issue_close_warning "could not close $ISSUE_REPO#$ISSUE${FM_FORGE_REASON:+: $FM_FORGE_REASON}"
  exit 0
fi
if ! ISSUE_STATE=$(issue_state "$ISSUE_HOST" "$ISSUE_REPO" "$ISSUE") \
  || [ "$ISSUE_STATE" != closed ]; then
  issue_close_warning "$ISSUE_REPO#$ISSUE is still not closed after the close request$(issue_state_reason)"
fi
exit 0
