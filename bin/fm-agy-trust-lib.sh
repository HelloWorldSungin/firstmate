#!/usr/bin/env bash
# bin/fm-agy-trust-lib.sh - manage agy's (Antigravity CLI) global workspace-trust
# list so a firstmate-launched agy crewmate can start unattended, and clean the
# entry up at teardown. Sourced by bin/fm-spawn.sh (add before launch) and
# bin/fm-teardown.sh (remove after landing).
#
# WHY: agy gates an interactive launch behind a per-workspace trust modal, and
# --dangerously-skip-permissions does NOT cover it (verified,
# data/cursor-agy-verify/report.md point 4). Trust lives in agy's SINGLE global
# settings file under "trustedWorkspaces", an array of EXACT absolute paths -
# prefix match does not count, so a trusted /home/x does not trust
# /home/x/worktree. firstmate therefore adds the exact crew-worktree path before
# launch and removes it at teardown.
#
# That settings file is SHARED with the captain's own direct agy use and with
# every other firstmate home, so every mutation is deliberately careful:
#   - locked with a self-contained mkdir lock next to the file, so concurrent
#     spawns/teardowns across homes serialize without depending on any other
#     firstmate lock library;
#   - additive and idempotent - other trusted paths and every other settings key
#     are preserved, and a re-add or double-remove is a no-op;
#   - atomic - written to a sibling temp file and mv'd into place;
#   - fail-closed - a settings file that is not valid JSON is left UNTOUCHED
#     rather than clobbered, and a missing file is created minimally only for an
#     add.
#
# FM_AGY_SETTINGS_OVERRIDE points the whole thing at a test file; the real path
# is $HOME/.gemini/antigravity-cli/settings.json.

# fm_agy_settings_path: the agy global settings file this home should mutate.
fm_agy_settings_path() {
  if [ -n "${FM_AGY_SETTINGS_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_AGY_SETTINGS_OVERRIDE"
  else
    printf '%s\n' "${HOME:-}/.gemini/antigravity-cli/settings.json"
  fi
}

# fm_agy_trust_lock_age: seconds since <lockdir>'s mtime, or empty when it cannot
# be read (portable across GNU and BSD stat).
fm_agy_trust_lock_age() {  # <lockdir>
  local lock=$1 now mtime
  now=$(date +%s 2>/dev/null) || return 0
  mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || true)
  [ -n "$mtime" ] || return 0
  printf '%s\n' "$((now - mtime))"
}

# fm_agy_trust_lock_acquire: atomic mkdir lock with a bounded spin and a
# stale-breaker (each mutation is a sub-second jq rewrite, so a lock older than
# 10s is from a dead mutator and is reclaimed).
fm_agy_trust_lock_acquire() {  # <lockdir>
  local lock=$1 tries=0 age
  while [ "$tries" -lt 100 ]; do
    if mkdir "$lock" 2>/dev/null; then
      return 0
    fi
    age=$(fm_agy_trust_lock_age "$lock")
    if [ -n "$age" ] && [ "$age" -ge 10 ]; then
      rmdir "$lock" 2>/dev/null || true
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  return 1
}

fm_agy_trust_lock_release() {  # <lockdir>
  rmdir "$1" 2>/dev/null || true
}

# fm_agy_trust_mutate <add|remove> <abs-path>: the shared locked, atomic,
# fail-closed read-modify-write. Returns non-zero (with a stderr warning) rather
# than ever clobbering an unparseable file.
fm_agy_trust_mutate() {  # <add|remove> <abs-path>
  local op=$1 path=$2 file lock tmp rc=0
  command -v jq >/dev/null 2>&1 || { echo "warning: jq unavailable; cannot $op agy workspace trust for $path" >&2; return 1; }
  case "$path" in
    /*) : ;;
    *) echo "warning: agy workspace trust needs an absolute path, got '$path'" >&2; return 1 ;;
  esac
  file=$(fm_agy_settings_path)
  [ -n "$file" ] || return 1
  # A remove against a missing file is already satisfied.
  if [ "$op" = remove ] && [ ! -e "$file" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  lock="$file.fm-trust.lock"
  fm_agy_trust_lock_acquire "$lock" || { echo "warning: could not lock agy settings to $op workspace trust for $path" >&2; return 1; }
  if [ -e "$file" ]; then
    if ! jq -e . "$file" >/dev/null 2>&1; then
      echo "warning: agy settings at $file is not valid JSON; leaving it untouched (workspace trust $op skipped for $path)" >&2
      fm_agy_trust_lock_release "$lock"
      return 1
    fi
    tmp=$(mktemp "$file.fm-trust.XXXXXX" 2>/dev/null) || { fm_agy_trust_lock_release "$lock"; return 1; }
    if [ "$op" = add ]; then
      jq --arg p "$path" '.trustedWorkspaces = ((.trustedWorkspaces // []) | map(select(. != $p)) + [$p])' "$file" > "$tmp" 2>/dev/null || rc=1
    else
      jq --arg p "$path" 'if (.trustedWorkspaces | type) == "array" then .trustedWorkspaces |= map(select(. != $p)) else . end' "$file" > "$tmp" 2>/dev/null || rc=1
    fi
  else
    # add into a fresh minimal file (remove already returned above).
    tmp=$(mktemp "$file.fm-trust.XXXXXX" 2>/dev/null) || { fm_agy_trust_lock_release "$lock"; return 1; }
    jq -n --arg p "$path" '{trustedWorkspaces: [$p]}' > "$tmp" 2>/dev/null || rc=1
  fi
  if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
    mv -f "$tmp" "$file" || rc=1
  else
    rc=1
  fi
  [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null || true
  fm_agy_trust_lock_release "$lock"
  return "$rc"
}

# fm_agy_trust_add: trust <abs-worktree-path> before an agy launch.
fm_agy_trust_add() {  # <abs-worktree-path>
  fm_agy_trust_mutate add "$1"
}

# fm_agy_trust_remove: drop <abs-worktree-path> at teardown.
fm_agy_trust_remove() {  # <abs-worktree-path>
  fm_agy_trust_mutate remove "$1"
}
