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
# The gh-axi merge abstraction always performs the merge; the outcome read that
# follows it never becomes a prerequisite for reaching that abstraction. After
# gh-axi returns success, GitHub's live state is read back and accepted only
# when the pull request is merged or in the merge queue. gh's GraphQL API
# supplies that queue-aware read when gh is on PATH; when gh is absent or its
# read fails, gh-axi's own view still proves a landed merge, and every outcome
# it cannot prove refuses, reporting the single failed read when gh is absent
# and naming both failed reads when gh is present and its own read failed.
# If the pull request remains open and the base branch has an effective
# merge_queue rule, the refusal names the queue's configured merge method and
# the exact -- --auto --<method> retry flags, unless the caller already passed
# that method with --auto to a merge command that returned success, in which
# case it reports instead that the accepted request has not entered the queue
# and the queue state has to be re-checked.
# No method is selected for the caller in any case. A rules response that names
# no queue rule, one that could not be read, rules that disagree, and a method
# this script does not recognise are four distinct outcomes and are reported
# apart, because each one leaves the operator somewhere different.
# A caller-requested --auto that leaves the pull request neither merged nor
# queued is refused the same way and says auto-merge was armed with nothing
# landed or queued yet, or, when the merge command itself failed, that auto-merge
# was only requested; both are read from the caller's own arguments rather than
# from the forge's prose. The observed state is judged the same way whichever
# read produced it, and a refusal built on the gh-axi view says the merge queue
# could not be observed at all rather than implying an unqueued pull request.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
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
# On GitLab, this script confirms the MR is actually merged before reporting it;
# an auto-merge-queued or unconfirmed request leaves the poll armed and records
# no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
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

# Forwarded arguments are an ALLOW-LIST, not a denylist. An unbounded passthrough
# cannot be closed: each refused flag only reveals the next one. Every admitted
# entry records WHY it is safe, and the reason is always the same shape - it acts
# on how the merge commit is FORMED, or AFTER execution has already happened, so
# it cannot defer execution. A flag whose safety justification cannot be written
# honestly does not belong here.
#
#   --squash --merge -s -m        merge-method selectors: choose how the merge
#                                 commit is formed, not when it happens.
#   --method --method=*           the same selection by name.
#   --subject --body -t -b        commit message text, applied to the commit the
#   --body-file -F                merge itself creates.
#   -d --delete-branch            GitHub branch cleanup, which runs AFTER the
#   --remove-source-branch        merge has executed and so cannot defer it.
#
# Deliberately NOT admitted, each for a stated reason:
#   --auto                        requests deferred execution outright.
#   --rebase -r                   on GitLab this rewrites the source branch
#                                 BEFORE the merge and leaves it rewritten even
#                                 when the SHA-bound merge then fails, which is
#                                 the mutation the no-auto-rebase rule prevents.
#   --repo -R                     would retarget the mutation away from the
#                                 identity this run validated.
# Refusing by name rather than silently dropping keeps a caller's mistake loud.
assert_merge_args_allowed() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|-s|-m|--method|--method=*) ;;
      --subject|--body|-t|-b|--body-file|-F) ;;
      --subject=*|--body=*|--body-file=*) ;;
      -d|--delete-branch|--remove-source-branch) ;;
      --auto|--auto=*)
        printf 'error: refusing to forward %s to the merge of %s because it requests deferred execution, and this fleet merges immediately on judged evidence\n' \
          "$arg" "$URL" >&2
        printf 'action: land the pull request with an immediate merge method, or bring the branch up and re-run validation\n' >&2
        return 1
        ;;
      --rebase|-r)
        printf 'error: refusing to forward %s to the merge of %s because a rebase rewrites the source branch before the merge and leaves it rewritten even if the merge then fails\n' \
          "$arg" "$URL" >&2
        printf 'action: land the pull request with --squash or --merge, or bring the branch up and re-run validation\n' >&2
        return 1
        ;;
      *)
        printf 'error: refusing to forward %s to the merge of %s because it is not on the allow-list of merge-method selectors, message arguments, and post-execution branch cleanup\n' \
          "$arg" "$URL" >&2
        printf 'action: re-run the merge without that argument, or add it to the allow-list in %s with a recorded reason why it cannot defer execution\n' \
          "$0" >&2
        return 1
        ;;
    esac
  done
}

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# The merge method the caller's own extra arguments named, in the --flag,
# --method <value> and --method=<value> forms caller_has_merge_method accepts.
caller_merge_method() {
  local arg method='' pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      method=$arg
      pending=false
      continue
    fi
    case "$arg" in
      --squash) method=squash ;;
      --merge) method=merge ;;
      --rebase) method=rebase ;;
      --method) pending=true ;;
      --method=*) method=${arg#--method=} ;;
    esac
  done
  printf '%s' "$method"
}

# Whether the caller's own extra arguments asked for auto-merge, including the
# --flag=value spelling the forge's flag parser accepts. --disable-auto cancels
# the request, and gh exposes no short option that could bundle either flag.
caller_requested_auto_merge() {
  local arg requested=1
  for arg in "$@"; do
    case "$arg" in
      --auto) requested=0 ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) requested=0 ;;
          *) requested=1 ;;
        esac
        ;;
      --disable-auto) requested=1 ;;
    esac
  done
  return "$requested"
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

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
# GitLab can rebase the source branch onto the target AT MERGE TIME, which lands
# commits whose pipeline never ran and strands the attestation this fleet merges
# on. Refusal is bounded to the window where that can actually happen, because a
# guard that refuses merges the forge could never have rebased is a guard people
# switch off.
#
# Version facts, verified against GitLab's own documentation:
#   - automatic rebase before merge is available only for the "Merge commit with
#     semi-linear history" (rebase_merge) and "Fast-forward merge" (ff) methods,
#     and runs only "when the source branch is behind the target branch"
#     (https://docs.gitlab.com/user/project/merge_requests/methods/)
#   - it became GENERALLY AVAILABLE in GitLab 19.2, while the API field that
#     reports it, automatic_rebase_enabled, first appears in 19.4
#     (https://docs.gitlab.com/api/projects/)
# THE GAP BETWEEN 19.2 AND 19.4 IS WHY THIS CHECK IS SHAPED THIS WAY: on those
# two versions the capability exists and cannot be read, so an absent field is
# NOT proof the capability is absent. Do not simplify this to "field missing
# means unsupported"; that silently disables the guard on the deployments that
# still carry the risk.
#
# UNKNOWN IS NOT ABSENT: only a POSITIVE reading permits. An unreadable merge
# method, or an unreadable setting on an applicable method, still refuses.
gitlab_require_attested_merge() {
  local json method enabled version
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$(github_urlencode_path_segment "$FM_PR_PATH")" 2>/dev/null) \
    || [ -z "$json" ]; then
    printf 'error: refusing to merge %s because the GitLab project merge settings could not be read, and unknown does not prove automatic rebase is disabled\n' \
      "$URL" >&2
    printf 'action: re-run validation once the forge is readable\n' >&2
    return 1
  fi
  method=$(printf '%s' "$json" | jq -r '.merge_method // empty' 2>/dev/null)
  if [ -z "$method" ]; then
    printf 'error: refusing to merge %s because the GitLab project merge method could not be read, and unknown does not prove automatic rebase is disabled\n' \
      "$URL" >&2
    printf 'action: re-run validation once the forge is readable\n' >&2
    return 1
  fi
  # A positive reading that the method cannot auto-rebase permits regardless of
  # version, because automatic rebase does not apply to plain merge commits.
  [ "$method" = merge ] && return 0

  enabled=$(printf '%s' "$json" | jq -r 'if has("automatic_rebase_enabled") then (.automatic_rebase_enabled | tostring) else "" end' 2>/dev/null)
  if [ "$enabled" = true ]; then
    printf 'error: refusing to merge %s because the GitLab project setting automatic_rebase_enabled is on with merge method %s, so the source branch can be rebased at merge time and land commits whose pipeline never ran\n' \
      "$URL" "$method" >&2
    printf 'action: bring the branch up to the current target branch and re-run validation, or turn off automatic rebase before merge for this project\n' >&2
    return 1
  fi
  [ "$enabled" = false ] && return 0

  # Field absent. On 19.4+ that is unreadable state and refuses; before 19.4 the
  # capability exists but cannot be reported, so an applicable method refuses too.
  version=$(GITLAB_HOST="$FM_PR_HOST" glab api version 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  if [ -z "$version" ]; then
    printf 'error: refusing to merge %s because the GitLab version could not be read, so automatic rebase on merge method %s cannot be ruled out\n' \
      "$URL" "$method" >&2
    printf 'action: re-run validation once the forge is readable\n' >&2
    return 1
  fi
  printf 'error: refusing to merge %s because this GitLab instance (version %s) does not expose automatic_rebase_enabled and merge method %s can rebase the source branch at merge time, so it cannot be ruled out\n' \
    "$URL" "$version" "$method" >&2
  printf 'action: bring the branch up to the current target branch and re-run validation, or set the project merge method to merge\n' >&2
  return 1
}

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

# Read one live GitHub pull request view after gh-axi returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete state needed for a refusal. gh supplies the complete queue-aware
# view when available; gh-axi remains the degradation path that can prove a
# landed merge without making gh a prerequisite for the merge abstraction.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_DEFAULT=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base='' default=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName} defaultBranchRef{name}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository | "state=" + (.pullRequest.state // ""), "merged=" + (.pullRequest.merged | tostring), "queued=" + (.pullRequest.isInMergeQueue | tostring), "base=" + (.pullRequest.baseRefName // ""), "default=" + (.defaultBranchRef.name // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      default=*) default=${line#default=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 5 ] || [ "$total" -ne 5 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ] || [ -z "$default" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_DEFAULT=$default
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$FM_PR_HOST/$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    github_read_outcome_with_gh_axi && return 0
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>/dev/null); then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}

record_pr_metadata() {
  if ! "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

FM_PR_GITHUB_AUTO_REQUESTED=false
FM_PR_GITHUB_MERGE_ACCEPTED=false
FM_PR_GITHUB_CALLER_METHOD=

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the caller's own named method is the one the queue is configured for,
# compared without regard to the spelling either side happens to use.
github_caller_method_is() {
  case "$FM_PR_GITHUB_CALLER_METHOD" in
    [mM][eE][rR][gG][eE]) [ "$1" = merge ] ;;
    [sS][qQ][uU][aA][sS][hH]) [ "$1" = squash ] ;;
    [rR][eE][bB][aA][sS][eE]) [ "$1" = rebase ] ;;
    *) return 1 ;;
  esac
}

github_report_queue_rules() {
  local queue_method methods_display
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      if github_merge_command_succeeded \
        && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
        && github_caller_method_is "$queue_method"; then
        printf 'error: this run refuses even though the request for %s was accepted with the exact flags base branch %s requires (--auto --%s): the pull request has still not entered the merge queue, so no landed or queued outcome is proven; re-check the pull request'"'"'s merge queue state before retrying\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      else
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s -- --auto --%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$queue_method" >&2
      fi
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); exact retry flags are ambiguous\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so exact retry flags cannot be named\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
      "$URL" >&2
    return 0
  fi
  github_report_queue_rules
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

# Record before either forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
# Constrain what may reach either forge BEFORE recording, so a refused argument
# never arms a poll for a merge this run will not attempt.
assert_merge_args_allowed "$@" || exit 1

record_pr_metadata || exit 1

# Guarded merging is limited to the repository's CURRENT default branch. A PR
# targeting a release or long-lived branch is refused BY NAME rather than being
# silently compared against, or merged into, something it does not target. The
# check runs before any queue, auto-merge, or method handling so its message is
# never pre-empted by a different rejection reaching the operator first.
github_assert_default_target() {
  if ! github_read_outcome; then
    printf 'error: refusing to merge %s because its target branch could not be read, and an unread target does not prove it is the default branch\n' \
      "$URL" >&2
    printf 'action: re-run validation once the forge is readable\n' >&2
    return 1
  fi
  [ "$FM_PR_GITHUB_MERGED" = true ] && return 0
  if [ "$FM_PR_GITHUB_BASE" != "$FM_PR_GITHUB_DEFAULT" ]; then
    printf 'error: refusing to merge %s because it targets branch %s, but guarded merging is limited to current default branch %s\n' \
      "$URL" "$FM_PR_GITHUB_BASE" "$FM_PR_GITHUB_DEFAULT" >&2
    printf 'action: retarget the pull request to %s, bring the branch up to current %s, and re-run validation\n' \
      "$FM_PR_GITHUB_DEFAULT" "$FM_PR_GITHUB_DEFAULT" >&2
    return 1
  fi
}

case "$PROVIDER" in
  github)
    merge_output=
    merge_args=()
    github_assert_default_target || exit 1
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    if caller_requested_auto_merge "$@"; then
      FM_PR_GITHUB_AUTO_REQUESTED=true
    fi
    FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "$@")
    if merge_output=$(gh-axi pr merge "$PR_NUMBER" --repo "$FM_PR_HOST/$PR_OWNER/$PR_REPO" \
      "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>&1); then
      FM_PR_GITHUB_MERGE_ACCEPTED=true
    else
      merge_status=$?
      [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
      if github_read_outcome; then
        if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
          github_report_unmerged_outcome
        else
          printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
            "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
          # The forge state is the authority, not the command status. A merge the
          # forge confirms LANDED is not a failed merge just because the command
          # reporting it failed, so this falls through to outcome reporting
          # instead of exiting non-zero and leaving the landed merge unrecorded.
          if [ "$FM_PR_GITHUB_MERGED" = true ]; then
            merge_command_failed_but_landed=true
          fi
        fi
      fi
      [ "${merge_command_failed_but_landed:-false}" = true ] || exit "$merge_status"
    fi
    if ! github_read_outcome; then
      github_report_forge_output "$merge_output"
      exit 1
    fi
    if [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
    elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      # DELIBERATE FORK DIVERGENCE from upstream, recorded in docs/fork-divergence.md.
      # Upstream reports a queued request as a verified outcome and exits zero.
      # This fleet refuses deferred execution: a queued merge lands later against
      # a base nobody compared, and we merge on judged evidence at a moment in
      # time. Only the OUTCOME of this branch differs; the queue read, its
      # vocabulary and its message shape are upstream's on purpose, so future
      # sync rounds conflict as little as possible.
      printf 'error: refusing to treat %s as merged because it is queued for deferred execution (state=%s, merged=%s, isInMergeQueue=%s); the merge poll remains armed\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
      printf 'action: land the pull request with an immediate merge method, or bring the branch up and re-run validation\n' >&2
      exit 1
    else
      github_report_forge_output "$merge_output"
      github_report_unmerged_outcome
      exit 1
    fi
    ;;
  gitlab)
    gitlab_require_attested_merge || exit 1
    gitlab_verify_mergeable || exit 1
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    # Capture the command status rather than letting set -e abort here: if the
    # forge LANDS the merge and a post-execution step or the response transport
    # then fails, aborting would skip the confirmation read entirely and leave a
    # merge that really happened with nothing recording it. The forge state read
    # below is the authority; only a merge confirmed not to have landed fails.
    gitlab_merge_rc=0
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@" || gitlab_merge_rc=$?
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    if [ "$gitlab_confirm_rc" -ne 0 ] && [ "$gitlab_merge_rc" -ne 0 ]; then
      printf 'error: refusing to treat %s as merged because the merge command failed and the forge does not confirm it landed; the merge poll remains armed\n' \
        "$URL" >&2
      printf 'action: bring the branch up to the current default branch and re-run validation\n' >&2
      exit 1
    fi
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
    # This directory holds a rendered comment payload, so the signal a bounded
    # caller sends must remove it and leave a 143 status behind - the same
    # pairing bin/fm-issue-comment.sh and bin/fm-issue-status.sh use for their
    # own scratch directories. Correcting the rationale that stood here: bash
    # DOES run the EXIT trap for an untrapped fatal signal (measured 2026-09-02,
    # bash 5.2.21, docs/verification/supervision.md), so removal does not depend
    # on this handler. It stays because it states that exit contract explicitly
    # rather than leaving it to the shell's signal disposition.
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
