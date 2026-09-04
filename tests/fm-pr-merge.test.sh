#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must record pr= and any available pr_head= into the task's meta so
# fm-teardown.sh's landed-check has a PR reference to verify against, even on
# repos with no PR CI where the usual "checks green" fm-pr-check.sh trigger
# never fires.
#
# Matrix:
#   (a) a verified merge records pr= and pr_head=
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL,
#       including a bundled short-option cluster that carries -R
#   (i) a GitLab MR URL resolves and merges through glab instead of erroring
#   (j) glab is addressed by the host from the URL, never an assumed one
#   (k) no merge method is imposed on GitLab, so the project's own one applies
#   (l) each pre-merge condition refuses independently, and all of them report
#   (m) a stale recorded pr_head= is reported and the live head is verified
#   (n) an unreadable merge request state refuses rather than merging blind
#   (o) glab or jq absent refuses before any state is recorded
#   (p) --sha in extra GitLab args fails fast, and still forwards on GitHub
#   (q) a GitLab refusal still leaves pr= recorded and the merge poll armed
#   (r) GitHub success is accepted only after the PR is read back as merged
#   (s) an open GitHub PR that is neither merged nor queued fails verification
#   (t) a GitHub PR in the merge queue is reported as queued, not merged
#   (u) a queue-required refusal names the exact compatible retry flags
#   (v) a failed poll setup cannot be reported as a verified GitHub merge
#   (w) a zero-exit queue-required refusal keeps merge semantics unchanged
#   (x) an unreadable outcome after a successful merge call keeps the PR
#       recorded and the merge poll armed
#   (y) agreeing queue rules still produce exact retry flags
#   (z) conflicting queue rules report ambiguous retry guidance
#   (aa) gh-axi remains usable when gh is absent
#   (ab) a landed merge whose fallback outcome read fails keeps its poll armed
#   (ac) a successful merge in a secondmate home reports the landed PR upward
#       once, on the route its parent binding names, and a repeat merge of the
#       same PR does not duplicate that line
#   (ad) a refused or failed merge reports nothing
#   (ae) a successful merge in a main home leaves a durable wake naming the PR
#   (af) a secondmate home with no usable parent binding says so loudly instead
#       of merging in silence
#   (ag) an accepted queued GitHub merge emits nothing and leaves its poll armed
#   (ah) an accepted queued GitLab merge emits nothing and leaves its poll armed
#   (ai) an uncommitted marker retry never loses the durable outcome
#   (aj) distinct merged PRs for a reused task each survive queue deduplication
#   (ak) pr= is already recorded when the forge call that can land the merge runs
#   (al) a failed gh read falls back to the gh-axi view, which can prove a merge
#   (am) a failed merge command still names an outcome read that proves a landed
#       or queued pull request, without masking the forge failure
#   (an) a refusal after a zero-exit merge quotes the forge's own output, marked
#       apart from the wrapper's verdict and never leaked to stdout
#   (ao) an outcome read that fails after a zero-exit merge still quotes the
#       forge's own output, the only evidence left
#   (ap) an unrecognised queue method still names the queue requirement and
#       guesses no method
#   (aq) unreadable branch rules are reported apart from a queue-less base
#   (ar) a base branch with no queue rule says nothing about a merge queue
#   (as) identical degraded evidence reaches an identical verdict whether gh is
#       absent or present but broken, so the outcome never depends on which of
#       the two readers happened to be missing
#   (at) an open recorded issue is closed after merge and linked to the PR
#   (au) an already-closed recorded issue is left alone
#   (av) issue-close failure reports the merge as successful and exits zero
#   (aw) a task with no recorded issue makes no issue API calls
#   (ax) issue-state verification failure reports the merge as successful
#   (ay) a successful close request that leaves the issue open warns
#   (az) malformed or duplicate recorded issue metadata warns without API calls
#   (ba) a gitea work item closes through its own host credential with the same
#       linking comment, an absent credential and an empty one are reported as
#       the two different facts they are with nothing sent, a verification that
#       fails says why it failed rather than only that it did, and a gitea close
#       failure never makes the merge look retryable
#   (bb) a cached-PR-state refresh that fails hands the operator the cause the
#       refresh named, bounded to one line, instead of only the symptom
#   (bc) every --auto spelling is refused by name before any merge is attempted
#   (bd) every path that observes a landed merge exits zero and records the
#       outcome durably, over the seven routes that reach such an observation,
#       each proving it reached its OWN observation point and leaving a witness
#       the others cannot match, so two routes that collapse onto one read fail
#       instead of both passing; and on both forges a merge whose command failed
#       says so against the readback that overrides it rather than exiting zero
#       in silence
#   (be) a pull request whose target is not the current default branch is
#       refused by name, before any queue or method handling, including one
#       already merged into that branch - the contract is a precondition, so it
#       is evaluated on a merged pull request too and refuses rather than
#       recording a landing onto a branch guarded merging may not touch
#   (bf) a target that could not be established refuses rather than permitting
#   (bg) the PRE-merge half of the degraded-view seam: the degraded gh-axi
#       reader reads the real target out of the api passthrough's own envelope,
#       including when a broken gh is installed, and is accepted for the target
#       question with no merged proof
#   (bh) a landed merge this run already observed is never re-read, including one
#       the PRE-merge target read is what observed
#   (bi) the GitLab automatic-rebase guard refuses only inside the window where
#       project-level rebase can fire, and permits outside it
#   (bj) the POST-merge half of that same seam, on BOTH degraded routes: the
#       degraded gh-axi view cannot answer the outcome question without a proved
#       merge, and reports an outcome it could not read rather than a concrete
#       not-merged verdict
#   (bk) no argument position lets a refused flag reach the forge - every
#       value-taking allow-list entry crossed with --auto in both orders - while
#       the detached values the allow-list exists to carry still merge
#   (bl) the degraded reader decodes a TOON-quoted branch name, so a ref name
#       containing a comma or beginning with a dash is compared as itself rather
#       than as its quotes, in both the permitting and refusing directions
#   (bm) a refused target arms nothing: neither pr= nor the merge poll, which
#       reads only whether the pull request merged and would otherwise record
#       the non-default landing the refusal exists to keep off this ledger
#   (bn) the default branch's tip is re-read immediately before the merge call,
#       a tip that moved refuses naming both commits, an unmoved one still
#       merges, and a tip that could not be re-read refuses rather than passing
#       as unmoved
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

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
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

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
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
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    cat "\$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    cat "\$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
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
  api\ *)
    case " $* " in
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
  "api graphql")
    cat "$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
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
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    count_file="\$FM_TEST_GH_OUTCOME.reads"
    count=\$(cat "\$count_file" 2>/dev/null || echo 0)
    count=\$((count + 1))
    printf '%s\n' "\$count" > "\$count_file"
    if [ "\$count" -ge $from ]; then
      echo 'error: could not reach the GitHub API' >&2
      exit 1
    fi
    cat "\$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

add_gh_mock_outcome_read_fails() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    echo 'error: could not reach the GitHub API' >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
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
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  printf '{"iid":7,"state":"%s","detailed_merge_status":"%s","has_conflicts":%s,' \
    "$state" "$detail" "$conflicts" > "$file"
  printf '"blocking_discussions_resolved":%s,"sha":"%s","head_pipeline":%s}\n' \
    "$discussions" "$head" "$pipeline" >> "$file"
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
  FM_HOME="${FM_TEST_HOME:-$ROOT}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_DEFAULT_TIP="$DEFAULT_TIP" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
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
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
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
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge")
    cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$FM_TEST_META_AT_MERGE"
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-ahead-of-forge-call: fm-pr-merge should succeed"
  assert_grep 'pr merge 62 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "records-ahead-of-forge-call: the merge abstraction was never invoked"
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
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "will be added to the merge queue when all requirements are met" ;;
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
      -- "$spelling" --merge \
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
  for taker in --method --sha --subject --body --body-file -t -b -F; do
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
  for order in '--sha abc123' '--subject fix' '--subject=-fix'; do
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
    grep -qxF "pr merge $number --repo example/repo --squash $order" \
      "$case_dir/gh-axi.log" \
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
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefOid*) printf '%s\n' 8484848484848484848484848484848484848484 ; exit 0 ;;
    esac
    ;;
  "api graphql")
    cat "$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
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

  expect_code 0 "$rc" "github-without-gh: gh-axi can prove a landed merge without gh"
  assert_grep 'pr merge 60 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "github-without-gh: the configured merge abstraction was not invoked"
  # Already merged when the run starts, so the view that answers here is the
  # PRE-merge one; github|degraded-no-gh in the landed-merge invariant is what
  # measures the POST-merge answer, against a fixture that reads OPEN until the
  # merge runs.
  assert_grep 'pr view 60 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-without-gh: the gh-axi view was never consulted on a host with no gh"
  assert_grep 'verified: https://github.com/example/repo/pull/60 is merged' \
    "$case_dir/stdout" "github-without-gh: the fallback did not report the proven merge"
  pass "fm-pr-merge reaches and verifies the gh-axi merge path without gh"
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

  expect_code 1 "$rc" "github-without-gh-read-fails: an unreadable outcome must fail"
  assert_grep 'pr merge 61 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "github-without-gh-read-fails: the merge call did not happen before the failed read"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-without-gh-read-fails: the failed read was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/61' "$case_dir/state/task-x1.meta" \
    "github-without-gh-read-fails: a landed merge lost its PR metadata"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-without-gh-read-fails: a landed merge lost its merge poll"
  pass "fm-pr-merge preserves bookkeeping when gh is absent and the fallback read fails"
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
  assert_grep '-- --auto --rebase' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the exact compatible flags"
  assert_grep 'api --paginate repos/example/repo/rules/branches/release%2F2026' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue rules were not read with pagination and encoded branch path"
  grep -qxF 'pr merge 56 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "github-zero-exit-queue-required: the attempted merge was changed unexpectedly"
  # Count the MERGES rather than the whole log: the guarded path also asks gh-axi
  # for the target and the base tip, and a line count silently turns "one merge"
  # into "one forge call of any kind".
  [ "$(count_log_lines "$case_dir/gh-axi.log" '^pr merge ')" = 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep --auto "$case_dir/gh-axi.log" \
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
  assert_no_grep '-- --auto --merge' "$case_dir/stderr" \
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
  grep -F -- '-- --auto --merge' "$case_dir/stderr" >/dev/null \
    || fail "github-queue-required: refusal did not name the exact compatible flags"
  grep -qxF 'pr merge 54 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "github-queue-required: the wrapper silently changed the attempted merge semantics"
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
  assert_grep '-- --auto --rebase' "$case_dir/stderr" \
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
  assert_no_grep '-- --auto --merge' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep '-- --auto --squash' "$case_dir/stderr" \
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

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
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
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
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
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
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
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
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
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
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

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "bundled-non-repo-cluster: fm-pr-merge refused a short flag that overrides nothing"

  grep -qxF 'pr merge 8 --repo example/repo --squash -d' "$case_dir/gh-axi.log" \
    || fail "bundled-non-repo-cluster: a short flag carrying no repository override was not forwarded"
  pass "fm-pr-merge refuses a bundled short-option repo override and forwards other short flags"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
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

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
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

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
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
  grep -qxF 'pr merge 34 --repo example/repo --squash' "$case_dir/gh-axi.log" \
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
  assert_grep 'pr merge 54 --repo example/repo' "$case_dir/gh-axi.log" \
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
  assert_grep 'pr merge 56 --repo example/repo' "$case_dir/gh-axi.log" \
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
  assert_grep 'pr merge 58 --repo example/repo' "$case_dir/gh-axi.log" \
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

  expect_code 0 "$rc" "gitlab-extra-args: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes --remove-source-branch" ] \
    || fail "gitlab-extra-args: extra glab flags were not forwarded: '$merge_line'"
  pass "fm-pr-merge forwards extra flags to glab mr merge after the -- separator"
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
  local case_dir
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  # --sha is ADMITTED to the forwarded-argument allow-list as a head-binding
  # argument: it constrains the mutation to the state this run verified, cannot
  # defer execution, and makes the merge strictly narrower, so a push landing
  # between validation and merge makes the forge refuse rather than merge
  # something nobody checked. It is forwarded because it is admitted
  # categorically and recorded in the allow-list, NOT because the unbounded
  # passthrough survived - that was deliberately closed, and every other
  # unlisted argument is refused by name.
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-sha-arg: fm-pr-merge failed"

  grep -qxF 'pr merge 44 --repo example/repo --squash --sha abc123' "$case_dir/gh-axi.log" \
    || fail "github-sha-arg: an admitted head-binding argument was not forwarded"
  pass "fm-pr-merge forwards --sha as an admitted head-binding argument"
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
  [ "$(wc -l <"$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward line"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
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
# THE LANDED-MERGE INVARIANT.
#
# Asserted as a POSITIVE property rather than policed by inspection: EVERY path
# on which this script observes a landed merge must reach outcome reporting and
# exit zero. It is written this way because the opposite contract - that a
# landed-but-unrecorded merge should fail - has previously reached the code, a
# test, and the architecture document by three separate routes, and an
# enumeration of the paths that get it wrong cannot keep finding them.
#
# SEVEN routes, each separated from every other by ONE STATED SENTENCE naming
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
#   github|degraded-no-gh          gh is absent entirely, so the gh-axi view
#                                  answers both reads and its POST-merge answer
#                                  is what proves the merge
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
    github\|degraded-no-gh \
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
        degraded-no-gh)
          # gh absent entirely: only the gh-axi view can prove the outcome, and
          # only its POST-merge answer can, because its pre-merge answer is open.
          # Deleting this case's own mock is NOT enough. run_pr_merge prepends
          # fakebin to the INHERITED PATH, so on any host that ships gh the real
          # binary still resolves, this route quietly becomes degraded-gh-failed
          # against the live forge, and the invariant's seven routes are six. The
          # search path is rebuilt without gh so no gh can resolve whatever the
          # host has installed.
          add_gh_axi_mock_open_until_merged "$case_dir" 0
          rm -f "$case_dir/fakebin/gh"
          run_path="$case_dir/path-without-gh"
          mirror_path_without "$run_path" gh "$case_dir/fakebin"
          ;;
        degraded-gh-failed)
          # gh present but its read fails; the gh-axi fallback proves the merge.
          # It logs before failing, which is how this route proves it is the one
          # where gh WAS consulted rather than the one where gh does not exist.
          add_gh_axi_mock_open_until_merged "$case_dir" 0
          cat >"$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
exit 1
SH
          chmod +x "$case_dir/fakebin/gh"
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

    # run_pr_merge PREPENDS fakebin to whatever PATH it inherits, so the search
    # path this case really runs on is the one asserted here rather than the one
    # built above. Deleting the case's own mock is not isolation: the host's own
    # gh stays resolvable and silently turns this route into degraded-gh-failed,
    # against the live forge, with the invariant's six routes quietly five.
    if [ "$route" = degraded-no-gh ]; then
      ! PATH="$case_dir/fakebin:${run_path:-$PATH}" command -v gh >/dev/null 2>&1 \
        || fail "landed-invariant github/degraded-no-gh: the search path this case runs on still resolves gh"
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
    # is the one thing all seven have in common.
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
        # The merge is still ATTEMPTED on this route; the preflight short-circuits
        # the outcome READ, not the mutation.
        assert_grep 'pr merge' "$case_dir/gh-axi.log" \
          "landed-invariant github/preflight-landed: the merge was skipped rather than attempted"
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
      github\|degraded-no-gh)
        [ ! -s "$case_dir/gh.log" ] \
          || fail "landed-invariant github/degraded-no-gh: gh was consulted on a route that must have none"
        [ "$axi_views" = 2 ] \
          || fail "landed-invariant github/degraded-no-gh: the gh-axi view did not prove the merge AFTER it landed (it answered $axi_views views)"
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

  # THE MATRIX REFUSES TO COLLAPSE. Seven routes that reached seven different
  # observation points leave seven different witnesses; two routes that ended up
  # in the same place leave the same witness twice and this fails, which is the
  # check the route count has been missing every time it was wrong.
  total=$(wc -l <"$witness_file" | tr -d '[:space:]')
  distinct=$(sort -u "$witness_file" | wc -l | tr -d '[:space:]')
  [ "$total" = 7 ] \
    || fail "landed-invariant: $total routes ran, and the sentences above name seven"
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
  rm -f "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
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
  grep -q 'pr merge' "$case_dir/gh-axi.log" \
    && fail "target-refusal-unestablished: a merge ran without an established target"
  pass "fm-pr-merge refuses when the merge target cannot be established"
}

test_degraded_path_reads_the_real_target() {
  local case_dir rc url ghless_path
  url=https://github.com/example/repo/pull/93
  case_dir=$(make_case target-refusal-degraded)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  rm -f "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
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
    : > "$case_dir/gh-axi-merge-attempted"
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    if [ -e "$case_dir/gh-axi-merge-attempted" ]; then
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
      assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
        "target-gh-failed-refuses: a refused target still reached the forge"
    else
      expect_code 0 "$rc" \
        "target-gh-failed-permits: a default target must merge even when gh's read fails"
      assert_grep 'pr merge' "$case_dir/gh-axi.log" \
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
    : > "$case_dir/gh-axi-merge-attempted"
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    if [ -e "$case_dir/gh-axi-merge-attempted" ]; then
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
      assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
        "target-quoted-refuses: a refused target still reached the forge"
    else
      expect_code 0 "$rc" \
        "target-quoted-permits: a quoted name equal to the default must still merge"
      assert_grep 'pr merge' "$case_dir/gh-axi.log" \
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
        assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
          "default-tip-moved: a merge ran against a base this run never judged"
        assert_absent "$case_dir/state/.wake-queue" \
          "default-tip-moved: a refused merge was recorded as a landed outcome"
        ;;
      steady)
        expect_code 0 "$rc" \
          "default-tip-steady: a base that did not move must still merge"
        assert_grep 'pr merge' "$case_dir/gh-axi.log" \
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
        assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
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
# BOTH DEGRADED ROUTES ARE RUN, and that is the point of the loop rather than a
# second case for tidiness. The evidence is the same gh-axi view whether gh is
# ABSENT or PRESENT AND BROKEN, so a verdict that differs between them is a
# verdict about which tool happens to be installed. The seam used to be consulted
# on the gh-failed route only, and the gh-absent route answered the same evidence
# with a concrete state=open verdict instead.
#
# Without this case, dropping the merged proof on the post-merge side leaves the
# suite green and the seam collapses back into the single rule it replaced.
test_degraded_view_cannot_answer_the_post_merge_question() {
  local case_dir rc url route run_path number=95
  for route in gh-failed no-gh; do
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
    if [ "$route" = gh-failed ]; then
      # gh answers the pre-merge target read and then fails, so the post-merge
      # read falls back to a gh-axi view that reports the request still OPEN.
      add_gh_mock_outcome_read_fails_from "$case_dir" ffffffffffffffffffffffffffffffffffffffff 2
    else
      # gh is absent entirely, so the same gh-axi view answers both reads.
      # Removing this case's own mock is not enough: run_pr_merge prepends
      # fakebin to the INHERITED PATH, so on a host that ships gh the real binary
      # resolves and this route quietly becomes the other one.
      rm -f "$case_dir/fakebin/gh"
      run_path="$case_dir/path-without-gh"
      mirror_path_without "$run_path" gh "$case_dir/fakebin"
      ! PATH="$case_dir/fakebin:$run_path" command -v gh >/dev/null 2>&1 \
        || fail "degraded-post-merge-unanswerable/no-gh: the search path this case runs on still resolves gh"
    fi
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
  done
  pass "neither degraded route answers the post-merge outcome question without a proved merge"
}

test_degraded_view_cannot_answer_the_post_merge_question

printf '\nall fm-pr-merge tests passed\n'
