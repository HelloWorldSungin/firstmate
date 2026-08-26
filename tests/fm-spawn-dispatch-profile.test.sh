#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
          if [ -n "${FM_FAKE_RESOLVED_CLAUDE_CONFIG_LOG:-}" ]; then
            case "$a" in
              *claude*)
                pinned=$(printf '%s\n' "$a" | sed -n "s/^CLAUDE_CONFIG_DIR='\([^']*\)'.*/\1/p")
                config_dir=${pinned:-${FM_FAKE_DAEMON_CLAUDE_CONFIG_DIR:-}}
                if [ -n "$config_dir" ]; then
                  printf '%s/.claude.json\n' "$config_dir"
                else
                  printf '%s/.claude.json\n' "$HOME"
                fi > "$FM_FAKE_RESOLVED_CLAUDE_CONFIG_LOG"
                ;;
            esac
          fi
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  # A pass-through `timeout` for the bounded calls fm-spawn makes (the cursor
  # catalog probe, the work-item milestone). It must accept BOTH shapes: the
  # plain `timeout <seconds> <cmd>` and this fork's
  # `timeout -k <grace> <seconds> <cmd>` (bin/fm-timeout-lib.sh). A shim that
  # strips only one leading argument would try to exec the duration and every
  # bounded call would silently fail.
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -k|--kill-after) shift 2 ;;
    -*) shift ;;
    *) shift; break ;;
  esac
done
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  [ "${FM_FAKE_CURSOR_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_LIST_STATUS}"
  printf '%b\n' "${FM_FAKE_CURSOR_MODELS:-Available models\ncursor-grok-4.5-high - Grok 4.5 High}"
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n<!-- firstmate-task-branch=fm/%s -->\nDelivery contract: mode=no-mistakes\n' "$id" "$id" \
      > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

enable_design_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"interactive design interview","use":[{"harness":"codex","model":"gpt-5.5","effort":"xhigh"},{"harness":"pi","model":"anthropic/claude-sonnet-5","effort":"xhigh"},{"harness":"claude","model":"claude-sonnet-5","effort":"xhigh"}]}]}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # An explicitly set CLAUDE_CONFIG_DIR is forwarded onto Claude launches, so
  # pin it empty by default instead of leaking the invoking shell's value.
  # A test opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_DAEMON_CLAUDE_CONFIG_DIR="${FM_FAKE_DAEMON_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_RESOLVED_CLAUDE_CONFIG_LOG="${FM_FAKE_RESOLVED_CLAUDE_CONFIG_LOG:-}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch runtime_home
  id='profile-off-z1'
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"
  runtime_home="$CASE_DIR/runtime-home"
  mkdir -p "$runtime_home/.claude"

  out=$(HOME="$runtime_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default
  assert_grep "branch=fm/$id" "$HOME_DIR/state/$id.meta" \
    "spawn did not copy the brief's exact task branch into metadata"

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_non_cursor_launch_clears_inherited_cursor_markers() {
  local rec id out status launch
  id='profile-claude-cursor-markers-z1b'
  rec=$(make_spawn_case profile-claude-cursor-markers claude "$id")
  read_case_record "$rec"

  out=$(CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn under Cursor markers should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "non-cursor launch must clear both inherited Cursor identity markers"
  pass "non-cursor launches clear inherited Cursor identity markers"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id='profile-relative-paths-z1b'
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id='profile-relative-home-defaults-z1c'
  absolute_id='profile-absolute-home-defaults-z1d'
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id='profile-absolute-paths-z1c'
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id='profile-unresolvable-paths-z1d'
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id='profile-required-ship-z11'
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id='profile-required-scout-z12'
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id='profile-explicit-z13'
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id='profile-positional-z14'
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id='profile-raw-z15'
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id='profile-claude-z2'
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  assert_not_contains "$launch" "--tui-mode" "non-Pi launches must not receive Pi's TUI mode override"
  pass "claude receives --model and --effort profile flags"
}

test_claude_records_pre_dispatch_transcript_identities() {
  local rec id out status cfg dir
  id='profile-claude-watermark-z2b'
  rec=$(make_spawn_case profile-claude-watermark claude "$id")
  read_case_record "$rec"
  cfg="$CASE_DIR/claude-config"
  dir="$cfg/projects/$(printf '%s' "$WT_DIR" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  printf '{"type":"assistant","message":{"model":"claude-opus-4-8"}}\n' > "$dir/existing.jsonl"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$cfg" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model opus)
  status=$?
  expect_code 0 "$status" "claude spawn should capture its transcript watermark"
  assert_grep "model_evidence_watermark=claude-transcript-v1" "$HOME_DIR/state/$id.meta" \
    "claude spawn did not record the watermark format"
  assert_grep "model_evidence_store=$cfg" "$HOME_DIR/state/$id.meta" \
    "claude spawn did not record the canonical evidence store"
  assert_grep "model_evidence_before=existing.jsonl" "$HOME_DIR/state/$id.meta" \
    "claude spawn did not record the existing transcript identity"
  pass "claude spawn records pre-dispatch transcript identities"
}

test_claude_watermark_failure_preserves_recoverable_metadata() {
  local rec id out status cfg dir real_find
  id='profile-claude-watermark-failure-z2c'
  rec=$(make_spawn_case profile-claude-watermark-failure claude "$id")
  read_case_record "$rec"
  cfg="$CASE_DIR/claude-config"
  dir="$cfg/projects/$(printf '%s' "$WT_DIR" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  real_find=$(command -v find)
  cat > "$FAKEBIN_DIR/find" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"*.jsonl"*) printf '%s\n' 'synthetic transcript enumeration failure' >&2; exit 7 ;;
esac
exec "$real_find" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/find"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$cfg" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model opus)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn continued after watermark capture failed"
  assert_contains "$out" "failed to capture the pre-dispatch model-evidence watermark" \
    "watermark capture failure was not surfaced"
  assert_grep "window=firstmate:fm-$id" "$HOME_DIR/state/$id.meta" \
    "watermark failure left no durable endpoint record"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "watermark failure left no recoverable worktree identity"
  assert_grep "model=opus" "$HOME_DIR/state/$id.meta" \
    "watermark failure left no dispatched-model record"
  assert_grep "spawned_at=" "$HOME_DIR/state/$id.meta" \
    "watermark failure left no dispatch timestamp"
  [ ! -s "$LAUNCH_LOG" ] || fail "watermark failure still launched the worker"
  pass "watermark failure preserves recoverable metadata without launching"
}

test_claude_newline_physical_store_refuses_before_launch() {
  local rec id out status target link meta_text
  id='profile-claude-newline-store-z2d'
  rec=$(make_spawn_case profile-claude-newline-store claude "$id")
  read_case_record "$rec"
  target="$CASE_DIR/physical"$'\n'"store"
  link="$CASE_DIR/store-link"
  mkdir -p "$target"
  ln -s "$target" "$link"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$link" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model opus)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn accepted a newline-bearing physical evidence store"
  assert_contains "$out" "failed to capture the pre-dispatch model-evidence watermark" \
    "newline-bearing physical store failure was not surfaced"
  meta_text=$(cat "$HOME_DIR/state/$id.meta")
  assert_not_contains "$meta_text" "model_evidence_store=" \
    "newline-bearing physical store was serialized into metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "newline-bearing physical store still launched the worker"
  pass "claude refuses newline-bearing physical stores before launch"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id='profile-codex-z3'
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_omits_invalid_max_effort() {
  local rec id out status launch
  id='profile-codex-max-z4'
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with unsupported max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch must omit unsupported max reasoning effort"
  pass "codex omits unsupported max effort instead of passing a bad config value"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id='profile-grok-z5'
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id='profile-grok-max-z6'
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported max reasoning effort"
}

test_grok_omits_invalid_xhigh_reasoning_effort() {
  local rec id out status launch
  id='profile-grok-xhigh-z6b'
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported xhigh reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 xhigh
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when xhigh effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported xhigh reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported xhigh reasoning effort"
}

test_cursor_threads_model_workspace_and_omits_effort_axis() {
  local rec id out status launch
  id='profile-cursor-z6c'
  rec=$(make_spawn_case profile-cursor cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5-high --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with a model-qualified reasoning class should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-grok-4.5-high high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--trust --yolo --model 'cursor-grok-4.5-high' --workspace '$WT_DIR'" \
    "cursor launch did not carry trust, autonomy, model, and exact workspace flags"
  # The executable is RESOLVED, never named: `cursor` is not the CLI, so a
  # literal `cursor agent` command cannot run on a machine that has only the
  # real installed names.
  assert_not_contains "$launch" "cursor agent --trust" \
    "cursor launch must resolve its executable, not invoke a literal 'cursor agent'"
  assert_contains "$launch" "cursor-agent" "cursor launch did not resolve a cursor executable"
  # -w/--worktree would allocate a SECOND worktree under ~/.cursor/worktrees and
  # break the isolation contract the spawn assertion depends on.
  assert_not_contains "$launch" " --worktree" "cursor launch must never allocate a second worktree"
  assert_not_contains "$launch" " -w " "cursor launch must never allocate a second worktree"
  # An inherited CLAUDECODE would otherwise outrank cursor's own marker.
  assert_contains "$launch" "env -u CLAUDECODE" "cursor launch must clear foreign primary markers"
  assert_contains "$launch" "encode launch-brief" "cursor launch did not deliver the brief positionally"
  assert_not_contains "$launch" "--effort" "cursor launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor launch must not invent a separate reasoning-effort flag"
  assert_grep 'harness=cursor' "$HOME_DIR/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'model=cursor-grok-4.5-high' "$HOME_DIR/state/$id.meta" "cursor model was recorded as default"
  pass "cursor receives its model-qualified reasoning class and exact task workspace"
}

test_cursor_refuses_model_absent_from_live_catalog() {
  local rec id out status
  id='profile-cursor-unsupported-z6d'
  rec=$(make_spawn_case profile-cursor-unsupported cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5)
  status=$?
  expect_code 1 "$status" "cursor spawn should refuse a model absent from a successful catalog"
  assert_contains "$out" "Cursor model 'cursor-grok-4.5' is not available" \
    "cursor model refusal did not identify the unavailable model"
  assert_contains "$out" "--list-models" \
    "cursor model refusal did not tell the caller how to find valid ids"
  [ ! -s "$LAUNCH_LOG" ] || fail "cursor model refusal must happen before launch"
  pass "cursor refuses model ids absent from its resolved binary's live catalog"
}

test_cursor_failed_catalog_probe_does_not_block_spawn() {
  local rec id out status launch
  id='profile-cursor-catalog-unreachable-z6e'
  rec=$(make_spawn_case profile-cursor-catalog-unreachable cursor "$id")
  read_case_record "$rec"

  FM_TEST_CURSOR_LIST_STATUS=124 \
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-catalog-unreachable)
  status=$?
  expect_code 0 "$status" "cursor spawn should fail open when the bounded catalog query fails"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'cursor-catalog-unreachable'" \
    "failed catalog lookup incorrectly removed the requested model"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-catalog-unreachable default
  pass "cursor preserves the requested model when its live catalog is unreachable"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id='profile-opencode-z7'
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id='profile-pi-z8'
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not force the regular TUI while threading the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id='profile-pi-signed-z8b'
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not force the regular TUI with Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  local ext gen
  ext=$(cat "$HOME_DIR/state/$id.pi-ext.ts")
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_contains "$ext" 'pi.on("agent_start"' "pi extension lost the semantic agent_start busy edge"
  assert_contains "$ext" 'pi.on("agent_settled"' "pi extension lost the semantic agent_settled idle edge"
  assert_contains "$ext" 'ctx.isIdle()' "pi extension no longer confirms idle with ctx.isIdle()"
  assert_contains "$ext" "\"--gen\", \"$gen\"" "pi extension does not carry the armed incarnation gen"
  assert_contains "$ext" '"--source", "pi-ext"' "pi extension does not attribute its semantic source"
  assert_contains "$ext" 'pi.on("turn_end"' "pi extension lost the turn-end notification touch"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_tui_mode_probe_is_safe_for_old_and_new_pi() {
  local harness version rec id out status launch
  for harness in pi pi-signed; do
    for version in 0.82.0 0.84.0; do
      id="profile-${harness}-tui-${version//./}-z8d"
      rec=$(make_spawn_case "profile-__MODELFLAG__-${harness}-tui-${version//./}" "$harness" "$id")
      read_case_record "$rec"

      out=$(FM_TEST_PI_VERSION="$version" \
        run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR")
      status=$?
      expect_code 0 "$status" "$harness $version spawn should succeed"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
        "$harness $version launch must use the executable selected for probing"
      assert_not_contains "$launch" "FM_PI_HARNESS=$harness $harness" \
        "$harness $version launch must not re-resolve a bare executable in the worker"
      if [ "$version" = 0.82.0 ]; then
        assert_not_contains "$launch" "--tui-mode" \
          "$harness $version launch must omit unsupported --tui-mode"
      else
        assert_contains "$launch" "'$FAKEBIN_DIR/$harness' --tui-mode regular" \
          "$harness $version launch must preserve the regular TUI"
      fi
    done
  done
  pass "Pi launch probing omits --tui-mode on older Pi and preserves it on supporting Pi"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id='profile-pi-signed-missing-z8c'
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity() {
  local rec id sm out status launch
  id='profile-pi-signed-secondmate-z8d'
  rec=$(make_spawn_case profile-pi-signed-secondmate codex "$id")
  read_case_record "$rec"
  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
  pass "pi-signed is a distinct persistent secondmate runtime with shared Pi supervision semantics"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1='profile-batch-a-z9'
  id2='profile-batch-b-z10'
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_claude_forwards_firstmate_config_dir_when_set() {
  local rec id out status launch canonical_root relative_cfg cfg daemon_cfg resolved_config recorded_store
  id='profile-claude-cfgdir-z17'
  rec=$(make_spawn_case profile-claude-cfgdir claude "$id")
  read_case_record "$rec"
  canonical_root="$CASE_DIR/canonical-root"
  relative_cfg=link/../cfg
  cfg="$canonical_root/real/cfg"
  daemon_cfg="$CASE_DIR/daemon-claude-config"
  resolved_config="$CASE_DIR/resolved-claude-config.log"
  mkdir -p "$canonical_root/real/child" "$cfg" "$daemon_cfg"
  ln -s "$canonical_root/real/child" "$canonical_root/link"
  printf '{"hasCompletedOnboarding":true}\n' > "$cfg/.claude.json"
  printf '{}\n' > "$daemon_cfg/.claude.json"

  out=$(cd "$canonical_root" && \
    FM_TEST_CLAUDE_CONFIG_DIR="$relative_cfg" \
      FM_FAKE_DAEMON_CLAUDE_CONFIG_DIR="$daemon_cfg" \
      FM_FAKE_RESOLVED_CLAUDE_CONFIG_LOG="$resolved_config" \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  recorded_store=$(sed -n 's/^model_evidence_store=//p' "$HOME_DIR/state/$id.meta")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$cfg' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "claude launch did not forward firstmate's canonical CLAUDE_CONFIG_DIR to the crewmate pane"
  [ "$recorded_store" = "$cfg" ] \
    || fail "explicit Claude config did not record its canonical evidence store: $recorded_store"
  [ "$(cat "$resolved_config")" = "$cfg/.claude.json" ] \
    || fail "daemon ambient config overrode firstmate's explicit Claude config"
  jq -e '.hasCompletedOnboarding == true' "$cfg/.claude.json" >/dev/null \
    || fail "explicitly forwarded Claude config was not onboarded"
  pass "claude forwards the canonical explicit config and evidence store"
}

test_claude_default_uses_home_config_and_records_evidence_store() {
  local rec id out status launch runtime_home resolved_config recorded_store
  id='profile-claude-nocfgdir-z18'
  rec=$(make_spawn_case profile-claude-nocfgdir claude "$id")
  read_case_record "$rec"
  runtime_home="$CASE_DIR/runtime-home"
  resolved_config="$CASE_DIR/resolved-claude-config.log"
  mkdir -p "$runtime_home/.claude"
  printf '{"hasCompletedOnboarding":true}\n' > "$runtime_home/.claude.json"
  printf '{}\n' > "$runtime_home/.claude/.claude.json"

  out=$(HOME="$runtime_home" \
    FM_FAKE_RESOLVED_CLAUDE_CONFIG_LOG="$resolved_config" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without CLAUDE_CONFIG_DIR should succeed"
  launch=$(cat "$LAUNCH_LOG")
  recorded_store=$(sed -n 's/^model_evidence_store=//p' "$HOME_DIR/state/$id.meta")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "default Claude launch confused the transcript store with the config directory"
  [ "$recorded_store" = "$runtime_home/.claude" ] \
    || fail "default-store spawn recorded the wrong evidence store: $recorded_store"
  [ "$(cat "$resolved_config")" = "$runtime_home/.claude.json" ] \
    || fail "default Claude launch resolved the wrong config: $(cat "$resolved_config")"
  jq -e '.hasCompletedOnboarding == true' "$(cat "$resolved_config")" >/dev/null \
    || fail "default Claude launch did not resolve an onboarded config"
  pass "default Claude launch uses the onboarded home config and records its transcript store separately"
}

test_non_claude_harness_ignores_config_dir() {
  local rec id out status launch
  id='profile-codex-nocfgdir-z19'
  rec=$(make_spawn_case profile-codex-nocfgdir codex "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "non-claude harness launch must not receive the claude-specific config-dir prefix"
  pass "non-claude harnesses do not receive the claude CLAUDE_CONFIG_DIR prefix"
}

test_design_profile_resolves_on_claude_codex_and_pi() {
  local plugin registry harness model effort rec id out status profile schema_launch schema_meta
  local fallback_id fallback_launch resolved binary model_flag effort_flag tracker_log
  plugin="$TMP_ROOT/design-plugin"
  registry="$TMP_ROOT/design-registry.json"
  mkdir -p "$plugin/skills/productivity/grilling" \
    "$plugin/skills/engineering/domain-modeling" \
    "$plugin/skills/engineering/ask-matt"
  printf 'grilling\n' > "$plugin/skills/productivity/grilling/SKILL.md"
  printf 'domain modeling\n' > "$plugin/skills/engineering/domain-modeling/SKILL.md"
  printf 'ask matt\n' > "$plugin/skills/engineering/ask-matt/SKILL.md"
  jq -n --arg plugin "$plugin" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$plugin,version:"1.2.0",lastUpdated:"2026-08-01T00:00:00Z"}
    ]}}' > "$registry"

  for harness in codex pi claude; do
    case "$harness" in
      codex)
        model=gpt-5.5
        binary='codex '
        effort_flag='model_reasoning_effort="xhigh"'
        ;;
      pi)
        model=anthropic/claude-sonnet-5
        binary='pi '
        effort_flag="--thinking 'xhigh'"
        ;;
      claude)
        model=claude-sonnet-5
        binary='claude '
        effort_flag="--effort 'xhigh'"
        ;;
    esac
    effort=xhigh
    model_flag="--model '$model'"

    id="design-schema-$harness-z20"
    rec=$(make_spawn_case "design-schema-$harness" claude "$id")
    read_case_record "$rec"
    enable_design_dispatch_profile "$HOME_DIR"
    profile=$(jq -r --arg harness "$harness" \
      '.rules[] | select(.when == "interactive design interview") | .use[] | select(.harness == $harness) | [.harness,.model,.effort] | @tsv' \
      "$HOME_DIR/config/crew-dispatch.json")
    [ "$profile" = "$harness"$'\t'"$model"$'\t'"$effort" ] \
      || fail "design dispatch schema did not resolve $harness/$model/$effort: $profile"
    if [ "$harness" = codex ]; then
      printf '%s\n' \
        '<!-- firstmate-work-item=github:https://github.com/acme/widget/issues/42 -->' \
        '<!-- firstmate-pr-target=github:github.com/acme/widget -->' \
        >> "$HOME_DIR/data/$id/brief.md"
      tracker_log="$CASE_DIR/tracker.log"
      cat > "$FAKEBIN_DIR/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tracker_log"
exit 1
EOF
      chmod +x "$FAKEBIN_DIR/gh"
    fi
    out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
      run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --design --harness "$harness" --model "$model" --effort "$effort" \
      --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "design profile should spawn on $harness"
    assert_contains "$out" "spawned $id harness=$harness kind=design" \
      "design spawn did not retain kind=design on $harness"
    schema_launch=$(cat "$LAUNCH_LOG")
    schema_meta="$HOME_DIR/state/$id.meta"
    pass "design matrix $harness 1/5: dispatch schema selects $harness/$model/$effort"
    if [ "$harness" = codex ]; then
      assert_grep 'work_item=declared|github|https://github.com/acme/widget/issues/42' \
        "$HOME_DIR/state/$id.meta" \
        "design spawn did not record its work item"
      assert_present "$tracker_log" \
        "design spawn did not attempt the tracked-output dispatch milestone"
    fi

    fallback_id="design-fallback-$harness-z21"
    rec=$(make_spawn_case "design-fallback-$harness" "$harness" "$fallback_id")
    read_case_record "$rec"
    resolved=$(FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-harness.sh" crew)
    [ "$resolved" = "$harness" ] \
      || fail "fm-harness.sh crew resolved $resolved instead of $harness"
    out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
      run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$fallback_id" "$PROJ_DIR" --design --model "$model" --effort "$effort" \
      --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "design profile fallback should spawn on $harness"
    assert_contains "$out" "spawned $fallback_id harness=$harness kind=design" \
      "design fallback spawn did not retain kind=design on $harness"
    fallback_launch=$(cat "$LAUNCH_LOG")
    pass "design matrix $harness 2/5: fm-harness.sh fallback resolves $harness"

    assert_contains "$schema_launch" "$binary" \
      "schema-selected design launch did not use the $harness template"
    assert_contains "$fallback_launch" "$binary" \
      "fallback-selected design launch did not use the $harness template"
    assert_contains "$schema_launch" "encode launch-brief" \
      "schema-selected design launch bypassed fm-launch-lib.sh construction"
    assert_contains "$fallback_launch" "encode launch-brief" \
      "fallback-selected design launch bypassed fm-launch-lib.sh construction"
    pass "design matrix $harness 3/5: fm-launch-lib.sh constructs both commands"

    assert_meta_profile "$HOME_DIR/state/$fallback_id.meta" "$harness" "$model" "$effort"
    assert_meta_profile "$schema_meta" "$harness" "$model" "$effort"
    assert_grep 'kind=design' "$schema_meta" \
      "schema-selected design metadata did not retain kind=design on $harness"
    assert_grep 'kind=design' "$HOME_DIR/state/$fallback_id.meta" \
      "fallback-selected design metadata did not retain kind=design on $harness"
    pass "design matrix $harness 4/5: fm-spawn.sh validates design and records all axes"

    assert_contains "$schema_launch" "$model_flag" \
      "schema-selected $harness launch omitted representative model $model"
    assert_contains "$fallback_launch" "$model_flag" \
      "fallback-selected $harness launch omitted representative model $model"
    assert_contains "$schema_launch" "$effort_flag" \
      "schema-selected $harness launch omitted representative effort $effort"
    assert_contains "$fallback_launch" "$effort_flag" \
      "fallback-selected $harness launch omitted representative effort $effort"
    pass "design matrix $harness 5/5: harness-adapters axes render $model/$effort"
  done
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id='profile-secondmate-z16'
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

# A brief scaffolded with --continue-branch must record that existing branch in
# metadata, not fm/<task-id>. Fails if spawn copies a name the worker never uses.
test_spawn_copies_continued_task_branch_from_brief_flag() {
  local rec id continued runtime_home out status
  id='continue-branch-meta-z9'
  continued='fm/existing-pr-head'
  rec=$(make_spawn_case continue-branch-meta claude "$id")
  read_case_record "$rec"
  rm -f "$HOME_DIR/data/$id/brief.md"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-brief.sh" "$id" "$PROJ_DIR" --mode no-mistakes --continue-branch "$continued" >/dev/null 2>&1 \
    || fail "fm-brief.sh --continue-branch should scaffold before spawn"
  runtime_home="$CASE_DIR/runtime-home"
  mkdir -p "$runtime_home/.claude"

  out=$(HOME="$runtime_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn of a continue-branch brief should succeed"
  assert_grep "branch=$continued" "$HOME_DIR/state/$id.meta" \
    "spawn did not copy the continued branch from the brief marker into metadata"
  assert_no_grep "branch=fm/$id" "$HOME_DIR/state/$id.meta" \
    "spawn recorded unused fm/<task-id> as the task branch"
  pass "spawn copies --continue-branch into metadata instead of fm/<task-id>"
}

test_spawn_refuses_default_branch_task_marker() {
  local rec id default_branch runtime_home out status
  id='continue-default-refused-z10'
  rec=$(make_spawn_case continue-default-refused claude "$id")
  read_case_record "$rec"
  default_branch=$(git -C "$PROJ_DIR" symbolic-ref --quiet --short HEAD) \
    || fail "default-branch refusal fixture has no symbolic branch"
  sed -i "s|firstmate-task-branch=fm/$id|firstmate-task-branch=$default_branch|" \
    "$HOME_DIR/data/$id/brief.md"
  runtime_home="$CASE_DIR/runtime-home"
  mkdir -p "$runtime_home/.claude"

  out=$(HOME="$runtime_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse a task marker naming the default branch"
  assert_contains "$out" "task branch marker names the repository default branch '$default_branch'" \
    "spawn did not protect the default branch from a hand-edited marker"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "spawn published metadata after the default-branch refusal"
  pass "spawn refuses a task marker naming the repository default branch"
}

test_spawn_refuses_fully_qualified_task_branch_marker() {
  local rec id runtime_home out status
  id='continue-qualified-refused-z11'
  rec=$(make_spawn_case continue-qualified-refused claude "$id")
  read_case_record "$rec"
  sed -i "s|firstmate-task-branch=fm/$id|firstmate-task-branch=refs/heads/main|" \
    "$HOME_DIR/data/$id/brief.md"
  runtime_home="$CASE_DIR/runtime-home"
  mkdir -p "$runtime_home/.claude"

  out=$(HOME="$runtime_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse a fully qualified task branch marker"
  assert_contains "$out" "outside the refs/ namespace" \
    "spawn accepted a fully qualified default-branch destination"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "spawn published metadata after the fully qualified branch refusal"
  pass "spawn refuses fully qualified task branch markers"
}

test_spawn_refuses_refspec_force_task_branch_marker() {
  local rec id runtime_home out status
  id='continue-force-refused-z12'
  rec=$(make_spawn_case continue-force-refused claude "$id")
  read_case_record "$rec"
  sed -i "s|firstmate-task-branch=fm/$id|firstmate-task-branch=+feature/existing|" \
    "$HOME_DIR/data/$id/brief.md"
  runtime_home="$CASE_DIR/runtime-home"
  mkdir -p "$runtime_home/.claude"

  out=$(HOME="$runtime_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse a refspec-force task branch marker"
  assert_contains "$out" "refspec force prefix" \
    "spawn accepted a refspec-force task branch destination"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "spawn published metadata after the refspec-force branch refusal"
  pass "spawn refuses refspec-force task branch markers"
}

test_no_profile_keeps_claude_profile_defaults
test_non_cursor_launch_clears_inherited_cursor_markers
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
test_claude_records_pre_dispatch_transcript_identities
test_claude_watermark_failure_preserves_recoverable_metadata
test_claude_newline_physical_store_refuses_before_launch
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_cursor_threads_model_workspace_and_omits_effort_axis
test_cursor_refuses_model_absent_from_live_catalog
test_cursor_failed_catalog_probe_does_not_block_spawn
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_default_uses_home_config_and_records_evidence_store
test_non_claude_harness_ignores_config_dir
test_design_profile_resolves_on_claude_codex_and_pi
test_active_dispatch_profile_does_not_block_secondmate_launch
test_spawn_copies_continued_task_branch_from_brief_flag
test_spawn_refuses_default_branch_task_marker
test_spawn_refuses_fully_qualified_task_branch_marker
test_spawn_refuses_refspec_force_task_branch_marker

printf '\nall fm-spawn-dispatch-profile tests passed\n'
