#!/usr/bin/env bash
# fm-brief-repo-lib.sh - detect when a crewmate task's project checkout is the
# firstmate repository itself.
#
# fm-brief.sh uses this to emit role-confusion guidance for ship and scout
# scaffolds only. The REPO name argument is not authoritative; two projects can
# share a display name or a clone can be misnamed. Instead, resolve the project
# directory the same way spawn does and compare git-common-dir against FM_ROOT.
#
# Sourced by bin/fm-brief.sh and tests. No side effects on source.

# fm_brief_resolve_project_dir: print the resolved project directory for a brief
# REPO argument, or return 1 when it cannot be resolved to an existing directory.
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
      else
        return 1
      fi
      ;;
  esac
  [ -d "$dir" ] || return 1
  if ! dir=$(cd "$dir" && pwd -P); then
    return 1
  fi
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
