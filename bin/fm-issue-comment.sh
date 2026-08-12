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
# Milestones come from bin/fm-milestone-lib.sh, which is the single owner of the
# vocabulary every write-back surface shares; the free-text note carries the
# substance. bin/fm-spawn.sh, bin/fm-pr-check.sh, and bin/fm-pr-merge.sh post
# dispatched, in-review, and landed themselves, so those three never depend on
# agent memory. The rest are firstmate's to post as the work moves.
#
# SCOPE. The target is only ever the task's own recorded work item: exactly one
# work_item= line, in the repository the PR opens against (pr_target= in task
# metadata, recorded at spawn from the brief's PR-target marker), never a
# reference parsed from prose, a PR body, or a git remote. Within that scope,
# write-back is per-forge through bin/fm-forge-lib.sh, the single owner of the
# per-host credential rules, the argv-free transport, the write-operation
# allowlist, and the minimum viable token scope per forge:
#   github.com  the ambient gh authentication, as everywhere else in this repo.
#   gitea       config/forge-tokens/<host>, the same credential the read side
#               uses; an absent token is reported as "no write credential", a
#               present but empty one as the empty file it is, a loose one is
#               refused, and a 401/403 is reported as the forge refusing the
#               credential - four different facts, never blurred into one.
#   gitlab and self-hosted GitHub have no write adapter yet and say so.
# An out-of-scope or unsupported work item is reported once rather than
# retargeted, and the recorded link always stays resolvable.
#
# NEVER CREATE ON A GUESS. Creating is the one act here that cannot be taken
# back: a second status comment can never be edited into the first. So a create
# happens only where the lookup PROVED there is nothing to edit - it reached the
# end of the comment list without finding the marker. Every other way the lookup
# can end is the same epistemic state, "could not prove absence", and every one
# of them takes the same branch: warn and write nothing. That covers the page cap
# running out, a host that re-serves a page it already served, a page carrying no
# readable comment id, and a comment found under an id that cannot be addressed.
# Refusing costs one milestone on one comment; guessing costs a tracker that
# accumulates a comment per milestone, which is what this design exists to
# prevent. This rule governs both forge paths below, not just the one whose
# server shape suggested it.
#
# FAIL OPEN. Write-back is decoration on top of work that already succeeded. An
# unreachable host, a missing or expired credential, a rate limit, a deleted
# issue, or a permissions error prints one "warning:" line on stderr and exits 0,
# exactly as the read-side enricher does, so it can never block or fail dispatch,
# validation, merge, or cleanup. A non-zero exit means the CALLER passed something
# invalid, never that a forge misbehaved. What must not happen is a SILENT
# failure: every non-write is either a warning or a notice on stderr.
#
# CONTENT. A tracker comment is outward-facing. The note is WITHHELD when it
# carries a firstmate marker, a credential, an absolute filesystem path, or a
# value this task's own metadata marks as private (its id, its worktree, its
# project directory, its worker runtime). Content safety fails CLOSED because a
# leak cannot be undone, while transport fails open - but withholding is not
# losing: the milestone still lands without the note and stderr says what was
# withheld and why, so a false positive costs a sentence rather than the update.
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
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
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
# shellcheck source=bin/fm-milestone-lib.sh
. "$SCRIPT_DIR/fm-milestone-lib.sh"
# shellcheck source=bin/fm-forge-lib.sh
. "$SCRIPT_DIR/fm-forge-lib.sh"

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
# A withheld note is not a withheld milestone: the update still lands, so this
# says what was dropped rather than reporting the whole write-back as skipped.
withheld() { printf 'warning: the note was withheld and the milestone recorded without it: %s\n' "$1" >&2; }
# A comment that was found but cannot be addressed is not an absent one; see the
# never-create-on-a-guess rule in the header.
refuse_unaddressable_comment() {
  warn "$ISSUE_URL already carries firstmate's status comment but $ISSUE_HOST reported it under an id that is not a number, so nothing was written rather than risk a second comment"
  exit 0
}

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
[ -n "$MILESTONE" ] || { echo "error: --milestone is required (one of: $FM_MILESTONE_TOKENS)" >&2; exit 1; }
LABEL=$(fm_milestone_label "$MILESTONE") \
  || { echo "error: --milestone must be one of: $FM_MILESTONE_TOKENS (got '$MILESTONE')" >&2; exit 1; }

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
ISSUE_FORGE=$FM_ISSUE_FORGE
ISSUE_HOST=$FM_ISSUE_HOST
ISSUE_PATH=$FM_ISSUE_PATH
ISSUE_NUMBER=$FM_ISSUE_NUMBER
if ! fm_forge_write_supported "$ISSUE_FORGE" "$ISSUE_HOST"; then
  notice "$FM_FORGE_REASON, so $ISSUE_URL keeps its link without a status comment"
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
if [ "$FM_ISSUE_TRACKER_FORGE" != "$ISSUE_FORGE" ] || [ "$FM_ISSUE_TRACKER_HOST" != "$ISSUE_HOST" ] \
  || [ "$FM_ISSUE_TRACKER_PATH" != "$ISSUE_PATH" ]; then
  notice "$ISSUE_URL is not in the repository this task's PR opens against, so it is outside this task's write-back scope"
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

# Anchored on the roots a real filesystem path actually starts at, so a project's
# own route (/api/v2/reports) and a relative-root markdown link ([docs](/docs/x))
# read as the project prose they are, while /home/..., ~/..., and C:\... stay
# refused. Narrowing what counts as a path is safe here precisely because a hit
# no longer costs the milestone.
PRIVATE_PATH_ROOTS='home|Users|root|tmp|var|etc|opt|usr|srv|mnt|media|private|proc|sys|dev|run|boot|bin|sbin|lib|lib64|Volumes|System|Library|Applications'
PRIVATE_PATH_RE="(^|[[:space:]([<\"'])(~/|/($PRIVATE_PATH_ROOTS)/|[A-Za-z]:\\\\)"
CREDENTIAL_RE='gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

if [ "$NOTE_SET" -eq 1 ]; then
  # Control characters would forge structure in the rendered comment; strip them
  # rather than refusing, then check the readable text that remains.
  NOTE=$(printf '%s' "$NOTE" | tr -d '\000-\010\013\014\016-\037\177')
  NOTE=${NOTE%"${NOTE##*[![:space:]]}"}
  NOTE_REFUSAL=
  if [ "${#NOTE}" -gt 4000 ]; then
    NOTE_REFUSAL='it is longer than 4000 characters, which is more than a reader of the issue needs'
  fi
  if [ -z "$NOTE_REFUSAL" ]; then
    for value in "${PRIVATE_VALUES[@]}"; do
      [ -n "$value" ] || continue
      case "$NOTE" in
        *"$value"*)
          NOTE_REFUSAL="it repeats a private fleet detail recorded in this task's own record; rewrite it as the project outcome"
          break
          ;;
      esac
    done
  fi
  if [ -z "$NOTE_REFUSAL" ]; then
    # A note carrying firstmate's own marker prefix could forge an entry into the
    # machine-owned timeline, where a fabricated line would then survive every
    # later edit. That timeline is the artifact this surface exists to make
    # trustworthy, so nothing able to write into it is ever published.
    case "$NOTE" in
      *'<!-- firstmate-'*)
        NOTE_REFUSAL='it carries a firstmate marker, which would forge entries into the machine-owned timeline'
        ;;
    esac
  fi
  if [ -z "$NOTE_REFUSAL" ] && printf '%s' "$NOTE" | grep -Eq "$PRIVATE_PATH_RE"; then
    NOTE_REFUSAL='it names an absolute filesystem path, which never belongs in a tracker comment'
  fi
  if [ -z "$NOTE_REFUSAL" ] && printf '%s' "$NOTE" | grep -Eq "$CREDENTIAL_RE"; then
    NOTE_REFUSAL='it looks like it contains a credential'
  fi
  if [ -n "$NOTE_REFUSAL" ]; then
    # The note goes, the milestone stays. A false positive then costs one
    # sentence and a true positive still leaks nothing, whereas dropping the
    # whole update would let the tracker quietly stop being true.
    NOTE=
    NOTE_SET=0
    withheld "$NOTE_REFUSAL"
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
  awk -v marker="$TIMELINE_MARKER" -v trimmed="$TIMELINE_TRIMMED" -v labels="|$FM_MILESTONE_LABELS|" '
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
# The caller bounds this whole script (bin/fm-work-item-milestone.sh), so being
# terminated mid-call is an ordinary outcome rather than a crash, and it must not
# leave a working directory behind each time it happens.
trap 'rm -rf -- "$WORKDIR"; trap - EXIT; exit 143' HUP INT TERM

if [ "$DRY_RUN" -eq 1 ]; then
  # Deliberately offline: it renders exactly what a first update would publish,
  # so content can be reviewed without contacting a forge or needing credentials.
  build_timeline '' "$WORKDIR/timeline"
  printf 'target: %s\n' "$ISSUE_URL"
  render_body "$WORKDIR/timeline"
  exit 0
fi

# --- gitea: the same lifecycle through the per-host credential ---------------
#
# The operations come from bin/fm-forge-lib.sh's write allowlist, bounded per
# call exactly as gh_call bounds the GitHub side. Writing needs authentication,
# so a token that is absent, or present but empty, ends the write here - unlike
# the read side, which falls back to an unauthenticated public read. Those two
# are separate facts and are reported as separate facts: "there is no file" and
# "the file is right there and holds nothing" send the captain to different
# places, so neither may be worded as the other.
if [ "$ISSUE_FORGE" = gitea ]; then
  command -v curl >/dev/null 2>&1 || { warn "curl is not installed, so $ISSUE_URL cannot be updated"; exit 0; }
  command -v jq >/dev/null 2>&1 || { warn "jq is not installed, so $ISSUE_URL cannot be updated"; exit 0; }
  TOKEN=
  token_rc=0
  TOKEN=$(fm_forge_token_read "$CONFIG" "$ISSUE_HOST") || token_rc=$?
  case "$token_rc" in
    0) ;;
    2)
      warn "refusing the token at config/forge-tokens/$ISSUE_HOST: it must be a regular file with mode 0600"
      exit 0
      ;;
    3)
      notice "firstmate holds no usable write credential for $ISSUE_HOST (config/forge-tokens/$ISSUE_HOST is present but empty), so $ISSUE_URL keeps its link without a status comment"
      exit 0
      ;;
    *)
      notice "firstmate holds no write credential for $ISSUE_HOST (config/forge-tokens/$ISSUE_HOST is absent), so $ISSUE_URL keeps its link without a status comment"
      exit 0
      ;;
  esac
  fm_forge_scratch_set "$WORKDIR"

  gitea_bound() {  # sets BOUND from the shared budget, or reports it spent
    BOUND=$(fm_call_bound "$CALL_TIMEOUT")
    if [ "$BOUND" -le 0 ]; then
      FM_FORGE_REASON="the milestone budget was already spent, so nothing was sent"
      return 1
    fi
  }

  # Find firstmate's own comment by its marker, earliest first, walking pages
  # oldest-first under a hard cap. Exactly two things ANSWER the lookup: the
  # marker is found, or an empty page proves the list is exhausted. A page
  # shorter than the requested limit proves nothing - Gitea clamps every list to
  # its own api.MAX_RESPONSE_ITEMS, so a short page is the normal answer on such
  # an instance - so the walk carries on past it.
  #
  # Everything else that stops the walk records WALK_GAP and reaches the refusal
  # below instead of the create, per the header's never-create-on-a-guess rule.
  # A server that ignores the page parameter and re-serves its first id is the
  # case that makes this matter: it is indistinguishable from a list this lookup
  # cannot see the end of, and treating it as "there is no comment" would post a
  # second one on every milestone. Exhausting the cap is the same state and has
  # always been reported; so is a page whose first entry carries no readable id.
  COMMENT_ID=
  : > "$WORKDIR/existing"
  page=1
  prev_first=
  walk_answered=0
  WALK_GAP=
  while [ "$page" -le 10 ]; do
    if ! gitea_bound \
      || ! fm_gitea_comments_page "$BOUND" "$TOKEN" "$ISSUE_HOST" "$ISSUE_PATH" "$ISSUE_NUMBER" "$page" "$WORKDIR/page"; then
      warn "could not look up the status comment on $ISSUE_URL: $FM_FORGE_REASON"
      exit 0
    fi
    count=$(jq 'length' "$WORKDIR/page" 2>/dev/null) || count=
    case "$count" in
      ''|*[!0-9]*)
        warn "could not read the comment list on $ISSUE_URL"
        exit 0
        ;;
    esac
    if [ "$count" -eq 0 ]; then
      walk_answered=1
      break
    fi
    first=$(jq -r '.[0].id // empty' "$WORKDIR/page" 2>/dev/null) || first=
    if [ -z "$first" ]; then
      WALK_GAP="page $page of its comment list came back with no readable comment id"
      break
    fi
    if [ "$first" = "$prev_first" ]; then
      WALK_GAP="$ISSUE_HOST answered page $page with the same first comment as the page before it, so the walk cannot reach the end of the list"
      break
    fi
    prev_first=$first
    COMMENT_ID=$(jq -r --arg m "$MARKER" \
      '[.[] | select(.body != null and (.body | contains($m))) | .id] | first // empty' \
      "$WORKDIR/page" 2>/dev/null) || COMMENT_ID=
    if [ -n "$COMMENT_ID" ]; then
      jq -r --arg m "$MARKER" \
        '[.[] | select(.body != null and (.body | contains($m))) | .body] | first // empty' \
        "$WORKDIR/page" > "$WORKDIR/existing" 2>/dev/null || : > "$WORKDIR/existing"
      walk_answered=1
      break
    fi
    page=$((page + 1))
  done
  if [ "$walk_answered" -eq 0 ]; then
    [ -n "$WALK_GAP" ] || WALK_GAP="its comment list is longer than the 10 pages this lookup walks"
    warn "could not tell whether $ISSUE_URL already carries firstmate's status comment: $WALK_GAP, so nothing was written rather than risk a second comment"
    exit 0
  fi
  case "$COMMENT_ID" in
    '') ;;
    *[!0-9]*) refuse_unaddressable_comment ;;
  esac

  build_timeline "$WORKDIR/existing" "$WORKDIR/timeline"
  render_body "$WORKDIR/timeline" > "$WORKDIR/body"

  if [ -n "$COMMENT_ID" ]; then
    if gitea_bound \
      && fm_gitea_comment_update "$BOUND" "$TOKEN" "$ISSUE_HOST" "$ISSUE_PATH" "$COMMENT_ID" "$WORKDIR/body"; then
      printf 'updated: %s\n' "$ISSUE_URL"
      exit 0
    fi
    warn "could not update the status comment on $ISSUE_URL: $FM_FORGE_REASON"
    exit 0
  fi
  if gitea_bound \
    && fm_gitea_comment_create "$BOUND" "$TOKEN" "$ISSUE_HOST" "$ISSUE_PATH" "$ISSUE_NUMBER" "$WORKDIR/body"; then
    printf 'created: %s\n' "$ISSUE_URL"
    exit 0
  fi
  warn "could not post the status comment on $ISSUE_URL: $FM_FORGE_REASON"
  exit 0
fi

command -v gh >/dev/null 2>&1 || { warn "gh is not installed, so $ISSUE_URL cannot be updated"; exit 0; }

gh_call() {  # <output-file> <args...>
  local out=$1 rc=0 bound
  shift
  # Each call takes the smaller of its own bound and whatever is left of the
  # overall budget a caller set, so this script finishes and reports rather than
  # being killed part-way through by the bound around it.
  bound=$(fm_call_bound "$CALL_TIMEOUT")
  if [ "$bound" -le 0 ]; then
    GH_REASON="the milestone budget was already spent, so nothing was sent"
    return 1
  fi
  fm_run_timed "$bound" gh "$@" > "$out" 2>"$WORKDIR/err" || rc=$?
  case "$rc" in
    0) return 0 ;;
    124|137) GH_REASON="GitHub did not answer within ${bound}s" ;;
    125) GH_REASON="no bounded timeout runner could start, so nothing was sent" ;;
    *) GH_REASON="GitHub rejected the request (the issue may be missing, or the credential may lack write access)" ;;
  esac
  return 1
}

COMMENT_ID=
# per_page=100 rather than GitHub's default 30: the lookup is one bounded call
# however many pages it walks, so a busy issue - exactly the one a reader is most
# likely following - must not spend that bound on round trips and silently stop
# being updated.
if gh_call "$WORKDIR/find" api --paginate "repos/$ISSUE_PATH/issues/$ISSUE_NUMBER/comments?per_page=100" \
  --jq "[.[] | select(.body != null and (.body | contains(\"$MARKER\"))) | .id] | first // empty"; then
  # --paginate applies the filter per page, so the first non-empty line is the
  # earliest matching comment: the one this task has been editing all along.
  COMMENT_ID=$(awk 'NF { print; exit }' "$WORKDIR/find")
else
  warn "could not look up the status comment on $ISSUE_URL: $GH_REASON"
  exit 0
fi
# --paginate walks the whole list, so an empty answer here IS proof of absence
# and may create. An id that is not a number is not: the comment exists and this
# lookup simply cannot address it, which the header's rule sends to the refusal
# rather than to a second comment.
case "$COMMENT_ID" in
  '') ;;
  *[!0-9]*) refuse_unaddressable_comment ;;
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
