#!/usr/bin/env bash
# Behavior tests for the read-only loopback fleet dashboard server and installer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVER="$ROOT/bin/fm-dashboard-server.mjs"
INSTALLER="$ROOT/bin/fm-dashboard-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)
SERVER_PID=
SSE_PID=

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cleanup() {
  if [ -n "$SSE_PID" ]; then kill "$SSE_PID" 2>/dev/null || true; fi
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

write_payload() {  # <path> <title>
  local destination=$1 title=$2
  cat > "$destination" <<JSON
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-08-04T00:00:00Z",
  "tasks": [
    {
      "id": "dashboard-task",
      "kind": "ship",
      "project": "firstmate",
      "harness": "codex",
      "model": "gpt-5.6-sol",
      "effort": "high",
      "backlog": {"title": "$title"},
      "current_state": {"state": "working", "detail": "Implementing the board"},
      "endpoint": {"exists": true, "status": "unknown"},
      "paths": {"status_log": {"last_event_age_seconds": 7}},
      "pr": {"url": "https://github.com/HelloWorldSungin/firstmate/pull/31"},
      "work_items": [{"url":"https://github.com/HelloWorldSungin/firstmate/issues/11","forge":"github","host":"github.com","path":"HelloWorldSungin/firstmate","number":11,"enrichment":{"title":"Dashboard","state":"open"}}],
      "card": {"rank": 8, "column": "active", "action": "supervise", "reason": "contract-defined"}
    },
    {
      "id": "quiet-task",
      "kind": "scout",
      "project": "firstmate",
      "harness": "claude",
      "model": "opus",
      "effort": "medium",
      "backlog": {"title": "No work item"},
      "current_state": {"state": "paused", "detail": "Waiting for an external release"},
      "endpoint": {"exists": false, "status": "absent"},
      "paths": {"status_log": {"last_event_age_seconds": 90}},
      "pr": {"url": null},
      "work_items": [],
      "card": {"rank": 7, "column": "waiting", "action": "recheck", "reason": "contract-defined"}
    },
    {
      "id": "deckhand",
      "kind": "secondmate",
      "project": "",
      "harness": "pi",
      "model": "kimi-k2",
      "effort": "medium",
      "current_state": {"state": "idle", "detail": "Standing by"},
      "endpoint": {"exists": true, "status": "alive"},
      "paths": {"status_log": {"last_event_age_seconds": 20}},
      "work_items": [],
      "card": {"rank": 9, "column": "secondmate", "action": "route_work", "reason": "contract-defined"}
    }
  ],
  "card_precedence": ["needs_decision","blocked","parked","failed","review","done","waiting","active","secondmate","idle"],
  "supervision": {"watcher":{"present":true,"age_seconds":2,"stale":false},"afk":{"active":false}}
}
JSON
}

make_runtime() {  # <name> [with-command]
  local name=$1 with_command=${2:-yes} runtime
  runtime="$TMP_ROOT/$name/runtime"
  mkdir -p "$runtime/bin" "$runtime/assets/dashboard" "$TMP_ROOT/$name/home/data" "$TMP_ROOT/$name/home/state" "$TMP_ROOT/$name/home/projects" "$TMP_ROOT/$name/control"
  cp "$SERVER" "$runtime/bin/fm-dashboard-server.mjs"
  cp "$ROOT/assets/dashboard/"* "$runtime/assets/dashboard/"
  write_payload "$TMP_ROOT/$name/control/payload.json" "Initial dashboard card"
  printf 'good\n' > "$TMP_ROOT/$name/control/mode"
  if [ "$with_command" = yes ]; then
    cat > "$runtime/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
set -u
control=${DASH_TEST_CONTROL:?}
if command -v flock >/dev/null 2>&1; then
  exec 9> "$control/execution.lock"
  if ! flock -n 9; then
    : > "$control/overlap"
    exit 91
  fi
fi
mode=$(cat "$control/mode")
case "$mode" in
  good) cat "$control/payload.json" ;;
  fail) echo "fixture snapshot failed" >&2; exit 7 ;;
  malformed) printf '{not json\n' ;;
  wrong-schema) printf '{"schema":"fm-fleet-snapshot.v99"}\n' ;;
  hung) sleep 4 ;;
  *) echo "unknown fixture mode" >&2; exit 8 ;;
esac
SH
    chmod +x "$runtime/bin/fm-fleet-snapshot.sh"
  fi
  printf '%s\n' "$TMP_ROOT/$name"
}

start_fixture_server() {  # <case-root> <timeout> <poll> [stale]
  local case_root=$1 timeout=$2 poll=$3 stale=${4:-2}
  TEST_PORT=$(free_port)
  FM_HOME="$case_root/home" \
    FM_DASHBOARD_PORT="$TEST_PORT" \
    FM_DASHBOARD_TIMEOUT_SECONDS="$timeout" \
    FM_DASHBOARD_POLL_SECONDS="$poll" \
    FM_DASHBOARD_STALE_SECONDS="$stale" \
    DASH_TEST_CONTROL="$case_root/control" \
    node "$case_root/runtime/bin/fm-dashboard-server.mjs" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
}

start_real_server() {  # <case-root>
  local case_root=$1
  TEST_PORT=$(free_port)
  FM_HOME="$case_root/home" \
    FM_DASHBOARD_PORT="$TEST_PORT" \
    FM_DASHBOARD_TIMEOUT_SECONDS=4 \
    FM_DASHBOARD_POLL_SECONDS=1 \
    node "$SERVER" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
}

wait_for_http() {  # <case-root>
  local case_root=$1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if curl -fsS "http://127.0.0.1:$TEST_PORT/api/snapshot" > "$case_root/envelope.json" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  fail "dashboard server did not listen: $(cat "$case_root/server.log")"
}

wait_for_expression() {  # <case-root> <jq-expression>
  local case_root=$1 expression=$2
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    curl -fsS "http://127.0.0.1:$TEST_PORT/api/snapshot" > "$case_root/envelope.json" || true
    if jq -e "$expression" "$case_root/envelope.json" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  fail "dashboard condition did not arrive ($expression): $(cat "$case_root/envelope.json")"
}

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
  fi
}

test_loopback_is_mandatory() {
  local out rc
  set +e
  out=$(FM_DASHBOARD_ADDRESS=0.0.0.0 node "$SERVER" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dashboard accepted a non-loopback bind"
  assert_contains "$out" "must name a loopback address" "non-loopback refusal was not explicit"
  pass "dashboard refuses every configured non-loopback bind"
}

test_sse_poll_and_last_good() {
  local case_root sse_log
  case_root=$(make_runtime sse)
  start_fixture_server "$case_root" 1 0.2
  wait_for_expression "$case_root" '.status.phase == "ready" and .snapshot.tasks[0].backlog.title == "Initial dashboard card"'

  sse_log="$case_root/sse.log"
  curl --max-time 4 -Ns "http://127.0.0.1:$TEST_PORT/api/events" > "$sse_log" 2>/dev/null &
  SSE_PID=$!
  sleep 0.2
  write_payload "$case_root/control/payload.json" "Updated without reload"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q "Updated without reload" "$sse_log" && break
    sleep 0.1
  done
  grep -q "Updated without reload" "$sse_log" || fail "SSE did not push a poll-driven fleet change"
  kill "$SSE_PID" 2>/dev/null || true
  wait "$SSE_PID" 2>/dev/null || true
  SSE_PID=

  printf 'fail\n' > "$case_root/control/mode"
  wait_for_expression "$case_root" '.status.phase == "last_good" and .status.stale == true and .status.error.kind == "exit_nonzero" and .snapshot.tasks[0].backlog.title == "Updated without reload"'
  stop_server
  pass "poll updates stream over SSE and failed refreshes retain explicit stale last-good data"
}

test_stale_transition_streams_without_refresh() {
  local case_root sse_log
  case_root=$(make_runtime stale-transition)
  start_fixture_server "$case_root" 1 5 1
  wait_for_expression "$case_root" '.status.phase == "ready"'

  sse_log="$case_root/sse-stale.log"
  curl --max-time 2 -Ns "http://127.0.0.1:$TEST_PORT/api/events" > "$sse_log" 2>/dev/null &
  SSE_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q '"stale":true' "$sse_log" && break
    sleep 0.1
  done
  grep -q '"stale":true' "$sse_log" || fail "SSE did not push the configured time-only stale transition"
  kill "$SSE_PID" 2>/dev/null || true
  wait "$SSE_PID" 2>/dev/null || true
  SSE_PID=
  stop_server
  pass "configured freshness threshold streams a stale transition without waiting for the next poll"
}

test_browser_renders_contract_actions_and_liveness() {
  node - "$ROOT/assets/dashboard/app.js" <<'NODE' || fail "dashboard browser contract rendering failed"
const { pathToFileURL } = require("node:url");

class FakeNode {
  constructor(tagName, text = "") {
    this.tagName = tagName.toUpperCase();
    this.children = [];
    this.attributes = {};
    this.className = "";
    this.dataset = {};
    this.id = "";
    this.listeners = {};
    this.value = "";
    this._text = String(text);
  }

  get options() { return this.children; }
  get textContent() { return this._text + this.children.map((child) => child.textContent).join(""); }
  set textContent(value) {
    this._text = String(value ?? "");
    this.children = [];
  }

  append(...children) {
    for (const child of children) {
      if (child === null || child === undefined) continue;
      this.children.push(typeof child === "string" ? new FakeNode("#text", child) : child);
    }
  }

  replaceChildren(...children) {
    this._text = "";
    this.children = [];
    this.append(...children);
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }

  addEventListener(name, listener) {
    this.listeners[name] = listener;
  }
}

const selectors = new Map();
for (const id of ["signals", "badges", "nav-badge", "health-strip", "inbox-list", "notice-region", "refresh-note", "filter-count", "clear-filters", "secondmate-list", "secondmate-count", "kanban", "theme-button", "phone-theme-button", "notify-button", "phone-notify-button"]) {
  selectors.set(`#${id}`, new FakeNode("div"));
}
const filterForm = new FakeNode("form");
filterForm.elements = {};
for (const key of ["project", "harness", "model", "kind", "state"]) {
  const select = new FakeNode("select");
  select.append(new FakeNode("option", `All ${key}`));
  filterForm.elements[key] = select;
}
selectors.set("#filter-form", filterForm);

const document = {
  documentElement: new FakeNode("html"),
  querySelector: (selector) => selectors.get(selector),
  createElement: (tagName) => new FakeNode(tagName),
  createTextNode: (text) => new FakeNode("#text", text),
};

const PR_URL = "https://github.com/HelloWorldSungin/firstmate/pull/31";
const DECISION_TEXT = "Should the retention window stay at 40 records, or drop to 20 so the manifest history fits one screen? Either is defensible.";

function task(id, kind, status, exists, action) {
  return {
    id,
    kind,
    project: "firstmate",
    harness: "codex",
    model: "gpt-5.6-sol",
    effort: "high",
    backlog: { title: id },
    current_state: { state: kind === "secondmate" ? "idle" : "working", detail: "Visible detail" },
    endpoint: { status, exists },
    paths: { status_log: { last_event_age_seconds: 5 } },
    work_items: [],
    card: { column: kind === "secondmate" ? "secondmate" : "active", action },
  };
}

const envelope = {
  schema: "fm-dashboard-envelope.v1",
  status: { phase: "ready", stale: false, last_success_at: "2026-08-04T00:00:00Z", last_success_age_seconds: 0 },
  snapshot: {
    tasks: [
      task("unknown-worker", "ship", "unknown", true, "supervise"),
      task("alive-mate", "secondmate", "alive", true, "route_work"),
      task("dead-mate", "secondmate", "dead", true, "route_work"),
      task("unknown-mate", "secondmate", "unknown", true, "route_work"),
      {
        ...task("waiting-on-you", "ship", "unknown", true, "decide"),
        current_state: { state: "parked", detail: "Parked at a gate" },
        hints: { open_decisions: [{ key: "retention", verb: "needs-decision", summary: DECISION_TEXT }] },
        pr: {
          url: PR_URL,
          number: 31,
          status: { state: "open", review: "approved", checks: "unknown", mergeable: "mergeable" },
          status_age_seconds: 12,
          status_freshness: "cached",
        },
        card: { column: "needs_decision", action: "decide" },
      },
    ],
    card_precedence: ["active", "secondmate"],
    supervision: { watcher: { present: true, age_seconds: 1, grace_seconds: 120, stale: false }, afk: { active: false } },
    main_inventory: { valid: true, orphan_in_flight: [] },
  },
};

class FakeEventSource {
  addEventListener() {}
  close() {}
}

// The browser app is an ES module that imports the inbox policy module beside
// it, so it is loaded through a real module graph rather than a flat script
// evaluation. Its DOM and platform dependencies are resolved from globals.
const storage = new Map();
Object.assign(globalThis, {
  document,
  EventSource: FakeEventSource,
  fetch: async () => ({ ok: true, json: async () => envelope }),
  localStorage: { getItem: (key) => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
  matchMedia: () => ({ matches: false }),
});

import(pathToFileURL(process.argv[2]).href).then(() => new Promise((resolve) => setImmediate(resolve))).then(() => {
  const all = (root, predicate, matches = []) => {
    if (predicate(root)) matches.push(root);
    for (const child of root.children) all(child, predicate, matches);
    return matches;
  };
  const hasClass = (node, className) => node.className.split(/\s+/).includes(className);
  const one = (root, predicate, label) => {
    const matches = all(root, predicate);
    if (matches.length !== 1) throw new Error(`${label}: expected one match, received ${matches.length}`);
    return matches[0];
  };

  const card = one(selectors.get("#kanban"), (node) => hasClass(node, "card"), "worker card");
  const action = one(card, (node) => hasClass(node, "card-action"), "card action");
  if (action.textContent !== "ACTIONsupervise") throw new Error(`card action was not literal: ${action.textContent}`);
  const endpoint = one(card, (node) => hasClass(node, "endpoint"), "worker endpoint");
  one(endpoint, (node) => hasClass(node, "dot") && hasClass(node, "grey"), "unknown endpoint tone");

  const signal = one(selectors.get("#signals"), (node) => hasClass(node, "signal") && node.textContent.includes("SECONDMATES"), "secondmate signal");
  if (!signal.textContent.includes("1 live · 1 dead · 1 unknown")) throw new Error(`liveness counts were collapsed: ${signal.textContent}`);
  one(signal, (node) => hasClass(node, "dot") && hasClass(node, "red"), "dead secondmate signal tone");

  for (const [id, tone] of [["alive-mate", "green"], ["dead-mate", "red"], ["unknown-mate", "grey"]]) {
    const mate = one(selectors.get("#secondmate-list"), (node) => hasClass(node, "mate") && node.textContent.includes(id), `${id} row`);
    one(mate, (node) => hasClass(node, "dot") && hasClass(node, tone), `${id} tone`);
    const mateAction = one(mate, (node) => hasClass(node, "mate-action"), `${id} action`);
    if (mateAction.textContent !== "ACTIONroute_work") throw new Error(`${id} action was not literal: ${mateAction.textContent}`);
  }

  const inboxCard = one(selectors.get("#inbox-list"), (node) => hasClass(node, "inbox-card"), "inbox card");
  const reasonTexts = all(inboxCard, (node) => hasClass(node, "reason-text")).map((node) => node.textContent);
  if (!reasonTexts.includes(DECISION_TEXT)) throw new Error(`decision text was not rendered in full: ${reasonTexts.join(" | ")}`);
  const link = one(inboxCard, (node) => hasClass(node, "pr-link"), "inbox pull-request link");
  if (link.textContent !== PR_URL || link.href !== PR_URL) {
    throw new Error(`pull-request link was not the full https URL: ${link.textContent} / ${link.href}`);
  }
  const checks = one(inboxCard, (node) => hasClass(node, "pr-field") && node.textContent.startsWith("checks"), "checks field");
  if (!hasClass(checks, "unknown") || checks.textContent !== "checksunknown") {
    throw new Error(`an unreadable check state was not rendered as an explicit unknown: ${checks.textContent}`);
  }
  const prPanel = one(inboxCard, (node) => hasClass(node, "pr-panel"), "inbox pull-request panel");
  if (!hasClass(prPanel, "unknown")) throw new Error("a pull request with an unreadable field was not toned unknown");
  const badge = one(selectors.get("#badges"), (node) => hasClass(node, "badge") && node.textContent.includes("Decisions"), "decision badge");
  if (!badge.textContent.startsWith("1")) throw new Error(`decision badge count was wrong: ${badge.textContent}`);
  if (selectors.get("#nav-badge").textContent !== "1") throw new Error("navigation badge did not carry the inbox total");
}).catch((error) => { console.error(error); process.exit(1); });
NODE
  pass "browser renders literal contract actions, distinct liveness, full decision text, and explicit unknown pull-request fields"
}

# Desktop alerts are entirely client-side and must fire only for items the
# captain has not already seen. The two ways to get this wrong are both silent:
# alerting for the whole backlog on the first render, and treating a render that
# carried no snapshot as proof the inbox was empty.
test_browser_alerts_only_for_new_inbox_items() {
  node - "$ROOT/assets/dashboard/app.js" <<'NODE' || fail "dashboard browser alert behavior failed"
const { pathToFileURL } = require("node:url");

class FakeNode {
  constructor(tagName, text = "") {
    this.tagName = tagName.toUpperCase();
    this.children = [];
    this.attributes = {};
    this.className = "";
    this.dataset = {};
    this.listeners = {};
    this.value = "";
    this._text = String(text);
  }

  get options() { return this.children; }
  get textContent() { return this._text + this.children.map((child) => child.textContent).join(""); }
  set textContent(value) {
    this._text = String(value ?? "");
    this.children = [];
  }

  append(...children) {
    for (const child of children) {
      if (child === null || child === undefined) continue;
      this.children.push(typeof child === "string" ? new FakeNode("#text", child) : child);
    }
  }

  replaceChildren(...children) {
    this._text = "";
    this.children = [];
    this.append(...children);
  }

  setAttribute(name, value) { this.attributes[name] = String(value); }
  addEventListener(name, listener) { this.listeners[name] = listener; }
}

const selectors = new Map();
for (const id of ["signals", "badges", "nav-badge", "health-strip", "inbox-list", "notice-region", "refresh-note", "filter-count", "clear-filters", "secondmate-list", "secondmate-count", "kanban", "theme-button", "phone-theme-button", "notify-button", "phone-notify-button"]) {
  selectors.set(`#${id}`, new FakeNode("div"));
}
const filterForm = new FakeNode("form");
filterForm.elements = {};
for (const key of ["project", "harness", "model", "kind", "state"]) {
  const select = new FakeNode("select");
  select.append(new FakeNode("option", `All ${key}`));
  filterForm.elements[key] = select;
}
selectors.set("#filter-form", filterForm);

const document = {
  documentElement: new FakeNode("html"),
  querySelector: (selector) => selectors.get(selector),
  createElement: (tagName) => new FakeNode(tagName),
  createTextNode: (text) => new FakeNode("#text", text),
};

function decisionTask(id) {
  return {
    id,
    kind: "ship",
    project: "firstmate",
    backlog: { title: `${id} title` },
    current_state: { state: "parked", detail: "Parked at a gate" },
    endpoint: { status: "unknown", exists: true },
    paths: { status_log: { last_event_age_seconds: 5 } },
    work_items: [],
    hints: { open_decisions: [{ key: "shape", verb: "needs-decision", summary: `Decide the ${id} shape` }] },
    card: { column: "needs_decision", action: "decide" },
  };
}

function envelopeWith(ids) {
  return {
    schema: "fm-dashboard-envelope.v1",
    status: { phase: "ready", stale: false, last_success_at: "2026-08-04T00:00:00Z", last_success_age_seconds: 0 },
    snapshot: {
      tasks: ids.map(decisionTask),
      card_precedence: ["needs_decision"],
      supervision: { watcher: { present: true, age_seconds: 1, grace_seconds: 120, stale: false }, afk: { active: false } },
      main_inventory: { valid: true, orphan_in_flight: [] },
    },
  };
}

const UNREACHABLE = {
  schema: "fm-dashboard-envelope.v1",
  status: { phase: "unavailable", stale: false, error: { kind: "server_unreachable", message: "HTTP 503" } },
  snapshot: null,
};

const notifications = [];
class FakeNotification {
  constructor(title, options) {
    notifications.push({ title, body: String(options?.body ?? ""), tag: String(options?.tag ?? "") });
  }
}
FakeNotification.permission = "granted";
FakeNotification.requestPermission = async () => "granted";

let streamed = null;
class FakeEventSource {
  addEventListener(name, listener) { if (name === "snapshot") streamed = listener; }
  close() {}
}

const storage = new Map([["fm-dashboard-alerts", "on"]]);
Object.assign(globalThis, {
  document,
  EventSource: FakeEventSource,
  Notification: FakeNotification,
  fetch: async () => ({ ok: true, json: async () => envelopeWith(["already-waiting"]) }),
  localStorage: { getItem: (key) => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
  matchMedia: () => ({ matches: false }),
});

import(pathToFileURL(process.argv[2]).href).then(() => new Promise((resolve) => setImmediate(resolve))).then(() => {
  const push = (envelope) => streamed({ data: JSON.stringify(envelope) });
  if (selectors.get("#notify-button").textContent !== "Alerts on") {
    throw new Error(`a granted saved preference did not restore the alert control: ${selectors.get("#notify-button").textContent}`);
  }
  if (notifications.length) throw new Error(`the first render alerted for items already waiting: ${JSON.stringify(notifications)}`);

  // A render that carried no snapshot saw nothing, so it must not become the
  // baseline: the item still waiting is not new when the server recovers.
  push(UNREACHABLE);
  push(envelopeWith(["already-waiting"]));
  if (notifications.length) throw new Error(`a failed refresh made a waiting item alert as new: ${JSON.stringify(notifications)}`);

  push(envelopeWith(["already-waiting", "just-arrived"]));
  if (notifications.length !== 1) throw new Error(`expected exactly one alert for the new item, received ${JSON.stringify(notifications)}`);
  const [alert] = notifications;
  if (!alert.title.includes("Decision")) throw new Error(`the alert did not name what needs the captain: ${alert.title}`);
  if (!alert.body.includes("just-arrived title") || !alert.body.includes("Decide the just-arrived shape")) {
    throw new Error(`the alert did not carry the new item's title and reason: ${alert.body}`);
  }

  push(envelopeWith(["already-waiting", "just-arrived"]));
  if (notifications.length !== 1) throw new Error(`an unchanged inbox alerted again: ${JSON.stringify(notifications)}`);
}).catch((error) => { console.error(error); process.exit(1); });
NODE
  pass "desktop alerts fire only for genuinely new inbox items and never for a failed refresh"
}

test_timeout_is_single_flight() {
  local case_root
  command -v flock >/dev/null 2>&1 || { echo "skip: flock not found"; return; }
  case_root=$(make_runtime timeout)
  printf 'hung\n' > "$case_root/control/mode"
  start_fixture_server "$case_root" 0.15 0.05
  wait_for_expression "$case_root" '.status.error.kind == "timed_out"'
  sleep 0.5
  [ ! -e "$case_root/control/overlap" ] || fail "snapshot executions overlapped while timeout and poll triggers raced"
  stop_server
  pass "hung snapshots are hard-killed and coalesced without overlapping executions"
}

test_first_run_failures_are_explicit() {
  local case_root
  case_root=$(make_runtime malformed)
  printf 'malformed\n' > "$case_root/control/mode"
  start_fixture_server "$case_root" 1 1
  wait_for_expression "$case_root" '.status.phase == "unavailable" and .status.error.kind == "malformed_json" and .snapshot == null'
  stop_server

  case_root=$(make_runtime version)
  printf 'wrong-schema\n' > "$case_root/control/mode"
  start_fixture_server "$case_root" 1 1
  wait_for_expression "$case_root" '.status.phase == "unavailable" and .status.error.kind == "unsupported_schema"'
  stop_server

  case_root=$(make_runtime missing no)
  start_fixture_server "$case_root" 1 1
  wait_for_expression "$case_root" '.status.phase == "unavailable" and .status.error.kind == "command_missing"'
  stop_server
  pass "malformed JSON, unsupported versions, and missing commands expose first-run errors"
}

fleet_fingerprint() {  # <home>
  node - "$1" <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const rows = [];
function walk(current) {
  for (const name of fs.readdirSync(current).sort()) {
    const full = path.join(current, name);
    const info = fs.lstatSync(full);
    rows.push([path.relative(root, full), info.mode, info.size, info.mtimeMs].join("\t"));
    if (info.isDirectory()) walk(full);
  }
}
walk(root);
process.stdout.write(rows.join("\n") + "\n");
NODE
}

test_real_snapshot_makes_zero_fleet_writes() {
  local case_root before after
  case_root="$TMP_ROOT/read-only"
  mkdir -p "$case_root/home/data" "$case_root/home/state" "$case_root/home/projects"
  printf 'data sentinel\n' > "$case_root/home/data/sentinel"
  printf 'state sentinel\n' > "$case_root/home/state/sentinel"
  printf 'project sentinel\n' > "$case_root/home/projects/sentinel"
  before=$(fleet_fingerprint "$case_root/home")
  start_real_server "$case_root"
  wait_for_expression "$case_root" '.status.phase == "ready" and .snapshot.schema == "fm-fleet-snapshot.v1"'
  sleep 0.2
  after=$(fleet_fingerprint "$case_root/home")
  stop_server
  [ "$after" = "$before" ] || fail "dashboard changed data, state, or projects while reading the real snapshot contract"
  pass "filesystem fingerprinting proves zero dashboard writes across fleet-owned directories"
}

test_installer_writes_hardened_user_service() {
  local case_root unit env_file out
  case_root="$TMP_ROOT/install"
  mkdir -p "$case_root/config" "$case_root/home"
  out=$(HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" "$INSTALLER" \
    --fm-home "$case_root/fleet" --port 18878 --poll 3 --timeout 4 --stale 9 --no-start)
  unit="$case_root/config/systemd/user/firstmate-dashboard.service"
  env_file="$case_root/config/firstmate/dashboard.env"
  [ -f "$unit" ] && [ -f "$env_file" ] || fail "installer did not create the user service and environment"
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_ADDRESS="127.0.0.1"' "installer lost the loopback default"
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_POLL_SECONDS="3"' "installer lost the poll interval"
  assert_contains "$(cat "$unit")" 'ProtectHome=read-only' "service does not enforce a read-only home mount"
  assert_contains "$(cat "$unit")" 'WantedBy=default.target' "service is not boot-persistent"
  assert_contains "$out" "Service not started (--no-start)." "installer did not honor its no-start boundary"
  pass "installer configures a hardened boot-persistent user service without sudo"
}

test_loopback_is_mandatory
test_sse_poll_and_last_good
test_stale_transition_streams_without_refresh
test_browser_renders_contract_actions_and_liveness
test_browser_alerts_only_for_new_inbox_items
test_timeout_is_single_flight
test_first_run_failures_are_explicit
test_real_snapshot_makes_zero_fleet_writes
test_installer_writes_hardened_user_service
