#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) allowlisted merge-method and message args are forwarded to the forge
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) non-allowlisted args fail fast because passthrough cannot prove immediacy
#   (i) an open recorded issue is closed after merge and linked to the PR
#   (j) an already-closed recorded issue is left alone
#   (k) issue-close failure reports the merge as successful and exits zero
#   (l) a task with no recorded issue makes no issue API calls
#   (m) issue-state verification failure reports the merge as successful
#   (n) a successful close request that leaves the issue open warns
#   (o) malformed or duplicate recorded issue metadata warns without API calls
#   (p) a gitea work item closes through its own host credential with the same
#       linking comment, an absent credential and an empty one are reported as
#       the two different facts they are with nothing sent, a verification that
#       fails says why it failed rather than only that it did, and a gitea close
#       failure never makes the merge look retryable
#   (q) a cached-PR-state refresh that fails hands the operator the cause the
#       refresh named, bounded to one line, instead of only the symptom
#   (r) a GitLab MR URL resolves and merges through glab instead of erroring
#   (s) glab is addressed by the host from the URL, never an assumed one
#   (t) no merge method is imposed on GitLab, so the project's own one applies
#   (u) each pre-merge condition refuses independently, and all of them report
#   (v) a stale recorded pr_head= is reported and the live head is verified
#   (w) an unreadable merge request state refuses rather than merging blind
#   (x) glab or jq absent refuses before any state is recorded
#   (y) caller-controlled head bindings fail fast on both providers
#   (z) a GitLab refusal still leaves pr= recorded and the merge poll armed
#   (aa) non-allowlisted short options are refused before recording
#   (bb) a successful merge in a secondmate home reports the landed PR upward
#        once, on the route its parent binding names, and a repeat merge of the
#        same PR does not duplicate that line
#   (cc) a refused or failed merge reports nothing
#   (dd) a successful merge in a main home leaves a durable wake naming the PR
#   (ee) a secondmate home with no usable parent binding says so loudly instead
#        of merging in silence
#   (ff) a post-command queued GitHub merge is a refusal and leaves its poll armed
#   (gg) a post-command queued GitLab merge is a refusal and leaves its poll armed
#   (hh) an uncommitted marker retry never loses the durable outcome
#   (ii) distinct merged PRs for a reused task each survive queue deduplication
#   (jj) a stale PR that omits a file added to the current default branch is
#        refused before the forge merge call and names the omitted content
#   (kk) an unavailable default-branch comparison fails closed and tells the
#        operator to restore the inputs instead of offering a bypass
#   (ll) non-allowlisted merge flags are refused before recording or comparison
#        because unbounded passthrough cannot guarantee immediate execution
#   (mm) a GitHub merge queue or unreadable immediacy state refuses before the
#        forge call because neither can prove immediate execution
#   (nn) both providers re-read the default tip immediately before the forge
#        call and refuse when it moved since the guarded comparison
#   (oo) GitHub body-file input is materialized and size-bounded before that
#        final tip read, so external input cannot reopen the stale-base race
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin origin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  origin="$case_dir/origin.git"
  git init -q --bare --initial-branch=main "$origin"
  git init -q --initial-branch=main "$case_dir/wt"
  printf 'shared base\n' >"$case_dir/wt/shared.txt"
  printf 'delete me\n' >"$case_dir/wt/presence-delete.txt"
  printf '#!/bin/sh\nexit 0\n' >"$case_dir/wt/mode.sh"
  printf 'plain file\n' >"$case_dir/wt/type.txt"
  printf 'old first\nold second\n' >"$case_dir/wt/replace.txt"
  git -C "$case_dir/wt" add shared.txt presence-delete.txt mode.sh type.txt replace.txt
  git -C "$case_dir/wt" commit -qm 'seed shared base'
  git -C "$case_dir/wt" remote add origin "$origin"
  git -C "$case_dir/wt" push -q -u origin main
  git -C "$case_dir/wt" switch -qc task
  printf 'task change\n' >"$case_dir/wt/task.txt"
  git -C "$case_dir/wt" add task.txt
  git -C "$case_dir/wt" commit -qm 'add task change'
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  cat >"$fakebin/git" <<'SH'
#!/usr/bin/env bash
rewrite=0
ls_remote=0
for arg in "$@"; do
  case "$arg" in
    ls-remote) rewrite=1; ls_remote=1 ;;
    fetch) rewrite=1 ;;
  esac
done
if [ "$rewrite" -eq 1 ]; then
  if [ "$ls_remote" -eq 1 ] && [ -n "${FM_TEST_ADVANCE_DEFAULT_ON_LS_REMOTE:-}" ]; then
    count_file="${FM_TEST_WT%/wt}/ls-remote-count"
    count=0
    [ ! -f "$count_file" ] || count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq "$FM_TEST_ADVANCE_DEFAULT_ON_LS_REMOTE" ]; then
      "$FM_TEST_REAL_GIT" --git-dir="$FM_TEST_GIT_REMOTE" update-ref \
        refs/heads/main "$FM_TEST_ADVANCED_BASE"
    fi
  fi
  args=()
  for arg in "$@"; do
    if [ "$arg" = origin ]; then args+=("$FM_TEST_GIT_REMOTE"); else args+=("$arg"); fi
  done
  exec "$FM_TEST_REAL_GIT" "${args[@]}"
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  printf '%s\n' "$case_dir"
}

# Build the stale topology from the 2026-09-02 incidents: the task branch and
# the default branch share an old base, then the default branch gains a file the
# task branch never touched while the task's own change and green head remain
# unchanged.
make_stale_case() {
  local name=$1 case_dir origin default_wt
  case_dir=$(make_case "$name")
  origin="$case_dir/origin.git"
  default_wt="$case_dir/default-wt"
  git clone -q "$origin" "$default_wt"
  printf 'published while the PR waited\n' >"$default_wt/published.md"
  git -C "$default_wt" add published.md
  git -C "$default_wt" commit -qm 'publish current-only content'
  git -C "$default_wt" push -q origin main
  printf '%s\n' "$case_dir"
}

prepare_advanced_default() {
  local case_dir=$1 advanced_wt
  advanced_wt="$case_dir/advanced-default-wt"
  git clone -q "$case_dir/origin.git" "$advanced_wt"
  printf 'landed after guarded comparison\n' >"$advanced_wt/late-default.txt"
  git -C "$advanced_wt" add late-default.txt
  git -C "$advanced_wt" commit -qm 'advance default after comparison'
  git -C "$advanced_wt" push -q origin HEAD:refs/fm-test/advanced-base
  git -C "$advanced_wt" rev-parse HEAD
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
  : >"$case_dir/gh.log"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_open_then_closed() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
  "issue view")
    count_file="$FM_TEST_GH_AXI_LOG.issue-views"
    count=0
    [ -f "$count_file" ] && count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'issue:\n  state: open\n'
    else
      printf 'issue:\n  state: closed\n'
    fi
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_closed() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
  "issue view") printf 'issue:\n  state: closed\n' ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_close_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
  "issue view") printf 'issue:\n  state: open\n' ;;
  "issue close") echo 'error: issue close failed' >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
  "issue view") echo 'error: issue view failed' >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_issue_stays_open() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
  "issue view") printf 'issue:\n  state: open\n' ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

BASE_PATH=$PATH

# The GitLab fixture. A placeholder host that resolves nowhere, and a namespace
# deeper than one group, because a GitLab project has no owner/repository pair.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"
MR_HEAD=__TASK_HEAD__
MR_STALE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

JQ_BIN=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"

# glab mock recording every invocation together with the GITLAB_HOST it was
# given, so a test can prove the instance came from the URL. `mr view` answers
# from the case's JSON payload; marker files in the case dir drive the failure
# modes, so no test has to leak environment into a shared runner.
add_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case_dir=$(dirname "$FM_TEST_GLAB_JSON")
case "${1:-} ${2:-}" in
  "api graphql")
    [ ! -e "$case_dir/glab-view-fails" ] || exit 1
    task_head=$(git -C "$FM_TEST_WT" rev-parse HEAD)
    default_head=$(git --git-dir="$FM_TEST_GIT_REMOTE" rev-parse refs/heads/main)
    sed -e "s/__TASK_HEAD__/$task_head/g" \
      -e "s/__DEFAULT_HEAD__/$default_head/g" "$FM_TEST_GLAB_JSON"
    exit 0
    ;;
  "api projects/"*)
    [ ! -e "$case_dir/glab-project-fails" ] || exit 1
    cat "$FM_TEST_GLAB_PROJECT_JSON"
    exit 0
    ;;
  "mr view")
    [ ! -e "$case_dir/glab-view-fails" ] || exit 1
    if [ -e "$case_dir/glab-merge-called" ] && [ -e "$case_dir/glab-post-view-fails" ]; then
      exit 1
    fi
    if [ -e "$case_dir/glab-stays-open" ]; then
      printf '{"state":"opened"}\n'
    else
      cat "$case_dir/mr-post.json"
    fi
    exit 0
    ;;
  "mr merge")
    [ ! -e "$case_dir/glab-merge-fails" ] || { echo "error: mr merge failed" >&2 ; exit 1 ; }
    : > "$case_dir/glab-merge-called"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# write_mr_json <file> [<field>=<value> ...]
# A merge request payload that satisfies every pre-merge condition, with the
# named fields overridden so one case drives exactly one condition. Values are
# written into the JSON as-is, so a value may carry a JSON escape.
write_mr_json() {
  local file=$1 kv key value
  local state=opened detail=mergeable conflicts=false discussions=true
  local target=main target_oid=__DEFAULT_HEAD__
  local head=$MR_HEAD pipeline_sha=$MR_HEAD pipeline_status=success pipeline=present
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      detail) detail=$value ;;
      conflicts) conflicts=$value ;;
      discussions) discussions=$value ;;
      head) head=$value ;;
      target) target=$value ;;
      target_oid) target_oid=$value ;;
      pipeline_sha) pipeline_sha=$value ;;
      pipeline_status) pipeline_status=$value ;;
      pipeline) pipeline=$value ;;
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  printf '{"data":{"project":{"mergeRequest":{"state":"%s","detailedMergeStatus":"%s","conflicts":%s,' \
    "$state" "$detail" "$conflicts" > "$file"
  printf '"mergeableDiscussionsState":%s,"diffHeadSha":"%s","targetBranch":"%s",' \
    "$discussions" "$head" "$target" >>"$file"
  printf '"headPipeline":%s},"repository":{"commit":{"sha":"%s"}}}}}\n' \
    "$pipeline" "$target_oid" >>"$file"
}

# make_gitlab_case <name> [<field>=<value> ...]: a case dir with both forge
# mocks and a merge request payload. Echoes the case dir.
make_gitlab_case() {
  local name=$1 case_dir
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  add_glab_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/glab.log"
  write_mr_json "$case_dir/mr.json" "$@"
  printf '{"state":"merged"}\n' >"$case_dir/mr-post.json"
  printf '{"automatic_rebase_enabled":false}\n' >"$case_dir/project.json"
  printf '%s\n' "$case_dir"
}

# mirror_path_without <dir> <tool> [<bindir> ...]: the whole search path
# re-exposed by symlink except one tool, because a real copy anywhere on PATH
# would prove nothing. The named bindirs are mirrored ahead of the search path,
# so the case's own mocks answer for every tool that is not the omitted one and
# the refusal names that tool alone whatever the host happens to have installed.
mirror_path_without() {
  local dir=$1 omit=$2 search bindir entry name
  shift 2
  mkdir -p "$dir"
  search=$(printf '%s\n' "$@"; printf '%s\n' "$BASE_PATH" | tr ':' '\n')
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$search
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

# The merge line glab was asked to run, so a test asserts one exact invocation
# rather than a substring of the whole log.
glab_merge_line() {
  grep -F ' mr merge ' "$1" || true
}

ensure_gh_state_mock() {
  local case_dir=$1
  [ -x "$case_dir/fakebin/gh" ] || return 0
  [ ! -e "$case_dir/fakebin/gh-command" ] || return 0
  mv "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-command"
  cat >"$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
delegate=${0%/*}/gh-command
case "${1:-} ${2:-}" in
  "api graphql")
    printf '%s\n' "$*" >>"$FM_TEST_GH_LOG"
    case_dir=${FM_TEST_WT%/wt}
    if [ -n "${FM_TEST_ADVANCE_DEFAULT_ON_GRAPHQL:-}" ]; then
      count_file="$case_dir/graphql-count"
      count=0
      [ ! -f "$count_file" ] || count=$(cat "$count_file")
      count=$((count + 1))
      printf '%s\n' "$count" >"$count_file"
      if [ "$count" -eq "$FM_TEST_ADVANCE_DEFAULT_ON_GRAPHQL" ]; then
        "$FM_TEST_REAL_GIT" --git-dir="$FM_TEST_GIT_REMOTE" update-ref \
          refs/heads/main "$FM_TEST_ADVANCED_BASE"
      fi
    fi
    number=
    for arg in "$@"; do
      case "$arg" in number=*) number=${arg#number=} ;; esac
    done
    [ -n "$number" ] || exit 2
    if [ -e "$case_dir/github-merge-called-$number" ]; then
      [ -z "${FM_TEST_GH_POST_STATE_UNAVAILABLE:-}" ] || exit 1
      state=${FM_TEST_GH_POST_STATE:-MERGED}
      queue_enabled=${FM_TEST_GH_POST_QUEUE_ENABLED:-false}
      in_queue=${FM_TEST_GH_POST_IN_QUEUE:-false}
      auto_merge=${FM_TEST_GH_POST_AUTO_MERGE:-none}
      queue_entry=${FM_TEST_GH_POST_QUEUE_ENTRY:-none}
    else
      [ -z "${FM_TEST_GH_STATE_UNAVAILABLE:-}" ] || exit 1
      state=${FM_TEST_GH_PRE_STATE:-OPEN}
      queue_enabled=${FM_TEST_GH_QUEUE_ENABLED:-false}
      if [ -n "${FM_TEST_GH_QUEUE_ENABLE_MARKER:-}" ] \
        && [ -e "$FM_TEST_GH_QUEUE_ENABLE_MARKER" ]; then
        queue_enabled=true
      fi
      in_queue=${FM_TEST_GH_IN_QUEUE:-false}
      auto_merge=${FM_TEST_GH_AUTO_MERGE:-none}
      queue_entry=${FM_TEST_GH_QUEUE_ENTRY:-none}
    fi
    head_oid=${FM_TEST_GH_HEAD_OID:-$("$FM_TEST_REAL_GIT" --git-dir="$FM_TEST_GIT_REMOTE" rev-parse "refs/pull/$number/head")}
    base_oid=${FM_TEST_GH_BASE_OID:-$("$FM_TEST_REAL_GIT" --git-dir="$FM_TEST_GIT_REMOTE" rev-parse refs/heads/main)}
    printf 'state=%s\nbase_ref=%s\nhead_oid=%s\nbase_oid=%s\nqueue_enabled=%s\nin_queue=%s\nauto_merge=%s\nqueue_entry=%s\n' \
      "$state" "${FM_TEST_GH_BASE_REF:-main}" "$head_oid" "$base_oid" \
      "$queue_enabled" "$in_queue" "$auto_merge" "$queue_entry"
    ;;
  "pr merge")
    "$delegate" "$@" || exit $?
    : >"${FM_TEST_WT%/wt}/github-merge-called-${3:?missing pull request number}"
    ;;
  *) exec "$delegate" "$@" ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 url number source_ref rc canonical remote rest; shift
  ensure_gh_state_mock "$case_dir"
  url=${2:-}
  case "$url" in
    https://github.com/*/pull/*)
      number=${url##*/pull/}
      source_ref="refs/pull/$number/head"
      rest=${url#https://github.com/}
      canonical="https://github.com/${rest%/pull/*}.git"
      ;;
    https://*/-/merge_requests/*)
      number=${url##*/merge_requests/}
      source_ref="refs/merge-requests/$number/head"
      canonical="${url%/-/merge_requests/*}.git"
      ;;
    *) source_ref=; canonical= ;;
  esac
  remote=$(git -C "$case_dir/wt" config --get remote.origin.url 2>/dev/null || true)
  if ! fm_project_origin_identity "$remote"; then
    [ -z "$canonical" ] || git -C "$case_dir/wt" remote set-url origin "$canonical"
  fi
  if [ -n "$source_ref" ] && git -C "$case_dir/wt" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$case_dir/wt" push -q --force "$case_dir/origin.git" "HEAD:$source_ref"
  fi
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$ROOT}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_REAL_GIT="$(command -v git)" \
  FM_TEST_GIT_REMOTE="$case_dir/origin.git" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  FM_TEST_GLAB_PROJECT_JSON="$case_dir/project.json" \
  FM_TEST_WT="$case_dir/wt" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir head rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF "pr merge 9 --repo example/repo --match-head-commit $head --squash" "$case_dir/gh.log" \
    || fail "records-before-merge: gh pr merge was not bound to the inspected head"
  pass "fm-pr-merge records the PR and binds GitHub merge to the inspected head"
}

test_stale_pr_refuses_before_merging() {
  local case_dir head rc
  case_dir=$(make_stale_case stale-pr-refusal)
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  : >"$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-refusal: fm-pr-merge should refuse"
  assert_grep 'warning: https://github.com/example/repo/pull/73 is behind the current default branch' "$case_dir/stderr" \
    "stale-pr-refusal: fm-pr-check did not report the stale PR when recording it"
  assert_grep 'because its head is behind the current default branch' "$case_dir/stderr" \
    "stale-pr-refusal: refusal did not name the stale-base cause"
  assert_grep 'published.md: current default adds a regular file containing 1 line absent from the PR head' "$case_dir/stderr" \
    "stale-pr-refusal: refusal did not name the untouched file and lost content"
  assert_grep 'bring the branch up to current main and re-run validation' "$case_dir/stderr" \
    "stale-pr-refusal: refusal did not tell the operator how to recover"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "stale-pr-refusal: gh pr merge was invoked for a stale PR"
  pass "fm-pr-merge refuses a stale PR that omits current default-branch content"
}

test_pathspec_magic_filename_cannot_bypass_stale_refusal() {
  local case_dir default_wt head rc
  case_dir=$(make_case stale-pathspec-magic)
  default_wt="$case_dir/default-pathspec-wt"
  git clone -q "$case_dir/origin.git" "$default_wt"
  printf 'published while the PR waited\n' >"$default_wt/:(glob)*"
  git -C "$default_wt" add -A
  git -C "$default_wt" commit -qm 'publish pathspec-named content'
  git -C "$default_wt" push -q origin main
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/79 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pathspec-magic: fm-pr-merge should refuse"
  assert_grep ':\(glob\)\*: current default adds a regular file containing 1 line absent from the PR head' \
    "$case_dir/stderr" \
    "stale-pathspec-magic: refusal did not name the literal pathspec filename"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "stale-pathspec-magic: pathspec interpretation bypassed the stale refusal"
  pass "literal pathspec filenames cannot bypass stale-base refusal"
}

test_unavailable_stale_comparison_refuses_before_merging() {
  local case_dir rc
  case_dir=$(make_case unavailable-stale-comparison)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/missing-wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  add_gh_mocks "$case_dir" 1212121212121212121212121212121212121212
  : >"$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unavailable-stale-comparison: fm-pr-merge should refuse"
  assert_grep 'refusing to merge https://github.com/example/repo/pull/74 because it could not be compared' "$case_dir/stderr" \
    "unavailable-stale-comparison: refusal did not name the failed safety check"
  assert_grep 'restore the task worktree and origin access, then retry the merge' "$case_dir/stderr" \
    "unavailable-stale-comparison: refusal did not name the recovery action"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unavailable-stale-comparison: gh pr merge ran without a comparison"
  pass "fm-pr-merge fails closed when the current-default comparison is unavailable"
}

test_mismatched_repository_refuses_before_merging() {
  local case_dir origin rc
  case_dir=$(make_case mismatched-repository)
  origin=$(git -C "$case_dir/wt" config --get remote.origin.url)
  git -C "$case_dir/wt" config "url.$origin.insteadOf" https://github.com/wrong/repository.git
  git -C "$case_dir/wt" remote set-url origin https://github.com/wrong/repository.git
  add_gh_mocks "$case_dir" 1313131313131313131313131313131313131313

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/76 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mismatched-repository: fm-pr-merge should refuse"
  assert_grep 'task worktree origin does not match the PR repository' "$case_dir/stderr" \
    "mismatched-repository: refusal did not name the identity mismatch"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "mismatched-repository: GitHub merge reached the wrong repository boundary"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "mismatched-repository: record-time warning prevented the durable poll"
  pass "fm-pr-merge refuses when task origin and PR repository identities differ"
}

test_supported_origin_spellings_preserve_repository_binding() {
  local case_dir name origin rc spec
  for spec in \
    'ssh-alias|git@work-gitlab:group/subgroup/project.git' \
    'ssh-port|ssh://git@gitlab.example:2222/group/subgroup/project.git' \
    'https-userinfo|https://user:token@gitlab.example/group/subgroup/project.git' \
    'scp-no-user|gitlab.example:group/subgroup/project.git'; do
    name=${spec%%|*}
    origin=${spec#*|}
    case_dir=$(make_gitlab_case "supported-origin-$name")
    git -C "$case_dir/wt" remote set-url origin "$origin"
    cat >"$case_dir/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
host=${!#}
case "$host" in
  work-gitlab) host=gitlab.example ;;
esac
printf 'hostname %s\n' "$host"
SH
    chmod +x "$case_dir/fakebin/ssh"

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" "supported-origin-$name: matching origin should merge"
    assert_grep ' mr merge ' "$case_dir/glab.log" \
      "supported-origin-$name: matching origin did not reach the forge merge"
  done
  pass "supported origin spellings retain exact repository binding"
}

test_ssh_resolution_preserves_origin_user_and_port() {
  local case_dir rc
  case_dir=$(make_gitlab_case ssh-user-port-resolution)
  git -C "$case_dir/wt" remote set-url origin \
    ssh://git@work-gitlab:2222/group/subgroup/project.git
  cat >"$case_dir/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_TEST_SSH_LOG"
if [ "$*" = '-G -l git -p 2222 work-gitlab' ]; then
  printf 'hostname gitlab.example\n'
else
  printf 'hostname mirror.internal\n'
fi
SH
  chmod +x "$case_dir/fakebin/ssh"

  set +e
  FM_TEST_SSH_LOG="$case_dir/ssh.log" \
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ssh-user-port-resolution: matching origin should merge"
  assert_grep '-G -l git -p 2222 work-gitlab' "$case_dir/ssh.log" \
    "ssh-user-port-resolution: origin user and port did not reach SSH configuration"
  assert_grep ' mr merge ' "$case_dir/glab.log" \
    "ssh-user-port-resolution: matching effective destination did not merge"
  pass "SSH identity resolution preserves the origin user and port"
}

test_ssh_hostname_override_refuses_repository_binding() {
  local case_dir head rc
  case_dir=$(make_case ssh-hostname-override)
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  git -C "$case_dir/wt" remote set-url origin git@github.com:example/repo.git
  cat >"$case_dir/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
host=${!#}
[ "$host" = github.com ] || exit 1
printf 'hostname mirror.internal\n'
SH
  chmod +x "$case_dir/fakebin/ssh"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/85 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ssh-hostname-override: fm-pr-merge should refuse"
  assert_grep 'task worktree origin does not match the PR repository' "$case_dir/stderr" \
    "ssh-hostname-override: effective SSH host mismatch was not reported"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "ssh-hostname-override: merge crossed the effective SSH host boundary"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "ssh-hostname-override: record-time warning prevented the durable poll"
  pass "effective SSH host overrides cannot bypass repository binding"
}

test_ssh_config_resolution_is_bounded() {
  local case_dir elapsed rc started
  case_dir=$(make_case ssh-config-timeout)
  add_gh_mocks "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  git -C "$case_dir/wt" remote set-url origin git@work-github:example/repo.git
  cat >"$case_dir/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
sleep 20
printf 'hostname github.com\n'
SH
  chmod +x "$case_dir/fakebin/ssh"

  started=$SECONDS
  set +e
  FM_PR_STALE_BASE_TIMEOUT=1 FM_TIMEOUT_KILL_GRACE=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/86 \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  elapsed=$((SECONDS - started))

  expect_code 1 "$rc" "ssh-config-timeout: fm-pr-merge should refuse"
  [ "$elapsed" -lt 8 ] \
    || fail "ssh-config-timeout: SSH configuration resolution exceeded its bound (${elapsed}s)"
  assert_grep 'task worktree origin does not match the PR repository' "$case_dir/stderr" \
    "ssh-config-timeout: bounded SSH resolution failure was not reported"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "ssh-config-timeout: merge ran after SSH configuration resolution timed out"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "ssh-config-timeout: timeout prevented the durable poll"
  pass "SSH configuration resolution obeys the stale-base probe timeout"
}

test_multiple_merge_bases_refuse_comparison() {
  local a1 a2 b1 b2 case_dir root tree rc
  case_dir=$(make_case multiple-merge-bases)
  root=$(git -C "$case_dir/wt" rev-parse main)
  tree=$(git -C "$case_dir/wt" rev-parse "$root^{tree}")
  a1=$(printf 'first side\n' | git -C "$case_dir/wt" commit-tree "$tree" -p "$root")
  b1=$(printf 'second side\n' | git -C "$case_dir/wt" commit-tree "$tree" -p "$root")
  a2=$(printf 'first merge\n' | git -C "$case_dir/wt" commit-tree "$tree" -p "$a1" -p "$b1")
  b2=$(printf 'second merge\n' | git -C "$case_dir/wt" commit-tree "$tree" -p "$b1" -p "$a1")
  git -C "$case_dir/wt" push -q --force origin "$a2:refs/heads/main"
  git -C "$case_dir/wt" switch -q --detach "$b2"
  add_gh_mocks "$case_dir" "$b2"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/87 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "multiple-merge-bases: fm-pr-merge should refuse"
  assert_grep 'multiple best merge bases' "$case_dir/stderr" \
    "multiple-merge-bases: ambiguous comparison was not reported"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "multiple-merge-bases: ambiguous history reached the forge merge"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "multiple-merge-bases: comparison refusal prevented the durable poll"
  pass "multiple best merge bases fail the stale-base comparison closed"
}

test_stale_details_name_presence_content_type_and_mode_losses() {
  local case_dir default_wt head rc
  case_dir=$(make_case stale-detail-kinds)
  default_wt="$case_dir/default-detail-wt"
  git clone -q "$case_dir/origin.git" "$default_wt"
  : >"$default_wt/empty-added.txt"
  rm "$default_wt/presence-delete.txt"
  chmod +x "$default_wt/mode.sh"
  rm "$default_wt/type.txt"
  ln -s shared.txt "$default_wt/type.txt"
  printf 'new first\nnew third\n' >"$default_wt/replace.txt"
  git -C "$default_wt" add -A
  git -C "$default_wt" commit -qm 'change every stale detail kind'
  git -C "$default_wt" push -q origin main
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/77 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-detail-kinds: fm-pr-merge should refuse"
  assert_grep 'empty-added.txt: current default adds an empty file absent from the PR head' "$case_dir/stderr" \
    "stale-detail-kinds: empty-file presence loss was inaccurate"
  assert_grep 'presence-delete.txt: current default deletes the regular file that the PR head would restore' "$case_dir/stderr" \
    "stale-detail-kinds: deleted-file presence loss was inaccurate"
  assert_grep 'mode.sh: current default changes mode from 100644 to 100755 absent from the PR head' "$case_dir/stderr" \
    "stale-detail-kinds: executable-mode loss was inaccurate"
  assert_grep 'type.txt: current default changes type from regular file to symbolic link' "$case_dir/stderr" \
    "stale-detail-kinds: file-type loss was inaccurate"
  assert_grep 'replace.txt: current default adds 2 lines and removes 2 lines; the PR head lacks the additions and would restore the removed lines' "$case_dir/stderr" \
    "stale-detail-kinds: replacement content loss was inaccurate"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "stale-detail-kinds: a stale detail case reached the forge merge"
  pass "stale refusal accurately names presence, content, type, and mode losses"
}

test_stale_submodule_update_names_both_commits() {
  local case_dir default_wt head new_oid old_oid rc subrepo
  case_dir=$(make_case stale-submodule-update)
  subrepo="$case_dir/subrepo"
  git init -q --initial-branch=main "$subrepo"
  printf 'old submodule content\n' >"$subrepo/content.txt"
  git -C "$subrepo" add content.txt
  git -C "$subrepo" commit -qm 'old submodule commit'
  old_oid=$(git -C "$subrepo" rev-parse HEAD)
  printf 'new submodule content\n' >"$subrepo/content.txt"
  git -C "$subrepo" commit -qam 'new submodule commit'
  new_oid=$(git -C "$subrepo" rev-parse HEAD)

  git -C "$case_dir/wt" switch -q main
  git -C "$case_dir/wt" update-index --add \
    --cacheinfo "160000,$old_oid,modules/dependency"
  git -C "$case_dir/wt" commit -qm 'add shared submodule revision'
  git -C "$case_dir/wt" push -q origin main
  git -C "$case_dir/wt" switch -q task
  git -C "$case_dir/wt" rebase -q main

  default_wt="$case_dir/default-submodule-wt"
  git clone -q "$case_dir/origin.git" "$default_wt"
  git -C "$default_wt" update-index \
    --cacheinfo "160000,$new_oid,modules/dependency"
  git -C "$default_wt" commit -qm 'advance submodule revision'
  git -C "$default_wt" push -q origin main
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-submodule-update: fm-pr-merge should refuse"
  assert_grep "modules/dependency: current default changes submodule commit from $old_oid to $new_oid; the PR head would restore $old_oid" \
    "$case_dir/stderr" \
    "stale-submodule-update: refusal did not name both submodule commits"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "stale-submodule-update: an omitted submodule update reached the forge"
  pass "stale submodule updates name both commit identities"
}

test_github_head_race_is_rejected_by_the_forge_binding() {
  local case_dir h1 h2 rc
  case_dir=$(make_case github-head-race)
  h1=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf 'later head\n' >"$case_dir/wt/later.txt"
  git -C "$case_dir/wt" add later.txt
  git -C "$case_dir/wt" commit -qm 'advance pull request head'
  h2=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" switch -q --detach "$h1"
  cat >"$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf '%s\n' "$FM_TEST_OLD_HEAD" ;;
  "pr merge")
    git --git-dir="$FM_TEST_ORIGIN" update-ref "$FM_TEST_SOURCE_REF" "$FM_TEST_NEW_HEAD"
    expected=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --match-head-commit ]; then expected=${2:-}; break; fi
      shift
    done
    [ "$expected" = "$FM_TEST_NEW_HEAD" ] || exit 1
    : >"$FM_TEST_MERGED_MARKER"
    ;;
esac
SH
  cat >"$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
  export FM_TEST_OLD_HEAD="$h1" FM_TEST_NEW_HEAD="$h2"
  export FM_TEST_ORIGIN="$case_dir/origin.git" FM_TEST_SOURCE_REF=refs/pull/78/head
  export FM_TEST_MERGED_MARKER="$case_dir/merged"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/78 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_OLD_HEAD FM_TEST_NEW_HEAD FM_TEST_ORIGIN FM_TEST_SOURCE_REF FM_TEST_MERGED_MARKER

  expect_code 1 "$rc" "github-head-race: changed head should reject the merge"
  assert_grep "pr merge 78 --repo example/repo --match-head-commit $h1" "$case_dir/gh.log" \
    "github-head-race: merge was not bound to the inspected head"
  assert_absent "$case_dir/merged" \
    "github-head-race: the replacement head merged without stale-base inspection"
  pass "GitHub rejects a replacement head that did not pass stale-base inspection"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_allowlisted_merge_args_forwarded() {
  local case_dir head
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- \
    --squash --subject 'Guarded merge' --body 'Current base checked' --delete-branch -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  grep -qxF "pr merge 15 --repo example/repo --match-head-commit $head --squash --subject Guarded merge --body Current base checked --delete-branch -d" "$case_dir/gh.log" \
    || fail "extra-args: allowlisted gh pr merge arguments were not forwarded"
  pass "fm-pr-merge forwards allowlisted GitHub method, message, and cleanup arguments"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  # A near-miss GitLab URL: one namespace segment where a project needs at
  # least two. A well-formed merge request URL is merged now, so the refusal
  # has to be proven on a URL that genuinely does not parse.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "malformed-url: gh pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unsafe-url-segment: gh pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_non_allowlisted_repo_arg_refuses_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'refusing extra merge argument --repo because an unbounded passthrough cannot guarantee immediate execution' "$case_dir/stderr" \
    "repo-override: refusal did not explain why passthrough is unsafe"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "repo-override: gh pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses a non-allowlisted repository argument before recording state"
}

test_non_allowlisted_merge_args_refuse_before_recording_or_comparison() {
  local case_dir flag name rc url
  set -- \
    'github|https://github.com/right/repo/pull/5|--auto' \
    'github-true|https://github.com/right/repo/pull/5|--auto=TRUE' \
    'github-wrong-cleanup|https://github.com/right/repo/pull/5|--remove-source-branch' \
    "gitlab|$MR_URL|--auto-merge" \
    "gitlab-true|$MR_URL|--auto-merge=true" \
    "gitlab-legacy|$MR_URL|--when-pipeline-succeeds" \
    "gitlab-legacy-true|$MR_URL|--when-pipeline-succeeds=1" \
    "gitlab-wrong-cleanup|$MR_URL|--delete-branch"
  for name in "$@"; do
    flag=${name##*|}
    url=${name#*|}
    url=${url%|*}
    name=${name%%|*}
    case "$name" in
      github*)
        case_dir=$(make_case "deferred-$name")
        add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
        : >"$case_dir/gh-axi.log"
        ;;
      gitlab*) case_dir=$(make_gitlab_case "deferred-$name") ;;
    esac
    fm_write_meta "$case_dir/state/task-x1.meta" \
      'window=fm-task-x1' \
      "worktree=$case_dir/missing-worktree" \
      "project=$case_dir/project" \
      'kind=ship' \
      'mode=no-mistakes'

    set +e
    run_pr_merge "$case_dir" task-x1 "$url" -- "$flag" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "deferred-$name: fm-pr-merge should refuse $flag"
    assert_grep "refusing extra merge argument $flag because an unbounded passthrough cannot guarantee immediate execution" "$case_dir/stderr" \
      "deferred-$name: refusal did not name the argument and immediate-execution guarantee"
    assert_no_grep "pr=$url" "$case_dir/state/task-x1.meta" \
      "deferred-$name: PR URL was recorded before rejecting $flag"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "deferred-$name: $flag armed a merge poll"
    [ ! -s "$case_dir/gh-axi.log" ] \
      || fail "deferred-$name: the GitHub wrapper was invoked despite $flag"
    [ ! -s "$case_dir/gh.log" ] \
      || fail "deferred-$name: GitHub was invoked despite $flag"
    if [ -e "$case_dir/glab.log" ]; then
      [ ! -s "$case_dir/glab.log" ] \
        || fail "deferred-$name: GitLab was invoked despite $flag"
    fi
  done
  pass "fm-pr-merge refuses non-allowlisted merge flags before recording or comparison"
}

test_github_immediate_execution_preflight_refuses_queue_and_unknown() {
  local case_dir name rc expected
  for name in merge-queue unknown; do
    case_dir=$(make_case "github-immediate-$name")
    add_gh_mocks "$case_dir" 9898989898989898989898989898989898989898
    : >"$case_dir/gh-axi.log"
    case "$name" in
      merge-queue)
        expected='GitHub merge queue on target branch main would defer execution'
        set +e
        FM_TEST_GH_QUEUE_ENABLED=true \
          run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
            >"$case_dir/stdout" 2>"$case_dir/stderr"
        rc=$?
        set -e
        ;;
      unknown)
        expected='immediate execution state is unknown, and unknown does not prove deferral is absent'
        set +e
        FM_TEST_GH_STATE_UNAVAILABLE=1 \
          run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
            >"$case_dir/stdout" 2>"$case_dir/stderr"
        rc=$?
        set -e
        ;;
    esac

    expect_code 1 "$rc" "github-immediate-$name: unsafe immediacy state should refuse"
    assert_grep "$expected" "$case_dir/stderr" \
      "github-immediate-$name: refusal did not name the unsafe state"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-immediate-$name: the forge merge ran without an immediate-execution guarantee"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "github-immediate-$name: refusal retired the durable merge poll"
  done
  pass "fm-pr-merge refuses GitHub merge queues and unknown immediate-execution state"
}

test_default_tip_move_refuses_both_forges() {
  local case_dir new_tip old_tip provider rc url
  for provider in github gitlab; do
    case "$provider" in
      github)
        case_dir=$(make_case default-tip-move-github)
        add_gh_mocks "$case_dir" 9797979797979797979797979797979797979797
        : >"$case_dir/gh-axi.log"
        url=https://github.com/example/repo/pull/79
        ;;
      gitlab)
        case_dir=$(make_gitlab_case default-tip-move-gitlab)
        url=$MR_URL
        ;;
    esac
    old_tip=$(git --git-dir="$case_dir/origin.git" rev-parse refs/heads/main)
    new_tip=$(prepare_advanced_default "$case_dir")

    set +e
    FM_TEST_ADVANCE_DEFAULT_ON_LS_REMOTE=3 FM_TEST_ADVANCED_BASE=$new_tip \
      run_pr_merge "$case_dir" task-x1 "$url" \
        >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "default-tip-move-$provider: moving main should refuse"
    [ "$(git --git-dir="$case_dir/origin.git" rev-parse refs/heads/main)" = "$new_tip" ] \
      || fail "default-tip-move-$provider: the fixture did not advance main"
    assert_grep "current default branch main moved from inspected tip $old_tip to live tip $new_tip before merge" \
      "$case_dir/stderr" "default-tip-move-$provider: refusal did not name both default tips"
    assert_grep 'bring the branch up to current main and re-run validation' "$case_dir/stderr" \
      "default-tip-move-$provider: refusal did not name the recovery action"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "default-tip-move-$provider: refusal retired the durable merge poll"
    case "$provider" in
      github)
        assert_no_grep 'pr merge' "$case_dir/gh.log" \
          "default-tip-move-github: the forge call ran after main moved"
        ;;
      gitlab)
        assert_no_grep ' mr merge ' "$case_dir/glab.log" \
          "default-tip-move-gitlab: the forge call ran after main moved"
        ;;
    esac
  done
  pass "fm-pr-merge rechecks the inspected default tip for both providers"
}

test_forge_oid_mismatch_and_unknown_refuse_before_merge() {
  local case_dir expected forge_oid name rc url
  forge_oid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  for name in github-head github-base github-unknown gitlab-base gitlab-unknown; do
    case "$name" in
      github-*)
        case_dir=$(make_case "forge-oid-$name")
        add_gh_mocks "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
        : >"$case_dir/glab.log"
        url=https://github.com/example/repo/pull/88
        ;;
      gitlab-*)
        case "$name" in
          gitlab-base) case_dir=$(make_gitlab_case "forge-oid-$name" "target_oid=$forge_oid") ;;
          gitlab-unknown) case_dir=$(make_gitlab_case "forge-oid-$name" target_oid=unreadable) ;;
        esac
        url=$MR_URL
        ;;
    esac

    set +e
    case "$name" in
      github-head)
        expected="GitHub reports head OID $forge_oid but guarded inspection used"
        FM_TEST_GH_HEAD_OID=$forge_oid run_pr_merge "$case_dir" task-x1 "$url" \
          >"$case_dir/stdout" 2>"$case_dir/stderr"
        ;;
      github-base)
        expected="GitHub reports target branch main at OID $forge_oid but guarded inspection used"
        FM_TEST_GH_BASE_OID=$forge_oid run_pr_merge "$case_dir" task-x1 "$url" \
          >"$case_dir/stdout" 2>"$case_dir/stderr"
        ;;
      github-unknown)
        expected='GitHub immediate execution state is unknown'
        FM_TEST_GH_HEAD_OID=unreadable run_pr_merge "$case_dir" task-x1 "$url" \
          >"$case_dir/stdout" 2>"$case_dir/stderr"
        ;;
      gitlab-base)
        expected="GitLab reports target branch main at OID $forge_oid but guarded inspection used"
        run_pr_merge "$case_dir" task-x1 "$url" \
          >"$case_dir/stdout" 2>"$case_dir/stderr"
        ;;
      gitlab-unknown)
        expected='GitLab did not provide a readable target-branch OID at the merge boundary'
        run_pr_merge "$case_dir" task-x1 "$url" \
          >"$case_dir/stdout" 2>"$case_dir/stderr"
        ;;
    esac
    rc=$?
    set -e

    expect_code 1 "$rc" "forge-oid-$name: fm-pr-merge should refuse"
    assert_grep "$expected" "$case_dir/stderr" \
      "forge-oid-$name: refusal did not name the forge identity failure"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "forge-oid-$name: GitHub merge ran after identity refusal"
    assert_no_grep ' mr merge ' "$case_dir/glab.log" \
      "forge-oid-$name: GitLab merge ran after identity refusal"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "forge-oid-$name: identity refusal disarmed the durable poll"
  done
  pass "forge head and target OIDs are bound to guarded inspection"
}

test_non_default_targets_refuse_both_forges() {
  local case_dir provider rc url
  for provider in github gitlab; do
    case "$provider" in
      github)
        case_dir=$(make_case non-default-target-github)
        add_gh_mocks "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
        : >"$case_dir/glab.log"
        url=https://github.com/example/repo/pull/89
        ;;
      gitlab)
        case_dir=$(make_gitlab_case non-default-target-gitlab target=release)
        url=$MR_URL
        ;;
    esac

    set +e
    case "$provider" in
      github)
        FM_TEST_GH_BASE_REF=release run_pr_merge "$case_dir" task-x1 "$url" \
          >"$case_dir/stdout" 2>"$case_dir/stderr"
        ;;
      gitlab)
        run_pr_merge "$case_dir" task-x1 "$url" \
          >"$case_dir/stdout" 2>"$case_dir/stderr"
        ;;
    esac
    rc=$?
    set -e

    expect_code 1 "$rc" "non-default-target-$provider: fm-pr-merge should refuse"
    assert_grep 'actual target branch release' "$case_dir/stderr" \
      "non-default-target-$provider: refusal did not name the actual target"
    assert_grep 'retarget the PR to current default branch main, bring the branch up to current main, and re-run validation' \
      "$case_dir/stderr" \
      "non-default-target-$provider: refusal did not name the recovery action"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "non-default-target-$provider: GitHub merge ran for a non-default target"
    assert_no_grep ' mr merge ' "$case_dir/glab.log" \
      "non-default-target-$provider: GitLab merge ran for a non-default target"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "non-default-target-$provider: refusal disarmed the durable poll"
  done
  pass "both forges refuse merge requests targeting non-default branches"
}

test_final_github_preflight_cannot_reopen_default_tip_race() {
  local case_dir head new_tip old_tip rc
  case_dir=$(make_case final-preflight-default-tip-race)
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  old_tip=$(git --git-dir="$case_dir/origin.git" rev-parse refs/heads/main)
  new_tip=$(prepare_advanced_default "$case_dir")

  set +e
  FM_TEST_ADVANCE_DEFAULT_ON_GRAPHQL=2 FM_TEST_ADVANCED_BASE=$new_tip \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/83 \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "final-preflight-default-tip-race: moving main should refuse"
  [ "$(git --git-dir="$case_dir/origin.git" rev-parse refs/heads/main)" = "$new_tip" ] \
    || fail "final-preflight-default-tip-race: the GraphQL preflight did not advance main"
  assert_grep "GitHub reports target branch main at OID $new_tip but guarded inspection used $old_tip" \
    "$case_dir/stderr" \
    "final-preflight-default-tip-race: forge OID binding missed the preflight move"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "final-preflight-default-tip-race: the forge ran after main moved during preflight"
  pass "GitHub preflight cannot reopen the final default-tip race"
}

test_body_file_is_materialized_and_bounded_before_the_tip_recheck() {
  local advanced_tip case_dir head rc writer writer_rc
  case_dir=$(make_case body-file-tip-race)
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  advanced_tip=$(prepare_advanced_default "$case_dir")
  mkfifo "$case_dir/body.fifo"
  cat >"$case_dir/fakebin/head" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_TEST_BODY_FIFO" ]; then
    : >"$FM_TEST_BODY_READ_STARTED"
  fi
done
exec "$FM_TEST_REAL_HEAD" "$@"
SH
  cat >"$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf '%s\n' "$FM_TEST_BODY_HEAD" ;;
  "pr merge")
    body_file=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --body-file|-F) body_file=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    : >"$FM_TEST_BODY_READ_STARTED"
    cat "$body_file" >"$FM_TEST_BODY_OBSERVED"
    : >"$FM_TEST_MERGED_MARKER"
    ;;
esac
exit 0
SH
  cat >"$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/head" "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
  : >"$case_dir/gh.log"
  export FM_TEST_BODY_FIFO="$case_dir/body.fifo"
  export FM_TEST_BODY_READ_STARTED="$case_dir/body-read-started"
  export FM_TEST_BODY_HEAD="$head"
  export FM_TEST_BODY_OBSERVED="$case_dir/body-observed"
  export FM_TEST_MERGED_MARKER="$case_dir/merged"
  export FM_TEST_REAL_HEAD
  FM_TEST_REAL_HEAD=$(command -v head)
  (
    attempts=0
    while [ ! -e "$FM_TEST_BODY_READ_STARTED" ] && [ "$attempts" -lt 500 ]; do
      sleep 0.01
      attempts=$((attempts + 1))
    done
    [ -e "$FM_TEST_BODY_READ_STARTED" ] || exit 1
    git --git-dir="$case_dir/origin.git" update-ref refs/heads/main "$advanced_tip"
    printf 'stable merge body\n' >"$FM_TEST_BODY_FIFO"
  ) &
  writer=$!

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/80 -- \
    --body-file "$case_dir/body.fifo" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  wait "$writer"
  writer_rc=$?
  set -e
  unset FM_TEST_BODY_FIFO FM_TEST_BODY_READ_STARTED FM_TEST_BODY_HEAD
  unset FM_TEST_BODY_OBSERVED FM_TEST_MERGED_MARKER FM_TEST_REAL_HEAD

  expect_code 0 "$writer_rc" "body-file-tip-race: the synchronized default advance failed"
  expect_code 1 "$rc" "body-file-tip-race: moving main during body input should refuse"
  assert_grep "GitHub reports target branch main at OID $advanced_tip but guarded inspection used" \
    "$case_dir/stderr" \
    "body-file-tip-race: the post-materialization forge binding did not observe the move"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "body-file-tip-race: the forge ran after default moved during body input"
  assert_absent "$case_dir/merged" \
    "body-file-tip-race: a body-file delay reopened the stale-base merge race"

  case_dir=$(make_case body-file-byte-bound)
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  head -c 1048577 /dev/zero >"$case_dir/oversized-body"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/81 -- \
    --body-file "$case_dir/oversized-body" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "body-file-byte-bound: oversized input should refuse"
  assert_grep 'body-file input exceeds the 1048576-byte bound' "$case_dir/stderr" \
    "body-file-byte-bound: the refusal did not name the input bound"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "body-file-byte-bound: oversized body input reached the forge"
  pass "GitHub body-file input is materialized and bounded before the final tip check"
}

test_body_file_materialization_rechecks_immediate_execution() {
  local case_dir head rc writer writer_rc
  case_dir=$(make_case body-file-queue-race)
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$head"
  mkfifo "$case_dir/body.fifo"
  cat >"$case_dir/fakebin/head" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_TEST_BODY_FIFO" ]; then
    : >"$FM_TEST_BODY_READ_STARTED"
  fi
done
exec "$FM_TEST_REAL_HEAD" "$@"
SH
  chmod +x "$case_dir/fakebin/head"
  : >"$case_dir/gh.log"
  export FM_TEST_BODY_FIFO="$case_dir/body.fifo"
  export FM_TEST_BODY_READ_STARTED="$case_dir/body-read-started"
  export FM_TEST_GH_QUEUE_ENABLE_MARKER="$case_dir/queue-enabled"
  export FM_TEST_REAL_HEAD
  FM_TEST_REAL_HEAD=$(command -v head)
  (
    attempts=0
    while [ ! -e "$FM_TEST_BODY_READ_STARTED" ] && [ "$attempts" -lt 500 ]; do
      sleep 0.01
      attempts=$((attempts + 1))
    done
    [ -e "$FM_TEST_BODY_READ_STARTED" ] || exit 1
    : >"$FM_TEST_GH_QUEUE_ENABLE_MARKER"
    printf 'stable merge body\n' >"$FM_TEST_BODY_FIFO"
  ) &
  writer=$!

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 -- \
    --body-file "$case_dir/body.fifo" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  wait "$writer"
  writer_rc=$?
  set -e
  unset FM_TEST_BODY_FIFO FM_TEST_BODY_READ_STARTED
  unset FM_TEST_GH_QUEUE_ENABLE_MARKER FM_TEST_REAL_HEAD

  expect_code 0 "$writer_rc" "body-file-queue-race: the synchronized queue transition failed"
  expect_code 1 "$rc" "body-file-queue-race: enabling a queue during body input should refuse"
  assert_grep 'GitHub merge queue on target branch main would defer execution' "$case_dir/stderr" \
    "body-file-queue-race: the post-materialization preflight missed the queue"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "body-file-queue-race: the forge ran after a queue appeared during body input"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "body-file-queue-race: refusal retired the durable merge poll"
  pass "GitHub rechecks immediate execution after body-file materialization"
}

test_non_allowlisted_short_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case bundled-repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abababababababababababababababababababab
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/6 -- -dR wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override: fm-pr-merge should refuse a bundled repo override"
  assert_grep 'refusing extra merge argument -dR because an unbounded passthrough cannot guarantee immediate execution' "$case_dir/stderr" \
    "bundled-repo-override: refusal did not explain why passthrough is unsafe"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "bundled-repo-override: PR URL was recorded before rejecting the bundled repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override: a bundled repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "bundled-repo-override: gh pr merge was invoked despite the bundled repo override"

  case_dir=$(make_gitlab_case bundled-repo-override-gitlab)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- -yR https://other.example/g/p \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override-gitlab: fm-pr-merge should refuse a bundled instance override"
  assert_grep 'refusing extra merge argument -yR because an unbounded passthrough cannot guarantee immediate execution' "$case_dir/stderr" \
    "bundled-repo-override-gitlab: refusal did not explain why passthrough is unsafe"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "bundled-repo-override-gitlab: the URL was recorded before rejecting the bundled override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override-gitlab: a bundled override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] \
    || fail "bundled-repo-override-gitlab: glab was invoked despite the bundled override"

  case_dir=$(make_case bundled-non-repo-cluster)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -x \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-non-repo-cluster: a non-allowlisted short option should refuse"
  assert_grep 'refusing extra merge argument -x because an unbounded passthrough cannot guarantee immediate execution' "$case_dir/stderr" \
    "bundled-non-repo-cluster: refusal did not name the short option"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "bundled-non-repo-cluster: non-allowlisted short option reached the forge"
  pass "fm-pr-merge refuses non-allowlisted short arguments before recording"
}

test_explicit_merge_method_not_overridden() {
  local case_dir head
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  grep -qxF "pr merge 22 --repo example/repo --match-head-commit $head --merge" "$case_dir/gh.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir head
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  grep -qxF "pr merge 23 --repo example/repo --match-head-commit $head --merge" "$case_dir/gh.log" \
    || fail "method-equals-merge-method: caller --method=merge was not translated without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir head
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  grep -qxF "pr merge 126 --repo my-org/my-repo --match-head-commit $head --squash" "$case_dir/gh.log" \
    || fail "url-parsing: gh pr merge was not addressed and head-bound from the URL"
  pass "fm-pr-merge parses a GitHub URL into repository and head-bound merge arguments"
}

test_open_recorded_issue_is_closed_after_merge() {
  local case_dir url
  case_dir=$(make_case issue-open)
  url=https://github.com/example/repo/pull/31
  printf 'issue=42\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_open_then_closed "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "issue-open: merge reconciliation failed"

  grep -qxF "issue close 42 --repo example/repo --reason completed --comment Closed after merge of $url." "$case_dir/gh-axi.log" \
    || fail "issue-open: recorded issue was not closed with the merged PR URL"
  [ "$(grep -c '^issue view 42 --repo example/repo --full$' "$case_dir/gh-axi.log")" -eq 2 ] \
    || fail "issue-open: issue state was not verified before and after closing"
  pass "fm-pr-merge closes an open recorded issue and verifies the close"
}

test_already_closed_recorded_issue_is_left_alone() {
  local case_dir
  case_dir=$(make_case issue-closed)
  printf 'issue=43\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_closed "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "issue-closed: merge reconciliation failed"

  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "issue-closed: already-closed issue received a redundant close call"
  grep -qxF 'issue view 43 --repo example/repo --full' "$case_dir/gh-axi.log" \
    || fail "issue-closed: recorded issue was not verified"
  pass "fm-pr-merge leaves an already-closed recorded issue alone"
}

test_issue_close_failure_keeps_merge_success_unambiguous() {
  local case_dir rc
  case_dir=$(make_case issue-close-fails)
  printf 'issue=44\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_close_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "issue-close-fails: a completed merge must remain successful"
  assert_grep 'warning: PR merge succeeded: https://github.com/example/repo/pull/33' "$case_dir/stderr" \
    "issue-close-fails: warning did not make the successful merge explicit"
  assert_grep 'could not close example/repo#44' "$case_dir/stderr" \
    "issue-close-fails: warning did not identify the failed bookkeeping"
  pass "fm-pr-merge reports issue-close failure without making a completed merge retryable"
}

test_no_recorded_issue_makes_no_issue_calls() {
  local case_dir head
  case_dir=$(make_case no-issue)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "no-issue: merge failed"

  assert_no_grep 'issue ' "$case_dir/gh-axi.log" \
    "no-issue: merge path made an issue API call without recorded issue metadata"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  grep -qxF "pr merge 34 --repo example/repo --match-head-commit $head --squash" "$case_dir/gh.log" \
    || fail "no-issue: ordinary merge invocation changed"
  pass "fm-pr-merge preserves the ordinary path when no issue is recorded"
}

test_issue_verification_failure_keeps_merge_success_unambiguous() {
  local case_dir rc
  case_dir=$(make_case issue-view-fails)
  printf 'issue=45\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "issue-view-fails: a completed merge must remain successful"
  assert_grep 'warning: PR merge succeeded: https://github.com/example/repo/pull/35' "$case_dir/stderr" \
    "issue-view-fails: warning did not make the successful merge explicit"
  assert_grep 'could not verify example/repo#45' "$case_dir/stderr" \
    "issue-view-fails: warning did not identify the failed verification"
  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "issue-view-fails: close was attempted without verifying the issue state"
  pass "fm-pr-merge reports issue verification failure without making a completed merge retryable"
}

test_issue_still_open_after_close_request_warns() {
  local case_dir rc
  case_dir=$(make_case issue-stays-open)
  printf 'issue=46\n' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_stays_open "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/36 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "issue-stays-open: a completed merge must remain successful"
  [ "$(grep -c '^issue view 46 --repo example/repo --full$' "$case_dir/gh-axi.log")" -eq 2 ] \
    || fail "issue-stays-open: issue state was not checked before and after closing"
  assert_grep 'example/repo#46 is still not closed after the close request' "$case_dir/stderr" \
    "issue-stays-open: post-close verification failure was not loud"
  pass "fm-pr-merge warns when an issue remains open after a successful close request"
}

test_invalid_recorded_issue_metadata_warns_without_issue_calls() {
  local case_dir rc name expected
  for name in malformed duplicate; do
    case_dir=$(make_case "issue-metadata-$name")
    case "$name" in
      malformed)
        printf 'issue=abc\n' >> "$case_dir/state/task-x1.meta"
        expected='recorded issue identity is malformed'
        ;;
      duplicate)
        printf 'issue=47\nissue=48\n' >> "$case_dir/state/task-x1.meta"
        expected='task metadata has multiple recorded issues'
        ;;
    esac
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    : > "$case_dir/gh-axi.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/37 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" "issue-metadata-$name: a completed merge must remain successful"
    assert_grep "$expected" "$case_dir/stderr" \
      "issue-metadata-$name: invalid metadata warning was not explicit"
    assert_no_grep 'issue ' "$case_dir/gh-axi.log" \
      "issue-metadata-$name: issue API was called with invalid metadata"
  done
  pass "fm-pr-merge warns on malformed or duplicate recorded issue metadata without making API calls"
}

test_work_item_closes_in_its_declared_repository_not_the_pr_repository() {
  local case_dir url
  case_dir=$(make_case work-item-declared)
  url=https://github.com/example/repo/pull/51
  printf 'work_item=declared|github|https://github.com/HelloWorldSungin/ark-robinhood/issues/42\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_open_then_closed "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "work-item-declared: merge reconciliation failed"

  grep -qxF "issue close 42 --repo HelloWorldSungin/ark-robinhood --reason completed --comment Closed after merge of $url." \
    "$case_dir/gh-axi.log" \
    || fail "work-item-declared: the work item was not closed in its own declared repository"
  assert_no_grep '--repo example/repo --reason' "$case_dir/gh-axi.log" \
    "work-item-declared: the close was addressed to the PR's repository instead of the declared tracker"
  [ "$(grep -c '^issue view 42 --repo HelloWorldSungin/ark-robinhood --full$' "$case_dir/gh-axi.log")" -eq 2 ] \
    || fail "work-item-declared: issue state was not verified in the declared repository before and after closing"
  pass "fm-pr-merge closes a work item in its declared repository, not the PR's"
}

test_gitea_work_item_without_credential_is_reported_not_closed() {
  local case_dir rc
  case_dir=$(make_case work-item-gitea)
  printf 'work_item=declared|gitea|https://gitea.example.com/DuckKingOri/BZ-SIM/issues/7\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "work-item-gitea: a completed merge must remain successful"
  assert_grep 'holds no write credential for gitea.example.com' "$case_dir/stderr" \
    "work-item-gitea: the missing credential was not reported as exactly that"
  assert_grep 'https://gitea.example.com/DuckKingOri/BZ-SIM/issues/7' "$case_dir/stderr" \
    "work-item-gitea: the warning did not carry the plain link"
  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "work-item-gitea: a non-GitHub work item reached the GitHub close path"
  pass "fm-pr-merge reports a credential-less gitea work item instead of closing it"
}

# The curl mock a gitea close talks to: an issue whose state is kept on disk, a
# comment endpoint recording the linking comment, and the argv/stdin logs the
# credential assertions read. It reads stdin only when `-K` is present, exactly
# as real curl takes its config from stdin.
add_gitea_close_mocks() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
STORE=${FM_TEST_GITEA_STORE:?curl mock needs FM_TEST_GITEA_STORE}
mkdir -p "$STORE"
printf '%s\n' "$*" >> "$STORE/curl-args.log"
METHOD=GET
OUT=/dev/null
DATA=
URL=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -K) cat >> "$STORE/curl-stdin.log" ;;
    -X) METHOD=$2; shift ;;
    -o) OUT=$2; shift ;;
    --data-binary) DATA=${2#@}; shift ;;
    -H|-w|-m) shift ;;
    https://*) URL=$1 ;;
  esac
  shift
done
[ -z "${FM_TEST_GITEA_UNREACHABLE:-}" ] || exit 7
emit() {  # <http-code> <body>
  printf '%s' "$2" > "$OUT"
  printf '%s' "$1"
  exit 0
}
[ -z "${FM_TEST_GITEA_HTTP:-}" ] || emit "$FM_TEST_GITEA_HTTP" '{"message":"refused"}'
case "$METHOD $URL" in
  "GET "*/issues/7)
    state=open
    [ ! -f "$STORE/issue-state" ] || state=$(cat "$STORE/issue-state")
    emit 200 "{\"state\":\"$state\"}"
    ;;
  "PATCH "*/issues/7)
    jq -r '.state' "$DATA" > "$STORE/issue-state"
    printf 'CLOSE\n' >> "$STORE/ops.log"
    emit 201 '{"state":"closed"}'
    ;;
  "POST "*/issues/7/comments)
    jq -r '.body' "$DATA" > "$STORE/close-comment"
    printf 'COMMENT\n' >> "$STORE/ops.log"
    emit 201 '{"id":1}'
    ;;
esac
emit 404 '{}'
SH
  chmod +x "$case_dir/fakebin/curl"
  mkdir -p "$case_dir/config/forge-tokens" "$case_dir/gitea-store"
  printf 'gitea-close-token\n' > "$case_dir/config/forge-tokens/gitea.example.com"
  chmod 600 "$case_dir/config/forge-tokens/gitea.example.com"
}

test_gitea_work_item_is_closed_with_its_own_credential() {
  local case_dir url rc
  command -v jq >/dev/null 2>&1 || { pass "gitea close (skipped: jq absent)"; return; }
  case_dir=$(make_case work-item-gitea-close)
  url=https://github.com/example/repo/pull/54
  printf 'work_item=declared|gitea|https://gitea.example.com/DuckKingOri/BZ-SIM/issues/7\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  add_gitea_close_mocks "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_GITEA_STORE="$case_dir/gitea-store" \
    run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitea-close: the merge with a gitea work item failed"
  assert_grep 'pr merge 54 --repo example/repo --match-head-commit' "$case_dir/gh.log" \
    "gitea-close: the PR was never merged"
  [ "$(cat "$case_dir/gitea-store/issue-state" 2>/dev/null)" = closed ] \
    || fail "gitea-close: the gitea issue was not closed"
  assert_grep "Closed after merge of $url." "$case_dir/gitea-store/close-comment" \
    "gitea-close: the close did not carry the linking comment"
  assert_grep 'COMMENT' "$case_dir/gitea-store/ops.log" \
    "gitea-close: the linking comment was never posted"
  assert_no_grep 'issue close' "$case_dir/gh-axi.log" \
    "gitea-close: the close was retargeted at the GitHub client"
  assert_no_grep 'gitea-close-token' "$case_dir/gitea-store/curl-args.log" \
    "gitea-close: the credential appeared in curl's process arguments"
  assert_grep 'gitea-close-token' "$case_dir/gitea-store/curl-stdin.log" \
    "gitea-close: the credential did not travel through curl's stdin config"
  pass "fm-pr-merge closes a gitea work item with its own credential and the linking comment"
}

test_gitea_close_failure_keeps_merge_success_unambiguous() {
  local case_dir rc
  command -v jq >/dev/null 2>&1 || { pass "gitea close failure (skipped: jq absent)"; return; }
  case_dir=$(make_case work-item-gitea-down)
  printf 'work_item=declared|gitea|https://gitea.example.com/DuckKingOri/BZ-SIM/issues/7\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca
  add_gitea_close_mocks "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_GITEA_STORE="$case_dir/gitea-store" FM_TEST_GITEA_UNREACHABLE=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitea-down: an unreachable gitea host made a completed merge look retryable"
  assert_grep 'pr merge 56 --repo example/repo --match-head-commit' "$case_dir/gh.log" \
    "gitea-down: the merge did not happen while the tracker was unreachable"
  assert_grep 'issue bookkeeping did not complete' "$case_dir/stderr" \
    "gitea-down: the failed close was silent"
  pass "an unreachable gitea host warns and the completed merge still stands"
}

test_gitea_verification_failure_names_its_own_reason() {
  local case_dir rc
  command -v jq >/dev/null 2>&1 || { pass "gitea verify reason (skipped: jq absent)"; return; }
  case_dir=$(make_case work-item-gitea-403)
  printf 'work_item=declared|gitea|https://gitea.example.com/DuckKingOri/BZ-SIM/issues/7\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  add_gitea_close_mocks "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_GITEA_STORE="$case_dir/gitea-store" FM_TEST_GITEA_HTTP=403 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitea-403: a refused credential made a completed merge look retryable"
  assert_grep 'pr merge 58 --repo example/repo --match-head-commit' "$case_dir/gh.log" \
    "gitea-403: the merge did not happen while the tracker refused the credential"
  assert_grep 'could not verify' "$case_dir/stderr" \
    "gitea-403: the failed verification was silent"
  assert_grep 'HTTP 403' "$case_dir/stderr" \
    "gitea-403: the warning did not name the forge's answer"
  assert_grep 'refused the credential' "$case_dir/stderr" \
    "gitea-403: a refused credential was not attributed to the credential"
  pass "a work item that cannot be verified says why, rather than only that it could not be"
}

test_gitea_empty_credential_is_reported_as_present_not_absent() {
  local case_dir rc
  case_dir=$(make_case work-item-gitea-empty)
  printf 'work_item=declared|gitea|https://gitea.example.com/DuckKingOri/BZ-SIM/issues/7\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt" "$case_dir/config/forge-tokens"
  : > "$case_dir/config/forge-tokens/gitea.example.com"
  chmod 600 "$case_dir/config/forge-tokens/gitea.example.com"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/60 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitea-empty: a completed merge must remain successful"
  assert_grep 'present but empty' "$case_dir/stderr" \
    "gitea-empty: an empty credential file was not reported as the empty file it is"
  assert_no_grep 'is absent' "$case_dir/stderr" \
    "gitea-empty: a credential file that is right there was reported as absent"
  pass "fm-pr-merge tells an empty credential file apart from a missing one"
}

test_self_hosted_github_work_item_is_reported_not_closed() {
  local case_dir rc
  case_dir=$(make_case work-item-self-hosted-github)
  printf 'work_item=declared|github|https://ghe.example.com/o/r/issues/5\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "work-item-self-hosted-github: a completed merge must remain successful"
  assert_grep 'GitHub host ghe.example.com' "$case_dir/stderr" \
    "work-item-self-hosted-github: the unsupported host was not reported"
  assert_grep 'https://ghe.example.com/o/r/issues/5' "$case_dir/stderr" \
    "work-item-self-hosted-github: the warning did not preserve the work-item link"
  assert_no_grep '^issue ' "$case_dir/gh-axi.log" \
    "work-item-self-hosted-github: the self-hosted issue was retargeted at github.com"
  pass "fm-pr-merge reports a self-hosted GitHub work item without retargeting it"
}

test_invalid_or_multiple_work_items_warn_without_issue_calls() {
  local case_dir rc name expected
  for name in malformed multiple; do
    case_dir=$(make_case "work-item-$name")
    case "$name" in
      malformed)
        printf 'work_item=declared|github|not-a-url\n' >> "$case_dir/state/task-x1.meta"
        expected='recorded work item is malformed'
        ;;
      multiple)
        printf 'work_item=declared|github|https://github.com/a/b/issues/1\n' \
          >> "$case_dir/state/task-x1.meta"
        printf 'work_item=declared|github|https://github.com/c/d/issues/2\n' \
          >> "$case_dir/state/task-x1.meta"
        expected='records several work items'
        ;;
    esac
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
    : > "$case_dir/gh-axi.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" "work-item-$name: a completed merge must remain successful"
    assert_grep "$expected" "$case_dir/stderr" \
      "work-item-$name: the warning was not explicit"
    assert_no_grep 'issue ' "$case_dir/gh-axi.log" \
      "work-item-$name: the issue API was called despite unusable work-item metadata"
  done
  pass "fm-pr-merge warns on malformed or multiple work items without making API calls"
}

test_work_item_record_wins_over_legacy_issue_line() {
  local case_dir url
  case_dir=$(make_case work-item-precedence)
  url=https://github.com/example/repo/pull/54
  printf 'issue=99\n' >> "$case_dir/state/task-x1.meta"
  printf 'work_item=declared|github|https://github.com/HelloWorldSungin/ark-robinhood/issues/42\n' \
    >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/wt"
  add_gh_mocks_issue_open_then_closed "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "work-item-precedence: merge reconciliation failed"

  grep -qxF "issue close 42 --repo HelloWorldSungin/ark-robinhood --reason completed --comment Closed after merge of $url." \
    "$case_dir/gh-axi.log" \
    || fail "work-item-precedence: the declared work item was not the close target"
  assert_no_grep 'issue close 99' "$case_dir/gh-axi.log" \
    "work-item-precedence: the legacy bare number was closed instead of the declared work item"
  pass "fm-pr-merge prefers a declared work item over a legacy bare issue number"
}

test_refresh_failure_warning_names_the_cause() {
  local case_dir rc
  case_dir=$(make_case refresh-cause)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "refresh-cause: a failed cache refresh must not fail the merge"
  assert_grep 'the cached PR state could not be refreshed: ' "$case_dir/stderr" \
    "refresh-cause: the warning did not fold in the cause the refresh named"
  assert_grep 'exited 0' "$case_dir/stderr" \
    "refresh-cause: the operator-visible line did not say the CLI exited 0"
  assert_grep 'non-JSON' "$case_dir/stderr" \
    "refresh-cause: the operator-visible line did not say the body was not JSON"
  [ "$(grep -c 'the cached PR state could not be refreshed' "$case_dir/stderr")" = 1 ] \
    || fail "refresh-cause: the refresh warning was emitted more than once"
  pass "a failed post-merge refresh warns with the cause, not only the symptom"
}

test_refresh_reason_is_bounded_to_one_line() {
  local long normalized
  [ -z "$(fm_pr_reason_normalize '')" ] \
    || fail "reason-normalize: empty stderr must produce an empty reason"
  [ -z "$(fm_pr_reason_normalize "$(printf '\n  \n\t')")" ] \
    || fail "reason-normalize: whitespace-only stderr must produce an empty reason"
  [ "$(fm_pr_reason_normalize "$(printf '  first line\nsecond   line  \n')")" \
    = 'first line second line' ] \
    || fail "reason-normalize: multi-line stderr was not collapsed to one trimmed line"
  long=$(printf 'x%.0s' $(seq 1 $((FM_PR_REASON_MAX + 40))))
  normalized=$(fm_pr_reason_normalize "$long")
  [ "${#normalized}" -eq "$((FM_PR_REASON_MAX + 3))" ] \
    || fail "reason-normalize: an overlong reason was not truncated to the bound"
  case "$normalized" in
    *...) ;;
    *) fail "reason-normalize: a truncated reason did not say it was truncated" ;;
  esac
  pass "a captured cause is collapsed to one trimmed, bounded line"
}

test_gitlab_url_resolves_and_merges() {
  local case_dir head rc merge_line
  case_dir=$(make_gitlab_case gitlab-merges)
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-merges: a well-formed merge request URL should merge, not error"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merges: pr= was not recorded before merging"
  assert_grep "GITLAB_HOST=$MR_HOST api graphql -f fullPath=$MR_PATH -f iid=7 -f targetRef=main" "$case_dir/glab.log" \
    "gitlab-merges: the pre-merge state was not read from the project URL"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $head --yes --auto-merge=false" ] \
    || fail "gitlab-merges: unexpected merge invocation: '$merge_line'"
  assert_grep "successful pipeline at head $head" "$case_dir/stderr" \
    "gitlab-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "gitlab-merges: a merge request reached the GitHub CLI"
  pass "fm-pr-merge merges a GitLab merge request through glab instead of refusing it"
}

test_gitlab_host_comes_from_the_url() {
  local case_dir rc host path project_url url
  host=gl.self-hosted.example
  path=deep/nested/group/project
  project_url="https://$host/$path"
  url="$project_url/-/merge_requests/31"
  case_dir=$(make_gitlab_case gitlab-host-from-url)

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-host-from-url: a self-hosted merge request should merge"
  assert_grep "GITLAB_HOST=$host api graphql -f fullPath=$path -f iid=31 -f targetRef=main" "$case_dir/glab.log" \
    "gitlab-host-from-url: the read did not use the host from the URL"
  assert_grep "GITLAB_HOST=$host mr merge 31 -R $project_url" "$case_dir/glab.log" \
    "gitlab-host-from-url: the merge did not use the host from the URL"
  assert_no_grep 'gitlab.com' "$case_dir/glab.log" \
    "gitlab-host-from-url: a host was assumed instead of taken from the URL"
  assert_no_grep '<unset>' "$case_dir/glab.log" \
    "gitlab-host-from-url: glab was left to resolve the instance from its own default"
  pass "fm-pr-merge takes the GitLab instance from the URL rather than assuming one"
}

test_gitlab_imposes_no_merge_method() {
  local case_dir rc merge_line flag
  case_dir=$(make_gitlab_case gitlab-no-method)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-no-method: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  for flag in --squash --rebase --merge --method; do
    case "$merge_line" in
      *"$flag"*) fail "gitlab-no-method: '$flag' was imposed on GitLab: '$merge_line'" ;;
    esac
  done
  pass "fm-pr-merge imposes no merge method on GitLab, leaving the project's own one"
}

test_gitlab_allowlisted_args_forwarded() {
  local case_dir head rc merge_line
  case_dir=$(make_gitlab_case gitlab-extra-args)
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- \
    --rebase -r --message guarded-merge --squash-message=base-checked \
    --remove-source-branch -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-extra-args: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $head --yes --auto-merge=false --rebase -r --message guarded-merge --squash-message=base-checked --remove-source-branch -d" ] \
    || fail "gitlab-extra-args: allowlisted glab arguments were not forwarded: '$merge_line'"
  pass "fm-pr-merge forwards allowlisted GitLab method, message, and cleanup arguments"
}

test_gitlab_automatic_rebase_setting_refuses_and_unknown_fails_closed() {
  local case_dir expected name rc
  for name in enabled unknown; do
    case_dir=$(make_gitlab_case "gitlab-auto-rebase-$name")
    case "$name" in
      enabled)
        printf '{"automatic_rebase_enabled":true}\n' >"$case_dir/project.json"
        expected='GitLab project setting automatic_rebase_enabled is enabled'
        ;;
      unknown)
        : >"$case_dir/glab-project-fails"
        expected='GitLab project setting automatic_rebase_enabled could not be determined'
        ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-auto-rebase-$name: fm-pr-merge should refuse"
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-auto-rebase-$name: refusal did not name the project setting"
    assert_grep 'action: bring the branch up to current main and re-run validation' \
      "$case_dir/stderr" \
      "gitlab-auto-rebase-$name: refusal did not name the required recovery"
    assert_no_grep ' mr merge ' "$case_dir/glab.log" \
      "gitlab-auto-rebase-$name: unsafe project setting reached merge"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "gitlab-auto-rebase-$name: refusal disarmed the durable poll"
  done
  pass "GitLab automatic rebase is rejected and unknown state fails closed"
}

test_gitlab_merge_failure_propagates() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-merge-fails)
  : > "$case_dir/glab-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-merge-fails: a failing glab merge should not report success"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merge-fails: pr= should already be recorded even though the merge failed"
  pass "fm-pr-merge propagates a real glab merge failure without silently succeeding"
}

test_gitlab_each_condition_refuses_independently() {
  local case_dir head rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "detail|detail=need_rebase|detailed_merge_status is \"need_rebase\", not mergeable" \
    "conflicts|conflicts=true|has_conflicts is \"true\", not false" \
    "discussions|discussions=false|blocking_discussions_resolved is \"false\", not true" \
    "pipeline-status|pipeline_status=failed|the head pipeline status is \"failed\", not success" \
    "pipeline-sha|pipeline_sha=$MR_STALE_HEAD|the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head __TASK_HEAD__" \
    "no-pipeline|pipeline=null|the head pipeline status is \"none\", not success"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_gitlab_case "gitlab-refuse-$name" "${spec%%|*}")
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    expected=${expected//__TASK_HEAD__/$head}

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $MR_URL" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the merge request"
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the failing condition"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "gitlab-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each GitLab pre-merge condition independently"
}

test_gitlab_reports_every_failing_condition() {
  local case_dir head rc expected
  case_dir=$(make_gitlab_case gitlab-refuse-all \
    state=closed detail=conflict conflicts=true discussions=false \
    pipeline_status=failed "pipeline_sha=$MR_STALE_HEAD")
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refuse-all: fm-pr-merge should refuse"
  for expected in \
    'state is "closed", not open' \
    'detailed_merge_status is "conflict", not mergeable' \
    'has_conflicts is "true", not false' \
    'blocking_discussions_resolved is "false", not true' \
    'the head pipeline status is "failed", not success' \
    "the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $head"
  do
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-all: '$expected' was not reported"
  done
  pass "fm-pr-merge reports every failing GitLab condition, not only the first"
}

test_gitlab_stale_recorded_head_is_reported() {
  local case_dir head rc merge_line
  case_dir=$(make_gitlab_case gitlab-stale-head)
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a GitLab task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$MR_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $MR_STALE_HEAD disagrees with the live head $head" \
    "$case_dir/stderr" "gitlab-stale-head: the stale recorded head was trusted silently"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *"--sha $head"*) : ;;
    *) fail "gitlab-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$MR_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "gitlab-stale-head: the recording step no longer drops an unresolvable GitLab head"
  pass "fm-pr-merge reports a stale recorded head and verifies the live one"
}

test_gitlab_unreadable_state_refuses() {
  local case_dir rc name
  for name in view-fails not-an-object split-value; do
    case_dir=$(make_gitlab_case "gitlab-unreadable-$name")
    case "$name" in
      view-fails) : > "$case_dir/glab-view-fails" ;;
      not-an-object) printf '[]\n' > "$case_dir/mr.json" ;;
      # A value carrying a newline splits into a line no field name matches, so
      # it must refuse rather than be truncated into a value a check accepts.
      split-value) write_mr_json "$case_dir/mr.json" 'state=opened\nnot-a-field' ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-unreadable-$name: fm-pr-merge should refuse"
    assert_grep 'could not read the GitLab merge request state before merging' \
      "$case_dir/stderr" "gitlab-unreadable-$name: refusal did not name the unreadable state"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-unreadable-$name: a merge was attempted on an unreadable state"
  done
  pass "fm-pr-merge refuses an unreadable GitLab merge request state rather than merging blind"
}

test_gitlab_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the GitLab merge request head commit before merging' \
    "$case_dir/stderr" "gitlab-invalid-head: refusal did not name the unreadable head"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a GitLab head commit it cannot validate"
}

test_gitlab_live_head_mismatch_reinspects_and_refuses() {
  local case_dir rc views
  case_dir=$(make_gitlab_case gitlab-live-head-mismatch \
    "head=$MR_STALE_HEAD" "pipeline_sha=$MR_STALE_HEAD")

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-live-head-mismatch: repeated mismatch should refuse"
  views=$(grep -c -F ' api graphql ' "$case_dir/glab.log")
  [ "$views" -ge 2 ] \
    || fail "gitlab-live-head-mismatch: the changed live head was not re-read after reinspection"
  assert_grep 're-inspecting the live head' "$case_dir/stderr" \
    "gitlab-live-head-mismatch: mismatch did not trigger reinspection"
  assert_grep 'head changed repeatedly during validation' "$case_dir/stderr" \
    "gitlab-live-head-mismatch: repeated mismatch was not refused explicitly"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-live-head-mismatch: an uninspected live head reached merge"
  pass "GitLab re-inspects a moved head and refuses repeated identity changes"
}

test_gitlab_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in glab jq; do
    if [ "$tool" = glab ]; then other=jq; else other=glab; fi
    case_dir=$(make_gitlab_case "gitlab-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    # One tool absent, the other still answered by this case's own mock, so the
    # refusal names exactly one tool on a host that ships neither.
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "gitlab-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$case_dir/glab.log" \
    FM_TEST_GLAB_JSON="$case_dir/mr.json" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a GitLab merge request requires $tool on PATH" \
      "$case_dir/stderr" "gitlab-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when glab or jq is absent"
}

test_gitlab_head_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-head-override)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --sha "$MR_STALE_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-head-override: fm-pr-merge should refuse a caller head override"
  assert_grep 'refusing extra merge argument --sha because an unbounded passthrough cannot guarantee immediate execution' "$case_dir/stderr" \
    "gitlab-head-override: refusal did not explain why passthrough is unsafe"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-head-override: the URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-head-override: a head override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-head-override: glab was invoked despite the head override"
  pass "fm-pr-merge refuses a GitLab head override before recording state"
}

test_github_head_override_args_refuse_before_recording() {
  local case_dir arg rc
  for arg in --sha --match-head-commit; do
    case_dir=$(make_case "github-head-override-${arg#--}")
    add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- "$arg" abc123 \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-head-override: $arg should refuse"
    assert_grep "refusing extra merge argument $arg because an unbounded passthrough cannot guarantee immediate execution" "$case_dir/stderr" \
      "github-head-override: $arg refusal was unexplained"
    assert_no_grep 'pr=https://github.com/example/repo/pull/44' "$case_dir/state/task-x1.meta" \
      "github-head-override: $arg was rejected after recording"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-head-override: $arg reached the forge"
  done
  pass "fm-pr-merge reserves GitHub head binding to its inspected commit"
}


# --- durable merge outcome ---------------------------------------------------
# A merge that lands must leave a record outside the merging agent's memory.
# bin/fm-merge-outcome-lib.sh owns where that record goes; these cases pin the
# behavior through the real merge entrypoint.

# make_home_case <name> [<route> [<parent-home>]]: a case dir whose home is a
# secondmate home bound to a parent, or a plain main home when no route is
# given. Echoes the case dir; the home is "$case_dir/home".
make_home_case() {
  local name=$1 route=${2:-} parent=${3:-} case_dir home
  case_dir=$(make_case "$name")
  home="$case_dir/home"
  mkdir -p "$home" "$case_dir/wt"
  if [ -n "$route" ]; then
    printf '%s\n' mate-x >"$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=%s\n' "$route"
      [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
    } >"$home/.fm-secondmate-parent"
  fi
  printf '%s\n' "$case_dir"
}

parent_reply_lines() {  # <file> <url>
  grep -c -F "$2" "$1" 2>/dev/null || true
}

test_secondmate_merge_reports_upward_once() {
  local advanced case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$replies" \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(wc -l <"$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward line"

  advanced=$(prepare_advanced_default "$case_dir")
  git --git-dir="$case_dir/origin.git" update-ref refs/heads/main "$advanced"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  [ "$(grep -c -F 'pr merge 61 ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "secondmate-merge-reports: an already merged PR invoked the forge merge again"
  pass "a merge a secondmate home performs itself is reported upward exactly once"
}

test_secondmate_merge_reports_on_the_local_route() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/62
  case_dir=$(make_home_case secondmate-merge-local local "$TMP_ROOT/secondmate-merge-local/parent")
  mkdir -p "$TMP_ROOT/secondmate-merge-local/parent/state"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : >"$case_dir/gh-axi.log"
  parent_status="$TMP_ROOT/secondmate-merge-local/parent/state/mate-x.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-local: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$parent_status" \
    "secondmate-merge-local: the landed PR did not reach the parent home's channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "secondmate-merge-local: a local-route report also wrote the remote reply channel"
  pass "a locally routed secondmate home reports the landed PR into its parent's own channel"
}

test_failed_merge_reports_nothing() {
  local case_dir rc
  case_dir=$(make_home_case failed-merge-silent remote)
  add_gh_mocks_merge_fails "$case_dir"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  assert_absent "$case_dir/state/parent-replies.status" \
    "failed-merge-silent: a merge that never landed was reported as landed"
  pass "a refused or failed merge reports no outcome"
}

test_gitlab_refusal_reports_nothing() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-refusal-silent state=merged)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refusal-silent: a refused GitLab merge should exit non-zero"
  assert_absent "$case_dir/state/parent-replies.status" \
    "gitlab-refusal-silent: a refused merge request was reported as landed"
  pass "a GitLab merge refused before the forge call reports no outcome"
}

test_gitlab_merge_reports_upward() {
  local case_dir url
  case_dir=$(make_gitlab_case gitlab-merge-reports)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"
  url=$MR_URL

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "gitlab-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    "$case_dir/state/parent-replies.status" \
    "gitlab-merge-reports: a landed merge request was not reported upward"
  pass "a landed GitLab merge request is reported upward on the same channel"
}

test_queued_gitlab_merge_is_refused_and_leaves_the_poll_armed() {
  local case_dir rc
  case_dir=$(make_gitlab_case queued-gitlab-merge)
  mkdir -p "$case_dir/home"
  : >"$case_dir/glab-stays-open"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "queued-gitlab-merge: a deferred result should refuse"
  assert_grep 'GitLab left it queued or pending instead of executing immediately' "$case_dir/stderr" \
    "queued-gitlab-merge: refusal did not name the deferred GitLab result"
  [ -n "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "queued-gitlab-merge: the fixture never reached the post-command state check"
  assert_absent "$case_dir/state/.wake-queue" \
    "queued-gitlab-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-gitlab-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-gitlab-merge: a queued merge was marked as reported"
  pass "a queued GitLab merge is refused and leaves its durable poll armed"
}

test_main_home_merge_leaves_a_durable_wake() {
  local case_dir url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_home_case main-merge-wake)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "main-merge-wake: merge failed"

  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "main-merge-wake: a merge this home performed left no durable record naming the PR"
  [ "$(grep -c -F "$url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "main-merge-wake: one merge produced more than one durable record"
  assert_absent "$case_dir/state/parent-replies.status" \
    "main-merge-wake: a main home wrote a parent reply channel it does not have"
  pass "a merge a main home performs itself leaves one durable wake naming the PR"
}

test_queued_github_merge_is_refused_and_leaves_the_poll_armed() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_GH_POST_STATE=OPEN FM_TEST_GH_POST_IN_QUEUE=true \
    FM_TEST_GH_POST_QUEUE_ENTRY=QUEUED FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "queued-github-merge: a deferred result should refuse"
  assert_grep 'GitHub queued it for deferred execution on target branch main' "$case_dir/stderr" \
    "queued-github-merge: refusal did not name the GitHub merge queue"
  assert_grep 'pr merge 66 ' "$case_dir/gh.log" \
    "queued-github-merge: the fixture never reached the post-command state check"
  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge is refused and leaves its durable poll armed"
}

test_unknown_github_post_merge_state_is_nonretryable() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/71
  case_dir=$(make_case unknown-github-post-merge)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  set +e
  FM_TEST_GH_POST_STATE_UNAVAILABLE=1 \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unknown-github-post-merge: an accepted mutation should not look retryable"
  assert_grep "GitHub accepted the merge request for $url but its landed state could not be confirmed" \
    "$case_dir/stderr" \
    "unknown-github-post-merge: unknown outcome was not actionable"
  assert_grep 'pr merge 71 ' "$case_dir/gh.log" \
    "unknown-github-post-merge: the fixture did not reach the forge mutation"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "unknown-github-post-merge: unknown outcome retired the durable poll"
  assert_absent "$case_dir/state/.wake-queue" \
    "unknown-github-post-merge: unknown outcome was reported as landed"
  pass "an unknown GitHub post-merge state is nonretryable and remains polled"
}

test_unknown_gitlab_post_merge_state_is_nonretryable() {
  local case_dir rc
  case_dir=$(make_gitlab_case unknown-gitlab-post-merge)
  : >"$case_dir/glab-post-view-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unknown-gitlab-post-merge: an accepted mutation should not look retryable"
  assert_grep "GitLab accepted the merge request for $MR_URL but its landed state could not be confirmed" \
    "$case_dir/stderr" \
    "unknown-gitlab-post-merge: unknown outcome was not actionable"
  [ -n "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "unknown-gitlab-post-merge: the fixture did not reach the forge mutation"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "unknown-gitlab-post-merge: unknown outcome retired the durable poll"
  assert_absent "$case_dir/state/.wake-queue" \
    "unknown-gitlab-post-merge: unknown outcome was reported as landed"
  pass "an unknown GitLab post-merge state is nonretryable and remains polled"
}

test_distinct_merged_prs_keep_distinct_wakes() {
  local case_dir first_url second_url
  first_url=https://github.com/example/repo/pull/68
  second_url=https://github.com/example/repo/pull/69
  case_dir=$(make_home_case distinct-merge-wakes)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$first_url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "distinct-merge-wakes: first merge failed"
  rm -f "$case_dir/state/task-x1.check.sh" \
    "$case_dir/state/task-x1.pr-poll" \
    "$case_dir/state/task-x1.pr-poll-registration"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$second_url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "distinct-merge-wakes: second merge failed"

  [ "$(grep -c -F "$first_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: first merge wake was missing or duplicated"
  [ "$(grep -c -F "$second_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: second merge wake was missing or duplicated"
  FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-wake-drain.sh" \
    >"$case_dir/drain.out" 2>"$case_dir/drain.err" \
    || fail "distinct-merge-wakes: wake drain failed"
  assert_grep "$first_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the first PR"
  assert_grep "$second_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the second PR"
  pass "distinct merged PRs for one task retain distinct captain-facing wakes"
}

test_uncommitted_marker_retry_is_never_silent() {
  local case_dir url count
  url=https://github.com/example/repo/pull/67
  case_dir=$(make_home_case uncommitted-wake-retry)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : >"$case_dir/gh-axi.log"
  cat >"$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.pr-poll-merge-notified)
    if mkdir "$FM_TEST_MARKER_FAILURE.claim" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  export FM_TEST_MARKER_FAILURE="$case_dir/marker-failure"
  export FM_TEST_REAL_MV
  FM_TEST_REAL_MV=$(command -v mv)

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "uncommitted-wake-retry: landed merge was reported as failed"
  assert_grep 'could not record the outcome' "$case_dir/stderr-1" \
    "uncommitted-wake-retry: failed marker commit was not loud"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "uncommitted-wake-retry: failed commit disarmed the retry poll"
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: failed marker commit lost the durable outcome"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: failed marker commit was treated as complete"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "uncommitted-wake-retry: retry failed"
  unset FM_TEST_MARKER_FAILURE FM_TEST_REAL_MV
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: retry left the merge silent"
  [ -f "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: retry did not commit the canonical marker"
  pass "an uncommitted marker retry preserves at least one durable outcome"
}

test_secondmate_without_parent_binding_is_loud() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/65
  case_dir=$(make_home_case unbound-secondmate)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : >"$case_dir/gh-axi.log"
  # A secondmate identity with no parent binding: exactly the seeding gap that
  # let three real merges land in silence.
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unbound-secondmate: the merge itself landed and must not be reported as failed"
  assert_grep 'could not report it upward' "$case_dir/stderr" \
    "unbound-secondmate: a merge that could not be reported upward said nothing about it"
  assert_absent "$case_dir/state/.wake-queue" \
    "unbound-secondmate: a secondmate home fell back to the main-home record"
  pass "a secondmate home that cannot report upward says so instead of merging in silence"
}

test_records_pr_and_head_before_merging
test_stale_pr_refuses_before_merging
test_pathspec_magic_filename_cannot_bypass_stale_refusal
test_unavailable_stale_comparison_refuses_before_merging
test_mismatched_repository_refuses_before_merging
test_supported_origin_spellings_preserve_repository_binding
test_ssh_resolution_preserves_origin_user_and_port
test_ssh_hostname_override_refuses_repository_binding
test_ssh_config_resolution_is_bounded
test_multiple_merge_bases_refuse_comparison
test_stale_details_name_presence_content_type_and_mode_losses
test_stale_submodule_update_names_both_commits
test_github_head_race_is_rejected_by_the_forge_binding
test_merge_failure_propagates_after_recording
test_allowlisted_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_non_allowlisted_repo_arg_refuses_before_recording
test_non_allowlisted_merge_args_refuse_before_recording_or_comparison
test_github_immediate_execution_preflight_refuses_queue_and_unknown
test_default_tip_move_refuses_both_forges
test_forge_oid_mismatch_and_unknown_refuse_before_merge
test_non_default_targets_refuse_both_forges
test_final_github_preflight_cannot_reopen_default_tip_race
test_body_file_is_materialized_and_bounded_before_the_tip_recheck
test_body_file_materialization_rechecks_immediate_execution
test_non_allowlisted_short_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_open_recorded_issue_is_closed_after_merge
test_already_closed_recorded_issue_is_left_alone
test_issue_close_failure_keeps_merge_success_unambiguous
test_no_recorded_issue_makes_no_issue_calls
test_issue_verification_failure_keeps_merge_success_unambiguous
test_issue_still_open_after_close_request_warns
test_invalid_recorded_issue_metadata_warns_without_issue_calls
test_work_item_closes_in_its_declared_repository_not_the_pr_repository
test_gitea_work_item_without_credential_is_reported_not_closed
test_gitea_work_item_is_closed_with_its_own_credential
test_gitea_close_failure_keeps_merge_success_unambiguous
test_gitea_verification_failure_names_its_own_reason
test_gitea_empty_credential_is_reported_as_present_not_absent
test_self_hosted_github_work_item_is_reported_not_closed
test_invalid_or_multiple_work_items_warn_without_issue_calls
test_work_item_record_wins_over_legacy_issue_line
test_refresh_failure_warning_names_the_cause
test_refresh_reason_is_bounded_to_one_line
test_gitlab_url_resolves_and_merges
test_gitlab_host_comes_from_the_url
test_gitlab_imposes_no_merge_method
test_gitlab_allowlisted_args_forwarded
test_gitlab_automatic_rebase_setting_refuses_and_unknown_fails_closed
test_gitlab_merge_failure_propagates
test_gitlab_each_condition_refuses_independently
test_gitlab_reports_every_failing_condition
test_gitlab_stale_recorded_head_is_reported
test_gitlab_unreadable_state_refuses
test_gitlab_invalid_head_refuses
test_gitlab_live_head_mismatch_reinspects_and_refuses
test_gitlab_missing_tool_refuses_before_recording
test_gitlab_head_override_args_refuse_before_recording
test_github_head_override_args_refuse_before_recording
test_secondmate_merge_reports_upward_once
test_secondmate_merge_reports_on_the_local_route
test_gitlab_merge_reports_upward
test_queued_gitlab_merge_is_refused_and_leaves_the_poll_armed
test_failed_merge_reports_nothing
test_gitlab_refusal_reports_nothing
test_main_home_merge_leaves_a_durable_wake
test_queued_github_merge_is_refused_and_leaves_the_poll_armed
test_unknown_github_post_merge_state_is_nonretryable
test_unknown_gitlab_post_merge_state_is_nonretryable
test_distinct_merged_prs_keep_distinct_wakes
test_uncommitted_marker_retry_is_never_silent
test_secondmate_without_parent_binding_is_loud
printf '\nall fm-pr-merge tests passed\n'
