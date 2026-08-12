#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# After a successful merge, an optional work item recorded in task metadata is
# verified and, when it is open on a forge with a write adapter, closed with a
# comment linking the merged PR. A work_item= record names the tracker the
# project declared and is closed on THAT host and in THAT repository; only the
# legacy bare issue= number falls back to the repository the PR landed in,
# which is all a bare number can mean. github.com closes through the ambient
# gh-axi authentication; Gitea closes through config/forge-tokens/<host> via
# bin/fm-forge-lib.sh, which owns the credential rules, the write-operation
# allowlist, and the minimum token scope per forge. Several recorded work
# items, a forge or host with no write adapter, a credential that is missing,
# empty, or loose, or one the forge refuses, each warn with their own distinct
# reason, and a work item that cannot be verified says why it could not be.
# Gitea calls are bounded by FM_ISSUE_CLOSE_TIMEOUT seconds each (default 10).
# The landed milestone is recorded on every tracker surface firstmate keeps true
# (bin/fm-work-item-milestone.sh) before that close bookkeeping runs.
# Issue verification, closure, or write-back failures warn while returning
# success, because the already-completed merge must never look retryable.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
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
# shellcheck source=bin/fm-issue-lib.sh
. "$SCRIPT_DIR/fm-issue-lib.sh"
# shellcheck source=bin/fm-forge-lib.sh
. "$SCRIPT_DIR/fm-forge-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
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
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

# Refresh the cached PR observation so the task's final normalized state reads
# `merged` in the fleet snapshot and in the outcome manifest teardown publishes.
# Best effort by design: the merge already succeeded and must never look
# retryable, so a failed refresh only leaves the previous observation in place.
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-pr-status.sh" refresh "$ID" >/dev/null 2>&1 || \
  echo "warning: PR merge succeeded: $URL; the cached PR state could not be refreshed" >&2

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
