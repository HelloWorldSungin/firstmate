#!/usr/bin/env bash
# Real-Pi away-mode supervision-ownership regression.
#
# Opt-in because it launches a real interactive Pi primary loading the tracked
# .pi/extensions/fm-primary-pi-watch.ts, plus a real away-mode supervisor daemon,
# against a throwaway firstmate home on a private tmux socket. It proves the
# away-mode ownership contract end to end:
#   1. away mode is entered with an active task;
#   2. routine crew events are daemon-triaged with no ordinary Pi watcher turns;
#   3. a captain-relevant daemon escalation still reaches the primary;
#   4. away mode is exited;
#   5. exactly one extension-owned supervision cycle resumes.
#
# A task-local capture extension grants session-only trust and records the exact
# prompts delivered to the primary. No provider work is wanted here, so the Pi
# session runs with a placeholder credential pointed at a closed loopback port:
# every model request fails locally and no tokens are spent. If that harness
# cannot capture a prompt at all (a different default provider, for example), the
# test skips rather than reporting a false failure.
#
# No process is ever matched by pattern: only this home's recorded pids and this
# test's own private tmux socket are signalled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_AFK_PI_DUAL_SUPERVISION_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AFK_PI_DUAL_SUPERVISION_E2E=1 to run the real Pi away-mode supervision regression"
  exit 0
fi

for tool in pi tmux node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

TMP_ROOT=$(fm_test_tmproot fm-afk-pi-dual-supervision)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
CONFIG="$HOME_DIR/config"
PI_DIR="$TMP_ROOT/pi-agent"
PROJECT="$TMP_ROOT/project"
CAPTURE="$TMP_ROOT/pi-prompts.jsonl"
SOCK="fm-afk-pi-dual-$$"
SESSION="fmafkpi"
TASK=e2e-task
mkdir -p "$STATE" "$CONFIG" "$HOME_DIR/data" "$PI_DIR" "$PROJECT"
printf '# Synthetic isolated firstmate primary\n' > "$PROJECT/AGENTS.md"
: > "$CAPTURE"

cleanup() {
  local pid
  pid=$(cat "$STATE/.supervise-daemon.pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  sleep 0.5
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

cat > "$TMP_ROOT/capture-extension.ts" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";
const capturePath = process.env.FM_PI_CAPTURE_PATH!;
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("before_agent_start", (event, ctx) => {
    appendFileSync(capturePath, `${JSON.stringify({ prompt: event.prompt })}\n`);
    ctx.abort();
  });
}
EOF

count_capture() {  # <pattern>
  local n
  n=$(grep -c "$1" "$CAPTURE" 2>/dev/null | head -1 | tr -dc '0-9')
  printf '%s' "${n:-0}"
}
watcher_turns() { count_capture 'FIRSTMATE WATCHER WAKE'; }
daemon_escalations() { count_capture 'FIRSTMATE_OP: v1 away-supervisor'; }

# Read-only pid discovery for this repo's arm script. Never used to signal a
# process: the away-mode contract is proven by absence or presence, and killing
# by pattern could reach a sibling firstmate home.
arm_processes() { pgrep -f "$ROOT/bin/fm-watch-arm\\.sh" 2>/dev/null || true; }
arm_process_count() { arm_processes | grep -c . || true; }

wait_until() {  # <seconds> <predicate...>
  local deadline
  deadline=$(( $(date +%s) + $1 ))
  shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" && return 0
    sleep 0.5
  done
  return 1
}

# Sampling helpers: one arm cycle is restarted per wake, so a single instant can
# catch a legitimate gap. Ownership is proven over a window, not one snapshot.
arm_absent_for() {  # <seconds>
  local deadline
  deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    no_arm_process || return 1
    sleep 0.5
  done
  return 0
}

arm_stays_single_for() {  # <seconds>
  local deadline seen count
  seen=0
  deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    count=$(arm_process_count)
    [ "$count" -le 1 ] || return 1
    [ "$count" -eq 1 ] && seen=1
    sleep 0.5
  done
  [ "$seen" -eq 1 ]
}

capture_grew() { [ "$(watcher_turns)" -gt 0 ]; }
one_arm_process() { [ "$(arm_process_count)" -eq 1 ]; }
no_arm_process() { [ "$(arm_process_count)" -eq 0 ]; }
escalation_arrived() { [ "$(daemon_escalations)" -gt "$ESCALATIONS_BEFORE" ]; }
turns_grew() { [ "$(watcher_turns)" -gt "$TURNS_BEFORE" ]; }

# --- a real Pi primary loading the tracked watch extension -------------------
tmux -L "$SOCK" new-session -d -s "$SESSION" -x 200 -y 50
PANE=$(tmux -L "$SOCK" list-panes -t "$SESSION" -F '#{pane_id}' | head -1)
tmux -L "$SOCK" send-keys -t "$PANE" -l "cd $PROJECT && exec env PI_CODING_AGENT_DIR=$PI_DIR FM_HOME=$HOME_DIR FM_ROOT_OVERRIDE=$ROOT FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG FM_PI_CAPTURE_PATH=$CAPTURE ANTHROPIC_API_KEY=placeholder-no-provider-work ANTHROPIC_BASE_URL=http://127.0.0.1:9 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 pi -e $TMP_ROOT/capture-extension.ts -e $ROOT/.pi/extensions/fm-primary-pi-watch.ts --no-context-files --no-session"
tmux -L "$SOCK" send-keys -t "$PANE" Enter
sleep 6
PI_PID=$(tmux -L "$SOCK" display-message -p -t "$PANE" '#{pane_pid}')
[ -n "$PI_PID" ] || fail "the Pi primary did not start"
printf '%s\n' "$PI_PID" > "$STATE/.lock"

cat > "$STATE/$TASK.meta" <<META
window=$SESSION:0
project=e2e
harness=pi
kind=ship
META
echo "working: task under way" > "$STATE/$TASK.status"

# --- baseline: the extension owns exactly one cycle before away mode ---------
tmux -L "$SOCK" send-keys -t "$PANE" -l "/fm-watch-arm-pi"
sleep 1.5
tmux -L "$SOCK" send-keys -t "$PANE" Enter
sleep 1
tmux -L "$SOCK" capture-pane -p -t "$PANE" -S -200 2>/dev/null | grep -q 'watcher:' \
  || tmux -L "$SOCK" send-keys -t "$PANE" Enter
wait_until 30 one_arm_process || fail "the Pi extension did not arm its baseline supervision cycle"
wait_until 40 capture_grew || {
  echo "skip: this Pi configuration delivers no capturable prompt (no usable default provider)"
  exit 0
}
pass "Pi extension owns one supervision cycle before away mode"

# --- step 1: enter away mode -------------------------------------------------
cat > "$TMP_ROOT/daemon-entry" <<EOF
#!/usr/bin/env bash
export FM_HOME='$HOME_DIR'
export FM_ROOT_OVERRIDE='$ROOT'
export FM_STATE_OVERRIDE='$STATE'
export FM_CONFIG_OVERRIDE='$CONFIG'
export FM_SUPERVISOR_BACKEND=tmux
export FM_SUPERVISOR_TARGET='$PANE'
export FM_ESCALATE_BATCH_SECS=0
export FM_HOUSEKEEPING_TICK=1
export FM_POLL=1
export FM_SIGNAL_GRACE=1
export FM_HEARTBEAT=999999
export FM_CHECK_INTERVAL=999999
export FM_MAX_DEFER_SECS=3
export FM_STALE_ESCALATE_SECS=999999
export FM_WEDGE_ALARM_EXEC=discard
exec '$ROOT/bin/fm-afk-start.sh'
EOF
chmod +x "$TMP_ROOT/daemon-entry"
tmux -L "$SOCK" new-window -t "$SESSION" -d "$TMP_ROOT/daemon-entry; sleep 900"
wait_until 30 test -e "$STATE/.afk" || fail "away mode was never entered"
wait_until 30 test -s "$STATE/.supervise-daemon.pid" || fail "the away supervisor never started"
wait_until 30 no_arm_process \
  || fail "the Pi extension kept its own supervision cycle alongside the away supervisor: $(arm_processes)"
arm_absent_for 12 \
  || fail "the Pi extension re-armed its own supervision cycle during away mode: $(arm_processes)"
pass "away mode leaves the away supervisor as the only supervision cycle"

# --- step 2: routine events are daemon-triaged, with no Pi watcher turns -----
TURNS_BEFORE=$(watcher_turns)
echo "working: still going" >> "$STATE/$TASK.status"
sleep 6
echo "working: another routine step" >> "$STATE/$TASK.status"
sleep 10
[ "$(watcher_turns)" -eq "$TURNS_BEFORE" ] \
  || fail "ordinary Pi watcher turns were injected during away mode: $(watcher_turns) vs $TURNS_BEFORE"
no_arm_process || fail "an extension-owned cycle reappeared during away mode: $(arm_processes)"
pass "routine away-mode events are daemon-triaged with no ordinary Pi watcher turns"

# --- step 3: captain-relevant escalation still arrives -----------------------
ESCALATIONS_BEFORE=$(daemon_escalations)
echo "blocked: needs a captain decision" >> "$STATE/$TASK.status"
wait_until 60 escalation_arrived \
  || fail "the away supervisor never escalated the captain-relevant event to the primary"
pass "captain-relevant away-mode escalation still reaches the primary"

# --- step 4 and 5: return leaves exactly one extension-owned cycle ------------
echo "resolved: unblocked" >> "$STATE/$TASK.status"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
  FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$PANE" \
  "$ROOT/bin/fm-afk-return.sh" begin >/dev/null 2>&1 || true
[ -e "$STATE/.afk" ] && fail "away mode did not clear on return"
wait_until 40 one_arm_process \
  || fail "supervision did not resume as exactly one extension-owned cycle: $(arm_processes)"
arm_stays_single_for 8 \
  || fail "away-mode return did not settle on exactly one supervision cycle: $(arm_processes)"
TURNS_BEFORE=$(watcher_turns)
echo "working: post-return step" >> "$STATE/$TASK.status"
wait_until 40 turns_grew \
  || fail "ordinary Pi watcher supervision did not resume after away mode"
arm_stays_single_for 6 || fail "post-return supervision is not a single cycle: $(arm_processes)"
pass "away-mode return resumes exactly one extension-owned supervision cycle"

printf 'evidence: pi=%s tmux=%s watcher-turns-during-away=0 daemon-escalations=%s\n' \
  "$(pi --version)" "$(tmux -V)" "$(daemon_escalations)"
