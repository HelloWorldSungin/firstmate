#!/usr/bin/env bash
# Real-Herdr multi-home topology, ownership and recovery coverage.
# Starts its own source, homes, named lab and evidence; no prior suite state.
set -u

# shellcheck source=tests/herdr-presentation-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-presentation-fixture.sh"
presentation_fixture_setup
presentation_fixture_seed_project recovery-anchor

spawn_secondmate_task() {
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "sh -c 'while :; do sleep 60; done'" --secondmate --backend herdr
}

assert_no_projection_mutation_since() {  # <line-count> <case-name>
  local start=$1 name=$2 calls
  calls=$(sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG")
  if printf '%s\n' "$calls" | grep -E $'^(workspace\t(create|close|rename)|tab\t(create|close)|pane\tclose|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$name performed a create, close, delete, rename, or lifecycle call during recovery inspection"
  fi
}

write_ship_brief "$HOME_DIR" fm-hibit-resume-r1 'Hi Bit-style projection restart fixture.'
write_ship_brief "$HOME_DIR" wheelhouse-healing-r1 'Wheelhouse-style projection restart fixture.'
presentation_fixture_seed_parents
: > "$HOME_DIR/config/herdr-presentation-spaces"

# ------------------------------------------------------------------
# Multi-home topology: real secondmate FM_HOME spawn paths, inheritance,
# concurrent cross-home waves, and session-scoped lock contention.
# ------------------------------------------------------------------
SECOND_HOME_A="$TMP_ROOT/home-2ndmate-alpha"
SECOND_HOME_B="$TMP_ROOT/home-2ndmate-bravo"
mkdir -p "$SECOND_HOME_A/state" "$SECOND_HOME_A/config" "$SECOND_HOME_A/data" \
  "$SECOND_HOME_B/state" "$SECOND_HOME_B/config" "$SECOND_HOME_B/data"
for SECOND_HOME in "$SECOND_HOME_A" "$SECOND_HOME_B"; do
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" \
    > "$SECOND_HOME/.fm-secondmate-parent"
done
printf 'alpha\n' > "$SECOND_HOME_A/.fm-secondmate-home"
printf 'bravo\n' > "$SECOND_HOME_B/.fm-secondmate-home"
printf -- '- alpha - fixture scope (home: %s; scope: fixture; projects: project; added 2026-09-11)\n- bravo - fixture scope (home: %s; scope: fixture; projects: project; added 2026-09-11)\n' \
  "$SECOND_HOME_A" "$SECOND_HOME_B" > "$HOME_DIR/data/secondmates.md"
# The presentation homes must also be one real local ownership tree, otherwise
# their project locks and exclusive-slot checks silently cover different homes.
PRIMARY_PROJECT_LOCK=
for OWNER_HOME in "$HOME_DIR" "$SECOND_HOME_A" "$SECOND_HOME_B"; do
  OWNER_PROJECT_LOCK=$(FM_HOME="$OWNER_HOME" ROOT="$ROOT" PROJECT_DIR="$PROJECT_DIR" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_treehouse_project_lock_path "$PROJECT_DIR"
  ') || fail "could not resolve the registered home's project lock"
  [ -n "$PRIMARY_PROJECT_LOCK" ] || PRIMARY_PROJECT_LOCK=$OWNER_PROJECT_LOCK
  [ "$OWNER_PROJECT_LOCK" = "$PRIMARY_PROJECT_LOCK" ] || fail "registered homes disagree on project ownership lock"
done
touch "$SECOND_HOME_A/state/.last-watcher-beat" "$SECOND_HOME_B/state/.last-watcher-beat"
# Ensure the secondmate homes look like gitignored firstmate homes so inheritance
# may write config/herdr-presentation-spaces.
git -C "$SECOND_HOME_A" init -q
git -C "$SECOND_HOME_B" init -q
printf 'config/herdr-presentation-spaces\nconfig/crew-harness\nconfig/crew-dispatch.json\nconfig/backlog-backend\nconfig/backend\nconfig/startup-memory-budget\n' \
  > "$SECOND_HOME_A/.gitignore"
cp "$SECOND_HOME_A/.gitignore" "$SECOND_HOME_B/.gitignore"
git -C "$SECOND_HOME_A" add .gitignore
git -C "$SECOND_HOME_B" add .gitignore
git -C "$SECOND_HOME_A" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm init
git -C "$SECOND_HOME_B" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm init
mkdir -p "$SECOND_HOME_A/bin"
printf '# Firstmate secondmate fixture\n' > "$SECOND_HOME_A/AGENTS.md"
printf 'Secondmate alpha charter.\n' > "$SECOND_HOME_A/data/charter.md"

# Primary setting only; real inheritance must push it into both secondmate homes.
[ -f "$HOME_DIR/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting disappeared before multi-home inheritance"
[ ! -e "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "secondmate A unexpectedly had a local presentation setting before inheritance"
[ ! -e "$SECOND_HOME_B/config/herdr-presentation-spaces" ] \
  || fail "secondmate B unexpectedly had a local presentation setting before inheritance"
SECOND_SPAWN_LOG_START=$(log_line_count)
spawn_secondmate_task alpha "$SECOND_HOME_A" > "$EVIDENCE_ROOT/alpha.out" 2> "$EVIDENCE_ROOT/alpha.err" \
  || fail "secondmate alpha spawn failed: $(cat "$EVIDENCE_ROOT/alpha.err")"
[ -f "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "secondmate spawn did not inherit the presentation setting"
[ ! -e "$HOME_DIR/state/alpha.herdr-presentation" ] \
  || fail "secondmate spawn published a presentation journal"
SECOND_META="$HOME_DIR/state/alpha.meta"
[ "$(grep '^kind=' "$SECOND_META" | cut -d= -f2-)" = secondmate ] \
  || fail "secondmate spawn did not record kind=secondmate"
SECOND_WSID=$(grep '^herdr_workspace_id=' "$SECOND_META" | cut -d= -f2-)
SECOND_LABEL=$(lab workspace get "$SECOND_WSID" | jq -r '.result.workspace.label')
[ "$SECOND_LABEL" = 2ndmate-alpha ] \
  || fail "secondmate spawn did not use its flat parent workspace: $SECOND_LABEL"
[ -z "$(projection_labels_from_log "$SECOND_SPAWN_LOG_START")" ] \
  || fail "secondmate spawn created a corner projection workspace"
if sed -n "$((SECOND_SPAWN_LOG_START + 1)),\$p" "$HERDR_CALL_LOG" \
  | grep -E $'^(workspace\tmove|session\tlist)' >/dev/null 2>&1; then
  fail "secondmate spawn attempted presentation ordering"
fi
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND_HOME_A/config" \
  || fail "inheritance into secondmate A failed"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND_HOME_B/config" \
  || fail "inheritance into secondmate B failed"
[ -f "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting did not reach secondmate A"
[ -f "$SECOND_HOME_B/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting did not reach secondmate B"
pass "real Herdr lab: the primary presentation setting inherits into real secondmate homes"

# Keep the pre-existing 2ndmate-alpha/bravo workspaces as owning parents and captain focus.
assert_focus_is "$CAPTAIN_FOCUS" "multi-home captain focus"

mkdir -p "$SECOND_HOME_A/data/a1" "$SECOND_HOME_A/data/a2" \
  "$SECOND_HOME_B/data/b1" "$SECOND_HOME_B/data/b2" \
  "$HOME_DIR/data/p1" "$HOME_DIR/data/p2"
write_ship_brief "$HOME_DIR" p1 'Primary multi-home fixture 1.'
write_ship_brief "$HOME_DIR" p2 'Primary multi-home fixture 2.'
write_ship_brief "$SECOND_HOME_A" a1 'Secondmate A fixture 1.'
write_ship_brief "$SECOND_HOME_A" a2 'Secondmate A fixture 2.'
write_ship_brief "$SECOND_HOME_B" b1 'Secondmate B fixture 1.'
write_ship_brief "$SECOND_HOME_B" b2 'Secondmate B fixture 2.'

MULTI_FOCUS_START=$(focus_audit_line_count)
spawn_task p1 "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/p1.out" 2> "$EVIDENCE_ROOT/p1.err" \
  || fail "multi-home primary p1 failed: $(cat "$EVIDENCE_ROOT/p1.err")"
spawn_task p2 "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/p2.out" 2> "$EVIDENCE_ROOT/p2.err" \
  || fail "multi-home primary p2 failed: $(cat "$EVIDENCE_ROOT/p2.err")"
spawn_task a1 "$SECOND_HOME_A" "$PROJECT_DIR" > "$EVIDENCE_ROOT/a1.out" 2> "$EVIDENCE_ROOT/a1.err" \
  || fail "multi-home secondmate A a1 failed: $(cat "$EVIDENCE_ROOT/a1.err")"
spawn_task a2 "$SECOND_HOME_A" "$PROJECT_DIR" > "$EVIDENCE_ROOT/a2.out" 2> "$EVIDENCE_ROOT/a2.err" \
  || fail "multi-home secondmate A a2 failed: $(cat "$EVIDENCE_ROOT/a2.err")"
spawn_task b1 "$SECOND_HOME_B" "$PROJECT_DIR" > "$EVIDENCE_ROOT/b1.out" 2> "$EVIDENCE_ROOT/b1.err" \
  || fail "multi-home secondmate B b1 failed: $(cat "$EVIDENCE_ROOT/b1.err")"
spawn_task b2 "$SECOND_HOME_B" "$PROJECT_DIR" > "$EVIDENCE_ROOT/b2.out" 2> "$EVIDENCE_ROOT/b2.err" \
  || fail "multi-home secondmate B b2 failed: $(cat "$EVIDENCE_ROOT/b2.err")"
for META_X in p1 p2 a1 a2 b1 b2; do
  case "$META_X" in
    p*) remember_meta_worktree "$HOME_DIR/state/$META_X.meta" >/dev/null ;;
    a*) remember_meta_worktree "$SECOND_HOME_A/state/$META_X.meta" >/dev/null ;;
    b*) remember_meta_worktree "$SECOND_HOME_B/state/$META_X.meta" >/dev/null ;;
  esac
done
assert_focus_is "$CAPTAIN_FOCUS" "multi-home sequential spawns"
assert_raw_presentation_mutations_preserved_since "$MULTI_FOCUS_START" "multi-home sequential spawns"

P1_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/p1.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
P2_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/p2.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
A1_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_A/state/a1.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
A2_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_A/state/a2.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
B1_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_B/state/b1.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
B2_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_B/state/b2.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
case "$P1_LABEL" in $'└ p1 · p:'*) ;; *) fail "primary p1 label wrong: $P1_LABEL" ;; esac
case "$P2_LABEL" in $'└ p2 · p:'*) ;; *) fail "primary p2 label wrong: $P2_LABEL" ;; esac
case "$A1_LABEL" in $'└ a1 · p:'*) ;; *) fail "secondmate A a1 label wrong: $A1_LABEL" ;; esac
case "$A2_LABEL" in $'└ a2 · p:'*) ;; *) fail "secondmate A a2 label wrong: $A2_LABEL" ;; esac
case "$B1_LABEL" in $'└ b1 · p:'*) ;; *) fail "secondmate B b1 label wrong: $B1_LABEL" ;; esac
case "$B2_LABEL" in $'└ b2 · p:'*) ;; *) fail "secondmate B b2 label wrong: $B2_LABEL" ;; esac

MULTI_LIST=$(lab workspace list) || fail "could not list multi-home topology"
MULTI_LABELS=$(printf '%s' "$MULTI_LIST" | jq -r '
  .result.workspaces[]
  | select(
      .label == "firstmate"
      or .label == "2ndmate-alpha"
      or .label == "2ndmate-bravo"
      or (.label | startswith("└ "))
    )
  | .label
')
MULTI_EXPECTED=$(printf '%s\n' \
  firstmate "$P1_LABEL" "$P2_LABEL" \
  2ndmate-alpha "$A1_LABEL" "$A2_LABEL" \
  2ndmate-bravo "$B1_LABEL" "$B2_LABEL")
[ "$MULTI_LABELS" = "$MULTI_EXPECTED" ] \
  || fail "multi-home topology was not owning-parent grouped: $MULTI_LABELS"
pass "real Herdr lab: primary and two secondmate homes each own a top-level contiguous child block"

# Concurrent cross-home wave under the one session lock.
mkdir -p "$HOME_DIR/data/pcw" "$SECOND_HOME_A/data/acw" "$SECOND_HOME_B/data/bcw"
write_ship_brief "$HOME_DIR" pcw 'Cross-home concurrent primary.'
write_ship_brief "$SECOND_HOME_A" acw 'Cross-home concurrent A.'
write_ship_brief "$SECOND_HOME_B" bcw 'Cross-home concurrent B.'
WAVE_CROSS_FOCUS=$(focus_audit_line_count)
spawn_task pcw "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/pcw.out" 2> "$EVIDENCE_ROOT/pcw.err" &
PCW_PID=$!
spawn_task acw "$SECOND_HOME_A" "$PROJECT_DIR" > "$EVIDENCE_ROOT/acw.out" 2> "$EVIDENCE_ROOT/acw.err" &
ACW_PID=$!
spawn_task bcw "$SECOND_HOME_B" "$PROJECT_DIR" > "$EVIDENCE_ROOT/bcw.out" 2> "$EVIDENCE_ROOT/bcw.err" &
BCW_PID=$!
PCW_STATUS=0; wait "$PCW_PID" || PCW_STATUS=$?
ACW_STATUS=0; wait "$ACW_PID" || ACW_STATUS=$?
BCW_STATUS=0; wait "$BCW_PID" || BCW_STATUS=$?
finish_concurrent_spawn pcw "$PCW_STATUS" "$EVIDENCE_ROOT/pcw.out" "$EVIDENCE_ROOT/pcw.err" "$HOME_DIR"
finish_concurrent_spawn acw "$ACW_STATUS" "$EVIDENCE_ROOT/acw.out" "$EVIDENCE_ROOT/acw.err" "$SECOND_HOME_A"
finish_concurrent_spawn bcw "$BCW_STATUS" "$EVIDENCE_ROOT/bcw.out" "$EVIDENCE_ROOT/bcw.err" "$SECOND_HOME_B"
remember_meta_worktree "$HOME_DIR/state/pcw.meta" >/dev/null
remember_meta_worktree "$SECOND_HOME_A/state/acw.meta" >/dev/null
remember_meta_worktree "$SECOND_HOME_B/state/bcw.meta" >/dev/null
assert_focus_is "$CAPTAIN_FOCUS" "cross-home concurrent wave"
assert_raw_presentation_mutations_preserved_since "$WAVE_CROSS_FOCUS" "cross-home concurrent wave"
CROSS_LIST=$(lab workspace list)
printf '%s' "$CROSS_LIST" | jq -e '
  ([.result.workspaces[].label] | index("firstmate")) as $fm
  | ([.result.workspaces[].label] | index("2ndmate-alpha")) as $a
  | ([.result.workspaces[].label] | index("2ndmate-bravo")) as $b
  | $fm != null and $a != null and $b != null
  and $fm < $a and $a < $b
' >/dev/null 2>&1 || fail "cross-home concurrent wave reordered parents"
PCW_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$HOME_DIR/state/pcw.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
ACW_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_A/state/acw.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
BCW_LABEL=$(lab workspace get "$(grep '^herdr_workspace_id=' "$SECOND_HOME_B/state/bcw.meta" | cut -d= -f2-)" | jq -r '.result.workspace.label')
case "$PCW_LABEL" in $'└ pcw · p:'*|firstmate) ;; *) fail "cross-home primary label wrong: $PCW_LABEL" ;; esac
case "$ACW_LABEL" in $'└ acw · p:'*|2ndmate-alpha) ;; *) fail "cross-home A label wrong: $ACW_LABEL" ;; esac
case "$BCW_LABEL" in $'└ bcw · p:'*|2ndmate-bravo) ;; *) fail "cross-home B label wrong: $BCW_LABEL" ;; esac
pass "real Herdr lab: concurrent primary/A/B spawns preserve parent order and exact focus"

# Hold the shared session lock from a different home and force flat fallback.
CROSS_LOCK_READY="$TMP_ROOT/cross-lock-ready"
CROSS_LOCK_RELEASE="$TMP_ROOT/cross-lock-release"
CROSS_LOCK_PATH=$(session_presentation_lock_path) \
  || fail "could not resolve session lock for cross-home contention"
ROOT="$ROOT" READY="$CROSS_LOCK_READY" RELEASE="$CROSS_LOCK_RELEASE" LOCK="$CROSS_LOCK_PATH" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  while [ ! -e "$RELEASE" ]; do sleep 0.05; done
  fm_lock_release "$LOCK"
' &
CROSS_LOCK_PID=$!
LOCK_CONTENTION_OWNER_PID=$CROSS_LOCK_PID
while [ ! -e "$CROSS_LOCK_READY" ] && kill -0 "$CROSS_LOCK_PID" 2>/dev/null; do sleep 0.01; done
[ -e "$CROSS_LOCK_READY" ] || fail "could not hold the cross-home session presentation lock"
mkdir -p "$SECOND_HOME_A/data/aflat"
write_ship_brief "$SECOND_HOME_A" aflat 'Flat fallback under session lock contention.'
if spawn_task aflat "$SECOND_HOME_A" "$PROJECT_DIR" > "$EVIDENCE_ROOT/aflat.out" 2> "$EVIDENCE_ROOT/aflat.err"; then
  AFLAT_STATUS=0
else
  AFLAT_STATUS=$?
fi
: > "$CROSS_LOCK_RELEASE"
wait "$CROSS_LOCK_PID" || fail "cross-home session lock owner failed"
LOCK_CONTENTION_OWNER_PID=
[ "$AFLAT_STATUS" -eq 0 ] \
  || fail "cross-home lock contention did not fall back flat: $(cat "$EVIDENCE_ROOT/aflat.err")"
grep -F "presentation focus lock unavailable; using the ordinary flat layout without projection" "$EVIDENCE_ROOT/aflat.err" >/dev/null 2>&1 \
  || fail "cross-home lock contention did not warn about flat fallback"
remember_meta_worktree "$SECOND_HOME_A/state/aflat.meta" >/dev/null
AFLAT_WSID=$(grep '^herdr_workspace_id=' "$SECOND_HOME_A/state/aflat.meta" | cut -d= -f2-)
AFLAT_LABEL=$(lab workspace get "$AFLAT_WSID" | jq -r '.result.workspace.label')
[ "$AFLAT_LABEL" = 2ndmate-alpha ] \
  || fail "cross-home lock contention did not use the ordinary secondmate home workspace: $AFLAT_LABEL"
[ ! -e "$SECOND_HOME_A/state/aflat.herdr-presentation" ] \
  || fail "cross-home lock contention published a projection journal"
assert_focus_is "$CAPTAIN_FOCUS" "cross-home lock contention flat fallback"
teardown_task aflat "$SECOND_HOME_A" > "$EVIDENCE_ROOT/aflat-teardown.out" 2> "$EVIDENCE_ROOT/aflat-teardown.err" \
  || fail "flat cross-home contention fixture teardown failed"
pass "real Herdr lab: session lock contention from a secondmate home falls back flat with no journal"

# Finish the multi-home scenario before stopping the entire lab for recovery.
# Treehouse leases belong to processes; restored shells return to the source
# directory, so an old task record must not outlive this completed scenario and
# collide with a later allocation of its now-unleased slot.
# Keep the presentation parent with a source-root shell, not a pooled task.
lab tab create --workspace "$FIRSTMATE_WSID" --cwd "$PROJECT_DIR" \
  --label fixture-layout-anchor --no-focus > "$EVIDENCE_ROOT/layout-anchor.out" \
  || fail "could not retain the task-free primary presentation parent"
for META_HOME_PAIR in \
  "p1:$HOME_DIR" "p2:$HOME_DIR" "pcw:$HOME_DIR" \
  "a1:$SECOND_HOME_A" "a2:$SECOND_HOME_A" "acw:$SECOND_HOME_A" \
  "b1:$SECOND_HOME_B" "b2:$SECOND_HOME_B" "bcw:$SECOND_HOME_B" \
  "$ANCHOR_ID:$HOME_DIR"
do
  TASK_ID=${META_HOME_PAIR%%:*}
  TASK_HOME=${META_HOME_PAIR#*:}
  teardown_task "$TASK_ID" "$TASK_HOME" > "$EVIDENCE_ROOT/td-$TASK_ID.out" 2> "$EVIDENCE_ROOT/td-$TASK_ID.err" \
    || fail "multi-home teardown of $TASK_ID failed: $(cat "$EVIDENCE_ROOT/td-$TASK_ID.err")"
  [ ! -e "$TASK_HOME/state/$TASK_ID.meta" ] || fail "completed task $TASK_ID still owns a recorded slot"
done
assert_focus_is "$CAPTAIN_FOCUS" "multi-home teardown before restart"
pass "real Herdr lab: completed multi-home tasks retire before restart with exact focus and no stale slot claims"

# Same-identity recovery replaces only one exact agent-free husk in its
# original projected workspace.
# Exercise both the leading fm- identity style seen in Hi Bit work and the
# project-name identity style used by Wheelhouse work.
for RESTART_ID in fm-hibit-resume-r1 wheelhouse-healing-r1; do
  spawn_task "$RESTART_ID" "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/$RESTART_ID-first.out" 2> "$EVIDENCE_ROOT/$RESTART_ID-first.err" \
    || fail "$RESTART_ID fixture's projected spawn failed: $(cat "$EVIDENCE_ROOT/$RESTART_ID-first.err")"
  RESTART_META="$HOME_DIR/state/$RESTART_ID.meta"
  remember_meta_worktree "$RESTART_META" >/dev/null
  OLD_RESTART_WSID=$(grep '^herdr_workspace_id=' "$RESTART_META" | cut -d= -f2-)
  OLD_RESTART_PANE=$(grep '^herdr_pane_id=' "$RESTART_META" | cut -d= -f2-)
  OLD_RESTART_LABEL=$(lab workspace get "$OLD_RESTART_WSID" | jq -r '.result.workspace.label')
  [ "$(grep '^version=' "$HOME_DIR/state/$RESTART_ID.herdr-presentation")" = version=2 ] \
    || fail "$RESTART_ID fresh projection did not publish an exact restart binding"
  EXPECTED_CONCISE=${RESTART_ID#fm-}
  case "$OLD_RESTART_LABEL" in
    "└ $EXPECTED_CONCISE · p:"*) ;;
    *) fail "$RESTART_ID fresh projection label did not apply concise prefix handling: $OLD_RESTART_LABEL" ;;
  esac
  PATH="$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
    || fail "could not stop the isolated session for $RESTART_ID validation"
  PATH="$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
    || fail "could not reprovision the isolated session for $RESTART_ID validation"
  lab pane get "$OLD_RESTART_PANE" >/dev/null 2>&1 \
    || fail "$RESTART_ID restart did not preserve the projected pane structurally"
  if lab agent get "$OLD_RESTART_PANE" >/dev/null 2>&1; then
    fail "$RESTART_ID restart fixture unexpectedly retained a registered agent"
  fi
  RECLAIM_FOCUS=$(focus_snapshot)
  spawn_task "$RESTART_ID" "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/$RESTART_ID-reclaim.out" 2> "$EVIDENCE_ROOT/$RESTART_ID-reclaim.err" \
    || fail "$RESTART_ID same-identity reclaim failed: $(cat "$EVIDENCE_ROOT/$RESTART_ID-reclaim.err")"
  remember_meta_worktree "$RESTART_META" >/dev/null
  NEW_RESTART_WSID=$(grep '^herdr_workspace_id=' "$RESTART_META" | cut -d= -f2-)
  NEW_RESTART_PANE=$(grep '^herdr_pane_id=' "$RESTART_META" | cut -d= -f2-)
  [ "$NEW_RESTART_WSID" = "$OLD_RESTART_WSID" ] \
    || fail "$RESTART_ID reclaim flattened into a different workspace"
  [ "$NEW_RESTART_PANE" != "$OLD_RESTART_PANE" ] \
    || fail "$RESTART_ID reclaim reused the old husk pane"
  [ "$(lab workspace get "$NEW_RESTART_WSID" | jq -r '.result.workspace.label')" = "$OLD_RESTART_LABEL" ] \
    || fail "$RESTART_ID reclaim renamed or replaced the projected workspace"
  if lab pane get "$OLD_RESTART_PANE" >/dev/null 2>&1; then
    fail "$RESTART_ID reclaim did not close the exact old husk pane"
  fi
  [ "$(grep '^pane_id=' "$HOME_DIR/state/$RESTART_ID.herdr-presentation" | cut -d= -f2-)" = "$NEW_RESTART_PANE" ] \
    || fail "$RESTART_ID reclaim did not advance the exact journal binding"
  assert_focus_is "$RECLAIM_FOCUS" "$RESTART_ID same-identity reclaim"

  if [ "$RESTART_ID" = fm-hibit-resume-r1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
      || fail "could not stop the isolated session for idempotent reclaim"
    PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
      || fail "could not reprovision the isolated session for idempotent reclaim"
    PRIOR_RESTART_PANE=$NEW_RESTART_PANE
    spawn_task "$RESTART_ID" "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/$RESTART_ID-idempotent.out" 2> "$EVIDENCE_ROOT/$RESTART_ID-idempotent.err" \
      || fail "$RESTART_ID repeated reclaim failed: $(cat "$EVIDENCE_ROOT/$RESTART_ID-idempotent.err")"
    remember_meta_worktree "$RESTART_META" >/dev/null
    NEW_RESTART_WSID=$(grep '^herdr_workspace_id=' "$RESTART_META" | cut -d= -f2-)
    NEW_RESTART_PANE=$(grep '^herdr_pane_id=' "$RESTART_META" | cut -d= -f2-)
    [ "$NEW_RESTART_WSID" = "$OLD_RESTART_WSID" ] \
      || fail "$RESTART_ID repeated reclaim changed workspace identity"
    [ "$NEW_RESTART_PANE" != "$PRIOR_RESTART_PANE" ] \
      || fail "$RESTART_ID repeated reclaim reused the prior husk pane"
  fi

  teardown_task "$RESTART_ID" "$HOME_DIR" > "$EVIDENCE_ROOT/$RESTART_ID-teardown.out" 2> "$EVIDENCE_ROOT/$RESTART_ID-teardown.err" \
    || fail "$RESTART_ID teardown after reclaim failed: $(cat "$EVIDENCE_ROOT/$RESTART_ID-teardown.err")"
  [ ! -e "$HOME_DIR/state/$RESTART_ID.herdr-presentation" ] \
    || fail "$RESTART_ID exact reclaimed teardown did not retire its journal"
done
pass "real Herdr lab: Hi Bit and Wheelhouse-style same-identity restarts reclaim one nested space with exact focus and idempotence"

# A secondmate child binds and reclaims only inside its own home and parent.
CROSS_RESTART_ID=wheel-child-resume
mkdir -p "$SECOND_HOME_A/data/$CROSS_RESTART_ID"
write_ship_brief "$SECOND_HOME_A" "$CROSS_RESTART_ID" 'Cross-home restart fixture.'
spawn_task "$CROSS_RESTART_ID" "$SECOND_HOME_A" "$PROJECT_DIR" > "$EVIDENCE_ROOT/cross-restart-first.out" 2> "$EVIDENCE_ROOT/cross-restart-first.err" \
  || fail "cross-home restart fixture failed: $(cat "$EVIDENCE_ROOT/cross-restart-first.err")"
CROSS_RESTART_META="$SECOND_HOME_A/state/$CROSS_RESTART_ID.meta"
remember_meta_worktree "$CROSS_RESTART_META" >/dev/null
CROSS_OLD_WSID=$(grep '^herdr_workspace_id=' "$CROSS_RESTART_META" | cut -d= -f2-)
CROSS_OLD_PANE=$(grep '^herdr_pane_id=' "$CROSS_RESTART_META" | cut -d= -f2-)
CROSS_OLD_LABEL=$(lab workspace get "$CROSS_OLD_WSID" | jq -r '.result.workspace.label')
CROSS_BOUND_HOME=$(grep '^home=' "$SECOND_HOME_A/state/$CROSS_RESTART_ID.herdr-presentation" | cut -d= -f2-)
[ "$CROSS_BOUND_HOME" = "$(cd "$SECOND_HOME_A" && pwd -P)" ] \
  || fail "cross-home restart journal did not bind the secondmate's exact home"
[ ! -e "$HOME_DIR/state/$CROSS_RESTART_ID.herdr-presentation" ] \
  || fail "cross-home restart published a journal in the primary home"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated session for cross-home restart"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not reprovision the isolated session for cross-home restart"
spawn_task "$CROSS_RESTART_ID" "$SECOND_HOME_A" "$PROJECT_DIR" > "$EVIDENCE_ROOT/cross-restart-resume.out" 2> "$EVIDENCE_ROOT/cross-restart-resume.err" \
  || fail "cross-home same-identity reclaim failed: $(cat "$EVIDENCE_ROOT/cross-restart-resume.err")"
remember_meta_worktree "$CROSS_RESTART_META" >/dev/null
CROSS_NEW_WSID=$(grep '^herdr_workspace_id=' "$CROSS_RESTART_META" | cut -d= -f2-)
CROSS_NEW_PANE=$(grep '^herdr_pane_id=' "$CROSS_RESTART_META" | cut -d= -f2-)
[ "$CROSS_NEW_WSID" = "$CROSS_OLD_WSID" ] && [ "$CROSS_NEW_PANE" != "$CROSS_OLD_PANE" ] \
  || fail "cross-home reclaim did not replace one pane inside the same secondmate child workspace"
[ "$(lab workspace get "$CROSS_NEW_WSID" | jq -r '.result.workspace.label')" = "$CROSS_OLD_LABEL" ] \
  || fail "cross-home reclaim changed the secondmate child's presentation label"
teardown_task "$CROSS_RESTART_ID" "$SECOND_HOME_A" > "$EVIDENCE_ROOT/cross-restart-teardown.out" 2> "$EVIDENCE_ROOT/cross-restart-teardown.err" \
  || fail "cross-home reclaimed teardown failed: $(cat "$EVIDENCE_ROOT/cross-restart-teardown.err")"
pass "real Herdr lab: secondmate restart binding and reclaim stay isolated to the exact child home and parent"

# Two homes recovering concurrently serialize on the named session lock and
# each replace only their own exact husk.
PRIMARY_WAVE_ID=resume-wave-primary
BRAVO_WAVE_ID=resume-wave-bravo
mkdir -p "$HOME_DIR/data/$PRIMARY_WAVE_ID" "$SECOND_HOME_B/data/$BRAVO_WAVE_ID"
write_ship_brief "$HOME_DIR" "$PRIMARY_WAVE_ID" 'Concurrent primary recovery fixture.'
write_ship_brief "$SECOND_HOME_B" "$BRAVO_WAVE_ID" 'Concurrent secondmate recovery fixture.'
spawn_task "$PRIMARY_WAVE_ID" "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/primary-wave-first.out" 2> "$EVIDENCE_ROOT/primary-wave-first.err" \
  || fail "primary recovery-wave fixture failed: $(cat "$EVIDENCE_ROOT/primary-wave-first.err")"
spawn_task "$BRAVO_WAVE_ID" "$SECOND_HOME_B" "$PROJECT_DIR" > "$EVIDENCE_ROOT/bravo-wave-first.out" 2> "$EVIDENCE_ROOT/bravo-wave-first.err" \
  || fail "secondmate recovery-wave fixture failed: $(cat "$EVIDENCE_ROOT/bravo-wave-first.err")"
PRIMARY_WAVE_META="$HOME_DIR/state/$PRIMARY_WAVE_ID.meta"
BRAVO_WAVE_META="$SECOND_HOME_B/state/$BRAVO_WAVE_ID.meta"
remember_meta_worktree "$PRIMARY_WAVE_META" >/dev/null
remember_meta_worktree "$BRAVO_WAVE_META" >/dev/null
PRIMARY_WAVE_WSID=$(grep '^herdr_workspace_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)
BRAVO_WAVE_WSID=$(grep '^herdr_workspace_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)
PRIMARY_WAVE_OLD_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)
BRAVO_WAVE_OLD_PANE=$(grep '^herdr_pane_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated session for concurrent recovery"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not reprovision the isolated session for concurrent recovery"
CONCURRENT_RECOVERY_FOCUS=$(focus_snapshot)
spawn_task "$PRIMARY_WAVE_ID" "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/primary-wave-resume.out" 2> "$EVIDENCE_ROOT/primary-wave-resume.err" &
PRIMARY_WAVE_PID=$!
spawn_task "$BRAVO_WAVE_ID" "$SECOND_HOME_B" "$PROJECT_DIR" > "$EVIDENCE_ROOT/bravo-wave-resume.out" 2> "$EVIDENCE_ROOT/bravo-wave-resume.err" &
BRAVO_WAVE_PID=$!
PRIMARY_WAVE_STATUS=0; wait "$PRIMARY_WAVE_PID" || PRIMARY_WAVE_STATUS=$?
BRAVO_WAVE_STATUS=0; wait "$BRAVO_WAVE_PID" || BRAVO_WAVE_STATUS=$?
finish_concurrent_spawn "$PRIMARY_WAVE_ID" "$PRIMARY_WAVE_STATUS" "$EVIDENCE_ROOT/primary-wave-resume.out" "$EVIDENCE_ROOT/primary-wave-resume.err" "$HOME_DIR"
finish_concurrent_spawn "$BRAVO_WAVE_ID" "$BRAVO_WAVE_STATUS" "$EVIDENCE_ROOT/bravo-wave-resume.out" "$EVIDENCE_ROOT/bravo-wave-resume.err" "$SECOND_HOME_B"
remember_meta_worktree "$PRIMARY_WAVE_META" >/dev/null
remember_meta_worktree "$BRAVO_WAVE_META" >/dev/null
PRIMARY_WAVE_NEW_PANE=$(grep '^herdr_pane_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)
BRAVO_WAVE_NEW_PANE=$(grep '^herdr_pane_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)
[ "$(grep '^herdr_workspace_id=' "$PRIMARY_WAVE_META" | cut -d= -f2-)" = "$PRIMARY_WAVE_WSID" ] \
  && [ "$(grep '^herdr_workspace_id=' "$BRAVO_WAVE_META" | cut -d= -f2-)" = "$BRAVO_WAVE_WSID" ] \
  || fail "concurrent recovery flattened one task into a different workspace"
[ "$PRIMARY_WAVE_NEW_PANE" != "$PRIMARY_WAVE_OLD_PANE" ] \
  && [ "$BRAVO_WAVE_NEW_PANE" != "$BRAVO_WAVE_OLD_PANE" ] \
  || fail "concurrent recovery reused an old husk pane"
if lab pane get "$PRIMARY_WAVE_OLD_PANE" >/dev/null 2>&1 \
   || lab pane get "$BRAVO_WAVE_OLD_PANE" >/dev/null 2>&1; then
  fail "concurrent recovery left an old husk pane behind"
fi
assert_focus_is "$CONCURRENT_RECOVERY_FOCUS" "concurrent cross-home recovery"
teardown_task "$PRIMARY_WAVE_ID" "$HOME_DIR" > "$EVIDENCE_ROOT/primary-wave-teardown.out" 2> "$EVIDENCE_ROOT/primary-wave-teardown.err" \
  || fail "concurrent primary recovery teardown failed: $(cat "$EVIDENCE_ROOT/primary-wave-teardown.err")"
teardown_task "$BRAVO_WAVE_ID" "$SECOND_HOME_B" > "$EVIDENCE_ROOT/bravo-wave-teardown.out" 2> "$EVIDENCE_ROOT/bravo-wave-teardown.err" \
  || fail "concurrent secondmate recovery teardown failed: $(cat "$EVIDENCE_ROOT/bravo-wave-teardown.err")"
pass "real Herdr lab: concurrent cross-home recoveries replace exact husks under one session lock with no focus drift"

# Seed a legacy old-format primary projection and a flat secondmate tab; correction must not migrate them.
LEGACY_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label "firstmate/legacy-seed · p:AbCdEfGhIjKlMnOpQrStUv" --no-focus) \
  || fail "could not seed a legacy old-format presentation space"
LEGACY_WSID=$(printf '%s' "$LEGACY_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$LEGACY_WSID" ] || fail "legacy seed returned no workspace id"
FLAT_TAB_OUT=$(lab tab create --workspace "$(lab workspace list | jq -r '.result.workspaces[] | select(.label == "2ndmate-alpha") | .workspace_id' | head -1)" --cwd "$PROJECT_DIR" --label fm-flat-legacy-tab --no-focus) \
  || fail "could not seed a flat secondmate child tab"
FLAT_TAB_ID=$(printf '%s' "$FLAT_TAB_OUT" | jq -r '.result.tab.tab_id // empty')
mkdir -p "$HOME_DIR/data/post-legacy"
write_ship_brief "$HOME_DIR" post-legacy 'Post-legacy primary child.'
spawn_task post-legacy "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/post-legacy.out" 2> "$EVIDENCE_ROOT/post-legacy.err" \
  || fail "post-legacy projected spawn failed: $(cat "$EVIDENCE_ROOT/post-legacy.err")"
remember_meta_worktree "$HOME_DIR/state/post-legacy.meta" >/dev/null
[ "$(lab workspace get "$LEGACY_WSID" | jq -r '.result.workspace.label')" = "firstmate/legacy-seed · p:AbCdEfGhIjKlMnOpQrStUv" ] \
  || fail "correction renamed or moved the seeded legacy projection"
lab tab get "$FLAT_TAB_ID" >/dev/null 2>&1 \
  || fail "correction removed the seeded flat secondmate child tab"
pass "real Herdr lab: legacy projection labels and flat secondmate tabs are left unmigrated"

# Retire the remaining post-restart task and the secondmate launcher record.
for META_HOME_PAIR in "post-legacy:$HOME_DIR" "alpha:$HOME_DIR"
do
  TASK_ID=${META_HOME_PAIR%%:*}
  TASK_HOME=${META_HOME_PAIR#*:}
  teardown_task "$TASK_ID" "$TASK_HOME" > "$EVIDENCE_ROOT/td-$TASK_ID.out" 2> "$EVIDENCE_ROOT/td-$TASK_ID.err" \
    || fail "multi-home teardown of $TASK_ID failed: $(cat "$EVIDENCE_ROOT/td-$TASK_ID.err")"
done
assert_focus_is "$CAPTAIN_FOCUS" "multi-home teardown"
pass "real Herdr lab: multi-home exact-pane teardowns restore captain focus without workspace close authority"

# Missing, renamed, and duplicate tokens are read-only recovery diagnostics.
# The duplicate case allows flat fallback only when every matching pane is
# positively agent-free.
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

MISSING_STATE="$TMP_ROOT/missing-state"; mkdir -p "$MISSING_STATE"
fm_backend_herdr_projection_journal_create "$MISSING_STATE" missing1 >/dev/null
MISSING_JOURNAL=$(fm_backend_herdr_projection_journal_path "$MISSING_STATE" missing1)
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$MISSING_JOURNAL" missing1 \
  || fail "missing token match should degrade to flat"
assert_no_projection_mutation_since "$START" "missing-token recovery"

RENAMED_STATE="$TMP_ROOT/renamed-state"; mkdir -p "$RENAMED_STATE"
RENAMED_TOKEN=$(fm_backend_herdr_projection_journal_create "$RENAMED_STATE" renamed1)
RENAMED_JOURNAL=$(fm_backend_herdr_projection_journal_path "$RENAMED_STATE" renamed1)
RENAMED_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label "firstmate/renamed1 · p:$RENAMED_TOKEN" --no-focus)
RENAMED_WSID=$(printf '%s' "$RENAMED_OUT" | jq -r '.result.workspace.workspace_id')
lab workspace rename "$RENAMED_WSID" renamed-without-token >/dev/null
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$RENAMED_JOURNAL" renamed1 \
  || fail "renamed token match should degrade to flat"
assert_no_projection_mutation_since "$START" "renamed-token recovery"
lab workspace get "$RENAMED_WSID" >/dev/null 2>&1 || fail "renamed-token recovery removed or adopted the old workspace"

DUP_STATE="$TMP_ROOT/duplicate-state"; mkdir -p "$DUP_STATE"
DUP_TOKEN=$(fm_backend_herdr_projection_journal_create "$DUP_STATE" duplicate1)
DUP_JOURNAL=$(fm_backend_herdr_projection_journal_path "$DUP_STATE" duplicate1)
DUP1=$(lab workspace create --cwd "$PROJECT_DIR" --label "firstmate/duplicate1 · p:$DUP_TOKEN" --no-focus)
DUP2=$(lab workspace create --cwd "$PROJECT_DIR" --label "copy/duplicate1 · p:$DUP_TOKEN" --no-focus)
DUP1_WSID=$(printf '%s' "$DUP1" | jq -r '.result.workspace.workspace_id')
DUP2_WSID=$(printf '%s' "$DUP2" | jq -r '.result.workspace.workspace_id')
DUP1_PANE=$(printf '%s' "$DUP1" | jq -r '.result.root_pane.pane_id')
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$DUP_JOURNAL" duplicate1 \
  || fail "agent-free duplicate token matches should permit flat fallback"
assert_no_projection_mutation_since "$START" "agent-free duplicate-token recovery"
lab workspace get "$DUP1_WSID" >/dev/null 2>&1 || fail "duplicate-token recovery removed the first quarantined workspace"
lab workspace get "$DUP2_WSID" >/dev/null 2>&1 || fail "duplicate-token recovery removed the second quarantined workspace"

lab pane report-agent "$DUP1_PANE" --source fm-projection-e2e --agent test-agent --state idle >/dev/null \
  || fail "could not register the duplicate-live-agent risk fixture"
START=$(log_line_count)
if fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$DUP_JOURNAL" duplicate1; then
  fail "a duplicate token match with a registered agent should refuse fallback"
fi
assert_no_projection_mutation_since "$START" "live duplicate-token recovery"
lab workspace get "$DUP1_WSID" >/dev/null 2>&1 || fail "live duplicate refusal removed the first workspace"
lab workspace get "$DUP2_WSID" >/dev/null 2>&1 || fail "live duplicate refusal removed the second workspace"
pass "real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch"

presentation_fixture_finish fm-backend-herdr-recovery-e2e
