#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must record pr= and any available pr_head= into the task's meta so
# fm-teardown.sh's landed-check has a PR reference to verify against, even on
# repos with no PR CI where the usual "checks green" fm-pr-check.sh trigger
# never fires.
#
# The test_* functions below name the covered merge, refusal, live-head,
# away-authority, outcome-publication, and recovery behavior directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)
BASE_PATH=$PATH

# The GitLab fixture. A placeholder host that resolves nowhere, and a namespace
# deeper than one group, because a GitLab project has no owner/repository pair.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"
MR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MR_STALE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# The GitHub default branch's tip, as the gh-axi mocks report it. Every case that
# reaches the merge is asked for it twice - once when the merge-target contract
# is settled and once immediately before the merge - and a case only sees a
# different answer the second time when it sets out to.
DEFAULT_TIP=1212121212121212121212121212121212121212
MOVED_DEFAULT_TIP=3434343434343434343434343434343434343434

JQ_BIN=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"
REAL_MV=$(command -v mv) || fail "these tests need mv to simulate a failed poll publish"

# Build a fresh sandbox for one test case: a state dir with task metadata and a
# directory for its forge-command mocks. Echoes the case directory.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$fakebin"
  cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' \
    'default=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  : > "$case_dir/gh.log"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# Live GitHub JSON for the pre-merge verify, plus gh-axi for the
# post-merge fallback view. Merge itself is `gh pr merge --match-head-commit`.
# Args: case_dir head_sha
write_github_live_json() {
  local case_dir=$1 head=$2
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
}

write_github_red_json() {
  local case_dir=$1 head=$2 name=$3
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"$name","status":"COMPLETED","conclusion":"FAILURE"}]}
JSON
}

# One CheckRun rollup entry the way GitHub reports it. A conclusion or timestamp
# of "-" is emitted as JSON null. Args: name status conclusion [startedAt]
# [completedAt]
check_run() {
  local name=$1 status=$2 conclusion=$3 started=${4:--} completed=${5:-${4:--}}
  local conclusion_json='null' started_json='null' completed_json='null'
  [ "$conclusion" = - ] || conclusion_json="\"$conclusion\""
  [ "$started" = - ] || started_json="\"$started\""
  [ "$completed" = - ] || completed_json="\"$completed\""
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":%s,"startedAt":%s,"completedAt":%s}' \
    "$name" "$status" "$conclusion_json" "$started_json" "$completed_json"
}

status_context() {
  local name=$1 state=$2
  printf '{"__typename":"StatusContext","context":"%s","state":"%s"}' "$name" "$state"
}

# Live GitHub JSON whose rollup holds the given entries verbatim, so a test can
# put several runs of one check name at the same head the way GitHub does after
# it cancels a pull request's in-flight run and re-triggers it. mergeStateStatus
# stays CLEAN because that is what GitHub reports for exactly this case.
# Args: case_dir head_sha <rollup-entry-json>...
write_github_rollup_json() {
  local case_dir=$1 head=$2 entry rollup=''
  shift 2
  for entry in "$@"; do
    rollup="${rollup:+$rollup,}$entry"
  done
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[$rollup]}
JSON
}

assert_logged_gh_merge() {
  local case_dir=$1 number=$2 repo=$3 head line extra=
  shift 3
  head=$(cat "$case_dir/github-head")
  [ "$#" -eq 0 ] || extra=" $*"
  line="pr merge $number --repo $repo --match-head-commit $head$extra"
  grep -qxF "$line" "$case_dir/gh.log" \
    || fail "expected gh merge line: $line"$'\n'"got: $(grep '^pr merge ' "$case_dir/gh.log" || true)"
}

add_gh_mocks() {
  local case_dir=$1 head=$2
  write_github_live_json "$case_dir" "$head"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
  # The merge target and the default branch's current tip both come through this
  # passthrough, so the default-target contract and the base-tip check hold on a
  # host without gh too.
  "api repos/"*|api\ *)
    # This fixture answers TWO queries, each a per-field object whose TOON
    # encoding puts every field on its own line. The SHAPE OF THE REQUEST is what
    # decides the shape of the reply - a jq expression that is not JSON comes
    # back inside an api_response envelope instead - so a run that asks a
    # question this fixture does not model gets the error a fixture owes it,
    # rather than an answer that hides the difference.
    case " $* " in
      *'{base:'*)
        printf 'base: %s\ndef: %s\n' \
          "${FM_TEST_GH_AXI_BASE:-main}" "${FM_TEST_GH_AXI_DEFAULT:-main}"
        ;;
      *'{tip:'*) printf 'tip: %s\n' "${FM_TEST_GH_AXI_TIP:-$FM_TEST_DEFAULT_TIP}" ;;
      *) echo "gh-axi mock: unmodelled api query: $*" >&2 ; exit 2 ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    if [ -e "$FM_TEST_GH_OUTCOME.cache-invalid" ]; then
      case " $* " in *'state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup'*) ;; *statusCheckRollup*) printf 'not JSON\n'; exit 0 ;; esac
    fi
    case " $* " in
      *statusCheckRollup*)
        cat "$FM_TEST_GH_VIEW_JSON"
        if [ -f "${FM_TEST_AWAY_RECORD_AFTER_VIEW:-}" ]; then
          cp "$FM_TEST_AWAY_RECORD_AFTER_VIEW" "$FM_STATE_OVERRIDE/.afk-contract"
        fi
        exit 0
        ;;
      *headRefOid*)
        cat "$FM_TEST_GH_HEAD"
        exit 0
        ;;
    esac
    ;;
  "pr merge")
    : > "$FM_TEST_GH_OUTCOME.merge-called"
    if [ -f "$FM_TEST_GH_OUTCOME.merged" ]; then
      cp "$FM_TEST_GH_OUTCOME.merged" "$FM_TEST_GH_OUTCOME"
    fi
    if [ -n "${FM_TEST_META_AT_MERGE:-}" ] && [ -f "${FM_STATE_OVERRIDE:-}/task-x1.meta" ]; then
      cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$FM_TEST_META_AT_MERGE"
    fi
    # The forge call runs inside the merge's critical section, so a real
    # away-record change attempted from here is the TOCTOU itself: whatever
    # happens to it happens between the authority read and the merge.
    if [ -x "${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" ]; then
      away_rc=0
      "$FM_TEST_AWAY_MUTATE_AT_MERGE" > "$FM_TEST_AWAY_MUTATE_OUT" 2>&1 || away_rc=$?
      printf '%s\n' "$away_rc" > "$FM_TEST_AWAY_MUTATE_RC"
      "$FM_TEST_ROOT/bin/fm-afk-contract.sh" grants \
        > "$FM_TEST_AWAY_GRANTS_AT_MERGE" 2>/dev/null \
        || printf 'no-live-record\n' > "$FM_TEST_AWAY_GRANTS_AT_MERGE"
    fi
    if [ -n "${FM_TEST_GH_MERGE_OUTPUT:-}" ]; then
      printf '%s\n' "$FM_TEST_GH_MERGE_OUTPUT"
    else
      printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    fi
    merge_rc=0
    if [ -f "${FM_TEST_GH_MERGE_RC_FILE:-}" ]; then
      merge_rc=$(cat "$FM_TEST_GH_MERGE_RC_FILE")
    fi
    exit "$merge_rc"
    ;;
  "api graphql")
    count_file="$FM_TEST_GH_OUTCOME.reads"
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [ -f "$FM_TEST_GH_OUTCOME.fail-from" ] && [ "$count" -ge "$(cat "$FM_TEST_GH_OUTCOME.fail-from")" ]; then
      echo 'error: could not reach the GitHub API' >&2
      exit 1
    fi
    if [ -f "${FM_TEST_GH_GRAPHQL_FAIL:-}" ]; then
      echo 'error: could not reach the GitHub API' >&2
      exit 1
    fi
    if [ ! -e "$FM_TEST_GH_OUTCOME.merge-called" ] && [ ! -e "$FM_TEST_GH_OUTCOME.initially-merged" ]; then
      sed -e 's/^state=.*/state=OPEN/' -e 's/^merged=.*/merged=false/' "$FM_TEST_GH_OUTCOME"
    else
      cat "$FM_TEST_GH_OUTCOME"
    fi
    exit 0
    ;;
  api\ *)
    if [ -f "${FM_TEST_GH_RULES_FAIL:-}" ]; then
      exit 1
    fi
    cat "$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that still answers fm-pr-check.sh's head lookup but cannot answer the
# outcome read, so a merge call that returned success is followed by a live
# state nothing can prove. Args: case_dir head_sha
# The guarded merge reads forge state TWICE: once before the mutation, for the
# default-target contract, and once after it, for the outcome. A mock that fails
# every read cannot tell those two cases apart, so a case named for an unreadable
# OUTCOME would actually die on an unreadable TARGET and stop testing its own
# subject. This variant fails only from the Nth read onward, so the target read
# succeeds and the post-merge outcome read is the one that fails.
# Args: case_dir head first_failing_read
add_gh_mock_outcome_read_fails_from() {
  local case_dir=$1 head=$2 from=$3
  cp "$case_dir/fakebin/gh-axi" "$case_dir/gh-axi.saved"
  add_gh_mocks "$case_dir" "$head"
  mv "$case_dir/gh-axi.saved" "$case_dir/fakebin/gh-axi"
  printf '%s\n' "$from" > "$case_dir/github-outcome.fail-from"
}

# gh mock that fails the merge call but succeeds live verify, so a real merge
# failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  local head=${2:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}
  add_gh_mocks "$case_dir" "$head"
  printf '1\n' > "$case_dir/github-merge-rc"
  printf 'error: pr merge failed\n' > "$case_dir/github-merge-output"
}

# Flag the shared gh mock so GraphQL outcome reads fail while live verify and
# merge still succeed. Args: case_dir [head_sha ignored]
add_gh_mock_outcome_read_fails() {
  local case_dir=$1
  : > "$case_dir/github-graphql-fail"
}

# gh-axi mock that merges but cannot answer its own view, so a case can prove
# what happens when neither reader can establish the outcome. Args: case_dir
add_gh_axi_mock_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") exit 1 ;;
  api\ *)
    case " $* " in
      *'{tip:'*) printf 'tip: %s\n' "${FM_TEST_GH_AXI_TIP:-$FM_TEST_DEFAULT_TIP}" ;;
      *) echo "gh-axi mock: unmodelled api query: $*" >&2 ; exit 2 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# A gh-axi mock whose pull request reads OPEN until the merge is attempted and
# MERGED afterwards, through BOTH readers, so a case cannot pass on a landing its
# PRE-merge read already saw. `pr merge` rewrites the one outcome fixture the gh
# mock answers from and the state this mock reports, which is what makes the
# switch visible to whichever reader the case leaves working. Its exit status is
# the only difference between a route whose merge command succeeds and one whose
# command fails after the merge landed.
# Args: case_dir merge_exit_status
add_gh_axi_mock_open_until_merged() {
  local case_dir=$1 merge_rc=$2
  printf '%s\n' \
    'state=MERGED' 'merged=true' 'queued=false' 'base=main' 'default=main' \
    > "$case_dir/github-outcome.merged"
  printf '%s\n' "$merge_rc" > "$case_dir/github-merge-rc"
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
case "\${1:-} \${2:-}" in
  "pr merge")
    cat "\$FM_TEST_GH_OUTCOME.merged" > "\$FM_TEST_GH_OUTCOME"
    if [ $merge_rc -ne 0 ]; then
      echo "simulated transport failure after the merge landed" >&2
      exit $merge_rc
    fi
    printf 'merged:\n  number: %s\n  status: ok\n' "\${3:-}"
    ;;
  "pr view")
    if grep -qx 'merged=true' "\$FM_TEST_GH_OUTCOME"; then
      printf 'pull_request:\n  number: %s\n  state: merged\n' "\$3"
    else
      printf 'pull_request:\n  number: %s\n  state: open\n' "\$3"
    fi
    ;;
  # The degraded reader establishes the merge target and the base tip through
  # this passthrough, in the per-field shape the reader is written against.
  api\ *)
    case " \$* " in
      *'{base:'*) printf 'base: main\ndef: main\n' ;;
      *'{tip:'*) printf 'tip: %s\n' "\${FM_TEST_GH_AXI_TIP:-\$FM_TEST_DEFAULT_TIP}" ;;
      *) echo "gh-axi mock: unmodelled api query: \$*" >&2 ; exit 2 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# How many times a mock was asked one kind of question, read back out of its own
# invocation log. Args: log_file extended_regex
count_log_lines() {
  local n
  n=$(grep -Ec -- "$2" "$1" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

add_failing_poll_publish_mv() {
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-poll-data.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
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
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

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
  # The guarded merge reads project merge settings, the instance version, and
  # the merge request divergence before mutating, because GitLab can rebase the
  # source branch at merge time and strand the attestation. Each answer comes
  # from a per-case file when one exists, so a case can exercise any point in
  # the bound; the defaults are the permitting ones.
  "api version")
    if [ -f "$case_dir/version" ]; then
      printf '{"version":"%s"}\n' "$(cat "$case_dir/version")"
    else
      printf '{"version":"19.3.0"}\n'
    fi
    exit 0
    ;;
  "api projects/"*)
    case " $* " in
      *include_diverged_commits_count*)
        if [ -f "$case_dir/behind" ]; then
          printf '{"diverged_commits_count":%s}\n' "$(cat "$case_dir/behind")"
        else
          printf '{"diverged_commits_count":0}\n'
        fi
        exit 0
        ;;
    esac
    if [ -f "$case_dir/project.json" ]; then
      cat "$case_dir/project.json"
    else
      printf '%s\n' "${FM_TEST_GLAB_PROJECT_JSON:-{\"merge_method\":\"merge\"}}"
    fi
    exit 0
    ;;
  "mr view")
    [ ! -e "$case_dir/glab-view-fails" ] || exit 1
    if [ -e "$case_dir/glab-merge-called" ] && [ ! -e "$case_dir/glab-stays-open" ]; then
      cat "$case_dir/mr-post.json"
    else
      cat "$FM_TEST_GLAB_JSON"
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
  local head=$MR_HEAD pipeline_sha=$MR_HEAD pipeline_status=success pipeline=present
  local merge_when_pipeline_succeeds=false merge_after=null
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
      pipeline_sha) pipeline_sha=$value ;;
      pipeline_status) pipeline_status=$value ;;
      pipeline) pipeline=$value ;;
      merge_when_pipeline_succeeds) merge_when_pipeline_succeeds=$value ;;
      merge_after) merge_after=$value ;;
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  printf '{"iid":7,"state":"%s","detailed_merge_status":"%s","has_conflicts":%s,' \
    "$state" "$detail" "$conflicts" > "$file"
  printf '"blocking_discussions_resolved":%s,"sha":"%s","head_pipeline":%s,' \
    "$discussions" "$head" "$pipeline" >> "$file"
  printf '"merge_when_pipeline_succeeds":%s,"merge_after":%s}\n' \
    "$merge_when_pipeline_succeeds" "$merge_after" >> "$file"
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
  write_mr_json "$case_dir/mr-post.json" state=merged
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

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$case_dir/home}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_DEFAULT_TIP="$DEFAULT_TIP" \
  FM_TEST_GH_VIEW_JSON="$case_dir/github-view.json" \
  FM_TEST_GH_HEAD="$case_dir/github-head" \
  FM_TEST_GH_MERGE_RC_FILE="$case_dir/github-merge-rc" \
  FM_TEST_GH_MERGE_OUTPUT="$(cat "$case_dir/github-merge-output" 2>/dev/null || true)" \
  FM_TEST_GH_GRAPHQL_FAIL="$case_dir/github-graphql-fail" \
  FM_TEST_GH_RULES_FAIL="$case_dir/github-rules-fail" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_AWAY_RECORD_AFTER_VIEW="$case_dir/away-record-after-view" \
  FM_TEST_ROOT="$ROOT" \
  FM_TEST_AWAY_MUTATE_AT_MERGE="${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" \
  FM_TEST_AWAY_MUTATE_OUT="$case_dir/away-mutate-output" \
  FM_TEST_AWAY_MUTATE_RC="$case_dir/away-mutate-rc" \
  FM_TEST_AWAY_GRANTS_AT_MERGE="$case_dir/away-grants-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  HOME="${FM_TEST_USER_HOME:-$case_dir/user-home}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

write_github_outcome() {  # <case-dir> <state> <merged> <queued> <base> [<default-branch>]
  # The default branch defaults to the PR's base, because guarded merging is
  # limited to the current default branch and almost every case targets it.
  # Pass a sixth argument only to exercise a non-default target refusal.
  local case_dir=$1 state=$2 merged=$3 queued=$4 base=$5 default=${6:-$5}
  printf '%s\n' \
    "state=$state" \
    "merged=$merged" \
    "queued=$queued" \
    "base=$base" \
    "default=$default" > "$case_dir/github-outcome"
}

write_away_record() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" propose "$@" >/dev/null
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null
}

test_verified_merge_records_pr_and_head() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  pass "fm-pr-merge records pr= and pr_head= for a verified GitHub merge"
}

# The forge call is the point of no return: once gh-axi has merged, nothing this
# script does afterwards can un-merge it. Proving pr= is already in the task's
# meta at that moment is what makes a later failure unable to lose the merge.
test_pr_metadata_is_recorded_before_the_forge_call() {
  local case_dir rc
  case_dir=$(make_case records-ahead-of-forge-call)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-ahead-of-forge-call: fm-pr-merge should succeed"
  assert_logged_gh_merge "$case_dir" 62 example/repo --squash
  assert_grep 'pr=https://github.com/example/repo/pull/62' "$case_dir/meta-at-merge" \
    "records-ahead-of-forge-call: the merge ran before pr= was recorded"
  pass "fm-pr-merge records pr= before the forge call can land the merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  # A GENUINE failure: the command failed AND the forge does not report the
  # request merged. make_case's default fixture reports MERGED, which is the
  # separate landed-but-command-failed case that must exit zero, so this case
  # states its own not-merged outcome rather than inheriting that one.
  write_github_outcome "$case_dir" OPEN false false main
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

test_github_merged_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-merged: a merged PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/51 is merged' \
    "$case_dir/stdout" "github-verified-merged: success was not reported as verified"
  # THIS CASE'S PULL REQUEST IS ALREADY MERGED WHEN THE RUN STARTS, so the read
  # this assertion sees is the PRE-merge one and the post-merge read is
  # deliberately skipped. Saying it proves a readback "after merging" is how the
  # collapse the invariant matrix was rebuilt to prevent went unnoticed for three
  # rounds; the post-merge readback is measured by the github|post-mutation route
  # of test_every_landed_observation_reaches_outcome_reporting, whose fixture no
  # pre-merge read can satisfy.
  assert_grep 'api graphql' "$case_dir/gh.log" \
    "github-verified-merged: the pull request state was never read through the queue-aware reader"
  pass "fm-pr-merge verifies a genuinely merged GitHub pull request"
}

test_github_verified_merge_requires_poll_recording() {
  local case_dir rc
  case_dir=$(make_case github-poll-recording-fails)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_failing_poll_publish_mv "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-poll-recording-fails: poll setup failure should fail the merge wrapper"
  assert_grep 'error: could not publish PR poll' "$case_dir/stderr" \
    "github-poll-recording-fails: poll setup failure was not reported"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-poll-recording-fails: failed poll setup was reported as a verified merge"
  assert_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "github-poll-recording-fails: metadata was not retained for the attempted merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-poll-recording-fails: the failed poll setup left a runnable poll"
  pass "fm-pr-merge refuses to claim a merge when poll recording fails"
}

test_github_open_unqueued_outcome_refuses() {
  local case_dir rc
  case_dir=$(make_case github-open-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  write_github_outcome "$case_dir" OPEN false false master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-open-unqueued: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-open-unqueued: refusal did not name the concrete observed state"
  assert_grep 'pr=https://github.com/example/repo/pull/52' "$case_dir/state/task-x1.meta" \
    "github-open-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-open-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge call that leaves the PR open and unqueued"
}

test_github_unreadable_outcome_keeps_pr_bookkeeping() {
  local case_dir rc
  case_dir=$(make_case github-outcome-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  # Read-specific: the pre-mutation target read succeeds so this case reaches the
  # post-merge unreadable outcome it asserts. Before the messages named their
  # phase, a failure here produced the same wording pre- and post-merge and this
  # assertion passed against a message the target check had emitted instead.
  write_github_outcome "$case_dir" OPEN false false main
  add_gh_mock_outcome_read_fails_from "$case_dir" 3131313131313131313131313131313131313131 2
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-outcome-read-fails: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-outcome-read-fails: the unreadable outcome was not reported"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" "github-outcome-read-fails: the refusal did not name both failed reads"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-outcome-read-fails: an unproved merge was reported as verified"
  # The merge call itself returned success, so the pull request may well have
  # landed. Losing the reference here would leave teardown with nothing to
  # verify against and no merge poll to catch up.
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-outcome-read-fails: a successful merge call lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-outcome-read-fails: no merge poll was armed for a merge that may have landed"
  pass "fm-pr-merge keeps PR bookkeeping when it cannot read a successful merge call's outcome"
}

test_github_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-refusal-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  printf '%s\n' 'will be added to the merge queue when all requirements are met' \
    > "$case_dir/github-merge-output"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-refusal-quotes-forge: an unproved merge must fail"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's own explanation was discarded on the refusal"
  assert_grep "not this script's verdict" "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's text was not marked as the forge's own"
  assert_grep 'error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false' \
    "$case_dir/stderr" "github-refusal-quotes-forge: the wrapper's own verdict was lost"
  # A forge sentence about the merge queue must never stand on its own line, or
  # it reads as this script's verdict rather than as quoted forge output.
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-refusal-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'will be added to the merge queue' "$case_dir/stdout" \
    "github-refusal-quotes-forge: the forge's unverified report leaked to stdout"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-refusal-quotes-forge: an unproved merge was reported as verified"
  pass "fm-pr-merge refuses with the forge's own output quoted apart from its verdict"
}

test_github_auto_merge_spellings_are_refused_before_the_merge() {
  local case_dir rc spelling
  # Upstream explained an armed auto-merge that landed nothing. This fork refuses
  # --auto before the merge is attempted, so that explanation is unreachable and
  # the case now covers what it can still prove: BOTH spellings are refused by
  # name, with the reason, and neither reaches the forge.
  # Collapsed from five near-identical cases that each set up the same scenario
  # and made the same three assertions. What they actually covered between them
  # is the argument SHAPE, so that is what varies here: both spellings, alone and
  # beside a method, and beside a method the base branch's queue would require.
  for spelling in --auto --auto=true; do
    case_dir=$(make_case "github-auto-refused${spelling#--auto}")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 7171717171717171717171717171717171717171
    write_github_outcome "$case_dir" OPEN false false main
    : > "$case_dir/github-rules"
    : > "$case_dir/gh-axi.log"
    : > "$case_dir/gh.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      --attended-override -- "$spelling" --merge \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-auto-refused: forwarding $spelling must be refused"
    assert_grep 'requests deferred execution' "$case_dir/stderr" \
      "github-auto-refused: the refusal did not name why $spelling is not forwardable"
    assert_grep 'merges immediately on judged evidence' "$case_dir/stderr" \
      "github-auto-refused: the refusal did not name the contract it protects"
    [ ! -s "$case_dir/gh-axi.log" ] \
      || fail "github-auto-refused: $spelling still reached the forge"
  done
  pass "fm-pr-merge refuses every --auto spelling before any merge is attempted"
}

# THE ARGUMENT GUARD MAKES TWO CLAIMS, so a table is where both of them live.
#
# It must refuse a refused flag WHEREVER it stands, and it must still admit the
# ordinary detached values the allow-list exists to carry. One case can prove
# only one of those, and a guard that fails either way looks correct from the
# other side: deleting the guard passes the admitting half, and a guard that
# refuses everything passes the refusing half.
#
# The hole this pins: the guard once modelled the forge CLI as a POSITIONAL
# parser, so a value-taking flag swallowed the next word whatever it was, and
# `-- --subject --auto` reached gh-axi, which scans the whole list, took --auto
# as a flag, dropped the valueless --subject and ARMED DEFERRED EXECUTION - the
# one thing this fork refuses - while the suite stayed green because every --auto
# case put the flag at the head of the vector.
test_no_argument_position_launders_a_refused_flag() {
  local case_dir rc number=300 taker order spec url
  local -a vector
  # Every value-taking entry on the allow-list crossed with the refused flag, in
  # BOTH orders: the refused flag standing where a value belongs, and standing
  # ahead of a well-formed pair that would otherwise consume it.
  for taker in --method --subject --body --body-file -t -b -F; do
    for order in "$taker --auto" "--auto $taker value"; do
      number=$((number + 1))
      url="https://github.com/example/repo/pull/$number"
      case_dir=$(make_case "arg-guard-refuses-$number")
      mkdir -p "$case_dir/wt"
      add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
      : >"$case_dir/gh-axi.log"
      read -r -a vector <<<"$order"

      set +e
      run_pr_merge "$case_dir" task-x1 "$url" -- "${vector[@]}" \
        >"$case_dir/stdout" 2>"$case_dir/stderr"
      rc=$?
      set -e

      expect_code 1 "$rc" \
        "arg-guard-refuses: '$order' must be refused wherever --auto stands"
      assert_grep '--auto' "$case_dir/stderr" \
        "arg-guard-refuses: '$order' was refused without naming the flag responsible"
      [ ! -s "$case_dir/gh-axi.log" ] \
        || fail "arg-guard-refuses: '$order' still reached the forge"
    done
  done
  # The admitting half. --sha <sha> is the detached value the allow-list was
  # widened for in the first place, and --subject=<value> is how a value that
  # legitimately begins with a dash is still passed: it is ONE token, so nothing
  # can read it as a flag standing on its own.
  for order in '--subject fix' '--subject=-fix'; do
    number=$((number + 1))
    url="https://github.com/example/repo/pull/$number"
    case_dir=$(make_case "arg-guard-admits-$number")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
    : >"$case_dir/gh-axi.log"
    read -r -a vector <<<"$order"

    set +e
    run_pr_merge "$case_dir" task-x1 "$url" -- "${vector[@]}" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" \
      "arg-guard-admits: '$order' is on the allow-list and must still merge"
    grep -qxF "pr merge $number --repo example/repo --match-head-commit cccccccccccccccccccccccccccccccccccccccc --squash $order" \
      "$case_dir/gh.log" \
      || fail "arg-guard-admits: '$order' was not forwarded to the forge unchanged"
  done
  pass "no argument position lets a refused flag reach the forge, and detached values still pass"
}





test_github_unrecognised_queue_method_still_names_the_queue() {
  local case_dir rc
  case_dir=$(make_case github-unrecognised-queue-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8383838383838383838383838383838383838383
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=FASTFORWARD\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unrecognised-queue-method: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue, but its configured merge method (FASTFORWARD) is not one this script recognises' \
    "$case_dir/stderr" \
    "github-unrecognised-queue-method: a readable queue rule produced no queue mention"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unrecognised-queue-method: retry flags were named for a method nothing recognises"
  assert_no_grep '--auto --' "$case_dir/stderr" \
    "github-unrecognised-queue-method: a merge method was guessed for the caller"
  pass "fm-pr-merge names the queue requirement even when its method is unrecognised"
}

test_github_unreadable_queue_rules_are_not_reported_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8484848484848484848484848484848484848484
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules-fail"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-queue-rules: an unproved merge must fail"
  assert_grep 'the branch rules for base branch main could not be read' "$case_dir/stderr" \
    "github-unreadable-queue-rules: an unreadable rules response read like a queue-less base"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unreadable-queue-rules: retry flags were named from rules nothing could read"
  pass "fm-pr-merge distinguishes unreadable branch rules from a base with no merge queue"
}

test_github_no_queue_rule_says_nothing_about_a_queue() {
  local case_dir rc
  case_dir=$(make_case github-no-queue-rule)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8585858585858585858585858585858585858585
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-no-queue-rule: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-no-queue-rule: refusal did not name the concrete observed state"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-no-queue-rule: a base with no queue rule was told it requires the merge queue"
  pass "fm-pr-merge says nothing about a merge queue when the base branch has no queue rule"
}

test_github_unmerged_fallback_cannot_replace_queue_aware_read() {
  local case_dir rc
  case_dir=$(make_case github-unmerged-fallback)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8686868686868686868686868686868686868686
  add_gh_mock_outcome_read_fails "$case_dir"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unmerged-fallback: an unproved merge must fail"
  assert_grep 'pr view 73 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-unmerged-fallback: the fallback view was not consulted"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback was treated as a readable outcome"
  assert_no_grep 'GitHub merge outcome was not successful' "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback reached detailed outcome handling"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unmerged-fallback: an unproved merge was reported as verified"
  pass "fm-pr-merge accepts only a proved merge from the gh-axi fallback"
}

test_github_unreadable_outcome_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-outcome-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8787878787878787878787878787878787878787
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "will be added to the merge queue when all requirements are met" ;;
  "pr view") exit 1 ;;
  api\ *)
    case " $* " in
      *'{tip:'*) printf 'tip: %s\n' "$FM_TEST_DEFAULT_TIP" ;;
      *) echo "gh-axi mock: unmodelled api query: $*" >&2 ; exit 2 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  # Read-specific: the pre-mutation target read succeeds so this case reaches the
  # unreadable OUTCOME it is named for, rather than dying on an unreadable target.
  write_github_outcome "$case_dir" OPEN false false main
  add_gh_mock_outcome_read_fails_from "$case_dir" 8787878787878787878787878787878787878787 2
  printf '%s\n' 'will be added to the merge queue when all requirements are met' > "$case_dir/github-merge-output"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-outcome-quotes-forge: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the unreadable outcome was not reported"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the forge's only evidence was discarded"
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-unreadable-outcome-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unreadable-outcome-quotes-forge: an unproved merge was reported as verified"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-unreadable-outcome-quotes-forge: the attempted merge lost its merge poll"
  pass "fm-pr-merge quotes the forge output when it cannot read the outcome either"
}

test_github_failed_gh_read_falls_back_to_gh_axi() {
  local case_dir rc
  case_dir=$(make_case github-gh-read-falls-back)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  add_gh_mock_outcome_read_fails "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-gh-read-falls-back: a merge the gh-axi view proves must succeed"
  # Already merged when the run starts, so the fallback that answers here is the
  # PRE-merge one; the post-merge half of this route is measured by
  # github|degraded-gh-failed in the landed-merge invariant, whose fixture reads
  # OPEN until the merge runs.
  assert_grep 'pr view 63 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-gh-read-falls-back: the gh-axi view was never consulted when gh's read failed"
  assert_grep 'verified: https://github.com/example/repo/pull/63 is merged' \
    "$case_dir/stdout" "github-gh-read-falls-back: the proven merge was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/63' "$case_dir/state/task-x1.meta" \
    "github-gh-read-falls-back: the merged PR was not recorded for teardown"
  pass "fm-pr-merge falls back to the gh-axi view when gh's read fails"
}

test_github_failed_merge_names_an_observed_landed_state() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_case github-failed-merge-actually-landed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # DELIBERATE FORK DIVERGENCE, recorded in docs/fork-divergence.md. Upstream
  # asserts exit 1 here: the merge command failed, so the wrapper fails. This
  # fork asserts exit 0, because the two things are answers to different
  # questions. The command's exit status reports whether the CALL succeeded; the
  # forge's own state reports whether the MERGE HAPPENED, and only the second is
  # the question anyone cares about. When they disagree the forge is the system
  # of record and the command status is a transport detail.
  #
  # The failure modes are not symmetric, which is what decides it. Exiting
  # non-zero on a landed merge is a FALSE NEGATIVE: the work is on the default
  # branch while everything downstream reasons that it is not - the task reads
  # unfinished, cleanup refuses, a retry runs against an already-merged request,
  # and a human is told something untrue about the repository. Exiting zero is
  # only wrong if the forge lied about its own merged flag, and if that flag
  # cannot be trusted then no verdict here is possible at all.
  #
  # This rule inverted four separate times while this task was being built, which
  # is why bin/fm-pr-merge.sh's header carries an explicit warning not to correct
  # it back to trusting the command status. Upstream arriving at the opposite
  # verdict independently is evidence the inversion is EASY to reach, not
  # evidence it is right.
  expect_code 0 "$rc" "github-failed-merge-actually-landed: a merge the forge confirms landed must not be reported as failed"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the original forge error was masked"
  assert_grep 'state=MERGED, merged=true, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the observed landed state was never named"
  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "github-failed-merge-actually-landed: the landed merge never reached outcome reporting"
  assert_grep 'pr=https://github.com/example/repo/pull/64' "$case_dir/state/task-x1.meta" \
    "github-failed-merge-actually-landed: the landed PR lost its reference"
  pass "fm-pr-merge names a landed state hiding behind a failed GitHub merge command"
}

test_github_without_gh_still_uses_gh_axi_merge() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/60 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing, before recording"
}

test_github_without_gh_failed_read_keeps_bookkeeping() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh-read-fails)
  mkdir -p "$case_dir/wt"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
# Read-specific for the same reason as the gh variant: the guarded merge reads
# forge state before the mutation for the target contract and again after it for
# the outcome. Failing every read would make this case die on an unreadable
# TARGET instead of the unreadable OUTCOME it is named for, so the first view
# succeeds and the post-merge view is the one that fails.
count_file="$FM_TEST_GH_AXI_LOG.views"
case "${1:-} ${2:-}" in
  "pr merge") exit 0 ;;
  "pr view")
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    [ "$count" -ge 2 ] && exit 1
    printf 'pull_request:\n  number: %s\n  state: open\n' "$3"
    ;;
  # The degraded reader establishes the merge target and the base tip through
  # this passthrough.
  api\ *)
    case " $* " in
      *'{base:'*) printf 'base: main\ndef: main\n' ;;
      *'{tip:'*) printf 'tip: %s\n' "$FM_TEST_DEFAULT_TIP" ;;
      *) echo "gh-axi mock: unmodelled api query: $*" >&2 ; exit 2 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh-read-fails: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh-read-fails: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh-read-fails: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh-read-fails: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing rather than merging blind"
}

test_github_zero_exit_queue_required_refuses_with_exact_retry() {
  local case_dir rc
  case_dir=$(make_case github-zero-exit-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  write_github_outcome "$case_dir" OPEN false false 'release/2026'
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-zero-exit-queue-required: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the concrete observed state"
  assert_grep 'base branch release/2026 requires the merge queue' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the exact compatible flags"
  assert_grep 'api --paginate repos/example/repo/rules/branches/release%2F2026' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue rules were not read with pagination and encoded branch path"
  assert_logged_gh_merge "$case_dir" 56 example/repo --squash
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep --auto "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue flags were auto-applied to the attempted merge"
  assert_grep 'pr=https://github.com/example/repo/pull/56' "$case_dir/state/task-x1.meta" \
    "github-zero-exit-queue-required: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-zero-exit-queue-required: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge reports exact queue retry flags after a zero-exit false success"
}

test_github_closed_unqueued_outcome_omits_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-closed-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2323232323232323232323232323232323232323
  write_github_outcome "$case_dir" CLOSED false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-closed-unqueued: an unproved merge must fail"
  assert_grep 'state=CLOSED, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-closed-unqueued: refusal did not name the concrete observed state"
  assert_no_grep 'requires the merge queue' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received unusable queue guidance"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received retry flags"
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-closed-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-closed-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge omits merge-queue retry guidance for a closed GitHub PR"
}


test_github_queued_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-queued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  write_github_outcome "$case_dir" OPEN false true master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  # Upstream reaches this outcome by passing -- --auto --merge. The queue verdict
  # it asserts is upstream's and unchanged, but the ARGUMENTS are not available
  # here: the forwarded-argument allow-list refuses --auto by name, which is a
  # separate rule and was not retired with the queue refusal. The queue state the
  # verdict is read from is the forge's, so the fixture supplies it directly.
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-queued: a queued PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/53 is queued' \
    "$case_dir/stdout" "github-verified-queued: success was not reported as queued"
  assert_no_grep 'merged:' "$case_dir/stdout" \
    "github-verified-queued: the forge CLI's unverified merged report leaked through"
  assert_grep 'pr=https://github.com/example/repo/pull/53' "$case_dir/state/task-x1.meta" \
    "github-verified-queued: the queued PR was not recorded for teardown"
  pass "fm-pr-merge accepts and accurately reports a GitHub merge-queue entry"
}

test_github_queue_required_refusal_names_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-queue-required: an incompatible direct merge must fail"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-queue-required: the original forge failure was not preserved"
  assert_grep 'base branch master requires the merge queue' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue requirement"
  grep -F -- '--attended-override -- --auto --merge' "$case_dir/stderr" >/dev/null \
    || fail "github-queue-required: refusal did not name the exact compatible flags"
  assert_logged_gh_merge "$case_dir" 54 example/repo --squash
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-required: the failed forge call did not leave the merge poll armed"
  pass "fm-pr-merge explains how to retry with the required GitHub merge queue method"
}

test_github_agreeing_queue_rules_keep_retry_guidance() {
  local case_dir rc
  case_dir=$(make_case github-agreeing-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2424242424242424242424242424242424242424
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\nmerge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-agreeing-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue' "$case_dir/stderr" \
    "github-agreeing-queue-rules: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules omitted exact retry flags"
  assert_no_grep 'exact retry flags are ambiguous' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules were reported as ambiguous"
  pass "fm-pr-merge aggregates agreeing merge-queue rules"
}

test_github_conflicting_queue_rules_report_ambiguity() {
  local case_dir rc
  case_dir=$(make_case github-conflicting-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2525252525252525252525252525252525252525
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\nmerge_method=SQUASH\nmerge_method=SQUASH\n' \
    > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-conflicting-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main has conflicting merge queue methods (MERGE, SQUASH)' \
    "$case_dir/stderr" \
    "github-conflicting-queue-rules: conflicting methods were not named"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep '--attended-override -- --auto --squash' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep 'SQUASH, SQUASH' "$case_dir/stderr" \
    "github-conflicting-queue-rules: a repeated queue method was named twice"
  pass "fm-pr-merge reports ambiguity for conflicting merge-queue rules"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "extra-args: branch deletion must be refused without --attended-override"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "extra-args: refusal did not name --attended-override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "extra-args: gh pr merge ran despite the denylist"

  case_dir=$(make_case extra-args-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 \
    --attended-override -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args-attended: attended override should merge"
  assert_logged_gh_merge "$case_dir" 15 example/repo --squash --delete-branch
  pass "fm-pr-merge refuses branch deletion unless --attended-override is passed"
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
  [ ! -s "$case_dir/gh.log" ] || fail "missing-meta: gh pr merge was invoked"
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
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
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
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
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
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_bundled_repo_override_args_refuse_before_recording() {
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
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "bundled-repo-override: PR URL was recorded before rejecting the bundled repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override: a bundled repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "bundled-repo-override: gh-axi pr merge was invoked despite the bundled repo override"

  case_dir=$(make_gitlab_case bundled-repo-override-gitlab)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- -yR https://other.example/g/p \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override-gitlab: fm-pr-merge should refuse a bundled instance override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override-gitlab: refusal did not explain the repo override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "bundled-repo-override-gitlab: the URL was recorded before rejecting the bundled override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override-gitlab: a bundled override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] \
    || fail "bundled-repo-override-gitlab: glab was invoked despite the bundled override"

  # Only a cluster carrying the repository flag is refused: every other short
  # cluster is still the caller's business and still reaches the forge.
  case_dir=$(make_case bundled-non-repo-cluster)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "bundled-non-repo-cluster: -d is branch deletion and must be refused"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "bundled-non-repo-cluster: refusal did not name --attended-override"

  case_dir=$(make_case bundled-delete-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 --attended-override -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "bundled-delete-attended: attended override should merge"
  assert_logged_gh_merge "$case_dir" 8 example/repo --squash -d
  pass "fm-pr-merge refuses a bundled short-option repo override and refuses -d unless attended"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 22 example/repo --merge
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 23 example/repo --merge
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 126 my-org/my-repo --squash
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
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
  local case_dir
  case_dir=$(make_case no-issue)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "no-issue: merge failed"

  assert_no_grep 'issue ' "$case_dir/gh-axi.log" \
    "no-issue: merge path made an issue API call without recorded issue metadata"
  assert_logged_gh_merge "$case_dir" 34 example/repo --squash
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
  assert_grep 'pr merge 54 --repo example/repo' "$case_dir/gh.log" \
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
  assert_grep 'pr merge 56 --repo example/repo' "$case_dir/gh.log" \
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
  assert_grep 'pr merge 58 --repo example/repo' "$case_dir/gh.log" \
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
  : > "$case_dir/github-outcome.cache-invalid"
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
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-merges: a well-formed merge request URL should merge, not error"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merges: pr= was not recorded before merging"
  assert_grep "GITLAB_HOST=$MR_HOST mr view 7 -R $MR_PROJECT_URL -F json" "$case_dir/glab.log" \
    "gitlab-merges: the pre-merge state was not read from the project URL"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "gitlab-merges: unexpected merge invocation: '$merge_line'"
  assert_grep "successful pipeline at head $MR_HEAD" "$case_dir/stderr" \
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
  assert_grep "GITLAB_HOST=$host mr view 31 -R $project_url -F json" "$case_dir/glab.log" \
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

test_gitlab_extra_args_forwarded() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-extra-args)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-extra-args: source-branch deletion must be refused without --attended-override"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "gitlab-extra-args: refusal did not name --attended-override"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-extra-args: glab ran despite the denylist"

  case_dir=$(make_gitlab_case gitlab-extra-args-attended)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --attended-override -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "gitlab-extra-args-attended: attended override should merge"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes --remove-source-branch" ] \
    || fail "gitlab-extra-args-attended: extra glab flags were not forwarded: '$merge_line'"
  pass "fm-pr-merge refuses GitLab source-branch deletion unless --attended-override is passed"
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

# Each pre-merge condition, driven one at a time, so no condition can be
# carried by another. The refusal names that condition, no merge is attempted,
# and pr= is still recorded and the poll still armed exactly as the GitHub path
# leaves them when live verification or the gh merge fails.
test_gitlab_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "detail|detail=need_rebase|detailed_merge_status is \"need_rebase\", not mergeable" \
    "conflicts|conflicts=true|has_conflicts is \"true\", not false" \
    "discussions|discussions=false|blocking_discussions_resolved is \"false\", not true" \
    "pipeline-status|pipeline_status=failed|the head pipeline status is \"failed\", not success" \
    "pipeline-sha|pipeline_sha=$MR_STALE_HEAD|the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD" \
    "no-pipeline|pipeline=null|the head pipeline status is \"none\", not success"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_gitlab_case "gitlab-refuse-$name" "${spec%%|*}")

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
  local case_dir rc expected
  case_dir=$(make_gitlab_case gitlab-refuse-all \
    state=closed detail=conflict conflicts=true discussions=false \
    pipeline_status=failed "pipeline_sha=$MR_STALE_HEAD")

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
    "the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD"
  do
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-all: '$expected' was not reported"
  done
  pass "fm-pr-merge reports every failing GitLab condition, not only the first"
}

test_gitlab_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-stale-head)
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
  assert_grep "recorded head $MR_STALE_HEAD disagrees with the live head $MR_HEAD" \
    "$case_dir/stderr" "gitlab-stale-head: the stale recorded head was trusted silently"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *"--sha $MR_HEAD"*) : ;;
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
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "gitlab-head-override: refusal did not explain the head override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-head-override: the URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-head-override: a head override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-head-override: glab was invoked despite the head override"
  pass "fm-pr-merge refuses a GitLab head override before recording state"
}

test_github_still_forwards_sha_arg() {
  local case_dir rc
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-sha-arg: a caller --sha must be refused on GitHub too"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "github-sha-arg: refusal did not name the head override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-sha-arg: gh pr merge ran despite the head override"
  pass "fm-pr-merge refuses a caller --sha on GitHub because the head comes from the live read"
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
  local case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$replies" \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward merge line"
  # The merge path registers the PR first, and that registration publishes the
  # child's ready line on the same channel from fm-pr-check itself.
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url" "$replies" \
    "secondmate-merge-reports: the registration's ready line was not reported upward"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 2 ] \
    || fail "secondmate-merge-reports: a repeat merge changed the upward lines: $(cat "$replies")"
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
  # A genuine failure needs a not-merged outcome; the inherited default reports
  # MERGED, which is the landed-but-command-failed case that must exit zero.
  write_github_outcome "$case_dir" OPEN false false main
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  # The registration's ready line is a fact of its own; only a merge line
  # would misreport the unlanded merge.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
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
  # Registration succeeds before the later GitLab pre-merge refusal, so the
  # PR-ready fact is expected; only a merged outcome would be false.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
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

test_queued_gitlab_merge_leaves_the_poll_armed() {
  local case_dir
  case_dir=$(make_gitlab_case queued-gitlab-merge)
  mkdir -p "$case_dir/home"
  : >"$case_dir/glab-stays-open"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-gitlab-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-gitlab-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-gitlab-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-gitlab-merge: a queued merge was marked as reported"
  pass "a queued GitLab merge stays silent and leaves confirmation to the armed poll"
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

test_queued_github_merge_leaves_the_poll_armed() {
  local case_dir url
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  write_github_outcome "$case_dir" OPEN false true main
  : >"$case_dir/gh-axi.log"

  FM_TEST_GH_MERGE_STATE=open FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-github-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge stays silent and leaves confirmation to the armed poll"
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
  # Reused tasks re-bind through fm-pr-check before the next merge. Merge
  # refuses a URL that is not the recorded pr=, so drop the first PR identity.
  grep -vE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    > "$case_dir/state/task-x1.meta.rebind"
  mv "$case_dir/state/task-x1.meta.rebind" "$case_dir/state/task-x1.meta"
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

test_github_zero_exit_queue_required_refuses_with_exact_retry
test_github_closed_unqueued_outcome_omits_retry_flags
test_github_agreeing_queue_rules_keep_retry_guidance
test_github_conflicting_queue_rules_report_ambiguity
test_verified_merge_records_pr_and_head
test_pr_metadata_is_recorded_before_the_forge_call
test_merge_failure_propagates_after_recording
test_github_open_unqueued_outcome_refuses
test_github_unreadable_outcome_keeps_pr_bookkeeping
test_github_refusal_quotes_the_forge_output
test_github_unreadable_outcome_refusal_quotes_the_forge_output
test_github_unrecognised_queue_method_still_names_the_queue
test_github_unreadable_queue_rules_are_not_reported_as_no_queue
test_github_no_queue_rule_says_nothing_about_a_queue
test_github_auto_merge_spellings_are_refused_before_the_merge
test_no_argument_position_launders_a_refused_flag
test_github_failed_gh_read_falls_back_to_gh_axi
test_github_failed_merge_names_an_observed_landed_state
test_github_without_gh_still_uses_gh_axi_merge
test_github_without_gh_failed_read_keeps_bookkeeping
test_github_merged_outcome_is_verified
test_github_verified_merge_requires_poll_recording
test_github_queued_outcome_is_verified
test_github_queue_required_refusal_names_retry_flags
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_bundled_repo_override_args_refuse_before_recording
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
test_gitlab_extra_args_forwarded
test_gitlab_merge_failure_propagates
test_gitlab_each_condition_refuses_independently
test_gitlab_reports_every_failing_condition
test_gitlab_stale_recorded_head_is_reported
test_gitlab_unreadable_state_refuses
test_gitlab_invalid_head_refuses
test_gitlab_missing_tool_refuses_before_recording

# The merge gate asks whether the task is still held for the captain. A home
# that carries no backlog records no captain calls at all, so nothing can be
# held and the merge must proceed; a backlog that EXISTS but cannot be read may
# hide a live hold, so that one must refuse. The two states are distinct and
# only the second is a refusal.
test_absent_backlog_still_merges() {
  local case_dir rc
  case_dir=$(make_case absent-backlog-merges)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/data/backlog.md"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absent-backlog-merges: a home with no backlog must still merge"
  assert_no_grep 'held for the captain' "$case_dir/stderr" \
    "absent-backlog-merges: an absent backlog was read as a captain hold"
  assert_logged_gh_merge "$case_dir" 61 example/repo --squash
  pass "fm-pr-merge proceeds when the home carries no backlog at all"
}

test_unreadable_backlog_refuses_the_merge() {
  local case_dir rc
  case_dir=$(make_case unreadable-backlog-refuses)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6262626262626262626262626262626262626262
  : > "$case_dir/gh-axi.log"
  chmod 000 "$case_dir/home/data/backlog.md"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$case_dir/home/data/backlog.md"

  expect_code 1 "$rc" "unreadable-backlog-refuses: an unreadable authority record must refuse"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "unreadable-backlog-refuses: the refusal did not say it refused to merge"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-backlog-refuses: the forge merge ran despite an unreadable record"
  pass "fm-pr-merge refuses when the backlog exists but cannot be read"
}

test_unreadable_backend_config_refuses_the_merge() {
  local case_dir rc
  case_dir=$(make_case unreadable-backend-config-refuses)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6363636363636363636363636363636363636363
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/data/backlog.md"
  chmod 000 "$case_dir/home/.tasks.toml"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$case_dir/home/.tasks.toml"

  expect_code 1 "$rc" "unreadable-backend-config-refuses: an unreadable authority route must refuse"
  assert_grep 'tasks-axi backend configuration cannot be read' "$case_dir/stderr" \
    "unreadable-backend-config-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-backend-config-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its configured backend cannot be read"
}

test_unreadable_user_backend_config_refuses_the_merge() {
  local case_dir rc user_config
  case_dir=$(make_case unreadable-user-backend-config-refuses)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6464646464646464646464646464646464646464
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "$user_config"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$user_config"

  expect_code 1 "$rc" "unreadable-user-backend-config-refuses: an unreadable authority route must refuse"
  assert_grep "tasks-axi backend configuration cannot be read at $user_config" "$case_dir/stderr" \
    "unreadable-user-backend-config-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-user-backend-config-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its user backend configuration cannot be read"
}

test_untraversable_user_backend_config_directory_refuses_the_merge() {
  local case_dir rc user_config
  case_dir=$(make_case untraversable-user-backend-config-directory-refuses)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "${user_config%/*}"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 755 "${user_config%/*}"

  expect_code 1 "$rc" "untraversable-user-backend-config-directory-refuses: an unreadable authority route must refuse"
  assert_grep "tasks-axi backend configuration cannot be read at $user_config" "$case_dir/stderr" \
    "untraversable-user-backend-config-directory-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "untraversable-user-backend-config-directory-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its user backend configuration directory cannot be traversed"
}

test_absent_user_backend_config_directory_and_backlog_still_merge() {
  local case_dir rc
  case_dir=$(make_case absent-user-backend-config-directory-and-backlog-merges)
  mkdir -p "$case_dir/wt" "$case_dir/user-home"
  add_gh_mocks "$case_dir" 6767676767676767676767676767676767676767
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absent-user-backend-config-directory-and-backlog-merges: sound defaults and no backlog must permit merging"
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "absent-user-backend-config-directory-and-backlog-merges: the forge must merge exactly once"
  assert_logged_gh_merge "$case_dir" 67 example/repo --squash
  pass "fm-pr-merge proceeds once when its user configuration directory and backlog are genuinely absent"
}

test_backend_override_bypasses_unreadable_user_config() {
  local case_dir rc user_config
  case_dir=$(make_case backend-override-bypasses-unreadable-user-config)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6565656565656565656565656565656565656565
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "$user_config"

  set +e
  TASKS_AXI_BACKEND=markdown FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$user_config"

  expect_code 0 "$rc" "backend-override-bypasses-unreadable-user-config: an explicit backend must bypass config"
  assert_logged_gh_merge "$case_dir" 65 example/repo --squash
  pass "fm-pr-merge honors a backend override over an unreadable user configuration"
}

test_github_red_checks_refuse_and_allow_red_waives_named() {
  local case_dir rc head
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  case_dir=$(make_case github-red-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/80 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-red: a red check must refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "github-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-red: gh pr merge ran on a red PR"

  case_dir=$(make_case github-allow-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/81 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-allow-red: named waiver should merge"
  assert_logged_gh_merge "$case_dir" 81 example/repo --squash
  pass "fm-pr-merge refuses red GitHub checks and waives only a named --allow-red check"
}

# When the base branch advances, GitHub cancels a pull request's in-flight run
# and re-triggers it, leaving the cancelled run in the rollup beside the passing
# re-run while reporting the pull request itself CLEAN. The merge must follow the
# current run rather than the one that re-run replaced.
test_superseded_failed_check_run_no_longer_refuses() {
  local case_dir head
  head=cccccccccccccccccccccccccccccccccccccccc
  case_dir=$(make_case github-superseded-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED CANCELLED 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/90 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-superseded-red: a failed run replaced by a passing re-run must merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 90 example/repo --squash
  pass "fm-pr-merge merges when a failed check run was replaced by a passing re-run"
}

# Legacy status contexts remain independent from check runs, even when their
# reported names match.
test_check_runs_never_supersede_status_contexts() {
  local case_dir rc head
  head=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  case_dir=$(make_case github-cross-check-kind)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(status_context ci FAILURE)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-cross-check-kind: a failing status context must refuse"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-cross-check-kind: the status context was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-cross-check-kind: a passing check run hid a failing status context"
  pass "fm-pr-merge never lets a check run supersede a legacy status context"
}

# The inverse, and the one that matters most: a check whose current run failed is
# still red however many earlier runs of it passed.
test_current_failed_check_run_still_refuses() {
  local case_dir rc head
  head=dddddddddddddddddddddddddddddddddddddddd
  case_dir=$(make_case github-current-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/91 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-current-red: a currently failing check must refuse"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-current-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-current-red: gh pr merge ran on a currently failing check"
  pass "fm-pr-merge still refuses when a check's current run failed after an earlier pass"
}

# Run generation follows startedAt rather than the order overlapping runs finish.
test_late_finishing_old_success_does_not_hide_current_failure() {
  local case_dir rc head
  head=dededededededededededededededededededede
  case_dir=$(make_case github-old-success-finishes-last)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:01Z 2026-01-01T00:00:10Z)" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:09Z 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/98 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-old-success-finishes-last: the later-started failure must refuse"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-old-success-finishes-last: the current failure was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-old-success-finishes-last: completion order hid the current failure"
  pass "fm-pr-merge uses start order when the old success finishes last"
}

# A cancelled old run may settle after the passing re-run that superseded it.
test_late_finishing_old_cancellation_is_superseded() {
  local case_dir head
  head=dfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdf
  case_dir=$(make_case github-old-cancellation-finishes-last)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED CANCELLED 2026-01-01T00:00:01Z 2026-01-01T00:00:10Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z 2026-01-01T00:00:09Z)"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/99 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-old-cancellation-finishes-last: the passing re-run must merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 99 example/repo --squash
  pass "fm-pr-merge supersedes an old cancellation that finishes last"
}

# A re-run that has not finished proves nothing, so it can neither be superseded
# nor supersede: the check stays red whether the run it replaces passed or failed.
test_unfinished_rerun_keeps_a_check_red() {
  local case_dir rc head prior
  head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  for prior in FAILURE SUCCESS; do
    case_dir=$(make_case "github-pending-rerun-$prior")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED "$prior" 2026-01-01T00:00:01Z)" \
      "$(check_run ci IN_PROGRESS - -)"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/92 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-pending-rerun-$prior: an unfinished re-run must refuse"
    assert_grep "check 'ci' is not green" "$case_dir/stderr" \
      "github-pending-rerun-$prior: the pending check was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-pending-rerun-$prior: gh pr merge ran with a re-run still in flight"
  done
  pass "fm-pr-merge keeps a check red while its re-run is still in flight"
}

# Supersession is scoped to one check name, which is also the name --allow-red
# matches, so a newer passing check never clears a different check's failure.
test_supersession_never_crosses_check_names() {
  local case_dir rc head
  head=ffffffffffffffffffffffffffffffffffffffff
  case_dir=$(make_case github-cross-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/93 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-cross-name: another check passing must not clear this failure"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "github-cross-name: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-cross-name: gh pr merge ran on a red check of a different name"
  pass "fm-pr-merge never lets one check's pass clear another check's failure"
}

# Supersession has to be proven from the forge's own start timestamps, so a run
# GitHub dated in any other way is treated as undated and clears nothing.
test_undated_runs_never_supersede() {
  local case_dir rc spec label older newer
  local head=0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a
  set -- \
    'undated-failure|-|2026-01-01T00:00:09Z' \
    'undated-pass|2026-01-01T00:00:01Z|-' \
    'fractional-pass|2026-01-01T00:00:01Z|2026-01-01T00:00:09.500Z' \
    'offset-pass|2026-01-01T00:00:01Z|2026-01-01T00:00:09+00:00'
  for spec in "$@"; do
    label=${spec%%|*}
    older=${spec#*|}
    older=${older%%|*}
    newer=${spec##*|}
    case_dir=$(make_case "github-undated-$label")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED FAILURE "$older")" \
      "$(check_run ci COMPLETED SUCCESS "$newer")"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/94 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-undated-$label: an unproven supersession must refuse"
    assert_grep "check 'ci' is not green" "$case_dir/stderr" \
      "github-undated-$label: the red check was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-undated-$label: gh pr merge ran on an unproven supersession"
  done
  pass "fm-pr-merge clears a failure only on a proven later pass of the same check"
}

# A superseded failure changes nothing about the waiver: --allow-red still covers
# exactly the named check, still needs every other check green, and the merge is
# still bound to the verified head.
test_allow_red_still_waives_only_the_current_failure() {
  local case_dir rc head
  head=0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b
  case_dir=$(make_case github-superseded-allow-red-wrong-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    --allow-red ci > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "superseded-allow-red-wrong-name: waiving the green check must not merge"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "superseded-allow-red-wrong-name: the unwaived red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "superseded-allow-red-wrong-name: gh pr merge ran with an unwaived red check"

  case_dir=$(make_case github-superseded-allow-red-named)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    --allow-red lint > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "superseded-allow-red-named: the named waiver should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 96 example/repo --squash
  pass "fm-pr-merge keeps --allow-red scoped to its named check beside a superseded failure"
}

test_allow_red_is_refused_while_away() {
  local case_dir rc head
  head=abababababababababababababababababababab
  case_dir=$(make_case github-allow-red-away)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-away: --allow-red must be refused while away"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "github-allow-red-away: refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-away: gh pr merge ran despite away --allow-red"

  case_dir=$(make_case github-allow-red-away-after-view)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --grant task-x1
  mv "$case_dir/state/.afk-contract" "$case_dir/away-record-after-view"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-away-after-view: late away publication must refuse --allow-red"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "github-allow-red-away-after-view: late refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-away-after-view: gh pr merge ran after late away publication"
  pass "fm-pr-merge rechecks away presence before an attended red merge"
}

test_allow_red_requires_one_separate_name() {
  local case_dir rc head
  head=afafafafafafafafafafafafafafafafafafafaf

  case_dir=$(make_case github-allow-red-equals)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/87 \
    --allow-red=lint > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-equals: equals form must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-equals: gh pr merge ran for the equals alias"

  case_dir=$(make_case github-allow-red-duplicate)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/88 \
    --allow-red lint --allow-red unit > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-duplicate: duplicate waiver must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-duplicate: gh pr merge ran for duplicate waivers"
  pass "fm-pr-merge accepts exactly one separately named red-check waiver"
}

test_away_grant_and_yolo_and_hold_for_return() {
  local case_dir rc url head
  head=acacacacacacacacacacacacacacacacacacacac
  url=https://github.com/example/repo/pull/83

  case_dir=$(make_case away-held)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir"
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-held: ungranted merge must refuse"
  assert_grep 'task task-x1 is held for the captain return' "$case_dir/stderr" \
    "away-held: refusal did not name hold-for-return"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-held: gh pr merge ran without a grant"

  case_dir=$(make_case away-held-attended-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir"
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" --attended-override \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-held-override: --attended-override must not skip the grant"
  assert_grep 'task task-x1 is held for the captain return' "$case_dir/stderr" \
    "away-held-override: override skipped the grant"

  case_dir=$(make_case away-grant)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --grant task-x1
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-grant: granted green merge should succeed"
  assert_logged_gh_merge "$case_dir" 83 example/repo --squash
  assert_grep "merge landed: task-x1 $url away-grant" "$case_dir/state/.wake-queue" \
    "away-grant: the durable outcome did not tag away-grant"

  case_dir=$(make_case away-yolo)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  printf '\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
  write_away_record "$case_dir"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-yolo: yolo green merge should succeed"
  assert_grep "merge landed: task-x1 $url yolo" "$case_dir/state/.wake-queue" \
    "away-yolo: the durable outcome did not tag yolo"
  pass "away merges require yolo or a grant, and --attended-override does not skip that"
}

test_away_posture_refuses_asynchronous_merge_paths() {
  local case_dir rc url head merge_line
  head=abababababababababababababababababababab
  url=https://github.com/example/repo/pull/89

  case_dir=$(make_case away-auto-refused)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-auto-refused: fork allow-list must refuse auto-merge"
  assert_grep 'refusing to forward --auto' "$case_dir/stderr" \
    "away-auto-refused: refusal did not name the asynchronous flag"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-auto-refused: gh pr merge ran for an away auto-merge request"

  case_dir=$(make_case away-queue-refused)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-queue-refused: a required merge queue must refuse before submission"
  assert_grep 'merge-queue state does not prove an immediate merge' "$case_dir/stderr" \
    "away-queue-refused: refusal did not explain the away restriction"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-queue-refused: gh received a merge that could enter its queue"

  case_dir=$(make_gitlab_case away-gitlab-auto)
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --attended-override -- --auto-merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-gitlab-auto: GitLab auto-merge must refuse"
  assert_grep 'refusing to forward --auto-merge' "$case_dir/stderr" \
    "away-gitlab-auto: refusal did not name auto-merge"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "away-gitlab-auto: glab received an asynchronous merge"

  case_dir=$(make_gitlab_case away-gitlab-configured merge_when_pipeline_succeeds=true)
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-gitlab-configured: configured auto-merge must refuse"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "away-gitlab-configured: glab received a configured asynchronous merge"

  case_dir=$(make_gitlab_case away-gitlab-sync)
  write_away_record "$case_dir" --grant task-x1
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "away-gitlab-sync: an immediate granted merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *" --auto-merge=false") ;;
    *) fail "away-gitlab-sync: the final glab flag did not force an immediate merge: '$merge_line'" ;;
  esac
  pass "away posture permits immediate merges but refuses every asynchronous path"
}

test_away_grant_does_not_bypass_red_or_identity() {
  local case_dir rc head
  head=adadadadadadadadadadadadadadadadadadadad
  case_dir=$(make_case away-grant-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --grant task-x1
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-grant-red: a grant must not waive red checks"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "away-grant-red: C1 did not refuse the red check"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-grant-red: gh pr merge ran on a granted red PR"

  case_dir=$(make_case pr-identity-mismatch)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '\npr=https://github.com/example/repo/pull/99\n' >> "$case_dir/state/task-x1.meta"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/85 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "pr-identity: a different recorded URL must refuse"
  assert_grep 'is bound to https://github.com/example/repo/pull/99' "$case_dir/stderr" \
    "pr-identity: refusal did not name the recorded URL"
  pass "a grant does not bypass red checks, and a recorded pr= must match the URL"
}

test_unreadable_away_record_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case away-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae
  printf 'not-a-contract\n' > "$case_dir/state/.afk-contract"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/86 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-unreadable: an unreadable away record must refuse"
  assert_grep 'away-posture record could not be read' "$case_dir/stderr" \
    "away-unreadable: refusal did not fail closed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-unreadable: gh pr merge ran despite an unreadable record"
  pass "an unreadable away-posture record refuses the merge instead of skipping the grant"
}

# The race this closes: the away record is read for merge authority and the
# forge is called afterwards, so an archive (the captain's return) or a grant
# revocation landing in between would merge on authority that no longer holds.
# away_change_script writes the change the gh mock attempts from inside the
# forge call, which IS that window. Its body drives the real away-record
# commands /afk and the return use, never a file edit, and takes a one-second
# lock bound so a contended case refuses quickly instead of waiting.
away_change_script() {  # <case-dir> <name>; script body on stdin
  local case_dir=$1 name=$2 path
  path="$case_dir/$name"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -eu\n'
    printf 'export FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1\n'
    printf 'CONTRACT="%s/bin/fm-afk-contract.sh"\n' "$ROOT"
    cat
  } > "$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

# Two away-record changes, each attempted from inside the merge's critical
# section: the archive a captain return performs, and the replacement that
# revokes a grant. Neither may land there, and the merge must still complete on
# the authority it read.
test_away_record_cannot_change_between_the_authority_read_and_the_merge() {
  local case_dir rc mutate
  case_dir=$(make_case away-archive-at-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b
  write_away_record "$case_dir" --grant task-x1
  mutate=$(away_change_script "$case_dir" archive-at-merge <<'SH'
"$CONTRACT" archive
SH
  )

  export FM_TEST_AWAY_MUTATE_AT_MERGE="$mutate"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AWAY_MUTATE_AT_MERGE

  expect_code 0 "$rc" "away-archive-at-merge: the granted green merge should still land"
  [ -s "$case_dir/away-mutate-rc" ] \
    || fail "away-archive-at-merge: the archive was never attempted inside the merge"
  [ "$(cat "$case_dir/away-mutate-rc")" != 0 ] \
    || fail "away-archive-at-merge: the archive landed inside the merge's critical section"
  assert_grep 'locked by live process' "$case_dir/away-mutate-output" \
    "away-archive-at-merge: the refused archive did not name the live holder"
  assert_equals task-x1 "$(cat "$case_dir/away-grants-at-merge" 2>/dev/null || true)" \
    "away-archive-at-merge: the grant this merge read was not still standing at the forge call"
  assert_grep "merge landed: task-x1 https://github.com/example/repo/pull/71 away-grant" \
    "$case_dir/state/.wake-queue" \
    "away-archive-at-merge: the landed merge was not recorded under the grant it read"
  # The lock goes with the merge rather than leaking: the captain's return
  # archives the record on its first try once the merge is done.
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null \
    || fail "away-archive-at-merge: the record stayed locked after the merge"

  case_dir=$(make_case away-revoke-at-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c
  write_away_record "$case_dir" --grant task-x1
  mutate=$(away_change_script "$case_dir" revoke-at-merge <<'SH'
"$CONTRACT" propose --grant task-other
"$CONTRACT" confirm
SH
  )
  export FM_TEST_AWAY_MUTATE_AT_MERGE="$mutate"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AWAY_MUTATE_AT_MERGE

  expect_code 0 "$rc" "away-revoke-at-merge: the granted green merge should still land"
  [ "$(cat "$case_dir/away-mutate-rc" 2>/dev/null || true)" != 0 ] \
    || fail "away-revoke-at-merge: the replacement landed inside the critical section"
  assert_equals task-x1 "$(cat "$case_dir/away-grants-at-merge" 2>/dev/null || true)" \
    "away-revoke-at-merge: the grant was revoked inside the merge's critical section"
  pass "no away-record archive or grant revocation lands between the authority read and the merge"
}

# The same serialization from the other side. A revocation that wins the race
# lands BEFORE the in-lock authority read, and the merge then refuses: the lock
# decides an order, it never lets a stale grant through.
test_a_grant_revoked_before_the_merge_refuses_it() {
  local case_dir rc
  case_dir=$(make_case away-revoked-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d
  write_away_record "$case_dir"
  mv "$case_dir/state/.afk-contract" "$case_dir/away-record-after-view"
  write_away_record "$case_dir" --grant task-x1

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "away-revoked-before-merge: a revoked grant must refuse"
  assert_grep 'held for the captain return' "$case_dir/stderr" \
    "away-revoked-before-merge: refusal did not name hold-for-return"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-revoked-before-merge: gh pr merge ran on a revoked grant"
  pass "a grant revoked before the merge's own authority read refuses the merge"
}

# Fail closed. The lock is what makes the authority read and the merge one
# action, so a merge that cannot take it has no locked window to merge in and
# refuses - including on this attended case, where the record is absent and
# there is no grant to check at all.
test_merge_refuses_when_the_away_record_cannot_be_locked() {
  local case_dir rc holder_pid i lock
  case_dir=$(make_case away-lock-unavailable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e
  lock="$case_dir/state/.afk-contract.lock"

  FM_STATE_OVERRIDE="$case_dir/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 10
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$case_dir/holder.ready" "$case_dir/release-holder" &
  holder_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$case_dir/holder.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$case_dir/holder.ready" ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "away-lock-unavailable: the fixture never took the record lock"; }

  export FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT
  : > "$case_dir/release-holder"
  wait "$holder_pid" || fail "away-lock-unavailable: the fixture holder did not release cleanly"

  expect_code 1 "$rc" "away-lock-unavailable: an unlockable away record must refuse the merge"
  assert_grep 'could not be locked for the merge' "$case_dir/stderr" \
    "away-lock-unavailable: refusal did not name the lock it could not take"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-lock-unavailable: gh pr merge ran without the away-record lock"
  pass "a merge that cannot lock the away record refuses instead of merging unlocked"
}

test_allow_red_refused_on_gitlab() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-allow-red)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "gitlab-allow-red: --allow-red must not apply on GitLab"
  assert_grep '--allow-red does not apply to GitLab' "$case_dir/stderr" \
    "gitlab-allow-red: refusal did not name GitLab"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-allow-red: glab ran despite --allow-red"
  pass "fm-pr-merge refuses --allow-red on GitLab"
}

test_gitlab_head_override_args_refuse_before_recording
test_github_still_forwards_sha_arg
test_secondmate_merge_reports_upward_once
test_secondmate_merge_reports_on_the_local_route
test_gitlab_merge_reports_upward
test_queued_gitlab_merge_leaves_the_poll_armed
test_failed_merge_reports_nothing
test_gitlab_refusal_reports_nothing
test_main_home_merge_leaves_a_durable_wake
test_queued_github_merge_leaves_the_poll_armed
test_distinct_merged_prs_keep_distinct_wakes
test_uncommitted_marker_retry_is_never_silent
test_secondmate_without_parent_binding_is_loud
test_absent_backlog_still_merges
test_unreadable_backlog_refuses_the_merge
test_unreadable_backend_config_refuses_the_merge
test_unreadable_user_backend_config_refuses_the_merge
test_untraversable_user_backend_config_directory_refuses_the_merge
test_absent_user_backend_config_directory_and_backlog_still_merge
test_backend_override_bypasses_unreadable_user_config

# THE LANDED-MERGE INVARIANT.
#
# Asserted as a POSITIVE property rather than policed by inspection: EVERY path
# on which this script observes a landed merge must reach outcome reporting and
# exit zero. It is written this way because the opposite contract - that a
# landed-but-unrecorded merge should fail - has previously reached the code, a
# test, and the architecture document by three separate routes, and an
# enumeration of the paths that get it wrong cannot keep finding them.
#
# SIX routes, each separated from every other by ONE STATED SENTENCE naming
# WHERE it observes the landing. The count has been wrong three times under a
# header rule asking for exactly that, most recently when the preflight's
# carried-forward observation collapsed four of the GitHub routes onto one read:
# every route shared an already-merged fixture, so the PRE-merge read proved the
# landing every time and the reads the other routes are named for never ran at
# all. A comment cannot keep finding that, so two mechanisms enforce it and both
# are executable:
#
#   1. FIXTURES THAT ONLY ONE READ CAN SATISFY. Every route but preflight-landed
#      reads the pull request OPEN until the merge is attempted and MERGED
#      afterwards, so exiting zero is impossible without reaching the read its own
#      sentence names. Delete the read that follows a SUCCESSFUL merge command and
#      post-mutation and both degraded routes fail; delete the one on the
#      command-FAILURE branch and command-error fails; delete the preflight
#      carry-forward and preflight-landed fails. Each names a different call site,
#      which is what the shared already-merged fixture used to hide.
#   2. A WITNESS PER ROUTE, required to be pairwise distinct. Each route records
#      how many outcome reads each reader answered and whether the run had to
#      reconcile a failed command against the readback, taken from the mocks' own
#      logs. Two routes that arrive at the same observation point produce the same
#      witness and this case FAILS instead of passing twice.
#
# Adding a genuinely new way to observe a landed merge means adding one line to
# the loop AND its sentence AND a fixture no other route's witness matches.
#
#   github|post-mutation           the merge command succeeds and the read AFTER
#                                  it is what confirms the landing; the preflight
#                                  read this pull request as open
#   github|preflight-landed        the pull request was ALREADY merged when this
#                                  run started, so the PRE-merge target read is
#                                  the only read that ever proves it - every read
#                                  after it fails
#   github|command-error           the merge command FAILS and the read that
#                                  follows the failure confirms it landed anyway
# Missing gh now refuses before any observation; the required-tool tests own
# that refusal rather than treating it as a reachable landed-outcome route.
#   github|degraded-gh-failed      gh is present and consulted, its read fails,
#                                  and the gh-axi fallback's POST-merge answer
#                                  proves the merge
#   gitlab|post-mutation           the merge command succeeds and the
#                                  confirmation read proves it
#   gitlab|command-error           the merge command FAILS and the confirmation
#                                  read proves it landed anyway
#
# NOT COVERED, deliberately: a queued request is not a landed merge and is
# refused rather than reported, which test_queued_github_merge_leaves_the_poll_armed
# and test_queued_gitlab_merge_leaves_the_poll_armed own. Nor is a pull request
# already merged into a NON-DEFAULT branch: that one never reaches this verdict,
# because the merge-target precondition refuses it before any of these routes
# begin, and test_merged_non_default_target_is_refused owns it.
test_every_landed_observation_reaches_outcome_reporting() {
  local case_dir number=700 provider route spec url rc run_path
  local gh_reads axi_views glab_views reconciled witness_file total distinct
  witness_file="$TMP_ROOT/landed-invariant-witnesses"
  : >"$witness_file"
  for spec in \
    github\|post-mutation \
    github\|preflight-landed \
    github\|command-error \
    github\|degraded-gh-failed \
    gitlab\|post-mutation \
    gitlab\|command-error; do
    provider=${spec%%|*}
    route=${spec#*|}
    number=$((number + 1))
    case_dir=$(make_home_case "landed-invariant-$provider-$route")
    mkdir -p "$case_dir/wt"
    run_path=

    if [ "$provider" = github ]; then
      url="https://github.com/example/repo/pull/$number"
      add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      : >"$case_dir/gh-axi.log"
      # OPEN before the mutation, MERGED after it. Sharing one already-merged
      # fixture across these routes is what collapsed four of them onto the
      # preflight read, so every route but preflight-landed starts from a pull
      # request no PRE-merge read can prove landed.
      write_github_outcome "$case_dir" OPEN false false main
      case "$route" in
        post-mutation)
          # The merge command succeeds and the read after it sees the landing.
          add_gh_axi_mock_open_until_merged "$case_dir" 0
          ;;
        preflight-landed)
          # Already merged before this run: the pre-merge target read answers
          # once and every read after it fails, on both readers. Only the
          # observation the preflight carried forward can reach outcome
          # reporting, so this route fails outright if that observation is
          # discarded rather than carried.
          write_github_outcome "$case_dir" MERGED true false main
          : > "$case_dir/github-outcome.initially-merged"
          add_gh_mock_outcome_read_fails_from "$case_dir" \
            aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2
          cat >"$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") exit 1 ;;
  api\ *) exit 1 ;;
esac
exit 0
SH
          chmod +x "$case_dir/fakebin/gh-axi"
          ;;
        command-error)
          # The merge command fails after the merge landed; the read that
          # follows the failure is what observes it.
          add_gh_axi_mock_open_until_merged "$case_dir" 1
          ;;
        degraded-gh-failed)
          # gh present but its read fails; the gh-axi fallback proves the merge.
          # It logs before failing, which is how this route proves it is the one
          # where gh WAS consulted rather than the one where gh does not exist.
          add_gh_axi_mock_open_until_merged "$case_dir" 0
          : > "$case_dir/github-graphql-fail"
          ;;
      esac
    else
      url="https://gitlab.com/example/repo/-/merge_requests/$number"
      add_glab_mock "$case_dir"
      : >"$case_dir/glab.log"
      write_mr_json "$case_dir/mr.json"
      write_mr_json "$case_dir/mr-post.json" state=merged
      if [ "$route" = command-error ]; then
        # The merge command fails, and the forge reports the merge landed anyway,
        # so the confirmation read is what observes it. The shared mock cannot
        # express that: it only switches to the merged view once a SUCCESSFUL
        # merge has run. This mock reports the request open until the merge is
        # attempted and merged afterwards, whatever the command's exit status.
        cat >"$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case_dir=$(dirname "$FM_TEST_GLAB_JSON")
case "${1:-} ${2:-}" in
  "api projects/"*|"api version")
    printf '{"merge_method":"merge"}\n'
    ;;
  "mr view")
    if [ -e "$case_dir/glab-merge-attempted" ]; then
      cat "$case_dir/mr-post.json"
    else
      cat "$FM_TEST_GLAB_JSON"
    fi
    ;;
  "mr merge")
    : > "$case_dir/glab-merge-attempted"
    echo "error: mr merge failed" >&2
    exit 1
    ;;
esac
exit 0
SH
        chmod +x "$case_dir/fakebin/glab"
      fi
    fi

    set +e
    if [ -n "$run_path" ]; then
      PATH="$run_path" FM_TEST_HOME="$case_dir/home" \
        run_pr_merge "$case_dir" task-x1 "$url" \
          >"$case_dir/stdout" 2>"$case_dir/stderr"
    else
      FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
        >"$case_dir/stdout" 2>"$case_dir/stderr"
    fi
    rc=$?
    set -e

    expect_code 0 "$rc" \
      "landed-invariant $provider/$route: an observed landed merge must exit zero"
    assert_grep "$url" "$case_dir/state/.wake-queue" \
      "landed-invariant $provider/$route: the landed outcome was not recorded durably"

    # THE WITNESS: which reader answered how many outcome reads, and whether the
    # run had to reconcile a failed command against the readback. Read back out
    # of the mocks' own logs rather than declared, because a route that declares
    # where it observed the landing is exactly what four routes were doing while
    # all four observed it in the same place.
    gh_reads=$(count_log_lines "$case_dir/gh.log" '^api graphql')
    axi_views=$(count_log_lines "$case_dir/gh-axi.log" '^pr view ')
    glab_views=$(count_log_lines "$case_dir/glab.log" ' mr view ')
    reconciled=no
    if grep -q 'but the forge reads it back as landed' "$case_dir/stderr"; then
      reconciled=yes
    fi
    printf '%s gh-reads=%s gh-axi-views=%s glab-views=%s reconciled=%s\n' \
      "$provider" "$gh_reads" "$axi_views" "$glab_views" "$reconciled" \
      >>"$witness_file"

    # Each route must stay the route it is named for AND reach its own
    # observation point. Exiting zero with the outcome recorded says neither: it
    # is the one thing all six have in common.
    case "$provider|$route" in
      github\|post-mutation)
        # Two reads, the preflight seeing an open pull request and the post-merge
        # read seeing the landing. One read means the preflight proved it, which
        # is preflight-landed's route and not this one.
        [ "$gh_reads" = 2 ] \
          || fail "landed-invariant github/post-mutation: the landing was not observed by a read AFTER the merge (gh answered $gh_reads outcome reads)"
        [ "$axi_views" = 0 ] \
          || fail "landed-invariant github/post-mutation: the degraded reader answered on a route where gh works"
        assert_grep "verified: $url is merged" "$case_dir/stdout" \
          "landed-invariant github/post-mutation: the readback's landing was not reported"
        ;;
      github\|preflight-landed)
        # An already-landed request needs neither another mutation nor another
        # outcome read; both can introduce false failures after success.
        assert_no_grep 'pr merge' "$case_dir/gh.log" \
          "landed-invariant github/preflight-landed: an already-landed request was mutated again"
        [ "$gh_reads" = 1 ] \
          || fail "landed-invariant github/preflight-landed: a landing the preflight already observed was read back again (gh answered $gh_reads outcome reads)"
        [ "$axi_views" = 0 ] \
          || fail "landed-invariant github/preflight-landed: the degraded reader was asked to re-prove a landing the preflight had"
        ;;
      github\|command-error)
        [ "$gh_reads" = 2 ] \
          || fail "landed-invariant github/command-error: the landing was not observed by the read that follows the failed command (gh answered $gh_reads outcome reads)"
        [ "$axi_views" = 0 ] \
          || fail "landed-invariant github/command-error: the degraded reader answered on a route where gh works"
        ;;
      github\|degraded-gh-failed)
        [ -s "$case_dir/gh.log" ] \
          || fail "landed-invariant github/degraded-gh-failed: gh was never consulted, so this is the no-gh route"
        [ "$gh_reads" = 2 ] \
          || fail "landed-invariant github/degraded-gh-failed: gh was not asked for the outcome on both sides of the merge (it was asked $gh_reads times)"
        [ "$axi_views" = 2 ] \
          || fail "landed-invariant github/degraded-gh-failed: the gh-axi fallback did not prove the merge AFTER it landed (it answered $axi_views views)"
        ;;
      gitlab\|post-mutation)
        # Two reads: the pre-merge conditions, and the confirmation after the
        # merge. The shared glab mock reports the request open until `mr merge`
        # succeeds, and an unconfirmed landing exits zero recording NOTHING, so
        # the durable outcome asserted above can only come from the second read.
        [ "$glab_views" = 2 ] \
          || fail "landed-invariant gitlab/post-mutation: the confirmation read after the merge did not run (glab answered $glab_views views)"
        ;;
    esac
    case "$route" in
      post-mutation)
        # This route's command SUCCEEDS. Reconciling a failed command against the
        # readback is command-error's own signature, and a post-mutation route
        # that produces it has become that route.
        [ "$reconciled" = no ] \
          || fail "landed-invariant $provider/post-mutation: the merge command failed, so this ran command-error's route"
        ;;
      command-error)
        # Exiting zero is only half of this route's contract. The forge CLI has
        # just printed its own error, so a run that then exits zero saying
        # nothing reads as an unexplained success. Asserted for BOTH forges from
        # one place: the silence being closed here existed on GitLab alone
        # precisely because only one forge's message was ever written.
        assert_grep 'but the forge reads it back as landed' "$case_dir/stderr" \
          "landed-invariant $provider/$route: a failed merge command that landed exited zero without reconciling the two"
        ;;
    esac
  done

  # THE MATRIX REFUSES TO COLLAPSE. Six routes that reached six different
  # observation points leave six different witnesses; two routes that ended up
  # in the same place leave the same witness twice and this fails, which is the
  # check the route count has been missing every time it was wrong.
  total=$(wc -l <"$witness_file" | tr -d '[:space:]')
  distinct=$(sort -u "$witness_file" | wc -l | tr -d '[:space:]')
  [ "$total" = 6 ] \
    || fail "landed-invariant: $total routes ran, and the sentences above name six"
  [ "$total" = "$distinct" ] || {
    sort "$witness_file" >&2
    fail "landed-invariant: only $distinct of $total routes reached a distinct observation point, so the matrix is smaller than it claims"
  }
  pass "every path that observes a landed merge reaches outcome reporting"
}

test_every_landed_observation_reaches_outcome_reporting

# THE MERGE-TARGET CONTRACT'S REFUSAL BRANCH.
#
# Every earlier case proved only the PERMIT branch, which is how two vacuous
# implementations of this contract reached a fully passing suite: one where the
# host-qualified --repo silently unbound the repository, and one where the
# degraded-path parser read a trailing envelope field and made every target
# compare equal. A contract with no refusal test reports itself as working.
#
# These cases fail if the contract is removed, which is the property that
# matters - not that they pass while it is present.
test_non_default_target_is_refused_by_name() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/91
  case_dir=$(make_case target-refusal-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  # The PR targets a release branch while the repository default is main.
  write_github_outcome "$case_dir" OPEN false false 'release/2026' main
  : >"$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "target-refusal-gh: a non-default target must be refused"
  assert_grep 'release/2026' "$case_dir/stderr" \
    "target-refusal-gh: the refusal did not name the branch the PR actually targets"
  assert_grep 'current default branch main' "$case_dir/stderr" \
    "target-refusal-gh: the refusal did not name the default branch it is limited to"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "target-refusal-gh: a refused target still reached the forge"
  # A REFUSAL THAT LEAVES THE POLL ARMED IS NOT A REFUSAL. bin/fm-pr-poll.sh
  # reports a merged pull request with no notion of the branch it merged into,
  # so a poll armed here records the non-default landing this contract just
  # refused - later, and through a different writer. Fails if the contract is
  # evaluated after bin/fm-pr-check.sh has armed anything.
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "target-refusal-gh: a refused target armed a merge poll that would record the landing anyway"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "target-refusal-gh: a refused target recorded the pull request the poll reads from"
  pass "fm-pr-merge refuses a non-default target by name before any mutation"
}

# THE CONTRACT IS A PRECONDITION, AND AN ALREADY-MERGED PULL REQUEST STILL HAS TO
# PASS IT. A landed merge has no target left to REFUSE and it still has one left
# to REPORT. Hand-merge a pull request into release/2026 in a repository whose
# default is main and the pre-merge read observes MERGED: short-circuiting there
# skipped the comparison entirely, the carried-forward observation then skipped
# the post-merge read, and the run reported a verified landing - recording work
# onto a branch guarded merging was never permitted to touch, in the one case the
# contract most needs to hold.
#
# This is NOT the landed-merge verdict, and the two must not be reconciled. That
# verdict answers "did OUR merge land" and exits zero on the forge's own word;
# this answers "was this a permitted target at all". A merged pull request
# satisfies the first and can still fail the second.
test_merged_non_default_target_is_refused() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/99
  case_dir=$(make_home_case target-refusal-already-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  # Already merged, and merged into a release branch while the default is main.
  write_github_outcome "$case_dir" MERGED true false 'release/2026' main
  : > "$case_dir/github-outcome.initially-merged"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "target-refusal-already-merged: a merge into a non-default branch must not be accepted"
  assert_grep 'release/2026' "$case_dir/stderr" \
    "target-refusal-already-merged: the refusal did not name the branch the work was merged into"
  assert_grep 'current default branch main' "$case_dir/stderr" \
    "target-refusal-already-merged: the refusal did not name the default branch it is limited to"
  assert_grep 'already merged there' "$case_dir/stderr" \
    "target-refusal-already-merged: the refusal did not say the merge has already happened"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "target-refusal-already-merged: a merge onto a non-default branch was reported as verified"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "target-refusal-already-merged: a refused target still reached the forge"
  assert_absent "$case_dir/state/.wake-queue" \
    "target-refusal-already-merged: a merge onto a non-default branch was recorded as this task's landed outcome"
  # .wake-queue only covers the outcome THIS run would write. The merge poll is a
  # second, independent writer of the same ledger and reads only whether the pull
  # request is merged - which this one already is - so a poll armed behind this
  # refusal records the non-default landing on the next watcher tick.
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "target-refusal-already-merged: a refused target armed the poll that records a merged pull request regardless of its branch"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "target-refusal-already-merged: a refused target recorded the pull request the poll reads from"
  pass "fm-pr-merge refuses a pull request already merged into a non-default branch"
}

test_unestablished_target_is_refused() {
  local case_dir rc url ghless_path
  url=https://github.com/example/repo/pull/92
  case_dir=$(make_case target-refusal-unestablished)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  # Degraded path: no gh at all, and the api passthrough cannot answer, so the
  # target is never established. Unknown is not absent - this must refuse.
  cat >"$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
  api\ *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/github-graphql-fail"
  ghless_path="$case_dir/path-without-gh"
  ghless_path="$case_dir/fakebin:$PATH"
  : >"$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "target-refusal-unestablished: an unestablished target must be refused"
  assert_grep 'target branch could not be' "$case_dir/stderr" \
    "target-refusal-unestablished: the refusal did not say the target was never established"
  grep -q 'pr merge' "$case_dir/gh.log" \
    && fail "target-refusal-unestablished: a merge ran without an established target"
  pass "fm-pr-merge refuses when the merge target cannot be established"
}

test_degraded_path_reads_the_real_target() {
  local case_dir rc url ghless_path
  url=https://github.com/example/repo/pull/93
  case_dir=$(make_case target-refusal-degraded)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/github-graphql-fail"
  ghless_path="$case_dir/path-without-gh"
  ghless_path="$case_dir/fakebin:$PATH"
  # The shared mock emits the REAL gh-axi shape for this query: one TOON field
  # per line, which is what the reader is written against. The parse has been
  # vacuous on this path once already - an earlier reader took the last ": " in
  # the whole payload, got the envelope's own trailing field for both branches,
  # compared them equal and permitted every target.
  # state stays open so this case keeps testing the degraded READER against an
  # open pull request; an already-merged one is refused by the same comparison,
  # which test_merged_non_default_target_is_refused owns.
  FM_TEST_GH_AXI_BASE='release/2026' FM_TEST_GH_AXI_DEFAULT=main
  FM_TEST_GH_MERGE_STATE=open
  export FM_TEST_GH_AXI_BASE FM_TEST_GH_AXI_DEFAULT FM_TEST_GH_MERGE_STATE
  : >"$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_GH_AXI_BASE FM_TEST_GH_AXI_DEFAULT FM_TEST_GH_MERGE_STATE

  expect_code 1 "$rc" \
    "target-refusal-degraded: a non-default target must be refused on the degraded path too"
  assert_grep 'release/2026' "$case_dir/stderr" \
    "target-refusal-degraded: the degraded path did not read the real target branch"
  pass "fm-pr-merge reads the real target through the degraded reader's envelope"
}

# THE OTHER DEGRADED PATH: gh is INSTALLED but its read fails - an unauthenticated
# gh, a rate limit, a transient 5xx. The file header defines the degraded path as
# "gh is absent OR its read fails", so the target contract must hold here too.
#
# What this pins is the seam in bin/fm-pr-merge.sh: the post-merge outcome rule
# accepts the degraded gh-axi view only on a PROVED MERGE, because that view
# cannot tell an open pull request from a queued one; the pre-merge target check
# accepts it on BASE AND DEFAULT alone, because those are what it consumes and a
# proved merge is not evidence about a target. Collapse the two and this case
# fails in both directions at once: the refusing half stops naming the branch the
# pull request actually targets and blames an unreadable target instead, and the
# permitting half refuses every open pull request on any host carrying a broken
# gh - a merge that succeeds once gh is uninstalled entirely.
test_gh_failure_still_reads_the_target_through_gh_axi() {
  local case_dir rc url spec direction number base default
  number=94
  for spec in 'refuses|release/2026|main' 'permits|main|main'; do
    direction=${spec%%|*}
    base=$(printf '%s' "$spec" | cut -d'|' -f2)
    default=$(printf '%s' "$spec" | cut -d'|' -f3)
    number=$((number + 1))
    url="https://github.com/example/repo/pull/$number"
    case_dir=$(make_home_case "target-gh-failed-$direction")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
    printf 'base: %s\ndef: %s\n' "$base" "$default" >"$case_dir/gh-axi-target"
    # gh resolves and is consulted, and its outcome read fails every time. The
    # head lookup still answers, so this case is about the READ failing rather
    # than about gh being unusable.
    add_gh_mock_outcome_read_fails "$case_dir" ffffffffffffffffffffffffffffffffffffffff
    # The pull request is OPEN until the merge runs, so the target check cannot
    # short-circuit on an already-landed merge, and merged afterwards, so the
    # permitting direction reaches outcome reporting on its own evidence.
    cat >"$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case_dir=$(dirname "$FM_TEST_GH_AXI_LOG")
case "${1:-} ${2:-}" in
  "pr merge")
    : > "$FM_TEST_GH_OUTCOME.merge-called"
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    if [ -e "$FM_TEST_GH_OUTCOME.merge-called" ]; then
      printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
    else
      printf 'pull_request:\n  number: %s\n  state: open\n' "$3"
    fi
    ;;
  api\ *)
    case " $* " in
      *'{base:'*) cat "$case_dir/gh-axi-target" ;;
      *'{tip:'*) printf 'tip: %s\n' "$FM_TEST_DEFAULT_TIP" ;;
      *) echo "gh-axi mock: unmodelled api query: $*" >&2 ; exit 2 ;;
    esac
    ;;
esac
exit 0
SH
    chmod +x "$case_dir/fakebin/gh-axi"
    : >"$case_dir/gh-axi.log"
    : >"$case_dir/gh.log"

    set +e
    FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    [ -s "$case_dir/gh.log" ] \
      || fail "target-gh-failed-$direction: gh was never consulted, so this is the no-gh path"
    if [ "$direction" = refuses ]; then
      expect_code 1 "$rc" \
        "target-gh-failed-refuses: a non-default target must be refused when gh's read fails"
      assert_grep 'targets branch release/2026' "$case_dir/stderr" \
        "target-gh-failed-refuses: the refusal did not name the branch gh-axi just read"
      assert_grep 'current default branch main' "$case_dir/stderr" \
        "target-gh-failed-refuses: the refusal did not name the default branch"
      assert_no_grep 'target branch could not be read' "$case_dir/stderr" \
        "target-gh-failed-refuses: a target the degraded reader supplied was called unreadable"
      assert_no_grep 'pr merge' "$case_dir/gh.log" \
        "target-gh-failed-refuses: a refused target still reached the forge"
    else
      expect_code 0 "$rc" \
        "target-gh-failed-permits: a default target must merge even when gh's read fails"
      assert_grep 'pr merge' "$case_dir/gh.log" \
        "target-gh-failed-permits: an open pull request on the default branch never reached the merge"
      assert_grep "verified: $url is merged" "$case_dir/stdout" \
        "target-gh-failed-permits: the landed merge was not reported"
    fi
  done
  pass "the merge-target contract holds when gh is installed but its read fails"
}

# A GIT REF NAME MAY CONTAIN A COMMA OR BEGIN WITH A DASH, and the TOON encoder
# gh-axi 0.1.34 bundles QUOTES any scalar that does either, so the degraded
# reader is handed `base: "a,b"` rather than `base: a,b`. The two payloads below
# are that encoder's own output for those names, captured from it rather than
# written from memory.
#
# A reader that takes the quoted text literally compares names that differ only
# by their quotes, so it REFUSES a pull request that does target the default
# branch, and names branches nobody has - a wrong verdict, wrong labels, and no
# error anywhere. Both directions are covered because a reader that strips too
# much fails the refusing half exactly as one that strips nothing fails the
# permitting half.
test_degraded_target_reads_a_quoted_branch_name() {
  local case_dir rc url number=96 spec direction base_toon def_toon named
  for spec in 'permits|"a,b"|"a,b"|a,b' 'refuses|"-lead"|main|-lead'; do
    direction=$(printf '%s' "$spec" | cut -d'|' -f1)
    base_toon=$(printf '%s' "$spec" | cut -d'|' -f2)
    def_toon=$(printf '%s' "$spec" | cut -d'|' -f3)
    named=$(printf '%s' "$spec" | cut -d'|' -f4)
    number=$((number + 1))
    url="https://github.com/example/repo/pull/$number"
    case_dir=$(make_home_case "target-quoted-$direction")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
    # gh is installed and its outcome read fails, which is the degraded path the
    # api passthrough answers on. The head lookup still works, so this case is
    # about the READ rather than about gh being unusable.
    add_gh_mock_outcome_read_fails "$case_dir" ffffffffffffffffffffffffffffffffffffffff
    printf 'base: %s\ndef: %s\n' "$base_toon" "$def_toon" >"$case_dir/gh-axi-target"
    cat >"$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case_dir=$(dirname "$FM_TEST_GH_AXI_LOG")
case "${1:-} ${2:-}" in
  "pr merge")
    : > "$FM_TEST_GH_OUTCOME.merge-called"
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    if [ -e "$FM_TEST_GH_OUTCOME.merge-called" ]; then
      printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
    else
      printf 'pull_request:\n  number: %s\n  state: open\n' "$3"
    fi
    ;;
  api\ *)
    case " $* " in
      *'{base:'*) cat "$case_dir/gh-axi-target" ;;
      *'{tip:'*) printf 'tip: %s\n' "$FM_TEST_DEFAULT_TIP" ;;
      *) echo "gh-axi mock: unmodelled api query: $*" >&2 ; exit 2 ;;
    esac
    ;;
esac
exit 0
SH
    chmod +x "$case_dir/fakebin/gh-axi"
    : >"$case_dir/gh-axi.log"
    : >"$case_dir/gh.log"

    set +e
    FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    if [ "$direction" = refuses ]; then
      expect_code 1 "$rc" \
        "target-quoted-refuses: a non-default target must be refused"
      assert_grep "targets branch $named," "$case_dir/stderr" \
        "target-quoted-refuses: the refusal named a branch the encoder's quotes invented"
      assert_grep 'current default branch main' "$case_dir/stderr" \
        "target-quoted-refuses: the default branch was not read back cleanly"
      assert_no_grep 'pr merge' "$case_dir/gh.log" \
        "target-quoted-refuses: a refused target still reached the forge"
    else
      expect_code 0 "$rc" \
        "target-quoted-permits: a quoted name equal to the default must still merge"
      assert_grep 'pr merge' "$case_dir/gh.log" \
        "target-quoted-permits: a pull request on the default branch never reached the merge"
      assert_grep "verified: $url is merged" "$case_dir/stdout" \
        "target-quoted-permits: the landed merge was not reported"
    fi
  done
  pass "the degraded reader decodes a quoted branch name instead of comparing its quotes"
}

# THE BASE IS PINNED BY STATE, NOT ONLY BY NAME.
#
# The merge-target contract settles WHICH branch may be merged into. This settles
# WHICH STATE OF IT this run judged: the default branch's tip is read when that
# contract is settled and RE-READ IMMEDIATELY BEFORE THE MERGE CALL, and a tip
# that moved in between refuses. Refusing deferred execution is only half of the
# immediate-execution guarantee; without this half nothing ever compares a base
# at merge time, and the merge executes against whatever the branch happens to be
# when the forge acts.
#
# THREE ROUTES, because a guard tested in one direction cannot be told apart from
# one that always refuses: `moved` proves the refusal, `steady` proves the permit
# AND that a second read happened at all, and `unreadable` proves that a tip
# nothing could read refuses rather than passing as unmoved.
test_default_tip_movement_refuses_and_permits() {
  local case_dir rc url route number=110 tip_reads
  for route in moved steady unreadable; do
    number=$((number + 1))
    url="https://github.com/example/repo/pull/$number"
    case_dir=$(make_home_case "default-tip-$route")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    # OPEN until the merge runs: an already-landed pull request has no base left
    # to judge and skips this check, so a merged fixture would test nothing.
    write_github_outcome "$case_dir" OPEN false false main
    printf '%s\n' \
      'state=MERGED' 'merged=true' 'queued=false' 'base=main' 'default=main' \
      >"$case_dir/github-outcome.merged"
    # One tip per read, in order. The second line is the only difference between
    # the three routes.
    case "$route" in
      moved) printf '%s\n%s\n' "$DEFAULT_TIP" "$MOVED_DEFAULT_TIP" >"$case_dir/tips" ;;
      steady) printf '%s\n%s\n' "$DEFAULT_TIP" "$DEFAULT_TIP" >"$case_dir/tips" ;;
      unreadable) printf '%s\n\n' "$DEFAULT_TIP" >"$case_dir/tips" ;;
    esac
    cat >"$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case_dir=$(dirname "$FM_TEST_GH_AXI_LOG")
case "${1:-} ${2:-}" in
  "pr merge")
    cat "$FM_TEST_GH_OUTCOME.merged" > "$FM_TEST_GH_OUTCOME"
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    if grep -qx 'merged=true' "$FM_TEST_GH_OUTCOME"; then
      printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
    else
      printf 'pull_request:\n  number: %s\n  state: open\n' "$3"
    fi
    ;;
  api\ *)
    case " $* " in
      *'{base:'*) printf 'base: main\ndef: main\n' ;;
      *'{tip:'*)
        count=$(cat "$case_dir/tip-reads" 2>/dev/null || echo 0)
        count=$((count + 1))
        printf '%s\n' "$count" > "$case_dir/tip-reads"
        tip=$(sed -n "${count}p" "$case_dir/tips")
        [ -n "$tip" ] || { echo 'error: could not read the branch' >&2; exit 1; }
        printf 'tip: %s\n' "$tip"
        ;;
      *) echo "gh-axi mock: unmodelled api query: $*" >&2 ; exit 2 ;;
    esac
    ;;
esac
exit 0
SH
    chmod +x "$case_dir/fakebin/gh-axi"
    : >"$case_dir/gh-axi.log"

    set +e
    FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    tip_reads=$(count_log_lines "$case_dir/gh-axi.log" '/branches/')
    case "$route" in
      moved)
        expect_code 1 "$rc" \
          "default-tip-moved: a base that moved before the merge must be refused"
        assert_grep "moved from tip $DEFAULT_TIP" "$case_dir/stderr" \
          "default-tip-moved: the refusal did not name the tip this run judged"
        assert_grep "to tip $MOVED_DEFAULT_TIP" "$case_dir/stderr" \
          "default-tip-moved: the refusal did not name the tip the branch moved to"
        assert_no_grep 'pr merge' "$case_dir/gh.log" \
          "default-tip-moved: a merge ran against a base this run never judged"
        assert_absent "$case_dir/state/.wake-queue" \
          "default-tip-moved: a refused merge was recorded as a landed outcome"
        ;;
      steady)
        expect_code 0 "$rc" \
          "default-tip-steady: a base that did not move must still merge"
        assert_grep 'pr merge' "$case_dir/gh.log" \
          "default-tip-steady: an unmoved base was refused, so the guard refuses always"
        assert_grep "verified: $url is merged" "$case_dir/stdout" \
          "default-tip-steady: the landed merge was not reported"
        [ "$tip_reads" = 2 ] \
          || fail "default-tip-steady: the tip was read $tip_reads times, so it was not re-read immediately before the merge"
        ;;
      unreadable)
        expect_code 1 "$rc" \
          "default-tip-unreadable: a tip that could not be re-read must refuse"
        assert_grep 'could not be read' "$case_dir/stderr" \
          "default-tip-unreadable: the refusal did not say the tip could not be read"
        assert_no_grep 'pr merge' "$case_dir/gh.log" \
          "default-tip-unreadable: an unreadable tip was treated as an unmoved one"
        ;;
    esac
  done
  pass "the default-branch tip is re-read before the merge and a base that moved refuses"
}

test_non_default_target_is_refused_by_name
test_merged_non_default_target_is_refused
test_unestablished_target_is_refused
test_degraded_path_reads_the_real_target
test_gh_failure_still_reads_the_target_through_gh_axi
test_degraded_target_reads_a_quoted_branch_name
test_default_tip_movement_refuses_and_permits

# A landed merge this run already observed must never be re-read, because a
# transient failure on that second read would strand a merge that is already on
# the default branch with nothing recording it. Fails if the second read is
# reinstated for the already-observed case.
#
# The FIRST read here is the pre-merge target read, and every read after it
# fails, so this case also fails if that read's landed observation is discarded
# instead of carried forward to the outcome decision.
test_observed_landed_merge_is_not_reread() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/94
  case_dir=$(make_home_case landed-no-second-read)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  write_github_outcome "$case_dir" MERGED true false main
  # The merge command fails, the pre-merge target read confirms the merge landed,
  # and every read after that fails. The outcome must still be recorded.
  cat >"$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql")
    count_file="$FM_TEST_GH_OUTCOME.reads"
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    [ "$count" -ge 2 ] && { echo 'error: transient forge failure' >&2; exit 1; }
    cat "$FM_TEST_GH_OUTCOME"
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  cat >"$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "simulated transport failure after the merge landed" >&2; exit 1 ;;
  "pr view") exit 1 ;;
  api\ *)
    case " $* " in
      *'{base:'*) ;;
      *) echo "gh-axi mock: unmodelled api query: $*" >&2 ; exit 2 ;;
    esac
    printf 'base: main\ndef: main\n'
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" \
    "landed-no-second-read: an already-observed landed merge must not fail on a later read"
  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "landed-no-second-read: the observed landed merge never reached outcome reporting"
  pass "an already-observed landed merge is not re-read and still records its outcome"
}

test_observed_landed_merge_is_not_reread

# THE GITLAB AUTOMATIC-REBASE GUARD, both directions.
#
# A guard makes TWO claims - that it refuses what it must, and that it permits
# what it must - and testing only one is how a fail-always control passes for a
# working one. Deleting gitlab_require_attested_merge used to leave this whole
# suite green, because only the permit path ran, incidentally, off a mock default.
#
# The bound is narrow on purpose: automatic rebase applies only to rebase_merge
# and ff, runs only when the source is BEHIND the target, became generally
# available in GitLab 19.2, and its API field first appears in 19.4. Refusing
# outside that window removes legitimate merges.
test_gitlab_auto_rebase_guard_refuses_and_permits() {
  local case_dir rc spec label project behind want
  for spec in \
    'enabled-and-behind|{"merge_method":"ff","automatic_rebase_enabled":true}|3|refuse' \
    'enabled-not-behind|{"merge_method":"ff","automatic_rebase_enabled":true}|0|permit' \
    'explicitly-disabled|{"merge_method":"ff","automatic_rebase_enabled":false}|3|permit' \
    'plain-merge-method|{"merge_method":"merge"}|3|permit' \
    'unreadable-method|{}|0|refuse' \
    'window-19-3-behind|{"merge_method":"rebase_merge"}|2|refuse' \
    'before-19-2|{"merge_method":"rebase_merge"}|2|permit'; do
    label=${spec%%|*}; spec=${spec#*|}
    project=${spec%%|*}; spec=${spec#*|}
    behind=${spec%%|*}; want=${spec#*|}
    case_dir=$(make_case "gitlab-rebase-$label")
    mkdir -p "$case_dir/wt"
    add_glab_mock "$case_dir"
    : >"$case_dir/glab.log"
    write_mr_json "$case_dir/mr.json"
    write_mr_json "$case_dir/mr-post.json" state=merged
    printf '%s\n' "$project" >"$case_dir/project.json"
    printf '%s\n' "$behind" >"$case_dir/behind"
    case "$label" in
      before-19-2) printf '19.1.0\n' >"$case_dir/version" ;;
      *) printf '19.3.0\n' >"$case_dir/version" ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e

    if [ "$want" = refuse ]; then
      expect_code 1 "$rc" "gitlab-rebase-$label: this case must be refused"
      assert_grep 'automatic' "$case_dir/stderr" \
        "gitlab-rebase-$label: the refusal did not name the automatic-rebase reason"
    else
      expect_code 0 "$rc" "gitlab-rebase-$label: this case must be permitted"
      assert_no_grep 'automatic_rebase' "$case_dir/stderr" \
        "gitlab-rebase-$label: a permitted case was refused for automatic rebase"
    fi
  done
  pass "the GitLab automatic-rebase guard refuses inside its window and permits outside it"
}

test_gitlab_auto_rebase_guard_refuses_and_permits

# THE OTHER HALF OF THE DEGRADED-VIEW SEAM, OVER BOTH DEGRADED ROUTES.
#
# The pre-merge target check accepts the degraded gh-axi view when it supplies a
# base and a default, because that is the question being asked of it. The
# POST-merge outcome question is different: the degraded view cannot tell an open
# pull request from a queued one, so only a proved merge makes it answerable, and
# anything else must be reported as an outcome that could not be READ rather than
# as a concrete not-merged verdict.
#
# The executable gh is required for head-bound mutation; its failed outcome
# read can still fall back to gh-axi, whose open state cannot prove a merge.
test_degraded_view_cannot_answer_the_post_merge_question() {
  local case_dir rc url route run_path number=95
  route=gh-failed
    number=$((number + 1))
    url="https://github.com/example/repo/pull/$number"
    case_dir=$(make_case "degraded-post-merge-unanswerable-$route")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
    write_github_outcome "$case_dir" OPEN false false main
    run_path=
    cat >"$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
  api\ *)
    case " $* " in
      *'{base:'*) printf 'base: main\ndef: main\n' ;;
      *'{tip:'*) printf 'tip: %s\n' "$FM_TEST_DEFAULT_TIP" ;;
      *) echo "gh-axi mock: unmodelled api query: $*" >&2 ; exit 2 ;;
    esac
    ;;
esac
exit 0
SH
    chmod +x "$case_dir/fakebin/gh-axi"
    add_gh_mock_outcome_read_fails_from "$case_dir" ffffffffffffffffffffffffffffffffffffffff 2
    : >"$case_dir/gh-axi.log"

    set +e
    if [ -n "$run_path" ]; then
      PATH="$run_path" run_pr_merge "$case_dir" task-x1 "$url" \
        >"$case_dir/stdout" 2>"$case_dir/stderr"
    else
      run_pr_merge "$case_dir" task-x1 "$url" \
        >"$case_dir/stdout" 2>"$case_dir/stderr"
    fi
    rc=$?
    set -e

    expect_code 1 "$rc" \
      "degraded-post-merge-unanswerable/$route: an unanswerable outcome must refuse"
    assert_grep 'could not read the GitHub pull request outcome' "$case_dir/stderr" \
      "degraded-post-merge-unanswerable/$route: an unreadable outcome was reported as a concrete verdict"
    # The concrete verdict is what the gh-absent route used to print for exactly
    # this evidence, which is the divergence between the two routes being closed.
    assert_no_grep 'GitHub merge outcome was not successful' "$case_dir/stderr" \
      "degraded-post-merge-unanswerable/$route: an outcome nothing proved was stated as a not-merged verdict"
    assert_no_grep 'verified: ' "$case_dir/stdout" \
      "degraded-post-merge-unanswerable/$route: an unproved merge was reported as verified"
  pass "a degraded outcome read cannot establish a merge without proof"
}

test_degraded_view_cannot_answer_the_post_merge_question

# Real Git histories prove the exception's parentage; only forge transport is
# mocked. Every refusal must leave the forge merge command uncalled.
test_reviewed_upstream_sync_policy_exception() {
  local case_dir scenario wt base target head id meta rc saved_tip url method filter
  saved_tip=$DEFAULT_TIP
  for scenario in attended away fix-forward absent-review stale-review wrong-target duplicate-review \
    wrong-mode wrong-task wrong-repo wrong-push wrong-upstream side-endpoint wrong-branch wrong-live-branch \
    wrong-live-repo wrong-local-head moved-base squash green-squash pending cancelled status-context lint-red lint-pending \
    extra-merge no-grant; do
    case_dir=$(make_case "sync-policy-$scenario")
    wt="$case_dir/wt"
    id=fm-upstream-sync-2026-09-14-tail
    url=https://github.com/HelloWorldSungin/firstmate/pull/96
    git init -q "$wt"
    git -C "$wt" commit -qm root --allow-empty
    git -C "$wt" checkout -qb upstream
    git -C "$wt" commit -qm upstream --allow-empty
    target=$(git -C "$wt" rev-parse HEAD)
    git -C "$wt" checkout -qb "fm/$id" HEAD~1
    git -C "$wt" commit -qm fork --allow-empty
    base=$(git -C "$wt" rev-parse HEAD)
    git -C "$wt" merge -q --no-ff -m sync "$target"
    if [ "$scenario" = extra-merge ]; then
      git -C "$wt" checkout -qb extra "$base"
      git -C "$wt" commit -qm extra --allow-empty
      git -C "$wt" checkout -q "fm/$id"
      git -C "$wt" merge -q --no-ff -m extra extra
    fi
    [ "$scenario" != fix-forward ] || git -C "$wt" commit -qm fix --allow-empty
    head=$(git -C "$wt" rev-parse HEAD)
    git -C "$wt" remote add origin https://github.com/HelloWorldSungin/firstmate.git
    git -C "$wt" remote add upstream https://github.com/kunchenguid/firstmate.git
    git -C "$wt" update-ref refs/remotes/upstream/main "$target"
    if [ "$scenario" = side-endpoint ]; then
      git -C "$wt" checkout -qb upstream-main "$target~1"
      git -C "$wt" commit -qm mainline --allow-empty
      git -C "$wt" merge -q --no-ff -m side-target "$target"
      git -C "$wt" update-ref refs/remotes/upstream/main HEAD
      git -C "$wt" checkout -q "fm/$id"
    fi
    DEFAULT_TIP=$base
    add_gh_mocks "$case_dir" "$head"
    write_github_red_json "$case_dir" "$head" 'PR must be raised via no-mistakes'
    jq --arg branch "fm/$id" '. + {headRefName:$branch,headRepository:{nameWithOwner:"HelloWorldSungin/firstmate"}}' \
      "$case_dir/github-view.json" > "$case_dir/view.tmp"
    mv "$case_dir/view.tmp" "$case_dir/github-view.json"
    [ "$scenario" != wrong-task ] || id=ordinary-task
    meta="$case_dir/state/$id.meta"
    mv "$case_dir/state/task-x1.meta" "$meta"
    sed 's/^mode=.*/mode=direct-PR/' "$meta" > "$case_dir/meta.tmp"
    mv "$case_dir/meta.tmp" "$meta"
    printf 'upstream_sync_review=%s:%s:%s\n' "$base" "$target" "$head" >> "$meta"
    method=--merge
    case "$scenario" in
      away|no-grant) write_away_record "$case_dir" --grant "$id"
        [ "$scenario" != no-grant ] || write_away_record "$case_dir" ;;
      absent-review) sed '/^upstream_sync_review=/d' "$meta" > "$case_dir/meta.tmp"; mv "$case_dir/meta.tmp" "$meta" ;;
      stale-review|wrong-target)
        sed '/^upstream_sync_review=/d' "$meta" > "$case_dir/meta.tmp"; mv "$case_dir/meta.tmp" "$meta"
        if [ "$scenario" = stale-review ]; then
          printf 'upstream_sync_review=%s:%s:%s\n' "$base" "$target" "$base" >> "$meta"
        else
          printf 'upstream_sync_review=%s:%s:%s\n' "$base" "$base" "$head" >> "$meta"
        fi ;;
      duplicate-review) printf 'upstream_sync_review=%s:%s:%s\n' "$base" "$target" "$head" >> "$meta" ;;
      wrong-mode) printf 'mode=no-mistakes\n' >> "$meta" ;;
      wrong-repo) url=https://github.com/example/repo/pull/96 ;;
      wrong-push) git -C "$wt" remote set-url --push origin https://github.com/kunchenguid/firstmate.git ;;
      wrong-upstream) git -C "$wt" remote set-url upstream https://github.com/example/repo.git ;;
      wrong-branch) git -C "$wt" checkout -qb unrelated ;;
      wrong-local-head) git -C "$wt" commit -qm unreviewed --allow-empty ;;
      moved-base) DEFAULT_TIP=$target ;;
      squash|green-squash) method=--squash ;;
    esac
    case "$scenario" in
      green-squash) filter='.statusCheckRollup[0].conclusion="SUCCESS"' ;;
      pending) filter='.statusCheckRollup[0].status="IN_PROGRESS"' ;;
      cancelled) filter='.statusCheckRollup[0].conclusion="CANCELLED"' ;;
      status-context) filter='.statusCheckRollup += [{__typename:"StatusContext",context:"PR must be raised via no-mistakes",state:"PENDING"}]' ;;
      lint-red) filter='.statusCheckRollup += [{__typename:"CheckRun",name:"lint",status:"COMPLETED",conclusion:"FAILURE"}]' ;;
      lint-pending) filter='.statusCheckRollup += [{__typename:"CheckRun",name:"lint",status:"QUEUED",conclusion:null}]' ;;
      wrong-live-branch) filter='.headRefName="unrelated"' ;;
      wrong-live-repo) filter='.headRepository.nameWithOwner="example/repo"' ;;
      *) filter='.' ;;
    esac
    jq "$filter" "$case_dir/github-view.json" > "$case_dir/view.tmp"
    mv "$case_dir/view.tmp" "$case_dir/github-view.json"
    rc=0
    run_pr_merge "$case_dir" "$id" "$url" -- "$method" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    case "$scenario" in
      attended|away|fix-forward)
        expect_code 0 "$rc" "sync-policy-$scenario: verified round should merge: $(cat "$case_dir/stderr")"
        assert_logged_gh_merge "$case_dir" 96 HelloWorldSungin/firstmate --merge ;;
      *)
        [ "$rc" -ne 0 ] || fail "sync-policy-$scenario: invalid proof or check was accepted"
        assert_no_grep 'pr merge' "$case_dir/gh.log" "sync-policy-$scenario: forge merge ran" ;;
    esac
  done
  DEFAULT_TIP=$saved_tip
  pass "fm-pr-merge limits the sync exception to reviewed graphs and completed policy failures"
}

test_reviewed_upstream_sync_policy_exception

test_github_red_checks_refuse_and_allow_red_waives_named
test_superseded_failed_check_run_no_longer_refuses
test_check_runs_never_supersede_status_contexts
test_current_failed_check_run_still_refuses
test_late_finishing_old_success_does_not_hide_current_failure
test_late_finishing_old_cancellation_is_superseded
test_unfinished_rerun_keeps_a_check_red
test_supersession_never_crosses_check_names
test_undated_runs_never_supersede
test_allow_red_still_waives_only_the_current_failure
test_allow_red_is_refused_while_away
test_allow_red_requires_one_separate_name
test_away_grant_and_yolo_and_hold_for_return
test_away_posture_refuses_asynchronous_merge_paths
test_away_grant_does_not_bypass_red_or_identity
test_unreadable_away_record_refuses_merge
test_away_record_cannot_change_between_the_authority_read_and_the_merge
test_a_grant_revoked_before_the_merge_refuses_it
test_merge_refuses_when_the_away_record_cannot_be_locked
test_allow_red_refused_on_gitlab

printf '\nall fm-pr-merge tests passed\n'
