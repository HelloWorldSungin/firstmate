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

test_resolve_uses_registry_capabilities_without_writing_plugin
test_check_refuses_missing_capability
test_missing_registry_is_actionable
test_resolve_and_check_keep_existing_v1_contract
test_resolve_reports_ask_matt
test_resolve_named_skill_by_directory_name
test_resolve_unknown_skill_names_what_was_looked_for
fm_test_every_defined_test_ran
printf '\nall fm-design-skills tests passed\n'
