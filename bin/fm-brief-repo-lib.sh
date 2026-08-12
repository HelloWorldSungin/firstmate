#!/usr/bin/env bash
# fm-brief-repo-lib.sh - detect when a crewmate task's project checkout is the
# firstmate repository itself.
#
# fm-brief.sh uses this to emit role-confusion guidance for ship and scout
# scaffolds only. The REPO name argument is not authoritative; two projects can
# share a display name or a clone can be misnamed. Instead, resolve the name to
# a project directory and compare that checkout's git-common-dir against
# FM_ROOT's, which is the sole authority on the verdict.
#
# Sourced by bin/fm-brief.sh and tests. No side effects on source.

_FM_BRIEF_REPO_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) \
  || _FM_BRIEF_REPO_LIB_DIR=.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$_FM_BRIEF_REPO_LIB_DIR/fm-primary-scope-lib.sh"

# fm_brief_repo_registers_home_root_clone: return 0 when data/projects.md
# carries a registry line for exactly this project name and that line declares
# the project's clone to be the home root itself rather than a directory under
# projects/. Same `- <name>` parsing as bin/fm-project-mode.sh, which owns the
# registry line format; docs/configuration.md owns the declaration prose.
fm_brief_repo_registers_home_root_clone() {
  local name=$1 registry=${FM_DATA_OVERRIDE:-${FM_HOME:-}/data}/projects.md
  [ -f "$registry" ] || return 1
  awk -v n="$name" '
    $1 == "-" && $2 == n {
      line = tolower($0)
      if (index(line, "home is the clone") || index(line, "lives at the home root rather than under projects/")) {
        found = 1
      }
      exit
    }
    END { exit !found }
  ' "$registry"
}

# fm_brief_repo_home_root_is_candidate: return 0 when the home root may be tried
# as a name's checkout, which is true in exactly two shapes.
#
# In a primary home the registry decides: only a name whose data/projects.md line
# declares the home-root layout gets the candidate, so an intake typo, a display
# spelling that differs from the clone directory, and an ordinary project
# registered before its clone is synced all resolve to nothing instead.
#
# A secondmate home carries no such line and structurally cannot: bin/fm-home-seed.sh
# leases it as a firstmate worktree and writes registry lines only for the
# projects it seeds, while a --no-projects domain - one whose whole subject is
# the firstmate repo - refuses a registry entirely. The genuine marker is the
# standing evidence for that shape, so it opens the same candidate there.
fm_brief_repo_home_root_is_candidate() {
  local repo=$1
  fm_brief_repo_registers_home_root_clone "$repo" && return 0
  fm_root_is_secondmate_home "${FM_HOME:-}"
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
