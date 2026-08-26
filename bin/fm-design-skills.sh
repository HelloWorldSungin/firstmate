#!/usr/bin/env bash
# Resolve named skills from the installed mattpocock plugin for a Firstmate
# design task without installing, updating, copying, pinning, or modifying it.
# The captain owns plugin lifecycle through Claude's /plugin action.
#
# Usage:
#   fm-design-skills.sh resolve [skill-name...]
#       print a JSON capability record
#   fm-design-skills.sh check
#       verify the required files and print one line
#
# The installed plugin registry is the identity owner for the active install
# path. The newest registry entry by lastUpdated is selected, then named
# skill files are looked up beneath that exact install root. Version strings
# are reported as evidence, never used as a pin: the profile depends on
# these capabilities rather than guessing which release first provided them.
#
# resolve always reports grilling, domain_modeling, and ask_matt.
# Additional skill-name arguments are looked up by directory name under the
# install's skills/ tree. Hyphens and underscores are equivalent.
# A name the plugin does not contain is a refusal that names what was
# looked for, never an empty path or a silently absent key.
#
# FM_MATTPOCOCK_PLUGIN_REGISTRY overrides the registry path for tests only.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  resolve|check) COMMAND=$1; shift ;;
  *) echo "usage: $(basename "$0") <resolve|check> [skill-name...]" >&2; exit 2 ;;
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

skill_dir_name() {
  printf '%s' "${1//_/-}"
}

skill_json_key() {
  local hyphenated
  hyphenated=$(skill_dir_name "$1")
  printf '%s' "${hyphenated//-/_}"
}

validate_skill_name() {
  local requested=$1
  [[ "$requested" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || {
    echo "error: skill name must be a simple identifier: $requested" >&2
    return 1
  }
}

lookup_skill_path() {
  local requested=$1
  local name candidate found="" count=0
  name=$(skill_dir_name "$requested")
  for candidate in "$INSTALL_PATH/skills/"*"/$name/SKILL.md"; do
    if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
      found=$candidate
      count=$((count + 1))
    fi
  done
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$found"
    return 0
  fi
  if [ "$count" -gt 1 ]; then
    echo "error: installed mattpocock plugin has multiple skills named $name" >&2
    return 1
  fi
  return 1
}

SKILLS_JSON='{}'

add_skill_record() {
  local requested=$1 path=$2 key
  key=$(skill_json_key "$requested")
  SKILLS_JSON=$(jq -cn --argjson acc "$SKILLS_JSON" --arg k "$key" --arg v "$path" '$acc + {($k): $v}')
}

skill_path=
for required in grilling domain-modeling ask-matt; do
  if ! skill_path=$(lookup_skill_path "$required"); then
    echo "error: installed mattpocock plugin lacks required design skill $required; the captain must refresh it with /plugin" >&2
    exit 1
  fi
  add_skill_record "$required" "$skill_path"
done

VERSION=$(printf '%s\n' "$ENTRY" | jq -r '.version')
LAST_UPDATED=$(printf '%s\n' "$ENTRY" | jq -r '.lastUpdated')

if [ "$COMMAND" = check ]; then
  printf 'mattpocock design skills ready: version=%s updated=%s path=%s\n' \
    "$VERSION" "$LAST_UPDATED" "$INSTALL_PATH"
  exit 0
fi

for requested in "$@"; do
  validate_skill_name "$requested" || exit 1
  if ! skill_path=$(lookup_skill_path "$requested"); then
    echo "error: installed mattpocock plugin has no skill named $requested" >&2
    exit 1
  fi
  add_skill_record "$requested" "$skill_path"
done

jq -n \
  --arg install_path "$INSTALL_PATH" \
  --arg version "$VERSION" \
  --arg last_updated "$LAST_UPDATED" \
  --argjson skills "$SKILLS_JSON" \
  '{schema:"fm-design-skills.v1", plugin:"mattpocock-skills@mattpocock",
    install_path:$install_path, version:$version, last_updated:$last_updated,
    skills:$skills}'
