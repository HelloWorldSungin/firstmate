#!/usr/bin/env bash
# Cleanup owner for the presentation E2E fixture only.
# The caller owns a unique named lab, source repository, worktree journal and
# sibling evidence directory; failure retains them for ownership diagnosis.
# Never register this source root with the generic orphan reaper.

cleanup_all() {
  local wt pid common expected meta key value claimed slot
  [ "${PRESENTATION_CLEANUP_DONE:-0}" -eq 0 ] || return "$PRESENTATION_CLEANUP_STATUS"
  PRESENTATION_CLEANUP_DONE=1
  PRESENTATION_CLEANUP_STATUS=1

  # Finish outstanding fixture operations before shutting down their lab.
  # Re-entering through EXIT never repeats a partial return or lifecycle call.
  for pid in $(jobs -pr); do
    [ "$pid" = "${LOCK_CONTENTION_OWNER_PID:-}" ] && continue
    wait "$pid" || FIXTURE_FAILED=1
  done
  if [ -n "${LOCK_CONTENTION_OWNER_PID:-}" ]; then
    fm_test_safe_stop_process "$LOCK_CONTENTION_OWNER_PID" "lock-contention owner" || return 1
    LOCK_CONTENTION_OWNER_PID=
  fi
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
      >> "$EVIDENCE_ROOT/cleanup.log" 2>&1 || {
      echo "cleanup: herdr lab teardown failed; retained $TMP_ROOT and $EVIDENCE_ROOT" >&2
      return 1
    }
    LAB_READY=0
  fi
  if [ "${FIXTURE_FAILED:-0}" -eq 1 ]; then
    echo "cleanup: failed fixture retained at $TMP_ROOT; evidence $EVIDENCE_ROOT; no slot returns" >&2
    return 1
  fi

  # Shutdown has completed before any return. Verify every recorded copy still
  # belongs to this exact source repository, and use an ordinary guarded return.
  expected=$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir) || return 1
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir) || return 1
    [ "$common" = "$expected" ] || {
      echo "cleanup: recorded copy $wt belongs to another repository; retained $TMP_ROOT" >&2
      return 1
    }
    slot=$(cd "$wt" && pwd -P) || return 1
    for meta in "$TMP_ROOT"/home*/state/*.meta; do
      [ -f "$meta" ] || continue
      while IFS='=' read -r key value; do
        case "$key" in worktree|home) ;; *) continue ;; esac
        [ -d "$value" ] || continue
        claimed=$(cd "$value" && pwd -P) || return 1
        [ "$claimed" != "$slot" ] || {
          echo "cleanup: $meta still claims $slot; retained $TMP_ROOT" >&2
          return 1
        }
      done < "$meta"
    done
    "$REAL_TREEHOUSE" return "$wt" >> "$EVIDENCE_ROOT/cleanup.log" 2>&1 || {
      echo "cleanup: treehouse return $wt failed; retained $TMP_ROOT and $EVIDENCE_ROOT" >&2
      return 1
    }
  done < "$RECORDED_WORKTREES"
  rm -rf "$TMP_ROOT" || return 1
  PRESENTATION_CLEANUP_STATUS=0
  return 0
}
