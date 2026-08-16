#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real agent is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, so registering and not registering an agent on a plain
# shell pane exercises exactly the classification the control plane gates on.
# A registration over a plain idle shell is the STALE-registration state (the
# registry outliving its agent), which the classifier must downgrade to
# agent-free; modelling a genuinely live agent therefore additionally needs a
# real foreground process in the pane, so the idle-shell cross-check refuses.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  local status=0
  herdr_safe_stop_and_delete "$SESSION" || { echo "cleanup: herdr teardown failed" >&2; status=1; }
  if [ -n "$SCRATCH" ]; then
    rm -rf "$SCRATCH" 2>/dev/null || { echo "cleanup: scratch removal failed" >&2; status=1; }
  fi
  return "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent over a plain idle shell: a STALE registration -------
#
# This is the live blocker fixed by task
# fm-control-classifies-shell-as-live-agent: herdr's registry can outlive its
# agent (a hook-authoritative harness never deregisters on exit, and herdr has
# no agent-deregister verb), so a registration whose pane provably holds only
# a lone idle shell must classify agent-free, making exit idempotent success
# and recovery available. Before the fix this exact state read `alive`
# forever and every recovery verb refused. `pane report-agent` on the plain
# shell pane reproduces that state against the real registry: registered, but
# with no agent process behind it.

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register an agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] || fail "a registered agent over a provably lone idle shell is a stale registration and must classify dead, got '$STATE'"
pass "real herdr: a registration with no agent process behind it classifies dead (stale), not alive"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse a stale registration with no agent behind it: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the stale-registration interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses a stale registration instead of keying a dead shell"

OUT=$(run_control hsmoke exit) || fail "exit against a stale registration must be idempotent success (this was the unrecoverable state): $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "a stale registration should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a stale registration is idempotent success, so relaunch can proceed"

# --- a genuinely live agent: a registered agent WITH a real process ---------
#
# The paired negative: with a real long-running foreground process occupying
# the pane, the idle-shell proof fails, the registration keeps the benefit of
# the doubt, and the verbs treat the agent as alive - the cross-check must
# never let a live worker be exited or replaced.

fm_backend_herdr_send_literal "$SESSION:$PANE_ID" "sleep 300" \
  || fail "could not type the live-process model into the task pane"
fm_backend_herdr_send_key "$SESSION:$PANE_ID" Enter \
  || fail "could not start the live-process model in the task pane"

STATE=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
  [ "$STATE" = alive ] && break
  sleep 0.3
done
[ "$STATE" = alive ] || fail "a registered agent with a live foreground process must classify alive, got '$STATE'"
pass "real herdr: a registered agent with a live process stays alive through the cross-check"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a live agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it deliberately types a harness command into a pane whose
# foreground process ignores it: the live agent cannot actually be stopped
# that way, and the control plane must say so rather than report a stop it
# did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true

cleanup_all || { trap - EXIT; printf 'not ok - cleanup failed\n' >&2; exit 1; }
trap - EXIT
printf '\nall fm-control-herdr-smoke tests passed\n'
