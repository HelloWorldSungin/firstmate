#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal tracked-output task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#
# Also covers task identity: the pool can hand one worktree path to a second
# task, so the worktree's ambient branch is placement, not identity. Both the
# landed-work refusal and the parked-run abort read the record's own branch=.
#   (t1) recorded branch, ambient branch's PR merged           -> REFUSE (not this task's PR)
#   (t2) legacy record with no branch= + no branchless proof   -> REFUSE (nothing left to judge)
#   (t2a) legacy record with no branch= + recorded pr= merged  -> ALLOW  (pr= reads no branch)
#   (t2b) legacy record with no branch= + content in default   -> ALLOW  (content reads no branch)
#   (t3) reallocated worktree hosting another task's live run  -> never aborted
#   (t4) legacy record + a perfectly matching ambient run      -> never aborted
#
# Also covers the model-routing refusal's never-started boundary: a worker that
# died before its first model-attributed turn can never produce a verdict, so
# refusing it forever preserves nothing, while a worker that RAN without a usable
# verdict, or one with work in its worktree, must keep refusing.
#   (z1) no model-attributed turn + clean detached worktree     -> ALLOW  (no verdict possible)
#   (z2) session opened but no turn + clean detached worktree   -> ALLOW  (same, other shape)
#   (z3) no turn + uncommitted changes                          -> REFUSE (work to lose)
#   (z4) no turn + commits on a task branch                     -> REFUSE (work to lose)
#   (z5) worker RAN, evidence unattributable, worktree clean    -> REFUSE (evidence to protect)
#
# Also covers the never-armed boundary: a dispatch whose record names no
# model-evidence store was never armed for that check and can never produce a
# verdict, so the gap stops being treated as a safety signal - without lending
# any other teardown refusal the same allowance.
#   (n1) no recorded store + landed + clean worktree            -> ALLOW  (gap, not a signal)
#   (n2) recorded store + failed verdict, same clean fixture    -> REFUSE (verdict is real)
#   (n3) recorded store + damaged dispatch anchor               -> REFUSE (armed, undecidable)
#   (n4) no recorded store + uncommitted changes                -> REFUSE (work to lose)
#   (n5) no recorded store + unlanded commits                   -> REFUSE (work to lose)
#   (n6) no recorded store + unpublishable completion manifest  -> REFUSE (no durable record)
#   (n7) no recorded store + endpoint that does not validate    -> REFUSE (endpoint identity)
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_PS_FOR_TEST=$(command -v ps)
export REAL_PS_FOR_TEST
REAL_LSOF_FOR_TEST=$(command -v lsof)
export REAL_LSOF_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Default hermetic no-mistakes stub: `axi status` answers FM_FAKE_AXI_STATUS
  # verbatim (empty by default, i.e. no active run - the pre-teardown run-abort
  # step is then a no-op), and `axi abort` appends one line to
  # FM_FAKE_NM_ABORT_LOG when set. This keeps every case hermetic - without it,
  # `command -v no-mistakes` would fall through to whatever real binary
  # happens to be on the test runner's own PATH. Tests exercising the run-abort
  # path override FM_FAKE_AXI_STATUS/FM_FAKE_NM_ABORT_LOG before run_teardown.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        run_id=""
        if [ "${1:-}" = --run ]; then run_id=${2:-}; fi
        if [ -n "${FM_FAKE_NM_ABORT_LOG:-}" ] \
           && grep -Fxq "abort --run $run_id" "$FM_FAKE_NM_ABORT_LOG" 2>/dev/null \
           && [ "${FM_FAKE_NM_ABORT_NOOP:-0}" != 1 ]; then
          if [ "${FM_FAKE_NM_NOT_FOUND_AFTER_ABORT:-0}" = 1 ]; then
            printf 'error: "run \\"%s\\" not found"\n' "$run_id" >&2
            exit 1
          elif [ "${FM_FAKE_NM_EMPTY_AFTER_ABORT:-0}" = 1 ]; then
            exit 0
          elif [ -n "${FM_FAKE_AXI_STATUS_AFTER_ABORT:-}" ]; then
            printf '%s\n' "$FM_FAKE_AXI_STATUS_AFTER_ABORT"
          else
            printf 'run:\n  id: "%s"\n  outcome: cancelled\n' "$run_id"
          fi
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
        fi
        ;;
      abort)
        shift
        [ -z "${FM_FAKE_NM_ABORT_LOG:-}" ] || printf 'abort %s\n' "$*" >> "$FM_FAKE_NM_ABORT_LOG"
        exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.2.4'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
if [ "${1:-}" = hold ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi hold <id> --kind captain'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
# A ship or design record carries the durable branch= fm-spawn copies from its brief's
# exact task-branch marker, which is the branch make_case checks the worktree
# out on. That record - never the worktree's ambient branch - is what teardown
# attributes runs and unlanded work to.
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "model=default"
  case "$kind" in
    ship|design) printf 'branch=fm/task-x1\n' >> "$case_dir/state/task-x1.meta" ;;
  esac
}

# A ship record from before the task-branch marker existed: it names a worktree
# and nothing that identifies the task's own branch. Args: case_dir mode
write_legacy_meta_without_branch() {
  local case_dir=$1 mode=$2
  write_meta "$case_dir" "$mode" ship
  grep -v '^branch=' "$case_dir/state/task-x1.meta" > "$case_dir/state/task-x1.meta.new"
  mv "$case_dir/state/task-x1.meta.new" "$case_dir/state/task-x1.meta"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
# The hidden pull ref models GitHub retaining the merged head after deleting its
# source branch, so branch cleanup can verify the commit still exists remotely.
# The two CLIs answer the two different questions they are really asked: gh-axi
# serves the TOON reads (pr list, plain pr view), and only gh serves a --json
# structured read. gh-axi is deliberately given no --json answer at all, because
# it has none in reality - it ignores the flag and exits 0 with its own TOON
# body - so a structured read routed back through the wrapper fails this fixture
# instead of quietly passing it.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  git -C "$case_dir/wt" push -q origin "$head:refs/pull/7/head"
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"'
    exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *statusCheckRollup*)
        printf '%s\n' '{"state":"MERGED","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","headRefOid":"$head","statusCheckRollup":[]}'
        exit 0 ;;
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Like add_gh_pr_merged_for_head, but the merged PR is discoverable ONLY through
# the named head branch. Any other branch looks up empty, so a landed-work check
# that asks about the wrong branch cannot find this PR at all.
add_gh_pr_merged_for_branch_head() {
  local case_dir=$1 branch=$2 head=$3
  add_gh_pr_merged_for_head "$case_dir" "$head"
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr list")
    case " \$* " in
      *" --head $branch "*)
        printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
    esac
    printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone. The cwd scan is a
# separate successful empty query.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ]; then
  case "${args[3]:-}" in --porcelain|--porcelain=v1) ;; *) exec "$real" "${args[@]}" ;; esac
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
  PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

test_terminal_model_verdict_blocks_cleanup_then_allows_match() {
  local case_dir cfg dir rc
  case_dir=$(make_case terminal-model-verdict)
  write_meta "$case_dir" local-only ship
  cfg="$case_dir/claude-config"
  printf '%s\n' \
    'harness=claude' \
    'model=opus' \
    "model_evidence_store=$cfg" \
    'model_evidence_watermark=claude-transcript-v1' >> "$case_dir/state/task-x1.meta"
  dir="$cfg/projects/$(printf '%s' "$case_dir/wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  printf '{"type":"assistant","message":{"model":"claude-sonnet-5"}}\n' > "$dir/current.jsonl"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$cfg" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "terminal model mismatch did not refuse teardown"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "terminal model mismatch erased task metadata"
  [ -d "$case_dir/wt" ] || fail "terminal model mismatch returned the task worktree"
  assert_grep "verdict: mismatch" "$case_dir/stderr" \
    "terminal model mismatch was not surfaced during teardown"

  printf '{"type":"assistant","message":{"model":"claude-opus-5"}}\n' > "$dir/current.jsonl"
  FM_TEST_CLAUDE_CONFIG_DIR="$cfg" \
    run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "matching terminal model verdict blocked teardown"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "matching terminal verdict left task metadata behind"
  pass "terminal teardown preserves mismatches and proceeds on a model match"
}

# Point the task at a claude dispatch with a pinned model, so its routing is
# verifiable IN PRINCIPLE and an absent verdict is meaningful. Echoes the
# transcript directory the verifier will look in; the caller decides whether it
# exists, and with what in it. Args: case_dir
claude_dispatch_meta() {
  local case_dir=$1 cfg
  cfg="$case_dir/claude-config"
  mkdir -p "$cfg/projects"
  printf '%s\n' \
    'harness=claude' \
    'model=opus' \
    "model_evidence_store=$cfg" \
    'model_evidence_watermark=claude-transcript-v1' >> "$case_dir/state/task-x1.meta"
  printf '%s/projects/%s\n' "$cfg" "$(printf '%s' "$case_dir/wt" | sed 's/[^A-Za-z0-9]/-/g')"
}

# The record shape this change is about: a claude dispatch with a pinned model
# and NO `model_evidence_store=` line, exactly as every dispatch that predates
# the model-routing guard was recorded. Deliberately built by writing the fields
# rather than deleting a line, so the fixture cannot drift into asserting on a
# store line that a future scaffold stops writing. Args: case_dir
pre_guard_dispatch_meta() {
  local case_dir=$1
  write_meta "$case_dir" no-mistakes ship
  sed -i.bak 's/^model=default$/model=opus/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'harness=claude' >> "$case_dir/state/task-x1.meta"
  grep -q '^model_evidence_store=' "$case_dir/state/task-x1.meta" \
    && fail "pre_guard_dispatch_meta: the fixture recorded an evidence store"
  mkdir -p "$case_dir/ambient-claude/projects"
}

use_unverified_zellij_backend() {
  local case_dir=$1
  sed -i.bak 's|^window=.*$|window=firstmate:7|' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=zellij' \
    'zellij_session=firstmate' \
    'zellij_tab_id=3' \
    'zellij_pane_id=7' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" list-sessions "*) printf '%s\n' firstmate ;;
  *" action list-panes --json "*)
    printf '%s\n' '[{"id":7,"tab_id":3,"is_plugin":false}]'
    ;;
  *" action list-tabs --json "*)
    printf '%s\n' '[{"tab_id":3,"name":"fm-task-x1"}]'
    ;;
  *" action close-tab-by-id "*)
    : > "${FM_TEST_ENDPOINT_CLOSE_ATTEMPTED:?}"
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/zellij"
}

install_tmux_close_mutation() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = kill-window ]; then
  [ -z "${FM_TEST_ENDPOINT_CLOSE_ATTEMPTED:-}" ] || : > "$FM_TEST_ENDPOINT_CLOSE_ATTEMPTED"
  case "${FM_TEST_CLOSE_MUTATION:-}" in
    model-turn)
      mkdir -p "${FM_TEST_TRANSCRIPT_DIR:?}"
      printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5"}}' > "${FM_TEST_TRANSCRIPT_DIR:?}/current.jsonl"
      ;;
    task-branch)
      git -C "${FM_TEST_PROJECT:?}" branch fm/task-x1
      ;;
    own-commit)
      git -C "${FM_TEST_WT:?}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "detached worker commit"
      ;;
    tracked-change)
      printf 'staged work\n' > "${FM_TEST_WT:?}/staged.txt"
      git -C "${FM_TEST_WT:?}" add staged.txt
      ;;
    untracked-file)
      printf 'untracked work\n' > "${FM_TEST_WT:?}/scratch.txt"
      ;;
  esac
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

install_authoritative_live_tmux() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf '%s\n' fm-task-x1 ;;
  display-message)
    case "\${*: -1}" in
      '#{pane_tty}') printf '\n' ;;
      '#{pane_current_command}') printf '%s\n' claude ;;
    esac
    ;;
  kill-window) : > '$case_dir/endpoint-close-attempted' ;;
esac
SH
  chmod +x "$case_dir/fakebin/tmux"
}

install_authoritative_dead_tmux() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' fm-task-x1 ;;
  display-message)
    case "${*: -1}" in
      '#{pane_tty}') printf '\n' ;;
      '#{pane_current_command}') printf '%s\n' bash ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

install_destructive_treehouse_probe() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "return --force" ]; then
  : > "${FM_TEST_TREEHOUSE_RETURNED:?}"
  rm -rf -- "${@: -1}"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Leave the worktree exactly as a worker that died before its first turn does:
# detached at the base commit, with the task branch never created. Args: case_dir
never_started_worktree() {
  local case_dir=$1
  git -C "$case_dir/wt" checkout --detach -q
  git -C "$case_dir/project" branch -D fm/task-x1 >/dev/null 2>&1 || true
}

# A worker stranded before its first model-attributed turn can never produce a
# verdict, so refusing it forever preserves nothing and strands its records. The
# allowance is evidence-based: it holds only while the worktree also proves there
# is no work to lose, and the absent verdict is still stated plainly.
test_never_started_and_clean_tears_down_without_force() {
  local case_dir dir rc
  case_dir=$(make_case never-started-clean)
  write_meta "$case_dir" no-mistakes ship
  dir=$(claude_dispatch_meta "$case_dir")
  never_started_worktree "$case_dir"
  mkdir -p "$case_dir/wt/.claude" "$case_dir/wt/.opencode/plugins"
  : > "$case_dir/wt/.claude/settings.local.json"
  : > "$case_dir/wt/.opencode/plugins/fm-turn-end.js"
  : > "$case_dir/wt/.opencode/plugins/fm-busy-state.js"
  : > "$case_dir/wt/.fm-grok-turnend"
  : > "$case_dir/wt/.fm-kimi-turnend"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "never-started-clean: a worker that never took a turn stayed blocked"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "never-started-clean: task metadata was left behind"
  assert_grep "verdict: unstarted" "$case_dir/stderr" \
    "never-started-clean: the absent session was not surfaced"
  assert_grep "no model-routing verdict could be obtained" "$case_dir/stderr" \
    "never-started-clean: teardown did not state that no verdict was obtained"
  [ ! -d "$dir" ] || fail "never-started-clean: fixture wrote a transcript directory"
  pass "a never-started worker with nothing to lose tears down and still reports no verdict"
}

test_fresh_store_and_clean_tears_down_without_force() {
  local case_dir rc
  case_dir=$(make_case fresh-store-clean)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  rmdir "$case_dir/claude-config/projects"
  never_started_worktree "$case_dir"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "fresh-store-clean: a fresh store without a transcript parent stayed blocked"
  assert_grep "verdict: unstarted" "$case_dir/stderr" \
    "fresh-store-clean: the absent transcript parent was not surfaced as unstarted"
  assert_grep "no transcript parent or session" "$case_dir/stderr" \
    "fresh-store-clean: the fresh-store cause was not named"
  assert_absent "$case_dir/state/task-x1.meta" "fresh-store-clean: task metadata was left behind"
  pass "a never-started worker with a fresh evidence store tears down"
}

test_uninspectable_evidence_store_still_refuses() {
  local case_dir rc
  case_dir=$(make_case uninspectable-evidence-store)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  rm -rf "$case_dir/claude-config"
  never_started_worktree "$case_dir"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "uninspectable-evidence-store: teardown discarded evidence it could not inspect"
  assert_grep "verdict: unverifiable" "$case_dir/stderr" \
    "uninspectable-evidence-store: the store failure was not unverifiable"
  assert_grep "model-evidence store is missing" "$case_dir/stderr" \
    "uninspectable-evidence-store: the missing store was not named"
  assert_grep "REFUSED" "$case_dir/stderr" "uninspectable-evidence-store: no refusal was printed"
  assert_present "$case_dir/state/task-x1.meta" "uninspectable-evidence-store: task metadata was erased"
  pass "an uninspectable recorded evidence store remains unverifiable and refuses teardown"
}

test_non_directory_session_path_still_refuses() {
  local case_dir dir rc
  case_dir=$(make_case non-directory-session-path)
  write_meta "$case_dir" no-mistakes ship
  dir=$(claude_dispatch_meta "$case_dir")
  printf 'not transcript data\n' > "$dir"
  never_started_worktree "$case_dir"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "non-directory-session-path: teardown discarded uninspectable evidence"
  assert_grep "verdict: unverifiable" "$case_dir/stderr" \
    "non-directory-session-path: the present path was not unverifiable"
  assert_grep "transcript path is not a directory" "$case_dir/stderr" \
    "non-directory-session-path: the path cause was not named"
  assert_present "$case_dir/state/task-x1.meta" "non-directory-session-path: task metadata was erased"
  pass "a present non-directory session path remains unverifiable and refuses teardown"
}

test_non_directory_session_parent_still_refuses() {
  local case_dir dir parent rc
  case_dir=$(make_case non-directory-session-parent)
  write_meta "$case_dir" no-mistakes ship
  dir=$(claude_dispatch_meta "$case_dir")
  parent=${dir%/*}
  rmdir "$parent"
  printf 'not a transcript parent\n' > "$parent"
  never_started_worktree "$case_dir"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "non-directory-session-parent: teardown discarded uninspectable evidence"
  assert_grep "verdict: unverifiable" "$case_dir/stderr" \
    "non-directory-session-parent: the present parent was not unverifiable"
  assert_grep "transcript parent path is not a directory" "$case_dir/stderr" \
    "non-directory-session-parent: the parent cause was not named"
  assert_present "$case_dir/state/task-x1.meta" "non-directory-session-parent: task metadata was erased"
  pass "a present non-directory session parent remains unverifiable and refuses teardown"
}

test_unreadable_session_parent_still_refuses() {
  local case_dir dir parent rc
  case_dir=$(make_case unreadable-session-parent)
  write_meta "$case_dir" no-mistakes ship
  dir=$(claude_dispatch_meta "$case_dir")
  parent=${dir%/*}
  never_started_worktree "$case_dir"
  chmod 000 "$parent"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  chmod 755 "$parent"
  if [ "$(id -u)" = 0 ]; then
    pass "unreadable session parent teardown case skipped (running as root)"
    return
  fi
  [ "$rc" -ne 0 ] || fail "unreadable-session-parent: teardown discarded hidden evidence"
  assert_grep "verdict: unverifiable" "$case_dir/stderr" \
    "unreadable-session-parent: the hidden path was not unverifiable"
  assert_grep "transcript parent directory is not readable" "$case_dir/stderr" \
    "unreadable-session-parent: the parent cause was not named"
  assert_present "$case_dir/state/task-x1.meta" "unreadable-session-parent: task metadata was erased"
  pass "an unreadable session parent remains unverifiable and refuses teardown"
}

test_first_turn_before_final_recompute_refuses() {
  local case_dir dir rc
  case_dir=$(make_case first-turn-before-cleanup)
  write_meta "$case_dir" no-mistakes ship
  dir=$(claude_dispatch_meta "$case_dir")
  never_started_worktree "$case_dir"
  install_tmux_close_mutation "$case_dir"

  rc=0
  FM_TEST_CLOSE_MUTATION=model-turn \
    FM_TEST_ENDPOINT_CLOSE_ATTEMPTED="$case_dir/endpoint-close-attempted" \
    FM_TEST_TRANSCRIPT_DIR="$dir" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "first-turn-before-cleanup: teardown discarded a mismatched first turn"
  assert_grep "verdict: unstarted" "$case_dir/stderr" \
    "first-turn-before-cleanup: the initial unstarted verdict was not surfaced"
  assert_grep "verdict: mismatch" "$case_dir/stderr" \
    "first-turn-before-cleanup: the recomputed mismatch was not surfaced"
  assert_grep "gained a model-attributed turn" "$case_dir/stderr" \
    "first-turn-before-cleanup: the changed no-turn condition was not named"
  assert_present "$case_dir/endpoint-close-attempted" \
    "first-turn-before-cleanup: the best-effort close did not trigger the late turn"
  assert_present "$dir/current.jsonl" \
    "first-turn-before-cleanup: the late transcript was erased"
  assert_present "$case_dir/wt" \
    "first-turn-before-cleanup: the task worktree was returned"
  assert_present "$case_dir/state/task-x1.meta" "first-turn-before-cleanup: task metadata was erased"
  pass "a first mismatched turn before final recomputation is preserved"
}

test_unknown_liveness_completes_cleanup_and_retains_worktree() {
  local case_dir rc
  case_dir=$(make_case unknown-liveness-clean)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  never_started_worktree "$case_dir"
  use_unverified_zellij_backend "$case_dir"
  install_destructive_treehouse_probe "$case_dir"
  mkdir -p "$case_dir/task-tmp"
  printf 'task temp evidence\n' > "$case_dir/task-tmp/evidence.txt"
  printf '%s\n' "tasktmp=$case_dir/task-tmp" >> "$case_dir/state/task-x1.meta"

  rc=0
  FM_TEST_ENDPOINT_CLOSE_ATTEMPTED="$case_dir/endpoint-close-attempted" \
    FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "unknown-liveness-clean: every on-disk protection still stayed blocked"
  assert_grep "Endpoint liveness could not be determined on backend zellij (state: unverified)" "$case_dir/stderr" \
    "unknown-liveness-clean: the missing recovery classifier was not stated"
  assert_grep "recomputed on-disk proof" "$case_dir/stderr" \
    "unknown-liveness-clean: the protections carrying the decision were not stated"
  assert_grep "worktree $case_dir/wt is retained rather than recycled because liveness could not be determined" "$case_dir/stderr" \
    "unknown-liveness-clean: the retained worktree and reason were not stated"
  assert_present "$case_dir/endpoint-close-attempted" \
    "unknown-liveness-clean: the best-effort endpoint close was not attempted"
  assert_absent "$case_dir/treehouse-returned" \
    "unknown-liveness-clean: the retained worktree reached treehouse return"
  assert_present "$case_dir/wt" "unknown-liveness-clean: the retained worktree was removed"
  assert_present "$case_dir/task-tmp/evidence.txt" \
    "unknown-liveness-clean: the retained task temp root was removed"
  assert_present "$case_dir/data/task-x1/outcome.json" \
    "unknown-liveness-clean: the durable outcome was not published"
  assert_absent "$case_dir/state/task-x1.meta" "unknown-liveness-clean: task metadata was left behind"
  pass "unknown endpoint liveness completes cleanup and retains the worktree"
}

# Usage attribution must outlive cleanup. The live session map is a volatile
# record like the metadata beside it, so teardown removes it - but only after the
# durable manifest has carried its contents into history.
test_usage_session_map_reaches_the_manifest_before_cleanup_removes_it() {
  local case_dir rc
  case_dir=$(make_case usage-session-map)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  never_started_worktree "$case_dir"
  use_unverified_zellij_backend "$case_dir"
  install_destructive_treehouse_probe "$case_dir"
  printf '%s\n' '{"schema":"fm-usage-sessions.v1","task_id":"task-x1","recorded_at":"2026-08-01T10:00:00Z","sessions":[{"harness":"claude","session_id":"session-teardown","source_kind":"claude-jsonl"}]}' \
    > "$case_dir/state/task-x1.usage-sessions"

  rc=0
  FM_TEST_ENDPOINT_CLOSE_ATTEMPTED="$case_dir/endpoint-close-attempted" \
    FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "usage-session-map: cleanup did not complete"
  assert_grep 'session-teardown' "$case_dir/data/task-x1/outcome.json" \
    "usage-session-map: the durable outcome lost the task's usage sessions"
  assert_absent "$case_dir/state/task-x1.usage-sessions" \
    "usage-session-map: the volatile session map was left behind"
  pass "the usage session map reaches durable history before cleanup removes it"
}

# The last usage a task produces arrives after any earlier collector run, so
# cleanup refreshes the session map from the live records before archiving them.
# The refresh is conditional on a store the operator already created, which is
# why every other cleanup test above never invokes it.
test_cleanup_refreshes_usage_sessions_when_a_store_exists() {
  local case_dir rc
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return; }
  node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null \
    || { echo "skip: node:sqlite not available"; return; }
  case_dir=$(make_case usage-refresh)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  never_started_worktree "$case_dir"
  use_unverified_zellij_backend "$case_dir"
  install_destructive_treehouse_probe "$case_dir"

  # An operator has opted into usage accounting, and a session ran in this
  # task's worktree since the last collection.
  mkdir -p "$case_dir/usage-claude/-slot" "$case_dir/usage-codex"
  # The task's dispatch record is what dates its start, and a session is only
  # claimed from the moment its task held the worktree.
  TZ=UTC touch -t 202607310000.00 "$case_dir/state/task-x1.meta"
  node "$ROOT/bin/fm-usage.mjs" migrate --home "$case_dir" \
    --db "$case_dir/data/usage.db" >/dev/null || fail "usage-refresh: store setup failed"
  printf '%s\n' "{\"type\":\"assistant\",\"uuid\":\"u9\",\"sessionId\":\"session-late\",\"cwd\":\"$case_dir/wt\",\"timestamp\":\"2026-08-01T10:00:00Z\",\"message\":{\"id\":\"msg_late\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":5,\"output_tokens\":5,\"cache_read_input_tokens\":5,\"cache_creation_input_tokens\":5}}}" \
    > "$case_dir/usage-claude/-slot/late.jsonl"

  rc=0
  FM_TEST_ENDPOINT_CLOSE_ATTEMPTED="$case_dir/endpoint-close-attempted" \
    FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    FM_USAGE_CLAUDE_ROOT="$case_dir/usage-claude" \
    FM_USAGE_CODEX_ROOT="$case_dir/usage-codex" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "usage-refresh: cleanup did not complete"
  assert_grep 'session-late' "$case_dir/data/task-x1/outcome.json" \
    "usage-refresh: a session observed only at cleanup time never reached durable history"
  pass "cleanup refreshes the usage session map before archiving the task"
}

# The acceptance criterion the whole durable-attribution design exists for, end
# to end through the REAL cleanup rather than in halves: a completed task's
# tokens are still reported once its volatile records are gone. The two cases
# above prove cleanup puts the sessions in the manifest and the usage suite
# proves a manifest carries totals; only reading the report after driving
# fm-teardown.sh proves the joint between them holds for both harnesses.
test_completed_task_still_reports_its_tokens_after_cleanup() {
  local case_dir rc roll before after sessions method
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return; }
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return; }
  node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null \
    || { echo "skip: node:sqlite not available"; return; }
  case_dir=$(make_case usage-survives-cleanup)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  never_started_worktree "$case_dir"
  use_unverified_zellij_backend "$case_dir"
  install_destructive_treehouse_probe "$case_dir"
  mkdir -p "$case_dir/usage-claude/-slot" "$case_dir/usage-codex/2026/08/01"
  TZ=UTC touch -t 202607310000.00 "$case_dir/state/task-x1.meta"

  # Claude repeats one API response across transcript lines; only the response
  # counts once. 120 + 880 + 40000 + 5000 = 46000 tokens.
  local line
  line="{\"type\":\"assistant\",\"sessionId\":\"session-claude-durable\",\"cwd\":\"$case_dir/wt\",\"timestamp\":\"2026-08-01T10:00:00Z\",\"message\":{\"id\":\"msg_durable\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":120,\"output_tokens\":880,\"cache_read_input_tokens\":40000,\"cache_creation_input_tokens\":5000}}}"
  printf '%s\n%s\n' "$line" "$line" > "$case_dir/usage-claude/-slot/session.jsonl"
  # Codex reports cumulative session totals, with its cached tokens inside the
  # input count: 9000 + 1000 = 10000 tokens.
  roll="$case_dir/usage-codex/2026/08/01/rollout-session-codex-durable.jsonl"
  printf '%s\n' "{\"timestamp\":\"2026-08-01T10:05:00Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"session-codex-durable\",\"cwd\":\"$case_dir/wt\"}}" > "$roll"
  printf '%s\n' "{\"timestamp\":\"2026-08-01T10:05:01Z\",\"type\":\"turn_context\",\"payload\":{\"cwd\":\"$case_dir/wt\",\"model\":\"gpt-5.6-sol\"}}" >> "$roll"
  printf '%s\n' '{"timestamp":"2026-08-01T10:06:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000,"output_tokens":1000,"cached_input_tokens":8000,"cache_write_input_tokens":0,"reasoning_output_tokens":400,"total_tokens":10000}}}}' >> "$roll"

  usage_cli() {
    FM_USAGE_CLAUDE_ROOT="$case_dir/usage-claude" FM_USAGE_CODEX_ROOT="$case_dir/usage-codex" \
      node "$ROOT/bin/fm-usage.mjs" "$@" --home "$case_dir" --db "$case_dir/data/usage.db"
  }
  usage_cli ingest >/dev/null || fail "usage-survives-cleanup: the live collection failed"
  before=$(usage_cli report --by task | jq -r '.rows[] | select(.key=="task-x1") | .total_tokens')
  [ "$before" = 56000 ] \
    || fail "usage-survives-cleanup: the live task should hold 56000 tokens, got '$before'"

  rc=0
  FM_TEST_ENDPOINT_CLOSE_ATTEMPTED="$case_dir/endpoint-close-attempted" \
    FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    FM_USAGE_CLAUDE_ROOT="$case_dir/usage-claude" \
    FM_USAGE_CODEX_ROOT="$case_dir/usage-codex" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "usage-survives-cleanup: cleanup did not complete"
  assert_absent "$case_dir/state/task-x1.meta" \
    "usage-survives-cleanup: cleanup left the task live, so nothing was proven"

  # A store rebuilt after cleanup can only learn whose tokens these are from the
  # durable manifest, which is the record that has to carry them.
  rm -f "$case_dir/data/usage.db" "$case_dir/data/usage.db-wal" "$case_dir/data/usage.db-shm"
  usage_cli ingest >/dev/null || fail "usage-survives-cleanup: the post-cleanup collection failed"
  after=$(usage_cli report --by task | jq -r '.rows[] | select(.key=="task-x1") | .total_tokens')
  [ "$after" = "$before" ] \
    || fail "usage-survives-cleanup: a torn-down task lost its tokens ($before -> '$after')"
  sessions=$(usage_cli report --by task | jq -r '.rows[] | select(.key=="task-x1") | .sessions')
  [ "$sessions" = 2 ] \
    || fail "usage-survives-cleanup: both harnesses' sessions must survive, got '$sessions'"
  method=$(usage_cli attribution | jq -r '.by_method[] | select(.tokens==56000) | .method + "/" + .confidence')
  [ "$method" = session_binding/high ] \
    || fail "usage-survives-cleanup: the surviving tokens must stay a high-confidence binding, got '$method'"
  unset -f usage_cli
  pass "a completed task still reports both harnesses' tokens after the real cleanup"
}

# A dispatch whose record names no evidence store was never armed for the
# model-routing check, so it can never produce a verdict no matter what happens
# later. That gap must not read as a safety signal - but it also must not turn
# into a licence to read whatever store the environment happens to point at.
# The ambient store here holds a MISMATCHING transcript for this exact worktree:
# it must stay unattributed, unreported, and undeleted.
test_pre_guard_dispatch_tears_down_without_attributing_ambient_evidence() {
  local case_dir rc ambient_dir
  case_dir=$(make_case pre-guard-clean)
  pre_guard_dispatch_meta "$case_dir"
  never_started_worktree "$case_dir"
  install_authoritative_dead_tmux "$case_dir"
  install_destructive_treehouse_probe "$case_dir"
  ambient_dir="$case_dir/ambient-claude/projects/$(printf '%s' "$case_dir/wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$ambient_dir"
  printf '{"type":"assistant","message":{"model":"claude-sonnet-5"}}\n' > "$ambient_dir/current.jsonl"

  rc=0
  FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/ambient-claude" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pre-guard-clean: a dispatch that can never produce a verdict stayed blocked"
  assert_grep "verdict: unarmed" "$case_dir/stderr" \
    "pre-guard-clean: the never-armed dispatch was not surfaced"
  assert_grep "actual: -" "$case_dir/stderr" \
    "pre-guard-clean: ambient evidence was attributed to a dispatch that recorded no store"
  assert_grep "not a failed verification" "$case_dir/stderr" \
    "pre-guard-clean: teardown did not tell the operator which case this is"
  grep -q "REFUSED" "$case_dir/stderr" \
    && fail "pre-guard-clean: teardown still refused: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "pre-guard-clean: the task metadata was left behind"
  assert_present "$case_dir/data/task-x1/outcome.json" \
    "pre-guard-clean: the task left the fleet without a durable completion record"
  assert_present "$ambient_dir/current.jsonl" \
    "pre-guard-clean: teardown deleted transcript evidence it never owned"
  pass "a dispatch that was never armed for verification tears down without reading ambient evidence"
}

# The case that must NOT move. Same landed, spotless fixture as the allowance
# above; the single difference is that this record DOES name its evidence store,
# so its verdict is real and its failure keeps refusing.
test_recorded_store_with_failed_verdict_still_refuses() {
  local case_dir dir rc
  case_dir=$(make_case recorded-store-failed-verdict)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^model=default$/model=opus/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  dir=$(claude_dispatch_meta "$case_dir")
  mkdir -p "$dir"
  printf '{"type":"assistant","message":{"model":"claude-sonnet-5"}}\n' > "$dir/current.jsonl"
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  install_destructive_treehouse_probe "$case_dir"

  rc=0
  FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "recorded-store-failed-verdict: a recorded failed verdict stopped refusing"
  assert_grep "verdict: mismatch" "$case_dir/stderr" \
    "recorded-store-failed-verdict: the mismatch was not surfaced"
  assert_grep "REFUSED" "$case_dir/stderr" \
    "recorded-store-failed-verdict: no refusal was printed"
  grep -q "verdict: unarmed" "$case_dir/stderr" \
    && fail "recorded-store-failed-verdict: an armed dispatch was reported as never armed"
  assert_absent "$case_dir/treehouse-returned" \
    "recorded-store-failed-verdict: the preserved worktree reached treehouse return"
  assert_present "$case_dir/state/task-x1.meta" \
    "recorded-store-failed-verdict: the task metadata was erased"
  assert_absent "$case_dir/data/task-x1/outcome.json" \
    "recorded-store-failed-verdict: a refused teardown published a completion outcome"
  pass "a recorded evidence store whose verdict did not pass still refuses on landed, spotless work"
}

# The release rests on positive markers, not on the bare absence of a store
# line. This is the SAME landed, spotless fixture the allowance above tears down
# on, with one line added: a model-evidence arming marker, which bin/fm-spawn.sh
# only ever writes together with the store it captured. That proves the record
# was armed and damaged afterwards, so it keeps refusing.
#
# The third shape in that enumeration, a remote secondmate route record, is
# pinned at verifier level in tests/fm-model-verify.test.sh only:
# bin/fm-teardown.sh routes a genuine remote secondmate to
# remote_secondmate_teardown and returns before the model check, so a teardown
# fixture for it would have to be faked and would assert something misleading.
test_arming_marker_without_store_still_refuses() {
  local case_dir rc
  case_dir=$(make_case armed-marker-no-store)
  pre_guard_dispatch_meta "$case_dir"
  printf '%s\n' 'model_evidence_watermark=claude-transcript-v1' >> "$case_dir/state/task-x1.meta"
  never_started_worktree "$case_dir"
  install_authoritative_dead_tmux "$case_dir"
  install_destructive_treehouse_probe "$case_dir"

  rc=0
  FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/ambient-claude" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "armed-marker-no-store: a damaged armed record stopped refusing"
  assert_grep "verdict: unverifiable" "$case_dir/stderr" \
    "armed-marker-no-store: the damaged armed record was not unverifiable"
  assert_grep "REFUSED" "$case_dir/stderr" \
    "armed-marker-no-store: no refusal was printed"
  grep -q "verdict: unarmed" "$case_dir/stderr" \
    && fail "armed-marker-no-store: a record proven to have been armed was released"
  assert_absent "$case_dir/treehouse-returned" \
    "armed-marker-no-store: the preserved worktree reached treehouse return"
  assert_present "$case_dir/state/task-x1.meta" \
    "armed-marker-no-store: the task metadata was erased"
  assert_absent "$case_dir/data/task-x1/outcome.json" \
    "armed-marker-no-store: a refused teardown published a completion outcome"
  pass "a record carrying an arming marker but no evidence store still refuses"
}

# An armed dispatch that produced no verdict for a DIFFERENT reason keeps
# refusing too: a damaged anchor is not the same record shape as an absent one.
test_recorded_store_with_malformed_timestamp_still_refuses() {
  local case_dir rc
  case_dir=$(make_case recorded-store-malformed-timestamp)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  printf '%s\n' 'spawned_at=not-a-timestamp' >> "$case_dir/state/task-x1.meta"
  never_started_worktree "$case_dir"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "recorded-store-malformed-timestamp: a damaged anchor stopped refusing"
  assert_grep "verdict: unverifiable" "$case_dir/stderr" \
    "recorded-store-malformed-timestamp: the damaged anchor was not unverifiable"
  assert_grep "REFUSED" "$case_dir/stderr" \
    "recorded-store-malformed-timestamp: no refusal was printed"
  assert_present "$case_dir/state/task-x1.meta" \
    "recorded-store-malformed-timestamp: the task metadata was erased"
  pass "a recorded evidence store with a damaged dispatch anchor still refuses"
}

# The allowance narrows ONE refusal. These four pin the others on exactly the
# record shape that now gets past the model-routing check, so it can never
# become a general-purpose escape from teardown safety.
test_pre_guard_with_uncommitted_changes_still_refuses() {
  local case_dir rc
  case_dir=$(make_case pre-guard-dirty)
  pre_guard_dispatch_meta "$case_dir"
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  printf 'uncommitted work\n' > "$case_dir/wt/scratch.txt"
  install_destructive_treehouse_probe "$case_dir"

  rc=0
  FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/ambient-claude" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "pre-guard-dirty: uncommitted work was discarded"
  assert_grep "verdict: unarmed" "$case_dir/stderr" \
    "pre-guard-dirty: the fixture did not exercise the never-armed path"
  assert_grep "has uncommitted changes" "$case_dir/stderr" \
    "pre-guard-dirty: the refusal was not the uncommitted-change one"
  assert_absent "$case_dir/treehouse-returned" \
    "pre-guard-dirty: the dirty worktree reached treehouse return"
  assert_present "$case_dir/wt/scratch.txt" "pre-guard-dirty: the uncommitted file was removed"
  assert_present "$case_dir/state/task-x1.meta" "pre-guard-dirty: the task metadata was erased"
  pass "a never-armed dispatch with uncommitted changes still refuses"
}

test_pre_guard_with_unlanded_work_still_refuses() {
  local case_dir rc
  case_dir=$(make_case pre-guard-unlanded)
  pre_guard_dispatch_meta "$case_dir"
  # Committed on the task branch, pushed nowhere, in no default branch.
  wt_commit_file "$case_dir" unlanded.txt "work that never landed"
  install_destructive_treehouse_probe "$case_dir"

  rc=0
  FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/ambient-claude" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "pre-guard-unlanded: unlanded work was discarded"
  assert_grep "verdict: unarmed" "$case_dir/stderr" \
    "pre-guard-unlanded: the fixture did not exercise the never-armed path"
  assert_grep "not on any remote and not landed" "$case_dir/stderr" \
    "pre-guard-unlanded: the refusal was not the unlanded-work one"
  assert_absent "$case_dir/treehouse-returned" \
    "pre-guard-unlanded: the unlanded worktree reached treehouse return"
  assert_present "$case_dir/wt/unlanded.txt" "pre-guard-unlanded: the unlanded commit was removed"
  assert_present "$case_dir/state/task-x1.meta" "pre-guard-unlanded: the task metadata was erased"
  pass "a never-armed dispatch with unlanded work still refuses"
}

test_pre_guard_with_unpublishable_manifest_still_refuses() {
  local case_dir rc
  case_dir=$(make_case pre-guard-manifest)
  pre_guard_dispatch_meta "$case_dir"
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # An unwritable manifest destination, exactly as the armed case uses.
  mkdir -p "$case_dir/data/task-x1/outcome.json"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/ambient-claude" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "pre-guard-manifest: an unarchivable task was erased"
  assert_grep "verdict: unarmed" "$case_dir/stderr" \
    "pre-guard-manifest: the fixture did not exercise the never-armed path"
  assert_grep "could not publish the durable outcome manifest" "$case_dir/stderr" \
    "pre-guard-manifest: teardown did not name the manifest failure"
  assert_present "$case_dir/state/task-x1.meta" "pre-guard-manifest: the task metadata was erased"
  pass "a never-armed dispatch whose completion manifest cannot be published still refuses"
}

test_pre_guard_with_invalid_endpoint_still_refuses() {
  local case_dir rc
  case_dir=$(make_case pre-guard-endpoint)
  pre_guard_dispatch_meta "$case_dir"
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # A second window= line makes the recorded endpoint ambiguous.
  printf '%s\n' 'window=firstmate:fm-someone-else' >> "$case_dir/state/task-x1.meta"
  install_destructive_treehouse_probe "$case_dir"

  rc=0
  FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/ambient-claude" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "pre-guard-endpoint: an ambiguous endpoint was cleaned up anyway"
  assert_grep "ambiguous window endpoint" "$case_dir/stderr" \
    "pre-guard-endpoint: the endpoint failure was not named"
  grep -q "verdict:" "$case_dir/stderr" \
    && fail "pre-guard-endpoint: endpoint validation no longer runs before the model check"
  assert_absent "$case_dir/treehouse-returned" \
    "pre-guard-endpoint: the worktree reached treehouse return"
  assert_present "$case_dir/state/task-x1.meta" "pre-guard-endpoint: the task metadata was erased"
  pass "a never-armed dispatch whose endpoint does not validate still refuses"
}

# Ignored content is work exactly as untracked content is, and `git status
# --untracked-files=all` does not report it at all. A cleanliness proof that
# cannot see it would authorize discarding real files.
test_ignored_content_refuses_while_allowlisted_harness_files_do_not() {
  local case_dir rc
  case_dir=$(make_case ignored-content)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  printf 'build/\n' > "$case_dir/wt/.gitignore"
  git -C "$case_dir/wt" add -- .gitignore
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "ignore build output"
  git -C "$case_dir/project" merge -q --ff-only fm/task-x1
  git -C "$case_dir/project" push -q origin main
  never_started_worktree "$case_dir"
  install_authoritative_dead_tmux "$case_dir"
  mkdir -p "$case_dir/wt/build"
  printf 'hours of generated work\n' > "$case_dir/wt/build/artifact.txt"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "ignored-content: ignored work was discarded"
  assert_grep "REFUSED" "$case_dir/stderr" "ignored-content: no refusal was printed"
  assert_present "$case_dir/wt/build/artifact.txt" "ignored-content: ignored work was removed"
  assert_present "$case_dir/state/task-x1.meta" "ignored-content: task metadata was erased"
  pass "ignored content beyond the allowlist refuses rather than being discarded"
}

# The mirror case: the harness files bin/fm-spawn.sh writes itself are the only
# content the proof may look past, whether they arrive untracked or ignored.
test_allowlisted_harness_files_still_tear_down() {
  local case_dir rc
  case_dir=$(make_case ignored-allowlisted)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  printf '.claude/\n' > "$case_dir/wt/.gitignore"
  git -C "$case_dir/wt" add -- .gitignore
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "ignore harness files"
  git -C "$case_dir/project" merge -q --ff-only fm/task-x1
  git -C "$case_dir/project" push -q origin main
  never_started_worktree "$case_dir"
  install_authoritative_dead_tmux "$case_dir"
  mkdir -p "$case_dir/wt/.claude"
  printf '{}\n' > "$case_dir/wt/.claude/settings.local.json"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "ignored-allowlisted: harness-owned files blocked teardown"
  assert_absent "$case_dir/state/task-x1.meta" "ignored-allowlisted: task metadata was left behind"
  pass "harness-owned files alone do not block the never-started allowance"
}

test_authoritative_dead_endpoint_recycles_worktree() {
  local case_dir rc
  case_dir=$(make_case authoritative-dead-endpoint)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  never_started_worktree "$case_dir"
  install_authoritative_dead_tmux "$case_dir"
  install_destructive_treehouse_probe "$case_dir"

  rc=0
  FM_TEST_TREEHOUSE_RETURNED="$case_dir/treehouse-returned" \
    FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "authoritative-dead-endpoint: teardown did not complete"
  assert_grep "Backend tmux reports no live worker (state: dead)" "$case_dir/stderr" \
    "authoritative-dead-endpoint: authoritative dead liveness was not stated"
  assert_present "$case_dir/treehouse-returned" \
    "authoritative-dead-endpoint: the worktree was not recycled"
  assert_absent "$case_dir/wt" "authoritative-dead-endpoint: the recycled worktree remained"
  assert_absent "$case_dir/state/task-x1.meta" \
    "authoritative-dead-endpoint: task metadata was left behind"
  pass "an authoritative dead endpoint recycles its worktree normally"
}

test_authoritative_live_endpoint_refuses() {
  local case_dir rc
  case_dir=$(make_case authoritative-live-endpoint)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  never_started_worktree "$case_dir"
  install_authoritative_live_tmux "$case_dir"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "authoritative-live-endpoint: teardown killed a verified live worker"
  assert_grep "live worker according to backend tmux" "$case_dir/stderr" \
    "authoritative-live-endpoint: authoritative liveness was not named"
  assert_absent "$case_dir/endpoint-close-attempted" \
    "authoritative-live-endpoint: a close was attempted for the live endpoint"
  assert_present "$case_dir/state/task-x1.meta" "authoritative-live-endpoint: task metadata was erased"
  pass "an authoritative live endpoint refuses never-started teardown"
}

test_recomputed_on_disk_proof_refuses_each_failed_condition() {
  local case_dir dir failure rc
  for failure in model-turn task-branch own-commit tracked-change untracked-file; do
    case_dir=$(make_case "recomputed-proof-$failure")
    write_meta "$case_dir" no-mistakes ship
    dir=$(claude_dispatch_meta "$case_dir")
    never_started_worktree "$case_dir"
    install_tmux_close_mutation "$case_dir"

    rc=0
    FM_TEST_CLOSE_MUTATION="$failure" \
      FM_TEST_TRANSCRIPT_DIR="$dir" \
      FM_TEST_PROJECT="$case_dir/project" \
      FM_TEST_WT="$case_dir/wt" \
      FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "recomputed-proof-$failure: teardown proceeded without every protection"
    assert_grep "REFUSED" "$case_dir/stderr" \
      "recomputed-proof-$failure: the missing protection did not refuse loudly"
    assert_present "$case_dir/state/task-x1.meta" \
      "recomputed-proof-$failure: task metadata was erased"
  done
  pass "the recomputed on-disk proof refuses each failed protection"
}

# The same allowance for the other no-turn shape: the runtime DID open a session
# but the worker never reached a model-attributed turn (Claude's first-run
# onboarding leaves exactly this). Its detail differs from the absent-session
# case, and both must clear.
test_never_started_with_session_but_no_turn_tears_down() {
  local case_dir dir rc
  case_dir=$(make_case never-started-pending)
  write_meta "$case_dir" no-mistakes ship
  dir=$(claude_dispatch_meta "$case_dir")
  mkdir -p "$dir"
  printf '{"type":"user","message":{"role":"user"}}\n' > "$dir/current.jsonl"
  never_started_worktree "$case_dir"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "never-started-pending: a session with no turn stayed blocked"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "never-started-pending: task metadata was left behind"
  assert_grep "verdict: pending" "$case_dir/stderr" \
    "never-started-pending: the pending verdict was not surfaced"
  assert_grep "no model-routing verdict could be obtained" "$case_dir/stderr" \
    "never-started-pending: teardown did not state that no verdict was obtained"
  pass "a worker whose session never reached a turn tears down and still reports no verdict"
}

# Half the evidence is not enough. Uncommitted changes are work to lose whatever
# the routing verdict says, and this boundary must not move with it.
test_never_started_but_dirty_still_refuses() {
  local case_dir rc
  case_dir=$(make_case never-started-dirty)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  never_started_worktree "$case_dir"
  printf 'half-written work\n' > "$case_dir/wt/scratch.txt"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "never-started-dirty: teardown discarded uncommitted work"
  assert_grep "REFUSED" "$case_dir/stderr" "never-started-dirty: no refusal was printed"
  assert_present "$case_dir/state/task-x1.meta" "never-started-dirty: task metadata was erased"
  [ -f "$case_dir/wt/scratch.txt" ] || fail "never-started-dirty: uncommitted work was removed"
  pass "a never-started worker with uncommitted changes still refuses"
}

test_never_started_with_untracked_claude_file_still_refuses() {
  local case_dir rc
  case_dir=$(make_case never-started-claude-file)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  never_started_worktree "$case_dir"
  mkdir -p "$case_dir/wt/.claude"
  printf 'recovery notes\n' > "$case_dir/wt/.claude/recovery.md"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "never-started-claude-file: teardown discarded an untracked file under .claude"
  assert_grep "REFUSED" "$case_dir/stderr" "never-started-claude-file: no refusal was printed"
  assert_present "$case_dir/state/task-x1.meta" "never-started-claude-file: task metadata was erased"
  assert_present "$case_dir/wt/.claude/recovery.md" "never-started-claude-file: untracked work was removed"
  pass "an untracked file under .claude remains work to preserve"
}

# The other half: a branch with its own commits is unlanded work, and the
# no-turn allowance must not reach it either.
test_never_started_but_committed_on_a_branch_still_refuses() {
  local case_dir rc
  case_dir=$(make_case never-started-branch)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  wt_commit "$case_dir" "work nobody has seen"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "never-started-branch: teardown discarded an unlanded branch"
  assert_grep "REFUSED" "$case_dir/stderr" "never-started-branch: no refusal was printed"
  assert_present "$case_dir/state/task-x1.meta" "never-started-branch: task metadata was erased"
  [ -d "$case_dir/wt" ] || fail "never-started-branch: the task worktree was returned"
  pass "a never-started worker whose branch carries commits still refuses"
}

test_never_started_with_detached_head_and_surviving_task_branch_still_refuses() {
  local case_dir rc
  case_dir=$(make_case never-started-detached-surviving-branch)
  write_meta "$case_dir" no-mistakes ship
  claude_dispatch_meta "$case_dir" >/dev/null
  wt_commit "$case_dir" "work retained only by the task branch"
  git -C "$case_dir/wt" checkout --detach -q main

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "never-started-detached-surviving-branch: teardown discarded a surviving task branch"
  assert_grep "REFUSED" "$case_dir/stderr" \
    "never-started-detached-surviving-branch: no refusal was printed"
  git -C "$case_dir/wt" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "never-started-detached-surviving-branch: the task branch was removed"
  assert_present "$case_dir/state/task-x1.meta" \
    "never-started-detached-surviving-branch: task metadata was erased"
  pass "a surviving task branch refuses teardown even while HEAD is detached and clean"
}

# The boundary this whole guard exists to hold: a worker that RAN, on evidence
# that cannot be attributed, keeps refusing even when its worktree is as clean
# as a never-started one. The allowance is keyed on the absent turn, not on the
# clean worktree.
test_ran_but_unverifiable_still_refuses_on_a_clean_worktree() {
  local case_dir dir rc
  case_dir=$(make_case ran-unverifiable)
  write_meta "$case_dir" no-mistakes ship
  dir=$(claude_dispatch_meta "$case_dir")
  # Drop the dispatch binding, then record two disagreeing models: evidence that
  # exists, was written by a worker that ran, and cannot be tied to this task.
  sed -i.bak '/^model_evidence_watermark=/d' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  mkdir -p "$dir"
  printf '{"type":"assistant","message":{"model":"claude-opus-5"}}\n' > "$dir/one.jsonl"
  printf '{"type":"assistant","message":{"model":"claude-sonnet-5"}}\n' > "$dir/two.jsonl"
  never_started_worktree "$case_dir"

  rc=0
  FM_TEST_CLAUDE_CONFIG_DIR="$case_dir/claude-config" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "ran-unverifiable: unattributable evidence was discarded unseen"
  assert_grep "verdict: unverifiable" "$case_dir/stderr" \
    "ran-unverifiable: the unverifiable verdict was not surfaced"
  assert_grep "REFUSED" "$case_dir/stderr" "ran-unverifiable: no refusal was printed"
  assert_present "$case_dir/state/task-x1.meta" "ran-unverifiable: task metadata was erased"
  pass "a worker that ran on unattributable evidence still refuses despite a clean worktree"
}

test_forced_teardown_surfaces_mismatch_before_discarding() {
  local case_dir cfg dir
  case_dir=$(make_case forced-terminal-model-verdict)
  write_meta "$case_dir" local-only ship
  cfg="$case_dir/claude-config"
  printf '%s\n' \
    'harness=claude' \
    'model=opus' \
    "model_evidence_store=$cfg" \
    'model_evidence_watermark=claude-transcript-v1' >> "$case_dir/state/task-x1.meta"
  dir="$cfg/projects/$(printf '%s' "$case_dir/wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  printf '{"type":"assistant","message":{"model":"claude-sonnet-5"}}\n' > "$dir/current.jsonl"

  FM_TEST_CLAUDE_CONFIG_DIR="$cfg" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "forced teardown lost its discard authority on a model mismatch"
  assert_grep "verdict: mismatch" "$case_dir/stderr" \
    "forced teardown did not surface the terminal model mismatch"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "forced teardown left task metadata behind"
  pass "forced teardown surfaces a mismatch before retaining its discard authority"
}

# Build the teardown test's executable search path without lsof, regardless of
# whether the host installs it in /usr/bin, /usr/sbin, or a package-manager bin.
make_path_without_lsof() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-lsof" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id jq ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present() {
  local case_dir out
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi done' >/dev/null \
    && fail "teardown prompted tasks-axi despite manual backend opt-out: $out"
  pass "teardown honors config/backlog-backend=manual even when tasks-axi is compatible"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "merged-main: cleanup left a task branch contained in local main"
  pass "local-only worktree merged into local main is torn down and its contained task branch is reaped"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "nm-origin: cleanup deleted a branch with no recorded PR or default-branch ancestry"
  assert_grep "kept local branch fm/task-x1" "$case_dir/stderr" \
    "nm-origin: cleanup did not explain why the unproven branch was kept"
  pass "no-mistakes worktree with HEAD on origin is torn down while its unproven branch is kept"
}

test_cleanup_never_deletes_the_worktrees_ambient_branch() {
  local case_dir rc
  case_dir=$(make_case ambient-branch)
  write_meta "$case_dir" no-mistakes ship
  git -C "$case_dir/wt" checkout -q -b unrelated
  wt_commit "$case_dir" "unrelated published work"
  git -C "$case_dir/wt" push -q origin unrelated
  git -C "$case_dir/project" fetch -q origin unrelated

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "ambient-branch: published work should allow cleanup"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/unrelated \
    || fail "ambient-branch: cleanup deleted the worktree's unrelated ambient branch"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "ambient-branch: cleanup left its own default-contained task branch behind"
  pass "cleanup targets only the task's exact fm/<id> branch, never the ambient branch"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

# The landed-work refusal decides whether removing this worktree destroys work
# nobody can recover. Asking about the branch the pool happens to have left in
# the worktree answers for whoever holds it now: here task-b's merged PR would
# have cleared task-x1's teardown. The task's own recorded branch is the only
# identity that can answer, and it finds no PR at all.
test_landed_work_is_evaluated_against_the_recorded_task_branch() {
  local case_dir rc head
  case_dir=$(make_case landed-recorded-branch)
  write_meta "$case_dir" no-mistakes ship
  git -C "$case_dir/wt" checkout -q -b fm/task-b
  wt_commit_file "$case_dir" feature.txt "task b work" "task b work"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_branch_head "$case_dir" fm/task-b "$head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "landed-recorded-branch: another branch's merged PR cleared this task's teardown"
  assert_grep "not on any remote and not landed" "$case_dir/stderr" \
    "landed-recorded-branch: the refusal was not the unlanded-work one"
  assert_present "$case_dir/wt" "landed-recorded-branch: the worktree was removed"
  assert_present "$case_dir/state/task-x1.meta" "landed-recorded-branch: task metadata was erased"
  pass "unlanded work is judged against the task's recorded branch, never the worktree's ambient one"
}

# The legacy half: with no recorded branch there is no identity to judge the
# work against, and guessing one from the ambient branch is exactly what loses
# another task's commits. Refusing keeps the worktree; --force still discards.
test_legacy_record_without_branch_refuses_unpushed_work() {
  local case_dir rc head
  case_dir=$(make_case landed-legacy-record)
  write_legacy_meta_without_branch "$case_dir" no-mistakes
  wt_commit_file "$case_dir" feature.txt "task work" "task work"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "landed-legacy-record: a record with no task branch cleared its own teardown"
  assert_grep "not on any remote and not landed" "$case_dir/stderr" \
    "landed-legacy-record: the refusal was not the unlanded-work one"
  assert_grep "no merged PR could be looked up by branch name" "$case_dir/stderr" \
    "landed-legacy-record: teardown did not state which proof it could not run"
  assert_present "$case_dir/wt" "landed-legacy-record: the worktree was removed"
  assert_present "$case_dir/state/task-x1.meta" "landed-legacy-record: task metadata was erased"
  pass "a legacy record with no task branch refuses unpushed work rather than guessing the branch"
}

# Fails if the missing branch= short-circuits the landed check instead of just
# disabling the branch-keyed PR lookup: pr= is read straight from the record.
test_legacy_record_without_branch_still_lands_on_its_recorded_pr() {
  local case_dir rc pr_head
  case_dir=$(make_case legacy-record-recorded-pr)
  write_legacy_meta_without_branch "$case_dir" no-mistakes
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "legacy-record-recorded-pr: teardown should succeed on a recorded merged PR"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "legacy-record-recorded-pr: teardown refused work its own pr= proves landed"
  pass "a legacy record with no task branch still lands on the merged PR its record names"
}

# Fails if the missing branch= short-circuits the landed check: content_in_default
# takes no branch at all, merge-treeing the default branch against the worktree HEAD.
test_legacy_record_without_branch_still_lands_on_default_content() {
  local case_dir rc
  case_dir=$(make_case legacy-record-content-landed)
  write_legacy_meta_without_branch "$case_dir" no-mistakes
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "legacy-record-content-landed: teardown should succeed on content already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" \
    || fail "legacy-record-content-landed: teardown refused work already squash-merged into the default branch"
  pass "a legacy record with no task branch still lands on content already in the default branch"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "squash-merged: cleanup left the exact merged task branch behind"
  pass "squash-merged + deleted-branch worktree is torn down and its exact merged branch is reaped"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_pushed_later_commit_keeps_branch() {
  local case_dir rc pr_head moved_head
  case_dir=$(make_case stale-pr-head-pushed)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  wt_commit_file "$case_dir" later.txt published "published follow-up"
  moved_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$moved_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-pr-head-pushed: published work should not block worktree cleanup"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "stale-pr-head-pushed: cleanup deleted a branch that moved after merge"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)" = "$moved_head" ] \
    || fail "stale-pr-head-pushed: cleanup changed the moved branch"
  assert_grep "kept local branch fm/task-x1: branch moved after the recorded merge" "$case_dir/stderr" \
    "stale-pr-head-pushed: cleanup did not explain why the moved branch was kept"
  pass "cleanup keeps a task branch that moved after its recorded PR merged"
}

test_forge_unreachable_keeps_branch_and_cleanup_succeeds() {
  local case_dir rc head
  case_dir=$(make_case branch-forge-unreachable)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "published feature"
  append_pr_meta_for_current_head "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q -u origin "$head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  # Model server-side branch deletion without updating this clone. Worktree
  # safety sees the still-present remote-tracking ref, then fleet refresh must
  # prune only that stale pointer while preserving the unproven local branch.
  git -C "$case_dir/origin.git" update-ref -d refs/heads/fm/task-x1
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "branch-forge-unreachable: branch proof failure must not fail cleanup"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "branch-forge-unreachable: cleanup deleted a branch it could not prove merged"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/remotes/origin/fm/task-x1 \
    || fail "branch-forge-unreachable: fleet refresh did not prune the stale remote pointer"
  assert_grep "kept local branch fm/task-x1: recorded PR merge could not be verified" "$case_dir/stderr" \
    "branch-forge-unreachable: cleanup did not explain why the branch was kept"
  # The keep-reason line is the only place an operator learns why the merge
  # could not be proven, so the refresh's own cause has to be folded into it
  # rather than discarded with its stderr.
  assert_grep "recorded PR merge could not be verified: fm-pr-status:" "$case_dir/stderr" \
    "branch-forge-unreachable: the keep reason did not name the cause the refresh reported"
  pass "an unreachable forge keeps the branch without failing cleanup"
}

test_unsupported_forge_keeps_branch_and_cleanup_succeeds() {
  local case_dir rc head
  case_dir=$(make_case branch-unsupported-forge)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "published feature"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://gitea.example/example/repo/pulls/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
  git -C "$case_dir/wt" push -q origin "$head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "branch-unsupported-forge: unsupported branch proof must not fail cleanup"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "branch-unsupported-forge: cleanup deleted a branch whose merge it could not query"
  assert_grep "kept local branch fm/task-x1: recorded PR forge is unsupported" "$case_dir/stderr" \
    "branch-unsupported-forge: cleanup did not explain why the branch was kept"
  pass "an unsupported forge keeps the branch without failing cleanup"
}

test_merged_pr_head_not_retained_by_forge_keeps_branch() {
  local case_dir rc head
  case_dir=$(make_case branch-head-not-retained)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$head"
  # The forge reports the merge at this exact head but keeps no copy of that
  # commit: its source branch is gone and its hidden pull ref is gone too. The
  # local branch is then the only place those commits survive, so a merged
  # verdict alone must not authorize deleting it.
  git -C "$case_dir/origin.git" update-ref -d refs/pull/7/head
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "branch-head-not-retained: an unverifiable head must not fail cleanup"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "branch-head-not-retained: cleanup deleted the only surviving copy of the merged commits"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)" = "$head" ] \
    || fail "branch-head-not-retained: cleanup moved the retained branch"
  assert_grep "kept local branch fm/task-x1: merged PR head is no longer verifiable on the remote" \
    "$case_dir/stderr" \
    "branch-head-not-retained: cleanup did not explain why the branch was kept"
  pass "a merged PR whose head the forge no longer retains keeps the branch"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "REFUSED: cannot determine leaked processes" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

# Flat (non-projected) Herdr endpoint whose fake pane exists until a locked
# close removes it. The socket path is case-local so the derived presentation
# lock never collides with another test or a real fleet session.
configure_flat_herdr_teardown_case() {  # <case-dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    fi
    ;;
  "pane close")
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ "\${FM_FAKE_HERDR_PANE_GET_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Record every treehouse invocation: the contended-lock refusal must fire
  # BEFORE the isolated copy is returned, so phase 1 may not invoke it at all.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if [ -s "$thlog" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "ambiguous structured presence" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
}

assert_herdr_teardown_preflight_refuses_before_changes() {
  local mode=$1 case_dir log closed rc thlog teardown_bin
  case_dir=$(make_case "herdr-preflight-$mode")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  teardown_bin=$TEARDOWN
  case "$mode" in
    missing-adapter|missing-parser|missing-explicit-close-helper)
      mkdir -p "$case_dir/test-root"
      cp -R "$ROOT/bin" "$case_dir/test-root/bin"
      if [ "$mode" = missing-adapter ]; then
        rm -f "$case_dir/test-root/bin/backends/herdr.sh"
      elif [ "$mode" = missing-explicit-close-helper ]; then
        sed -i.bak 's/^fm_backend_herdr_explicit_close_pane_confirmed()/fm_backend_herdr_explicit_close_pane_confirmed_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      else
        sed -i.bak 's/^fm_backend_herdr_parse_target()/fm_backend_herdr_parse_target_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      fi
      teardown_bin="$case_dir/test-root/bin/fm-teardown.sh"
      ;;
  esac
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE="$([ "$mode" = unresolvable-lock ] && printf 1 || printf 0)" \
    PATH="$case_dir/fakebin:$PATH" \
    "$teardown_bin" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-preflight-$mode: teardown continued without its required preflight"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-preflight-$mode: the retryable pre-return refusal was not explained visibly"
  [ -d "$case_dir/wt" ] || fail "herdr-preflight-$mode: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "fm/task-x1" ] \
    || fail "herdr-preflight-$mode: refusal dropped the task branch"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-preflight-$mode: refusal erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-preflight-$mode: refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] \
    || fail "herdr-preflight-$mode: refusal erased the turn-end record"
  [ ! -s "$thlog" ] || fail "herdr-preflight-$mode: refusal returned the isolated copy"
  [ ! -e "$closed" ] || fail "herdr-preflight-$mode: refusal attempted an unlocked pane close"
}

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
}

configure_secondmate_with_herdr_child() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-herdr.meta" \
    "window=childsession:wC:p1" \
    "endpoint_task_id=child-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "model=default" \
    "backend=herdr" \
    "herdr_session=childsession" \
    "herdr_workspace_id=wC" \
    "herdr_tab_id=wC:t1" \
    "herdr_pane_id=wC:p1"
  : > "$home/state/child-herdr.status"
  : > "$home/state/child-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"childsession","running":true,"socket_path":"$case_dir/child.sock"}]}'
    fi
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "\${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' 'not-json'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_secondmate_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the secondmate home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-child-preflight: refusal did not explain its non-mutating boundary"
  pass "forced secondmate teardown preflights every Herdr child before cleanup mutation"
}

test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the secondmate home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  assert_grep "child-herdr · verdict: unpinned" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: recursive forced cleanup did not surface the child's model verdict"
  pass "forced secondmate teardown retains Herdr child identity until exact pane disappearance"
}

configure_nested_secondmate_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" nested_home="$1/secondmate-home/nested-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' nested-sm > "$nested_home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/nested-sm.meta" \
    "window=firstmate:fm-nested-sm" \
    "endpoint_task_id=nested-sm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "home=$nested_home"
  fm_write_meta "$nested_home/state/grandchild-herdr.meta" \
    "window=grandchildsession:wG:p1" \
    "endpoint_task_id=grandchild-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=grandchildsession" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:t1" \
    "herdr_pane_id=wG:p1"
  : > "$nested_home/state/grandchild-herdr.status"
  : > "$nested_home/state/grandchild-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    printf '%s\n' '{"sessions":[{"name":"grandchildsession","running":true,"socket_path":"$case_dir/grandchild.sock"}]}'
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wG:p1","tab_id":"wG:t1","workspace_id":"wG"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested secondmate home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested secondmate's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level secondmate's record"
  pass "forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' '{"error":{"code":"internal"}}' >&2
        exit 1
      fi
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  local rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

# --- durable outcome manifest ------------------------------------------------
#
# Teardown is the last moment the records that describe a task still exist, so
# the manifest it publishes is the only thing that keeps the task in history.
# These cases pin publication before removal, the forced-discard outcome, and
# the refusal that stops a task being erased when it could not be archived.

test_teardown_publishes_outcome_manifest_before_removing_records() {
  local case_dir rc manifest
  case_dir=$(make_case manifest-publish)
  write_meta "$case_dir" local-only ship
  printf '%s\n' 'model=opus' 'effort=xhigh' >> "$case_dir/state/task-x1.meta"
  printf 'done: ready in branch\n' > "$case_dir/state/task-x1.status"
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "manifest-publish: teardown should succeed on landed work"

  manifest="$case_dir/data/task-x1/outcome.json"
  assert_present "$manifest" "teardown did not publish the durable outcome manifest"
  assert_absent "$case_dir/state/task-x1.meta" "teardown left the volatile task metadata behind"
  jq -e '.schema == "fm-outcome-manifest.v1" and .task_id == "task-x1"
    and .outcome.state == "done" and .outcome.forced == false
    and .model == "opus" and .effort == "xhigh"
    and .attribution.endpoint.target == "firstmate:fm-task-x1"' "$manifest" >/dev/null \
    || fail "the published manifest did not record the outcome and attribution: $(cat "$manifest")"
  pass "teardown publishes the durable outcome manifest and then removes the volatile records"
}

test_design_teardown_publishes_manifest_and_removes_records() {
  local case_dir rc manifest
  case_dir=$(make_case design-manifest-publish)
  write_meta "$case_dir" local-only design
  add_compatible_tasks_axi "$case_dir"
  printf '%s\n' 'decisions_reviewed=1' 'decision_keys=' >> "$case_dir/state/task-x1.meta"
  printf 'done: ADR ready in branch\n' > "$case_dir/state/task-x1.status"
  wt_commit "$case_dir" "record the design decision"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "design-manifest-publish: teardown should succeed on a reviewed landed ADR"

  manifest="$case_dir/data/task-x1/outcome.json"
  assert_present "$manifest" "design teardown did not publish its durable outcome manifest"
  assert_absent "$case_dir/state/task-x1.meta" "design teardown left volatile task metadata behind"
  jq -e '.kind == "design" and .outcome.state == "done" and .outcome.forced == false' \
    "$manifest" >/dev/null \
    || fail "design teardown published an invalid outcome manifest: $(cat "$manifest")"
  pass "design teardown preserves normal manifest publication and volatile-record cleanup"
}

test_forced_teardown_records_a_discarded_outcome() {
  local case_dir rc manifest
  case_dir=$(make_case manifest-forced)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unlanded work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "manifest-forced: forced teardown should succeed"

  manifest="$case_dir/data/task-x1/outcome.json"
  assert_present "$manifest" "a forced teardown did not publish a manifest"
  jq -e '.outcome.state == "discarded" and .outcome.forced == true
    and .outcome.source == "forced_teardown"' "$manifest" >/dev/null \
    || fail "a forced teardown did not record a discarded outcome: $(cat "$manifest")"
  pass "a forced teardown records the discard in durable history instead of erasing the task silently"
}

test_teardown_refuses_when_the_manifest_cannot_be_published() {
  local case_dir rc
  case_dir=$(make_case manifest-refuse)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # An unwritable manifest destination: publication fails, so the task must not
  # be erased without a durable record of it.
  mkdir -p "$case_dir/data/task-x1/outcome.json"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "manifest-refuse: teardown succeeded despite an unpublishable manifest"
  grep -q "could not publish the durable outcome manifest" "$case_dir/stderr" \
    || fail "manifest-refuse: teardown did not name the manifest failure: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.meta" \
    "manifest-refuse: teardown erased the task metadata it could not archive"
  pass "teardown refuses and retains every task record when the manifest cannot be published"
}

# --- Fix 1: conclude/abort the task's own parked no-mistakes run before the
# worker is removed, and Fix 2: reap leaked descendant processes rooted under
# the task's own worktree/tasktmp - both exercised through the real teardown
# path (bin/fm-teardown.sh), never by matching its source text. ------------

# A parked-at-a-gate `axi status` TOON payload for <branch>/<head>, matching
# the shape no-mistakes actually emits (see tests/fm-crew-state.test.sh's
# run_parked fixture, the same shape bin/fm-crew-state.sh's own tests pin).
parked_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$2"
  pr: ""
  findings: none
gate: review
EOF
}

running_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: running
  head: "$2"
  pr: ""
steps[1]{step,status,findings,summary}:
  test,running,0,"agent under way"
EOF
}

# Land a shippable commit on the task branch and push it to origin, the same
# "definitely landed, teardown must ALLOW" shape test_no_mistakes_origin_remote_allows
# uses, so these new cases exercise the abort/reap steps on a real successful
# teardown rather than a refusal path.
land_shippable_commit() {
  local case_dir=$1
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

test_parked_own_run_is_aborted_before_teardown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort: teardown should still succeed"
  assert_present "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort was never invoked for the task's own parked run"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort did not target the verified run id"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-abort: teardown did not report aborting the parked run before removing the worker"
  pass "a task's own parked no-mistakes run is aborted, not orphaned, before the worker is removed"
}

test_mismatched_run_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-replaced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head" 01RUN)" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT="$(parked_axi_status_toon fm/task-x1 "$head" 02RUN)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-replaced: a different run does not confirm the targeted abort"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-replaced: teardown did not abort only the verified run"
  assert_present "$case_dir/wt" "parked-run-replaced: teardown removed the worktree without confirmation"
  pass "a different run cannot confirm the targeted abort"
}

test_empty_status_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-empty-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_EMPTY_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-empty-confirmation: empty status should refuse"
  assert_present "$case_dir/wt" "parked-run-empty-confirmation: teardown removed the worktree"
  pass "empty post-abort status is not accepted as confirmation"
}

test_not_found_status_after_abort_confirms_completion() {
  local case_dir rc head
  case_dir=$(make_case parked-run-not-found-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_NOT_FOUND_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-found-confirmation: explicit not-found should confirm completion"
  pass "the CLI's exact run-not-found signal confirms completion"
}

test_parked_own_run_refuses_when_abort_is_unconfirmed() {
  local case_dir rc head pid
  case_dir=$(make_case parked-run-abort-unconfirmed)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown

  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_ABORT_NOOP=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-abort-unconfirmed: teardown should refuse"
  assert_grep "REFUSED: no-mistakes run for task-x1 is still parked after axi abort" "$case_dir/stderr" \
    "parked-run-abort-unconfirmed: teardown did not explain the parked-run refusal"
  assert_present "$case_dir/wt" \
    "parked-run-abort-unconfirmed: teardown removed the worktree after refusing"
  assert_present "$case_dir/state/task-x1.meta" \
    "parked-run-abort-unconfirmed: teardown removed task metadata after refusing"
  assert_absent "$case_dir/treehouse.log" \
    "parked-run-abort-unconfirmed: teardown returned the worktree after refusing"
  kill -0 "$pid" 2>/dev/null || fail "parked-run-abort-unconfirmed: process reap ran before refusal"
  kill -KILL "$pid" 2>/dev/null || true
  pass "teardown refuses before reap or removal when a task-owned run remains parked"
}

test_another_branchs_parked_run_is_never_touched() {
  local case_dir rc
  case_dir=$(make_case parked-run-not-ours)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  local rc=0
  # A parked run reported for a DIFFERENT branch - e.g. another crew's task
  # still validating on the shared gate - must never be aborted by this task's
  # teardown.
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/some-other-task deadbeef)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-ours: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-not-ours: teardown called axi abort for a run on another branch"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "parked-run-not-ours: teardown reported aborting a run it does not own"
  pass "a parked run on another branch is never aborted by this task's teardown (ownership is precise)"
}

# Fork issue #81's own sequence, from the teardown side. Task-x1 is parked and
# its record still names the pooled worktree path, but the pool has since handed
# that path to task-b, which created its own branch and started a run parked at a
# gate. Reading "this task's branch" out of the shared worktree would answer
# fm/task-b, match its head, and abort a DIFFERENT live task's pipeline.
test_reallocated_worktree_never_aborts_the_other_tasks_run() {
  local case_dir rc head
  case_dir=$(make_case parked-run-reallocated)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  git -C "$case_dir/wt" checkout -q -b fm/task-b
  wt_commit "$case_dir" "task-b work in the reallocated worktree"
  git -C "$case_dir/wt" push -q origin fm/task-b
  git -C "$case_dir/project" fetch -q origin
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-b "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-reallocated: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-reallocated: teardown aborted the run of the task now holding the worktree"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "parked-run-reallocated: teardown reported aborting another task's run"
  assert_grep "not this task's recorded fm/task-x1" "$case_dir/stderr" \
    "parked-run-reallocated: teardown did not say which run it refused to attribute"
  pass "a reallocated worktree's live run belongs to its new task and is never aborted"
}

# A record with no durable branch cannot show any run to be its own, so it must
# refuse attribution outright rather than fall through to the ambient branch -
# even when that branch's run looks like a perfect match.
test_legacy_record_without_branch_never_aborts_an_ambient_run() {
  local case_dir rc head
  case_dir=$(make_case parked-run-legacy-record)
  write_legacy_meta_without_branch "$case_dir" no-mistakes
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-legacy-record: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-legacy-record: teardown aborted a run it cannot prove is this task's"
  assert_grep "records no task branch" "$case_dir/stderr" \
    "parked-run-legacy-record: teardown did not surface the unattributable parked run"
  pass "a legacy record with no task branch refuses run attribution instead of using the ambient branch"
}

test_own_autonomous_run_is_left_alone() {
  local case_dir rc head
  case_dir=$(make_case autonomous-run-left-alone)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "autonomous-run-left-alone: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "autonomous-run-left-alone: teardown aborted a task-owned autonomous run"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "autonomous-run-left-alone: teardown reported aborting an autonomous run"
  pass "a task-owned autonomous running step is left alone rather than aborted"
}

test_leaked_worktree_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-process-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # A backgrounded, disowned process rooted (by cwd) under the task's own
  # worktree - the same shape the observed incident's leaked `go test`
  # binaries took (reparented to init, no live task meta to attribute them
  # to once an unpatched teardown had already run).
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-process-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-process-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-process-reap: leaked worktree process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-process-reap: teardown did not report reaping the leaked process"
  pass "a leaked descendant process rooted under the task's worktree is reaped by teardown, not left surviving"
}

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  ( cd "$case_dir/tasktmp" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

test_lsof_absent_reaps_tmux_process_group() {
  local case_dir rc pid path_without_lsof
  case_dir=$(make_case lsof-absent-process-group-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-process-group-reap: fixture path unexpectedly exposes lsof"

  perl -e 'setpgrp(0, 0); chdir shift or die; exec "sleep", "300"' "$case_dir/wt" &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-process-group-reap: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "lsof-absent-process-group-reap: teardown should succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "lsof-absent-process-group-reap: tmux process group survived teardown"
  fi
  assert_grep "reaping leaked worktree process group" "$case_dir/stderr" \
    "lsof-absent-process-group-reap: teardown did not use the process-group fallback"
  pass "missing lsof falls back to reaping the tmux pane process group"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep "REFUSED: cannot determine leaked processes under $case_dir/wt for task-x1 (lsof failed)" "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() {
  local case_dir rc pid
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  perl -e '$SIG{TERM} = "IGNORE"; sleep 300' &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$case_dir/lsof-count' ] || count=\$(cat '$case_dir/lsof-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$case_dir/lsof-count'
if [ "\$count" -le 3 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  if [ "$count" -le 2 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_REUSED_PID="$pid" FM_FAKE_PS_COUNT="$case_dir/ps-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  kill -KILL "$pid" 2>/dev/null || true
  pass "a reused pid with a different start time is never force-killed"
}

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  ( cd "$case_dir/wt" && exec perl -e '
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      open my $fh, ">", $done or die "open";
      close $fh;
      exec "perl", "-e", '\''$SIG{TERM} = "IGNORE"; sleep 300'\'';
    ' "$marker" "$done_flag" ) &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$FM_FAKE_EXEC_MARKER" ] || : > "$FM_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_FAKE_LSOF_COUNT" ] || count=$(cat "$FM_FAKE_LSOF_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_LSOF_COUNT"
if [ "$count" -eq 2 ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$FM_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_EXEC_PID="$pid" FM_FAKE_EXEC_MARKER="$marker" \
  FM_FAKE_EXEC_DONE="$done_flag" FM_FAKE_LSOF_COUNT="$case_dir/lsof-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  ( cd "$case_dir/wt" && exec perl -e '
      my $file = shift;
      $SIG{TERM} = sub {
        my $child = fork();
        die "fork" unless defined $child;
        if (!$child) { exec "sleep", "300"; }
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh;
        exit 0;
      };
      sleep 300;
    ' "$child_file" ) &
  pid=$!
  disown
  sleep 0.2

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc wt_path fake_pid=99999999
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_PERSISTENT_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  printf 'Tue Aug  4 10:00:00 2026\n'
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_PERSISTENT_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f "$case_dir/lsof-count" ] || count=\$(cat "$case_dir/lsof-count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/lsof-count"
if [ "\$count" -eq 1 ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXITED_PID:-}" ]; then
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'returned\n' > "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_EXITED_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_run_abort_precedes_process_reap_precedes_worktree_removal() {
  local case_dir rc head pid abort_log
  case_dir=$(make_case abort-then-reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  abort_log="$case_dir/nm-abort.log"

  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "abort-then-reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs, whether the run was already aborted and whether the
  # leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ -s "$abort_log" ]; then echo "abort-already-happened" >> "$case_dir/order.log"; fi
if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$abort_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "abort-then-reap-then-remove-order: teardown should still succeed"
  kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid" 2>/dev/null || true; }

  assert_present "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "abort-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the run was not yet aborted when the worktree return ran"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the run abort and the leaked-process reap both complete before the destructive worktree return"
}

test_local_only_fork_remote_allows
test_teardown_publishes_outcome_manifest_before_removing_records
test_design_teardown_publishes_manifest_and_removes_records
test_forced_teardown_records_a_discarded_outcome
test_teardown_refuses_when_the_manifest_cannot_be_published
test_terminal_model_verdict_blocks_cleanup_then_allows_match
test_never_started_and_clean_tears_down_without_force
test_fresh_store_and_clean_tears_down_without_force
test_uninspectable_evidence_store_still_refuses
test_non_directory_session_path_still_refuses
test_non_directory_session_parent_still_refuses
test_unreadable_session_parent_still_refuses
test_never_started_with_session_but_no_turn_tears_down
test_first_turn_before_final_recompute_refuses
test_unknown_liveness_completes_cleanup_and_retains_worktree
test_usage_session_map_reaches_the_manifest_before_cleanup_removes_it
test_cleanup_refreshes_usage_sessions_when_a_store_exists
test_completed_task_still_reports_its_tokens_after_cleanup
test_pre_guard_dispatch_tears_down_without_attributing_ambient_evidence
test_recorded_store_with_failed_verdict_still_refuses
test_arming_marker_without_store_still_refuses
test_recorded_store_with_malformed_timestamp_still_refuses
test_pre_guard_with_uncommitted_changes_still_refuses
test_pre_guard_with_unlanded_work_still_refuses
test_pre_guard_with_unpublishable_manifest_still_refuses
test_pre_guard_with_invalid_endpoint_still_refuses
test_ignored_content_refuses_while_allowlisted_harness_files_do_not
test_allowlisted_harness_files_still_tear_down
test_authoritative_dead_endpoint_recycles_worktree
test_authoritative_live_endpoint_refuses
test_recomputed_on_disk_proof_refuses_each_failed_condition
test_never_started_but_dirty_still_refuses
test_never_started_with_untracked_claude_file_still_refuses
test_never_started_but_committed_on_a_branch_still_refuses
test_never_started_with_detached_head_and_surviving_task_branch_still_refuses
test_ran_but_unverifiable_still_refuses_on_a_clean_worktree
test_forced_teardown_surfaces_mismatch_before_discarding
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_cleanup_never_deletes_the_worktrees_ambient_branch
test_no_mistakes_truly_unpushed_refuses
test_landed_work_is_evaluated_against_the_recorded_task_branch
test_legacy_record_without_branch_refuses_unpushed_work
test_legacy_record_without_branch_still_lands_on_its_recorded_pr
test_legacy_record_without_branch_still_lands_on_default_content
test_local_only_force_overrides_unpushed
test_teardown_missing_busy_sidecar_completes
test_herdr_teardown_clears_escalation_marker
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_forced_secondmate_herdr_child_preflight_refuses_before_changes
test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed
test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_merged_pr_with_pushed_later_commit_keeps_branch
test_forge_unreachable_keeps_branch_and_cleanup_succeeds
test_unsupported_forge_keeps_branch_and_cleanup_succeeds
test_merged_pr_head_not_retained_by_forge_keeps_branch
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_gh_error_and_content_absent_refuses
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_parked_own_run_is_aborted_before_teardown
test_parked_own_run_refuses_when_abort_is_unconfirmed
test_mismatched_run_after_abort_refuses_unconfirmed
test_empty_status_after_abort_refuses_unconfirmed
test_not_found_status_after_abort_confirms_completion
test_another_branchs_parked_run_is_never_touched
test_reallocated_worktree_never_aborts_the_other_tasks_run
test_legacy_record_without_branch_never_aborts_an_ambient_run
test_own_autonomous_run_is_left_alone
test_leaked_worktree_process_is_reaped
test_leaked_tasktmp_process_is_reaped
test_lsof_absent_reaps_tmux_process_group
test_lsof_error_refuses_before_removal
test_reused_pid_identity_is_not_force_killed
test_exec_changed_process_is_still_reaped
test_process_spawned_during_grace_is_reaped_on_later_pass
test_persistent_scan_refuses_after_bounded_retries
test_process_exit_during_identity_lookup_does_not_refuse
test_run_abort_precedes_process_reap_precedes_worktree_removal
printf '\nall fm-teardown tests passed\n'
