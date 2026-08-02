#!/usr/bin/env bash
# One-shot endpoint-binding migration for task records written before
# state/<id>.meta carried `endpoint_task_id=`.
#
# fm_backend_validate_task_endpoint (bin/fm-backend.sh) requires that binding
# before any non-tmux endpoint may be cleaned up, because a herdr/zellij/orca/
# cmux endpoint id is opaque and does not encode the task it belongs to. Legacy
# tmux records need no migration: their window name is exactly `fm-<id>`, so the
# record identifies itself. A record spawned on a non-tmux backend before that
# field existed instead refuses cleanup permanently.
#
# This sweep writes the missing binding ONLY for a record whose recorded
# endpoint still resolves, live, to a runtime object carrying that task's own
# label - the same class of self-identifying evidence the legacy tmux path
# validates by window name. Every other outcome refuses and leaves the record
# byte-unchanged: an opaque id whose ownership cannot be proven right now must
# never gain a durable binding, because a wrongly bound record authorizes
# destroying another task's endpoint. An uncleanable task is a nuisance; a
# wrongly bound one destroys work.
#
# A confirmed-gone endpoint is reported, never bound. Absence is not proof of
# ownership, and runtimes may later reuse a freed opaque id.
#
# The candidate record is bound only after the exact bytes that would be written
# pass fm_backend_validate_task_endpoint itself, so a migrated record is proven
# cleanable before it replaces the original, and this script never relaxes,
# reimplements, or bypasses that check.
#
# Idempotent and convergent: a record that already carries any
# `endpoint_task_id=` line is skipped untouched, so re-running only ever
# re-examines the records still missing one.
#
# Usage: fm-endpoint-binding-migrate.sh [--dry-run]
#          Sweeps FM_HOME/state. Silent when no record needs the binding.
#          Lines: "ENDPOINT_BINDING_MIGRATION: task <id> (<backend>): <reason>"
#                   - an actionable refusal; the record was left unchanged.
#                 "BOOTSTRAP_INFO: endpoint binding migration: task <id>
#                   (<backend>) bound after live task-label verification"
#                   - a completed no-action fact.
#          --dry-run reports exactly what a real run would decide and writes
#          nothing.
#          Always exits 0: an unreachable runtime is a refusal to report, not a
#          bootstrap failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

DRY_RUN=0
if [ "$#" -eq 1 ] && [ "$1" = --dry-run ]; then
  DRY_RUN=1
elif [ "$#" -ne 0 ]; then
  echo "usage: fm-endpoint-binding-migrate.sh [--dry-run]" >&2
  exit 2
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

umask 077

# REASON carries the refusal each verifier reports for the current record.
REASON=

refuse() {  # <reason>
  REASON=$1
  return 1
}

# verify_herdr: the recorded tab must still be the exact tab the record names,
# in the recorded workspace, carrying this task's own label, and must still own
# the recorded pane. Herdr tab labels are the plain `fm-<id>` firstmate created
# them with (bin/backends/herdr.sh fm_backend_herdr_create_task).
verify_herdr() {  # <meta> <id>
  local meta=$1 id=$2 session workspace tab pane window tabs matched present live_pane
  session=$(fm_backend_meta_exact_value "$meta" herdr_session) \
    && workspace=$(fm_backend_meta_exact_value "$meta" herdr_workspace_id) \
    && tab=$(fm_backend_meta_exact_value "$meta" herdr_tab_id) \
    && pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id) \
    && window=$(fm_backend_meta_exact_value "$meta" window) \
    || refuse "the record's Herdr endpoint fields are missing, empty, or ambiguous" || return 1
  [ "$window" = "$session:$pane" ] \
    || refuse "the recorded Herdr endpoint and its pane identity disagree" || return 1
  fm_backend_source herdr >/dev/null 2>&1 \
    && fm_backend_herdr_tool_check >/dev/null 2>&1 \
    || refuse "the Herdr runtime is unavailable, so the recorded endpoint cannot be verified" || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) \
    || refuse "Herdr session '$session' could not be read, so the recorded endpoint cannot be verified" || return 1
  matched=$(printf '%s' "$tabs" | jq -r --arg tab "$tab" --arg want "fm-$id" \
    '[.result.tabs[]? | select(.tab_id == $tab and .label == $want)] | length' 2>/dev/null)
  if [ "$matched" != 1 ]; then
    present=$(printf '%s' "$tabs" | jq -r --arg tab "$tab" \
      '[.result.tabs[]? | select(.tab_id == $tab)] | length' 2>/dev/null)
    if [ "$present" = 0 ]; then
      refuse "the recorded Herdr endpoint is gone; absence does not prove the record owned it"
    else
      refuse "the recorded Herdr tab does not carry this task's label fm-$id"
    fi
    return 1
  fi
  live_pane=$(fm_backend_herdr_pane_for_tab "$session" "$workspace" "$tab" 2>/dev/null) || live_pane=
  [ -n "$live_pane" ] && [ "$live_pane" = "$pane" ] \
    || refuse "the recorded Herdr pane is no longer the labelled tab's own pane" || return 1
  return 0
}

# verify_zellij: reuse the adapter's own tab-label match, which already owns
# the home-scoped title, the unambiguous bare-title fallback for a tab created
# before home scoping, and the refusal when that bare title is shared.
verify_zellij() {  # <meta> <id>
  local meta=$1 id=$2 session tab pane window live_tab
  session=$(fm_backend_meta_exact_value "$meta" zellij_session) \
    && tab=$(fm_backend_meta_exact_value "$meta" zellij_tab_id) \
    && pane=$(fm_backend_meta_exact_value "$meta" zellij_pane_id) \
    && window=$(fm_backend_meta_exact_value "$meta" window) \
    || refuse "the record's Zellij endpoint fields are missing, empty, or ambiguous" || return 1
  [ "$window" = "$session:$pane" ] \
    || refuse "the recorded Zellij endpoint and its pane identity disagree" || return 1
  fm_backend_source zellij >/dev/null 2>&1 \
    && fm_backend_zellij_tool_check >/dev/null 2>&1 \
    || refuse "the Zellij runtime is unavailable, so the recorded endpoint cannot be verified" || return 1
  fm_backend_zellij_session_exists "$session" \
    || refuse "Zellij session '$session' is not live, so the recorded endpoint cannot be verified" || return 1
  fm_backend_zellij_pane_exists "$session" "$pane" \
    || refuse "the recorded Zellij endpoint is gone; absence does not prove the record owned it" || return 1
  live_tab=$(fm_backend_zellij_tab_for_pane "$session" "$pane" 2>/dev/null) || live_tab=
  [ -n "$live_tab" ] && [ "$live_tab" = "$tab" ] \
    || refuse "the recorded Zellij pane no longer belongs to the recorded tab" || return 1
  fm_backend_zellij_tab_matches_label "$session" "$tab" "fm-$id" \
    || refuse "the recorded Zellij tab does not carry this task's label fm-$id" || return 1
  return 0
}

# verify_cmux: the recorded workspace must still carry this home's scoped title
# for the task, and must still hold the recorded surface. The recorded ids are
# checked as recorded - never refreshed by label the way
# fm_backend_cmux_target_ready may, because adopting a re-resolved id would
# verify some other object than the one the record names.
verify_cmux() {  # <meta> <id>
  local meta=$1 id=$2 workspace surface window expected title
  workspace=$(fm_backend_meta_exact_value "$meta" cmux_workspace_id) \
    && surface=$(fm_backend_meta_exact_value "$meta" cmux_surface_id) \
    && window=$(fm_backend_meta_exact_value "$meta" window) \
    || refuse "the record's cmux endpoint fields are missing, empty, or ambiguous" || return 1
  [ "$window" = "$workspace:$surface" ] \
    || refuse "the recorded cmux endpoint and its surface identity disagree" || return 1
  fm_backend_source cmux >/dev/null 2>&1 \
    && fm_backend_cmux_tool_check >/dev/null 2>&1 \
    || refuse "the cmux runtime is unavailable, so the recorded endpoint cannot be verified" || return 1
  expected=$(fm_backend_cmux_scoped_title "fm-$id")
  title=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null \
    | jq -r --arg id "$workspace" '.workspaces[]? | select(.id == $id) | .title' 2>/dev/null)
  if [ -z "$title" ]; then
    refuse "the recorded cmux endpoint is gone; absence does not prove the record owned it"
    return 1
  fi
  [ "$title" = "$expected" ] \
    || refuse "the recorded cmux workspace does not carry this task's title $expected" || return 1
  fm_backend_cmux_surface_exists "$workspace" "$surface" \
    || refuse "the recorded cmux surface is no longer part of the labelled workspace" || return 1
  return 0
}

# verify_orca: Orca exposes no readable title for a terminal handle, so the
# handle is verified through the worktree it was created against: the recorded
# Orca worktree id must still resolve to this task's own recorded worktree path
# and must still report the recorded terminal as its own. An Orca build whose
# `worktree show` omits the terminal handle leaves the handle unproven, which
# refuses rather than assuming.
verify_orca() {  # <meta> <id>
  local meta=$1 id=$2 terminal worktree_id window worktree out live_path live_terminal resolved
  terminal=$(fm_backend_meta_exact_value "$meta" terminal) \
    && worktree_id=$(fm_backend_meta_exact_value "$meta" orca_worktree_id) \
    && worktree=$(fm_backend_meta_exact_value "$meta" worktree) \
    && window=$(fm_backend_meta_exact_value "$meta" window) \
    || refuse "the record's Orca endpoint fields are missing, empty, or ambiguous" || return 1
  [ "$window" = "fm-$id" ] \
    || refuse "the recorded Orca endpoint is not labelled for this task" || return 1
  fm_backend_source orca >/dev/null 2>&1 \
    && fm_backend_orca_tool_check >/dev/null 2>&1 \
    || refuse "the Orca runtime is unavailable, so the recorded endpoint cannot be verified" || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json 2>/dev/null) \
    || refuse "the recorded Orca worktree is gone; absence does not prove the record owned it" || return 1
  live_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path 2>/dev/null) || live_path=
  live_terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null) || live_terminal=
  [ -n "$live_terminal" ] \
    || refuse "this Orca build does not report a terminal handle for the recorded worktree, leaving the endpoint unproven" || return 1
  [ "$live_terminal" = "$terminal" ] \
    || refuse "the recorded Orca worktree now reports a different terminal than the record names" || return 1
  resolved=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || resolved=$worktree
  [ -n "$live_path" ] && { [ "$live_path" = "$worktree" ] || [ "$live_path" = "$resolved" ]; } \
    || refuse "the recorded Orca worktree no longer resolves to this task's own worktree" || return 1
  return 0
}

verify_endpoint() {  # <backend> <meta> <id>
  case "$1" in
    herdr) verify_herdr "$2" "$3" ;;
    zellij) verify_zellij "$2" "$3" ;;
    cmux) verify_cmux "$2" "$3" ;;
    orca) verify_orca "$2" "$3" ;;
    *) refuse "backend $1 has no endpoint-binding verifier" ;;
  esac
}

# bind_record: atomically write <source> plus a validated binding to <meta>.
bind_record() {  # <meta> <source> <id>
  local meta=$1 source=$2 id=$3 tmp
  tmp=$(mktemp "$meta.migrate.XXXXXX") || {
    refuse "the migrated record could not be staged"
    return 1
  }
  {
    cat -- "$source" && printf 'endpoint_task_id=%s\n' "$id"
  } > "$tmp" 2>/dev/null || {
    rm -f -- "$tmp"
    refuse "the migrated record could not be staged"
    return 1
  }
  if ! fm_backend_validate_task_endpoint "$tmp" "$id" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    refuse "the migrated record would still be refused by cleanup validation"
    return 1
  fi
  chmod 600 -- "$tmp" 2>/dev/null || true
  if ! cmp -s -- "$source" "$meta"; then
    rm -f -- "$tmp"
    refuse "the task record changed concurrently before endpoint binding could be published"
    return 1
  fi
  if [ "$DRY_RUN" = 1 ]; then
    rm -f -- "$tmp"
    return 0
  fi
  mv -f -- "$tmp" "$meta" || {
    rm -f -- "$tmp"
    refuse "the migrated record could not replace the original"
    return 1
  }
  return 0
}

[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  # A missing, non-regular, or symlinked record is never migrated: cleanup
  # validation refuses it for the same reason, and following a link would let
  # something outside this home's private state be rewritten.
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename -- "$meta" .meta)
  case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  # Already bound, or ambiguously bound. Either way the record is not this
  # migration's to touch; validation owns the ambiguous case.
  [ "$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)" = 0 ] || continue
  backend_count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  [ "$backend_count" = 1 ] || continue
  backend=$(fm_backend_meta_exact_value "$meta" backend) || continue
  # A tmux record needs no binding: its window name is exactly fm-<id>, so it
  # already identifies itself to cleanup validation.
  [ "$backend" != tmux ] || continue
  fm_backend_is_known "$backend" || continue

  REASON=
  source=$(mktemp "$meta.source.XXXXXX") || {
    echo "ENDPOINT_BINDING_MIGRATION: task $id ($backend): the task record could not be snapshotted; record left unchanged"
    continue
  }
  if ! cat -- "$meta" > "$source" 2>/dev/null; then
    rm -f -- "$source"
    echo "ENDPOINT_BINDING_MIGRATION: task $id ($backend): the task record could not be snapshotted; record left unchanged"
    continue
  fi
  if ! verify_endpoint "$backend" "$source" "$id" || ! bind_record "$meta" "$source" "$id"; then
    rm -f -- "$source"
    echo "ENDPOINT_BINDING_MIGRATION: task $id ($backend): ${REASON:-the recorded endpoint could not be verified}; record left unchanged"
    continue
  fi
  rm -f -- "$source"
  if [ "$DRY_RUN" = 1 ]; then
    echo "BOOTSTRAP_INFO: endpoint binding migration: task $id ($backend) would be bound after live task-label verification"
  else
    echo "BOOTSTRAP_INFO: endpoint binding migration: task $id ($backend) bound after live task-label verification"
  fi
done

exit 0
