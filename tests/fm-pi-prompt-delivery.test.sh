#!/usr/bin/env bash
# Tests for the primary Pi prompt delivery owner,
# .pi/extensions/lib/fm-pi-prompt-delivery.ts.
#
# Two layers, because they fail for different reasons:
# - A session double pins the join's routing, fall-through, stranded-message,
#   idempotence, and missing-seam reporting with no Pi installed.
# - The real Pi AgentSession, driven in-process through the installed Pi SDK
#   with a deterministic in-process provider, reproduces the captain-visible
#   collision for every Firstmate primary prompt shape (watcher wake, turn-end
#   guard nudge, supervision-branch processing request) and for a captain prompt
#   that loses to a Firstmate prompt. Each case first proves the unwrapped
#   session still rejects the overlapping prompt, so the fixed verdict cannot go
#   quietly vacuous on a Pi that stops racing. It skips only when the Pi package
#   is not installed; tests/fm-pi-prompt-collision-live-e2e.test.sh is the
#   opt-in guard that drives the same overlap through the real interactive TUI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-prompt-delivery)
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
export NODE_NO_WARNINGS=1

install_delivery_fixture() { # <dir> <real|stub>
  local dir=$1 package=$2
  mkdir -p "$dir/.pi/extensions/lib" "$dir/bin" "$dir/node_modules/@earendil-works"
  cp "$ROOT/.pi/extensions/lib/fm-pi-prompt-delivery.ts" "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
    "$dir/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
  chmod +x "$dir/bin/fm-operational-input.sh"
  printf '%s\n' '{"type":"module"}' > "$dir/package.json"
  if [ "$package" = real ]; then
    ln -s "$PI_PACKAGE_DIR" "$dir/node_modules/@earendil-works/pi-coding-agent"
    ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$dir/node_modules/@earendil-works/pi-ai"
    return
  fi
  mkdir -p "$dir/node_modules/@earendil-works/pi-coding-agent"
  printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' \
    > "$dir/node_modules/@earendil-works/pi-coding-agent/package.json"
  printf '%s\n' 'export const VERSION = "0.0.0-stub";' > "$dir/node_modules/@earendil-works/pi-coding-agent/index.js"
}

test_session_double_contract() {
  local fixture out status
  fixture="$TMP_ROOT/double"
  install_delivery_fixture "$fixture" stub
  cat > "$fixture/double.ts" <<'TS'
import { installPiPromptDelivery, installPromptJoin } from "./.pi/extensions/lib/fm-pi-prompt-delivery.ts";
import { encodeFirstmateOperationalInput } from "./.pi/extensions/lib/fm-operational-input.ts";

const fail = (message: string): never => {
  throw new Error(message);
};

class Queue {
  messages: unknown[] = [];
  hasItems() { return this.messages.length > 0; }
  drain() { const drained = this.messages; this.messages = []; return drained; }
}

// Pi 0.85.1's shape: a session-level run flag spanning prompt plus
// continuations, and an agent with steering and follow-up queues.
function sessionClass(lateJoin?: (session: DoubleSession) => void) {
  return class DoubleSession {
    _isAgentRunActive = false;
    isCompacting = false;
    runs: unknown[] = [];
    agent = {
      state: { isStreaming: false },
      steered: [] as unknown[],
      followed: [] as unknown[],
      steeringQueue: new Queue(),
      followUpQueue: new Queue(),
      steer(message: unknown) { this.steered.push(message); this.steeringQueue.messages.push(message); },
      followUp(message: unknown) { this.followed.push(message); this.followUpQueue.messages.push(message); },
      hasQueuedMessages() { return this.steeringQueue.hasItems() || this.followUpQueue.hasItems(); },
    };
    async _runAgentPrompt(messages: unknown) {
      this._isAgentRunActive = true;
      this.runs.push(messages);
      await new Promise((resolve) => setTimeout(resolve, 5));
      // The run's final queue check has passed; a late joiner lands here.
      lateJoin?.(this);
      this._isAgentRunActive = false;
    }
  };
}
type DoubleSession = InstanceType<ReturnType<typeof sessionClass>>;

const captain = { role: "user", content: [{ type: "text", text: "CAPTAIN" }] };
const digest = { role: "custom", customType: "firstmate-sessionstart-nudge", content: "DIGEST" };
const wake = { role: "user", content: [{ type: "text", text: encodeFirstmateOperationalInput("watcher", "WAKE") }] };
const processing = { role: "custom", customType: "fm-branch-process", content: "PROCESS" };

// A missing seam is reported with its Pi version, never patched around.
const stub = installPiPromptDelivery();
if (stub.ok || !stub.detail.includes("0.0.0-stub") || !stub.detail.includes("AgentSession is not exported")) {
  fail(`stub Pi did not report the missing AgentSession: ${JSON.stringify(stub)}`);
}
const seamless = installPromptJoin({ prototype: {} });
if (seamless.ok || !seamless.detail.includes("_runAgentPrompt")) fail(`missing seam was not reported: ${JSON.stringify(seamless)}`);

// Idle: the original run owns the prompt.
const Routing = sessionClass();
if (!installPromptJoin(Routing).ok) fail("install failed on a joinable session");
if (!installPromptJoin(Routing).ok) fail("a second install was not idempotent");
const idle = new Routing();
await idle._runAgentPrompt([captain]);
if (idle.runs.length !== 1 || idle.agent.steered.length + idle.agent.followed.length !== 0) {
  fail(`idle prompt did not run as its own turn: ${JSON.stringify(idle)}`);
}

// Running: captain input steers with its attached context, in order; every
// Firstmate shape follows up; nothing starts a second run.
const running = new Routing();
running._isAgentRunActive = true;
await running._runAgentPrompt([captain, digest]);
await running._runAgentPrompt([wake]);
await running._runAgentPrompt(processing);
if (running.runs.length !== 0) fail("a prompt that reached a running turn started its own run");
if (JSON.stringify(running.agent.steered) !== JSON.stringify([captain, digest])) {
  fail(`captain prompt was not steered with its context: ${JSON.stringify(running.agent.steered)}`);
}
if (JSON.stringify(running.agent.followed) !== JSON.stringify([wake, processing])) {
  fail(`Firstmate prompts were not queued as follow-ups exactly once: ${JSON.stringify(running.agent.followed)}`);
}

// The gap between a turn's last queue check and its settlement: the agent run
// has ended while the session run is still active. A join there is started as
// its own turn once the running turn settles.
let joined = false;
const Late = sessionClass((session) => {
  if (joined) return;
  joined = true;
  session.agent.state.isStreaming = false;
  void session._runAgentPrompt([wake]);
});
installPromptJoin(Late);
const late = new Late();
await late._runAgentPrompt([captain]);
await new Promise((resolve) => setTimeout(resolve, 30));
if (late.runs.length !== 2 || JSON.stringify(late.runs[1]) !== JSON.stringify([wake])) {
  fail(`a stranded join was not started after the running turn settled: ${JSON.stringify(late.runs)}`);
}
if (late.agent.hasQueuedMessages()) fail("a stranded join stayed queued behind an idle session");

// A session without Pi's queue API keeps Pi's own behavior.
const Opaque = class {
  runs = 0;
  _isAgentRunActive = true;
  agent = {};
  async _runAgentPrompt() { this.runs += 1; }
};
installPromptJoin(Opaque);
const opaque = new Opaque();
await opaque._runAgentPrompt();
if (opaque.runs !== 1) fail("a session without Pi's queue API did not fall through to its own run");
TS
  out=$(cd "$fixture" && FM_OPERATIONAL_INPUT_SCRIPT="$fixture/bin/fm-operational-input.sh" \
    node --experimental-strip-types "$fixture/double.ts" 2>&1)
  status=$?
  expect_code 0 "$status" "prompt delivery double contract: $out"
  [ -z "$out" ] || fail "prompt delivery double contract printed output: $out"
  pass "prompt delivery joins a running turn by shape (captain steers with context, Firstmate prompts follow up), starts a stranded join after settlement, installs idempotently, and reports a missing seam"
}

write_real_race() { # <fixture>
  cat > "$1/race.ts" <<'TS'
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "./.pi/extensions/lib/fm-operational-input.ts";

const scenario = process.env.FM_RACE_SCENARIO ?? "";
const patched = process.env.FM_RACE_PATCHED === "1";
const fail = (message: string): never => {
  throw new Error(`${scenario} (${patched ? "patched" : "unpatched"}): ${message}`);
};
if (patched) {
  const { installPiPromptDelivery } = await import("./.pi/extensions/lib/fm-pi-prompt-delivery.ts");
  const installed = installPiPromptDelivery();
  if (!installed.ok) fail(installed.detail);
}

const base = process.env.FM_RACE_TMP ?? fail("FM_RACE_TMP unset");
const agentDir = mkdtempSync(join(base, "agent-"));
const cwd = mkdtempSync(join(base, "cwd-"));
const text = (content: unknown): string => typeof content === "string"
  ? content
  : Array.isArray(content) ? content.filter((part) => part?.type === "text").map((part) => part.text).join("\n") : "";
const delivered: string[] = [];
let settles = 0;
let api: any;
let preflightStarted: (() => void) | null = null;

const factory = (pi: any) => {
  api = pi;
  pi.registerProvider("fm-race", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "fm-race-api",
    models: [{ id: "deterministic", name: "deterministic", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 64000, maxTokens: 64 }],
    streamSimple(model: any) {
      const stream = createAssistantMessageEventStream();
      const output: any = {
        role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: "stop", timestamp: Date.now(),
      };
      setTimeout(() => {
        stream.push({ type: "start", partial: output });
        output.content.push({ type: "text", text: "ok" });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      }, 300);
      return stream;
    },
  });
  pi.on("session_start", async (_event: unknown, ctx: any) => {
    await pi.setModel(ctx.modelRegistry.find("fm-race", "deterministic"));
  });
  // Preflight latency: the window in which both prompts decide to start a turn.
  pi.on("before_agent_start", async () => {
    preflightStarted?.();
    await new Promise((resolve) => setTimeout(resolve, 150));
  });
  pi.on("message_start", (event: any) => {
    if (event.message.role !== "assistant") delivered.push(text(event.message.content));
  });
  pi.on("agent_settled", () => { settles += 1; });
};

const loader = new DefaultResourceLoader({
  cwd, agentDir, extensionFactories: [factory],
  noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
} as any);
await loader.reload();
const modelRuntime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: join(agentDir, "models.json") } as any);
const { session } = await createAgentSession({ cwd, agentDir, resourceLoader: loader, sessionManager: SessionManager.inMemory(cwd), modelRuntime } as any);
const errors: string[] = [];
await session.bindExtensions({ onError: (error: any) => errors.push(`${error.extensionPath}: ${error.error}`) });

const nextPreflight = () => new Promise<void>((resolve) => {
  preflightStarted = () => {
    preflightStarted = null;
    resolve();
  };
});
const captainText = "CAPTAIN_PROBE";
const wake = encodeFirstmateOperationalInput("watcher", "FIRSTMATE WATCHER WAKE: signal: race probe");
const nudge = encodeFirstmateOperationalInput("turn-end-guard", "TURN WOULD END BLIND - race probe");
const processingText = "BRANCH_PROCESSING_PROBE";
const captainPrompt = () => session.prompt(captainText).catch((error: Error) => { errors.push(`captain: ${error.message}`); });
const settle = async () => {
  for (let i = 0; i < 200 && !session.isIdle; i += 1) await new Promise((resolve) => setTimeout(resolve, 20));
  await new Promise((resolve) => setTimeout(resolve, 500));
};

let expected: string[] = [];
let loser = "";
if (scenario === "control") {
  await captainPrompt();
  await settle();
  api.sendUserMessage(wake, { deliverAs: "followUp" });
  await settle();
  expected = [captainText, wake];
} else if (scenario === "wake-first") {
  const preflight = nextPreflight();
  api.sendUserMessage(wake, { deliverAs: "followUp" });
  await preflight;
  await captainPrompt();
  expected = [wake, captainText];
  loser = `captain: Agent is already processing a prompt`;
} else {
  const preflight = nextPreflight();
  const captain = captainPrompt();
  await preflight;
  if (scenario === "captain-first-wake") {
    api.sendUserMessage(wake, { deliverAs: "followUp" });
    expected = [captainText, wake];
    loser = `<runtime>: Agent is already processing a prompt`;
  } else if (scenario === "captain-first-nudge") {
    api.sendUserMessage(nudge, { deliverAs: "followUp" });
    expected = [captainText, nudge];
    loser = `<runtime>: Agent is already processing a prompt`;
  } else if (scenario === "captain-first-processing") {
    api.sendMessage({ customType: "fm-branch-process", content: processingText, display: false }, { triggerTurn: true, deliverAs: "followUp" });
    expected = [processingText, captainText];
    loser = `captain: Agent is already processing a prompt`;
  } else {
    fail("unknown scenario");
  }
  await captain;
}
await settle();
session.dispose();

if (!patched) {
  if (!errors.some((error) => error.startsWith(loser))) fail(`the unwrapped session no longer rejects the overlap (errors=${JSON.stringify(errors)} delivered=${JSON.stringify(delivered)})`);
  process.exit(0);
}
if (errors.length !== 0) fail(`overlap surfaced errors: ${JSON.stringify(errors)}`);
const missing = expected.filter((item) => delivered.filter((seen) => seen === item).length !== 1);
if (missing.length !== 0) fail(`not every prompt reached a model turn exactly once: delivered=${JSON.stringify(delivered)}`);
const wantSettles = scenario === "control" ? 2 : 1;
if (settles !== wantSettles) fail(`expected ${wantSettles} settled turn(s), saw ${settles}`);
process.exit(0);
TS
}

test_real_pi_overlap() {
  local fixture scenario patched out status version
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found for the real Pi prompt overlap"
    return 0
  fi
  version=$(node -p "require('$PI_PACKAGE_DIR/package.json').version")
  fixture="$TMP_ROOT/real"
  install_delivery_fixture "$fixture" real
  write_real_race "$fixture"
  for scenario in captain-first-wake captain-first-nudge captain-first-processing wake-first control; do
    for patched in 0 1; do
      [ "$scenario" = control ] && [ "$patched" = 0 ] && continue
      mkdir -p "$fixture/tmp-$scenario-$patched"
      out=$(cd "$fixture" && FM_RACE_SCENARIO="$scenario" FM_RACE_PATCHED="$patched" FM_RACE_TMP="$fixture/tmp-$scenario-$patched" \
        FM_OPERATIONAL_INPUT_SCRIPT="$fixture/bin/fm-operational-input.sh" \
        node --experimental-strip-types "$fixture/race.ts" 2>&1)
      status=$?
      expect_code 0 "$status" "real Pi $version prompt overlap $scenario patched=$patched: $out"
      [ -z "$out" ] || fail "real Pi $version prompt overlap $scenario patched=$patched printed output: $out"
    done
  done
  pass "real Pi $version: an overlapping watcher wake, turn-end nudge, branch processing request, or captain prompt is rejected without the delivery owner and reaches one model turn exactly once with it, while non-overlapping prompts still run as separate turns"
}

test_session_double_contract
test_real_pi_overlap

printf '\nall fm-pi-prompt-delivery tests passed\n'
