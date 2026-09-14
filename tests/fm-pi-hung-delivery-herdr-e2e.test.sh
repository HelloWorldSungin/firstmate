#!/usr/bin/env bash
# Opt-in real Pi/Herdr regression for later-cycle watcher restore under three
# branch-settlement controls. Every Herdr call is routed through fm-herdr-lab.sh.
# The named lab is never default. Each control gets an isolated FM_HOME.
#
#   hung     the branch accepts every wake and never settles; main turns abort
#            before any provider call.
#   slow     the branch accepts every wake and settles after a bounded delay.
#   healthy  no branch accepts, so every wake reaches main and runs a real model
#            turn against an in-process deterministic provider.
#
# Each control requires every actionable close to start a successor, a fresh
# beacon through an unattended interval, and exactly one monitoring cycle.
# The portable suite pins the same restore/delivery split without Pi.
#
# Lab ownership: by default this script provisions and tears down its own named
# lab. A caller that already provisioned one through fm-herdr-lab.sh passes it
# as HERDR_LAB_SESSION; the script then only runs commands inside it and leaves
# teardown to that caller.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

if [ "${FM_PI_HUNG_DELIVERY_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_HUNG_DELIVERY_HERDR_E2E=1 to run the isolated Pi settlement-control Herdr regression"
  exit 0
fi

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

herdr_forget_inherited_pane

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
OWN_LAB=0
if [ -n "${HERDR_LAB_SESSION:-}" ]; then
  SESSION=$HERDR_LAB_SESSION
else
  SESSION=$("$LAB_HELPER" name fm-pi-hung-deliv)
  OWN_LAB=1
fi
TMP_ROOT=$(fm_test_tmproot fm-pi-hung-delivery-herdr-e2e)
CONTROLS=${FM_PI_SETTLEMENT_CONTROLS:-"hung slow healthy"}
SLOW_SETTLE_MS=${FM_PI_SLOW_SETTLE_MS:-20000}
UNATTENDED_SECS=8
PANE=
HOME_DIR=

quit_pane() {
  [ -n "$PANE" ] || return 0
  "$LAB_HELPER" run "$SESSION" pane send-text "$PANE" '/quit' >/dev/null 2>&1 || true
  "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null 2>&1 || true
  sleep 2
  PANE=
}

cleanup() {
  local rc=$?
  trap - EXIT
  quit_pane
  if [ "$OWN_LAB" -eq 1 ] && ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

[ "$OWN_LAB" -eq 0 ] || "$LAB_HELPER" provision "$SESSION"

cycle_count() { # <needle>
  local needle=$1 file=$HOME_DIR/state/.watch-cycle-exits.log count=0
  if [ -f "$file" ]; then
    count=$(grep -cE "$needle" "$file" || true)
  fi
  printf '%s\n' "${count:-0}"
}

wait_started() { # <need>
  local need=$1 i=0
  while [ "$i" -lt 120 ]; do
    [ "$(cycle_count 'successor=started:')" -ge "$need" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

beacon_age_s() {
  local beat=$HOME_DIR/state/.last-watcher-beat now mtime
  [ -f "$beat" ] || return 1
  now=$(date +%s)
  mtime=$(stat -c %Y "$beat")
  printf '%s\n' "$((now - mtime))"
}

# Live watchers bound to this control's home; anything but one is a lost or
# duplicate monitoring cycle.
live_watchers() {
  local pid count=0
  for pid in $(pgrep -f "$ROOT/bin/fm-watch.sh" 2>/dev/null || true); do
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -Fxq "FM_HOME=$HOME_DIR"; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

write_companion() { # <control> <file>  (the control is read from the environment at load)
  local file=$2
  cat > "$file" <<'TS'
import { type AssistantMessage, createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";

const control = process.env.FM_SETTLEMENT_CONTROL ?? "";
const settleMs = Number(process.env.FM_SLOW_SETTLE_MS ?? "0");
const events = process.env.FM_SETTLEMENT_EVENTS ?? "/dev/null";
const record = (line: string) => appendFileSync(events, `${line}\n`);

export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.events?.on?.("fm-branch-supervision:dispatch", (data: { accept?: (p: Promise<void>) => void }) => {
    if (control === "hung") data.accept?.(new Promise(() => {}));
    if (control === "slow") {
      data.accept?.(new Promise((resolve) => setTimeout(resolve, settleMs)));
      record("slow-accepted");
    }
  });
  if (control !== "healthy") {
    pi.on("before_agent_start", (_event, ctx) => {
      ctx.abort();
    });
    return;
  }
  pi.registerProvider("fm-settlement", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "fm-settlement-api",
    models: [{ id: "deterministic", name: "deterministic", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 64000, maxTokens: 64 }],
    streamSimple(model) {
      record("provider-call");
      const stream = createAssistantMessageEventStream();
      const output: AssistantMessage = {
        role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: "stop", timestamp: Date.now(),
      };
      setTimeout(() => {
        stream.push({ type: "start", partial: output });
        output.content.push({ type: "text", text: "noted" });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      }, 200);
      return stream;
    },
  });
  pi.on("session_start", async (_event, ctx) => {
    const model = ctx.modelRegistry.find("fm-settlement", "deterministic");
    if (model) await pi.setModel(model);
  });
  pi.on("message_start", (event) => {
    if (event.message.role !== "user") return;
    const content = event.message.content;
    const text = typeof content === "string" ? content : content.map((part) => part.type === "text" ? part.text : "").join("");
    if (text.includes("FIRSTMATE WATCHER WAKE")) record("main-wake-turn");
  });
}
TS
}

run_control() { # <control>
  local control=$1 dir project pi_dir companion launch events out closes i age none
  dir="$TMP_ROOT/$control"
  HOME_DIR="$dir/home"
  project="$dir/project"
  pi_dir="$dir/pi-agent"
  companion="$dir/companion.ts"
  launch="$dir/launch-pi.sh"
  events="$dir/events.log"
  mkdir -p "$HOME_DIR"/{state,config,data} "$project" "$pi_dir"
  printf '# Synthetic isolated %s settlement lab\n' "$control" > "$project/AGENTS.md"
  write_companion "$control" "$companion"

  local model_flags="--model openai-codex/gpt-5.6-sol --thinking low"
  [ "$control" != healthy ] || model_flags=
  cat > "$launch" <<EOF
#!/usr/bin/env bash
set -u
echo \$\$ > $(printf %q "$HOME_DIR/state/.lock")
exec env \\
  FM_HOME=$(printf %q "$HOME_DIR") \\
  FM_ROOT_OVERRIDE=$(printf %q "$ROOT") \\
  PI_CODING_AGENT_DIR=$(printf %q "$pi_dir") \\
  PI_OFFLINE=1 \\
  FM_SETTLEMENT_CONTROL=$control \\
  FM_SLOW_SETTLE_MS=$SLOW_SETTLE_MS \\
  FM_SETTLEMENT_EVENTS=$(printf %q "$events") \\
  FM_POLL=1 \\
  FM_SIGNAL_GRACE=0 \\
  FM_HEARTBEAT=600 \\
  FM_CHECK_INTERVAL=999999 \\
  pi --approve --no-session --no-context-files --no-extensions \\
    -e $(printf %q "$companion") \\
    -e $(printf %q "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts") \\
    -e $(printf %q "$ROOT/.pi/extensions/fm-primary-pi-watch.ts") \\
    $model_flags
EOF
  chmod +x "$launch"

  out=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$project" --label "fm-pi-$control" --no-focus) \
    || fail "$control: Herdr lab workspace create failed"
  PANE=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id') \
    || fail "$control: Herdr lab workspace create omitted pane id"
  "$LAB_HELPER" run "$SESSION" pane run "$PANE" "$launch" >/dev/null \
    || fail "$control: could not launch isolated Pi in the named Herdr lab"

  i=0
  while [ "$i" -lt 120 ]; do
    [ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] && [ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] && break
    sleep 0.5
    i=$((i + 1))
  done
  [ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] && [ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] \
    || fail "$control: Pi watch and turn-end extensions did not load in the isolated lab"

  # The synthetic worker's endpoint is recorded on a tmux target that cannot
  # exist, so the watcher's endpoint probes never issue a Herdr call outside
  # fm-herdr-lab.sh; only the status line drives these closes.
  cat > "$HOME_DIR/state/settlement.meta" <<EOF
window=fm-pi-settlement-absent-$$:synthetic-worker
backend=tmux
kind=ship
mode=direct-PR
worktree=$project
project=synthetic-$control-settlement
EOF

  closes=4
  for i in $(seq 1 "$closes"); do
    printf 'done: simulated %s completion %s\n' "$control" "$i" >> "$HOME_DIR/state/settlement.status"
    wait_started "$i" || fail "$control: actionable close $i did not start a successor"
    sleep 1
  done
  none=$(cycle_count 'successor=none')
  [ "$none" -eq 0 ] || fail "$control: an actionable close left successor=none (none=$none)"

  if [ "$control" = slow ]; then
    # Outlive every accepted settlement so later closes run after they resolve.
    sleep $(( SLOW_SETTLE_MS / 1000 + 2 ))
  fi
  sleep "$UNATTENDED_SECS"
  age=$(beacon_age_s) || fail "$control: watcher beacon missing after the unattended interval"
  [ "$age" -le $((UNATTENDED_SECS + 5)) ] || fail "$control: watcher beacon went stale (age=${age}s)"

  printf 'done: simulated %s completion %s\n' "$control" "$((closes + 1))" >> "$HOME_DIR/state/settlement.status"
  wait_started "$((closes + 1))" || fail "$control: the close after the unattended interval did not start a successor"
  [ "$(cycle_count 'successor=none')" -eq 0 ] || fail "$control: the unattended interval recorded successor=none"
  sleep 2
  [ "$(live_watchers)" -eq 1 ] || fail "$control: expected exactly one monitoring cycle, found $(live_watchers)"

  case "$control" in
    slow)
      grep -q '^slow-accepted$' "$events" 2>/dev/null || fail "slow: the branch never accepted a wake, so the control was vacuous"
      ;;
    healthy)
      [ "$(grep -c '^main-wake-turn$' "$events" 2>/dev/null || true)" -ge "$closes" ] \
        || fail "healthy: wakes did not reach real main turns: $(cat "$events" 2>/dev/null)"
      [ "$(grep -c '^provider-call$' "$events" 2>/dev/null || true)" -ge "$closes" ] \
        || fail "healthy: main wake turns made no provider calls"
      if "$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 400 2>/dev/null | grep -Fq 'already processing'; then
        fail "healthy: the prompt-collision banner appeared"
      fi
      ;;
  esac
  quit_pane
  printf 'ok - isolated Pi %s-settlement Herdr lab linked every close, kept a fresh beacon, and ran exactly one monitoring cycle\n' "$control"
}

for control in $CONTROLS; do
  run_control "$control"
done

printf '\nall fm-pi-hung-delivery-herdr-e2e tests passed\n'
