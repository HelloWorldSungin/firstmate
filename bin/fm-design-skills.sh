#!/usr/bin/env bash
# Resolve the installed mattpocock design-skill dependency for a Firstmate
# design task without installing, updating, copying, pinning, or modifying it.
# The captain owns plugin lifecycle through Claude's /plugin action.
#
# Usage:
#   fm-design-skills.sh resolve        print a JSON capability record
#   fm-design-skills.sh check          verify the required files and print one line
#
# The installed plugin registry is the identity owner for the active install
# path. The newest registry entry by lastUpdated is selected, then the two
# capability files the design profile requires are verified beneath that exact
# install root. Version strings are reported as evidence, never used as a pin:
# the profile depends on these capabilities rather than guessing which release
# first provided them.
#
# FM_MATTPOCOCK_PLUGIN_REGISTRY overrides the registry path for tests only.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  resolve|check) COMMAND=$1 ;;
  *) echo "usage: $(basename "$0") <resolve|check>" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to resolve the mattpocock design skills" >&2
  exit 1
}

REGISTRY=${FM_MATTPOCOCK_PLUGIN_REGISTRY:-${CLAUDE_CONFIG_DIR:-${HOME:?}/.claude}/plugins/installed_plugins.json}
[ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] || {
  echo "error: mattpocock plugin registry is unavailable at $REGISTRY; the captain must install or refresh it with /plugin" >&2
  exit 1
}

ENTRY=$(jq -cer '
  .plugins["mattpocock-skills@mattpocock"] // .["mattpocock-skills@mattpocock"] // []
  | map(select(.installPath | type == "string")
        | select(.installPath | length > 0)
        | select(.lastUpdated | type == "string"))
  | sort_by(.lastUpdated)
  | last
  | select(. != null)
  | {installPath, version: (.version // "unknown"), lastUpdated}
' "$REGISTRY" 2>/dev/null) || {
  echo "error: no active mattpocock-skills@mattpocock install is recorded; the captain must install or refresh it with /plugin" >&2
  exit 1
}

INSTALL_PATH=$(printf '%s\n' "$ENTRY" | jq -er '.installPath')
case "$INSTALL_PATH" in
  /*) ;;
  *) echo "error: mattpocock plugin registry contains a non-absolute install path" >&2; exit 1 ;;
esac
case "$INSTALL_PATH" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    echo "error: mattpocock plugin registry contains an unsafe install path" >&2
    exit 1
    ;;
esac
INSTALL_PATH=$(CDPATH='' cd -- "$INSTALL_PATH" 2>/dev/null && pwd -P) || {
  echo "error: recorded mattpocock plugin install is missing: $INSTALL_PATH; the captain must refresh it with /plugin" >&2
  exit 1
}

GRILLING="$INSTALL_PATH/skills/productivity/grilling/SKILL.md"
DOMAIN_MODELING="$INSTALL_PATH/skills/engineering/domain-modeling/SKILL.md"
for skill in "$GRILLING" "$DOMAIN_MODELING"; do
  [ -f "$skill" ] && [ ! -L "$skill" ] || {
    echo "error: installed mattpocock plugin lacks required design skill $skill; the captain must refresh it with /plugin" >&2
    exit 1
  }
done

VERSION=$(printf '%s\n' "$ENTRY" | jq -r '.version')
LAST_UPDATED=$(printf '%s\n' "$ENTRY" | jq -r '.lastUpdated')
if [ "$COMMAND" = check ]; then
  printf 'mattpocock design skills ready: version=%s updated=%s path=%s\n' \
    "$VERSION" "$LAST_UPDATED" "$INSTALL_PATH"
  exit 0
fi

jq -n \
  --arg install_path "$INSTALL_PATH" \
  --arg version "$VERSION" \
  --arg last_updated "$LAST_UPDATED" \
  --arg grilling "$GRILLING" \
  --arg domain_modeling "$DOMAIN_MODELING" \
  '{schema:"fm-design-skills.v1", plugin:"mattpocock-skills@mattpocock",
    install_path:$install_path, version:$version, last_updated:$last_updated,
    skills:{grilling:$grilling, domain_modeling:$domain_modeling}}'
