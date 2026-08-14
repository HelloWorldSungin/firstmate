#!/usr/bin/env bash
# Behavior tests for read-only upstream drift reporting and bootstrap wiring.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATUS="$ROOT/bin/fm-upstream-status.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-status-tests)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_fixture() {  # <name> -> prints <fork-work>|<upstream-work>
  local name=$1 dir upstream_work upstream_bare origin_bare fork_work
  dir="$TMP_ROOT/$name"
  upstream_work="$dir/upstream-work"
  upstream_bare="$dir/kunchenguid/firstmate.git"
  origin_bare="$dir/HelloWorldSungin/firstmate.git"
  fork_work="$dir/fork-work"
  mkdir -p "$dir/kunchenguid" "$dir/HelloWorldSungin"
  git init -q -b main "$upstream_work"
  git -C "$upstream_work" config user.name fmtest
  git -C "$upstream_work" config user.email fmtest@example.invalid
  printf '%s\n' base > "$upstream_work/base.txt"
  git -C "$upstream_work" add base.txt
  git -C "$upstream_work" commit -qm 'base'
  git clone -q --bare "$upstream_work" "$upstream_bare"
  git clone -q --bare "$upstream_work" "$origin_bare"
  git clone -q "$origin_bare" "$fork_work"
  git -C "$fork_work" config user.name fmtest
  git -C "$fork_work" config user.email fmtest@example.invalid
  git -C "$fork_work" remote add upstream "$upstream_bare"
  printf '%s\n' fork > "$fork_work/fork.txt"
  git -C "$fork_work" add fork.txt
  git -C "$fork_work" commit -qm 'fork change'
  git -C "$fork_work" push -q origin main
  git -C "$upstream_work" remote add publish "$upstream_bare"
  printf '%s|%s\n' "$fork_work" "$upstream_work"
}

add_upstream_change() {  # <work> <path> <subject> <content>
  local work=$1 path=$2 subject=$3 content=$4 parent
  parent=${path%/*}
  [ "$parent" = "$path" ] || mkdir -p "$work/$parent"
  printf '%s\n' "$content" > "$work/$path"
  git -C "$work" add "$path"
  git -C "$work" commit -qm "$subject"
  git -C "$work" push -q publish main
}

run_status() {  # <fork> [args...]
  local fork=$1
  shift
  FM_ROOT_OVERRIDE="$fork" FM_UPSTREAM_STATUS_TIMEOUT=10 "$STATUS" "$@"
}

make_stalling_git() {  # <directory>
  local directory=$1
  mkdir -p "$directory"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case " $* " in' \
    '  *" diff-tree "*) sleep "${FM_TEST_GIT_STALL:-5}" ;;' \
    'esac' \
    'exec "$FM_TEST_REAL_GIT" "$@"' \
    > "$directory/git"
  chmod +x "$directory/git"
}

test_absent_remote_is_inert() {
  local fixture fork upstream out
  fixture=$(make_fixture absent)
  fork=${fixture%%|*}
  upstream=${fixture#*|}
  git -C "$fork" remote remove upstream
  out=$(run_status "$fork")
  [ -z "$out" ] || fail "absent upstream remote should be silent, got: $out"
  pass "upstream status is inert without an upstream remote"
}

test_reports_drift_without_mutating_source_repo() {
  local fixture fork upstream out refs_before refs_after status_before status_after objects_before objects_after
  fixture=$(make_fixture basic)
  fork=${fixture%%|*}
  upstream=${fixture#*|}
  add_upstream_change "$upstream" docs/one.md 'docs: first change (#101)' one
  add_upstream_change "$upstream" tests/two.test.sh 'test: second change (#102)' two
  add_upstream_change "$upstream" fork.txt 'feat: overlap with the fork (#103)' upstream

  refs_before=$(git -C "$fork" for-each-ref --format='%(refname) %(objectname)')
  status_before=$(git -C "$fork" status --porcelain=v1)
  objects_before=$(git -C "$fork" count-objects -v)
  out=$(run_status "$fork" --details)
  refs_after=$(git -C "$fork" for-each-ref --format='%(refname) %(objectname)')
  status_after=$(git -C "$fork" status --porcelain=v1)
  objects_after=$(git -C "$fork" count-objects -v)

  assert_contains "$out" \
    'UPSTREAM: behind kunchenguid/firstmate by 3 merged changes (0 touch bin/, 0 touch AGENTS.md/skills;' \
    "summary should name the fully qualified upstream and count"
  assert_contains "$out" 'sync trigger not crossed' "small non-instruction drift should remain below the trigger"
  assert_contains "$out" 'UPSTREAM_TARGET: kunchenguid/firstmate@' "details should pin the measured target"
  assert_contains "$out" 'UPSTREAM_CHANGES: docs/' "details should group documentation changes"
  assert_contains "$out" '- kunchenguid/firstmate#101 docs: first change [' \
    "details should use a full owner/repo PR reference"
  assert_contains "$out" 'UPSTREAM_CHANGES: tests/' "details should group test changes"
  assert_contains "$out" 'UPSTREAM_OVERLAP: 1 paths changed on both sides of the merge base' \
    "details should report collision-risk overlap"
  assert_contains "$out" '- fork.txt' "details should name every overlap path"
  [ "$refs_before" = "$refs_after" ] || fail "status changed a source repository ref"
  [ "$status_before" = "$status_after" ] || fail "status changed the source worktree"
  [ "$objects_before" = "$objects_after" ] || fail "status fetched objects into the source repository"
  pass "upstream status reports grouped drift through a disposable object store"
}

test_instruction_surface_crosses_trigger() {
  local fixture fork upstream out
  fixture=$(make_fixture instruction)
  fork=${fixture%%|*}
  upstream=${fixture#*|}
  add_upstream_change "$upstream" bin/new-tool.sh 'feat: change runtime instructions (#201)' tool
  out=$(run_status "$fork")
  assert_contains "$out" '1 touch bin/, 0 touch AGENTS.md/skills' \
    "summary should count bin changes on the instruction surface"
  assert_contains "$out" 'sync trigger crossed: instruction-surface change' \
    "one instruction-surface change should cross the standing trigger"
  pass "instruction-surface drift crosses the sync trigger"
}

test_pending_count_crosses_trigger() {
  local fixture fork upstream out i
  fixture=$(make_fixture threshold)
  fork=${fixture%%|*}
  upstream=${fixture#*|}
  i=1
  while [ "$i" -le 15 ]; do
    add_upstream_change "$upstream" "misc-$i.txt" "change $i (#$((300 + i)))" "$i"
    i=$((i + 1))
  done
  out=$(run_status "$fork")
  assert_contains "$out" 'behind kunchenguid/firstmate by 15 merged changes' \
    "summary should count first-parent pending changes"
  assert_contains "$out" 'sync trigger crossed: at least 15 pending changes' \
    "the standing pending-count threshold should cross at 15"
  pass "pending change volume crosses the sync trigger"
}

test_current_fork_is_silent() {
  local fixture fork upstream out
  fixture=$(make_fixture current)
  fork=${fixture%%|*}
  upstream=${fixture#*|}
  add_upstream_change "$upstream" docs/current.md 'docs: current change (#401)' current
  git -C "$fork" fetch -q upstream
  git -C "$fork" merge -q --no-edit upstream/main
  git -C "$fork" push -q origin main
  out=$(run_status "$fork")
  [ -z "$out" ] || fail "fork containing upstream should be silent, got: $out"
  pass "upstream status stays silent when the fork contains upstream HEAD"
}

test_remote_fork_head_overrides_stale_tracking_ref() {
  local fixture fork upstream publisher origin_url upstream_url local_oid remote_oid out
  fixture=$(make_fixture stale-fork)
  fork=${fixture%%|*}
  upstream=${fixture#*|}
  add_upstream_change "$upstream" docs/landed.md 'docs: landed upstream change (#402)' landed

  origin_url=$(git -C "$fork" remote get-url origin)
  upstream_url=$(git -C "$fork" remote get-url upstream)
  publisher="$TMP_ROOT/stale-fork/publisher"
  git clone -q "$origin_url" "$publisher"
  git -C "$publisher" config user.name fmtest
  git -C "$publisher" config user.email fmtest@example.invalid
  git -C "$publisher" remote add upstream "$upstream_url"
  git -C "$publisher" fetch -q upstream
  git -C "$publisher" merge -q --no-edit upstream/main
  git -C "$publisher" push -q origin main

  local_oid=$(git -C "$fork" rev-parse refs/remotes/origin/main)
  remote_oid=$(git ls-remote "$origin_url" HEAD | awk '{print $1}')
  [ "$local_oid" != "$remote_oid" ] || fail "fixture should leave the local fork tracking ref stale"
  out=$(run_status "$fork")
  [ -z "$out" ] || fail "current remote fork head should make landed drift silent, got: $out"
  pass "upstream status measures the current remote fork default branch"
}

test_default_is_aggregate_and_details_share_total_deadline() {
  local fixture fork upstream shim real_git out rc started elapsed
  fixture=$(make_fixture bounded)
  fork=${fixture%%|*}
  upstream=${fixture#*|}
  add_upstream_change "$upstream" docs/bounded.md 'docs: bounded change (#403)' bounded
  shim="$TMP_ROOT/bounded/git-shim"
  real_git=$(command -v git)
  make_stalling_git "$shim"

  out=$(PATH="$shim:$PATH" FM_TEST_REAL_GIT="$real_git" FM_TEST_GIT_STALL=6 \
    FM_ROOT_OVERRIDE="$fork" FM_UPSTREAM_STATUS_TIMEOUT=2 "$STATUS")
  assert_contains "$out" 'UPSTREAM: behind kunchenguid/firstmate by 1 merged changes' \
    "default reporting should not enumerate detailed commit records"

  started=$SECONDS
  set +e
  out=$(PATH="$shim:$PATH" FM_TEST_REAL_GIT="$real_git" FM_TEST_GIT_STALL=6 \
    FM_ROOT_OVERRIDE="$fork" FM_UPSTREAM_STATUS_TIMEOUT=2 "$STATUS" --details 2>/dev/null)
  rc=$?
  set -e
  elapsed=$((SECONDS - started))
  [ "$rc" -ne 0 ] || fail "stalled detail enumeration should return nonzero"
  [ "$elapsed" -lt 5 ] || fail "the total measurement deadline took ${elapsed}s"
  assert_contains "$out" 'UPSTREAM: unable to measure upstream - timed out after 2s' \
    "the total deadline should bound post-fetch detail enumeration"
  pass "default reporting avoids enumeration and all detail work stays bounded"
}

test_fetch_failure_is_actionable() {
  local fixture fork upstream out rc
  fixture=$(make_fixture failure)
  fork=${fixture%%|*}
  upstream=${fixture#*|}
  git -C "$fork" remote set-url upstream "$TMP_ROOT/failure/missing.git"
  set +e
  out=$(run_status "$fork" 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unreachable upstream should return nonzero"
  assert_contains "$out" 'UPSTREAM: unable to measure failure/missing - upstream fetch failed with exit' \
    "fetch failure should be visible on the diagnostic prefix"
  pass "upstream status reports an upstream it cannot measure"
}

test_bootstrap_relays_upstream_in_normal_and_detect_only_modes() {
  local fixture fork upstream home out mode
  fixture=$(make_fixture bootstrap)
  fork=${fixture%%|*}
  upstream=${fixture#*|}
  add_upstream_change "$upstream" .agents/skills/example/SKILL.md \
    'feat: change agent instructions (#501)' instructions
  home="$TMP_ROOT/bootstrap-home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  for mode in 0 1; do
    out=$(FM_ROOT_OVERRIDE="$fork" FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY="$mode" \
      FM_UPSTREAM_STATUS_TIMEOUT=10 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null || true)
    assert_contains "$out" 'UPSTREAM: behind kunchenguid/firstmate by 1 merged changes' \
      "bootstrap detect-only=$mode should relay upstream drift"
    assert_contains "$out" 'sync trigger crossed: instruction-surface change' \
      "bootstrap detect-only=$mode should relay the trigger verdict"
  done
  pass "bootstrap relays upstream drift in normal and detect-only sessions"
}

test_absent_remote_is_inert
test_reports_drift_without_mutating_source_repo
test_instruction_surface_crosses_trigger
test_pending_count_crosses_trigger
test_current_fork_is_silent
test_remote_fork_head_overrides_stale_tracking_ref
test_default_is_aggregate_and_details_share_total_deadline
test_fetch_failure_is_actionable
test_bootstrap_relays_upstream_in_normal_and_detect_only_modes
printf '\nall fm-upstream-status tests passed\n'
