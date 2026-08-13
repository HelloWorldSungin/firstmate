#!/usr/bin/env bash
# Behavior tests for bin/fm-design-skills.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-design-skills)
RESOLVER="$ROOT/bin/fm-design-skills.sh"

make_install() {
  local root=$1 marker=$2
  mkdir -p "$root/skills/productivity/grilling" "$root/skills/engineering/domain-modeling"
  printf '%s\n' "$marker grilling" > "$root/skills/productivity/grilling/SKILL.md"
  printf '%s\n' "$marker domain" > "$root/skills/engineering/domain-modeling/SKILL.md"
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

test_resolve_uses_registry_capabilities_without_writing_plugin
test_check_refuses_missing_capability
test_missing_registry_is_actionable
printf '\nall fm-design-skills tests passed\n'
