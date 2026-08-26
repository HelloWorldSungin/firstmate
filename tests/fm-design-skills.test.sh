#!/usr/bin/env bash
# Behavior tests for bin/fm-design-skills.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-design-skills)
RESOLVER="$ROOT/bin/fm-design-skills.sh"

add_skill() {
  local root=$1 category=$2 name=$3 body=$4
  mkdir -p "$root/skills/$category/$name"
  printf '%s\n' "$body" > "$root/skills/$category/$name/SKILL.md"
}

make_install() {
  local root=$1 marker=$2
  add_skill "$root" productivity grilling "$marker grilling"
  add_skill "$root" engineering domain-modeling "$marker domain"
  add_skill "$root" engineering ask-matt "$marker ask-matt"
}

write_registry() {
  local path=$1 old=$2 current=$3
  mkdir -p "$(dirname "$path")"
  jq -n --arg old "$old" --arg current "$current" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$old,version:"1.0.0",lastUpdated:"2026-01-01T00:00:00Z"},
      {scope:"user",installPath:$current,version:"1.2.0",lastUpdated:"2026-08-01T00:00:00Z"}
    ]}}' > "$path"
}

test_resolve_uses_registry_capabilities_without_writing_plugin() {
  local old current registry before after out
  old="$TMP_ROOT/old"
  current="$TMP_ROOT/current"
  registry="$TMP_ROOT/config/plugins/installed_plugins.json"
  make_install "$old" old
  make_install "$current" current
  write_registry "$registry" "$old" "$current"
  before=$(find "$old" "$current" -type f -print0 | sort -z | xargs -0 sha256sum)

  out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" "$RESOLVER" resolve) \
    || fail "resolver refused a complete installed plugin"
  [ "$(printf '%s\n' "$out" | jq -r '.schema')" = fm-design-skills.v1 ] \
    || fail "resolver emitted the wrong schema"
  [ "$(printf '%s\n' "$out" | jq -r '.install_path')" = "$current" ] \
    || fail "resolver did not select the latest active registry entry"
  [ "$(printf '%s\n' "$out" | jq -r '.skills.grilling')" = "$current/skills/productivity/grilling/SKILL.md" ] \
    || fail "resolver returned the wrong grilling skill"
  [ "$(printf '%s\n' "$out" | jq -r '.skills.domain_modeling')" = "$current/skills/engineering/domain-modeling/SKILL.md" ] \
    || fail "resolver returned the wrong domain-modeling skill"

  after=$(find "$old" "$current" -type f -print0 | sort -z | xargs -0 sha256sum)
  [ "$after" = "$before" ] || fail "resolver modified the installed plugin"
  pass "design skill resolver reads the active plugin capabilities without modifying them"
}

test_check_refuses_missing_capability() {
  local install registry out rc
  install="$TMP_ROOT/incomplete"
  registry="$TMP_ROOT/incomplete-registry.json"
  mkdir -p "$install/skills/productivity/grilling"
  printf 'grilling\n' > "$install/skills/productivity/grilling/SKILL.md"
  jq -n --arg install "$install" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$install,version:"1.2.0",lastUpdated:"2026-08-01T00:00:00Z"}
    ]}}' > "$registry"

  out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" "$RESOLVER" check 2>&1)
  rc=$?
  expect_code 1 "$rc" "resolver should refuse a plugin missing domain-modeling"
  assert_contains "$out" "lacks required design skill" \
    "resolver did not name the missing capability"
  assert_contains "$out" "captain must refresh it with /plugin" \
    "resolver did not preserve captain-owned plugin lifecycle"
  pass "design skill resolver refuses an incomplete plugin without working around it"
}

test_missing_registry_is_actionable() {
  local out rc
  out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$TMP_ROOT/absent.json" "$RESOLVER" resolve 2>&1)
  rc=$?
  expect_code 1 "$rc" "resolver should refuse an absent plugin registry"
  assert_contains "$out" "captain must install or refresh it with /plugin" \
    "absent-registry refusal did not name the owner action"
  pass "design skill resolver reports the captain-owned dependency action"
}

write_single_registry() {
  local path=$1 install=$2
  jq -n --arg install "$install" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$install,version:"1.2.0",lastUpdated:"2026-08-01T00:00:00Z"}
    ]}}' > "$path"
}

test_resolve_and_check_keep_existing_v1_contract() {
  local current registry out check_out
  current="$TMP_ROOT/compat"
  registry="$TMP_ROOT/compat-registry.json"
  make_install "$current" compat
  write_single_registry "$registry" "$current"

  out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" "$RESOLVER" resolve) \
    || fail "compat resolve refused a complete installed plugin"
  [ "$(printf '%s\n' "$out" | jq -r '.schema')" = fm-design-skills.v1 ] \
    || fail "compat resolve changed schema away from fm-design-skills.v1"
  [ "$(printf '%s\n' "$out" | jq -r '.skills.grilling')" = "$current/skills/productivity/grilling/SKILL.md" ] \
    || fail "compat resolve lost skills.grilling"
  [ "$(printf '%s\n' "$out" | jq -r '.skills.domain_modeling')" = "$current/skills/engineering/domain-modeling/SKILL.md" ] \
    || fail "compat resolve lost skills.domain_modeling"

  check_out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" "$RESOLVER" check) \
    || fail "compat check refused a complete installed plugin"
  [ "$check_out" = "mattpocock design skills ready: version=1.2.0 updated=2026-08-01T00:00:00Z path=$current" ] \
    || fail "compat check output changed: $check_out"
  pass "resolve and check keep the v1 schema, grilling and domain_modeling keys, and check line"
}

test_resolve_reports_ask_matt() {
  local current registry out
  current="$TMP_ROOT/ask-matt"
  registry="$TMP_ROOT/ask-matt-registry.json"
  make_install "$current" router
  write_single_registry "$registry" "$current"

  out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" "$RESOLVER" resolve) \
    || fail "resolve refused a plugin that contains ask-matt"
  [ "$(printf '%s\n' "$out" | jq -r '.skills.ask_matt')" = "$current/skills/engineering/ask-matt/SKILL.md" ] \
    || fail "resolve did not report skills.ask_matt"
  pass "resolve reports the ask-matt router path"
}

test_resolve_named_skill_by_directory_name() {
  local current registry out
  current="$TMP_ROOT/named"
  registry="$TMP_ROOT/named-registry.json"
  make_install "$current" named
  add_skill "$current" engineering grill-with-docs "grill-with-docs"
  write_single_registry "$registry" "$current"

  out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" "$RESOLVER" resolve grill-with-docs) \
    || fail "resolve refused a named skill the plugin contains"
  [ "$(printf '%s\n' "$out" | jq -r '.skills.grill_with_docs')" = "$current/skills/engineering/grill-with-docs/SKILL.md" ] \
    || fail "resolve did not return the named skill path"
  [ "$(printf '%s\n' "$out" | jq -r '.skills.grilling')" = "$current/skills/productivity/grilling/SKILL.md" ] \
    || fail "named-skill resolve dropped skills.grilling"
  [ "$(printf '%s\n' "$out" | jq -r '.skills.domain_modeling')" = "$current/skills/engineering/domain-modeling/SKILL.md" ] \
    || fail "named-skill resolve dropped skills.domain_modeling"
  [ "$(printf '%s\n' "$out" | jq -r '.skills.ask_matt')" = "$current/skills/engineering/ask-matt/SKILL.md" ] \
    || fail "named-skill resolve dropped skills.ask_matt"
  pass "resolve looks up an extra named skill by directory name"
}

test_resolve_unknown_skill_names_what_was_looked_for() {
  local current registry out rc
  current="$TMP_ROOT/unknown"
  registry="$TMP_ROOT/unknown-registry.json"
  make_install "$current" unknown
  write_single_registry "$registry" "$current"

  out=$(FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" "$RESOLVER" resolve no-such-skill 2>&1)
  rc=$?
  expect_code 1 "$rc" "resolve should refuse a skill the plugin does not contain"
  assert_contains "$out" "no-such-skill" \
    "unknown-skill refusal did not name what was looked for"
  printf '%s\n' "$out" | jq -e '.skills | has("no_such_skill")' >/dev/null 2>&1 \
    && fail "unknown-skill refusal emitted a no_such_skill key instead of refusing"
  assert_not_contains "$out" '"no_such_skill": ""' \
    "unknown-skill refusal must not emit an empty path"
  pass "resolve refuses an unknown skill by name rather than emitting an empty key"
}


# --- dispatch-time provenance -----------------------------------------------

SPAWN="$ROOT/bin/fm-spawn.sh"

# A home, a real git worktree, and fakes for everything a design spawn shells
# out to, so the spawn runs end to end and writes real task metadata.
# Echoes "<home>|<project>|<worktree>|<fakebin>".
make_spawn_case() {  # <name>
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

write_design_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  printf 'design brief\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' \
    > "$1/data/$2/brief.md"
}

run_design_spawn() {  # <home> <worktree> <fakebin> <registry> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 registry=$4
  shift 4
  FM_ROOT_OVERRIDE="${FM_SPAWN_ROOT:-}" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_MATTPOCOCK_PLUGIN_REGISTRY="$registry" \
    FM_FAKE_DESIGN_RESOLVE_COUNT="${FM_FAKE_DESIGN_RESOLVE_COUNT:-}" \
    FM_FAKE_DESIGN_PLUGIN_ONE="${FM_FAKE_DESIGN_PLUGIN_ONE:-}" \
    FM_FAKE_DESIGN_PLUGIN_TWO="${FM_FAKE_DESIGN_PLUGIN_TWO:-}" \
    FM_FAKE_DESIGN_DELETE="${FM_FAKE_DESIGN_DELETE:-0}" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --design --mode no-mistakes --yolo off 2>&1
}

meta_field() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

make_spawn_root_with_counting_resolver() {  # <root>
  local fake_root=$1 source name
  mkdir -p "$fake_root/bin"
  for source in "$ROOT"/bin/*; do
    [ -f "$source" ] || continue
    name=$(basename "$source")
    [ "$name" = fm-design-skills.sh ] && continue
    ln -s "$source" "$fake_root/bin/$name"
  done
  cat > "$fake_root/bin/fm-design-skills.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = resolve ] || exit 2
count=0
[ ! -f "$FM_FAKE_DESIGN_RESOLVE_COUNT" ] \
  || read -r count < "$FM_FAKE_DESIGN_RESOLVE_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_DESIGN_RESOLVE_COUNT"
if [ "$count" -eq 1 ]; then
  plugin=$FM_FAKE_DESIGN_PLUGIN_ONE
  version=1.2.0
  updated=2026-08-01T00:00:00Z
else
  plugin=$FM_FAKE_DESIGN_PLUGIN_TWO
  version=9.9.9
  updated=2026-08-26T09:15:00Z
fi
jq -n \
  --arg plugin "$plugin" --arg version "$version" --arg updated "$updated" \
  '{schema:"fm-design-skills.v1", plugin:"mattpocock-skills@mattpocock",
    install_path:$plugin, version:$version, last_updated:$updated,
    skills:{grilling:($plugin + "/skills/productivity/grilling/SKILL.md"),
      domain_modeling:($plugin + "/skills/engineering/domain-modeling/SKILL.md"),
      ask_matt:($plugin + "/skills/engineering/ask-matt/SKILL.md")}}'
if [ "$FM_FAKE_DESIGN_DELETE" = 1 ]; then
  rm -f "$plugin/skills/productivity/grilling/SKILL.md" \
    "$plugin/skills/engineering/domain-modeling/SKILL.md"
fi
SH
  chmod +x "$fake_root/bin/fm-design-skills.sh"
}

# The plugin auto-updates, so the release behind one design result need not be
# the release behind the next. The dispatch is the only moment that can observe
# the one the interview will actually read: by cleanup the plugin may have moved,
# and recording the wrong release is worse than recording none.
test_design_dispatch_records_the_release_it_resolved() {
  local rec home proj wt fakebin registry install meta out

  rec=$(make_spawn_case record)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  install="$TMP_ROOT/spawn-record/plugin-1"
  registry="$TMP_ROOT/spawn-record/registry.json"
  make_install "$install" first
  write_single_registry "$registry" "$install"
  write_design_brief "$home" design-one

  out=$(run_design_spawn "$home" "$wt" "$fakebin" "$registry" design-one "$proj") \
    || fail "design spawn failed: $out"
  meta="$home/state/design-one.meta"
  [ -f "$meta" ] || fail "design spawn wrote no task metadata: $out"
  [ "$(meta_field "$meta" design_skills_plugin)" = "mattpocock-skills@mattpocock" ] \
    || fail "dispatch did not record which plugin informed the design task"
  [ "$(meta_field "$meta" design_skills_version)" = "1.2.0" ] \
    || fail "dispatch did not record the resolved plugin version"
  [ "$(meta_field "$meta" design_skills_updated)" = "2026-08-01T00:00:00Z" ] \
    || fail "dispatch did not record the resolved plugin update stamp"

  # The recorded value must track the plugin as it is at each dispatch, not a
  # constant baked in at the first one - that is the whole traceability claim.
  install="$TMP_ROOT/spawn-record/plugin-2"
  make_install "$install" second
  jq -n --arg install "$install" '{plugins:{
    "mattpocock-skills@mattpocock":[
      {scope:"user",installPath:$install,version:"9.9.9",lastUpdated:"2026-08-26T09:15:00Z"}
    ]}}' > "$registry"
  write_design_brief "$home" design-two

  out=$(run_design_spawn "$home" "$wt" "$fakebin" "$registry" design-two "$proj") \
    || fail "second design spawn failed: $out"
  meta="$home/state/design-two.meta"
  [ "$(meta_field "$meta" design_skills_version)" = "9.9.9" ] \
    || fail "a later dispatch recorded a stale plugin version"
  [ "$(meta_field "$home/state/design-one.meta" design_skills_version)" = "1.2.0" ] \
    || fail "the plugin moving rewrote an earlier design task's recorded version"
  pass "each design dispatch records the plugin release it resolved at that dispatch"
}

test_design_dispatch_binds_one_resolve_to_metadata_and_brief() {
  local rec home proj wt fakebin fake_root count_file plugin_one plugin_two registry
  local out meta dispatch_brief binding
  rec=$(make_spawn_case binding)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  fake_root="$TMP_ROOT/spawn-binding/root"
  count_file="$TMP_ROOT/spawn-binding/resolve-count"
  plugin_one="$TMP_ROOT/spawn-binding/plugin-1"
  plugin_two="$TMP_ROOT/spawn-binding/plugin-2"
  registry="$TMP_ROOT/spawn-binding/unused-registry.json"
  make_install "$plugin_one" first
  make_install "$plugin_two" second
  make_spawn_root_with_counting_resolver "$fake_root"
  write_design_brief "$home" design-binding
  cat >> "$home/data/design-binding/brief.md" <<EOF
Run \`$ROOT/bin/fm-design-skills.sh resolve\`, then use your read tool to load the exact \`grilling\` and \`domain_modeling\` skill paths in its JSON output.
This direct file-resolution contract is identical on Claude, Codex, and Pi and does not depend on harness-specific skill-command spelling.
EOF

  out=$(FM_SPAWN_ROOT="$fake_root" \
    FM_FAKE_DESIGN_RESOLVE_COUNT="$count_file" \
    FM_FAKE_DESIGN_PLUGIN_ONE="$plugin_one" \
    FM_FAKE_DESIGN_PLUGIN_TWO="$plugin_two" \
    run_design_spawn "$home" "$wt" "$fakebin" "$registry" design-binding "$proj") \
    || fail "design spawn with a moving resolver failed: $out"
  meta="$home/state/design-binding.meta"
  dispatch_brief="$(meta_field "$meta" tasktmp)/brief.md"
  [ "$(cat "$count_file")" = 1 ] \
    || fail "design dispatch resolved the auto-updating plugin more than once"
  [ "$(meta_field "$meta" design_skills_version)" = 1.2.0 ] \
    || fail "task metadata did not record the single resolver result"
  [ -f "$dispatch_brief" ] \
    || fail "design spawn did not publish a worker-facing dispatch brief"
  binding=$(sed -n '/^```json$/{n;p;q;}' "$dispatch_brief")
  [ "$(printf '%s\n' "$binding" | jq -r '.version')" = 1.2.0 ] \
    || fail "worker-facing brief did not carry the recorded resolver version"
  [ "$(printf '%s\n' "$binding" | jq -r '.skills.grilling')" \
      = "$plugin_one/skills/productivity/grilling/SKILL.md" ] \
    || fail "worker-facing brief did not carry the grilling path from the recorded resolve"
  [ "$(printf '%s\n' "$binding" | jq -r '.skills.domain_modeling')" \
      = "$plugin_one/skills/engineering/domain-modeling/SKILL.md" ] \
    || fail "worker-facing brief did not carry the domain-modeling path from the recorded resolve"
  assert_not_contains "$(cat "$dispatch_brief")" "then use your read tool" \
    "worker-facing brief retained the legacy instruction to resolve the plugin again"
  assert_not_contains "$(cat "$dispatch_brief")" "$plugin_two" \
    "worker-facing brief silently moved to a later resolver result"
  pass "one resolver result supplies both recorded provenance and pinned brief paths"
}

test_design_dispatch_refuses_a_missing_pinned_path() {
  local rec home proj wt fakebin fake_root count_file plugin_one plugin_two registry out status
  rec=$(make_spawn_case missing-pin)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  fake_root="$TMP_ROOT/spawn-missing-pin/root"
  count_file="$TMP_ROOT/spawn-missing-pin/resolve-count"
  plugin_one="$TMP_ROOT/spawn-missing-pin/plugin-1"
  plugin_two="$TMP_ROOT/spawn-missing-pin/plugin-2"
  registry="$TMP_ROOT/spawn-missing-pin/unused-registry.json"
  make_install "$plugin_one" first
  make_install "$plugin_two" second
  make_spawn_root_with_counting_resolver "$fake_root"
  write_design_brief "$home" design-missing-pin

  out=$(FM_SPAWN_ROOT="$fake_root" \
    FM_FAKE_DESIGN_RESOLVE_COUNT="$count_file" \
    FM_FAKE_DESIGN_PLUGIN_ONE="$plugin_one" \
    FM_FAKE_DESIGN_PLUGIN_TWO="$plugin_two" \
    FM_FAKE_DESIGN_DELETE=1 \
    run_design_spawn "$home" "$wt" "$fakebin" "$registry" design-missing-pin "$proj")
  status=$?
  expect_code 1 "$status" "design spawn should refuse a vanished dispatch-pinned path"
  assert_contains "$out" "dispatch-pinned mattpocock design skill path disappeared" \
    "missing pinned path did not stop loudly at dispatch"
  [ "$(cat "$count_file")" = 1 ] \
    || fail "missing pinned path triggered a silent re-resolve"
  assert_absent "$home/state/design-missing-pin.meta" \
    "design spawn recorded metadata after its pinned path disappeared"
  pass "a missing pinned path refuses instead of resolving another release"
}

# A ship task never reads those skills, so it must not resolve them, record
# them, or be blocked when the plugin is absent.
test_ship_dispatch_records_no_release() {
  local rec home proj wt fakebin meta out
  rec=$(make_spawn_case ship)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  write_design_brief "$home" ship-one

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_MATTPOCOCK_PLUGIN_REGISTRY="$TMP_ROOT/spawn-ship/absent.json" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" ship-one "$proj" --mode no-mistakes --yolo off 2>&1) \
    || fail "ship spawn failed with no plugin installed: $out"
  meta="$home/state/ship-one.meta"
  [ -f "$meta" ] || fail "ship spawn wrote no task metadata: $out"
  ! grep -q '^design_skills_' "$meta" \
    || fail "a ship task recorded a design plugin release it never read"
  pass "a non-design dispatch neither resolves nor records the design plugin"
}

# The dispatch gate and the provenance record are the same resolve call, so a
# refusal must still name the captain-owned fix rather than dispatching a design
# task whose inputs nothing recorded.
test_design_dispatch_refuses_an_unresolvable_plugin() {
  local rec home proj wt fakebin out status
  rec=$(make_spawn_case refuse)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  write_design_brief "$home" design-refused

  out=$(run_design_spawn "$home" "$wt" "$fakebin" \
    "$TMP_ROOT/spawn-refuse/absent.json" design-refused "$proj")
  status=$?
  expect_code 1 "$status" "a design spawn should refuse an unresolvable plugin"
  assert_contains "$out" "captain must install or refresh it with /plugin" \
    "the refusal did not preserve captain-owned plugin lifecycle"
  assert_absent "$home/state/design-refused.meta" \
    "a design task was dispatched without recording which plugin informed it"
  pass "a design dispatch refuses rather than launching an untraceable interview"
}

test_resolve_uses_registry_capabilities_without_writing_plugin
test_check_refuses_missing_capability
test_missing_registry_is_actionable
test_resolve_and_check_keep_existing_v1_contract
test_resolve_reports_ask_matt
test_resolve_named_skill_by_directory_name
test_resolve_unknown_skill_names_what_was_looked_for
test_design_dispatch_records_the_release_it_resolved
test_design_dispatch_binds_one_resolve_to_metadata_and_brief
test_design_dispatch_refuses_a_missing_pinned_path
test_ship_dispatch_records_no_release
test_design_dispatch_refuses_an_unresolvable_plugin
fm_test_every_defined_test_ran
printf '\nall fm-design-skills tests passed\n'
