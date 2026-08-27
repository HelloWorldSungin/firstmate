#!/usr/bin/env bash
# Report this fork's drift from its optional upstream remote without changing
# this repository.
#
# Usage: fm-upstream-status.sh [--details]
#
# The presence of a git remote named `upstream` is the opt-in.
# Without it the command exits 0 silently.
# When upstream is current it also exits 0 silently.
# When the fork is behind, the default output is one `UPSTREAM:` summary naming
# the first-parent change count, the bin/ and AGENTS.md/skills counts within it,
# and whether the standing trigger was crossed.
# The standing trigger is pending first-parent volume alone: it crosses once the
# fork is behind by at least FM_UPSTREAM_STATUS_THRESHOLD changes (default 50).
# The reported subsystem counts are context for judging urgency once a reader is
# already looking, not trigger conditions; upstream touches its instruction
# surface in most changes, so that signal cannot distinguish a round worth
# dispatching from ordinary upstream activity.
# `--details` adds the measured target and merge base, pending changes grouped
# by their primary subsystem, and paths changed on both sides of the merge base.
# Pull-request references use owner/repo#number rather than an ambiguous bare
# number whenever the upstream commit subject carries a PR number.
#
# The detector never fetches into this repository, updates one of its refs,
# merges, or changes a worktree.
# It fetches the fork and upstream default branches into a disposable bare
# repository whose object store can read this repository's objects as
# alternates, then removes that temporary repository before exiting.
# FM_UPSTREAM_STATUS_TIMEOUT bounds the entire measurement in seconds (default
# 20), including both fetches and all reporting work.
# FM_UPSTREAM_STATUS_THRESHOLD sets the pending-change count at which the
# standing trigger crosses (default 50); a non-positive or non-numeric value
# falls back to the default.
# FM_ROOT_OVERRIDE selects the repository, primarily for bootstrap and tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DETAILS=0
THRESHOLD=${FM_UPSTREAM_STATUS_THRESHOLD:-50}
TIMEOUT=${FM_UPSTREAM_STATUS_TIMEOUT:-20}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  "") ;;
  --details) DETAILS=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "usage: fm-upstream-status.sh [--details]" >&2; exit 2 ;;
esac

case "$TIMEOUT" in
  ''|*[!0-9]*) TIMEOUT=20 ;;
esac
[ "$TIMEOUT" -ge 1 ] || TIMEOUT=20

case "$THRESHOLD" in
  ''|*[!0-9]*) THRESHOLD=50 ;;
esac
[ "$THRESHOLD" -ge 1 ] || THRESHOLD=50

repo_label() {  # <remote-url-or-path>
  local value=$1 path owner repo
  value=${value%/}
  case "$value" in
    *://*)
      path=${value#*://}
      path=${path#*/}
      ;;
    *@*:* ) path=${value#*:} ;;
    *) path=$value ;;
  esac
  path=${path%/}
  repo=${path##*/}
  repo=${repo%.git}
  path=${path%/*}
  owner=${path##*/}
  if [ -n "$owner" ] && [ -n "$repo" ]; then
    printf '%s/%s\n' "$owner" "$repo"
  else
    printf '%s\n' upstream
  fi
}

report_failure() {
  printf 'UPSTREAM: unable to measure %s - %s\n' "${upstream_label:-upstream}" "$1"
  exit 1
}

fetch_default_branch() {  # <url> <destination-ref> <remote-name>
  local url=$1 destination=$2 remote_name=$3 fetch_status=0
  GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" GIT_TERMINAL_PROMPT=0 \
    git --git-dir="$measurement_repo" fetch --quiet \
      --no-tags --no-write-fetch-head -- "$url" "+HEAD:$destination" \
      || fetch_status=$?
  [ "$fetch_status" -eq 0 ] \
    || report_failure "$remote_name fetch failed with exit $fetch_status"
}

render_change() {  # <commit> <subject>
  local commit=$1 subject=$2 pr title
  pr=
  if [[ "$subject" =~ \(\#([0-9]+)\)$ ]]; then
    pr=${BASH_REMATCH[1]}
    title=${subject% "(#$pr)"}
  elif [[ "$subject" =~ \#([0-9]+)$ ]]; then
    pr=${BASH_REMATCH[1]}
    title=${subject% "#$pr"}
  else
    title=$subject
  fi
  title=${title% }
  if [ -n "$pr" ] && [ "$upstream_label" != upstream ]; then
    printf -- '- %s#%s %s [%s]\n' "$upstream_label" "$pr" "$title" "${commit:0:12}"
  else
    printf -- '- %s@%s %s\n' "$upstream_label" "${commit:0:12}" "$subject"
  fi
}

measure() {
  local upstream_url origin_url common_dir range upstream_oid fork_oid merge_base
  local behind bin_count contract_count newest_date trigger
  local commits_file contract_group bin_group docs_group tests_group other_group
  local commit subject paths path touches_contract touches_bin touches_docs touches_tests
  local group_spec group_name group_file fork_paths upstream_paths overlap_paths overlap_count

  upstream_url=$(git -C "$ROOT" remote get-url upstream 2>/dev/null) || exit 0
  upstream_label=$(repo_label "$upstream_url")
  origin_url=$(git -C "$ROOT" remote get-url origin 2>/dev/null) \
    || report_failure 'fork origin remote cannot be resolved'

  measurement_repo="$FM_UPSTREAM_STATUS_TMP/repo.git"
  git init -q --bare "$measurement_repo" \
    || report_failure 'temporary repository could not be initialized'
  common_dir=$(git -C "$ROOT" rev-parse --git-common-dir) \
    || report_failure 'fork object store cannot be resolved'
  case "$common_dir" in
    /*) ;;
    *) common_dir=$(cd "$ROOT" && cd "$common_dir" && pwd -P) \
         || report_failure 'fork object store cannot be resolved' ;;
  esac
  objects_dir="$common_dir/objects"

  fetch_default_branch "$origin_url" refs/remotes/fork/HEAD fork
  fetch_default_branch "$upstream_url" refs/remotes/upstream/HEAD upstream

  fork_oid=$(GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" rev-parse 'refs/remotes/fork/HEAD^{commit}') \
    || report_failure 'fork default branch is not a commit'
  upstream_oid=$(GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" rev-parse 'refs/remotes/upstream/HEAD^{commit}') \
    || report_failure 'upstream HEAD is not a commit'
  merge_base=$(GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" merge-base \
      refs/remotes/fork/HEAD refs/remotes/upstream/HEAD) \
    || report_failure 'fork and upstream have no common ancestor'
  range="$merge_base..refs/remotes/upstream/HEAD"
  behind=$(GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" rev-list --first-parent --count "$range")
  [ "$behind" -gt 0 ] || exit 0

  bin_count=$(GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" rev-list --first-parent --count "$range" -- bin)
  contract_count=$(GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" rev-list --first-parent --count "$range" \
      -- AGENTS.md .agents/skills)
  newest_date=$(GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" show -s --format=%cs "$upstream_oid")

  if [ "$behind" -ge "$THRESHOLD" ]; then
    trigger="sync trigger crossed: at least $THRESHOLD pending changes"
  else
    trigger='sync trigger not crossed'
  fi
  printf 'UPSTREAM: behind %s by %s merged changes (%s touch bin/, %s touch AGENTS.md/skills; newest %s); %s\n' \
    "$upstream_label" "$behind" "$bin_count" "$contract_count" "$newest_date" "$trigger"

  [ "$DETAILS" -eq 1 ] || exit 0

  commits_file="$FM_UPSTREAM_STATUS_TMP/commits"
  contract_group="$FM_UPSTREAM_STATUS_TMP/group-contract"
  bin_group="$FM_UPSTREAM_STATUS_TMP/group-bin"
  docs_group="$FM_UPSTREAM_STATUS_TMP/group-docs"
  tests_group="$FM_UPSTREAM_STATUS_TMP/group-tests"
  other_group="$FM_UPSTREAM_STATUS_TMP/group-other"
  : > "$contract_group"
  : > "$bin_group"
  : > "$docs_group"
  : > "$tests_group"
  : > "$other_group"
  GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" rev-list --first-parent --reverse "$range" \
      > "$commits_file"

  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    subject=$(GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
      git --git-dir="$measurement_repo" show -s --format=%s "$commit")
    paths=$(GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
      git --git-dir="$measurement_repo" diff-tree --no-commit-id --name-only -r \
        "$commit^1" "$commit")
    touches_contract=0
    touches_bin=0
    touches_docs=0
    touches_tests=0
    while IFS= read -r path; do
      case "$path" in
        AGENTS.md|.agents/skills/*) touches_contract=1 ;;
        bin/*) touches_bin=1 ;;
        docs/*) touches_docs=1 ;;
        tests/*) touches_tests=1 ;;
      esac
    done <<< "$paths"

    if [ "$touches_contract" -eq 1 ]; then
      render_change "$commit" "$subject" >> "$contract_group"
    elif [ "$touches_bin" -eq 1 ]; then
      render_change "$commit" "$subject" >> "$bin_group"
    elif [ "$touches_docs" -eq 1 ]; then
      render_change "$commit" "$subject" >> "$docs_group"
    elif [ "$touches_tests" -eq 1 ]; then
      render_change "$commit" "$subject" >> "$tests_group"
    else
      render_change "$commit" "$subject" >> "$other_group"
    fi
  done < "$commits_file"

  printf 'UPSTREAM_TARGET: %s@%s\n' "$upstream_label" "$upstream_oid"
  printf 'UPSTREAM_BASE: fork@%s merge-base@%s\n' "$fork_oid" "$merge_base"
  for group_spec in \
    "AGENTS.md/skills|$contract_group" \
    "bin/|$bin_group" \
    "docs/|$docs_group" \
    "tests/|$tests_group" \
    "other|$other_group"; do
    group_name=${group_spec%%|*}
    group_file=${group_spec#*|}
    [ -s "$group_file" ] || continue
    printf 'UPSTREAM_CHANGES: %s\n' "$group_name"
    cat "$group_file"
  done

  fork_paths="$FM_UPSTREAM_STATUS_TMP/fork-paths"
  upstream_paths="$FM_UPSTREAM_STATUS_TMP/upstream-paths"
  overlap_paths="$FM_UPSTREAM_STATUS_TMP/overlap-paths"
  LC_ALL=C GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" diff --name-only \
      "$merge_base..refs/remotes/fork/HEAD" | LC_ALL=C sort -u > "$fork_paths"
  LC_ALL=C GIT_ALTERNATE_OBJECT_DIRECTORIES="$objects_dir" \
    git --git-dir="$measurement_repo" diff --name-only "$range" \
      | LC_ALL=C sort -u > "$upstream_paths"
  LC_ALL=C comm -12 "$fork_paths" "$upstream_paths" > "$overlap_paths"
  overlap_count=$(wc -l < "$overlap_paths" | tr -d '[:space:]')
  printf 'UPSTREAM_OVERLAP: %s paths changed on both sides of the merge base\n' "$overlap_count"
  if [ "$overlap_count" -gt 0 ]; then
    sed 's/^/- /' "$overlap_paths"
  fi
}

if [ "${FM_UPSTREAM_STATUS_INTERNAL:-0}" = 1 ]; then
  measure
  exit 0
fi

git -C "$ROOT" remote get-url upstream >/dev/null 2>&1 || exit 0

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-upstream-status.XXXXXX") || {
  printf 'UPSTREAM: unable to measure upstream - temporary repository could not be created\n'
  exit 1
}
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
result_file="$tmp/result"

# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
measurement_status=0
(
  export FM_UPSTREAM_STATUS_INTERNAL=1
  export FM_UPSTREAM_STATUS_TMP="$tmp"
  fm_run_timed "$TIMEOUT" "$0" "${1:-}"
) > "$result_file" || measurement_status=$?

case "$measurement_status" in
  0) cat "$result_file" ;;
  124|137)
    printf 'UPSTREAM: unable to measure upstream - timed out after %ss\n' "$TIMEOUT"
    exit 1
    ;;
  125)
    printf 'UPSTREAM: unable to measure upstream - no bounded command runner is available\n'
    exit 1
    ;;
  *)
    if [ -s "$result_file" ]; then
      cat "$result_file"
    else
      printf 'UPSTREAM: unable to measure upstream - measurement failed with exit %s\n' \
        "$measurement_status"
    fi
    exit 1
    ;;
esac
