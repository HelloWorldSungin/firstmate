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

# fm_brief_resolve_project_dir: print the resolved project directory for a brief
# REPO argument, or return 1 when it cannot be resolved to an existing directory.
#
# Firstmate is the one project whose checkout is the home itself rather than a
# clone under projects/ (docs/configuration.md), so a bare name that matches no
# clone falls back to the home root as the last lookup candidate; without it the
# canonical `fm-brief.sh <id> firstmate` resolves nowhere and the comparison
# below never runs. The fallback is deliberately not gated on the name matching
# a basename - a display name decides nothing here. It only says where to look,
# and the git-common-dir comparison stays the sole authority: a home that is not
# a firstmate checkout shares no object database and is rejected there.
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
        dir=${FM_HOME:-}
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
