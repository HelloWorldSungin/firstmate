#!/usr/bin/env bash
# fm-brief-repo-lib.sh - detect when a crewmate task's project checkout is the
# firstmate repository itself.
#
# fm-brief.sh uses this to emit role-confusion guidance for ship, design, and scout
# scaffolds only. The REPO name argument is not authoritative; two projects can
# share a display name or a clone can be misnamed. Instead, resolve the name to
# a project directory and compare that checkout's git-common-dir against
# FM_ROOT's, which is the sole authority on the verdict.
#
# Sourced by bin/fm-brief.sh, bin/fm-issue-ref.sh, and tests. No side effects
# on source.

_FM_BRIEF_REPO_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) \
  || _FM_BRIEF_REPO_LIB_DIR=.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$_FM_BRIEF_REPO_LIB_DIR/fm-primary-scope-lib.sh"

# fm_brief_repo_home_root_clone_name: print the canonical registry name of
# the home root's clone if the home root is structurally a firstmate
# checkout, otherwise return 1.
#
# The firstmate repo's registry entry is the one line data/projects.md
# carries for the project whose clone IS the home root. The convention is
# that the entry is named "firstmate" (see docs/configuration.md "Operational
# home layout and state"); that convention is what this function returns.
# The structural part is the home root's git object DB equalling FM_ROOT's -
# the same check that fm_brief_task_repo_is_firstmate uses for the final
# verdict - so this function cannot misclassify a home root that is not the
# firstmate repo and it cannot be silenced by a registry prose rewrite.
#
# issue #104: the previous implementation read the registry entry's English
# prose for phrases like "home is the clone" / "lives at the home root
# rather than under projects/" and refused to detect the home-root clone
# the moment those phrases were reworded. Deriving the name from the
# structural fact removes the prose coupling entirely.
fm_brief_repo_home_root_clone_name() {
  local root_common home_common
  root_common=$(git -C "${FM_ROOT:-}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  home_common=$(git -C "${FM_HOME:-}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$root_common" = "$home_common" ] || return 1
  printf '%s\n' firstmate
}

# fm_brief_repo_registers_home_root_clone: return 0 when the passed name is
# the registry entry whose clone is the home root itself rather than a
# directory under projects/. The structural check is delegated to
# fm_brief_repo_home_root_clone_name: the home root is structurally a
# firstmate checkout and the entry is named "firstmate" by convention.
# The git object DB comparison is the sole authority on the verdict, so a
# registry prose rewrite cannot disable this check.
fm_brief_repo_registers_home_root_clone() {
  local name=$1 home_root_name
  home_root_name=$(fm_brief_repo_home_root_clone_name 2>/dev/null) || return 1
  [ "$name" = "$home_root_name" ]
}

# fm_brief_repo_home_root_is_candidate: return 0 when the home root may be
# tried as a name's checkout, which is true in exactly two shapes.
#
# The first is structural: the home root is a firstmate checkout and the
# name is the firstmate repo's registry entry. This subsumes the old
# prose-based shape - the home root is the firstmate repo's clone by
# construction, and the registry entry's name is the canonical handle for
# it. A registry prose rewrite cannot disable this branch.
#
# The second is the secondmate-home shape: bin/fm-home-seed.sh leases it
# as a firstmate worktree and writes registry lines only for the projects
# it seeds, while a --no-projects domain - one whose whole subject is the
# firstmate repo - refuses a registry entirely. The .fm-secondmate-home
# marker is the standing evidence for that shape, so it opens the same
# candidate there.
fm_brief_repo_home_root_is_candidate() {
  local repo=$1
  if [ "$(fm_brief_repo_home_root_clone_name 2>/dev/null)" = "$repo" ]; then
    return 0
  fi
  fm_root_is_secondmate_home "${FM_HOME:-}"
}

# fm_brief_repo_resolve_project_name: take a name or path and return the
# canonical registry name. The home root is the firstmate repo's checkout,
# so a path that matches the home root resolves to the firstmate repo's
# registry name (conventionally "firstmate"). Other names and paths are
# returned unchanged.
#
# This is the bridge that lets bin/fm-issue-ref.sh's --project parameter
# accept either the registry name or the home root's path without losing
# the registry lookup: the lookup itself is keyed by name, while a caller
# that has a path can still resolve it to the same key.
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
