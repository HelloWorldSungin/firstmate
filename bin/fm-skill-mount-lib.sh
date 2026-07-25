#!/usr/bin/env bash
# Shared owner of the staged skill-mount lifecycle: what one spawn copied into a
# task worktree, and what that task's teardown must undo.
#
# bin/fm-spawn.sh copies vendored design-toolkit skills into the task worktree so
# the harness can model-invoke them, and hides every copy from git so a
# crewmate's `git add -A` cannot commit skill directories into its ADR PR and so
# the mounts never trip teardown's own dirty check. Both halves outlive the task
# unless something removes them: `treehouse return` leaves git-excluded files in
# the pooled worktree for the next lessee, and `git rev-parse --git-path
# info/exclude` resolves to the SHARED common git dir, so the ignore lines are
# repo-wide and permanent.
#
# Teardown must therefore undo exactly what one spawn did and nothing else.
# stage_skill_dir deliberately SKIPS a path the project already carries as its
# own vendored copy - this repo vendors the same toolkit, so a design spawn onto
# a firstmate checkout stages nothing at all - which makes any "delete
# .agents/skills/*" cleanup a destroyer of committed project content. The ledger
# below records what one spawn actually created, and cleanup removes only that.
#
# Ledger: <state>/<id>.skill-mounts, one TAB-separated record per line.
#   mount<TAB><worktree-relative directory this spawn created>
#   exclude<TAB><owned|foreign><TAB><exclude file><TAB><exact line>
# `owned` means firstmate put that line there: this spawn appended it, or a live
# sibling task's ledger already owned it. `foreign` means the line was already
# present with no firstmate task claiming it, so the project owns it and teardown
# never touches it. Sibling co-ownership is not hypothetical - a design task and
# the prototype scout it dispatches both mount `prototype` into worktrees that
# share one common git dir - so a claim held by another live ledger always wins
# over removal, and whichever task tears down last releases the line.

# Proof that a file IS the vendored copy rather than a same-named project skill.
# Every vendored SKILL.md carries this exact frontmatter line, and
# tests/fm-design-skills.test.sh pins it for all nine. Consumed by the sourcing
# script (bin/fm-spawn.sh's staging guard), not by this library.
# shellcheck disable=SC2034
FM_VENDORED_SKILL_MARKER='source: https://github.com/mattpocock/skills'

fm_skill_mount_ledger() { # <state> <id>
  printf '%s/%s.skill-mounts\n' "$1" "$2"
}

# Absolute path of the git exclude file that hides a worktree's staged mounts,
# or nothing when it cannot be resolved. git prints a relative --git-path against
# the directory it ran in, not against this process's working directory, so a
# non-linked checkout's `.git/info/exclude` must be re-anchored on the worktree.
fm_skill_mount_exclude_file() { # <worktree>
  local wt=$1 excl wt_real
  [ -n "$wt" ] || return 0
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null) || return 0
  [ -n "$excl" ] || return 0
  case "$excl" in
    /*) printf '%s\n' "$excl"; return 0 ;;
  esac
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || return 0
  printf '%s/%s\n' "$wt_real" "$excl"
}

# 0 when this call appended the line, 1 when it was already present. Idempotent
# either way: the line exists exactly once when this returns.
fm_skill_mount_exclude_add() { # <exclude-file> <line>
  local excl=$1 line=$2
  mkdir -p "$(dirname "$excl")"
  if grep -qxF "$line" "$excl" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$line" >> "$excl"
  return 0
}

fm_skill_mount_exclude_remove() { # <exclude-file> <line>
  local excl=$1 line=$2 tmp status
  [ -f "$excl" ] || return 0
  grep -qxF "$line" "$excl" 2>/dev/null || return 0
  tmp="$excl.fm-skill-mount.$$"
  # cp -p first so the rewritten file keeps the original's mode; grep -v exits 1
  # when it selects nothing, which is the legitimate "that was the only line".
  cp -p "$excl" "$tmp" 2>/dev/null || return 1
  if grep -vxF "$line" "$excl" > "$tmp"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -gt 1 ]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$excl"
}

# 0 when a DIFFERENT task's ledger records this exact exclude line. <ownership>
# narrows the match to that class; empty matches any claim.
fm_skill_mount_exclude_claimed_by_other() { # <state> <id> <exclude-file> <line> [ownership]
  local state=$1 id=$2 excl=$3 line=$4 want=${5:-} ledger kind owned file value
  for ledger in "$state"/*.skill-mounts; do
    [ -f "$ledger" ] || continue
    [ "${ledger##*/}" != "$id.skill-mounts" ] || continue
    while IFS=$'\t' read -r kind owned file value; do
      [ "$kind" = exclude ] || continue
      [ -z "$want" ] || [ "$owned" = "$want" ] || continue
      [ "$file" = "$excl" ] || continue
      [ "$value" = "$line" ] || continue
      return 0
    done < "$ledger"
  done
  return 1
}

# Record one mount this spawn is about to create and claim the exclude line that
# hides it. Called BEFORE the copy so the files are never briefly visible to git
# and so a failed copy still leaves a removable record.
fm_skill_mount_record() { # <state> <id> <worktree> <relative-path>
  local state=$1 id=$2 wt=$3 rel=$4 ledger excl ownership
  ledger=$(fm_skill_mount_ledger "$state" "$id")
  mkdir -p "$state"
  printf 'mount\t%s\n' "$rel" >> "$ledger"
  excl=$(fm_skill_mount_exclude_file "$wt")
  [ -n "$excl" ] || return 0
  if fm_skill_mount_exclude_add "$excl" "$rel"; then
    ownership=owned
  elif fm_skill_mount_exclude_claimed_by_other "$state" "$id" "$excl" "$rel" owned; then
    ownership=owned
  else
    ownership=foreign
  fi
  printf 'exclude\t%s\t%s\t%s\n' "$ownership" "$excl" "$rel" >> "$ledger"
}

# Remove one recorded mount, or refuse loudly and leave it alone. Every refusal
# path protects content this spawn did not create.
fm_skill_mount_remove_dir() { # <worktree> <worktree-realpath> <relative-path>
  local wt=$1 wt_real=$2 rel=$3 target target_real
  case "$rel" in
    ''|/*|*..*)
      echo "fm-skill-mount: refusing to remove suspicious staged path '$rel'" >&2
      return 1
      ;;
  esac
  # No worktree left: the mount went with it, so the record is satisfied.
  [ -n "$wt_real" ] || return 0
  target="$wt/$rel"
  { [ -e "$target" ] || [ -L "$target" ]; } || return 0
  if [ -L "$target" ] || [ ! -d "$target" ]; then
    echo "fm-skill-mount: staged mount $target is no longer a plain directory; leaving it in place" >&2
    return 1
  fi
  target_real=$(cd "$target" 2>/dev/null && pwd -P) || target_real=
  case "${target_real:-}/" in
    "$wt_real"/*) ;;
    *)
      echo "fm-skill-mount: staged mount $target resolves outside $wt_real; leaving it in place" >&2
      return 1
      ;;
  esac
  # A tracked path is the project's own committed content, never a staged mount.
  if [ -n "$(git -C "$wt" ls-files -- "$rel" 2>/dev/null || true)" ]; then
    echo "fm-skill-mount: staged mount $rel is tracked in git; leaving the project's own files in place" >&2
    return 1
  fi
  rm -rf "$target" || {
    echo "fm-skill-mount: could not remove staged mount $target" >&2
    return 1
  }
  return 0
}

# Undo one task's staged mounts. Idempotent and safe to call more than once: the
# ledger is the whole record, and it is dropped once processed. Pass an empty
# worktree to release ignore lines only - the right call once the worktree is
# gone or already returned to its pool, where the path may belong to another task.
fm_skill_mount_cleanup() { # <state> <id> <worktree>
  local state=$1 id=$2 wt=$3 ledger wt_real kept kind a b c
  ledger=$(fm_skill_mount_ledger "$state" "$id")
  [ -f "$ledger" ] || return 0
  wt_real=
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=
  fi
  kept=$'\n'
  while IFS=$'\t' read -r kind a b c; do
    [ "$kind" = mount ] || continue
    if fm_skill_mount_remove_dir "$wt" "$wt_real" "$a"; then
      continue
    fi
    kept="$kept$a"$'\n'
  done < "$ledger"
  # Release an ignore line only after the directory it hid is gone, and only when
  # no other live task still relies on the same line.
  while IFS=$'\t' read -r kind a b c; do
    [ "$kind" = exclude ] || continue
    [ "$a" = owned ] || continue
    case "$kept" in
      *$'\n'"$c"$'\n'*) continue ;;
    esac
    if fm_skill_mount_exclude_claimed_by_other "$state" "$id" "$b" "$c"; then
      continue
    fi
    fm_skill_mount_exclude_remove "$b" "$c" || true
  done < "$ledger"
  rm -f "$ledger"
  return 0
}
