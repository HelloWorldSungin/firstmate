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
# and naming both failed reads when gh is present and its own read failed;
# neither degraded route accepts an outcome the gh-axi view cannot prove, so the
# same evidence yields the same verdict whether gh is absent or merely broken.
# If the pull request remains open and the base branch has an effective
# merge_queue rule, the refusal names the queue's configured merge method and
# the exact -- --auto --<method> retry flags, unless the caller already passed
# that method with --auto to a merge command that returned success, in which
# case it reports instead that the accepted request has not entered the queue
# and the queue state has to be re-checked. Reporting a queued request as
# upstream reports it is a captain decision of 2026-09-03 that RETIRED this
# fork's earlier refusal of deferred execution; see docs/fork-divergence.md.
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
# GUARDED MERGING IS LIMITED TO THE REPOSITORY'S CURRENT DEFAULT BRANCH on
# GitHub. A pull request targeting anything else is refused by name, naming both
# branches, before any queue, auto-merge or method handling, so that refusal is
# never pre-empted by a different one. The target and the default branch come
# from the same GraphQL query, or from gh-axi's own api passthrough when gh is
# degraded. That contract is settled BEFORE pr= is recorded and the merge poll
# armed, because the poll is a second writer of this task's landed outcome and
# knows nothing about target branches. GitLab carries no such contract yet;
# HelloWorldSungin/firstmate#257 tracks extending it.
# THE BASE IS ALSO PINNED BY STATE, not only by name: the default branch's tip
# commit is read when that contract is settled and RE-READ IMMEDIATELY BEFORE THE
# MERGE CALL, and a tip that moved in between refuses. Neither forge CLI exposes
# an expected-base parameter, so a sub-second residual window remains and is
# declared beside the check rather than papered over. An already-landed merge
# skips it, having no base left to judge.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
# Extra GitHub args are an ALLOW-LIST, not an unchanged passthrough: merge-method
# selectors, message arguments, post-execution branch cleanup, and head-binding
# arguments are admitted with a recorded reason each, and everything else is
# refused by name. See assert_merge_args_allowed below.
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
# A merge command that FAILED while the forge's own readback confirms the merge
# landed exits zero on both forges, and both say so through one shared line
# (report_landed_after_failed_command), because a run that exits zero in silence
# straight after the forge CLI printed its own error reads as an unexplained
# success.
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
# WHICH ENTRIES ARE INERT ON GITHUB TODAY, disclosed for the same reason the
# --sha entry discloses it: an admitted flag must not read as a working control
# when the tool behind it has no such flag. As OBSERVED FROM `gh-axi pr merge
# --help` AT gh-axi 0.1.34 - a version-observed fact, not a permanent property of
# the tool - gh-axi accepts exactly --method <merge|squash|rebase>, --merge,
# --squash, --rebase, --auto, --delete-branch, --body <text>, --body-file <path>
# and --subject: NO short options at all, and no --remove-source-branch. So on
# GitHub -s, -m, -t, -b, -F, -d, -r and --remove-source-branch are inert exactly
# as --sha is - a forwarded one is REJECTED BY THE TOOL rather than doing
# anything. They stay admitted because the allow-list records what this script
# considers safe to forward, which is a judgement about deferral and not a claim
# about any one CLI's current spelling; the failure mode is a loud command
# rejection, never a silent one. Mirror-image on GitLab: --delete-branch is
# glab's wrong spelling there, where the same cleanup is --remove-source-branch.
# One consequence worth stating where it is, so it is not read as a bug:
# caller_has_merge_method recognises only the long spellings, so `-- -s` still
# gets --squash prepended. That is harmless while the short forms are inert, and
# is the thing to revisit first if gh-axi ever grows them.
#
#   --squash --merge -s -m        merge-method selectors: choose how the merge
#                                 commit is formed, not when it happens.
#   --method --method=*           the same selection by name.
#   --subject --body -t -b        commit message text, applied to the commit the
#   --body-file -F                merge itself creates.
#   -d --delete-branch            GitHub branch cleanup, which runs AFTER the
#   --remove-source-branch        merge has executed and so cannot defer it.
#   --sha --sha=*                 head-binding: constrains the mutation to the
#                                 exact state this run verified. It cannot defer
#                                 execution and makes the merge strictly
#                                 narrower, so it is admitted on principle.
#                                 INERT ON BOTH FORGES TODAY, and the entry says
#                                 so rather than reading as a working control:
#                                 on GitLab reject_head_overrides refuses a
#                                 caller --sha earlier by design, because this
#                                 script supplies its own verified --sha; on
#                                 GitHub `gh-axi pr merge --help` lists its
#                                 supported flags as --method, --merge, --squash,
#                                 --rebase, --auto, --delete-branch, --body,
#                                 --body-file and --subject, with no --sha, so a
#                                 forwarded one would be rejected by the tool
#                                 rather than binding anything. NOTHING ELSE
#                                 BINDS THE HEAD ON GITHUB EITHER: this script
#                                 carries no head check on that forge, and the
#                                 entry says so rather than pointing at a check
#                                 that would have to exist for it to be true.
#                                 The BASE is bound - github_read_default_tip
#                                 refuses a merge whose default-branch tip moved
#                                 - and a base is not a head. Head binding waits
#                                 on the deferred synchronous REST merge
#                                 boundary, which is what could carry one.
#
# Deliberately NOT admitted, each for a stated reason:
#   --auto                        requests deferred execution outright.
#   --rebase -r                   REFUSED ON GITLAB ONLY. There it rewrites the
#                                 source branch BEFORE the merge and leaves it
#                                 rewritten even when the SHA-bound merge then
#                                 fails, which is the mutation the no-auto-rebase
#                                 rule prevents. On GitHub rebase merge replays
#                                 onto the base without touching the source, so
#                                 it is admitted as an ordinary merge-method
#                                 selector. Do not re-collapse these into one
#                                 rule: the rationale is forge-specific.
#   --repo -R                     would retarget the mutation away from the
#                                 identity this run validated.
# Refusing by name rather than silently dropping keeps a caller's mistake loud.
#
# WHY NO TOKEN IS EXEMPT FROM CLASSIFICATION, which is the one rule below that is
# about the TOOL rather than about deferral. This guard used to model the forge
# CLI as a POSITIONAL parser - a value-taking flag consumes the next word,
# whatever that word is - and that model was wrong in both directions before it
# was wrong here. The tool does not parse positionally: it SCANS the whole
# argument list for each flag it knows, so a token that LOOKS like a flag IS a
# flag to it, wherever it stands. OBSERVED AT gh-axi 0.1.34 and recorded as a
# version-observed fact about a third-party tool rather than a permanent
# property: dist/src/commands/pr.js calls takeBoolFlag(args, "--auto") before
# takeFlag(args, "--subject"), and dist/src/args.js's takeFlag returns undefined
# without erroring when its flag is left valueless, so `-- --subject --auto`
# satisfies a positional guard while gh-axi still arms deferred execution; the
# same file's rejectUnknownFlags inspects EVERY dash-leading token, so even one
# the tool would not act on is judged as a flag rather than carried as text.
# Hence a value-taking flag consumes the next word only when that word is not
# itself flag-shaped. A value that legitimately begins with a dash is passed with
# the --flag=<value> spelling, which is one token and cannot be mistaken for one.
assert_merge_args_allowed() {
  local arg
  # Detached values belong to the flag before them - "--sha abc123" is one
  # argument and its value, not two arguments - so a value-taking flag consumes
  # the next word. Without this the value itself reaches the catch-all and is
  # refused as an unknown argument.
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --method|--sha|--subject|--body|--body-file|-t|-b|-F)
        if [ "$#" -lt 2 ]; then
          printf 'error: refusing to merge %s because %s was given without a value\n' \
            "$URL" "$arg" >&2
          return 1
        fi
        case $2 in
          -*)
            printf 'error: refusing to forward %s to the merge of %s because it stands where %s expects a value, and the forge CLI reads every dash-leading token as a flag wherever it stands rather than as the value beside it\n' \
              "$2" "$URL" "$arg" >&2
            printf 'action: give the value with the %s=<value> spelling if that flag accepts one, or re-run the merge without that argument\n' \
              "$arg" >&2
            return 1
            ;;
        esac
        shift 2
        continue
        ;;
      --squash|--merge|-s|-m|--method=*) ;;
      --sha=*) ;;
      --subject=*|--body=*|--body-file=*) ;;
      -d|--delete-branch|--remove-source-branch) ;;
      --auto|--auto=*)
        printf 'error: refusing to forward %s to the merge of %s because it requests deferred execution, and this fleet merges immediately on judged evidence\n' \
          "$arg" "$URL" >&2
        printf 'action: land the pull request with an immediate merge method, or bring the branch up and re-run validation\n' >&2
        return 1
        ;;
      --rebase|-r)
        # THE TWO FORGES DIFFER HERE AND THE DIFFERENCE IS THE WHOLE POINT, so it
        # is recorded rather than collapsed into one rule. On GITLAB, rebase
        # REWRITES THE SOURCE BRANCH before merging and leaves it rewritten even
        # when the SHA-bound merge then fails, which is the mutation the
        # no-auto-rebase exclusion exists to prevent - so it is refused. On
        # GITHUB, rebase merge replays the commits onto the base and does not
        # touch the source branch at all: it is an ordinary immediate merge
        # method and belongs in the merge-method-selector category above.
        # Refusing it there would remove a method this file documents as
        # supported and would tell the operator something untrue about why.
        if [ "$PROVIDER" != gitlab ]; then
          shift
          continue
        fi
        printf 'error: refusing to forward %s to the merge of %s because a GitLab rebase rewrites the source branch before the merge and leaves it rewritten even if the merge then fails\n' \
          "$arg" "$URL" >&2
        printf 'action: land the merge request with --squash or --merge, or bring the branch up and re-run validation\n' >&2
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
    shift
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
FM_PR_GITLAB_ACCEPTANCE=
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
  local json method enabled version major minor behind
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
  # POSITIVE reading that the method cannot auto-rebase. Automatic rebase applies
  # only to rebase_merge and ff, so a plain merge commit permits at any version.
  [ "$method" = merge ] && return 0

  enabled=$(printf '%s' "$json" \
    | jq -r 'if has("automatic_rebase_enabled") then (.automatic_rebase_enabled | tostring) else "" end' 2>/dev/null)
  [ "$enabled" = false ] && return 0
  if [ "$enabled" = true ]; then
    gitlab_refuse_if_behind "the project setting automatic_rebase_enabled is on with merge method $method"
    return $?
  fi

  # The field is absent. That is NOT proof the capability is absent: automatic
  # rebase became generally available in GitLab 19.2 while the field reporting it
  # first appears in 19.4, so on 19.2 and 19.3 it can be on and unreadable. The
  # version decides which of the three windows applies.
  version=$(GITLAB_HOST="$FM_PR_HOST" glab api version 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  case "$version" in
    [0-9]*.[0-9]*) ;;
    *)
      printf 'error: refusing to merge %s because the GitLab version could not be read, so automatic rebase on merge method %s cannot be ruled out\n' \
        "$URL" "$method" >&2
      printf 'action: re-run validation once the forge is readable\n' >&2
      return 1
      ;;
  esac
  major=${version%%.*}
  minor=${version#*.}
  minor=${minor%%.*}
  case "$major$minor" in
    *[!0-9]*)
      printf 'error: refusing to merge %s because the GitLab version %s could not be compared, so automatic rebase on merge method %s cannot be ruled out\n' \
        "$URL" "$version" "$method" >&2
      printf 'action: re-run validation once the forge is readable\n' >&2
      return 1
      ;;
  esac
  # 19.4 and later: the field exists on this version, so its absence means the
  # response was not readable rather than that the capability is missing.
  if [ "$major" -gt 19 ] || { [ "$major" -eq 19 ] && [ "$minor" -ge 4 ]; }; then
    printf 'error: refusing to merge %s because GitLab %s exposes automatic_rebase_enabled but this project response did not carry it, and unknown does not prove automatic rebase is disabled\n' \
      "$URL" "$version" >&2
    printf 'action: re-run validation once the forge is readable\n' >&2
    return 1
  fi
  # Before 19.2 the capability did not exist at all, so there is nothing to rule
  # out and refusing here would remove legitimate merges.
  if [ "$major" -lt 19 ] || { [ "$major" -eq 19 ] && [ "$minor" -lt 2 ]; }; then
    return 0
  fi
  # 19.2 and 19.3: capability present, field absent. This is the real risk
  # window, and it only fires when the branch is actually behind.
  gitlab_refuse_if_behind "GitLab $version can rebase before merge with merge method $method but does not expose automatic_rebase_enabled"
}

# Automatic rebase runs only when the source branch is BEHIND the target, so a
# branch that is not behind cannot be rebased and must not be refused. The count
# needs include_diverged_commits_count=true; it is not returned by default.
gitlab_refuse_if_behind() {  # <because-clause>
  local because=$1 behind
  behind=$(GITLAB_HOST="$FM_PR_HOST" glab api \
    "projects/$(github_urlencode_path_segment "$FM_PR_PATH")/merge_requests/$PR_NUMBER?include_diverged_commits_count=true" \
    2>/dev/null | jq -r '.diverged_commits_count // empty' 2>/dev/null)
  case "$behind" in
    ''|*[!0-9]*)
      printf 'error: refusing to merge %s because %s, and whether the source branch is behind the target could not be established\n' \
        "$URL" "$because" >&2
      printf 'action: re-run validation once the forge reports the merge request divergence\n' >&2
      return 1
      ;;
  esac
  [ "$behind" -eq 0 ] && return 0
  printf 'error: refusing to merge %s because %s, and the source branch is %s commits behind the target, so the merge can land commits whose pipeline never ran\n' \
    "$URL" "$because" "$behind" >&2
  printf 'action: bring the branch up to the current target branch and re-run validation\n' >&2
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

# One TOON scalar field, read by name out of a TOON object gh-axi printed.
# It decodes a SINGLE value on a SINGLE line and never splits one line into two
# fields, which is the mistake it replaced. The encoder quotes a scalar only when
# leaving it bare would be ambiguous, escaping an embedded quote or backslash
# inside those quotes, so an unquoted value is already literal and a quoted one
# is undone here. A bare null is JSON null - the field was never established -
# and is reported as absent so the caller's positive-reading rule refuses, while
# the STRING "null" arrives quoted and survives as text.
github_toon_scalar() {
  local raw=$1 field=$2 value
  value=$(printf '%s\n' "$raw" \
    | sed -n "s/^[[:space:]]*$field:[[:space:]]*//p" | head -1)
  case "$value" in
    '"'*'"')
      value=${value#'"'}
      value=${value%'"'}
      value=${value//\\\"/\"}
      value=${value//\\\\/\\}
      ;;
    null) value= ;;
  esac
  printf '%s' "$value"
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
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
  # The degraded view cannot observe the merge QUEUE, but the target branch is
  # not queue state and is available through gh-axi's own api passthrough, so the
  # default-target contract is evaluated on this path too rather than silently
  # skipped. One call carries both fields: a pull request payload contains its
  # own base ref and that base repository's default branch.
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_DEFAULT=
  # ASK FOR ONE FIELD PER LINE, and the reason is the encoding rather than taste.
  # A --jq expression whose result is not JSON comes back inside a TOON envelope
  # as a single `body:` line, so two ref names joined by a space had to be SPLIT
  # back apart - and a git ref name may legally contain a comma or begin with a
  # dash, both of which make the TOON encoder QUOTE the whole scalar, after which
  # the split lands inside the quotes and the contract compares two mangled
  # names. A --jq object is valid JSON, so gh-axi encodes it as a TOON object
  # instead and each field arrives on its own line with nothing to split.
  # Captured live from gh-axi 0.1.34 - version-observed, like every other fact
  # recorded here about that tool - the exact output is two lines:
  #   base: <base>
  #   def: <default>
  # A hostile-but-legal name is still QUOTED on its own line (`base: "a,b"`,
  # `def: "-lead"`), which is why each value goes through the scalar reader
  # rather than being taken raw.
  local target_raw
  if target_raw=$(gh-axi api "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
    --jq '{base: .base.ref, def: .base.repo.default_branch}' 2>/dev/null); then
    FM_PR_GITHUB_BASE=$(github_toon_scalar "$target_raw" base)
    FM_PR_GITHUB_DEFAULT=$(github_toon_scalar "$target_raw" def)
  fi
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

# WHAT THE DEGRADED VIEW HAS TO SUPPLY, and it is not the same for both readers
# of this function. THE SEAM IS DELIBERATE; do not re-collapse it, because each
# side's rule is the wrong answer to the other side's question.
#   outcome  asked AFTER the mutation. The degraded view cannot tell an OPEN
#            pull request from a QUEUED one, so only a proved merge is legible
#            at all; without that proof there is no outcome to report. This
#            holds on BOTH degraded routes - gh absent entirely, and gh present
#            with its own read failed - because the evidence is the same gh-axi
#            view either way, and identical evidence must not yield two
#            different verdicts depending on which tool happens to be installed.
#   target   asked BEFORE the mutation. The question is which branch the pull
#            request targets and which branch is the default, and the degraded
#            reader gets both from its own api passthrough, so it ALSO accepts
#            those two fields with no merged proof. Requiring the merge here
#            would refuse every OPEN pull request on a host carrying a broken
#            gh, saying the target could not be read moments after it was.
#            ACCEPTING THE VIEW IS NOT PERMITTING THE MERGE. A proved merge
#            makes the view legible, exactly as it does on the outcome side, but
#            it answers nothing about a target: a request hand-merged into
#            release/2026 reads merged and still names a branch guarded merging
#            was never permitted to touch. github_assert_default_target decides
#            that on the two branch names alone, and refuses a landed merge this
#            view names a non-default target for, so what is accepted here is a
#            view worth reading rather than a merge worth recording.
FM_PR_GITHUB_DEGRADED_ANSWERS=outcome
github_degraded_view_answers() {
  [ "$FM_PR_GITHUB_MERGED" = true ] && return 0
  case "$FM_PR_GITHUB_DEGRADED_ANSWERS" in
    target) [ -n "$FM_PR_GITHUB_BASE" ] && [ -n "$FM_PR_GITHUB_DEFAULT" ] ;;
    *) return 1 ;;
  esac
}

# WHAT THE OPERATOR IS TOLD ABOUT BOOKKEEPING TRAVELS WITH THE PHASE, because
# the two reads sit on opposite sides of the recording step. After the merge
# attempt the PR identity and its poll are deliberately kept, so a merge that may
# have landed still has something watching it; before the merge nothing has been
# armed yet, and saying otherwise would send the operator looking for a poll that
# does not exist. One default beside the other keeps the pair from drifting.
github_read_outcome() {
  local bookkeeping=${FM_PR_GITHUB_READ_BOOKKEEPING:-PR metadata and merge poll remain recorded}
  if ! command -v gh >/dev/null 2>&1; then
    github_read_outcome_with_gh_axi && github_degraded_view_answers && return 0
    printf 'error: could not read the GitHub pull request outcome %s; %s\n' \
      "${FM_PR_GITHUB_READ_PHASE:-after the merge attempt}" "$bookkeeping" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. What the fallback then has to
  # prove depends on which question is being asked of it; see
  # FM_PR_GITHUB_DEGRADED_ANSWERS above.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && github_degraded_view_answers; then
    return 0
  fi
  printf 'error: could not read the GitHub pull request outcome %s: the gh read failed and the gh-axi view could not prove the outcome either; %s\n' \
    "${FM_PR_GITHUB_READ_PHASE:-after the merge attempt}" "$bookkeeping" >&2
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
      # The auto-requested branch below is unreachable in this fork, and the
      # reason is the forwarded-argument allow-list rather than anything about
      # the merge queue: it refuses --auto by name before the merge is attempted,
      # so FM_PR_GITHUB_AUTO_REQUESTED cannot be true here. The retry the
      # else-branch names has the same standing - it is upstream's guidance,
      # restored by the captain decision of 2026-09-03, and a caller who takes it
      # is refused by that allow-list. It is left whole rather than reworded so a
      # future upstream merge conflicts on as little as possible.
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
  # Unreachable in this fork for the same reason the auto branch above is: the
  # degraded-view seam accepts no unmerged outcome from the gh-axi view on either
  # degraded route, so every read that reaches here came from the queue-aware
  # one. Left whole rather than deleted, so a future upstream merge conflicts on
  # as little as possible.
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
      "$URL" >&2
    return 0
  fi
  github_report_queue_rules
}

# The ONE place either forge reconciles a merge command that failed with its own
# readback confirming the merge LANDED - the reachable half of the fork
# divergence recorded in docs/fork-divergence.md. Both forges reach that verdict,
# so both must state it from here: while GitHub and GitLab each wrote their own
# line, GitHub reconciled the two facts and GitLab exited zero in silence right
# after the operator had seen glab's own error, which is what two hand-written
# messages drift into. Reversing or rewording the verdict is one edit here.
report_landed_after_failed_command() {
  printf 'actionable: the merge command for %s failed, but the forge reads it back as landed (%s), so the forge state is the authority and the command status is not; the landed merge is recorded and this run exits zero\n' \
    "$URL" "$1" >&2
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab %s for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "${FM_PR_GITLAB_ACCEPTANCE:-accepted the merge request}" "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab %s for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "${FM_PR_GITLAB_ACCEPTANCE:-accepted the merge request}" "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

# Record before either forge call. This arms the merge poll without claiming a
# landed outcome, so even a provider read failure after a real merge cannot
# leave teardown without the PR identity it needs to verify the result.
# EVERY PRECONDITION THAT CAN REFUSE THE MERGE IS EVALUATED BEFORE THAT
# RECORDING, and the reason is stronger than tidiness: RECORDING ARMS A SECOND,
# INDEPENDENT WRITER OF THIS TASK'S LANDED OUTCOME. bin/fm-pr-poll.sh reads only
# whether the pull request is merged and has no notion of which branch it merged
# into, so a poll armed behind a refusal records the very landing the refusal
# exists to keep off this task's ledger - later, and by a different writer.
# A refused argument, a target this fleet may not merge into, and a base that
# could not be read are all decided here, before anything is armed.
assert_merge_args_allowed "$@" || exit 1

# Guarded merging is limited to the repository's CURRENT default branch. A PR
# targeting a release or long-lived branch is refused BY NAME rather than being
# silently compared against, or merged into, something it does not target. The
# check runs before any queue, auto-merge, or method handling so its message is
# never pre-empted by a different rejection reaching the operator first.
github_assert_default_target() {
  # This runs BEFORE any mutation AND before any bookkeeping, so the shared
  # reader must not report its failure as having happened "after the merge
  # attempt" or claim a poll it has not armed - the operator's next decision
  # depends on knowing no merge was tried and nothing is watching for one.
  local FM_PR_GITHUB_READ_PHASE='before the merge was attempted'
  local FM_PR_GITHUB_READ_BOOKKEEPING='no PR metadata was recorded and no merge poll was armed'
  # This check consumes the BASE and DEFAULT branches, which the degraded gh-axi
  # reader supplies directly, so it also accepts that reader on those two fields
  # with no proved merge - unlike the post-merge outcome read, where a proved
  # merge is the only thing that makes the degraded view legible at all, because
  # it cannot tell an open pull request from a queued one. Without this seam a
  # broken gh would refuse a target the degraded reader had just established.
  # See FM_PR_GITHUB_DEGRADED_ANSWERS.
  local FM_PR_GITHUB_DEGRADED_ANSWERS=target
  if ! github_read_outcome; then
    printf 'error: refusing to merge %s because its target branch could not be read, and an unread target does not prove it is the default branch\n' \
      "$URL" >&2
    printf 'action: re-run validation once the forge is readable\n' >&2
    return 1
  fi
  # THIS IS A PRECONDITION, NOT AN OUTCOME, so wherever the forge names both
  # branches the comparison is made - on a pull request that already reads
  # MERGED as much as on an open one. Two nearby rules invite being reconciled
  # into one; they answer different questions and must not be:
  #   the LANDED-MERGE VERDICT below asks "did OUR merge land", and exits zero on
  #   the forge's own word however the merge command behaved;
  #   this asks "was this a permitted target at all", and a merged pull request
  #   satisfies the first while still failing the second.
  # A request hand-merged into release/2026 in a repository whose default is main
  # has landed - and landed somewhere guarded merging may not touch, so recording
  # it as this task's landed outcome reports work onto a branch this contract
  # exists to keep it off. A landed merge has no target left to REFUSE and it
  # still has one left to REPORT.
  # Only a POSITIVE reading of both may permit. An empty field means the target
  # was never established, and a contract that reports itself satisfied without
  # being evaluated is worse than no contract.
  if [ -z "$FM_PR_GITHUB_BASE" ] || [ -z "$FM_PR_GITHUB_DEFAULT" ]; then
    # THE ONE CASE AN UNREAD TARGET CHANGES NOTHING: the merge already landed, so
    # there is no mutation left to refuse, and refusing here would exit non-zero
    # on a merge this run has just observed - the false negative the landed-merge
    # invariant exists to prevent. This is narrow on purpose. It permits only
    # when the target could not be READ; a target that reads as non-default is
    # refused below whether the request has merged or not.
    [ "$FM_PR_GITHUB_MERGED" = true ] && return 0
    printf 'error: refusing to merge %s because its target branch could not be established, and an unread target does not prove it is the default branch\n' \
      "$URL" >&2
    printf 'action: re-run validation once the forge reports the pull request target\n' >&2
    return 1
  fi
  if [ "$FM_PR_GITHUB_BASE" != "$FM_PR_GITHUB_DEFAULT" ]; then
    if [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'error: refusing to record %s as a landed merge because it targets branch %s and is already merged there, but guarded merging is limited to current default branch %s\n' \
        "$URL" "$FM_PR_GITHUB_BASE" "$FM_PR_GITHUB_DEFAULT" >&2
      printf 'action: the merge is on %s and nothing here undoes it; land this work on %s and re-run validation, or retire the task\n' \
        "$FM_PR_GITHUB_BASE" "$FM_PR_GITHUB_DEFAULT" >&2
      return 1
    fi
    printf 'error: refusing to merge %s because it targets branch %s, but guarded merging is limited to current default branch %s\n' \
      "$URL" "$FM_PR_GITHUB_BASE" "$FM_PR_GITHUB_DEFAULT" >&2
    printf 'action: retarget the pull request to %s, bring the branch up to current %s, and re-run validation\n' \
      "$FM_PR_GITHUB_DEFAULT" "$FM_PR_GITHUB_DEFAULT" >&2
    return 1
  fi
}

# The CURRENT tip of the branch this merge would land on, read as a commit id
# rather than a branch name. The target contract above settles WHICH branch is
# permitted; this settles WHICH STATE OF IT this run judged, so the merge can be
# refused when that state is no longer the one it judged.
#
# ONE READER ON EVERY ROUTE, deliberately: this goes through gh-axi's api
# passthrough whether gh is present, absent or broken, because gh-axi is the tool
# that performs the merge and is therefore the one tool a merge run always has.
# A base guarantee that quietly lapses on the host where gh happens to be missing
# is the shape of guarantee this file has already been wrong about twice.
FM_PR_GITHUB_DEFAULT_TIP=
github_read_default_tip() {
  local raw tip branch_path
  FM_PR_GITHUB_DEFAULT_TIP=
  [ -n "$FM_PR_GITHUB_DEFAULT" ] || return 1
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_DEFAULT")
  # A branch payload names its own head commit; asked for one field, gh-axi
  # encodes the reply as a TOON object with that field on its own line, which is
  # why the value goes through the same scalar reader the target names use.
  raw=$(gh-axi api "repos/$PR_OWNER/$PR_REPO/branches/$branch_path" \
    --jq '{tip: .commit.sha}' 2>/dev/null) || return 1
  tip=$(github_toon_scalar "$raw" tip)
  fm_pr_head_valid "$tip" || return 1
  FM_PR_GITHUB_DEFAULT_TIP=$tip
}

github_refuse_unreadable_default_tip() {
  printf 'error: refusing to merge %s because the current tip of default branch %s could not be read, and an unread tip does not prove the merge would execute against the base this run judged\n' \
    "$URL" "$FM_PR_GITHUB_DEFAULT" >&2
  printf 'action: re-run validation once the forge is readable\n' >&2
}

# THE LANDED-MERGE VERDICT'S FIRST OBSERVATION POINT, and the two preconditions
# that must be settled before anything is armed.
#
# Every landed observation this run makes, wherever it is made, is carried in
# github_landed_observed. The preflight target read can be the first of them - a
# retry, or a pull request someone merged by hand - and discarding that
# observation would let a later transient read failure exit non-zero on a merge
# this run already knew had landed.
#
# THE LANDED-MERGE VERDICT answers ONE question: did our merge land? The forge's
# own word settles it, so every path below that reaches a merged reading exits
# zero. It is NOT the merge-target contract evaluated here, which answers whether
# this was a permitted target at all. That one is a precondition and can refuse a
# pull request the forge reports MERGED - merged into a branch guarded merging
# may not touch - which is why the verdict is only ever reached after the
# contract permitted, and why the two must not be reconciled into a single "the
# forge says merged, so we are done" rule.
github_landed_observed=false
github_judged_default_tip=
if [ "$PROVIDER" = github ]; then
  github_assert_default_target || exit 1
  [ "$FM_PR_GITHUB_MERGED" != true ] || github_landed_observed=true
  # A merge already landed has no base left to judge: the mutation this baseline
  # exists to bound has happened, and refusing on a tip read would exit non-zero
  # on a merge this run has just observed. Narrow on purpose, exactly as the
  # target contract's unread-target exception is.
  if [ "$github_landed_observed" != true ]; then
    github_read_default_tip || { github_refuse_unreadable_default_tip; exit 1; }
    github_judged_default_tip=$FM_PR_GITHUB_DEFAULT_TIP
  fi
fi

record_pr_metadata || exit 1

case "$PROVIDER" in
  github)
    merge_output=
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    if caller_requested_auto_merge "$@"; then
      FM_PR_GITHUB_AUTO_REQUESTED=true
    fi
    FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "$@")
    # THE DEFAULT TIP IS RE-READ IMMEDIATELY BEFORE THE MERGE CALL, and the merge
    # is refused if it moved. Refusing deferred execution is only half of the
    # immediate-execution guarantee; the other half is that the base was compared
    # AT MERGE TIME, so what lands is a merge onto the state this run judged
    # rather than onto whatever the branch happens to be by the time the forge
    # acts. The interval this closes is real work, not a formality: the metadata
    # recording between the two reads talks to the forge itself.
    #
    # THE RESIDUAL WINDOW IS DECLARED RATHER THAN PAPERED OVER. `gh-axi pr merge`
    # exposes no expected-base parameter (observed at gh-axi 0.1.34, like every
    # other fact recorded here about that tool), so nothing can make the forge
    # itself reject a merge whose base moved. Between this read returning and the
    # merge landing there remains a sub-second window in which the default branch
    # can still move, and this check NARROWS that window to two back-to-back
    # calls rather than closing it. Closing it needs a forge-side expected-base,
    # which is what the deferred synchronous REST merge boundary would carry.
    #
    # GITHUB ONLY, and stated so rather than implied: GitLab binds its own merge
    # to the head it verified through --sha and reads every pre-merge condition
    # live, and extending this contract there is deferred with the rest of the
    # GitLab target work (HelloWorldSungin/firstmate#257).
    if [ "$github_landed_observed" != true ]; then
      if ! github_read_default_tip; then
        github_refuse_unreadable_default_tip
        exit 1
      fi
      if [ "$FM_PR_GITHUB_DEFAULT_TIP" != "$github_judged_default_tip" ]; then
        printf 'error: refusing to merge %s because default branch %s moved from tip %s, which this run judged, to tip %s before the merge could execute\n' \
          "$URL" "$FM_PR_GITHUB_DEFAULT" "$github_judged_default_tip" \
          "$FM_PR_GITHUB_DEFAULT_TIP" >&2
        printf 'action: bring the branch up to current %s and re-run validation\n' \
          "$FM_PR_GITHUB_DEFAULT" >&2
        exit 1
      fi
    fi
    if merge_output=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
      "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>&1); then
      FM_PR_GITHUB_MERGE_ACCEPTED=true
    else
      merge_status=$?
      [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
      if [ "$github_landed_observed" = true ] || github_read_outcome; then
        if [ "$FM_PR_GITHUB_MERGED" = true ]; then
          # The forge state is the authority, not the command status. A merge the
          # forge confirms LANDED is not a failed merge just because the command
          # reporting it failed, so this falls through to outcome reporting
          # instead of exiting non-zero and leaving the landed merge unrecorded.
          report_landed_after_failed_command \
            "state=$FM_PR_GITHUB_STATE, merged=$FM_PR_GITHUB_MERGED, isInMergeQueue=$FM_PR_GITHUB_QUEUED"
          github_landed_observed=true
        elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
          printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
            "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
        else
          github_report_unmerged_outcome
        fi
      fi
      [ "$github_landed_observed" = true ] || exit "$merge_status"
    fi
    # A landed merge this run has ALREADY OBSERVED must not be re-read, whether
    # the preflight target read or the post-failure read is what observed it.
    # Asking the forge a second time can fail transiently - a rate limit, a 5xx,
    # a token blip between two back-to-back calls - and exiting on that would
    # strand a merge that is already on the default branch with nothing recording
    # it, which is the invariant this script asserts positively.
    if [ "$github_landed_observed" != true ] \
      && ! github_read_outcome; then
      github_report_forge_output "$merge_output"
      exit 1
    fi
    if [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
    elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      exit 0
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
    # Before the command status was captured, set -e guaranteed the merge command
    # had succeeded whenever this ran, so "accepted the merge request" was always
    # true. It is not any more, and a confirm that claims acceptance on a failed
    # command contradicts the refusal printed immediately after it.
    gitlab_confirm_rc=0
    if [ "$gitlab_merge_rc" -ne 0 ]; then
      FM_PR_GITLAB_ACCEPTANCE='rejected the merge command'
    fi
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    if [ "$gitlab_confirm_rc" -ne 0 ] && [ "$gitlab_merge_rc" -ne 0 ]; then
      printf 'error: refusing to treat %s as merged because the merge command failed and the forge does not confirm it landed; the merge poll remains armed\n' \
        "$URL" >&2
      printf 'action: bring the branch up to the current default branch and re-run validation\n' >&2
      exit 1
    fi
    if [ "$gitlab_merge_rc" -ne 0 ] && [ "$gitlab_confirm_rc" -eq 0 ]; then
      report_landed_after_failed_command 'state=merged'
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
