#!/usr/bin/env bash
# Opt-in real Pi TUI regression for overlapping primary prompts.
#
# A captain prompt typed into the real interactive Pi and a real watcher wake
# from the tracked watch extension are made to overlap inside one preflight
# window, in both orders, before and after /reload. Without the delivery owner
# (.pi/extensions/lib/fm-pi-prompt-delivery.ts) Pi rejects whichever prompt's
# preflight settles second: the captain sees `Extension "<runtime>" error:
# Agent is already processing a prompt` or `Error: Agent is already processing a
# prompt`, and that message is dropped. This guard requires both messages to
# reach one model turn with no banner, and one monitoring cycle to keep running.
#
# Isolation: a private tmux socket, an isolated FM_HOME and Pi agent directory,
# an in-process deterministic provider (no credentials, no network), and a
# companion extension that adds preflight latency and records Pi's lifecycle.
# tests/fm-pi-prompt-delivery.test.sh owns the portable, always-run layer that
# also proves the unwrapped session still rejects each overlap.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_PI_PROMPT_COLLISION_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_PROMPT_COLLISION_LIVE_E2E=1 to run the real Pi TUI prompt-overlap regression"
  exit 0
fi

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"
PI_VERSION=$(pi --version 2>/dev/null) || fail "pi --version failed"
[ -n "$PI_VERSION" ] || fail "pi --version printed nothing"

TMP_ROOT=$(fm_test_tmproot fm-pi-prompt-collision-live-e2e)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
EVENTS="$TMP_ROOT/events.log"
COMPANION="$TMP_ROOT/companion.ts"
LAUNCH="$TMP_ROOT/launch-pi.sh"
SOCKET="fm-pi-collision-$$"
SESSION=pi-collision
PREFLIGHT_MS=3000
REPLY_MS=4000

cleanup() {
  local rc=$? pid
  trap - EXIT
  if tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    tmux -L "$SOCKET" send-keys -t "$SESSION" -l "/quit" >/dev/null 2>&1 || true
    tmux -L "$SOCKET" send-keys -t "$SESSION" Enter >/dev/null 2>&1 || true
    sleep 2
  fi
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  # The lab watcher runs under the tmux server, outside this shell's process
  # tree, so it is retired by its recorded pid when it is still this lab's.
  pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -Fxq "FM_HOME=$HOME_DIR"; then
    kill "$pid" 2>/dev/null || true
  fi
  if [ -n "${FM_COLLISION_KEEP:-}" ]; then
    printf 'kept lab: %s\n' "$TMP_ROOT" >&2
  else
    fm_test_cleanup
  fi
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR"/{state,config,data} "$PROJECT" "$PI_DIR"
printf '# Synthetic isolated prompt-overlap lab\n' > "$PROJECT/AGENTS.md"

cat > "$COMPANION" <<'TS'
import { type AssistantMessage, createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";

const log = process.env.FM_COLLISION_EVENTS ?? "/dev/null";
const preflightMs = Number(process.env.FM_COLLISION_PREFLIGHT_MS ?? "0");
const replyMs = Number(process.env.FM_COLLISION_REPLY_MS ?? "0");
const record = (line: string) => appendFileSync(log, `${line}\n`);
const label = (text: string) => text.includes("FIRSTMATE WATCHER WAKE: signal:")
  ? "wake-signal"
  : text.includes("FIRSTMATE WATCHER WAKE") ? "wake-other" : text.startsWith("CAPTAIN_") ? text.split(/\s/)[0] : "other";
const text = (content: unknown): string => typeof content === "string"
  ? content
  : Array.isArray(content) ? content.filter((part) => part?.type === "text").map((part) => part.text).join("\n") : "";

export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.registerProvider("fm-collision", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "fm-collision-api",
    models: [{ id: "deterministic", name: "deterministic", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 64000, maxTokens: 128 }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const users = context.messages.filter((message) => message.role === "user").map((message) => label(text(message.content)));
      const reply = `REPLY_SEES ${users.slice(-2).join("+")}`;
      const output: AssistantMessage = {
        role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: "stop", timestamp: Date.now(),
      };
      setTimeout(() => {
        stream.push({ type: "start", partial: output });
        output.content.push({ type: "text", text: reply });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      }, replyMs);
      return stream;
    },
  });
  pi.on("session_start", async (event, ctx) => {
    const model = ctx.modelRegistry.find("fm-collision", "deterministic");
    if (model) await pi.setModel(model);
    record(`session_start ${(event as { reason?: string }).reason ?? ""}`);
  });
  pi.on("input", (event) => {
    record(`input ${event.source} ${label(event.text)}`);
    record(`detail ${JSON.stringify(event.text.slice(0, 160))}`);
  });
  pi.on("before_agent_start", async (event) => {
    record(`before_agent_start ${label(event.prompt)}`);
    await new Promise((resolve) => setTimeout(resolve, preflightMs));
  });
  pi.on("agent_start", () => record("agent_start"));
  pi.on("message_start", (event) => {
    if (event.message.role === "user") record(`user ${label(text(event.message.content))}`);
  });
  pi.on("agent_settled", () => record("agent_settled"));
}
TS

cat > "$LAUNCH" <<EOF
#!/usr/bin/env bash
echo \$\$ > $(printf %q "$HOME_DIR/state/.lock")
cd $(printf %q "$PROJECT")
exec env \\
  FM_HOME=$(printf %q "$HOME_DIR") \\
  FM_ROOT_OVERRIDE=$(printf %q "$ROOT") \\
  PI_CODING_AGENT_DIR=$(printf %q "$PI_DIR") \\
  PI_OFFLINE=1 \\
  FM_COLLISION_EVENTS=$(printf %q "$EVENTS") \\
  FM_COLLISION_PREFLIGHT_MS=$PREFLIGHT_MS \\
  FM_COLLISION_REPLY_MS=$REPLY_MS \\
  FM_POLL=1 \\
  FM_SIGNAL_GRACE=0 \\
  FM_HEARTBEAT=600 \\
  FM_CHECK_INTERVAL=999999 \\
  pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions --no-session \\
    -e $(printf %q "$COMPANION") \\
    -e $(printf %q "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts") \\
    -e $(printf %q "$ROOT/.pi/extensions/fm-primary-pi-watch.ts")
EOF
chmod +x "$LAUNCH"

capture() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" -S -2000 2>/dev/null || true
}

type_line() { # <text>
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

event_count() { # <exact line> [first line]
  local count
  count=$(tail -n +"${2:-1}" "$EVENTS" 2>/dev/null | grep -Fxc "$1") || true
  printf '%s\n' "${count:-0}"
}

event_lines() {
  local lines
  lines=$(wc -l < "$EVENTS" 2>/dev/null) || true
  printf '%s\n' "${lines:-0}"
}

wait_event() { # <exact line> <count> <label> [first line]
  local i=0
  while [ "$i" -lt 600 ]; do
    [ "$(event_count "$1" "${4:-1}")" -ge "$2" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  capture >&2
  fail "timeout waiting for $3 (event '$1' x$2)"
}

watcher_alive() {
  local pid
  pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

completion=0
complete_worker() {
  completion=$((completion + 1))
  printf 'done: simulated completion %s\n' "$completion" >> "$HOME_DIR/state/collision.status"
}

# One overlap: <order> is captain-first or wake-first. Pi may also deliver an
# unrelated watcher wake (such as the re-arm resurfacing after /reload) into the
# same window; it must not be dropped either.
overlap() { # <order> <tag>
  local order=$1 tag=$2 captain="CAPTAIN_$2" from pane
  from=$(( $(event_lines) + 1 ))
  if [ "$order" = captain-first ]; then
    type_line "$captain overlap probe"
    wait_event "before_agent_start $captain" 1 "$tag captain preflight" "$from"
    complete_worker
    wait_event "before_agent_start wake-signal" 1 "$tag wake preflight during the captain preflight" "$from"
  else
    complete_worker
    wait_event "before_agent_start wake-signal" 1 "$tag wake preflight" "$from"
    type_line "$captain overlap probe"
    wait_event "before_agent_start $captain" 1 "$tag captain preflight during the wake preflight" "$from"
  fi
  wait_event "user $captain" 1 "$tag captain message to reach a model turn" "$from"
  wait_event "user wake-signal" 1 "$tag wake to reach a model turn" "$from"
  wait_event agent_settled 1 "$tag turn to settle" "$from"
  sleep 3
  # Both preflights began before the turn that carries both messages started,
  # and no settlement separates the two messages: the overlap was real and both
  # joined one turn.
  tail -n +"$from" "$EVENTS" | awk -v c="$captain" '
    $0 == "before_agent_start " c { cpre = 1; next }
    $0 == "before_agent_start wake-signal" { wpre = 1; next }
    $0 == "agent_start" { overlapped = cpre && wpre; next }
    $0 == "user " c { cuser = NR; cok = overlapped; next }
    $0 == "user wake-signal" { wuser = NR; wok = overlapped; next }
    $0 == "agent_settled" && cuser && !wuser { split_turn = 1 }
    $0 == "agent_settled" && wuser && !cuser { split_turn = 1 }
    END { exit (split_turn || !cuser || !wuser || !cok || !wok) }
  ' || fail "$tag did not overlap both preflights into one turn: $(tail -n +"$from" "$EVENTS" | grep -v '^detail ')"
  [ "$(event_count "user $captain" "$from")" -eq 1 ] || fail "$tag captain message did not reach a model turn exactly once"
  [ "$(event_count "user wake-signal" "$from")" -eq 1 ] || fail "$tag watcher wake did not reach a model turn exactly once"
  pane=$(capture)
  if printf '%s\n' "$pane" | grep -Fq 'already processing'; then
    fail "$tag showed the prompt-collision banner: $(printf '%s\n' "$pane" | grep -F 'already processing')"
  fi
  watcher_alive || fail "$tag left no live monitoring cycle"
  pass "real Pi $PI_VERSION TUI: $order overlap ($tag) delivers the captain message and the watcher wake in one turn with no banner"
}

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 "$LAUNCH; sleep 60"
wait_event "session_start startup" 1 "Pi startup"
i=0
while ! watcher_alive && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
watcher_alive || fail "the watch extension did not arm a monitoring cycle"
[ "$(sed -n 2p "$HOME_DIR/state/.pi-watch-extension-loaded" 2>/dev/null)" = "$(cat "$HOME_DIR/state/.lock")" ] \
  || fail "the primary did not record its own loaded-generation evidence"

# A non-overlapping warm-up absorbs the session-start delivery and is the
# healthy control: one captain turn, no banner.
type_line "CAPTAIN_WARMUP control"
wait_event "user CAPTAIN_WARMUP" 1 "the warm-up captain message"
wait_event agent_settled 1 "the warm-up turn"
sleep 2

cat > "$HOME_DIR/state/collision.meta" <<EOF
window=$SESSION:collision
backend=tmux
kind=ship
mode=direct-PR
worktree=$PROJECT
project=synthetic-prompt-collision
EOF

overlap captain-first before-reload-1
overlap wake-first before-reload-2

type_line "/reload"
wait_event "session_start reload" 1 "/reload"
i=0
while ! watcher_alive && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
sleep 2
overlap captain-first after-reload-1
overlap wake-first after-reload-2

watchers=$(pgrep -f "$ROOT/bin/fm-watch.sh" 2>/dev/null | while read -r pid; do
  tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -Fxq "FM_HOME=$HOME_DIR" && printf '%s\n' "$pid"
done | wc -l | tr -d ' ')
[ "$watchers" -eq 1 ] || fail "expected exactly one monitoring cycle for the lab home, found $watchers"
# Every prompt any source started reached a model turn: nothing was dropped,
# including watcher wakes unrelated to the probes.
for source in "extension wake-signal:wake-signal" "extension wake-other:wake-other" "interactive CAPTAIN_WARMUP:CAPTAIN_WARMUP"; do
  [ "$(event_count "input ${source%%:*}")" -eq "$(event_count "user ${source#*:}")" ] \
    || fail "a ${source#*:} prompt never reached a model turn: $(grep -v '^detail ' "$EVENTS")"
done

# A cycle the /reload itself interrupted has no successor by design; every
# other cycle must hand off to one.
unlinked=$(grep 'successor=none' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null | grep -v 'reason=arm-interrupted' || true)
[ -z "$unlinked" ] || fail "a monitoring cycle ended without a successor: $unlinked"
pass "real Pi $PI_VERSION TUI: overlapping prompts kept exactly one linked monitoring cycle across /reload"

printf '\nall fm-pi-prompt-collision-live-e2e tests passed\n'
