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
  has-session|new-session|new-window) exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_KILL_LOG"
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
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
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
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
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
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
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
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
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
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
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
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
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
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
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
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
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
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
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
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
  id=profile-grok-xhigh-z6b
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
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

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
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
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not thread the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
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

test_design_spawn_mounts_skills_records_kind_and_installs_backstop() {
  local rec id out status meta hook skill
  id=profile-design-z18
  rec=$(make_spawn_case profile-design claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --model sonnet --effort xhigh --design)
  status=$?
  expect_code 0 "$status" "Claude design spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=design" \
    "design spawn did not report kind=design"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "kind=design" "$meta" "design spawn did not record kind=design"
  [ "$(git -C "$WT_DIR" rev-parse --show-toplevel)" = "$WT_DIR" ] \
    || fail "design spawn fixture did not resolve the isolated worktree root"
  for skill in \
    ask-matt grilling grill-me batch-grill-me to-questionnaire handoff \
    to-spec domain-modeling prototype
  do
    # Copies, never symlinks: a symlink would let the crewmate write through the
    # mount into the firstmate home's real skill files.
    [ -f "$WT_DIR/.agents/skills/$skill/SKILL.md" ] \
      || fail "design spawn did not mount .agents skill $skill"
    [ -L "$WT_DIR/.agents/skills/$skill" ] \
      && fail "design spawn mounted .agents skill $skill as a writable symlink"
    [ -f "$WT_DIR/.claude/skills/$skill/SKILL.md" ] \
      || fail "design spawn did not mount Claude skill $skill"
    [ -L "$WT_DIR/.claude/skills/$skill" ] \
      && fail "design spawn mounted Claude skill $skill as a writable symlink"
  done
  [ -z "$(git -C "$WT_DIR" status --short)" ] \
    || fail "design skill mounts or hooks dirtied the isolated worktree"
  hook="$WT_DIR/.claude/settings.local.json"
  assert_grep "fm-design-context.sh" "$hook" \
    "design Claude Stop hook did not install the context backstop"
  assert_grep "turn-end '$id'" "$hook" \
    "design Claude Stop hook did not bind the task identity"
  pass "design spawn resolves an isolated worktree, records its kind, mounts skills, and installs context telemetry"
}

# The crewmate's environment comes from the terminal server, not from firstmate,
# so an operator's ceiling override only reaches the process that ENFORCES the
# ceiling if the hook command carries it.
test_design_hook_pins_the_operator_context_ceiling() {
  local rec id status hook
  id=profile-design-ceiling-z27
  rec=$(make_spawn_case profile-design-ceiling claude "$id")
  read_case_record "$rec"

  export FM_DESIGN_CONTEXT_HARD_LIMIT=4242
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --design >/dev/null
  status=$?
  unset FM_DESIGN_CONTEXT_HARD_LIMIT
  expect_code 0 "$status" "design spawn under a ceiling override should succeed"
  hook="$WT_DIR/.claude/settings.local.json"
  assert_grep "FM_DESIGN_CONTEXT_HARD_LIMIT='4242'" "$hook" \
    "design Stop hook enforced the default ceiling despite an operator override"
  pass "design Stop hook pins the operator's context ceiling into the enforcing process"
}

# A malformed ceiling makes fm-design-context.sh exit before it writes any
# telemetry, so pinning one would remove the mechanical backstop rather than trip
# it. The spawn has to refuse before it leases anything.
test_design_spawn_refuses_a_malformed_context_ceiling() {
  local rec id out status
  id=profile-design-badceiling-z28
  rec=$(make_spawn_case profile-design-badceiling claude "$id")
  read_case_record "$rec"

  export FM_DESIGN_CONTEXT_HARD_LIMIT=110k
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --design)
  status=$?
  unset FM_DESIGN_CONTEXT_HARD_LIMIT
  expect_code 1 "$status" "a malformed ceiling override must refuse the design spawn"
  assert_contains "$out" "must be a positive integer" \
    "the ceiling refusal did not explain what it rejected"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused ceiling override still published task metadata"
  assert_absent "$WT_DIR/.claude/settings.local.json" \
    "a refused ceiling override still installed a Stop hook"
  pass "a malformed context ceiling refuses the spawn instead of disabling the backstop"
}

test_design_spawn_refuses_unverified_harness() {
  local rec id out status
  id=profile-design-refuse-z19
  rec=$(make_spawn_case profile-design-refuse codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --design)
  status=$?
  expect_code 1 "$status" "design spawn on an unverified harness should fail"
  assert_contains "$out" "--design currently requires harness=claude" \
    "design harness refusal did not explain its empirical boundary"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "unverified design harness refusal still published task metadata"
  pass "design spawn fails closed on a harness without invocation and context evidence"
}

# Regression: this repo VENDORS the nine design skills, so every firstmate
# worktree already carries .agents/skills/<skill> as a real tracked directory.
# The mount guard used to refuse any pre-existing real directory, which made
# --design and --prototype abort on a firstmate-repo target - the exact case the
# design profile exists to serve. A project that already carries the skill needs
# no mount; anything else occupying that path is still a genuine collision.
test_design_spawn_succeeds_on_a_target_that_already_carries_the_skills() {
  local rec id out status skill
  id=profile-design-selfrepo-z21
  rec=$(make_spawn_case profile-design-selfrepo claude "$id")
  read_case_record "$rec"

  # Make the target look like a firstmate checkout: its own committed copies,
  # each carrying the vendored marker that proves it IS the vendored skill.
  for skill in \
    ask-matt grilling grill-me batch-grill-me to-questionnaire handoff \
    to-spec domain-modeling prototype
  do
    mkdir -p "$WT_DIR/.agents/skills/$skill" "$WT_DIR/.claude/skills/$skill"
    printf 'source: https://github.com/mattpocock/skills\nproject-owned %s\n' "$skill" \
      > "$WT_DIR/.agents/skills/$skill/SKILL.md"
    printf 'source: https://github.com/mattpocock/skills\nproject-owned %s\n' "$skill" \
      > "$WT_DIR/.claude/skills/$skill/SKILL.md"
  done

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --design)
  status=$?
  expect_code 0 "$status" "design spawn must succeed when the target already carries the skills (got: $out)"
  assert_contains "$out" "spawned $id harness=claude kind=design" \
    "design spawn on a self-carrying target did not report kind=design"
  # The project's own copy is left untouched and stays loadable.
  assert_grep "project-owned grilling" "$WT_DIR/.agents/skills/grilling/SKILL.md" \
    "design spawn overwrote the project's own committed skill copy"
  # A path occupied by something that is NOT a skill is still a real collision.
  mkdir -p "$HOME_DIR/data/${id}b"
  printf 'brief for %sb\n' "$id" > "$HOME_DIR/data/${id}b/brief.md"
  rm -rf "$WT_DIR/.agents/skills/handoff"
  printf 'not a skill\n' > "$WT_DIR/.agents/skills/handoff"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "${id}b" "$PROJ_DIR" --harness claude --design)
  status=$?
  expect_code 1 "$status" "a non-skill file occupying a mount path must still refuse"
  assert_contains "$out" "collides with project path" \
    "genuine mount collision lost its diagnostic"
  pass "design spawn reuses a target's own skills and still refuses a foreign path"
}

# Regression: a staged mount is hidden from git and survives `treehouse return`,
# so nothing but a per-task record of what THIS spawn created can tell teardown
# which directories are safe to remove. A target that already carries the skills
# is staged nothing, and must therefore be recorded as nothing.
test_design_spawn_records_only_what_it_actually_staged() {
  local rec id ledger excl skill
  id=profile-design-ledger-z25
  rec=$(make_spawn_case profile-design-ledger claude "$id" "${id}b")
  read_case_record "$rec"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --design >/dev/null \
    || fail "design spawn should succeed"
  ledger="$HOME_DIR/state/$id.skill-mounts"
  excl=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  assert_present "$ledger" "design spawn did not record what it staged"
  for skill in \
    ask-matt grilling grill-me batch-grill-me to-questionnaire handoff \
    to-spec domain-modeling prototype
  do
    assert_grep $'mount\t.agents/skills/'"$skill" "$ledger" \
      "ledger lost the staged .agents mount for $skill"
    assert_grep $'exclude\towned\t'"$excl"$'\t.agents/skills/'"$skill" "$ledger" \
      "ledger lost the ignore line it added for $skill"
    assert_grep ".agents/skills/$skill" "$excl" \
      "staged mount $skill was never hidden from git"
  done

  # Round trip: the real cleanup owner consumes the real ledger this spawn wrote,
  # which is what teardown runs before the worktree goes back to its pool.
  bash -c '. "$1/bin/fm-skill-mount-lib.sh"; fm_skill_mount_cleanup "$2" "$3" "$4"' \
    _ "$ROOT" "$HOME_DIR/state" "$id" "$WT_DIR" \
    || fail "cleanup of the recorded design mounts failed"
  assert_absent "$ledger" "cleanup left the mount ledger behind"
  for skill in \
    ask-matt grilling grill-me batch-grill-me to-questionnaire handoff \
    to-spec domain-modeling prototype
  do
    assert_absent "$WT_DIR/.agents/skills/$skill" \
      "cleanup left the staged .agents mount for $skill behind"
    assert_absent "$WT_DIR/.claude/skills/$skill" \
      "cleanup left the staged Claude mount for $skill behind"
    assert_no_grep ".agents/skills/$skill" "$excl" \
      "cleanup left the ignore line for $skill in the shared git dir"
  done

  # The project's own vendored copies are skipped, so nothing is recorded and
  # teardown has no license to delete the project's committed content.
  for skill in \
    ask-matt grilling grill-me batch-grill-me to-questionnaire handoff \
    to-spec domain-modeling prototype
  do
    mkdir -p "$WT_DIR/.agents/skills/$skill" "$WT_DIR/.claude/skills/$skill"
    printf 'source: https://github.com/mattpocock/skills\nproject-owned %s\n' "$skill" \
      > "$WT_DIR/.agents/skills/$skill/SKILL.md"
    printf 'source: https://github.com/mattpocock/skills\nproject-owned %s\n' "$skill" \
      > "$WT_DIR/.claude/skills/$skill/SKILL.md"
  done
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "${id}b" "$PROJ_DIR" --harness claude --design >/dev/null \
    || fail "design spawn on a self-carrying target should succeed"
  assert_absent "$HOME_DIR/state/${id}b.skill-mounts" \
    "a spawn that staged nothing still claimed removable mounts"
  pass "a design spawn records exactly the mounts and ignore lines it created"
}

# The isolation assertion fires with the pooled worktree already leased and the
# backend window already open, and it exits before any meta exists - so the
# refusal itself has to hand both back.
test_isolation_refusal_releases_the_window_and_lease() {
  local rec id out status killlog thlog stray
  id=profile-isolation-refuse-z29
  rec=$(make_spawn_case profile-isolation-refuse claude "$id")
  read_case_record "$rec"

  # A real directory that is not a git worktree root: the pane settles there, so
  # the wait succeeds and validate_spawn_worktree is what refuses.
  stray="$CASE_DIR/not-a-worktree"
  mkdir -p "$stray"
  killlog="$CASE_DIR/kill.log"
  thlog="$CASE_DIR/treehouse.log"

  export FM_FAKE_KILL_LOG="$killlog" FM_FAKE_TREEHOUSE_LOG="$thlog"
  out=$(run_spawn "$HOME_DIR" "$stray" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude)
  status=$?
  unset FM_FAKE_KILL_LOG FM_FAKE_TREEHOUSE_LOG

  expect_code 1 "$status" "a non-worktree pane path must refuse the spawn"
  assert_contains "$out" "did not yield an isolated worktree" \
    "the isolation assertion lost its diagnostic"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the isolation refusal published task metadata"
  assert_grep "kill-window" "$killlog" \
    "the isolation refusal orphaned the backend window it had already opened"
  assert_grep "return --force $stray" "$thlog" \
    "the isolation refusal orphaned the worktree lease it had already taken"
  # The cleanup is armed BEFORE the assertion whose job is to catch a $WT that is
  # actually the primary checkout, so it must only ever return the resolved pane
  # path - never the project it was spawned against.
  assert_no_grep "return --force $PROJ_DIR\$" "$thlog" \
    "the abort path returned the primary checkout to a treehouse pool"
  pass "the isolation assertion gives back the window and lease it already took"
}

# Regression: a refused mount aborts before meta exists, so no teardown will ever
# run for that id. The attempt must leave nothing of its own behind - not the
# mounts and ignore lines, and not the worktree lease, window, or temp root it
# had already acquired by the time staging ran.
test_refused_mount_cleans_up_what_it_already_staged() {
  local rec id out status excl
  id=profile-design-refuse-cleanup-z26
  rec=$(make_spawn_case profile-design-refuse-cleanup claude "$id")
  read_case_record "$rec"

  # `to-spec` is staged after several successful mounts, so the refusal lands
  # mid-way through staging.
  mkdir -p "$WT_DIR/.agents/skills"
  printf 'not a skill\n' > "$WT_DIR/.agents/skills/to-spec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --design)
  status=$?
  expect_code 1 "$status" "a mid-staging collision must refuse"
  assert_contains "$out" "collides with project path" "refusal lost its diagnostic"
  excl=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  assert_absent "$HOME_DIR/state/$id.skill-mounts" \
    "a refused spawn left its mount ledger behind"
  assert_absent "$WT_DIR/.agents/skills/ask-matt" \
    "a refused spawn left an already-staged mount in the worktree"
  assert_no_grep ".agents/skills/ask-matt" "$excl" \
    "a refused spawn left its ignore lines in the project's shared git dir"
  assert_grep "not a skill" "$WT_DIR/.agents/skills/to-spec" \
    "cleanup after refusal touched the project's own path"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused spawn published task metadata"
  # Nothing names /tmp/fm-<id> once the refusal exits without meta, so the spawn
  # itself has to give the temp root back.
  assert_absent "/tmp/fm-$id" \
    "a refused spawn orphaned its per-task temp root"
  pass "a refused mount undoes the mounts, ignore lines, and lease it already took"
}

# Regression: the mounted names are generic (prototype, handoff, grilling), so a
# project shipping its OWN same-named skill must never silently shadow the
# vendored one. Presence of a SKILL.md is not proof; only the vendored marker is.
test_foreign_same_named_skill_refuses_instead_of_shadowing() {
  local rec id out status
  id=profile-design-foreign-z23
  rec=$(make_spawn_case profile-design-foreign claude "$id")
  read_case_record "$rec"

  # A project's own unrelated `prototype` skill - a real SKILL.md, no marker.
  mkdir -p "$WT_DIR/.agents/skills/prototype"
  printf -- '---\nname: prototype\n---\n\nThis project has its own prototype skill.\n' \
    > "$WT_DIR/.agents/skills/prototype/SKILL.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --design)
  status=$?
  expect_code 1 "$status" "a foreign same-named skill must refuse, not silently shadow the vendored one"
  assert_contains "$out" "collides with a different skill already at" \
    "foreign-skill refusal did not name the shadowing hazard"
  assert_grep "This project has its own prototype skill." \
    "$WT_DIR/.agents/skills/prototype/SKILL.md" \
    "refusal overwrote the project's own skill"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused foreign-skill spawn still published task metadata"
  pass "a foreign same-named skill refuses loudly instead of shadowing the vendored one"
}

# Regression: stage_skill_dir guarded only the leaf path, so a project whose
# skills ROOT is a symlink pointing outside the worktree would have nine
# directories written through the link. This repo itself ships
# `.claude/skills -> ../.agents/skills`, so symlinked roots are a live pattern.
test_skill_mount_root_outside_the_worktree_refuses() {
  local rec id out status outside
  id=profile-design-rootescape-z24
  rec=$(make_spawn_case profile-design-rootescape claude "$id")
  read_case_record "$rec"

  outside="$TMP_ROOT/outside-skills-root"
  mkdir -p "$outside"
  mkdir -p "$WT_DIR/.claude"
  ln -s "$outside" "$WT_DIR/.claude/skills"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --design)
  status=$?
  expect_code 1 "$status" "a skills root resolving outside the worktree must refuse"
  assert_contains "$out" "resolves outside the worktree" \
    "root-escape refusal did not explain the isolation boundary"
  [ -z "$(ls -A "$outside")" ] \
    || fail "staging wrote through the symlinked root to $outside"
  pass "a skills root outside the worktree refuses before anything is written"
}

# Regression: the mount was a symlink into $FM_ROOT/.agents/skills, so a write
# inside the disposable worktree reached the firstmate home's REAL skill files -
# an isolation break teardown cannot see, because the mount is git-excluded.
test_skill_mount_write_cannot_reach_the_firstmate_home() {
  local rec id status home_skill before
  id=profile-design-isolation-z22
  rec=$(make_spawn_case profile-design-isolation claude "$id")
  read_case_record "$rec"

  home_skill="$ROOT/.agents/skills/grilling/SKILL.md"
  before=$(cat "$home_skill")

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --design >/dev/null
  status=$?
  expect_code 0 "$status" "design spawn should succeed for the isolation check"

  printf 'CREWMATE WROTE THROUGH THE MOUNT\n' >> "$WT_DIR/.agents/skills/grilling/SKILL.md"
  [ "$(cat "$home_skill")" = "$before" ] \
    || fail "a write inside the worktree reached the firstmate home's real skill file"
  assert_no_grep "CREWMATE WROTE THROUGH THE MOUNT" "$home_skill" \
    "worktree write leaked into the firstmate home skill"
  pass "a write to a mounted skill cannot reach the firstmate home"
}

test_prototype_spawn_is_scout_profile_with_invocable_skill() {
  local rec id out status meta
  id=profile-prototype-z20
  rec=$(make_spawn_case profile-prototype claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --prototype)
  status=$?
  expect_code 0 "$status" "Claude prototype scout spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=scout" \
    "prototype spawn did not retain kind=scout"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "kind=scout" "$meta" "prototype spawn did not record scout kind"
  assert_grep "profile=prototype" "$meta" "prototype spawn did not record its profile"
  [ -f "$WT_DIR/.agents/skills/prototype/SKILL.md" ] \
    || fail "prototype scout did not mount the Agent Skills path"
  [ -L "$WT_DIR/.agents/skills/prototype" ] \
    && fail "prototype scout mounted the Agent Skills path as a writable symlink"
  [ -f "$WT_DIR/.claude/skills/prototype/SKILL.md" ] \
    || fail "prototype scout did not mount the Claude skill path"
  [ -L "$WT_DIR/.claude/skills/prototype" ] \
    && fail "prototype scout mounted the Claude skill path as a writable symlink"
  assert_absent "$WT_DIR/.agents/skills/ask-matt" \
    "prototype scout mounted the full design interview toolkit"
  assert_no_grep "fm-design-context.sh" "$WT_DIR/.claude/settings.local.json" \
    "prototype scout incorrectly inherited the design-session context hook"
  [ -z "$(git -C "$WT_DIR" status --short)" ] \
    || fail "prototype skill mounts or hook dirtied the isolated worktree"
  pass "prototype spawn remains kind=scout and mounts only its invocable skill"
}

test_no_profile_keeps_claude_profile_defaults
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_batch_forwards_shared_profile_flags
test_active_dispatch_profile_does_not_block_secondmate_launch
test_design_spawn_mounts_skills_records_kind_and_installs_backstop
test_design_hook_pins_the_operator_context_ceiling
test_design_spawn_refuses_a_malformed_context_ceiling
test_design_spawn_refuses_unverified_harness
test_design_spawn_succeeds_on_a_target_that_already_carries_the_skills
test_design_spawn_records_only_what_it_actually_staged
test_isolation_refusal_releases_the_window_and_lease
test_refused_mount_cleans_up_what_it_already_staged
test_foreign_same_named_skill_refuses_instead_of_shadowing
test_skill_mount_root_outside_the_worktree_refuses
test_skill_mount_write_cannot_reach_the_firstmate_home
test_prototype_spawn_is_scout_profile_with_invocable_skill

echo "# all fm-spawn-dispatch-profile tests passed"
