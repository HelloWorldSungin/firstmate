#!/usr/bin/env bash
# Contract tests for the crew-only, herdr-only cursor/agy adapters at the spawn
# and teardown boundaries:
#   - fm-spawn refuses cursor/agy as a secondmate launcher (crew-only), and
#   - refuses them on any non-herdr backend (herdr-only), both BEFORE any backend
#     or worktree work, and
#   - fm-teardown drops an agy task's global workspace-trust entry (and never
#     touches the shared settings file for a non-agy task).
# The end-to-end launch + native-detection path is covered live in
# tests/fm-cursor-agy-smoke.test.sh; here everything is deterministic with fakes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-agy-adapter)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = return ]; then
  [ -z "${FM_TEST_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_TREEHOUSE_LOG"
  if [ -n "${FM_TEST_AGY_TRUST_ABSENT_PATH:-}" ]; then
    jq -e --arg path "$FM_TEST_AGY_TRUST_ABSENT_PATH" \
      '.trustedWorkspaces | index($path) == null' \
      "${FM_TEST_AGY_SETTINGS:?}" >/dev/null || exit 93
  fi
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" herdr gh-axi gh
  printf '%s\n' "$fakebin"
}

# --- spawn refusals ----------------------------------------------------------

run_spawn() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$home/wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

setup_home() {  # <name> <id> -> prints "home|proj|fakebin"
  local name=$1 id=$2 case_dir home proj fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_init_commit "$proj"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s\n' "$home" "$proj" "$fakebin"
}

test_crew_only_refuses_secondmate() {
  local harness=$1 id home proj fakebin out status
  id="crew-$harness-z1"
  IFS='|' read -r home proj fakebin <<EOF
$(setup_home "crew-$harness" "$id")
EOF
  # The home arg need not be a valid secondmate home: the crew-only guard fires
  # before any home validation.
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" --secondmate --harness "$harness")
  status=$?
  expect_code 1 "$status" "$harness --secondmate spawn should be refused"
  assert_contains "$out" "crew-only" "$harness secondmate refusal should say crew-only"
  assert_absent "$home/state/$id.meta" "crew-only refusal must happen before meta is written"
  pass "$harness is refused as a secondmate launcher (crew-only)"
}

test_herdr_only_refuses_non_herdr_backend() {
  local harness=$1 id home proj fakebin out status
  id="herdr-$harness-z2"
  IFS='|' read -r home proj fakebin <<EOF
$(setup_home "herdr-$harness" "$id")
EOF
  # TMUX is set, so the backend resolves to tmux; the herdr-only guard must refuse.
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off "$harness")
  status=$?
  expect_code 1 "$status" "$harness spawn on the tmux backend should be refused"
  assert_contains "$out" "only on the herdr backend" "$harness refusal should say herdr-only"
  assert_absent "$home/state/$id.meta" "herdr-only refusal must happen before meta is written"
  pass "$harness is refused on a non-herdr backend (herdr-only)"
}

test_raw_command_bypass_refused() {
  # B1: the raw launch-command escape hatch must not slip a cursor/agy launch past
  # the crew-only/herdr-only gates. A raw command that RESOLVES to cursor-agent or
  # agy - directly, via env, or behind assignment prefixes - is refused outright,
  # on every dimension (the raw hatch cannot provide the trust seed / native
  # supervision cursor/agy need). Each variant is tried on a forbidden dimension.
  local variant extra want id home proj fakebin out status ship_flags n=0
  # <raw command>|<extra spawn args>|<expected-restricted-harness>
  while IFS='|' read -r variant extra want; do
    [ -n "$variant" ] || continue
    n=$((n + 1))
    id="rawbypass-$n"
    IFS='|' read -r home proj fakebin <<EOF
$(setup_home "rawbypass-$n" "$id")
EOF
    # Ship spawns must name --mode and --yolo; a --secondmate row must not, because
    # a secondmate records its own fixed posture and refuses both flags.
    if [ -n "$extra" ]; then
      ship_flags=
    else
      ship_flags="--mode no-mistakes --yolo off"
    fi
    # shellcheck disable=SC2086  # $extra and $ship_flags are intentional argument lists (may be empty)
    out=$(run_spawn "$home" "$fakebin" "$id" "$proj" $ship_flags $extra "$variant")
    status=$?
    expect_code 1 "$status" "raw command '$variant' ($extra) must be refused"
    if [ "$want" = unresolved ]; then
      assert_contains "$out" "uses shell expansion or command substitution" \
        "raw '$variant' should be refused as unverifiable shell indirection"
    else
      assert_contains "$out" "cannot be launched through the raw command escape hatch" \
        "raw '$variant' refusal should explain the escape-hatch block"
      assert_contains "$out" "harness '$want'" "raw '$variant' should be classified as $want"
    fi
    assert_absent "$home/state/$id.meta" "raw bypass refusal must happen before meta is written"
  done <<'ROWS'
cursor-agent --trust --force|--secondmate|cursor
agy --dangerously-skip-permissions|--secondmate|agy
env agy --dangerously-skip-permissions|--secondmate|agy
FOO=1 cursor-agent --force|--secondmate|cursor
FOO=1 BAR=2 agy -p hi||agy
env -u HOME cursor-agent --force||cursor
bash -lc 'agy --dangerously-skip-permissions'||agy
bash -lc 'cursor-agent --trust --force'||cursor
sh -c "agy -p hi"|--secondmate|agy
env bash -lc 'cursor-agent'||cursor
AGY=agy bash -lc '$AGY --dangerously-skip-permissions'||unresolved
CUR=cursor-agent bash -lc '$CUR --trust --force'|--secondmate|unresolved
bash -lc 'x=agy; eval "$x --dangerously-skip-permissions"'||unresolved
bash -lc 'a=a; g=gy; $a$g --x'||unresolved
ROWS
  pass "raw launch commands resolving to cursor-agent/agy are refused (direct, env, assignment, wrapper, and variable indirection)"
}

# --- exec-time raw guard installed by a real raw spawn ----------------------

# A fake tmux that records every send-keys payload to $FM_FAKE_SEND_LOG, so the
# test can see the PATH export fm-spawn sends before a raw launch, and lets a full
# spawn succeed (pane path = the settled worktree).
make_logging_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys) [ -z "${FM_FAKE_SEND_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_SEND_LOG"; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

test_raw_spawn_installs_exec_time_guard() {
  # The robust B1 defense is installed by a REAL raw spawn: a raw command that the
  # string classifier does NOT catch (quote-concat `ag"y"`) still gets the
  # exec-time cursor/agy PATH shim written and prepended to the pane PATH, so the
  # binary can never resolve to the real CLI regardless of shell spelling.
  local case_dir home proj wt fakebin sendlog id out status guard
  case_dir="$TMP_ROOT/raw-guard-install"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  sendlog="$case_dir/send.log"
  fakebin=$(make_logging_fakebin "$case_dir/fake")
  id=rawguard-install-z1
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"

  : > "$sendlog"
  # A quote-concat agy spelling: the classifier returns empty (harness=bash), so
  # the spawn proceeds - and must still install the exec-time guard.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_SEND_LOG="$sendlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 'bash -c '\''ag"y" --dangerously-skip-permissions'\''' 2>&1)
  status=$?
  expect_code 0 "$status" "the quote-concat raw spawn should proceed (classifier does not catch it): $out"
  assert_contains "$out" "spawned $id harness=bash" "raw spawn did not launch as harness=bash"

  guard="/tmp/fm-$id/raw-guard"
  assert_present "$guard/agy" "raw spawn did not install the agy exec-time guard shim"
  assert_present "$guard/cursor-agent" "raw spawn did not install the cursor-agent guard shim"
  assert_present "$guard/cursor" "raw spawn did not install the cursor guard shim"
  [ -x "$guard/agy" ] || fail "installed agy guard shim is not executable"
  # The refusing shim, when run, must block and exit non-zero.
  "$guard/agy" >/dev/null 2>&1 && fail "the installed agy guard shim did not refuse"
  # fm-spawn must have prepended the guard dir to the pane PATH before the launch.
  assert_grep "export PATH='$guard'" "$sendlog" "fm-spawn did not prepend the raw-guard dir to the pane PATH"
  rm -rf "/tmp/fm-$id"
  pass "a real raw spawn installs the exec-time cursor/agy guard and prepends it to the pane PATH"
}

# --- teardown workspace-trust cleanup ---------------------------------------

run_teardown() {  # <home> <fakebin> <settings> <id>
  local home=$1 fakebin=$2 settings=$3 id=$4
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_AGY_SETTINGS_OVERRIDE="$settings" FM_TEST_AGY_SETTINGS="$settings" \
    FM_TEST_TREEHOUSE_LOG="${FM_TEST_TREEHOUSE_LOG:-}" \
    FM_TEST_AGY_TRUST_ABSENT_PATH="${FM_TEST_AGY_TRUST_ABSENT_PATH:-}" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1
}

# setup_teardown_case <name> <id> <harness> <owned:yes|no> -> "home|wt|fakebin|settings"
# When owned=yes it writes the ownership marker state/<id>.agy-trust (as fm-spawn
# does only when firstmate actually CREATED the trust entry); owned=no models a
# path the captain had already trusted (no marker).
setup_teardown_case() {
  local name=$1 id=$2 harness=$3 owned=${4:-no} case_dir home proj wt fakebin settings
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  settings="$case_dir/agy-settings.json"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=$harness" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off" \
    "tasktmp="
  [ "$owned" = yes ] && printf '%s' "$wt" > "$home/state/$id.agy-trust"
  printf '{"trustedWorkspaces":["/home/cap","%s"]}' "$wt" > "$settings"
  printf '%s|%s|%s|%s\n' "$home" "$wt" "$fakebin" "$settings"
}

test_teardown_removes_owned_agy_trust() {
  local id home wt fakebin settings out order_log
  id=agy-teardown-z3
  IFS='|' read -r home wt fakebin settings <<EOF
$(setup_teardown_case agy-teardown "$id" agy yes)
EOF
  order_log="$home/treehouse-order.log"
  out=$(FM_TEST_TREEHOUSE_LOG="$order_log" FM_TEST_AGY_TRUST_ABSENT_PATH="$wt" \
    run_teardown "$home" "$fakebin" "$settings" "$id") \
    || fail "agy teardown failed"$'\n'"$out"
  [ "$(jq -c '.trustedWorkspaces' "$settings")" = '["/home/cap"]' ] \
    || fail "agy teardown did not drop the firstmate-owned worktree path (got $(jq -c '.trustedWorkspaces' "$settings"))"
  assert_absent "$home/state/$id.agy-trust" "teardown should remove the ownership marker after a successful trust removal"
  assert_absent "$home/state/$id.meta" "teardown should remove the task meta"
  assert_present "$order_log" "teardown did not return the worktree after removing owned trust"
  pass "agy teardown removes firstmate-owned trust before returning the worktree lease"
}

test_teardown_preserves_unowned_agy_trust() {
  # No ownership marker: the captain had already trusted this exact path. Teardown
  # must leave it (and the whole settings file) untouched.
  local id home wt fakebin settings before out
  id=agy-unowned-z5
  IFS='|' read -r home wt fakebin settings <<EOF
$(setup_teardown_case agy-unowned "$id" agy no)
EOF
  before=$(cat "$settings")
  out=$(run_teardown "$home" "$fakebin" "$settings" "$id") \
    || fail "agy teardown (unowned) failed"$'\n'"$out"
  [ "$(cat "$settings")" = "$before" ] \
    || fail "teardown removed a captain-owned (unmarked) agy trust entry"
  pass "agy teardown leaves a captain-owned (unmarked) trust entry untouched"
}

test_teardown_incomplete_on_removal_failure() {
  # A malformed settings file makes removal fail. Teardown must treat that as an
  # INCOMPLETE teardown: non-zero exit, and the metadata + ownership marker
  # retained so a rerun retries deterministically.
  local id home wt fakebin settings out status order_log
  id=agy-incomplete-z6
  IFS='|' read -r home wt fakebin settings <<EOF
$(setup_teardown_case agy-incomplete "$id" agy yes)
EOF
  printf 'NOT VALID JSON {' > "$settings"
  order_log="$home/treehouse-order.log"
  out=$(FM_TEST_TREEHOUSE_LOG="$order_log" run_teardown "$home" "$fakebin" "$settings" "$id")
  status=$?
  expect_code 1 "$status" "teardown must fail when the owned trust entry cannot be removed"
  assert_contains "$out" "teardown incomplete" "teardown should report an incomplete teardown"
  assert_present "$home/state/$id.meta" "an incomplete teardown must retain task metadata for retry"
  assert_present "$home/state/$id.agy-trust" "an incomplete teardown must retain the ownership marker for retry"
  assert_absent "$order_log" "teardown must not return the worktree when owned trust removal fails"
  pass "owned trust removal failure retains retry evidence and the worktree lease"
}

test_forced_secondmate_child_trust_failure_prevents_release() {
  local case_dir home parent_home parent_proj child_proj child_wt fakebin settings
  local parent_id child_id order_log out status
  case_dir="$TMP_ROOT/secondmate-child-trust-failure"
  home="$case_dir/home"
  parent_home="$case_dir/secondmate-home"
  parent_proj="$case_dir/parent-project"
  child_proj="$case_dir/child-project"
  child_wt="$case_dir/child-worktree"
  parent_id=secondmate-parent-z7
  child_id=agy-child-z8
  fakebin=$(make_fakebin "$case_dir/fake")
  settings="$case_dir/agy-settings.json"
  order_log="$case_dir/treehouse-order.log"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  mkdir -p "$parent_home/state" "$parent_home/data" "$parent_home/projects" "$parent_home/config"
  printf '%s' "$parent_id" > "$parent_home/.fm-secondmate-home"
  fm_git_init_commit "$parent_proj"
  fm_git_worktree "$child_proj" "$child_wt" "fm/$child_id"
  fm_write_meta "$home/state/$parent_id.meta" \
    "window=firstmate:fm-$parent_id" \
    "worktree=$parent_home" \
    "project=$parent_proj" \
    "home=$parent_home" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=local-only" \
    "yolo=off" \
    "tasktmp="
  # The child is recorded on tmux, not herdr. What this case exercises is
  # cleanup_firstmate_home_children refusing when a child's firstmate-owned agy
  # trust cannot be removed, which runs before any backend-specific work and is
  # backend-independent. A herdr child would additionally have to clear
  # teardown_herdr_preflight_target, which needs real structured pane inspection
  # from a live herdr; faking that protocol here would prove nothing about trust
  # cleanup. Real herdr endpoint behaviour is covered by the real-herdr-gated lane.
  fm_write_meta "$parent_home/state/$child_id.meta" \
    "window=firstmate:fm-$child_id" \
    "endpoint_task_id=$child_id" \
    "worktree=$child_wt" \
    "project=$child_proj" \
    "backend=tmux" \
    "harness=agy" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off" \
    "tasktmp="
  printf '%s' "$child_wt" > "$parent_home/state/$child_id.agy-trust"
  printf 'NOT VALID JSON {' > "$settings"

  out=$(FM_TEST_TREEHOUSE_LOG="$order_log" run_teardown "$home" "$fakebin" "$settings" "$parent_id")
  status=$?
  expect_code 1 "$status" "forced secondmate teardown must fail when child owned trust cannot be removed"
  assert_contains "$out" "secondmate child $child_id" "forced child trust failure should identify the child"
  assert_absent "$order_log" "forced child cleanup must not return the child worktree after trust removal failure"
  assert_present "$parent_home/state/$child_id.agy-trust" "forced child cleanup must retain the ownership marker"
  assert_present "$parent_home/state/$child_id.meta" "forced child cleanup must retain child metadata"
  assert_present "$home/state/$parent_id.meta" "forced child cleanup failure must retain parent metadata"
  assert_present "$parent_home" "forced child cleanup failure must retain the secondmate home"
  pass "forced secondmate child cleanup removes trust before release and fails closed"
}

test_teardown_leaves_trust_for_non_agy() {
  local id home wt fakebin settings before out
  id=claude-teardown-z4
  IFS='|' read -r home wt fakebin settings <<EOF
$(setup_teardown_case claude-teardown "$id" claude no)
EOF
  before=$(cat "$settings")
  out=$(run_teardown "$home" "$fakebin" "$settings" "$id") \
    || fail "claude teardown failed"$'\n'"$out"
  [ "$(cat "$settings")" = "$before" ] \
    || fail "a non-agy teardown must not touch the shared agy settings file"
  pass "a non-agy teardown leaves the agy workspace-trust file untouched"
}

# --- send and crew-state signals for cursor and agy --------------------------

make_herdr_signal_fakebin() {  # <dir> <agent-status-sequence...> -> fakebin dir
  local dir=$1 fakebin seq_file
  shift
  fakebin=$(fm_fakebin "$dir")
  seq_file="$dir/agent_get_seq"
  rm -f "$seq_file"
  for st in "$@"; do
    printf '%s\n' "$st" >> "$seq_file"
  done
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
cmd=""
for a in "$@"; do
  case "$a" in
    status|pane|agent|get|read|capture|send-keys|send-text) cmd="$cmd $a" ;;
  esac
done
dir=$(dirname "$0")/..
seq_file="$dir/agent_get_seq"
counter_file="$dir/agent_get_counter"
case "$cmd" in
  *"status"*) printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  *"pane get"*) printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n' ;;
  *"pane send-keys"*)
    printf 'enter\n' >> "$dir/enter_log"
    [ "${FM_HERDR_FAKE_ENTER:-ok}" != fail ] || exit 1
    exit 0
    ;;
  *"pane send-text"*) exit 0 ;;
  *"pane read"*|*"pane capture"*)
    if [ -n "${FM_HERDR_FAKE_COMPOSER:-}" ]; then
      printf '%s\n' "${FM_HERDR_FAKE_COMPOSER}"
    else
      printf '$ \n'
    fi
    ;;
  *"agent get"*)
    cnt=$(cat "$counter_file" 2>/dev/null || echo 0)
    cnt=$((cnt + 1))
    echo "$cnt" > "$counter_file"
    st=""
    if [ -f "$seq_file" ]; then
      st=$(sed -n "${cnt}p" "$seq_file")
    fi
    st=${st:-idle}
    printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' "${FM_HERDR_FAKE_AGENT:-claude_code}" "$st"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" gh-axi gh treehouse
  printf '%s\n' "$fakebin"
}

test_send_text_submit_lands_on_cursor_and_agy() {
  local harness=$1 case_dir home proj wt fakebin err rc
  # Counterfactual: If send_text_submit could not prove a new turn after a
  # settled idle-to-working transition, this test would fail.
  case_dir="$TMP_ROOT/send-land-$harness"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; err="$case_dir/send.err"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/lane-$harness"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/lane-$harness.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj"
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "working" "idle" "idle" "working")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_RETRIES=2 FM_SEND_SETTLE=0 \
    FM_HERDR_FAKE_AGENT="$harness" \
    "$ROOT/bin/fm-send.sh" "fm-lane-$harness" "steer message" >/dev/null 2>"$err"
  rc=$?
  expect_code 0 "$rc" "ordinary steer to live $harness worker should succeed when native turn starts"
  assert_no_grep "error:" "$err" "successful steer to live $harness worker should produce no error diagnostic"
  pass "ordinary steer to a live $harness worker that lands does not report failure"
}

test_transient_idle_does_not_confirm_cursor_and_agy_send() {
  local harness=$1 case_dir home proj wt fakebin err rc
  case_dir="$TMP_ROOT/send-idle-blip-$harness"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; err="$case_dir/send.err"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/lane-$harness"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/lane-$harness.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj"
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "working" "idle" "working")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_RETRIES=2 FM_SEND_SETTLE=0 \
    FM_HERDR_FAKE_AGENT="$harness" \
    "$ROOT/bin/fm-send.sh" "fm-lane-$harness" "steer message" >/dev/null 2>"$err"
  rc=$?
  expect_code 3 "$rc" "transient idle on $harness should be unverifiable"
  assert_absent "$case_dir/fake/enter_log" \
    "transient idle on $harness must not trigger an attributable Enter"
  pass "a transient idle never confirms a $harness steer"
}

test_unchanged_working_does_not_confirm_cursor_and_agy_send() {
  local harness=$1 case_dir home proj wt fakebin err rc
  case_dir="$TMP_ROOT/send-unchanged-$harness"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; err="$case_dir/send.err"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/lane-$harness"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/lane-$harness.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj"
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "working" "working" "working")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_RETRIES=2 FM_SEND_SETTLE=0 \
    FM_HERDR_FAKE_AGENT="$harness" \
    "$ROOT/bin/fm-send.sh" "fm-lane-$harness" "steer message" >/dev/null 2>"$err"
  rc=$?
  expect_code 3 "$rc" "unchanged working on $harness should be unverifiable"
  assert_contains "$(cat "$err")" "verdict=unverifiable" \
    "unchanged pre-existing work on $harness must not confirm this Enter"
  pass "unchanged pre-existing work never confirms a $harness steer"
}

test_failed_enter_reports_cursor_and_agy_send_failure() {
  local harness=$1 case_dir home proj wt fakebin err rc
  case_dir="$TMP_ROOT/send-enter-fail-$harness"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; err="$case_dir/send.err"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/lane-$harness"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/lane-$harness.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj"
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "idle" "idle")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_RETRIES=2 FM_SEND_SETTLE=0 \
    FM_HERDR_FAKE_AGENT="$harness" FM_HERDR_FAKE_ENTER=fail \
    "$ROOT/bin/fm-send.sh" "fm-lane-$harness" "steer message" >/dev/null 2>"$err"
  rc=$?
  expect_code 1 "$rc" "failed Enter on $harness should report delivery failure"
  assert_contains "$(cat "$err")" "send failed" \
    "failed Enter on $harness should surface a send failure"
  pass "a failed Enter reports a $harness steer as undelivered"
}

test_unreadable_after_enter_does_not_retry_cursor_and_agy_send() {
  local harness=$1 case_dir home proj wt fakebin err rc
  case_dir="$TMP_ROOT/send-unreadable-$harness"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; err="$case_dir/send.err"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/lane-$harness"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/lane-$harness.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj"
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "idle" "idle" "unknown" "unknown")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_RETRIES=2 \
    FM_BACKEND_HERDR_SUBMIT_POLLS=2 FM_SEND_SETTLE=0 FM_HERDR_FAKE_AGENT="$harness" \
    "$ROOT/bin/fm-send.sh" "fm-lane-$harness" "steer message" >/dev/null 2>"$err"
  rc=$?
  expect_code 3 "$rc" "lost visibility after Enter on $harness should be unverifiable"
  [ "$(wc -l < "$case_dir/fake/enter_log")" -eq 1 ] \
    || fail "lost visibility after Enter on $harness sent another Enter"
  pass "lost visibility stops $harness Enter retries"
}

test_genuinely_undelivered_steer_on_composer_supported_harness() {
  local case_dir home proj wt fakebin err rc
  # Counterfactual: If a swallowed steer on a composer-supported harness was falsely
  # confirmed as delivered, this test would fail.
  case_dir="$TMP_ROOT/send-undelivered-claude"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; err="$case_dir/send.err"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/lane-claude"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/lane-claude.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj"
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "idle" "idle" "idle")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    FM_HERDR_FAKE_AGENT="claude_code" FM_HERDR_FAKE_COMPOSER='│ › unsubmitted text │' \
    "$ROOT/bin/fm-send.sh" "fm-lane-claude" "steer message" >/dev/null 2>"$err"
  rc=$?
  expect_code 1 "$rc" "genuinely undelivered steer on claude should report failure"
  assert_contains "$(cat "$err")" "delivery unconfirmed; verdict=pending" \
    "undelivered steer on composer-supported harness should report verdict=pending"
  pass "a genuinely undelivered steer on a composer-supported harness is reported as failure"
}

test_send_into_dead_shell_is_never_confirmed() {
  local harness=$1 case_dir home proj wt fakebin err rc
  # Counterfactual: If a send into a dead shell without native agent activity was
  # confirmed as empty/success, this test would fail.
  case_dir="$TMP_ROOT/send-dead-shell-$harness"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; err="$case_dir/send.err"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/lane-$harness"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/lane-$harness.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj"
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "idle" "idle" "idle")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    FM_HERDR_FAKE_AGENT="$harness" FM_HERDR_FAKE_COMPOSER='$ ' \
    "$ROOT/bin/fm-send.sh" "fm-lane-$harness" "steer message" >/dev/null 2>"$err"
  rc=$?
  [ "$rc" -ne 0 ] || fail "send into dead shell on $harness must not exit 0"
  expect_code 3 "$rc" "send into dead shell on $harness should exit code 3 (unverifiable)"
  assert_contains "$(cat "$err")" "text delivery unverifiable on" \
    "send into dead shell on $harness should state delivery unverifiable"
  assert_contains "$(cat "$err")" "verdict=unverifiable" \
    "send into dead shell on $harness should state verdict=unverifiable"
  pass "a send into a dead shell on $harness is never confirmed"
}

test_live_cursor_and_agy_tasks_read_working_in_crew_state() {
  local harness=$1 case_dir home proj wt fakebin out
  # Counterfactual: If fm_busy_classify returned unknown source-mismatch for a live
  # working cursor/agy worker, this test would fail.
  case_dir="$TMP_ROOT/crew-state-working-$harness"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/task-$harness"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/task-$harness.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj" "branch=fm/task-$harness"
  "$ROOT/bin/fm-busy-event.sh" arm "$home/state" "task-$harness" >/dev/null
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "working")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_HERDR_FAKE_AGENT="$harness" \
    "$ROOT/bin/fm-crew-state.sh" "task-$harness")
  assert_contains "$out" "state: working" "live $harness worker should read state: working"
  assert_contains "$out" "source: pane" "live $harness worker should have source: pane"
  assert_contains "$out" "herdr-native" "live $harness worker detail should cite herdr-native"
  pass "a live, actively working $harness task reads as working from bin/fm-crew-state.sh"
}

test_idle_unreadable_cursor_and_agy_tasks_read_unknown_in_crew_state() {
  local harness=$1 case_dir home proj wt fakebin out
  # Counterfactual: If an idle cursor/agy task without a turn-end hook was falsely
  # read as working or idle instead of unknown, this test would fail.
  case_dir="$TMP_ROOT/crew-state-idle-$harness"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/task-$harness"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/task-$harness.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj" "branch=fm/task-$harness"
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "idle")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_HERDR_FAKE_AGENT="$harness" \
    "$ROOT/bin/fm-crew-state.sh" "task-$harness")
  assert_contains "$out" "state: unknown" "idle $harness worker should read state: unknown"
  pass "a $harness task whose state genuinely cannot be read still reads unknown"
}

test_unverifiable_send_reports_distinct_wording_and_exit_code() {
  local harness=$1 case_dir home proj wt fakebin err rc
  # Counterfactual: If an unverifiable send on cursor/agy reported standard exit 1
  # delivery unconfirmed instead of exit 3 unverifiable, this test would fail.
  case_dir="$TMP_ROOT/unverifiable-$harness"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; err="$case_dir/send.err"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/lane-$harness"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/lane-$harness.meta" \
    "window=default:w1:p1" "backend=herdr" "herdr_session=default" "herdr_pane_id=w1:p1" \
    "harness=$harness" "kind=ship" "mode=local-only" "yolo=off" "worktree=$wt" "project=$proj"
  fakebin=$(make_herdr_signal_fakebin "$case_dir/fake" "idle" "idle" "idle")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    FM_HERDR_FAKE_AGENT="$harness" FM_HERDR_FAKE_COMPOSER='$ ' \
    "$ROOT/bin/fm-send.sh" "fm-lane-$harness" "steer message" >/dev/null 2>"$err"
  rc=$?
  expect_code 3 "$rc" "unverifiable send on $harness should exit code 3"
  assert_contains "$(cat "$err")" "text delivery unverifiable on" \
    "unverifiable send on $harness should state text delivery unverifiable"
  assert_contains "$(cat "$err")" "verdict=unverifiable" \
    "unverifiable send on $harness should state verdict=unverifiable"
  pass "unverifiable send on $harness is reported distinctly in wording and exit code"
}

test_crew_only_refuses_secondmate cursor
test_crew_only_refuses_secondmate agy
test_herdr_only_refuses_non_herdr_backend cursor
test_herdr_only_refuses_non_herdr_backend agy
test_raw_command_bypass_refused
test_raw_spawn_installs_exec_time_guard
test_teardown_removes_owned_agy_trust
test_teardown_preserves_unowned_agy_trust
test_teardown_incomplete_on_removal_failure
test_forced_secondmate_child_trust_failure_prevents_release
test_teardown_leaves_trust_for_non_agy
test_send_text_submit_lands_on_cursor_and_agy cursor
test_send_text_submit_lands_on_cursor_and_agy agy
test_transient_idle_does_not_confirm_cursor_and_agy_send cursor
test_transient_idle_does_not_confirm_cursor_and_agy_send agy
test_unchanged_working_does_not_confirm_cursor_and_agy_send cursor
test_unchanged_working_does_not_confirm_cursor_and_agy_send agy
test_failed_enter_reports_cursor_and_agy_send_failure cursor
test_failed_enter_reports_cursor_and_agy_send_failure agy
test_unreadable_after_enter_does_not_retry_cursor_and_agy_send cursor
test_unreadable_after_enter_does_not_retry_cursor_and_agy_send agy
test_genuinely_undelivered_steer_on_composer_supported_harness
test_send_into_dead_shell_is_never_confirmed cursor
test_send_into_dead_shell_is_never_confirmed agy
test_live_cursor_and_agy_tasks_read_working_in_crew_state cursor
test_live_cursor_and_agy_tasks_read_working_in_crew_state agy
test_idle_unreadable_cursor_and_agy_tasks_read_unknown_in_crew_state cursor
test_idle_unreadable_cursor_and_agy_tasks_read_unknown_in_crew_state agy
test_unverifiable_send_reports_distinct_wording_and_exit_code cursor
test_unverifiable_send_reports_distinct_wording_and_exit_code agy

echo "# all fm-cursor-agy-adapter tests passed"
