#!/usr/bin/env bash
# Deliberate transition for live no-mistakes task records written before
# state/<id>.meta carried the authoritative `branch=` identity.
#
# The default locked-bootstrap path attempts one narrow migration.
# A legacy record gains `branch=` only when all of these durable and remote
# facts agree without consulting the worktree's ambient branch:
#   - the record identifies one live no-mistakes ship;
#   - it carries exactly one canonical GitHub `pr=` URL and one valid
#     `pr_head=` SHA, both written by bin/fm-pr-check.sh for that task;
#   - GitHub currently reports that same SHA as the recorded PR's head; and
#   - the head branch returned in that same response is a valid Git branch.
# The recorded task-to-PR binding plus the matching recorded/current PR head is
# independent evidence of the branch identity.
#
# No other candidate is migrated.
# In particular, the worktree's current branch, an fm/<task-id> naming match, a
# no-mistakes run's branch, and a work item do not independently bind a branch
# to this task.
# Pre-transition briefs contain no firstmate-task-branch marker, so they cannot
# supply the proof that current fm-spawn records at launch.
#
# After any migration attempt, every remaining live no-mistakes ship without a
# usable branch emits one RUN_ATTRIBUTION line.
# The diagnostic is also emitted in --detect-only mode without any migration,
# so a lock-refused session still names the tasks whose run state is unreadable.
# Missing worktrees, scouts, direct-PR tasks, local-only tasks, and records that
# already carry a non-empty branch stay silent.
#
# The GitHub proof lookup is bounded per candidate by
# FM_RUN_ATTRIBUTION_MIGRATION_TIMEOUT (10 seconds by default).
# A failed or unavailable lookup leaves the record unchanged and lets the
# diagnostic expose the accepted legacy cost.
# Metadata publication is atomic and refuses a concurrent record change.
#
# Usage: fm-run-attribution-legacy-transition.sh [--detect-only]
# Lines:
#   BOOTSTRAP_INFO: run attribution transition: task <id> recorded branch <branch> from matching GitHub PR head
#   RUN_ATTRIBUTION: task <id>: legacy no-mistakes metadata has no proven branch=; any run is unattributable until task cleanup
# Always exits 0 after valid invocation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DETECT_ONLY=0
if [ "$#" -eq 1 ] && [ "$1" = --detect-only ]; then
  DETECT_ONLY=1
elif [ "$#" -ne 0 ]; then
  echo "usage: fm-run-attribution-legacy-transition.sh [--detect-only]" >&2
  exit 2
fi

LOOKUP_TIMEOUT=${FM_RUN_ATTRIBUTION_MIGRATION_TIMEOUT:-10}
case "$LOOKUP_TIMEOUT" in ''|*[!0-9]*) LOOKUP_TIMEOUT=10 ;; esac
[ "$LOOKUP_TIMEOUT" -ge 1 ] || LOOKUP_TIMEOUT=10

meta_exact_value() {  # <meta> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  value=$(grep "^$key=" "$meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

record_is_legacy_live_no_mistakes_ship() {  # <meta>
  local meta=$1 kind mode worktree branch
  kind=$(meta_exact_value "$meta" kind 2>/dev/null) || return 1
  mode=$(meta_exact_value "$meta" mode 2>/dev/null) || return 1
  worktree=$(meta_exact_value "$meta" worktree 2>/dev/null) || return 1
  [ "$kind" = ship ] && [ "$mode" = no-mistakes ] && [ -d "$worktree" ] || return 1
  branch=$(meta_exact_value "$meta" branch 2>/dev/null || true)
  [ -z "$branch" ]
}

lookup_github_pr_head() {  # <project-path> <number>
  local project=$1 number=$2
  command -v gh >/dev/null 2>&1 || return 1
  fm_run_timed "$LOOKUP_TIMEOUT" gh api "repos/$project/pulls/$number" \
    --jq '[.head.ref, .head.sha] | @tsv' 2>/dev/null
}

publish_branch() {  # <meta> <snapshot> <branch>
  local meta=$1 snapshot=$2 branch=$3 tmp
  tmp=$(mktemp "$meta.transition.XXXXXX") || return 1
  {
    cat -- "$snapshot" && printf 'branch=%s\n' "$branch"
  } > "$tmp" 2>/dev/null || {
    rm -f -- "$tmp"
    return 1
  }
  [ "$(grep -c '^branch=' "$tmp" 2>/dev/null || true)" = 1 ] || {
    rm -f -- "$tmp"
    return 1
  }
  [ "$(meta_exact_value "$tmp" branch 2>/dev/null || true)" = "$branch" ] || {
    rm -f -- "$tmp"
    return 1
  }
  chmod 600 -- "$tmp" 2>/dev/null || true
  cmp -s -- "$snapshot" "$meta" || {
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$meta" || {
    rm -f -- "$tmp"
    return 1
  }
}

attempt_pr_proven_migration() {  # <meta> <id>
  local meta=$1 id=$2 pr recorded_head snapshot response branch remote_head extra
  [ "$DETECT_ONLY" = 0 ] || return 1
  [ "$(grep -c '^branch=' "$meta" 2>/dev/null || true)" = 0 ] || return 1
  pr=$(meta_exact_value "$meta" pr 2>/dev/null) || return 1
  recorded_head=$(meta_exact_value "$meta" pr_head 2>/dev/null) || return 1
  fm_pr_head_valid "$recorded_head" || return 1
  fm_pr_url_parse "$pr" || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1

  snapshot=$(mktemp "$meta.source.XXXXXX") || return 1
  if ! cat -- "$meta" > "$snapshot" 2>/dev/null; then
    rm -f -- "$snapshot"
    return 1
  fi
  response=$(lookup_github_pr_head "$FM_PR_PATH" "$FM_PR_NUMBER") || {
    rm -f -- "$snapshot"
    return 1
  }
  case "$response" in *$'\n'*) rm -f -- "$snapshot"; return 1 ;; esac
  IFS=$'\t' read -r branch remote_head extra <<< "$response"
  if [ -z "$branch" ] || [ -z "$remote_head" ] || [ -n "${extra:-}" ] \
    || [ "$remote_head" != "$recorded_head" ] \
    || ! git check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || ! publish_branch "$meta" "$snapshot" "$branch"; then
    rm -f -- "$snapshot"
    return 1
  fi
  rm -f -- "$snapshot"
  printf 'BOOTSTRAP_INFO: run attribution transition: task %s recorded branch %s from matching GitHub PR head\n' \
    "$id" "$branch"
  return 0
}

[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename -- "$meta" .meta)
  fm_pr_task_id_valid "$id" || continue
  record_is_legacy_live_no_mistakes_ship "$meta" || continue
  attempt_pr_proven_migration "$meta" "$id" && continue
  printf 'RUN_ATTRIBUTION: task %s: legacy no-mistakes metadata has no proven branch=; any run is unattributable until task cleanup\n' \
    "$id"
done

exit 0
