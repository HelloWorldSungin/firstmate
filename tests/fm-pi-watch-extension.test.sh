#!/usr/bin/env bash
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
# Node 24 warns when these test-only dynamic imports load tracked ESM plugins
# from a clean checkout with no tracked .opencode/package.json. The warning is
# unrelated to plugin output, which the assertions intentionally require empty.
export NODE_NO_WARNINGS=1

# One owner for the readiness budget every unready-successor test below spends
# on purpose. Both plugins start a successor arm through a login shell and
# SIGTERM it when it stays silent past this budget, so the budget has to outlast
# a cold login-shell start. A successor killed before its first statement never
# appends its arm row and never installs the TERM trap these tests observe, so
# too small a budget reports a lost successor instead of the bounded recovery
# under test. A stock login shell already costs about 200ms on an idle
# workstation, and a loaded CI runner is slower, so keep an order of magnitude
# over that rather than a value that only holds locally. The wait loops in those
# tests are sized against this number.
ARM_READY_TIMEOUT_MS=2000

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

test_pi_extension_reports_external_healthy_watcher() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-external-healthy-root"
  home="$TMP_ROOT/pi-external-healthy-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let handler = null;
let notification = "";
let prompt = "";
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompt = message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!handler) {
  console.error("Pi watch command was not registered");
  process.exit(1);
}
const result = await handler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (result !== undefined) {
  console.error(`Pi command returned a value: ${String(result)}`);
  process.exit(1);
}
if (!notification.includes("started Pi extension arm child")) {
  console.error(notification);
  process.exit(1);
}
for (let i = 0; i < 1000 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.startsWith("\u2063FIRSTMATE_OP: v1 watcher: ")) {
  console.error(`untyped operational follow-up: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) {
  console.error(`missing follow-up prompt: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("external healthy watcher")) {
  console.error(prompt);
  process.exit(1);
}
if (!prompt.includes("watcher: healthy pid=1")) {
  console.error(prompt);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must surface an external healthy watcher as an owned-wake failure"
  [ -z "$out" ] || fail "Pi external-healthy test printed output: $out"
  pass "Pi extension reports external healthy watcher output"
}

test_pi_tool_returns_agent_tool_result() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-tool-result-root"
  home="$TMP_ROOT/pi-tool-result-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
if (tool.label !== "Arm firstmate watcher") throw new Error(`unexpected label: ${tool.label}`);
if (tool.parameters?.type !== "object") throw new Error("tool parameters are not a TypeBox object schema");
const metadata = [tool.description, tool.promptSnippet, ...(tool.promptGuidelines ?? [])].join("\n");
if (metadata.includes("Always use this tool")) throw new Error(`broad tool-selection metadata remained visible: ${metadata}`);
if (!tool.description.includes("first required Pi watcher cycle")) throw new Error(`tool description omitted the first-cycle condition: ${tool.description}`);
if (!tool.promptSnippet.includes("ordinary re-arming is automatic")) throw new Error(`tool snippet omitted automatic continuation: ${tool.promptSnippet}`);
if (!tool.promptGuidelines.some((guideline) => guideline.includes("ordinary signal, stale, check, or heartbeat handling"))) {
  throw new Error(`tool guidelines omitted ordinary-notification prevention: ${tool.promptGuidelines}`);
}
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!Array.isArray(result.content) || result.content[0]?.type !== "text") {
  throw new Error(`invalid tool content: ${JSON.stringify(result)}`);
}
if (!result.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`unexpected tool text: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("future ordinary re-arms are automatic")) {
  throw new Error(`initial tool result omitted automatic continuation guidance: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`initial tool result omitted the repair-only condition: ${result.content[0].text}`);
}
if (result.details?.ok !== true || result.details?.message !== result.content[0].text) {
  throw new Error(`invalid tool details: ${JSON.stringify(result.details)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi custom tool must expose first-cycle or repair-only metadata and return Pi's AgentToolResult shape"
  [ -z "$out" ] || fail "Pi tool-result test printed output: $out"
  pass "Pi custom tool exposes repair-only metadata and returns automatic-continuation guidance"
}

test_pi_redundant_tool_call_is_owned_noop() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-redundant-tool-root"
  home="$TMP_ROOT/pi-redundant-tool-home"
  log="$TMP_ROOT/pi-redundant-tool.log"
  stop="$TMP_ROOT/pi-redundant-tool.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const initial = await tool.execute("tool-call-first", {}, undefined, undefined, {});
if (!initial.content[0]?.text.includes("started Pi extension arm child")) {
  throw new Error(`initial call did not start the arm child: ${initial.content[0]?.text}`);
}
const redundant = await tool.execute("tool-call-redundant", {}, undefined, undefined, {});
if (!redundant.content[0]?.text.includes("Pi extension already owns an arm child; no manual re-arm needed")) {
  throw new Error(`redundant call omitted ownership-based no-op guidance: ${redundant.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`redundant call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`redundant call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
// Event wait: fails only when the child never starts, so a 20s ceiling
// absorbs CI runner contention without weakening any assertion.
for (let i = 0; i < 2000 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("initial arm child did not start");
// Stability window on the launch count, which unlike the fixture log does not
// depend on how quickly the runner schedules child shells.
await new Promise((resolve) => setTimeout(resolve, 100));
if (armSpawns !== 1) throw new Error(`redundant call spawned ${armSpawns - 1} extra arm children`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi redundant tool call must remain an ownership-based no-op with repair-only guidance"
  [ -z "$out" ] || fail "Pi redundant-call test printed output: $out"
  pass "Pi redundant tool call returns ownership guidance and spawns no second child"
}

test_pi_scheduled_retry_call_is_owned_noop() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-scheduled-retry-root"
  home="$TMP_ROOT/pi-scheduled-retry-home"
  log="$TMP_ROOT/pi-scheduled-retry.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=10000 FM_WATCH_REARM_RETRY_MAX_MS=10000 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-first", {}, undefined, undefined, {});
// Event wait: the ownership guidance can only appear once the initial arm
// close has been observed, so the ceiling fires only on genuine failure and
// 20s absorbs CI runner contention without weakening any assertion.
let redundant = null;
for (let i = 0; i < 2000; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
  redundant = await tool.execute("tool-call-during-retry", {}, undefined, undefined, {});
  if (redundant.content[0]?.text.includes("scheduled continuity retry")) break;
}
if (!redundant?.content[0]?.text.includes("Pi extension already owns a scheduled continuity retry; no manual re-arm needed")) {
  throw new Error(`scheduled retry did not return ownership-based no-op guidance: ${redundant?.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`scheduled retry call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`scheduled retry call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
// Stability window on the launch count, which unlike the fixture log does not
// depend on how quickly the runner schedules child shells. The extension-owned
// retry itself cannot fire inside it because the retry base is 10s.
await new Promise((resolve) => setTimeout(resolve, 100));
if (armSpawns !== 1) throw new Error(`scheduled retry call spawned ${armSpawns - 1} extra arm children`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi scheduled-retry call must not duplicate the extension-owned retry"
  [ -z "$out" ] || fail "Pi scheduled-retry test printed output: $out"
  pass "Pi scheduled retry remains extension-owned after another tool call"
}

test_pi_actionable_close_starts_single_successor_before_delivery() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-continuous-rearm-root"
  home="$TMP_ROOT/pi-continuous-rearm-home"
  log="$TMP_ROOT/pi-continuous-rearm.log"
  stop="$TMP_ROOT/pi-continuous-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveryStarted = false;
let armSpawns = 0;
let successorSpawns = 0;
let successorSpawnsAtDelivery = 0;
let successorStartedAtDelivery = false;
const successorPredecessors = [];
let releaseDelivery = () => {};
const deliveryBlocked = new Promise((resolve) => {
  releaseDelivery = resolve;
});
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm); the spawn call is the successor launch, so counting it does not
  // race the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) {
    armSpawns += 1;
    if (args[2].env.FM_WATCH_PREDECESSOR_ARM_PID) {
      successorSpawns += 1;
      successorPredecessors.push(args[2].env.FM_WATCH_PREDECESSOR_ARM_PID);
    }
  }
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    successorSpawnsAtDelivery = successorSpawns;
    successorStartedAtDelivery = rows().some((row) => /predecessor=[0-9]+/.test(row));
    deliveryStarted = true;
    await deliveryBlocked;
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-continuity", {}, undefined, undefined, {});
// Wait on the observable events - delivery beginning and the successor child
// appending its row. The ceilings fire only when an event never happens, so
// 20s absorbs CI runner contention without weakening any assertion.
for (let i = 0; i < 2000 && !deliveryStarted; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!deliveryStarted) throw new Error("wake delivery did not begin");
if (successorSpawnsAtDelivery !== 1) throw new Error(`wake delivery began with ${successorSpawnsAtDelivery} successor launches`);
if (!successorStartedAtDelivery) throw new Error("wake delivery began before the successor arm child started");
if (!/^[0-9]+$/.test(successorPredecessors[0] ?? "")) throw new Error(`successor launch missing predecessor identity: ${successorPredecessors.join(" | ")}`);
for (let i = 0; i < 2000 && rows().length < 2; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (rows().length < 2) throw new Error(`successor arm child did not start: ${rows().join(" | ")}`);
if (!/predecessor=[0-9]+/.test(rows()[1])) throw new Error(`successor did not receive predecessor identity: ${rows()[1]}`);
// Stability window: single-flight holds, so no further arm launches happen
// once the successor is up and delivery has begun.
await new Promise((resolve) => setTimeout(resolve, 100));
if (armSpawns !== 2 || successorSpawns !== 1) throw new Error(`single-flight violation launched ${armSpawns} arms (${successorSpawns} successors): ${rows().join(" | ")}`);
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.filter((row) => row.startsWith("arm=")).length !== 2) {
  throw new Error(`blocked follow-up started extra arm work: ${stableRows.join(" | ")}`);
}
if (stableRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${stableRows.join(" | ")}`);
}
releaseDelivery();
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi actionable close must start one successor before wake delivery settles"
  [ -z "$out" ] || fail "Pi continuous-rearm test printed output: $out"
  pass "Pi actionable close starts one successor before wake delivery settles"
}

test_pi_handling_delivery_failure_is_typed_once() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-handling-fail-root"
  home="$TMP_ROOT/pi-handling-fail-home"
  log="$TMP_ROOT/pi-handling-fail.log"
  stop="$TMP_ROOT/pi-handling-fail.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'refused generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 1
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-handling-fail", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt.includes("handling delivery confirmation was rejected"); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) throw new Error(`missing follow-up: ${prompt}`);
if (!prompt.includes("handling delivery confirmation was rejected")) {
  throw new Error(`failed handshake was swallowed: ${prompt}`);
}
if ((prompt.match(/FIRSTMATE WATCHER WAKE/g) || []).length !== 1) {
  throw new Error(`failed handshake was not a single typed message: ${prompt}`);
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.filter((row) => row.startsWith("refused ")).length < 1) {
  throw new Error(`handling-delivered was never attempted: ${rows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must surface a refused handling handshake as one typed failure"
  [ -z "$out" ] || fail "Pi handling-delivery failure test printed output: $out"
  pass "Pi refused handling handshake is classified and not swallowed"
}

test_pi_hung_successor_falls_back_to_typed_wake() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-hung-successor-root"
  home="$TMP_ROOT/pi-hung-successor-home"
  log="$TMP_ROOT/pi-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let successorAttempts = 0;
let successorAttemptsAtPrompt = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  if (args[2]?.env?.FM_WATCH_PREDECESSOR_ARM_PID) successorAttempts += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    successorAttemptsAtPrompt = successorAttempts;
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-hung-successor", {}, undefined, undefined, {});
for (let i = 0; i < 2000 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!prompt) throw new Error("hung-successor prompt did not arrive within ceiling");
// The spawn call is the restoration attempt. Waiting for the child shell to
// append its fixture row races process scheduling against the ready timeout.
if (successorAttemptsAtPrompt < 1) throw new Error("wake arrived before restoration was attempted");
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, 200));
if (successorAttempts !== successorAttemptsAtPrompt) throw new Error(`single-flight recovery launched additional ${successorAttempts - successorAttemptsAtPrompt} arms after delivery`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must deliver the actionable wake after bounded hung-successor recovery${out:+: $out}"
  [ -z "$out" ] || fail "Pi hung-successor test printed output: $out"
  pass "Pi hung successor falls back to one typed actionable wake"
}

test_pi_unretired_successor_falls_back_without_retry() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-unretired-successor-root"
  home="$TMP_ROOT/pi-unretired-successor-home"
  log="$TMP_ROOT/pi-unretired-successor.log"
  release="$TMP_ROOT/pi-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let successorAttempts = 0;
let successorAttemptsAtPrompt = 0;
let retireRequests = 0;
let retireRequestsAtPrompt = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  const child = originalSpawn(...args);
  if (args[2]?.env?.FM_WATCH_PREDECESSOR_ARM_PID) {
    successorAttempts += 1;
    const originalKill = child.kill.bind(child);
    child.kill = (signal, ...killArgs) => {
      if (signal === "SIGTERM") {
        retireRequests += 1;
        return true;
      }
      return originalKill(signal, ...killArgs);
    };
  }
  return child;
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    successorAttemptsAtPrompt = successorAttempts;
    retireRequestsAtPrompt = retireRequests;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-unretired-successor", {}, undefined, undefined, {});
for (let i = 0; i < 2000 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!prompt) throw new Error("unretired-successor prompt did not arrive within ceiling");
// Spawn and kill are the lifecycle events under test. Waiting for the child
// shell to append a fixture row races process scheduling against the timeout.
if (successorAttemptsAtPrompt !== 1) throw new Error(`fallback observed ${successorAttemptsAtPrompt} successor attempts`);
if (retireRequestsAtPrompt !== 1) throw new Error(`fallback observed ${retireRequestsAtPrompt} retirement requests`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm was still running when the 20ms retirement deadline settled or did not close within the additional 20ms grace after exit")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must fall back without overlapping an unretired successor${out:+: $out}"
  [ -z "$out" ] || fail "Pi unretired-successor test printed output: $out"
  pass "Pi unretired successor falls back without an overlapping retry"
}

# Deterministic regression for the retirement deadline races: a successor exits
# across the retire deadline while an inherited stdio pipe keeps its close
# pending, then the pipe closes while the event loop is stalled across the grace
# deadline. The next timers phase always races the queued close at both verdicts
# - the interleaving a contended CI runner produces by starvation.
test_pi_retired_successor_close_at_deadline_keeps_continuity() {
  local repo home plugin log retire_ready recovery_ready term_seen retire_release exit_marker stdio_release stdio_exit stop out status
  repo="$TMP_ROOT/pi-retire-settle-root"
  home="$TMP_ROOT/pi-retire-settle-home"
  log="$TMP_ROOT/pi-retire-settle.log"
  retire_ready="$TMP_ROOT/pi-retire-settle.ready"
  recovery_ready="$TMP_ROOT/pi-retire-settle.recovery-ready"
  term_seen="$TMP_ROOT/pi-retire-settle.term-seen"
  retire_release="$TMP_ROOT/pi-retire-settle.retire-release"
  exit_marker="$TMP_ROOT/pi-retire-settle.exit-marker"
  stdio_release="$TMP_ROOT/pi-retire-settle.stdio-release"
  stdio_exit="$TMP_ROOT/pi-retire-settle.stdio-exit"
  stop="$TMP_ROOT/pi-retire-settle.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  on_term() {
    printf 'seen\n' > "${FM_TERM_SEEN_FILE:?}"
    while [ ! -e "${FM_RETIRE_RELEASE_FILE:?}" ]; do sleep 0.02; done
    (
      while [ ! -e "${FM_STDIO_RELEASE_FILE:?}" ]; do sleep 0.02; done
      printf 'gone\n' > "${FM_STDIO_EXIT_FILE:?}"
    ) &
    printf 'gone\n' > "${FM_EXIT_MARKER_FILE:?}"
    exit 0
  }
  trap on_term TERM
  printf 'ready\n' > "${FM_RETIRE_READY_FILE:?}"
  while :; do sleep 0.02; done
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'ready\n' > "${FM_RECOVERY_READY_FILE:?}"
trap 'exit 0' TERM INT
while [ ! -e "${FM_STOP_FILE:?}" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RETIRE_READY_FILE="$retire_ready" FM_RECOVERY_READY_FILE="$recovery_ready" FM_TERM_SEEN_FILE="$term_seen" FM_RETIRE_RELEASE_FILE="$retire_release" FM_EXIT_MARKER_FILE="$exit_marker" FM_STDIO_RELEASE_FILE="$stdio_release" FM_STDIO_EXIT_FILE="$stdio_exit" FM_STOP_FILE="$stop" FM_PI_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=200 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let successorAttempts = 0;
let retireStalled = false;
// Barriers that establish the test setup, so runner scheduling never decides
// it: the arm child has provably reached the marked point before the plugin
// gets to arm any deadline against it. The event-loop stalls below still
// decide the retirement verdict.
const awaitFixture = (path, what) => {
  const deadline = Date.now() + 5000;
  while (!existsSync(path)) {
    if (Date.now() >= deadline) throw new Error(`fixture timed out ${what}: ${path}`);
  }
};
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  const successor = Boolean(args[2]?.env?.FM_WATCH_PREDECESSOR_ARM_PID);
  const child = originalSpawn(...args);
  if (successor) {
    successorAttempts += 1;
    if (successorAttempts === 1) {
      // SIGTERM must not arrive before the retiring successor installs its handler.
      awaitFixture(process.env.FM_RETIRE_READY_FILE, "installing retirement handler");
    } else {
      // The readiness deadline is armed once this spawn returns, so the recovery
      // arm's readiness line must already be written. Otherwise a starved runner
      // that cannot start bash within the readiness deadline spends an extra
      // retry here and the retirement verdict under test is no longer what the
      // successor count measures.
      awaitFixture(process.env.FM_RECOVERY_READY_FILE, "producing recovery readiness");
    }
    const originalKill = child.kill.bind(child);
    child.kill = (signal, ...killArgs) => {
      const delivered = originalKill(signal, ...killArgs);
      if (signal === "SIGTERM" && !retireStalled) {
        retireStalled = true;
        // The retire timer is armed synchronously after this kill call
        // returns. From the check phase, release the held successor and spin
        // past the retire deadline while its inherited stdio remains open.
        // After the first settle arms the grace timer, release that pipe and
        // spin past grace so the queued close races its deadline too.
        setImmediate(() => {
          writeFileSync(process.env.FM_RETIRE_RELEASE_FILE, "release\n");
          const exitDeadline = Date.now() + 5000;
          while (!existsSync(process.env.FM_EXIT_MARKER_FILE)) {
            if (Date.now() >= exitDeadline) {
              throw new Error(`fixture timed out waiting for exit marker: ${process.env.FM_EXIT_MARKER_FILE}`);
            }
          }
          const settle = Date.now() + 350;
          while (Date.now() < settle) { /* spin */ }
          setImmediate(() => setImmediate(() => {
            writeFileSync(process.env.FM_STDIO_RELEASE_FILE, "release\n");
            const stdioDeadline = Date.now() + 5000;
            while (!existsSync(process.env.FM_STDIO_EXIT_FILE)) {
              if (Date.now() >= stdioDeadline) {
                throw new Error(`fixture timed out waiting for stdio-exit marker: ${process.env.FM_STDIO_EXIT_FILE}`);
              }
            }
            const graceSettle = Date.now() + 350;
            while (Date.now() < graceSettle) { /* spin */ }
          }));
        });
      }
      return delivered;
    };
  }
  return child;
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-retire-settle", {}, undefined, undefined, {});
for (let i = 0; i < 2000 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
try {
  if (!prompt) throw new Error("restored wake was not delivered");
  if (!existsSync(process.env.FM_TERM_SEEN_FILE)) throw new Error("successor was never asked to retire");
  if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
  // Match the failure by what it means, not by one release's phrasing: any
  // wording of a lost-continuity verdict must fail this regression.
  if (prompt.includes("could not restore watcher continuity")) throw new Error(`retired successor lost continuity: ${prompt}`);
  if (successorAttempts !== 2) throw new Error(`restoration did not continue after retirement: ${successorAttempts} successor attempts`);
} finally {
  writeFileSync(process.env.FM_STOP_FILE, "stop\n");
  await new Promise((resolve) => setTimeout(resolve, 80));
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must honor a successor that exited by the retire deadline${out:+: $out}"
  [ -z "$out" ] || fail "Pi retire-settle test printed output: $out"
  pass "Pi retirement honors a queued close at the deadline and keeps continuity"
}

test_pi_late_unretired_close_resumes_supervision() {
  local kind repo home plugin log ready release stop out status
  for kind in actionable non-actionable; do
    repo="$TMP_ROOT/pi-late-$kind-root"
    home="$TMP_ROOT/pi-late-$kind-home"
    log="$TMP_ROOT/pi-late-$kind.log"
    ready="$TMP_ROOT/pi-late-$kind.ready"
    release="$TMP_ROOT/pi-late-$kind.release"
    stop="$TMP_ROOT/pi-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    install_pi_watch_extension_fixture "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  trap '' TERM INT
  printf 'ready\n' > "${FM_UNRETIRED_READY_FILE:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_UNRETIRED_READY_FILE="$ready" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
let armSpawns = 0;
let retireRequests = 0;
let retireRequestsAtPrompt = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  const child = originalSpawn(...args);
  if (args[2]?.env?.FM_WATCH_PREDECESSOR_ARM_PID) {
    const originalKill = child.kill.bind(child);
    child.kill = (signal, ...killArgs) => {
      // Hold the successor open deterministically until the release event.
      // The retirement request itself is the lifecycle event under test; a
      // shell trap is not a reliable process-boundary oracle under load.
      if (signal === "SIGTERM") {
        retireRequests += 1;
        return true;
      }
      return originalKill(signal, ...killArgs);
    };
  }
  return child;
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    retireRequestsAtPrompt = retireRequests;
    prompts.push(message);
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  // Event waits fail only when the event never happens; a 20s ceiling absorbs
  // CI runner contention without weakening any assertion.
  for (let i = 0; i < 2000; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-late-close", {}, undefined, undefined, {});
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_READY_FILE),
  "unretired successor did not enter its retirement wait",
);
await waitFor(() => prompts.length >= 1, "original fallback was not delivered");
// The intercepted kill call is the retirement request; withholding it keeps
// the successor unretired deterministically until the release event.
if (retireRequestsAtPrompt < 1) throw new Error("unretired successor was not asked to retire before fallback");
if (armSpawns !== 2) throw new Error(`unretired arm overlapped before fallback: ${armSpawns} arm launches: ${rows().join(" | ")}`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
// The restored supervisor is the third arm launch; an actionable late close
// must also deliver its wake. Both are observable events, so the ceiling
// never decides the verdict.
await waitFor(
  () => armSpawns >= 3 && (process.env.FM_LATE_KIND !== "actionable" || prompts.some((message) => message.includes("late wake"))),
  "late close did not restore one successor",
);
await waitFor(() => rows().length >= 3, "restored arm child did not start");
// Sample the exact count only after the restore event, holding a short
// stability window so a duplicate restore cannot hide behind the sample.
await new Promise((resolve) => setTimeout(resolve, 100));
if (armSpawns !== 3) throw new Error(`late close restored ${armSpawns - 2} successors: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
    status=$?
    expect_code 0 "$status" "Pi late $kind close must remain supervised after fallback${out:+: $out}"
    [ -z "$out" ] || fail "Pi late-$kind test printed output: $out"
  done
  pass "Pi late unretired closes resume classified supervision"
}

test_pi_empty_close_retries_instead_of_disappearing() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-empty-close-root"
  home="$TMP_ROOT/pi-empty-close-home"
  log="$TMP_ROOT/pi-empty-close.log"
  stop="$TMP_ROOT/pi-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
let prompts = 0;
let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    prompts += 1;
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-empty", {}, undefined, undefined, {});
// Wait on the observable events - the retry launch and its child appending a
// row. The ceilings fire only when an event never happens, so 20s absorbs CI
// runner contention without weakening any assertion.
for (let i = 0; i < 2000 && armSpawns < 2; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (armSpawns < 2) throw new Error(`clean empty close was ignored: ${rows().join(" | ")}`);
for (let i = 0; i < 2000 && rows().length < 2; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (rows().length < 2) throw new Error(`continuity retry arm child did not start: ${rows().join(" | ")}`);
// Stability window on the launch count: exactly one bounded retry, sampled at
// a defined point instead of at a timeout.
await new Promise((resolve) => setTimeout(resolve, 100));
if (armSpawns !== 2) throw new Error(`clean empty close launched ${armSpawns} arms: ${rows().join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "Pi empty-close retry test printed output: $out"
  pass "Pi clean empty close triggers a bounded continuity retry"
}

test_pi_established_empty_close_honors_retry_limit() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-established-empty-close-root"
  home="$TMP_ROOT/pi-established-empty-close-home"
  log="$TMP_ROOT/pi-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-established-empty", {}, undefined, undefined, {});
// Wait on the observable event - the exhaustion prompt - rather than racing
// the retry cadence on a wall-clock bound; 20s absorbs CI runner contention
// without weakening any assertion.
for (let i = 0; i < 2000 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!prompt) throw new Error("retry exhaustion prompt did not arrive");
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
// Sampled after the exhaustion event: every arm row is written before the
// close that advances the retry sequence, so both counts are settled here.
if (armSpawns !== 3) throw new Error(`retry limit launched ${armSpawns} arm cycles`);
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit ran ${rows.length} arm cycles: ${rows.join(" | ")}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "Pi established-empty-close retry test printed output: $out"
  pass "Pi established clean closes stop at the configured retry limit"
}

test_pi_actionable_close_rechecks_session_lock() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-close-lock-root"
  home="$TMP_ROOT/pi-close-lock-home"
  log="$TMP_ROOT/pi-close-lock.log"
  release="$TMP_ROOT/pi-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append; the test helper spawn below
  // passes no env and stays uncounted.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-lock-close", {}, undefined, undefined, {});
const other = originalSpawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  // Event wait: fails only when the lock-loss prompt never arrives, so a 20s
  // ceiling absorbs CI runner contention without weakening any assertion.
  for (let i = 0; i < 2000 && !prompt.includes("no longer owns the lock"); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
  // Sampled after the lock-loss prompt: only the initial arm may have
  // launched, so any second launch is a successor that ignored lock loss.
  if (armSpawns !== 1) throw new Error(`successor launched after lock loss: ${armSpawns} arm launches`);
} finally {
  other.kill("SIGTERM");
}
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi close handler must verify session-lock ownership before successor launch: $out"
  [ -z "$out" ] || fail "Pi close lock test printed output: $out"
  pass "Pi close handler verifies session-lock ownership before successor launch"
}

test_pi_arm_distinguishes_session_lock_ownership() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-lock-ownership-root"
  home="$TMP_ROOT/pi-lock-ownership-home"
  log="$TMP_ROOT/pi-lock-ownership.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");

const lock = `${process.env.FM_HOME}/state/.lock`;
const callArm = () => tool.execute("tool-call-lock", {}, undefined, undefined, {});
const assertMissingLock = (result, label) => {
  if (result.details?.ok !== false) throw new Error(`${label} unexpectedly armed: ${JSON.stringify(result.details)}`);
  if (!result.details.message.includes("no live session holds the lock")) {
    throw new Error(`${label} missing no-live-session guidance: ${result.details.message}`);
  }
  if (!result.details.message.includes("bin/fm-session-start.sh") || !result.details.message.includes("re-arm")) {
    throw new Error(`${label} missing reclaim and re-arm guidance: ${result.details.message}`);
  }
  if (result.details.message.includes("held by another firstmate session")) {
    throw new Error(`${label} was misreported as a live other holder: ${result.details.message}`);
  }
};

if (existsSync(lock)) unlinkSync(lock);
assertMissingLock(await callArm(), "absent lock");
writeFileSync(lock, "999999\n");
assertMissingLock(await callArm(), "dead lock holder");

const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  const liveOther = await callArm();
  if (liveOther.details?.ok !== false) throw new Error(`live other holder unexpectedly armed: ${JSON.stringify(liveOther.details)}`);
  if (liveOther.details.message !== "watcher: read-only - session lock is held by another firstmate session") {
    throw new Error(`unexpected live-other response: ${liveOther.details.message}`);
  }
} finally {
  other.kill("SIGTERM");
}

if (existsSync(process.env.FM_ARM_LOG)) throw new Error("watcher arm ran without lock ownership");
writeFileSync(lock, `${process.pid}\n`);
const owned = await callArm();
if (owned.details?.ok !== true || !owned.details.message.includes("started Pi extension arm child")) {
  throw new Error(`owned lock did not arm: ${JSON.stringify(owned.details)}`);
}
for (let i = 0; i < 1000 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("owned lock did not run the watcher arm");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher arm must distinguish owned, live-other, and missing or dead session locks"
  [ -z "$out" ] || fail "Pi lock-ownership arm test printed output: $out"
  pass "Pi watcher arm distinguishes all session lock ownership states"
}

test_pi_session_transition_generation_owner() {
  local repo home plugin child_pid_file arm_log out status
  repo="$TMP_ROOT/pi-session-transition-root"
  home="$TMP_ROOT/pi-session-transition-home"
  child_pid_file="$TMP_ROOT/pi-session-transition-child.pid"
  arm_log="$TMP_ROOT/pi-session-transition-arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
printf 'arm pid=%s\n' "$$" >> "${FM_ARM_LOG:?}"
# The pid file is the single commit point the assertions poll on, so it is
# published last and by rename. Appending the arm log after it, or letting a
# truncate-then-write expose an empty file, would let a reader observe this
# child in the pid file while the live-arm log still reads as none.
printf '%s\n' "$$" > "${FM_CHILD_PID_FILE:?}.$$"
mv -f "${FM_CHILD_PID_FILE:?}.$$" "${FM_CHILD_PID_FILE:?}"
trap 'exit 0' TERM INT
while :; do sleep 0.2; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CHILD_PID_FILE="$child_pid_file" FM_ARM_LOG="$arm_log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  let tool = null;
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async () => {},
    events: { on() {} },
  };
  return { pi, handlers, getTool: () => tool };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(pred, label, attempts = 1000) {
  for (let i = 0; i < attempts; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timeout waiting for ${label}`);
}

function liveArmPids() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split(/\n/)
    .filter(Boolean)
    .map((line) => {
      const match = /pid=(\d+)/.exec(line);
      return match ? match[1] : "";
    })
    .filter(Boolean)
    .filter(pidAlive);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);

const startup = makePi();
mod.default(startup.pi);
await startup.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
const first = await startup.getTool().execute("startup", {}, undefined, undefined, {});
if (!first.details?.ok || !String(first.details.message).includes("started Pi extension arm child")) {
  throw new Error(`startup arm failed: ${JSON.stringify(first.details)}`);
}
await waitFor(() => existsSync(process.env.FM_CHILD_PID_FILE), "startup child");
const startupChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
if (!pidAlive(startupChild)) throw new Error("startup child was not alive");
const staleTool = startup.getTool();

async function replaceSession(previous, reason) {
  const previousChild = existsSync(process.env.FM_CHILD_PID_FILE)
    ? readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim()
    : "";
  await previous.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason }, {});
  if (previousChild) {
    await waitFor(() => !pidAlive(previousChild), `${reason} previous child exit`);
  }
  const next = makePi();
  mod.default(next.pi);
  await next.handlers.get("session_start")?.({
    type: "session_start",
    reason,
    previousSessionFile: `/tmp/previous-${reason}.jsonl`,
  }, {});
  const armed = await next.getTool().execute(`arm-${reason}`, {}, undefined, undefined, {});
  if (!armed.details?.ok) {
    throw new Error(`${reason} replacement arm failed: ${JSON.stringify(armed.details)}`);
  }
  if (String(armed.details.message).includes("shutting down")) {
    throw new Error(`${reason} replacement still refused with shutting-down latch`);
  }
  await waitFor(() => {
    if (!existsSync(process.env.FM_CHILD_PID_FILE)) return false;
    const child = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
    return child && child !== previousChild && pidAlive(child);
  }, `${reason} replacement child`);
  const live = liveArmPids();
  if (live.length !== 1) {
    throw new Error(`${reason} expected exactly one live arm child, got ${live.join(",") || "(none)"}`);
  }
  return next;
}

let current = await replaceSession(startup, "new");
current = await replaceSession(current, "resume");
current = await replaceSession(current, "fork");

// Same bound instance: ordinary shutdown then session_start without a fresh factory.
const sameInstanceChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
await current.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
const sameInstanceArm = await current.getTool().execute("same-instance", {}, undefined, undefined, {});
if (!sameInstanceArm.details?.ok || String(sameInstanceArm.details.message).includes("shutting down")) {
  throw new Error(`same-instance replacement arm failed: ${JSON.stringify(sameInstanceArm.details)}`);
}
await waitFor(() => {
  if (!existsSync(process.env.FM_CHILD_PID_FILE)) return false;
  const child = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
  return child !== sameInstanceChild && pidAlive(child);
}, "same-instance replacement child");
await waitFor(() => !pidAlive(sameInstanceChild), "same-instance previous child exit");
if (liveArmPids().length !== 1) {
  throw new Error(`same-instance expected one live arm child, got ${liveArmPids().join(",")}`);
}

// Stale prior-generation callback must not stop, rearm, or clear the active generation.
const activeChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
const stale = await staleTool.execute("stale-prior-generation", {}, undefined, undefined, {});
if (stale.details?.ok !== false || !String(stale.details.message).includes("shutting down")) {
  throw new Error(`stale prior generation did not refuse: ${JSON.stringify(stale.details)}`);
}
if (!pidAlive(activeChild)) throw new Error("active generation child died after stale callback");
if (pidAlive(startupChild)) throw new Error("startup generation child was resurrected");
if (liveArmPids().length !== 1 || liveArmPids()[0] !== activeChild) {
  throw new Error(`stale callback mutated live arm set: ${liveArmPids().join(",")}`);
}
const redundant = await current.getTool().execute("redundant", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`active generation lost single-flight ownership: ${JSON.stringify(redundant.details)}`);
}

// Repeated transitions keep exactly one live cycle and never revive the refusal.
for (const reason of ["resume", "fork", "new", "resume"]) {
  current = await replaceSession(current, reason);
}

// Real terminal shutdown still blocks late rearming.
const finalChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
await waitFor(() => !pidAlive(finalChild), "terminal shutdown child exit");
const quitArm = await current.getTool().execute("after-quit", {}, undefined, undefined, {});
if (quitArm.details?.ok !== false || quitArm.details.message !== "watcher: not armed - Pi session is shutting down") {
  throw new Error(`terminal quit must keep the shutting-down refusal: ${JSON.stringify(quitArm.details)}`);
}
if (liveArmPids().length !== 0) {
  throw new Error(`terminal quit left live arm children: ${liveArmPids().join(",")}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi session transitions must rearm through an explicit generation owner"
  [ -z "$out" ] || fail "Pi session-transition generation owner test printed output: $out"
  pass "Pi session transitions use a generation owner across /new /resume /fork, stale callbacks, and quit"
}

test_pi_process_exit_cleanup_listener_lifecycle() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-exit-listener-root"
  home="$TMP_ROOT/pi-exit-listener-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async () => {},
};
const before = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("Pi extension did not install exactly one process-exit fallback");
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("session_shutdown removed the process-lifetime exit fallback");
}
await handlers.get("session_start")?.({ type: "session_start" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("replacement activation duplicated the process-exit fallback");
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi cleanup fallback listener must remain singular across session replacement"
  [ -z "$out" ] || fail "Pi listener-lifecycle test printed output: $out"
  pass "Pi process-exit cleanup listener remains singular across session replacement"
}

test_pi_process_exit_cleanup_stops_arm_child() {
  local repo home plugin cleanup_log pid_file out status pid i
  repo="$TMP_ROOT/pi-process-exit-root"
  home="$TMP_ROOT/pi-process-exit-home"
  cleanup_log="$TMP_ROOT/pi-process-exit-cleaned"
  pid_file="$TMP_ROOT/pi-process-exit-child.pid"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "%s\n" "$$" >> "$FM_CLEANUP_LOG"; exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-exit", {}, undefined, undefined, {});
for (let i = 0; i < 1000 && !existsSync(process.env.FM_CHILD_PID_FILE); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_CHILD_PID_FILE)) throw new Error("arm child did not start");
const firstChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
await handlers.get("session_start")?.({ type: "session_start" }, {});
await tool.execute("tool-call-replacement", {}, undefined, undefined, {});
for (let i = 0; i < 1000; i += 1) {
  const currentChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
  if (currentChild !== firstChild) break;
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim() === firstChild) {
  throw new Error("replacement arm child did not start");
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi process exit must run the watcher cleanup fallback"
  [ -z "$out" ] || fail "Pi process-exit cleanup test printed output: $out"
  pid=$(cat "$pid_file")
  i=0
  while [ "$i" -lt 1000 ] && ! grep -qx "$pid" "$cleanup_log" 2>/dev/null; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -qx "$pid" "$cleanup_log" 2>/dev/null || fail "Pi process-exit fallback did not deliver TERM to the replacement arm child"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_opencode_plugin_package_boundary_is_explicit_esm() {
  local fixture plugin out status
  fixture="$TMP_ROOT/opencode-esm-boundary/.opencode"
  plugin="$fixture/plugins/fm-primary-watch-arm.js"
  mkdir -p "$fixture/plugins/lib"
  printf '%s\n' '{"dependencies":{}}' > "$fixture/package.json"
  cp "$ROOT/.opencode/plugins/package.json" "$fixture/plugins/package.json"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$fixture/plugins/lib/fm-operational-input.js"
  out=$(PLUGIN="$plugin" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
await import(pathToFileURL(process.env.PLUGIN).href);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must import beneath an explicit ESM package boundary"
  [ -z "$out" ] || fail "OpenCode ESM boundary import printed output: $out"
  pass "OpenCode plugins have an explicit ESM boundary even under a typeless parent package"
}

test_opencode_primary_watch_plugin_uses_effective_state_home() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-state-root"
  home="$TMP_ROOT/opencode-effective-state-home"
  log="$TMP_ROOT/opencode-effective-state.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s root=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 1000 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
const expectedRoot = realpathSync(process.env.WORKTREE);
if (!text.includes(`home=${process.env.FM_HOME}`) || !text.includes(`root=${expectedRoot}`)) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must use FM_HOME state outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-state test printed output: $out"
  pass "OpenCode watcher plugin uses the effective FM_HOME state"
}

test_opencode_primary_watch_plugin_sources_effective_config() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-config-root"
  home="$TMP_ROOT/opencode-effective-config-home"
  log="$TMP_ROOT/opencode-effective-config.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  printf 'export FM_POLL=7\n' > "$home/config/x-mode.env"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'poll=%s\n' "${FM_POLL:-missing}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 1000 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
if (!text.includes("poll=7")) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must source FM_HOME config outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-config test printed output: $out"
  pass "OpenCode watcher plugin sources the effective config"
}

test_opencode_primary_watch_plugin_requires_session_lock() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-lock-root"
  home="$TMP_ROOT/opencode-lock-home"
  log="$TMP_ROOT/opencode-lock.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm). The launch count proves the withheld arm was never even spawned,
  // where the fixture log could stay absent merely because a spawned child
  // had not been scheduled yet.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "999999\n");
await hooks.event(event);
// The hook starts its attempt without awaiting it, and the plugin answers a
// second attempt from the one already in flight. Join that attempt through the
// coordinator rather than waiting a fixed span: refusing an unowned lock walks
// git and ps probes that can outlast any such span, and the owned-lock event
// below would then be answered from the refusal instead of arming.
const refusal = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (refusal !== "read-only") {
  console.error(`expected a read-only refusal without the session lock, got ${refusal}`);
  process.exit(1);
}
if (armSpawns !== 0 || existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm ran without owning the session lock");
  process.exit(1);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
// The plugin coalesces idle events that arrive while a launch attempt is
// still in flight, and the dead-lock attempt above walks subprocesses that
// can outlast any fixed pause on a contended runner. OpenCode re-emits
// session.idle whenever the session settles, so model that by re-firing the
// event while waiting; the wait fails only when the arm never runs, so a 20s
// ceiling absorbs contention without weakening the withheld-arm assertion.
for (let i = 0; i < 1000 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await hooks.event(event);
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run after the session lock matched");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must arm only when this session owns the fleet lock"
  [ -z "$out" ] || fail "OpenCode session-lock test printed output: $out"
  pass "OpenCode watcher plugin requires session lock ownership"
}

test_opencode_watch_arm_coordinator_respects_primary_scope() {
  local plugin base repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  base="$TMP_ROOT/opencode-coordinator-base"
  repo="$TMP_ROOT/opencode-coordinator-wt"
  home="$TMP_ROOT/opencode-coordinator-home"
  log="$TMP_ROOT/opencode-coordinator.log"
  fm_git_worktree "$base" "$repo" fm/opencode-coordinator
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
await new Promise((resolve) => setTimeout(resolve, 120));
if (status !== "not-primary") {
  console.error(`expected not-primary, got ${status}`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("coordinator armed from a linked worktree");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch coordinator must keep primary scope checks in the shared arm path"
  [ -z "$out" ] || fail "OpenCode coordinator-scope test printed output: $out"
  pass "OpenCode watcher coordinator respects primary scope"
}

test_opencode_primary_watch_plugin_rearms_after_wake() {
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-rearm-root"
  home="$TMP_ROOT/opencode-rearm-home"
  log="$TMP_ROOT/opencode-rearm.log"
  stop="$TMP_ROOT/opencode-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let prompts = 0;
let armSpawns = 0;
let successorSpawns = 0;
let successorSpawnsAtPrompt = 0;
let successorStartedAtPrompt = false;
const successorPredecessors = [];
let releasePrompt = () => {};
const promptBlocked = new Promise((resolve) => {
  releasePrompt = resolve;
});
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm); the spawn call is the successor launch, so counting it does not
  // race the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) {
    armSpawns += 1;
    if (args[2].env.FM_WATCH_PREDECESSOR_ARM_PID) {
      successorSpawns += 1;
      successorPredecessors.push(args[2].env.FM_WATCH_PREDECESSOR_ARM_PID);
    }
  }
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: async () => {
      successorSpawnsAtPrompt = successorSpawns;
      successorStartedAtPrompt = rows().some((row) => /predecessor=[0-9]+/.test(row));
      prompts += 1;
      await promptBlocked;
    },
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
// Wait on the observable events - the wake prompt beginning and the successor
// child appending its row. The ceilings fire only when an event never
// happens, so 20s absorbs CI runner contention without weakening assertions.
for (let i = 0; i < 2000 && prompts < 1; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (prompts !== 1) throw new Error(`expected one blocked wake prompt, got ${prompts}`);
if (successorSpawnsAtPrompt !== 1) throw new Error(`wake prompt began with ${successorSpawnsAtPrompt} successor launches`);
if (!successorStartedAtPrompt) throw new Error("wake prompt began before the successor arm child started");
if (!/^[0-9]+$/.test(successorPredecessors[0] ?? "")) throw new Error(`successor launch missing predecessor identity: ${successorPredecessors.join(" | ")}`);
for (let i = 0; i < 2000 && rows().length < 2; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (rows().length < 2) throw new Error(`successor arm child did not start: ${rows().join(" | ")}`);
if (!/predecessor=[0-9]+/.test(rows()[1])) throw new Error(`successor did not receive predecessor identity: ${rows()[1]}`);
// Stability window: single-flight holds, so no further arm launches happen
// once the successor is up and the wake prompt has begun.
await new Promise((resolve) => setTimeout(resolve, 100));
if (armSpawns !== 2 || successorSpawns !== 1) throw new Error(`single-flight violation launched ${armSpawns} arms (${successorSpawns} successors): ${rows().join(" | ")}`);
if (prompts !== 1) throw new Error(`expected one blocked wake prompt, got ${prompts}`);
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.filter((row) => row.startsWith("arm=")).length !== 2) {
  throw new Error(`blocked follow-up started extra arm work: ${stableRows.join(" | ")}`);
}
if (stableRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${stableRows.join(" | ")}`);
}
releasePrompt();
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "OpenCode watch plugin must start one successor before wake prompt delivery settles: $out"
  [ -z "$out" ] || fail "OpenCode rearm test printed output: $out"
  pass "OpenCode watcher plugin starts one successor before wake prompt delivery settles"
}

test_opencode_pre_ready_actionable_close_preserves_its_successor() {
  local plugin repo home log release retired stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-pre-ready-actionable-root"
  home="$TMP_ROOT/opencode-pre-ready-actionable-home"
  log="$TMP_ROOT/opencode-pre-ready-actionable.log"
  release="$TMP_ROOT/opencode-pre-ready-actionable.release"
  retired="$TMP_ROOT/opencode-pre-ready-actionable.retired"
  stop="$TMP_ROOT/opencode-pre-ready-actionable.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  printf 'signal: pre-ready successor wake\n'
  trap 'printf "retired\\n" > "${FM_PRE_READY_RETIRED_FILE:?}"; exit 0' TERM INT
  while [ ! -e "$FM_PRE_READY_RELEASE_FILE" ]; do sleep 0.02; done
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_PRE_READY_RELEASE_FILE="$release" FM_PRE_READY_RETIRED_FILE="$retired" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  // Event waits fail only when the event never happens; a 20s ceiling absorbs
  // CI runner contention without weakening any assertion.
  for (let i = 0; i < 2000; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
await waitFor(
  () => prompts.some((message) => message.includes("original wake")),
  "original actionable wake was not delivered",
);
await waitFor(() => rows().length >= 2, "pre-ready successor arm child did not start");
// Sampled after both events: a replacement of the pre-ready successor would
// show up as a third arm launch before its close.
if (armSpawns !== 2) throw new Error(`pre-ready successor was replaced before its close: ${armSpawns} arm launches: ${rows().join(" | ")}`);
await new Promise((resolve) => setTimeout(resolve, 150));
if (existsSync(process.env.FM_PRE_READY_RETIRED_FILE)) throw new Error("pre-ready actionable successor was retired before its close");
writeFileSync(process.env.FM_PRE_READY_RELEASE_FILE, "release\n");
await waitFor(
  () => armSpawns >= 3 && prompts.some((message) => message.includes("pre-ready successor wake")),
  "pre-ready actionable wake was not delivered with a successor",
);
await waitFor(() => rows().length >= 3, "restored arm child did not start");
// Sample the exact count only after the restore event, holding a short
// stability window so a duplicate restore cannot hide behind the sample.
await new Promise((resolve) => setTimeout(resolve, 100));
if (armSpawns !== 3) throw new Error(`pre-ready close created ${armSpawns - 2} successors: ${rows().join(" | ")}`);
if (!prompts.some((message) => message.includes("pre-ready successor wake"))) throw new Error(`pre-ready actionable wake was not delivered: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must retire the pre-ready arm, not its actionable successor"
  [ -z "$out" ] || fail "OpenCode pre-ready actionable test printed output: $out"
  pass "OpenCode pre-ready actionable close preserves its successor"
}

test_opencode_hung_successor_falls_back_to_typed_wake() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-hung-successor-root"
  home="$TMP_ROOT/opencode-hung-successor-home"
  log="$TMP_ROOT/opencode-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let prompt = "";
let successorAttempts = 0;
let successorAttemptsAtPrompt = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  if (args[2]?.env?.FM_WATCH_PREDECESSOR_ARM_PID) successorAttempts += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: async (request) => {
      successorAttemptsAtPrompt = successorAttempts;
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 2000 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!prompt) throw new Error("hung-successor prompt did not arrive within ceiling");
// The spawn call is the restoration attempt. Waiting for the child shell to
// append its fixture row races process scheduling against the ready timeout.
if (successorAttemptsAtPrompt < 1) throw new Error("wake arrived before restoration was attempted");
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, 200));
if (successorAttempts !== successorAttemptsAtPrompt) throw new Error(`single-flight recovery launched additional ${successorAttempts - successorAttemptsAtPrompt} arms after delivery`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must deliver the actionable wake after bounded hung-successor recovery"
  [ -z "$out" ] || fail "OpenCode hung-successor test printed output: $out"
  pass "OpenCode hung successor falls back to one typed actionable wake"
}

test_opencode_unretired_successor_falls_back_without_retry() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-unretired-successor-root"
  home="$TMP_ROOT/opencode-unretired-successor-home"
  log="$TMP_ROOT/opencode-unretired-successor.log"
  release="$TMP_ROOT/opencode-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_OPENCODE_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let prompt = "";
let successorAttempts = 0;
let successorAttemptsAtPrompt = 0;
let retireRequests = 0;
let retireRequestsAtPrompt = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  const child = originalSpawn(...args);
  if (args[2]?.env?.FM_WATCH_PREDECESSOR_ARM_PID) {
    successorAttempts += 1;
    const originalKill = child.kill.bind(child);
    child.kill = (signal, ...killArgs) => {
      if (signal === "SIGTERM") {
        retireRequests += 1;
        return true;
      }
      return originalKill(signal, ...killArgs);
    };
  }
  return child;
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      successorAttemptsAtPrompt = successorAttempts;
      retireRequestsAtPrompt = retireRequests;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 2000 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!prompt) throw new Error("unretired-successor prompt did not arrive within ceiling");
// Spawn and kill are the lifecycle events under test. Waiting for the child
// shell to append a fixture row races process scheduling against the timeout.
if (successorAttemptsAtPrompt !== 1) throw new Error(`fallback observed ${successorAttemptsAtPrompt} successor attempts`);
if (retireRequestsAtPrompt !== 1) throw new Error(`fallback observed ${retireRequestsAtPrompt} retirement requests`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm was still running when the 20ms retirement deadline settled or did not close within the additional 20ms grace after exit")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must fall back without overlapping an unretired successor${out:+: $out}"
  [ -z "$out" ] || fail "OpenCode unretired-successor test printed output: $out"
  pass "OpenCode unretired successor falls back without an overlapping retry"
}

test_opencode_late_unretired_close_resumes_supervision() {
  local kind plugin repo home log initial_ready initial_release ready release stop out status
  for kind in actionable non-actionable; do
    plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
    repo="$TMP_ROOT/opencode-late-$kind-root"
    home="$TMP_ROOT/opencode-late-$kind-home"
    log="$TMP_ROOT/opencode-late-$kind.log"
    initial_ready="$TMP_ROOT/opencode-late-$kind-initial.ready"
    initial_release="$TMP_ROOT/opencode-late-$kind-initial.release"
    ready="$TMP_ROOT/opencode-late-$kind.ready"
    release="$TMP_ROOT/opencode-late-$kind.release"
    stop="$TMP_ROOT/opencode-late-$kind.stop"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    git init -q "$repo"
    : > "$repo/AGENTS.md"
    : > "$home/state/task.meta"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'ready\n' > "${FM_INITIAL_READY_FILE:?}"
  while [ ! -e "$FM_INITIAL_RELEASE_FILE" ]; do sleep 0.02; done
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  trap '' TERM INT
  # Announce unreadiness instead of waiting out the readiness deadline. This
  # case also needs the restored arm below to be observed ready, so a
  # compressed readiness budget would have to cover a real bash login-shell
  # start: that measures runner speed, not behavior. Exactly that happened on
  # CI - a slow start made the plugin declare a spurious readiness timeout on
  # the continuity retry and surface a second wake. An observed unready line
  # keeps the same restoration path without any wall-clock verdict.
  printf 'watcher: FAILED - successor arm cannot confirm a watcher\n'
  printf 'ready\n' > "${FM_UNRETIRED_READY_FILE:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    # No compressed FM_OPENCODE_ARM_READY_TIMEOUT_MS: every arm here settles
    # readiness from its own output, so the shipped budget is never waited out
    # and can never be the oracle. The retirement budget stays compressed
    # because that verdict is deterministic - the successor is held alive by
    # the release event until well after the deadline settles.
    out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_INITIAL_READY_FILE="$initial_ready" FM_INITIAL_RELEASE_FILE="$initial_release" FM_UNRETIRED_READY_FILE="$ready" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

const prompts = [];
let armSpawns = 0;
let retireRequests = 0;
let retireRequestsAtPrompt = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  const child = originalSpawn(...args);
  if (args[2]?.env?.FM_WATCH_PREDECESSOR_ARM_PID) {
    const originalKill = child.kill.bind(child);
    child.kill = (signal, ...killArgs) => {
      // Hold the successor open deterministically until the release event.
      // The retirement request itself is the lifecycle event under test; a
      // shell trap is not a reliable process-boundary oracle under load.
      if (signal === "SIGTERM") {
        retireRequests += 1;
        return true;
      }
      return originalKill(signal, ...killArgs);
    };
  }
  return child;
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: async (request) => {
      retireRequestsAtPrompt = retireRequests;
      prompts.push(request.body.parts[0].text);
    },
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
async function waitFor(predicate, message) {
  // Event waits fail only when the event never happens; a 20s ceiling absorbs
  // CI runner contention without weakening any assertion.
  for (let i = 0; i < 2000; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(message);
}
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
await waitFor(
  () => existsSync(process.env.FM_INITIAL_READY_FILE),
  "initial arm child did not reach its ready boundary",
);
// Join the event's launch attempt before allowing its actionable close. This
// proves the initial child is ready and clears OpenCode's deliberate in-flight
// coalescing boundary before the late-close lifecycle begins.
const initialStatus = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (initialStatus !== "armed") throw new Error(`initial arm did not become ready: ${initialStatus}`);
writeFileSync(process.env.FM_INITIAL_RELEASE_FILE, "release\n");
await waitFor(
  () => existsSync(process.env.FM_UNRETIRED_READY_FILE),
  "unretired successor did not enter its retirement wait",
);
await waitFor(() => prompts.length >= 1, "original fallback was not delivered");
// The intercepted kill call is the retirement request; withholding it keeps
// the successor unretired deterministically until the release event.
if (retireRequestsAtPrompt < 1) throw new Error("unretired successor was not asked to retire before fallback");
if (armSpawns !== 2) throw new Error(`unretired arm overlapped before fallback: ${armSpawns} arm launches: ${rows().join(" | ")}`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
// The restored supervisor is the third arm launch; an actionable late close
// must also deliver its wake. Both are observable events, so the ceiling
// never decides the verdict.
await waitFor(
  () => armSpawns >= 3 && (process.env.FM_LATE_KIND !== "actionable" || prompts.some((message) => message.includes("late wake"))),
  "late close did not restore one successor",
);
await waitFor(() => rows().length >= 3, "restored arm child did not start");
// Sample the exact count only after the restore event, holding a short
// stability window so a duplicate restore cannot hide behind the sample.
await new Promise((resolve) => setTimeout(resolve, 100));
if (armSpawns !== 3) throw new Error(`late close restored ${armSpawns - 2} successors: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
    status=$?
    expect_code 0 "$status" "OpenCode late $kind close must remain supervised after fallback${out:+: $out}"
    [ -z "$out" ] || fail "OpenCode late-$kind test printed output: $out"
  done
  pass "OpenCode late unretired closes resume classified supervision"
}

# Deterministic regression for the readiness deadline race: readiness output
# already queued in the poll phase when the deadline timer fires must settle
# the verdict, not be discarded for a spurious timeout. The arm child holds
# its readiness line until the go file exists; the harness releases it from a
# check-phase callback and spins until the output is provably written and the
# deadline has passed, so the next iteration's timers phase always races the
# queued output - the interleaving a contended CI runner produces by
# starvation.
test_opencode_queued_readiness_at_deadline_reports_armed() {
  local plugin repo home go marker stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-ready-settle-root"
  home="$TMP_ROOT/opencode-ready-settle-home"
  go="$TMP_ROOT/opencode-ready-settle.go"
  marker="$TMP_ROOT/opencode-ready-settle.marker"
  stop="$TMP_ROOT/opencode-ready-settle.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while [ ! -e "${FM_GO_FILE:?}" ]; do sleep 0.01; done
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'ready\n' > "${FM_READY_MARKER:?}"
while [ ! -e "${FM_STOP_FILE:?}" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_GO_FILE="$go" FM_READY_MARKER="$marker" FM_STOP_FILE="$stop" FM_OPENCODE_ARM_READY_TIMEOUT_MS=200 node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let armSpawns = 0;
const prompts = [];
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async (request) => { prompts.push(request.body.parts[0].text); } } };
await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const statusPromise = globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
for (let i = 0; i < 2000 && armSpawns < 1; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (armSpawns < 1) throw new Error("arm child never spawned");
// The readiness timer is armed in the same macrotask as the spawn. From a
// check-phase callback, release the child, spin until its readiness line is
// provably written (the marker file follows it), then spin past the
// deadline. The next loop iteration runs its timers phase before its poll
// phase, so the deadline always fires while readiness output is queued.
await new Promise((resolve) => setImmediate(() => {
  writeFileSync(process.env.FM_GO_FILE, "go\n");
  const markerDeadline = Date.now() + 5000;
  while (!existsSync(process.env.FM_READY_MARKER)) {
    if (Date.now() >= markerDeadline) {
      throw new Error(`fixture timed out waiting for readiness marker: ${process.env.FM_READY_MARKER}`);
    }
  }
  const settle = Date.now() + 350;
  while (Date.now() < settle) { /* spin */ }
  resolve();
}));
const status = await statusPromise;
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
if (status !== "armed") throw new Error(`queued readiness was discarded at the deadline: ${status}`);
if (prompts.length !== 0) throw new Error(`readiness deadline surfaced a spurious failure: ${prompts.join(" | ")}`);
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must honor readiness output queued when the deadline fires${out:+: $out}"
  [ -z "$out" ] || fail "OpenCode readiness-settle test printed output: $out"
  pass "OpenCode readiness queued at the deadline reports armed"
}

# Deterministic regression for the retirement deadline race, mirroring the Pi
# case: a successor that exits while the loop is stalled across the retire
# deadline must be reported retired so restoration continues, instead of the
# false unretired verdict that tears down continuity.
test_opencode_retired_successor_close_at_deadline_keeps_continuity() {
  local plugin repo home log retire_ready recovery_ready term_seen retire_release exit_marker stdio_release stdio_exit stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-retire-settle-root"
  home="$TMP_ROOT/opencode-retire-settle-home"
  log="$TMP_ROOT/opencode-retire-settle.log"
  retire_ready="$TMP_ROOT/opencode-retire-settle.ready"
  recovery_ready="$TMP_ROOT/opencode-retire-settle.recovery-ready"
  term_seen="$TMP_ROOT/opencode-retire-settle.term-seen"
  retire_release="$TMP_ROOT/opencode-retire-settle.retire-release"
  exit_marker="$TMP_ROOT/opencode-retire-settle.exit-marker"
  stdio_release="$TMP_ROOT/opencode-retire-settle.stdio-release"
  stdio_exit="$TMP_ROOT/opencode-retire-settle.stdio-exit"
  stop="$TMP_ROOT/opencode-retire-settle.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  on_term() {
    printf 'seen\n' > "${FM_TERM_SEEN_FILE:?}"
    while [ ! -e "${FM_RETIRE_RELEASE_FILE:?}" ]; do sleep 0.02; done
    (
      while [ ! -e "${FM_STDIO_RELEASE_FILE:?}" ]; do sleep 0.02; done
      printf 'gone\n' > "${FM_STDIO_EXIT_FILE:?}"
    ) &
    printf 'gone\n' > "${FM_EXIT_MARKER_FILE:?}"
    exit 0
  }
  trap on_term TERM
  printf 'ready\n' > "${FM_RETIRE_READY_FILE:?}"
  while :; do sleep 0.02; done
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'ready\n' > "${FM_RECOVERY_READY_FILE:?}"
trap 'exit 0' TERM INT
while [ ! -e "${FM_STOP_FILE:?}" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RETIRE_READY_FILE="$retire_ready" FM_RECOVERY_READY_FILE="$recovery_ready" FM_TERM_SEEN_FILE="$term_seen" FM_RETIRE_RELEASE_FILE="$retire_release" FM_EXIT_MARKER_FILE="$exit_marker" FM_STDIO_RELEASE_FILE="$stdio_release" FM_STDIO_EXIT_FILE="$stdio_exit" FM_STOP_FILE="$stop" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=200 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let armSpawns = 0;
let successorSpawns = 0;
let retireStalled = false;
const prompts = [];
// Barriers that establish the test setup, so runner scheduling never decides
// it: the arm child has provably reached the marked point before the plugin
// gets to arm any deadline against it. The event-loop stalls below still
// decide the retirement verdict.
const awaitFixture = (path, what) => {
  const deadline = Date.now() + 5000;
  while (!existsSync(path)) {
    if (Date.now() >= deadline) throw new Error(`fixture timed out ${what}: ${path}`);
  }
};
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  const successor = Boolean(args[2]?.env?.FM_WATCH_PREDECESSOR_ARM_PID);
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  const child = originalSpawn(...args);
  if (successor) {
    successorSpawns += 1;
    if (successorSpawns === 1) {
      // SIGTERM must not arrive before the retiring successor installs its handler.
      awaitFixture(process.env.FM_RETIRE_READY_FILE, "installing retirement handler");
    } else {
      // The readiness deadline is armed once this spawn returns, so the recovery
      // arm's readiness line must already be written. Otherwise a starved runner
      // that cannot start bash within the readiness deadline spends an extra
      // retry here and the retirement verdict under test is no longer what the
      // arm-launch count measures.
      awaitFixture(process.env.FM_RECOVERY_READY_FILE, "producing recovery readiness");
    }
    const originalKill = child.kill.bind(child);
    child.kill = (signal, ...killArgs) => {
      const delivered = originalKill(signal, ...killArgs);
      if (signal === "SIGTERM" && !retireStalled) {
        retireStalled = true;
        // The retire timer is armed synchronously after this kill call
        // returns. From the check phase, release the held successor and spin
        // past the retire deadline while its inherited stdio remains open.
        // After the first settle arms the grace timer, release that pipe and
        // spin past grace so the queued close races its deadline too.
        setImmediate(() => {
          writeFileSync(process.env.FM_RETIRE_RELEASE_FILE, "release\n");
          const exitDeadline = Date.now() + 5000;
          while (!existsSync(process.env.FM_EXIT_MARKER_FILE)) {
            if (Date.now() >= exitDeadline) {
              throw new Error(`fixture timed out waiting for exit marker: ${process.env.FM_EXIT_MARKER_FILE}`);
            }
          }
          const settle = Date.now() + 350;
          while (Date.now() < settle) { /* spin */ }
          setImmediate(() => setImmediate(() => {
            writeFileSync(process.env.FM_STDIO_RELEASE_FILE, "release\n");
            const stdioDeadline = Date.now() + 5000;
            while (!existsSync(process.env.FM_STDIO_EXIT_FILE)) {
              if (Date.now() >= stdioDeadline) {
                throw new Error(`fixture timed out waiting for stdio-exit marker: ${process.env.FM_STDIO_EXIT_FILE}`);
              }
            }
            const graceSettle = Date.now() + 350;
            while (Date.now() < graceSettle) { /* spin */ }
          }));
        });
      }
      return delivered;
    };
  }
  return child;
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async (request) => { prompts.push(request.body.parts[0].text); } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 2000 && prompts.length < 1; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
try {
  if (prompts.length < 1) throw new Error("restored wake was not delivered");
  if (!existsSync(process.env.FM_TERM_SEEN_FILE)) throw new Error("successor was never asked to retire");
  if (!prompts[0].includes("original wake")) throw new Error(`missing original wake: ${prompts.join(" | ")}`);
  // Match the failure by what it means, not by one release's phrasing: any
  // wording of a lost-continuity verdict must fail this regression.
  if (prompts[0].includes("could not restore watcher continuity")) throw new Error(`retired successor lost continuity: ${prompts[0]}`);
  if (armSpawns !== 3) throw new Error(`restoration did not continue after retirement: ${armSpawns} arm launches`);
} finally {
  writeFileSync(process.env.FM_STOP_FILE, "stop\n");
  await new Promise((resolve) => setTimeout(resolve, 80));
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must honor a successor that exited by the retire deadline${out:+: $out}"
  [ -z "$out" ] || fail "OpenCode retire-settle test printed output: $out"
  pass "OpenCode retirement honors a queued close at the deadline and keeps continuity"
}

test_opencode_empty_close_retries_instead_of_disappearing() {
  local plugin repo home log stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-empty-close-root"
  home="$TMP_ROOT/opencode-empty-close-home"
  log="$TMP_ROOT/opencode-empty-close.log"
  stop="$TMP_ROOT/opencode-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let prompts = 0;
let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// Wait on the observable events - the retry launch and its child appending a
// row. The ceilings fire only when an event never happens, so 20s absorbs CI
// runner contention without weakening any assertion.
for (let i = 0; i < 2000 && armSpawns < 2; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (armSpawns < 2) throw new Error(`clean empty close was ignored: ${rows().join(" | ")}`);
for (let i = 0; i < 2000 && rows().length < 2; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (rows().length < 2) throw new Error(`continuity retry arm child did not start: ${rows().join(" | ")}`);
// Stability window on the launch count: exactly one bounded retry, sampled at
// a defined point instead of at a timeout.
await new Promise((resolve) => setTimeout(resolve, 100));
if (armSpawns !== 2) throw new Error(`clean empty close launched ${armSpawns} arms: ${rows().join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "OpenCode empty-close retry test printed output: $out"
  pass "OpenCode clean empty close triggers a bounded continuity retry"
}

test_opencode_established_empty_close_honors_retry_limit() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-established-empty-close-root"
  home="$TMP_ROOT/opencode-established-empty-close-home"
  log="$TMP_ROOT/opencode-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let prompt = "";
let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append on a contended runner.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// Wait on the observable event - the exhaustion prompt - rather than racing
// the retry cadence on a wall-clock bound; 20s absorbs CI runner contention
// without weakening any assertion.
for (let i = 0; i < 2000 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!prompt) throw new Error("retry exhaustion prompt did not arrive");
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
// Sampled after the exhaustion event: every arm row is written before the
// close that advances the retry sequence, so both counts are settled here.
if (armSpawns !== 3) throw new Error(`retry limit launched ${armSpawns} arm cycles`);
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit ran ${rows.length} arm cycles: ${rows.join(" | ")}`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "OpenCode established-empty-close retry test printed output: $out"
  pass "OpenCode established clean closes stop at the configured retry limit"
}

test_opencode_actionable_close_rechecks_session_lock() {
  local plugin repo home log release out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-close-lock-root"
  home="$TMP_ROOT/opencode-close-lock-home"
  log="$TMP_ROOT/opencode-close-lock.log"
  release="$TMP_ROOT/opencode-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let prompt = "";
let armSpawns = 0;
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
childProcess.spawn = (...args) => {
  // Every plugin arm spawn carries the predecessor key (empty for a fresh
  // arm), so counting the spawn calls observes arm launches without racing
  // the child-shell fixture-row append; the test helper spawn below
  // passes no env and stays uncounted.
  if (args[2]?.env && "FM_WATCH_PREDECESSOR_ARM_PID" in args[2].env) armSpawns += 1;
  return originalSpawn(...args);
};
syncBuiltinESMExports();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const eventPromise = hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// Event wait: fails only when the arm child never starts, so a 20s ceiling
// absorbs CI runner contention without weakening any assertion.
for (let i = 0; i < 2000 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("initial arm child did not start");
const other = originalSpawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  await eventPromise;
  for (let i = 0; i < 2000 && !prompt.includes("no longer owns the lock"); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
  // Sampled after the lock-loss prompt: only the initial arm may have
  // launched, so any second launch is a successor that ignored lock loss.
  if (armSpawns !== 1) throw new Error(`successor launched after lock loss: ${armSpawns} arm launches`);
} finally {
  other.kill("SIGTERM");
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode close handler must verify session-lock ownership before successor launch"
  [ -z "$out" ] || fail "OpenCode close lock test printed output: $out"
  pass "OpenCode close handler verifies session-lock ownership before successor launch"
}

test_opencode_watch_arm_coordinates_with_turnend_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-coordinate-root"
  home="$TMP_ROOT/opencode-coordinate-home"
  log="$TMP_ROOT/opencode-coordinate-arm.log"
  guard_log="$TMP_ROOT/opencode-coordinate-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard should not run\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 1000 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard ran before the watch arm could establish supervision");
  process.exit(1);
}
if (promptBody) {
  console.error(`unexpected prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode turn-end guard must let the auto-arm plugin establish supervision first"
  [ -z "$out" ] || fail "OpenCode coordination test printed output: $out"
  pass "OpenCode watcher plugin coordinates with the turn-end guard"
}

test_opencode_healthy_arm_output_does_not_suppress_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-external-healthy-root"
  home="$TMP_ROOT/opencode-external-healthy-home"
  log="$TMP_ROOT/opencode-external-healthy-arm.log"
  guard_log="$TMP_ROOT/opencode-external-healthy-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard ran after external healthy watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 1000 && !existsSync(process.env.FM_GUARD_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (!readFileSync(process.env.FM_ARM_LOG, "utf8").includes("args=--restart")) {
  console.error("watch arm was not asked to restart into an owned child");
  process.exit(1);
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard was suppressed by an external healthy watcher");
  process.exit(1);
}
if (!promptBody.includes("TURN WOULD END BLIND")) {
  console.error(`missing blind-turn prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must not treat external healthy output as an owned arm"
  [ -z "$out" ] || fail "OpenCode external-healthy test printed output: $out"
  pass "OpenCode healthy arm output does not suppress the turn-end guard"
}

test_pi_away_mode_leaves_one_supervision_cycle() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/pi-away-mode-root"
  home="$TMP_ROOT/pi-away-mode-home"
  log="$TMP_ROOT/pi-away-mode.log"
  stop="$TMP_ROOT/pi-away-mode.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'start %s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'printf "stop %s\n" "$$" >> "$FM_ARM_LOG"; exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" \
    FM_PI_AWAY_POLL_MS=50 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const home = process.env.FM_HOME;
const armLog = process.env.FM_ARM_LOG;
const awayFlag = `${home}/state/.afk`;
const wakes = [];
let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    wakes.push(message);
  },
};
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);

const armRecords = () =>
  existsSync(armLog) ? readFileSync(armLog, "utf8").split("\n").filter(Boolean) : [];
const armCount = (verb) => armRecords().filter((record) => record.startsWith(verb)).length;
const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 1000; i += 1) {
    if (predicate()) return;
    await settle(20);
  }
  throw new Error(`${label}; arm records: ${armRecords().join(" | ")}`);
};

const first = await tool.execute("call-first", {}, undefined, undefined, {});
if (!first.content[0]?.text.includes("started Pi extension arm child")) {
  throw new Error(`the first cycle was not armed: ${first.content[0]?.text}`);
}
await waitFor(() => armCount("start") === 1, "the first extension-owned cycle never started");

// Away mode arrives: the sub-supervisor daemon becomes the only supervision owner.
writeFileSync(awayFlag, `${Math.floor(Date.now() / 1000)}\n`);
await waitFor(
  () => armCount("stop") === 1,
  "the extension kept its own watcher cycle alive alongside the away daemon",
);

const standby = await tool.execute("call-away", {}, undefined, undefined, {});
if (!standby.content[0]?.text.includes("standby - away mode owns supervision")) {
  throw new Error(`away-mode arm did not report standby: ${standby.content[0]?.text}`);
}
await settle(300);
if (armCount("start") !== 1) {
  throw new Error(`the extension armed a second cycle while away: ${armRecords().join(" | ")}`);
}
if (wakes.length !== 0) {
  throw new Error(`ordinary watcher turns reached the primary while away: ${wakes.join(" | ")}`);
}

// The captain returns: exactly one extension-owned cycle comes back.
rmSync(awayFlag);
await waitFor(
  () => armCount("start") === 2,
  "extension-owned supervision did not resume after away mode cleared",
);
await settle(300);
if (armCount("start") !== 2) {
  throw new Error(`away-mode return armed more than one cycle: ${armRecords().join(" | ")}`);
}
if (wakes.length !== 0) {
  throw new Error(`unexpected watcher turns across the away cycle: ${wakes.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must leave the away daemon as the only supervision cycle and resume exactly one cycle on return"
  [ -z "$out" ] || fail "Pi away-mode test printed output: $out"
  pass "Pi away mode leaves one supervision cycle and resumes exactly one on return"
}

test_pi_extension_reports_external_healthy_watcher
test_pi_away_mode_leaves_one_supervision_cycle
test_pi_tool_returns_agent_tool_result
test_pi_redundant_tool_call_is_owned_noop
test_pi_scheduled_retry_call_is_owned_noop
test_pi_actionable_close_starts_single_successor_before_delivery
test_pi_handling_delivery_failure_is_typed_once
test_pi_hung_successor_falls_back_to_typed_wake
test_pi_unretired_successor_falls_back_without_retry
test_pi_retired_successor_close_at_deadline_keeps_continuity
test_pi_late_unretired_close_resumes_supervision
test_pi_empty_close_retries_instead_of_disappearing
test_pi_established_empty_close_honors_retry_limit
test_pi_actionable_close_rechecks_session_lock
test_pi_arm_distinguishes_session_lock_ownership
test_pi_session_transition_generation_owner
test_pi_process_exit_cleanup_listener_lifecycle
test_pi_process_exit_cleanup_stops_arm_child
test_opencode_plugin_package_boundary_is_explicit_esm
test_opencode_primary_watch_plugin_uses_effective_state_home
test_opencode_primary_watch_plugin_sources_effective_config
test_opencode_primary_watch_plugin_requires_session_lock
test_opencode_watch_arm_coordinator_respects_primary_scope
test_opencode_primary_watch_plugin_rearms_after_wake
test_opencode_pre_ready_actionable_close_preserves_its_successor
test_opencode_hung_successor_falls_back_to_typed_wake
test_opencode_unretired_successor_falls_back_without_retry
test_opencode_late_unretired_close_resumes_supervision
test_opencode_queued_readiness_at_deadline_reports_armed
test_opencode_retired_successor_close_at_deadline_keeps_continuity
test_opencode_empty_close_retries_instead_of_disappearing
test_opencode_established_empty_close_honors_retry_limit
test_opencode_actionable_close_rechecks_session_lock
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
printf '\nall fm-pi-watch-extension tests passed\n'
