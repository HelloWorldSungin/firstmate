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
# over removal, and whichever task tears down last releases the line. Because
# those siblings are separate processes racing on one shared file, every claim
# and every release runs under the per-exclude-file lock below.

# Portable lock primitives (fm_lock_try_acquire/fm_lock_release). bin/fm-spawn.sh
# already sources this library before us; bin/fm-teardown.sh does not, so pull it
# in here rather than making every consumer remember to.
if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
fi

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

# One lock per exclude file, keyed on the file itself so that everything touching
# it serializes - including spawns and teardowns from DIFFERENT firstmate homes,
# which share no other state. Without it the release below (a read-modify-write:
# grep -v into a temp, then mv) silently drops any line a concurrent spawn
# appended between its read and its mv, which un-hides that live task's staged
# mounts and lets its own `git add -A` commit them.
#
# The critical section is wider than the file: a line is `owned` iff the file AND
# the sibling ledgers say so, so the claim decision and the ledger append belong
# inside the same section as the append. A release that scanned for other claims
# before a sibling's claim landed would otherwise strip the ignore line out from
# under mounts that are still on disk.
#
# Bounded at FM_SKILL_MOUNT_LOCK_ATTEMPTS polls of 0.1s (10s by default, lowered
# by tests), because the section is a few file operations long and blocking a
# spawn or a teardown forever is worse than the race: on timeout an append
# proceeds anyway (>> is atomic against other appends; only the rewrite can lose
# it) while a release refuses and leaves its line, the conservative failure.
fm_skill_mount_exclude_lock_path() { # <exclude-file>
  printf '%s.fm-skill-mount.lock\n' "$1"
}

case "${FM_SKILL_MOUNT_LOCK_ATTEMPTS:-}" in
  ''|*[!0-9]*) FM_SKILL_MOUNT_LOCK_ATTEMPTS=100 ;;
esac

# The one lock this process currently holds, or empty. Nothing here ever nests an
# acquire, so finding this set on entry means an earlier section was abandoned
# mid-flight - and the path that discovers it is bin/fm-spawn.sh's EXIT trap,
# which runs fm_skill_mount_cleanup in the SAME process. fm_lock_try_acquire
# refuses to steal from a live pid, so without adoption that cleanup would poll
# out its whole budget on every recorded line and then leave each ignore line
# behind: the exact leak the lock exists to prevent.
FM_SKILL_MOUNT_LOCK_HELD=

fm_skill_mount_exclude_lock() { # <exclude-file>
  local lock attempt=0
  lock=$(fm_skill_mount_exclude_lock_path "$1")
  if [ "$FM_SKILL_MOUNT_LOCK_HELD" = "$lock" ]; then
    return 0
  fi
  # An unwritable git dir is not contention: the lock could never be created, so
  # polling out the whole budget would only stall the caller once per mount.
  [ -w "$(dirname "$1")" ] || return 1
  while [ "$attempt" -lt "$FM_SKILL_MOUNT_LOCK_ATTEMPTS" ]; do
    if fm_lock_try_acquire "$lock"; then
      FM_SKILL_MOUNT_LOCK_HELD=$lock
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

fm_skill_mount_exclude_unlock() { # <exclude-file>
  local lock
  lock=$(fm_skill_mount_exclude_lock_path "$1")
  if [ "$FM_SKILL_MOUNT_LOCK_HELD" = "$lock" ]; then
    FM_SKILL_MOUNT_LOCK_HELD=
  fi
  fm_lock_release "$lock" || true
}

# Lock-held primitives. Callers that need a wider critical section than one file
# operation hold the lock themselves and call these directly.
fm_skill_mount_exclude_append() { # <exclude-file> <line>
  local excl=$1 line=$2
  if grep -qxF "$line" "$excl" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$line" >> "$excl"
  return 0
}

fm_skill_mount_exclude_strip() { # <exclude-file> <line>
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

# 0 when this call appended the line, 1 when it was already present. Idempotent
# either way: the line exists exactly once when this returns.
fm_skill_mount_exclude_add() { # <exclude-file> <line>
  local excl=$1 line=$2 held=0 status
  mkdir -p "$(dirname "$excl")"
  if fm_skill_mount_exclude_lock "$excl"; then
    held=1
  else
    echo "fm-skill-mount: could not serialize on $excl; appending '$line' unserialized" >&2
  fi
  if fm_skill_mount_exclude_append "$excl" "$line"; then
    status=0
  else
    status=$?
  fi
  if [ "$held" = 1 ]; then
    fm_skill_mount_exclude_unlock "$excl"
  fi
  return "$status"
}

# Give up one ignore line this task claimed, unless another live task's ledger
# still claims the same line. Both halves run under one lock so a sibling's claim
# can never land in between.
fm_skill_mount_exclude_release() { # <state> <id> <exclude-file> <line>
  local state=$1 id=$2 excl=$3 line=$4
  [ -f "$excl" ] || return 0
  if ! fm_skill_mount_exclude_lock "$excl"; then
    echo "fm-skill-mount: could not serialize on $excl; leaving the ignore line '$line' in place" >&2
    return 0
  fi
  if ! fm_skill_mount_exclude_claimed_by_other "$state" "$id" "$excl" "$line"; then
    fm_skill_mount_exclude_strip "$excl" "$line" || true
  fi
  fm_skill_mount_exclude_unlock "$excl"
  return 0
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
  local state=$1 id=$2 wt=$3 rel=$4 ledger excl ownership held=0 status=0
  ledger=$(fm_skill_mount_ledger "$state" "$id")
  # Every write here is checked. The caller stages a real directory once this
  # returns 0, and it runs with `set -e` suppressed (bin/fm-spawn.sh reaches it
  # through `if ! stage_profile_skills`), so an unwritable ledger has to be
  # reported as a refusal or the mount would exist with nothing recording it.
  if ! mkdir -p "$state"; then
    echo "fm-skill-mount: could not create the ledger directory $state" >&2
    return 1
  fi
  if ! printf 'mount\t%s\n' "$rel" >> "$ledger"; then
    echo "fm-skill-mount: could not record the staged mount '$rel' in $ledger" >&2
    return 1
  fi
  excl=$(fm_skill_mount_exclude_file "$wt")
  [ -n "$excl" ] || return 0
  mkdir -p "$(dirname "$excl")"
  # Append, decide ownership, and publish the claim as one section: a concurrent
  # release that scanned the ledgers first would otherwise remove a line this
  # task is about to depend on.
  if fm_skill_mount_exclude_lock "$excl"; then
    held=1
  else
    echo "fm-skill-mount: could not serialize on $excl; claiming '$rel' unserialized" >&2
  fi
  if fm_skill_mount_exclude_append "$excl" "$rel"; then
    ownership=owned
  elif fm_skill_mount_exclude_claimed_by_other "$state" "$id" "$excl" "$rel" owned; then
    ownership=owned
  else
    ownership=foreign
  fi
  # Never let a failed append abort the function under `set -e`: the lock is held
  # here, and every consumer's abort path runs the release code in this same
  # process.
  if ! printf 'exclude\t%s\t%s\t%s\n' "$ownership" "$excl" "$rel" >> "$ledger"; then
    echo "fm-skill-mount: could not record the ignore-line claim for '$rel' in $ledger" >&2
    status=1
  fi
  if [ "$held" = 1 ]; then
    fm_skill_mount_exclude_unlock "$excl"
  fi
  return "$status"
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
    fm_skill_mount_exclude_release "$state" "$id" "$b" "$c" || true
  done < "$ledger"
  rm -f "$ledger"
  return 0
}
