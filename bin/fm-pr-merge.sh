#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# merged through gh with its inspected head required to match; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
# Extra forge arguments are limited to merge-method selectors, commit-message
# inputs, and post-execution branch cleanup because an unbounded passthrough
# cannot guarantee immediate execution. GitLab rebase selectors are excluded
# because they can change the source branch before a SHA-bound merge fails.
# GitHub's live PR state must prove that neither a merge queue nor auto-merge can
# defer execution before the merge command runs.
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
# URL, nor a head override because the head comes only from the live read.
# Every provider also fetches the PR head and origin's current default branch
# before merging so the forge's final object identities can be bound to the
# repository this task inspected.
# After a successful merge, an optional work item recorded in task metadata is
# verified and, when it is open on a forge with a write adapter, closed with a
# comment linking the merged PR. A work_item= record names the tracker the
# project declared and is closed on THAT host and in THAT repository; only the
# legacy bare issue= number falls back to the repository the PR landed in.
# Issue verification, closure, or write-back failures warn while returning
# success, because the already-completed merge must never look retryable.
#
# After an attempted forge mutation, this script confirms the PR is actually
# merged before reporting it. A queued or pending result is a refusal, while an
# unreadable result is actionable; each leaves the poll armed and records no
# landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
# destination, normal-case deduplication, and at-least-once recovery.
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
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --squash|--merge|--rebase|-s|-m|-r|--method|--method=*) return 0 ;;
      --subject|--body|--body-file|-t|-b|-F) shift 2 ;;
      *) shift ;;
    esac
  done
  return 1
}

merge_method_value_valid() {
  case "${1-}" in merge|squash|rebase) return 0 ;; *) return 1 ;; esac
}

forwarded_argument_refusal() {
  printf 'error: refusing extra merge argument %s because an unbounded passthrough cannot guarantee immediate execution\n' \
    "${1-<missing>}" >&2
  return 1
}

require_forwardable_merge_arguments() {
  local arg value
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$PROVIDER:$arg" in
      # Merge-method selectors choose the form of an immediate merge and cannot defer execution.
      github:--merge|github:--squash|github:--rebase|github:-m|github:-s|github:-r|\
      gitlab:--squash|gitlab:-s)
        shift
        ;;
      github:--method)
        [ "$#" -ge 2 ] || { echo "error: merge method value is missing" >&2; return 1; }
        value=$2
        merge_method_value_valid "$value" \
          || { printf 'error: unsupported merge method %s\n' "$value" >&2; return 1; }
        shift 2
        ;;
      github:--method=*)
        value=${arg#--method=}
        merge_method_value_valid "$value" \
          || { printf 'error: unsupported merge method %s\n' "${value:-<empty>}" >&2; return 1; }
        shift
        ;;
      # Message arguments only supply text for the immediate merge and cannot defer execution.
      github:--subject|github:--body|github:--body-file|github:-t|github:-b|github:-F|\
      gitlab:--message|gitlab:--squash-message|gitlab:-m)
        [ "$#" -ge 2 ] \
          || { printf 'error: value is missing for extra merge argument %s\n' "$arg" >&2; return 1; }
        shift 2
        ;;
      github:--subject=*|github:--body=*|github:--body-file=*|\
      gitlab:--message=*|gitlab:--squash-message=*)
        shift
        ;;
      # Cleanup runs only after merge execution, so these flags cannot defer execution.
      github:--delete-branch|github:-d|gitlab:--remove-source-branch|gitlab:-d)
        shift
        ;;
      *) forwarded_argument_refusal "$arg"; return 1 ;;
    esac
  done
}

require_forwardable_merge_arguments "$@" || exit 1

MATERIALIZED_BODY_WORKDIR=
MATERIALIZED_BODY_DEADLINE=
MATERIALIZED_BODY_BYTES=0
MATERIALIZED_BODY_COUNT=0
FM_PR_MATERIALIZED_BODY_FILE=

cleanup_materialized_body_files() {
  [ -z "$MATERIALIZED_BODY_WORKDIR" ] || rm -rf -- "$MATERIALIZED_BODY_WORKDIR"
  MATERIALIZED_BODY_WORKDIR=
}

materialize_github_body_file() {
  local source=$1 option=$2 staged read_source read_limit read_rc remaining bytes
  local timeout=15 max_bytes=1048576
  if [ -z "$MATERIALIZED_BODY_WORKDIR" ]; then
    MATERIALIZED_BODY_WORKDIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-pr-merge-body.XXXXXX") || {
      printf 'error: refusing extra merge argument %s because its body-file input could not be staged safely\n' \
        "$option" >&2
      return 1
    }
    chmod 0700 "$MATERIALIZED_BODY_WORKDIR" || {
      cleanup_materialized_body_files
      printf 'error: refusing extra merge argument %s because its body-file input could not be staged safely\n' \
        "$option" >&2
      return 1
    }
    MATERIALIZED_BODY_DEADLINE=$((SECONDS + timeout))
    trap cleanup_materialized_body_files EXIT
    trap 'cleanup_materialized_body_files; trap - EXIT; exit 143' HUP INT TERM
  fi
  remaining=$((MATERIALIZED_BODY_DEADLINE - SECONDS))
  if [ "$remaining" -le 0 ]; then
    printf 'error: refusing extra merge argument %s because body-file materialization exceeded %s seconds\n' \
      "$option" "$timeout" >&2
    return 1
  fi
  read_limit=$((max_bytes - MATERIALIZED_BODY_BYTES + 1))
  if [ "$read_limit" -le 0 ]; then
    printf 'error: refusing extra merge argument %s because body-file input exceeds the %s-byte bound\n' \
      "$option" "$max_bytes" >&2
    return 1
  fi
  MATERIALIZED_BODY_COUNT=$((MATERIALIZED_BODY_COUNT + 1))
  staged="$MATERIALIZED_BODY_WORKDIR/body-$MATERIALIZED_BODY_COUNT"
  if : >"$staged" && chmod 0600 "$staged"; then
    :
  else
    printf 'error: refusing extra merge argument %s because its body-file input could not be staged safely\n' \
      "$option" >&2
    return 1
  fi
  case "$source" in
    -) read_source=- ;;
    -*) read_source="./$source" ;;
    *) read_source=$source ;;
  esac
  read_rc=0
  fm_run_timed "$remaining" head -c "$read_limit" "$read_source" >"$staged" || read_rc=$?
  case "$read_rc" in
    0) ;;
    124)
      printf 'error: refusing extra merge argument %s because body-file materialization exceeded %s seconds\n' \
        "$option" "$timeout" >&2
      return 1
      ;;
    *)
      printf 'error: refusing extra merge argument %s because its body-file input could not be read\n' \
        "$option" >&2
      return 1
      ;;
  esac
  bytes=$(wc -c <"$staged" | tr -d '[:space:]') || bytes=
  case "$bytes" in ''|*[!0-9]*) bytes=$((max_bytes + 1)) ;; esac
  MATERIALIZED_BODY_BYTES=$((MATERIALIZED_BODY_BYTES + bytes))
  if [ "$MATERIALIZED_BODY_BYTES" -gt "$max_bytes" ]; then
    printf 'error: refusing extra merge argument %s because body-file input exceeds the %s-byte bound\n' \
      "$option" "$max_bytes" >&2
    return 1
  fi
  FM_PR_MATERIALIZED_BODY_FILE=$staged
}

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

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
FM_PR_INSPECTED_HEAD=
FM_PR_INSPECTED_BASE=
FM_PR_INSPECTED_DEFAULT=
FM_PR_INSPECTION_REASON=
inspect_merge_boundary() {
  local target=${1-} source_ref remote_state default_ref default_name
  local token base_ref head_ref base head
  local probe_timeout=${FM_PR_MERGE_PROBE_TIMEOUT:-15}
  FM_PR_INSPECTED_HEAD=
  FM_PR_INSPECTED_BASE=
  FM_PR_INSPECTED_DEFAULT=
  FM_PR_INSPECTION_REASON=

  if [ -z "$WT" ] || [ ! -d "$WT" ] \
    || ! git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    FM_PR_INSPECTION_REASON="task worktree is unavailable or is not a Git worktree"
  elif ! fm_pr_task_id_valid "$ID"; then
    FM_PR_INSPECTION_REASON="task identity is invalid"
  fi
  case "$probe_timeout" in ''|*[!0-9]*|0) probe_timeout=15 ;; esac
  case "$PROVIDER" in
    github) source_ref="refs/pull/$PR_NUMBER/head" ;;
    gitlab) source_ref="refs/merge-requests/$PR_NUMBER/head" ;;
    *) FM_PR_INSPECTION_REASON="forge provider is unsupported" ;;
  esac
  if [ -z "$FM_PR_INSPECTION_REASON" ] \
    && ! fm_pr_remote_matches_identity "$WT" "$FM_PR_HOST" "$FM_PR_PATH" "$probe_timeout"; then
    FM_PR_INSPECTION_REASON="task worktree origin does not match the PR repository"
  fi
  if [ -z "$FM_PR_INSPECTION_REASON" ]; then
    remote_state=$(fm_pr_remote_git "$probe_timeout" -C "$WT" \
      ls-remote --symref origin HEAD "$source_ref" 2>/dev/null) \
      || FM_PR_INSPECTION_REASON="origin did not expose its current default branch and PR head"
  fi
  if [ -z "$FM_PR_INSPECTION_REASON" ]; then
    default_ref=$(printf '%s\n' "$remote_state" | awk '
      $1 == "ref:" && $3 == "HEAD" { count++; value=$2 }
      END { if (count == 1) print value; else exit 1 }
    ') || default_ref=
    case "$default_ref" in
      refs/heads/*) ;;
      *) FM_PR_INSPECTION_REASON="origin did not name its current default branch" ;;
    esac
  fi
  if [ -z "$FM_PR_INSPECTION_REASON" ] \
    && ! git check-ref-format "$default_ref" >/dev/null 2>&1; then
    FM_PR_INSPECTION_REASON="origin named an invalid default branch"
  fi
  if [ -n "$FM_PR_INSPECTION_REASON" ]; then
    printf 'error: refusing to merge %s because the merge-boundary repository state could not be read: %s\n' \
      "$URL" "$FM_PR_INSPECTION_REASON" >&2
    printf 'action: restore the task worktree and origin access, then retry the merge\n' >&2
    return 1
  fi

  default_name=${default_ref#refs/heads/}
  FM_PR_INSPECTED_DEFAULT=$default_name
  if [ "$target" != "$default_name" ]; then
    printf 'error: refusing to merge %s because %s reports actual target branch %s, but guarded merging is limited to current default branch %s\n' \
      "$URL" "$([ "$PROVIDER" = github ] && printf GitHub || printf GitLab)" \
      "${target:-unreadable}" "$FM_PR_INSPECTED_DEFAULT" >&2
    printf 'action: retarget the PR to current default branch %s, bring the branch up to current %s, and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi

  token="$$-${RANDOM:-0}"
  base_ref="refs/fm-pr-merge/$token/base"
  head_ref="refs/fm-pr-merge/$token/head"
  if ! fm_pr_remote_git "$probe_timeout" -C "$WT" fetch --quiet --no-tags origin \
    "+$default_ref:$base_ref" "+$source_ref:$head_ref" 2>/dev/null; then
    git -C "$WT" update-ref -d "$base_ref" >/dev/null 2>&1 || true
    git -C "$WT" update-ref -d "$head_ref" >/dev/null 2>&1 || true
    printf 'error: refusing to merge %s because the merge-boundary repository state could not be read: origin did not provide the current default branch and PR head\n' \
      "$URL" >&2
    printf 'action: restore the task worktree and origin access, then retry the merge\n' >&2
    return 1
  fi
  base=$(git -C "$WT" rev-parse --verify "$base_ref^{commit}" 2>/dev/null) || base=
  head=$(git -C "$WT" rev-parse --verify "$head_ref^{commit}" 2>/dev/null) || head=
  git -C "$WT" update-ref -d "$base_ref" >/dev/null 2>&1 || true
  git -C "$WT" update-ref -d "$head_ref" >/dev/null 2>&1 || true
  if ! fm_pr_head_valid "$base" || ! fm_pr_head_valid "$head"; then
    printf 'error: refusing to merge %s because the merge-boundary repository state could not be read: fetched default branch or PR head is not a commit\n' \
      "$URL" >&2
    printf 'action: restore the task worktree and origin access, then retry the merge\n' >&2
    return 1
  fi
  FM_PR_INSPECTED_HEAD=$head
  FM_PR_INSPECTED_BASE=$base
}

FM_GITLAB_INITIAL_STATE=
FM_GITLAB_INITIAL_TARGET=
gitlab_read_initial_state() {
  local encoded_path json fields line total=0 named=0
  FM_GITLAB_INITIAL_STATE=
  FM_GITLAB_INITIAL_TARGET=
  encoded_path=$(printf '%s' "$FM_PR_PATH" | sed 's|/|%2F|g')
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab api \
    "projects/$encoded_path/merge_requests/$PR_NUMBER" 2>/dev/null) \
    || [ -z "$json" ] \
    || ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" and (.state | type) == "string"
        and (.target_branch | type) == "string"
      then "state=" + .state, "target=" + .target_branch
      else error("merge request state is unavailable") end' 2>/dev/null); then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) FM_GITLAB_INITIAL_STATE=${line#state=} ;;
      target=*) FM_GITLAB_INITIAL_TARGET=${line#target=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  [ "$total" -eq 2 ] && [ "$named" -eq 2 ] \
    && [ -n "$FM_GITLAB_INITIAL_TARGET" ] \
    && case "$FM_GITLAB_INITIAL_STATE" in opened|closed|merged) true ;; *) false ;; esac
}

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
FM_PR_MERGE_TARGET=
FM_PR_MERGE_TARGET_OID=
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' target='' target_oid='' pipeline_sha='' pipeline_status=''
  local source_ref="refs/merge-requests/$PR_NUMBER/head"
  local target_ref="refs/heads/$FM_PR_INSPECTED_DEFAULT"

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  # shellcheck disable=SC2016 # Non-expansion is intentional: these are GraphQL variables.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab api graphql \
    -f fullPath="$FM_PR_PATH" -f iid="$PR_NUMBER" \
    -f targetRef="$target_ref" -f sourceRef="$source_ref" \
    -f query='query($fullPath: ID!, $iid: String!, $sourceRef: String!, $targetRef: String!) {
      project(fullPath: $fullPath) {
        mergeRequest(iid: $iid) {
          state
          detailedMergeStatus
          conflicts
          mergeableDiscussionsState
          targetBranch
          headPipeline { sha status }
        }
        repository {
          mergeRequestHead: commit(ref: $sourceRef) { sha }
          target: commit(ref: $targetRef) { sha }
        }
      }
    }' 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" and ((.errors // []) | length) == 0
        and (.data.project | type) == "object"
        and (.data.project.mergeRequest | type) == "object"
      then
        .data.project as $project |
        $project.mergeRequest as $mr |
        "state=" + (($mr.state // "") | tostring),
        "detail=" + (($mr.detailedMergeStatus // "") | tostring | ascii_downcase),
        "conflicts=" + ($mr.conflicts | tostring),
        "discussions=" + ($mr.mergeableDiscussionsState | tostring),
        "head=" + (($project.repository.mergeRequestHead.sha // "") | tostring),
        "target=" + (($mr.targetBranch // "") | tostring),
        "target_oid=" + (($project.repository.target.sha // "") | tostring),
        "pipeline_sha=" + (($mr.headPipeline.sha // "") | tostring),
        "pipeline_status=" + (($mr.headPipeline.status // "") | tostring | ascii_downcase)
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
      target=*) target=${line#target=} ;;
      target_oid=*) target_oid=${line#target_oid=} ;;
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
  if [ "$named" -ne 9 ] || [ "$total" -ne 9 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  FM_PR_MERGE_TARGET=$target
  FM_PR_MERGE_TARGET_OID=$target_oid
  [ "$state" = merged ] && return 4
  [ "$target" = "$FM_PR_INSPECTED_DEFAULT" ] || return 5
  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  if [ "$live_head" != "$FM_PR_INSPECTED_HEAD" ]; then
    printf 'notice: GitLab head moved from inspected %s to live %s; re-inspecting the live head\n' \
      "$FM_PR_INSPECTED_HEAD" "$live_head" >&2
    return 3
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

gitlab_require_attested_merge() {
  local encoded_path json automatic_rebase merge_method ancestry_rc
  local version_json version_fields line server_major='' server_minor=''
  local total=0 named=0
  encoded_path=$(printf '%s' "$FM_PR_PATH" | sed 's|/|%2F|g')
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded_path" 2>/dev/null) \
    || [ -z "$json" ]; then
    printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled could not be determined, and unknown does not prove automatic rebase is disabled\n' \
      "$URL" >&2
    printf 'action: bring the branch up to current %s and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi
  if ! automatic_rebase=$(printf '%s' "$json" | jq -r '
      if type != "object" then error("project payload is not an object")
      elif has("automatic_rebase_enabled") then
        if (.automatic_rebase_enabled | type) == "boolean"
        then (.automatic_rebase_enabled | tostring)
        else error("automatic_rebase_enabled is unreadable") end
      else "absent" end' 2>/dev/null); then
    printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled could not be determined, and unknown does not prove automatic rebase is disabled\n' \
      "$URL" >&2
    printf 'action: bring the branch up to current %s and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi
  if [ "$automatic_rebase" = true ]; then
    if ! merge_method=$(printf '%s' "$json" | jq -r '
        if type == "object" and (.merge_method | type) == "string"
        then .merge_method else error("merge_method is unreadable") end' \
        2>/dev/null); then
      printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled could not be determined, and unknown does not prove automatic rebase is disabled\n' \
        "$URL" >&2
      printf 'action: bring the branch up to current %s and re-run validation\n' \
        "$FM_PR_INSPECTED_DEFAULT" >&2
      return 1
    fi
    case "$merge_method" in
      merge) return 0 ;;
      rebase_merge|ff) ;;
      *)
        printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled could not be determined, and unknown does not prove automatic rebase is disabled\n' \
          "$URL" >&2
        printf 'action: bring the branch up to current %s and re-run validation\n' \
          "$FM_PR_INSPECTED_DEFAULT" >&2
        return 1
        ;;
    esac
    ancestry_rc=0
    git -C "$WT" merge-base --is-ancestor \
      "$FM_PR_INSPECTED_BASE" "$FM_PR_INSPECTED_HEAD" 2>/dev/null \
      || ancestry_rc=$?
    case "$ancestry_rc" in
      0) return 0 ;;
      1) ;;
      *)
        printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled could not be determined, and unknown does not prove automatic rebase is disabled\n' \
          "$URL" >&2
        printf 'action: bring the branch up to current %s and re-run validation\n' \
          "$FM_PR_INSPECTED_DEFAULT" >&2
        return 1
        ;;
    esac
    printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled is enabled and can rebase the source branch at merge time\n' \
      "$URL" >&2
    printf 'action: bring the branch up to current %s and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi
  [ "$automatic_rebase" = false ] && return 0

  if ! version_json=$(GITLAB_HOST="$FM_PR_HOST" glab api version 2>/dev/null) \
    || [ -z "$version_json" ] \
    || ! version_fields=$(printf '%s' "$version_json" | jq -r '
      if type == "object" and (.version | type) == "string"
      then .version | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)") |
        "major=" + .major, "minor=" + .minor
      else error("GitLab version is unavailable") end' 2>/dev/null); then
    printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled could not be determined, and unknown does not prove automatic rebase is disabled\n' \
      "$URL" >&2
    printf 'action: bring the branch up to current %s and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      major=*) server_major=${line#major=} ;;
      minor=*) server_minor=${line#minor=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<VERSION_FIELDS
$version_fields
VERSION_FIELDS
  if [ "$named" -ne 2 ] || [ "$total" -ne 2 ] \
    || [ -z "$server_major" ] || [ -z "$server_minor" ]; then
    printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled could not be determined, and unknown does not prove automatic rebase is disabled\n' \
      "$URL" >&2
    printf 'action: bring the branch up to current %s and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi

  # GitLab introduced automatic rebase in 18.0 behind a feature flag, enabled
  # it on GitLab.com in 18.11, removed the flag in 19.0, and made it generally
  # available in 19.2: https://docs.gitlab.com/user/project/merge_requests/methods/
  # The Projects API first exposes automatic_rebase_enabled in 19.4:
  # https://docs.gitlab.com/api/projects/
  # The gap between those versions is why a pre-19.4 response without the field
  # is accepted only when merge method or ancestry proves rebase cannot run.
  if [ "$server_major" -gt 19 ] \
    || { [ "$server_major" -eq 19 ] && [ "$server_minor" -ge 4 ]; }; then
    printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled could not be determined, and unknown does not prove automatic rebase is disabled\n' \
      "$URL" >&2
    printf 'action: bring the branch up to current %s and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi

  merge_method=$(printf '%s' "$json" | jq -r '
    if type == "object" and (.merge_method | type) == "string"
    then .merge_method else "" end' 2>/dev/null) || merge_method=
  [ "$merge_method" = merge ] && return 0
  if git -C "$WT" merge-base --is-ancestor \
    "$FM_PR_INSPECTED_BASE" "$FM_PR_INSPECTED_HEAD" 2>/dev/null; then
    return 0
  fi
  printf 'error: refusing to merge %s because this pre-19.4 GitLab instance does not expose automatic_rebase_enabled and the source branch is behind the target, so automatic rebase cannot be ruled out\n' \
    "$URL" >&2
  printf 'action: bring the branch up to current %s and re-run validation\n' \
    "$FM_PR_INSPECTED_DEFAULT" >&2
  return 1
}

FM_GITHUB_STATE=
FM_GITHUB_BASE_REF=
FM_GITHUB_HEAD_OID=
FM_GITHUB_BASE_OID=
FM_GITHUB_QUEUE_ENABLED=
FM_GITHUB_IN_QUEUE=
FM_GITHUB_AUTO_MERGE=
FM_GITHUB_QUEUE_ENTRY=
github_read_merge_state() {
  local fields line
  local total=0 named=0
  FM_GITHUB_STATE=
  FM_GITHUB_BASE_REF=
  FM_GITHUB_HEAD_OID=
  FM_GITHUB_BASE_OID=
  FM_GITHUB_QUEUE_ENABLED=
  FM_GITHUB_IN_QUEUE=
  FM_GITHUB_AUTO_MERGE=
  FM_GITHUB_QUEUE_ENTRY=
  # shellcheck disable=SC2016 # Non-expansion is intentional: these are GraphQL variables.
  if ! fields=$(GH_PROMPT_DISABLED=1 gh api graphql --hostname "$FM_PR_HOST" \
    -f owner="$PR_OWNER" -f name="$PR_REPO" -F number="$PR_NUMBER" \
    -f query='query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          state
          baseRefName
          headRefOid
          baseRefOid
          isMergeQueueEnabled
          isInMergeQueue
          autoMergeRequest { enabledAt }
          mergeQueueEntry { state }
        }
      }
    }' --jq '
      .data.repository.pullRequest |
      if type != "object" then error("pull request state is unavailable") else
        "state=" + ((.state // "") | tostring),
        "base_ref=" + ((.baseRefName // "") | tostring),
        "head_oid=" + ((.headRefOid // "") | tostring),
        "base_oid=" + ((.baseRefOid // "") | tostring),
        "queue_enabled=" + (if has("isMergeQueueEnabled") then (.isMergeQueueEnabled | tostring) else "" end),
        "in_queue=" + (if has("isInMergeQueue") then (.isInMergeQueue | tostring) else "" end),
        "auto_merge=" + (if has("autoMergeRequest") then (if .autoMergeRequest == null then "none" else "active" end) else "unknown" end),
        "queue_entry=" + (if has("mergeQueueEntry") then (if .mergeQueueEntry == null then "none" else ((.mergeQueueEntry.state // "unknown") | tostring) end) else "unknown" end)
      end' 2>/dev/null); then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) FM_GITHUB_STATE=${line#state=} ;;
      base_ref=*) FM_GITHUB_BASE_REF=${line#base_ref=} ;;
      head_oid=*) FM_GITHUB_HEAD_OID=${line#head_oid=} ;;
      base_oid=*) FM_GITHUB_BASE_OID=${line#base_oid=} ;;
      queue_enabled=*) FM_GITHUB_QUEUE_ENABLED=${line#queue_enabled=} ;;
      in_queue=*) FM_GITHUB_IN_QUEUE=${line#in_queue=} ;;
      auto_merge=*) FM_GITHUB_AUTO_MERGE=${line#auto_merge=} ;;
      queue_entry=*) FM_GITHUB_QUEUE_ENTRY=${line#queue_entry=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  [ "$total" -eq 8 ] && [ "$named" -eq 8 ] || return 1
  case "$FM_GITHUB_STATE" in OPEN|CLOSED|MERGED) ;; *) return 1 ;; esac
}

github_refuse_unknown_immediate_execution() {
  printf 'error: refusing to merge %s because GitHub immediate execution state is unknown, and unknown does not prove deferral is absent\n' \
    "$URL" >&2
  return 1
}

github_require_immediate_execution() {
  case "$FM_GITHUB_STATE" in
    MERGED) return 3 ;;
    CLOSED)
      printf 'error: refusing to merge %s because GitHub reports the pull request is closed\n' "$URL" >&2
      return 1
      ;;
  esac
  case "$FM_GITHUB_QUEUE_ENABLED:$FM_GITHUB_IN_QUEUE" in
    true:true|true:false|false:true|false:false) ;;
    *) github_refuse_unknown_immediate_execution; return 1 ;;
  esac
  case "$FM_GITHUB_AUTO_MERGE" in
    none|active) ;;
    *) github_refuse_unknown_immediate_execution; return 1 ;;
  esac
  case "$FM_GITHUB_QUEUE_ENTRY" in
    none|AWAITING_CHECKS|LOCKED|MERGEABLE|QUEUED|UNMERGEABLE) ;;
    *) github_refuse_unknown_immediate_execution; return 1 ;;
  esac
  if [ "$FM_GITHUB_QUEUE_ENABLED" = true ] || [ "$FM_GITHUB_IN_QUEUE" = true ] \
    || [ "$FM_GITHUB_QUEUE_ENTRY" != none ]; then
    printf 'error: refusing to merge %s because the GitHub merge queue on target branch %s would defer execution\n' \
      "$URL" "$FM_GITHUB_BASE_REF" >&2
    return 1
  fi
  if [ "$FM_GITHUB_AUTO_MERGE" = active ]; then
    printf 'error: refusing to merge %s because GitHub auto-merge is active and would defer execution\n' \
      "$URL" >&2
    return 1
  fi
}

refuse_changed_target_after_reinspection() {
  local target=$1 old_default=$FM_PR_INSPECTED_DEFAULT forge
  case "$PROVIDER" in
    github) forge=GitHub ;;
    gitlab) forge=GitLab ;;
    *) return 1 ;;
  esac
  inspect_merge_boundary "$target" || return 1
  printf 'error: refusing to merge %s because the %s target and current default branch changed during validation from %s to %s\n' \
    "$URL" "$forge" "$old_default" "$FM_PR_INSPECTED_DEFAULT" >&2
  printf 'action: re-run validation against current default branch %s\n' \
    "$FM_PR_INSPECTED_DEFAULT" >&2
  return 1
}

verify_forge_inspected_identity() {
  local forge target head_oid base_oid
  case "$PROVIDER" in
    github)
      forge=GitHub
      target=$FM_GITHUB_BASE_REF
      head_oid=$FM_GITHUB_HEAD_OID
      base_oid=$FM_GITHUB_BASE_OID
      ;;
    gitlab)
      forge=GitLab
      target=$FM_PR_MERGE_TARGET
      head_oid=$FM_PR_MERGE_HEAD
      base_oid=$FM_PR_MERGE_TARGET_OID
      ;;
    *) return 1 ;;
  esac
  if [ "$target" != "$FM_PR_INSPECTED_DEFAULT" ]; then
    printf 'error: refusing to merge %s because %s reports actual target branch %s, but guarded merging is limited to current default branch %s\n' \
      "$URL" "$forge" "${target:-unreadable}" "$FM_PR_INSPECTED_DEFAULT" >&2
    printf 'action: retarget the PR to current default branch %s, bring the branch up to current %s, and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi
  if ! fm_pr_head_valid "$head_oid"; then
    printf 'error: refusing to merge %s because %s did not provide a readable head OID at the merge boundary\n' \
      "$URL" "$forge" >&2
    return 1
  fi
  if ! fm_pr_head_valid "$base_oid"; then
    printf 'error: refusing to merge %s because %s did not provide a readable target-branch OID at the merge boundary\n' \
      "$URL" "$forge" >&2
    return 1
  fi
  if [ "$head_oid" != "$FM_PR_INSPECTED_HEAD" ]; then
    printf 'error: refusing to merge %s because %s reports head OID %s but the merge-boundary repository snapshot used %s\n' \
      "$URL" "$forge" "$head_oid" "$FM_PR_INSPECTED_HEAD" >&2
    return 1
  fi
  if [ "$base_oid" != "$FM_PR_INSPECTED_BASE" ]; then
    printf 'error: refusing to merge %s because %s reports target branch %s at OID %s but the merge-boundary repository snapshot used %s\n' \
      "$URL" "$forge" "$target" "$base_oid" "$FM_PR_INSPECTED_BASE" >&2
    printf 'action: bring the branch up to current %s and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi
}

github_confirm_merged() {
  if ! github_read_merge_state; then
    printf 'actionable: GitHub accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$FM_GITHUB_STATE" = MERGED ] && return 0
  if [ "$FM_GITHUB_IN_QUEUE" = true ] || [ "$FM_GITHUB_QUEUE_ENTRY" != none ]; then
    printf 'error: refusing to treat %s as merged because GitHub queued it for deferred execution on target branch %s; the merge poll remains armed\n' \
      "$URL" "$FM_GITHUB_BASE_REF" >&2
    return 1
  fi
  if [ "$FM_GITHUB_AUTO_MERGE" = active ]; then
    printf 'error: refusing to treat %s as merged because GitHub left auto-merge pending; the merge poll remains armed\n' \
      "$URL" >&2
    return 1
  fi
  printf 'error: refusing to treat %s as merged because GitHub left it pending instead of executing immediately; the merge poll remains armed\n' \
    "$URL" >&2
  return 1
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
  if [ "$state" != merged ]; then
    printf 'error: refusing to treat %s as merged because GitLab left it queued or pending instead of executing immediately; the merge poll remains armed\n' \
      "$URL" >&2
    return 1
  fi
}

verify_inspected_default_tip() {
  local remote_state live_ref live_tip
  local probe_timeout=${FM_PR_MERGE_PROBE_TIMEOUT:-15}
  case "$probe_timeout" in ''|*[!0-9]*|0) probe_timeout=15 ;; esac
  if ! remote_state=$(fm_pr_remote_git "$probe_timeout" \
    -C "$WT" ls-remote --symref origin HEAD 2>/dev/null); then
    printf 'error: refusing to merge %s because the current default-branch tip could not be re-read immediately before merge\n' \
      "$URL" >&2
    return 1
  fi
  live_ref=$(printf '%s\n' "$remote_state" | awk '
    $1 == "ref:" && $3 == "HEAD" { count++; value=$2 }
    END { if (count == 1) print value; else exit 1 }
  ') || live_ref=
  live_tip=$(printf '%s\n' "$remote_state" | awk '
    $2 == "HEAD" && $1 != "ref:" { count++; value=$1 }
    END { if (count == 1) print value; else exit 1 }
  ') || live_tip=
  case "$live_ref" in refs/heads/*) ;; *) live_ref= ;; esac
  if [ -z "$live_ref" ] || ! fm_pr_head_valid "$live_tip"; then
    printf 'error: refusing to merge %s because the current default-branch tip could not be identified immediately before merge\n' \
      "$URL" >&2
    return 1
  fi
  if [ "$live_ref" != "refs/heads/$FM_PR_INSPECTED_DEFAULT" ]; then
    printf 'error: refusing to merge %s because the current default branch moved from %s at tip %s to %s at tip %s before merge\n' \
      "$URL" "$FM_PR_INSPECTED_DEFAULT" "$FM_PR_INSPECTED_BASE" \
      "${live_ref#refs/heads/}" "$live_tip" >&2
    printf 'action: re-run validation against current default branch %s\n' \
      "${live_ref#refs/heads/}" >&2
    return 1
  fi
  if [ "$live_tip" != "$FM_PR_INSPECTED_BASE" ]; then
    printf 'error: refusing to merge %s because current default branch %s moved from inspected tip %s to live tip %s before merge\n' \
      "$URL" "$FM_PR_INSPECTED_DEFAULT" "$FM_PR_INSPECTED_BASE" "$live_tip" >&2
    printf 'action: bring the branch up to current %s and re-run validation\n' \
      "$FM_PR_INSPECTED_DEFAULT" >&2
    return 1
  fi
}

merge_mutation_accepted=0
case "$PROVIDER" in
  github)
    github_preflight_rc=0
    if ! github_read_merge_state; then
      github_refuse_unknown_immediate_execution
      exit 1
    fi
    if [ "$FM_GITHUB_STATE" = MERGED ]; then
      github_preflight_rc=3
    else
      inspect_merge_boundary "$FM_GITHUB_BASE_REF" || exit 1
      github_require_immediate_execution || github_preflight_rc=$?
      [ "$github_preflight_rc" -eq 0 ] || exit 1
    fi
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    if [ "$github_preflight_rc" -eq 0 ]; then
      github_args=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --method)
            [ "$#" -ge 2 ] || { echo "error: merge method value is missing" >&2; exit 1; }
            github_args+=("--$2")
            shift 2
            ;;
          --method=*)
            github_args+=("--${1#--method=}")
            shift
            ;;
          --body-file|-F)
            materialize_github_body_file "$2" "$1" || exit 1
            github_args+=(--body-file "$FM_PR_MATERIALIZED_BODY_FILE")
            shift 2
            ;;
          --body-file=*)
            materialize_github_body_file "${1#--body-file=}" --body-file || exit 1
            github_args+=(--body-file "$FM_PR_MATERIALIZED_BODY_FILE")
            shift
            ;;
          --subject|--body|-t|-b)
            github_args+=("$1" "$2")
            shift 2
            ;;
          *) github_args+=("$1"); shift ;;
        esac
      done
      github_preflight_rc=0
      if ! github_read_merge_state; then
        github_refuse_unknown_immediate_execution
        exit 1
      fi
      if [ "$FM_GITHUB_STATE" != MERGED ] \
        && [ "$FM_GITHUB_BASE_REF" != "$FM_PR_INSPECTED_DEFAULT" ]; then
        refuse_changed_target_after_reinspection "$FM_GITHUB_BASE_REF" || exit 1
      fi
      github_require_immediate_execution || github_preflight_rc=$?
      case "$github_preflight_rc" in
        0)
          verify_forge_inspected_identity || exit 1
          # A sub-second residual window remains because neither forge exposes an
          # expected-base parameter; this guard narrows rather than eliminates it.
          verify_inspected_default_tip || exit 1
          GH_PROMPT_DISABLED=1 gh pr merge "$PR_NUMBER" \
            --repo "$FM_PR_HOST/$PR_OWNER/$PR_REPO" \
            --match-head-commit "$FM_PR_INSPECTED_HEAD" \
            "${merge_args[@]+"${merge_args[@]}"}" "${github_args[@]+"${github_args[@]}"}"
          merge_mutation_accepted=1
          ;;
        3) ;;
        *) exit 1 ;;
      esac
      cleanup_materialized_body_files
      trap - EXIT HUP INT TERM
    fi
    if [ "$merge_mutation_accepted" -eq 1 ]; then
      github_confirm_rc=0
      github_confirm_merged || github_confirm_rc=$?
      case "$github_confirm_rc" in 0) ;; 2) exit 0 ;; *) exit 1 ;; esac
    fi
    ;;
  gitlab)
    if ! gitlab_read_initial_state; then
      echo "error: could not read the GitLab merge request state before merging" >&2
      exit 1
    fi
    case "$FM_GITLAB_INITIAL_STATE" in
      merged) ;;
      opened|closed)
        inspect_merge_boundary "$FM_GITLAB_INITIAL_TARGET" || exit 1
        gitlab_attempt=1
        while :; do
          gitlab_require_attested_merge || exit 1
          gitlab_verify_rc=0
          gitlab_verify_mergeable || gitlab_verify_rc=$?
          case "$gitlab_verify_rc" in
            0|4) break ;;
            3)
              if [ "$gitlab_attempt" -ne 1 ]; then
                echo "error: refusing to merge $URL because its head changed repeatedly during validation" >&2
                exit 1
              fi
              inspect_merge_boundary "$FM_PR_MERGE_TARGET" || exit 1
              gitlab_attempt=2
              ;;
            5)
              refuse_changed_target_after_reinspection "$FM_PR_MERGE_TARGET" || exit 1
              ;;
            *) exit 1 ;;
          esac
        done
        if [ "$gitlab_verify_rc" -eq 0 ]; then
          verify_forge_inspected_identity || exit 1
          # A sub-second residual window remains because neither forge exposes an
          # expected-base parameter; this guard narrows rather than eliminates it.
          verify_inspected_default_tip || exit 1
          # --sha binds the merge to the head this run verified, so a push that lands
          # in between is refused by GitLab instead of merged unverified. --yes only
          # skips the interactive confirmation, which no supervised run can answer;
          # the conditions above are what authorize the merge.
          GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
            --sha "$FM_PR_MERGE_HEAD" --yes --auto-merge=false "$@"
          merge_mutation_accepted=1
        fi
        if [ "$merge_mutation_accepted" -eq 1 ]; then
          gitlab_confirm_rc=0
          gitlab_confirm_merged || gitlab_confirm_rc=$?
          case "$gitlab_confirm_rc" in 0) ;; 2) exit 0 ;; *) exit 1 ;; esac
        fi
        ;;
    esac
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after a preflight or post-mutation forge read reported the merge
# landed: set -e exits on a refused, queued, pending, unreadable, or failed merge
# above while its existing poll remains armed.
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
