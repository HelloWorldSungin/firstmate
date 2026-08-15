#!/usr/bin/env bash
# Resolve work-item references against a project's declared issue tracker.
#
# Firstmate runs this at intake, the same way it resolves a task's delivery mode
# and yolo posture: the answer is decided once, against the project, and then
# passed explicitly to bin/fm-brief.sh and bin/fm-spawn.sh, which never guess.
#
# Usage: fm-issue-ref.sh --project <name> [--format meta|url|json] <ref>...
#        fm-issue-ref.sh --project <name> --show-tracker
#
#   <ref> is a full issue URL, a "<forge>:<url>" prefixed URL, "<owner>/<repo>#<n>",
#   "#<n>", or "<n>". bin/fm-issue-lib.sh owns the accepted forms, the registry
#   tracker declaration they resolve against, and every refusal reason.
#
#   --format meta (default) prints "work_item=<origin>|<forge>|<url>" lines ready
#   to record in task metadata; brief prints "<forge>:<url>" arguments to pass
#   straight to bin/fm-brief.sh --work-item; url prints canonical URLs; json
#   prints the array of reference objects issue #18's outcome manifest carries.
#
#   --show-tracker prints the project's raw tracker declaration and exits 0, or
#   explains that the project declares none and exits 3. It answers with a
#   declaration rather than a reference, so it takes neither a <ref> nor a
#   --format and refuses either as a usage error.
#
# Several references may be passed and none is also valid: with no <ref> the
# command succeeds and prints nothing, which is how a task with no work item is
# represented. Any single unresolvable reference fails the whole call with its
# reason on stderr, so a partially-resolved set is never recorded.
#
# Exit codes: 0 resolved (or nothing to resolve); 1 usage error; 2 a reference
# could not be resolved; 3 --show-tracker found no declaration.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/projects.md"

# shellcheck source=bin/fm-issue-lib.sh
. "$SCRIPT_DIR/fm-issue-lib.sh"
# shellcheck source=bin/fm-brief-repo-lib.sh
. "$SCRIPT_DIR/fm-brief-repo-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

PROJECT=
FORMAT=meta
FORMAT_SET=0
SHOW_TRACKER=0
REFS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      project) PROJECT=$a ;;
      format) FORMAT=$a; FORMAT_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --project) want_value=project ;;
    --project=*) PROJECT=${a#--project=} ;;
    --format) want_value=format ;;
    --format=*) FORMAT=${a#--format=}; FORMAT_SET=1 ;;
    --show-tracker) SHOW_TRACKER=1 ;;
    --*) echo "error: unknown option $a" >&2; exit 1 ;;
    *) REFS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

[ -n "$PROJECT" ] || { echo "error: --project <name> is required; a reference is meaningless without the project it resolves against" >&2; exit 1; }
# Resolve a path-style project identifier to a registry name. The home root
# is the firstmate repo's checkout, so a path that matches the home root
# resolves to the firstmate repo's registry entry rather than reading as
# an unknown name. issue #104: this is the structural complement to the
# prose-based detection fm_brief_repo_registers_home_root_clone used to
# derive from registry entries.
PROJECT=$(fm_brief_repo_resolve_project_name "$PROJECT")
case "$FORMAT" in
  meta|brief|url|json) ;;
  *) echo "error: --format must be one of meta, brief, url, json (got '$FORMAT')" >&2; exit 1 ;;
esac

# An unreadable or malformed declaration must never read as "undeclared":
# undeclared refuses a bare reference with an actionable reason, while a typo'd
# declaration is a registry bug the captain has to see. On that path the library
# prints the detail phrase, so the refusal can point at the offending token.
TRACKER=
tracker_rc=0
TRACKER=$(fm_issue_registry_tracker "$REGISTRY" "$PROJECT") || tracker_rc=$?
case "$tracker_rc" in
  0) ;;
  1) TRACKER= ;;
  *)
    echo "error: project \"$PROJECT\" has a malformed tracker declaration in $REGISTRY${TRACKER:+: $TRACKER}" >&2
    exit 2
    ;;
esac

if [ "$SHOW_TRACKER" -eq 1 ]; then
  [ "${#REFS[@]}" -eq 0 ] || { echo "error: --show-tracker takes no references" >&2; exit 1; }
  # --show-tracker answers with the raw declaration, which is not a reference
  # and has no representation in any --format shape. Refusing the combination
  # keeps every --format json call a parseable document; quietly printing a bare
  # declaration to a caller that asked for json would not.
  [ "$FORMAT_SET" -eq 0 ] \
    || { echo "error: --show-tracker prints the raw tracker declaration and takes no --format" >&2; exit 1; }
  if [ -z "$TRACKER" ]; then
    echo "project \"$PROJECT\" declares no issue tracker in $REGISTRY" >&2
    exit 3
  fi
  printf '%s\n' "$TRACKER"
  exit 0
fi

if [ "${#REFS[@]}" -eq 0 ]; then
  # A task with no work items is a first-class case. The line-oriented formats
  # say that with no lines; json must still emit a document a consumer can
  # parse, so it emits the empty array rather than nothing at all.
  [ "$FORMAT" != json ] || printf '[]\n'
  exit 0
fi

records=()
for ref in "${REFS[@]}"; do
  if ! fm_issue_ref_resolve "$ref" "$TRACKER" "$PROJECT"; then
    echo "error: $FM_ISSUE_ERROR" >&2
    exit 2
  fi
  # bin/fm-issue-lib.sh owns the record format; build it there, never here.
  records+=("$(fm_issue_work_item_format "$FM_ISSUE_ORIGIN" "$FM_ISSUE_FORGE" "$FM_ISSUE_URL")")
done

case "$FORMAT" in
  meta)
    for record in "${records[@]}"; do
      printf 'work_item=%s\n' "$record"
    done
    ;;
  brief)
    for record in "${records[@]}"; do
      fm_issue_work_item_parse "$record" || { echo "error: could not re-derive $record" >&2; exit 2; }
      printf '%s:%s\n' "$FM_ISSUE_FORGE" "$FM_ISSUE_URL"
    done
    ;;
  url)
    for record in "${records[@]}"; do
      fm_issue_work_item_parse "$record" || { echo "error: could not re-derive $record" >&2; exit 2; }
      printf '%s\n' "$FM_ISSUE_URL"
    done
    ;;
  json)
    # Every field was validated into a charset with no JSON metacharacters, so
    # the emitted document needs no escaping pass to stay well formed.
    printf '[\n'
    sep=
    for record in "${records[@]}"; do
      fm_issue_work_item_parse "$record" || { echo "error: could not re-derive $record" >&2; exit 2; }
      printf '%s' "$sep"
      printf '  {"url": "%s", "forge": "%s", "host": "%s", "path": "%s", ' \
        "$FM_ISSUE_URL" "$FM_ISSUE_FORGE" "$FM_ISSUE_HOST" "$FM_ISSUE_PATH"
      if [ -n "$FM_ISSUE_OWNER" ]; then
        printf '"owner": "%s", "repo": "%s", ' "$FM_ISSUE_OWNER" "$FM_ISSUE_REPO"
      else
        printf '"owner": null, "repo": null, '
      fi
      printf '"number": %s, "origin": "%s"}' "$FM_ISSUE_NUMBER" "$FM_ISSUE_ORIGIN"
      sep=',
'
    done
    printf '\n]\n'
    ;;
esac
