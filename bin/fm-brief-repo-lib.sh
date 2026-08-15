#!/usr/bin/env bash
# fm-brief-repo-lib.sh - detect when a crewmate task's project checkout is the
# firstmate repository itself.
#
# fm-brief.sh uses this to emit role-confusion guidance for ship, design, and
# scout scaffolds only. The REPO name selects a checkout candidate, but only a
# git-common-dir match with FM_ROOT decides the final firstmate-repo verdict.
#
# Sourced by bin/fm-brief.sh, bin/fm-issue-ref.sh, and tests. No side effects
# on source.

_FM_BRIEF_REPO_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) \
  || _FM_BRIEF_REPO_LIB_DIR=.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$_FM_BRIEF_REPO_LIB_DIR/fm-primary-scope-lib.sh"

# fm_brief_repo_home_root_clone_name: print the canonical registry name when
# FM_HOME and FM_ROOT share a git object database, otherwise return 1.
# docs/configuration.md owns the canonical `firstmate` name and home layout.
fm_brief_repo_home_root_clone_name() {
  local root_common home_common
  root_common=$(git -C "${FM_ROOT:-}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  home_common=$(git -C "${FM_HOME:-}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$root_common" = "$home_common" ] || return 1
  printf '%s\n' firstmate
}

# fm_brief_repo_registers_home_root_clone: return 0 when the passed name
# matches the structurally detected home-root clone name.
fm_brief_repo_registers_home_root_clone() {
  local name=$1 home_root_name
  home_root_name=$(fm_brief_repo_home_root_clone_name 2>/dev/null) || return 1
  [ "$name" = "$home_root_name" ]
}

# fm_brief_repo_home_root_is_candidate: return 0 when the home root may be
# tried as a name's checkout. A structural `firstmate` match or a genuine
# secondmate-home marker may select the candidate; fm_brief_task_repo_is_firstmate
# still owns the final git object-database verdict.
fm_brief_repo_home_root_is_candidate() {
  local repo=$1
  if [ "$(fm_brief_repo_home_root_clone_name 2>/dev/null)" = "$repo" ]; then
    return 0
  fi
  fm_root_is_secondmate_home "${FM_HOME:-}"
}

# fm_brief_repo_resolve_project_name: return the canonical registry name for
# a structurally verified home-root path. Return other names and paths unchanged.
fm_brief_repo_resolve_project_name() {
  local project=$1 home_root_name fm_home_abs project_abs
  home_root_name=$(fm_brief_repo_home_root_clone_name 2>/dev/null) || true
  if [ -n "$home_root_name" ]; then
    fm_home_abs=$(CDPATH='' cd -- "${FM_HOME:-}" 2>/dev/null && pwd -P) || true
    project_abs=$(CDPATH='' cd -- "$project" 2>/dev/null && pwd -P) || true
    if [ -n "$fm_home_abs" ] && [ -n "$project_abs" ] && [ "$fm_home_abs" = "$project_abs" ]; then
      printf '%s\n' "$home_root_name"
      return 0
    fi
  fi
  printf '%s\n' "$project"
}

# fm_brief_resolve_project_dir: print the resolved project directory for a brief
# REPO argument, or return 1 when it cannot be resolved to an existing directory.
#
# Firstmate is the one project whose checkout is the home itself rather than a
# clone under projects/ (docs/configuration.md), so a name the home may hold
# gets the home root as a last lookup candidate; without it the canonical
# `fm-brief.sh <id> firstmate` resolves nowhere and the comparison below never
# runs. The candidate only says where to look; git-common-dir stays the sole
# authority on the verdict, so a home that is not a firstmate checkout is
# rejected there however it was selected.
fm_brief_resolve_project_dir() {
  local repo=$1 projects=${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects} dir
  case "$repo" in
    projects/*) dir="$projects/${repo#projects/}" ;;
    /*|[A-Za-z]:/*) dir=$repo ;;
    *)
      if [ -d "$projects/$repo" ]; then
        dir="$projects/$repo"
      elif [ -d "$repo" ]; then
        dir=$repo
      elif fm_brief_repo_home_root_is_candidate "$repo"; then
        dir=${FM_HOME:-}
      else
        return 1
      fi
      ;;
  esac
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  # CDPATH='' cd -- matches resolve_directory_input in bin/fm-brief.sh: an
  # exported CDPATH otherwise prints the destination into the substitution and
  # can land elsewhere, and a leading dash would parse as a cd option.
  dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s\n' "$dir"
}

# fm_brief_task_repo_is_firstmate: return 0 when the resolved project checkout
# shares FM_ROOT's git object database (same repository, not merely same name).
fm_brief_task_repo_is_firstmate() {
  local repo=$1 project_dir root_common project_common
  project_dir=$(fm_brief_resolve_project_dir "$repo") || return 1
  root_common=$(git -C "$FM_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  project_common=$(git -C "$project_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$root_common" = "$project_common" ]
}
