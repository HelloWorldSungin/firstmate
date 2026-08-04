#!/usr/bin/env bash
# Tracker WRITE-BACK for a task's work item: one living status comment, owned by
# firstmate and edited in place.
#
# Usage: fm-issue-comment.sh status <task-id> --milestone <token>
#                                             [--note <text> | --note-file <path>]
#                                             [--dry-run]
#
# Read-side lookups belong to bin/fm-issue-status.sh and reference identity to
# bin/fm-issue-lib.sh; this script is the single owner of everything firstmate
# WRITES to a tracker. It decides eligibility, renders the comment, and performs
# the create-or-edit, so no other script needs to know a tracker can be written.
#
# ONE comment per work item, never one per milestone. An issue that accumulates
# a machine comment per event is less readable than one with none, and readable
# is the entire point. The comment is located idempotently by the firstmate-owned
# marker in its body, so a restart, a partial failure, or a repeated milestone
# all find and correct the same comment rather than adding another.
#
# Firstmate owns this comment because it is the only party that observes the whole
# lifecycle. The task worker owns exactly one separate thing: its substantive
# delivery summary, which bin/fm-brief.sh requires of it before the PR is ready.
#
# Milestones (fixed vocabulary; the free-text note carries the substance):
#   dispatched implemented validated in-review landed blocked stopped
# bin/fm-spawn.sh, bin/fm-pr-check.sh, and bin/fm-pr-merge.sh post dispatched,
# in-review, and landed themselves, so those three never depend on agent memory.
# The rest are firstmate's to post as the work moves.
#
# SCOPE. Write-back applies only where a write credential genuinely exists: the
# task records exactly one work item, it is a github.com issue, and its repository
# is the one the PR opens against (pr_target= in task metadata, recorded at spawn
# from the brief's PR-target marker). Cross-forge write-back needs a per-host
# write-credential design of its own; config/forge-tokens/ is read-side only, and
# an out-of-scope work item is reported once rather than retargeted.
#
# FAIL OPEN. Write-back is decoration on top of work that already succeeded. An
# unreachable host, a missing or expired credential, a rate limit, a deleted
# issue, or a permissions error prints one "warning:" line on stderr and exits 0,
# exactly as the read-side enricher does, so it can never block or fail dispatch,
# validation, merge, or cleanup. A non-zero exit means the CALLER passed something
# invalid, never that a forge misbehaved. What must not happen is a SILENT
# failure: every non-write is either a warning or a notice on stderr.
#
# CONTENT. A tracker comment is outward-facing. The note is refused outright -
# leaving the previous comment untouched - when it carries a credential, an
# absolute filesystem path, or a value this task's own metadata marks as private
# (its id, its worktree, its project directory, its worker runtime). Content
# safety fails CLOSED because a leak cannot be undone, while transport fails open.
#
# GitHub access goes through `gh api` rather than gh-axi: editing an existing
# comment is a PATCH that gh-axi exposes no subcommand for, and mixing the two
# for one comment's lifecycle would be worse than using the lower-level path for
# all of it. bin/fm-pr-check.sh already reads structured PR data the same way.
# Every call is bounded by FM_ISSUE_COMMENT_TIMEOUT seconds (default 10).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CALL_TIMEOUT=${FM_ISSUE_COMMENT_TIMEOUT:-10}
case "$CALL_TIMEOUT" in
  ''|*[!0-9]*|0) CALL_TIMEOUT=10 ;;
esac

# shellcheck source=bin/fm-issue-lib.sh
. "$SCRIPT_DIR/fm-issue-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# The body marker is a constant, not a task-keyed one: the comment belongs to the
# work item, and a task id has no place in outward-facing text anyway.
MARKER='<!-- firstmate-status-comment -->'
TIMELINE_MARKER='<!-- firstmate-status-timeline -->'
FOOTER='_Posted by firstmate and updated in place as the work moves._'
TIMELINE_MAX=20
TIMELINE_TRIMMED='- (earlier updates trimmed)'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

warn() { printf 'warning: status comment not updated: %s\n' "$1" >&2; }
notice() { printf 'notice: no tracker status comment for this task: %s\n' "$1" >&2; }

milestone_label() {  # <token> -> prints the rendered phase label
  case "$1" in
    dispatched) printf 'dispatched\n' ;;
    implemented) printf 'implementation committed\n' ;;
    validated) printf 'validated\n' ;;
    in-review) printf 'in review\n' ;;
    landed) printf 'landed\n' ;;
    blocked) printf 'blocked\n' ;;
    stopped) printf 'stopped\n' ;;
    *) return 1 ;;
  esac
}

MILESTONE_TOKENS='dispatched implemented validated in-review landed blocked stopped'
# The rendered labels, in the same order, for reading back a published timeline.
MILESTONE_LABELS='dispatched|implementation committed|validated|in review|landed|blocked|stopped'
GH_REASON=

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "${1:-}" = status ] || { usage >&2; exit 1; }
shift

ID=
MILESTONE=
NOTE=
NOTE_SET=0
DRY_RUN=0
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      milestone) MILESTONE=$a ;;
      note) NOTE=$a; NOTE_SET=1 ;;
      note-file)
        [ -f "$a" ] && [ ! -L "$a" ] || { echo "error: --note-file must be a regular file" >&2; exit 1; }
        NOTE=$(cat "$a"); NOTE_SET=1
        ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --milestone) want_value=milestone ;;
    --milestone=*) MILESTONE=${a#--milestone=} ;;
    --note) want_value=note ;;
    --note=*) NOTE=${a#--note=}; NOTE_SET=1 ;;
    --note-file) want_value=note-file ;;
    --note-file=*)
      [ -f "${a#--note-file=}" ] && [ ! -L "${a#--note-file=}" ] \
        || { echo "error: --note-file must be a regular file" >&2; exit 1; }
      NOTE=$(cat "${a#--note-file=}"); NOTE_SET=1
      ;;
    --dry-run) DRY_RUN=1 ;;
    --*) echo "error: unknown option $a" >&2; exit 1 ;;
    *)
      [ -z "$ID" ] || { echo "error: exactly one task id is accepted" >&2; exit 1; }
      ID=$a
      ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ -n "$ID" ] || { echo "error: a task id is required" >&2; exit 1; }
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id" >&2; exit 1; }
[ -n "$MILESTONE" ] || { echo "error: --milestone is required (one of: $MILESTONE_TOKENS)" >&2; exit 1; }
LABEL=$(milestone_label "$MILESTONE") \
  || { echo "error: --milestone must be one of: $MILESTONE_TOKENS (got '$MILESTONE')" >&2; exit 1; }

# --- task metadata: eligibility and the private values a comment may never carry

META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  warn "task metadata is unavailable"
  exit 0
fi

meta_values() {  # <key> -> one line per occurrence
  grep "^$1=" "$META" 2>/dev/null | cut -d= -f2- || true
}

meta_one() {  # <key> -> the single value, or empty when absent or repeated
  local values count
  values=$(meta_values "$1")
  [ -n "$values" ] || return 0
  count=$(printf '%s\n' "$values" | wc -l)
  [ "$count" -eq 1 ] || return 0
  printf '%s\n' "$values"
}

WORK_ITEMS=$(meta_values work_item)
if [ -z "$WORK_ITEMS" ]; then
  # A task with no work item has nothing to write back to. That is the ordinary
  # case for most tasks, so it is silent rather than a notice.
  exit 0
fi
if [ "$(printf '%s\n' "$WORK_ITEMS" | wc -l)" -ne 1 ]; then
  notice "the task records several work items, so none of them owns the status comment"
  exit 0
fi
if ! fm_issue_work_item_parse "$WORK_ITEMS"; then
  warn "the recorded work item is malformed"
  exit 0
fi
ISSUE_URL=$FM_ISSUE_URL
ISSUE_PATH=$FM_ISSUE_PATH
ISSUE_NUMBER=$FM_ISSUE_NUMBER
if [ "$FM_ISSUE_FORGE" != github ] || [ "$FM_ISSUE_HOST" != github.com ]; then
  notice "the work item lives on $FM_ISSUE_FORGE host $FM_ISSUE_HOST ($ISSUE_URL), where firstmate holds no write credential"
  exit 0
fi

PR_TARGET=$(meta_one pr_target)
if [ -z "$PR_TARGET" ]; then
  notice "the task records no PR target, so firstmate cannot tell whether it may write to $ISSUE_URL"
  exit 0
fi
if ! fm_issue_tracker_parse "$PR_TARGET"; then
  warn "the recorded PR target is malformed"
  exit 0
fi
if [ "$FM_ISSUE_TRACKER_FORGE" != github ] || [ "$FM_ISSUE_TRACKER_HOST" != github.com ] \
  || [ "$FM_ISSUE_TRACKER_PATH" != "$ISSUE_PATH" ]; then
  notice "$ISSUE_URL is not in the repository this task's PR opens against, so firstmate holds no write credential for it"
  exit 0
fi

# --- the note: outward-facing content, checked before anything is written -----

# Values this task's own metadata marks as fleet-private. Checked as exact
# substrings, which is precise: they come from the record rather than a guess.
PRIVATE_VALUES=("$ID")
for key in worktree project tasktmp harness; do
  value=$(meta_one "$key")
  [ -z "$value" ] || PRIVATE_VALUES+=("$value")
done
PRIVATE_VALUES+=("$FM_HOME" "$STATE")

if [ "$NOTE_SET" -eq 1 ]; then
  # Control characters would forge structure in the rendered comment; strip them
  # rather than refusing, then check the readable text that remains.
  NOTE=$(printf '%s' "$NOTE" | tr -d '\000-\010\013\014\016-\037\177')
  NOTE=${NOTE%"${NOTE##*[![:space:]]}"}
  if [ "${#NOTE}" -gt 4000 ]; then
    warn "the note is longer than 4000 characters; shorten it to what a reader of the issue needs"
    exit 0
  fi
  for value in "${PRIVATE_VALUES[@]}"; do
    [ -n "$value" ] || continue
    case "$NOTE" in
      *"$value"*)
        warn "the note repeats a private fleet detail recorded in this task's own record; rewrite it as the project outcome"
        exit 0
        ;;
    esac
  done
  if printf '%s' "$NOTE" | grep -Eq '(^|[[:space:]([<"'"'"'])/[A-Za-z0-9._-]+/'; then
    warn "the note contains an absolute filesystem path, which never belongs in a tracker comment"
    exit 0
  fi
  if printf '%s' "$NOTE" | grep -Eq 'gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
    warn "the note looks like it contains a credential"
    exit 0
  fi
fi

# --- rendering ---------------------------------------------------------------

NOW=$(date -u '+%Y-%m-%d %H:%M UTC')

PR_LINE=
PR_URL_VALUE=$(meta_one pr)
if [ -n "$PR_URL_VALUE" ] && fm_pr_url_parse "$PR_URL_VALUE"; then
  PR_LINE="Pull request: $FM_PR_URL"
fi

# Keep only entries this script itself could have written: "- <stamp> - <label>"
# with a known label. Anything else in the timeline block is someone's edit, and
# rewriting it back into a machine-owned list would launder it.
timeline_keep() {  # reads a comment body on stdin
  awk -v marker="$TIMELINE_MARKER" -v trimmed="$TIMELINE_TRIMMED" -v labels="|$MILESTONE_LABELS|" '
    BEGIN { seen = 0 }
    $0 == marker { seen = 1; next }
    seen == 0 { next }
    $0 == trimmed { print; next }
    /^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] UTC - .+$/ {
      label = $0
      sub(/^- [0-9-]+ [0-9:]+ UTC - /, "", label)
      if (index(labels, "|" label "|") > 0) print
    }
  '
}

render_body() {  # <timeline-file>
  printf '%s\n' "$MARKER"
  printf '**Status: %s** - updated %s\n' "$LABEL" "$NOW"
  if [ -n "$NOTE" ]; then
    printf '\n%s\n' "$NOTE"
  fi
  if [ -n "$PR_LINE" ]; then
    printf '\n%s\n' "$PR_LINE"
  fi
  printf '\n%s\n' "$TIMELINE_MARKER"
  cat "$1"
  printf '\n%s\n' "$FOOTER"
}

# Build the new timeline from the entries already published. A repeated milestone
# refreshes its own entry instead of appending a second one, so an issue never
# shows "in review" three times because a poll ran three times.
build_timeline() {  # <existing-body-file> <output-file>
  local kept=() line last trimmed=0
  if [ -n "$1" ] && [ -f "$1" ]; then
    while IFS= read -r line; do
      [ "$line" = "$TIMELINE_TRIMMED" ] && { trimmed=1; continue; }
      kept+=("$line")
    done < <(timeline_keep < "$1")
  fi
  if [ "${#kept[@]}" -gt 0 ]; then
    last=${kept[$((${#kept[@]} - 1))]}
    case "$last" in
      *" - $LABEL") unset 'kept[$((${#kept[@]} - 1))]' ;;
    esac
  fi
  kept+=("- $NOW - $LABEL")
  while [ "${#kept[@]}" -gt "$TIMELINE_MAX" ]; do
    kept=("${kept[@]:1}")
    trimmed=1
  done
  : > "$2"
  [ "$trimmed" -eq 0 ] || printf '%s\n' "$TIMELINE_TRIMMED" >> "$2"
  printf '%s\n' "${kept[@]}" >> "$2"
}

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-issue-comment.XXXXXX") || {
  warn "could not create a temporary working directory"
  exit 0
}
trap 'rm -rf -- "$WORKDIR"' EXIT

if [ "$DRY_RUN" -eq 1 ]; then
  # Deliberately offline: it renders exactly what a first update would publish,
  # so content can be reviewed without contacting a forge or needing credentials.
  build_timeline '' "$WORKDIR/timeline"
  printf 'target: %s\n' "$ISSUE_URL"
  render_body "$WORKDIR/timeline"
  exit 0
fi

command -v gh >/dev/null 2>&1 || { warn "gh is not installed, so $ISSUE_URL cannot be updated"; exit 0; }

gh_call() {  # <output-file> <args...>
  local out=$1 rc=0
  shift
  fm_run_timed "$CALL_TIMEOUT" gh "$@" > "$out" 2>"$WORKDIR/err" || rc=$?
  case "$rc" in
    0) return 0 ;;
    124|137) GH_REASON="GitHub did not answer within ${CALL_TIMEOUT}s" ;;
    125) GH_REASON="no bounded timeout runner could start, so nothing was sent" ;;
    *) GH_REASON="GitHub rejected the request (the issue may be missing, or the credential may lack write access)" ;;
  esac
  return 1
}

COMMENT_ID=
if gh_call "$WORKDIR/find" api --paginate "repos/$ISSUE_PATH/issues/$ISSUE_NUMBER/comments" \
  --jq "[.[] | select(.body != null and (.body | contains(\"$MARKER\"))) | .id] | first // empty"; then
  # --paginate applies the filter per page, so the first non-empty line is the
  # earliest matching comment: the one this task has been editing all along.
  COMMENT_ID=$(awk 'NF { print; exit }' "$WORKDIR/find")
else
  warn "could not look up the status comment on $ISSUE_URL: $GH_REASON"
  exit 0
fi
case "$COMMENT_ID" in
  ''|*[!0-9]*) COMMENT_ID= ;;
esac

: > "$WORKDIR/existing"
if [ -n "$COMMENT_ID" ]; then
  if ! gh_call "$WORKDIR/existing" api "repos/$ISSUE_PATH/issues/comments/$COMMENT_ID" --jq '.body'; then
    warn "could not read the existing status comment on $ISSUE_URL: $GH_REASON"
    exit 0
  fi
fi

build_timeline "$WORKDIR/existing" "$WORKDIR/timeline"
render_body "$WORKDIR/timeline" > "$WORKDIR/body"

if [ -n "$COMMENT_ID" ]; then
  if gh_call "$WORKDIR/response" api --method PATCH \
    "repos/$ISSUE_PATH/issues/comments/$COMMENT_ID" -F 'body=@-' < "$WORKDIR/body"; then
    printf 'updated: %s\n' "$ISSUE_URL"
    exit 0
  fi
  warn "could not update the status comment on $ISSUE_URL: $GH_REASON"
  exit 0
fi

if gh_call "$WORKDIR/response" api --method POST \
  "repos/$ISSUE_PATH/issues/$ISSUE_NUMBER/comments" -F 'body=@-' < "$WORKDIR/body"; then
  printf 'created: %s\n' "$ISSUE_URL"
  exit 0
fi
warn "could not post the status comment on $ISSUE_URL: $GH_REASON"
exit 0
