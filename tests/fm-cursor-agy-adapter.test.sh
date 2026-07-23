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
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
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
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" "$harness")
  status=$?
  expect_code 1 "$status" "$harness spawn on the tmux backend should be refused"
  assert_contains "$out" "only on the herdr backend" "$harness refusal should say herdr-only"
  assert_absent "$home/state/$id.meta" "herdr-only refusal must happen before meta is written"
  pass "$harness is refused on a non-herdr backend (herdr-only)"
}

# --- teardown workspace-trust cleanup ---------------------------------------

run_teardown() {  # <home> <fakebin> <settings> <id>
  local home=$1 fakebin=$2 settings=$3 id=$4
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_AGY_SETTINGS_OVERRIDE="$settings" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1
}

setup_teardown_case() {  # <name> <id> <harness> -> prints "home|wt|fakebin|settings"
  local name=$1 id=$2 harness=$3 case_dir home proj wt fakebin settings
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
  printf '{"trustedWorkspaces":["/home/cap","%s"]}' "$wt" > "$settings"
  printf '%s|%s|%s|%s\n' "$home" "$wt" "$fakebin" "$settings"
}

test_teardown_removes_agy_trust() {
  local id home wt fakebin settings out
  id=agy-teardown-z3
  IFS='|' read -r home wt fakebin settings <<EOF
$(setup_teardown_case agy-teardown "$id" agy)
EOF
  out=$(run_teardown "$home" "$fakebin" "$settings" "$id") \
    || fail "agy teardown failed"$'\n'"$out"
  [ "$(jq -c '.trustedWorkspaces' "$settings")" = '["/home/cap"]' ] \
    || fail "agy teardown did not drop the worktree path from trustedWorkspaces (got $(jq -c '.trustedWorkspaces' "$settings"))"
  assert_absent "$home/state/$id.meta" "teardown should remove the task meta"
  pass "agy teardown removes the worktree entry from global workspace trust"
}

test_teardown_leaves_trust_for_non_agy() {
  local id home wt fakebin settings before out
  id=claude-teardown-z4
  IFS='|' read -r home wt fakebin settings <<EOF
$(setup_teardown_case claude-teardown "$id" claude)
EOF
  before=$(cat "$settings")
  out=$(run_teardown "$home" "$fakebin" "$settings" "$id") \
    || fail "claude teardown failed"$'\n'"$out"
  [ "$(cat "$settings")" = "$before" ] \
    || fail "a non-agy teardown must not touch the shared agy settings file"
  pass "a non-agy teardown leaves the agy workspace-trust file untouched"
}

test_crew_only_refuses_secondmate cursor
test_crew_only_refuses_secondmate agy
test_herdr_only_refuses_non_herdr_backend cursor
test_herdr_only_refuses_non_herdr_backend agy
test_teardown_removes_agy_trust
test_teardown_leaves_trust_for_non_agy

echo "# all fm-cursor-agy-adapter tests passed"
