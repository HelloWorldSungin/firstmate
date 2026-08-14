#!/usr/bin/env bash

FM_TASK_BRANCH_ERROR=

fm_task_branch_validate() {  # <branch>
  local branch=${1:-}
  FM_TASK_BRANCH_ERROR=
  if [ -z "$branch" ] || ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    FM_TASK_BRANCH_ERROR="must be a valid git branch name"
    return 1
  fi
  case "$branch" in
    refs/*)
      FM_TASK_BRANCH_ERROR="must use a branch name outside the refs/ namespace"
      return 1
      ;;
    HEAD|FETCH_HEAD|ORIG_HEAD|MERGE_HEAD|CHERRY_PICK_HEAD|REVERT_HEAD|BISECT_HEAD|REBASE_HEAD|AUTO_MERGE)
      FM_TASK_BRANCH_ERROR="cannot use Git's reserved ref name '$branch'"
      return 1
      ;;
    *'`'*|*'-->'*)
      FM_TASK_BRANCH_ERROR="cannot contain a backtick or --> because the name is rendered in Markdown task metadata"
      return 1
      ;;
  esac
  return 0
}
