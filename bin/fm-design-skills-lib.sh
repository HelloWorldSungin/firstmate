#!/usr/bin/env bash

# Matches the durable manifest's free-text cap (FM_OUTCOME_TEXT_MAX in
# bin/fm-outcome-lib.sh), so a value recorded here can always be published.
DESIGN_SKILLS_FIELD_MAX=240
# Collapses to the same single-line, trimmed, capped shape the durable manifest
# applies, so the emptiness check below sees exactly what would be published.
design_skills_field() {  # <resolve-json> <field> -> one meta-safe line
  printf '%s\n' "$1" \
    | jq -r --arg field "$2" '.[$field] // ""' \
    | tr -d '\000-\037\177' \
    | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' \
    | cut -c "1-$DESIGN_SKILLS_FIELD_MAX"
}
design_skill_path() {  # <resolve-json> <skill-key> -> exact absolute path
  printf '%s\n' "$1" \
    | jq -er --arg skill "$2" '.skills[$skill] | select(type == "string" and length > 0)'
}
design_skill_path_is_safe() {  # <path>
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  [ "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')" = "$1" ]
}
# adopt_relaunch_design_skills: reuse the dispatch pin already recorded for
# this design task. Never call fm-design-skills.sh resolve here; a later
# plugin auto-update must not silently rebind the interview.
adopt_relaunch_design_skills() {
  local RELAUNCH_META=$1 ID=$2
  local recorded_plugin recorded_version recorded_updated tasktmp dispatch_brief
  local binding schema
  recorded_plugin=$(fm_meta_get "$RELAUNCH_META" design_skills_plugin)
  recorded_version=$(fm_meta_get "$RELAUNCH_META" design_skills_version)
  recorded_updated=$(fm_meta_get "$RELAUNCH_META" design_skills_updated)
  if [ -z "$recorded_plugin" ] || [ -z "$recorded_version" ] \
    || [ -z "$recorded_updated" ]; then
    echo "error: task $ID has no recorded design-skill release; refusing to relaunch rather than resolving a different plugin pin" >&2
    return 1
  fi
  tasktmp=$(fm_meta_get "$RELAUNCH_META" tasktmp)
  [ -n "$tasktmp" ] || tasktmp="/tmp/fm-$ID"
  dispatch_brief="$tasktmp/brief.md"
  if [ ! -f "$dispatch_brief" ] || [ -L "$dispatch_brief" ] || [ ! -r "$dispatch_brief" ]; then
    echo "error: task $ID has no dispatch-pinned design brief at $dispatch_brief; refusing to relaunch rather than resolving a different plugin release" >&2
    return 1
  fi
  binding=$(sed -n '/^```json$/{n;p;q;}' "$dispatch_brief")
  schema=$(printf '%s\n' "$binding" | jq -r '.schema // empty' 2>/dev/null) || schema=
  [ "$schema" = fm-design-skills.dispatch.v1 ] || {
    echo "error: task $ID's dispatch-pinned design brief is not a usable skill binding; refusing to relaunch rather than resolving a different plugin release" >&2
    return 1
  }
  DESIGN_SKILLS_PLUGIN=$(design_skills_field "$binding" plugin)
  DESIGN_SKILLS_VERSION=$(design_skills_field "$binding" version)
  DESIGN_SKILLS_UPDATED=$(design_skills_field "$binding" last_updated)
  DESIGN_SKILLS_GRILLING=$(design_skill_path "$binding" grilling) || DESIGN_SKILLS_GRILLING=
  DESIGN_SKILLS_DOMAIN_MODELING=$(design_skill_path "$binding" domain_modeling) || DESIGN_SKILLS_DOMAIN_MODELING=
  if [ "$DESIGN_SKILLS_PLUGIN" != "$recorded_plugin" ] \
    || [ "$DESIGN_SKILLS_VERSION" != "$recorded_version" ] \
    || [ "$DESIGN_SKILLS_UPDATED" != "$recorded_updated" ] \
    || ! design_skill_path_is_safe "$DESIGN_SKILLS_GRILLING" \
    || ! design_skill_path_is_safe "$DESIGN_SKILLS_DOMAIN_MODELING"; then
    echo "error: task $ID's dispatch-pinned design skills do not match its recorded release; refusing to relaunch rather than substituting another plugin pin" >&2
    return 1
  fi
  design_skill_files_readable
}

design_skill_files_readable() {
  if [ ! -f "$DESIGN_SKILLS_GRILLING" ] || [ -L "$DESIGN_SKILLS_GRILLING" ] \
    || [ ! -r "$DESIGN_SKILLS_GRILLING" ] \
    || [ ! -f "$DESIGN_SKILLS_DOMAIN_MODELING" ] || [ -L "$DESIGN_SKILLS_DOMAIN_MODELING" ] \
    || [ ! -r "$DESIGN_SKILLS_DOMAIN_MODELING" ]; then
    echo "error: a dispatch-pinned mattpocock design skill path disappeared or became unreadable after resolution; refusing instead of silently resolving a different plugin release" >&2
    return 1
  fi
}
