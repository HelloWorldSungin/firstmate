#!/usr/bin/env bash
# Behavior tests for the read-only loopback fleet dashboard server and installer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVER="$ROOT/bin/fm-dashboard-server.mjs"
INSTALLER="$ROOT/bin/fm-dashboard-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)
# Most servers below are fixture servers that configure no instrumentation, so
# this is where a dashboard that opened its store unconditionally would show up:
# outside every FM_HOME, in the operator's own state root.
USER_EVENT_STORE_BEFORE=$(fm_user_event_store_snapshot)
SERVER_PID=
SSE_PID=
EVENT_TOKEN=

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
  # The server imports its event store, which imports the shared telemetry
  # store discipline. A fixture runtime that copied only the server would fail
  # to start for a reason unrelated to the case under test.
  cp "$ROOT/bin/fm-event-store.mjs" "$ROOT/bin/fm-telemetry-store.mjs" "$runtime/bin/"
  cp "$ROOT/assets/dashboard/"* "$runtime/assets/dashboard/"
  write_payload "$TMP_ROOT/$name/control/payload.json" "Initial dashboard card"
  printf 'good\n' > "$TMP_ROOT/$name/control/mode"
  if [ "$with_command" = yes ]; then
    cat > "$runtime/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
set -u
control=${DASH_TEST_CONTROL:?}
printf 'run\n' >> "$control/executions"
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
  EVENT_TOKEN=0123456789abcdef0123456789abcdef
  printf '{"schema":"fm-dashboard-events-config.v1","url":"http://127.0.0.1:%s/events","token":"%s"}\n' \
    "$TEST_PORT" "$EVENT_TOKEN" > "$case_root/dashboard-events.json"
  FM_HOME="$case_root/home" \
    FM_DASHBOARD_PORT="$TEST_PORT" \
    FM_DASHBOARD_TIMEOUT_SECONDS=4 \
    FM_DASHBOARD_POLL_SECONDS=1 \
    FM_DASHBOARD_EVENTS_CONFIG="$case_root/dashboard-events.json" \
    FM_DASHBOARD_EVENT_DB="$case_root/events.db" \
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

# The bind address decides what this process is reachable on, so it may not be
# anything whose meaning is resolved elsewhere. tests/fm-dashboard-access.test.sh
# owns the rest of that contract: exposure beyond loopback and the credentials
# it requires.
test_the_bind_address_is_a_numeric_address() {
  local out rc
  set +e
  out=$(FM_DASHBOARD_ADDRESS=dashboard.invalid node "$SERVER" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dashboard accepted a name as its bind address"
  assert_contains "$out" "must be a numeric IPv4 or IPv6 address" "the refusal was not explicit"
  pass "dashboard refuses a bind address that name resolution would decide"
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

test_browser_renders_exclusive_views_and_honest_states() {
  node - "$ROOT/assets/dashboard/app.js" <<'NODE' || fail "dashboard exclusive-view rendering failed"
const { pathToFileURL } = require("node:url");

// A minimal DOM for the rebuilt shell: the static index.html nodes the app
// wires itself to, plus enough of Node/Element for the render path. Parents
// are tracked so closest() works, because the task page reads back up the
// tree it just built.
class FakeNode {
  constructor(tagName, text = "") {
    this.tagName = String(tagName).toUpperCase();
    this.children = [];
    this.attributes = {};
    this.className = "";
    this.dataset = {};
    this.id = "";
    this.listeners = {};
    this.value = "";
    this.selectionStart = 0;
    this.selectionEnd = 0;
    this.focused = false;
    this.hidden = false;
    this.parent = null;
    this.style = { properties: {}, setProperty(name, value) { this.properties[name] = value; } };
    this._text = String(text);
    const node = this;
    this.classList = {
      add(...names) { for (const name of names) if (!node.classNames().includes(name)) node.className = `${node.className} ${name}`.trim(); },
      remove(...names) { node.className = node.classNames().filter((existing) => !names.includes(existing)).join(" "); },
      toggle(name, force) {
        const has = node.classNames().includes(name);
        const want = force === undefined ? !has : Boolean(force);
        if (want && !has) node.classList.add(name);
        if (!want && has) node.classList.remove(name);
        return want;
      },
      contains(name) { return node.classNames().includes(name); },
    };
  }

  classNames() { return this.className.split(/\s+/).filter(Boolean); }
  get options() { return this.children; }
  get childNodes() { return this.children; }
  get firstElementChild() { return this.children.find((child) => child.tagName !== "#TEXT") ?? null; }
  get textContent() { return this._text + this.children.map((child) => child.textContent).join(""); }
  set textContent(value) { this._text = String(value ?? ""); this.children = []; }

  append(...children) {
    for (const child of children) {
      if (child === null || child === undefined) continue;
      const node = typeof child === "string" ? new FakeNode("#text", child) : child;
      node.parent = this;
      this.children.push(node);
    }
  }

  replaceChildren(...children) {
    this._text = "";
    for (const child of this.children) child.parent = null;
    this.children = [];
    this.append(...children);
  }

  insertBefore(child, before) {
    if (child.parent) child.parent.removeChild(child);
    const index = before ? this.children.indexOf(before) : this.children.length;
    child.parent = this;
    this.children.splice(index < 0 ? this.children.length : index, 0, child);
    return child;
  }

  replaceChild(child, replaced) {
    const index = this.children.indexOf(replaced);
    if (index < 0) throw new Error("replacement target is not a child");
    if (child.parent) child.parent.removeChild(child);
    replaced.parent = null;
    child.parent = this;
    this.children[index] = child;
    return replaced;
  }

  removeChild(child) {
    const index = this.children.indexOf(child);
    if (index < 0) throw new Error("removal target is not a child");
    this.children.splice(index, 1);
    child.parent = null;
    return child;
  }

  setAttribute(name, value) { this.attributes[name] = String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  addEventListener(name, listener) { this.listeners[name] = listener; }
  focus() { this.focused = true; }
  setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }
  getBoundingClientRect() { return this.rect ?? { top: 0, bottom: 0, height: 0 }; }

  matchesSelector(selector) {
    if (selector.startsWith("#")) return this.id === selector.slice(1);
    if (selector.startsWith(".")) return this.classNames().includes(selector.slice(1));
    return this.tagName === selector.toUpperCase();
  }

  querySelector(selector) {
    for (const child of this.children) {
      if (child.matchesSelector(selector)) return child;
      const hit = child.querySelector(selector);
      if (hit) return hit;
    }
    return null;
  }

  closest(selector) {
    let node = this;
    while (node) {
      if (node.matchesSelector && node.matchesSelector(selector)) return node;
      node = node.parent;
    }
    return null;
  }

  click() { this.listeners.click?.({ stopPropagation() {} }); }
}

const byId = new Map();
function staticNode(tag, id, className = "") {
  const node = new FakeNode(tag);
  node.id = id;
  node.className = className;
  byId.set(id, node);
  return node;
}
const appNode = staticNode("div", "app", "app");
const viewNode = staticNode("main", "view", "main");
staticNode("span", "vdot", "vdot");
staticNode("span", "verdict", "verdict");
staticNode("div", "segbar", "segbar");
staticNode("span", "stalenote", "stalenote");
staticNode("span", "staleno-txt");
staticNode("span", "navbadge", "navbadge");
staticNode("span", "tabbadge", "tabbadge");
for (const buttonId of ["theme-button", "notify-button"]) {
  const button = staticNode("button", buttonId, "iconbtn");
  button.append(Object.assign(new FakeNode("span"), { className: "nlabel" }));
}
const routeButtons = [];
for (const route of ["needs", "fleet", "backlog", "history", "knowledge"]) {
  for (const prefix of ["nav", "tab"]) {
    const button = staticNode("button", `${prefix}-${route}`, prefix === "nav" ? "navitem" : "tabitem");
    button.dataset.route = route;
    routeButtons.push(button);
  }
}

const document = {
  documentElement: new FakeNode("html"),
  getElementById: (id) => byId.get(id) ?? null,
  querySelector: (selector) => {
    const compound = selector.match(/^#([\w-]+)\s+\.([\w-]+)$/);
    if (compound) return byId.get(compound[1])?.querySelector(`.${compound[2]}`) ?? null;
    if (selector.startsWith("#")) return byId.get(selector.slice(1)) ?? null;
    return null;
  },
  querySelectorAll: (selector) => (selector === "[data-route]" ? routeButtons : []),
  createElement: (tagName) => new FakeNode(tagName),
  createTextNode: (text) => new FakeNode("#text", text),
};

const PR_URL = "https://github.com/HelloWorldSungin/firstmate/pull/31";
const DECISION_TEXT = "Should the retention window stay at 40 records, or drop to 20 so the manifest history fits one screen? Either is defensible.";
const TASK_ID = "waiting-on-you";

function task(id, kind, column) {
  return {
    id,
    kind,
    project: "firstmate",
    harness: "codex",
    model: "gpt-5.6-sol",
    backlog: { title: `${id} title` },
    current_state: { state: "working", detail: "Visible detail" },
    endpoint: { status: "alive", exists: true },
    paths: { status_log: { last_event_age_seconds: 5 } },
    work_items: [],
    spawn_age_seconds: 120,
    card: { column },
  };
}

const envelope = {
  schema: "fm-dashboard-envelope.v1",
  status: { phase: "ready", stale: false, last_success_at: "2026-08-04T00:00:00Z", last_success_age_seconds: 0 },
  snapshot: {
    tasks: [
      task("busy-worker", "ship", "active"),
      task("resting-mate", "secondmate", "secondmate"),
      {
        ...task(TASK_ID, "ship", "needs_decision"),
        current_state: { state: "parked", detail: "Parked at a gate" },
        hints: { open_decisions: [{ key: "retention", verb: "needs-decision", summary: DECISION_TEXT }] },
        pr: {
          url: PR_URL,
          number: 31,
          status: { state: "open", review: "approved", checks: "unknown", mergeable: "mergeable" },
          status_age_seconds: 12,
          status_freshness: "cached",
        },
      },
    ],
    card_precedence: ["needs_decision", "active", "secondmate"],
    supervision: { watcher: { present: true, age_seconds: 1, grace_seconds: 120, stale: false }, afk: { active: false } },
    main_inventory: { valid: true, orphan_in_flight: [] },
  },
};

const recentIso = (hoursAgo) => new Date(Date.now() - hoursAgo * 3_600_000).toISOString().replace(/\.\d+Z$/, "Z");
function completionRecord(id, state, hoursAgo) {
  return {
    schema: "fm-outcome-manifest.v1",
    task_id: id,
    title: `${id} delivered title`,
    project: id === "delivered-one" ? "/home/captain/projects/firstmate" : "firstmate",
    kind: "ship",
    outcome: { state },
    timestamps: { completed: recentIso(hoursAgo) },
    pr: id === "delivered-one" ? {
      url: "https://github.com/HelloWorldSungin/firstmate/pull/156",
      status: { state: "merged", review: "approved", checks: "passing", mergeable: "mergeable", observed_at: recentIso(hoursAgo), source: "github" },
    } : {},
    report: {},
    work_items: id === "delivered-one" ? { references: [{ forge: "github", url: "https://github.com/HelloWorldSungin/firstmate/issues/156", enrichment: { title: "Dashboard rebuild" } }] } : { references: [] },
  };
}
const historyEnvelope = {
  schema: "fm-dashboard-history.v1",
  status: { phase: "ready", stale: false, last_success_at: recentIso(0), last_success_age_seconds: 0 },
  history: {
    present: true,
    records: [
      completionRecord("delivered-one", "done", 2),
      completionRecord("delivered-two", "done", 5),
      completionRecord("failed-one", "failed", 9),
    ],
    malformed: [],
  },
};
const backlogEnvelope = {
  schema: "fm-dashboard-backlog.v1",
  status: { phase: "ready", stale: false, last_success_at: recentIso(0), last_success_age_seconds: 0 },
  backlog: {
    present: true,
    records: [
      { id: "queued-a", title: "Queued a", state: "queued", repo: "/home/captain/projects/firstmate", order: 1 },
      { id: "held-b", title: "Held b", state: "queued", hold_reason: "waiting on the captain", order: 2 },
    ],
  },
};
const gbrainHealth = { schema: "fm-gbrain-health.v1", status: {}, config: {}, health: { configured: false } };
let timelineEnvelope = {
  events: [
    { event_id: "e1", task_id: TASK_ID, harness: "codex", type: "tool_finished", tool: "bash", outcome: "ok", occurred_at: "2026-08-15T10:00:02Z", occurred_epoch: 2 },
    { event_id: "e2", task_id: TASK_ID, harness: "codex", type: "tool_finished", tool: "bash", occurred_at: "2026-08-15T10:00:01Z", occurred_epoch: 1 },
  ],
};

const eventSources = [];
let timelineFetches = 0;
class FakeEventSource {
  constructor() {
    this.listeners = {};
    eventSources.push(this);
  }

  addEventListener(name, listener) { this.listeners[name] = listener; }
  close() {}
}

const scrollCalls = [];
const fakeWindow = {
  innerWidth: 1440,
  innerHeight: 900,
  scrollY: 0,
  location: { hash: "" },
  listeners: {},
  history: { back() {} },
  addEventListener(name, listener) { fakeWindow.listeners[name] = listener; },
  scrollTo(options) { scrollCalls.push(options); },
  open() {},
};

const storage = new Map();
Object.assign(globalThis, {
  document,
  window: fakeWindow,
  requestAnimationFrame: (frame) => { frame(); return 0; },
  EventSource: FakeEventSource,
  fetch: async (url) => ({
    ok: true,
    json: async () => {
      if (url.startsWith("/api/snapshot")) return envelope;
      if (url.startsWith("/api/history")) return historyEnvelope;
      if (url.startsWith("/api/backlog")) return backlogEnvelope;
      if (url.startsWith("/api/gbrain/health")) return gbrainHealth;
      if (url.startsWith("/api/timeline")) { timelineFetches += 1; return timelineEnvelope; }
      return {};
    },
  }),
  localStorage: { getItem: (key) => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
});

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

import(pathToFileURL(process.argv[2]).href).then(async () => {
  await settle();
  await settle();

  const all = (root, predicate, matches = []) => {
    if (predicate(root)) matches.push(root);
    for (const child of root.children) all(child, predicate, matches);
    return matches;
  };
  const hasClass = (node, className) => node.classNames().includes(className);
  const one = (root, predicate, label) => {
    const matches = all(root, predicate);
    if (matches.length !== 1) throw new Error(`${label}: expected one match, received ${matches.length}`);
    return matches[0];
  };

  const VIEW_IDS = ["view-needs", "view-fleet", "view-backlog", "view-history", "view-knowledge", "view-task"];
  // The exclusivity assertion the rebuild exists for: the active view's root
  // is on the page AND every other view root is absent from the DOM - not
  // hidden, absent. A check that only looked for the active view would pass
  // against the old always-render-everything page.
  const assertOnly = (activeId, when) => {
    const present = VIEW_IDS.filter((id) => all(viewNode, (node) => node.id === id).length > 0);
    if (present.length !== 1 || present[0] !== activeId) {
      throw new Error(`${when}: expected only #${activeId} in the view container, found [${present.join(", ")}]`);
    }
    for (const id of VIEW_IDS) {
      if (id === activeId) continue;
      if (all(viewNode, (node) => node.id === id).length !== 0) throw new Error(`${when}: #${id} is on the page beside #${activeId}`);
    }
  };
  const go = async (hash) => {
    fakeWindow.location.hash = hash;
    fakeWindow.listeners.hashchange();
    await settle();
  };

  // --- the default route renders Needs you, alone ---------------------------
  assertOnly("view-needs", "initial render");
  const verdict = byId.get("verdict");
  if (verdict.textContent !== "1 decision waiting") throw new Error(`the verdict did not count the decision: ${verdict.textContent}`);
  if (byId.get("vdot").className !== "vdot vd-amber") throw new Error(`the verdict dot missed its tone: ${byId.get("vdot").className}`);
  for (const badgeId of ["navbadge", "tabbadge"]) {
    const badge = byId.get(badgeId);
    if (badge.hidden || badge.textContent !== "1") throw new Error(`${badgeId} did not carry the inbox count: hidden=${badge.hidden} text=${badge.textContent}`);
  }
  const card = one(viewNode, (node) => hasClass(node, "card"), "needs card");
  const ask = one(card, (node) => hasClass(node, "card-ask"), "card ask");
  if (ask.textContent !== DECISION_TEXT) throw new Error(`the decision text was not rendered in full: ${ask.textContent}`);

  // --- every route renders its view and only its view ------------------------
  for (const route of ["fleet", "backlog", "history", "knowledge", "needs"]) {
    await go(`#/${route}`);
    assertOnly(`view-${route}`, `#/${route}`);
    for (const button of routeButtons) {
      const active = button.dataset.route === route;
      if (hasClass(button, "is-active") !== active) throw new Error(`#/${route}: ${button.id} active state is wrong`);
      if (active && button.attributes["aria-current"] !== "page") throw new Error(`#/${route}: ${button.id} lost aria-current`);
      if (!active && "aria-current" in button.attributes) throw new Error(`#/${route}: ${button.id} kept a stale aria-current`);
    }
  }

  // --- History displays every record it found --------------------------------
  await go("#/history");
  let historyRows = all(viewNode, (node) => hasClass(node, "rrow"));
  if (historyRows.length !== 3) throw new Error(`History found 3 completion records but displayed ${historyRows.length}`);
  const shownTitles = historyRows.map((row) => row.textContent);
  for (const id of ["delivered-one", "delivered-two", "failed-one"]) {
    if (!shownTitles.some((title) => title.includes(`${id} delivered title`))) throw new Error(`the ${id} record is not on the page`);
  }
  const delivered = all(viewNode, (node) => hasClass(node, "stat")).map((node) => node.textContent).find((text) => text.startsWith("Delivered"));
  if (delivered !== "Delivered2") throw new Error(`the Delivered stat did not count the done records: ${delivered}`);
  let historySearch = one(viewNode, (node) => node.id === "history-search", "history search");
  historySearch.focus();
  historySearch.value = "del";
  historySearch.selectionStart = 3;
  historySearch.selectionEnd = 3;
  historySearch.listeners.input();
  const mountedHistorySearch = one(viewNode, (node) => node.id === "history-search", "mounted history search");
  eventSources[0].listeners.history({ data: JSON.stringify(historyEnvelope) });
  historySearch = one(viewNode, (node) => node.id === "history-search", "history search after refresh");
  if (historySearch !== mountedHistorySearch || !historySearch.focused || historySearch.selectionStart !== 3) throw new Error("History search was replaced by a data refresh");
  historySearch.value = "delivered-two";
  historySearch.selectionStart = 13;
  historySearch.selectionEnd = 13;
  historySearch.listeners.input();
  historySearch = one(viewNode, (node) => node.id === "history-search", "second restored history search");
  historyRows = all(viewNode, (node) => hasClass(node, "rrow"));
  if (!historySearch.focused || historySearch.value !== "delivered-two" || historyRows.length !== 1) throw new Error("History search did not accept multiple characters continuously");

  // --- Backlog renders the queue with its held reason -------------------------
  await go("#/backlog");
  let backlogRows = all(viewNode, (node) => hasClass(node, "rrow"));
  if (backlogRows.length !== 2) throw new Error(`the backlog queue rendered ${backlogRows.length} of 2 rows`);
  if (!backlogRows[1].textContent.includes("waiting on the captain")) throw new Error("the held reason is not on the page");
  if (one(viewNode, (node) => node.id === "view-backlog", "backlog view").textContent.includes("/home/captain")) throw new Error("a backlog project path reached the page");
  if (!all(viewNode, (node) => hasClass(node, "ronote")).length) throw new Error("the read-only note is missing from the Backlog page");
  let backlogSearch = one(viewNode, (node) => node.id === "backlog-search", "backlog search");
  backlogSearch.focus();
  backlogSearch.value = "he";
  backlogSearch.selectionStart = 2;
  backlogSearch.selectionEnd = 2;
  backlogSearch.listeners.input();
  const mountedBacklogSearch = one(viewNode, (node) => node.id === "backlog-search", "mounted backlog search");
  eventSources[0].listeners.backlog({ data: JSON.stringify(backlogEnvelope) });
  backlogSearch = one(viewNode, (node) => node.id === "backlog-search", "backlog search after refresh");
  if (backlogSearch !== mountedBacklogSearch || !backlogSearch.focused) throw new Error("Backlog search was replaced by a data refresh");
  backlogSearch.value = "held";
  backlogSearch.selectionStart = 4;
  backlogSearch.selectionEnd = 4;
  backlogSearch.listeners.input();
  backlogSearch = one(viewNode, (node) => node.id === "backlog-search", "second restored backlog search");
  backlogRows = all(viewNode, (node) => hasClass(node, "rrow"));
  if (!backlogSearch.focused || backlogSearch.value !== "held" || backlogRows.length !== 1) throw new Error("Backlog search did not accept multiple characters continuously");

  // --- Knowledge without a brain is the quiet explanation page ----------------
  await go("#/knowledge");
  const knowledgeText = one(viewNode, (node) => node.id === "view-knowledge", "knowledge view").textContent;
  if (!knowledgeText.includes("Knowledge is not configured.")) throw new Error(`the no-brain page lost its explanation: ${knowledgeText}`);

  // --- the task route: kv strip, full PR URL, and honest outcome chips -------
  await go(`#/task/${TASK_ID}`);
  assertOnly("view-task", "task route");
  await settle();
  await settle();
  const taskView = one(viewNode, (node) => node.id === "view-task", "task view");
  const prLink = one(taskView, (node) => node.tagName === "A" && node.textContent === PR_URL, "task PR link");
  if (prLink.href !== PR_URL) throw new Error(`the PR link href is not the full https URL: ${prLink.href}`);
  const chips = all(taskView, (node) => hasClass(node, "chip"));
  if (chips.length !== 2) throw new Error(`expected two outcome chips on the timeline, found ${chips.length}`);
  const okChip = chips.find((chip) => chip.textContent === "ok");
  if (!okChip || !hasClass(okChip, "green")) throw new Error("an observed ok outcome did not render as a green chip");
  const unknownChip = chips.find((chip) => chip.textContent === "unknown");
  if (!unknownChip || !hasClass(unknownChip, "unknown")) throw new Error("an unobserved outcome did not render as an explicit unknown chip");
  const beforeBroadcast = timelineFetches;
  eventSources[0].listeners.agent_events({ data: JSON.stringify({
    schema: "fm-dashboard-events.v1",
    events: [{ event_id: "e3", task_id: TASK_ID, harness: "codex", type: "tool_finished", tool: "git", outcome: "failed", occurred_at: "2026-08-15T10:00:03Z", occurred_epoch: 3 }],
  }) });
  await settle();
  if (timelineFetches !== beforeBroadcast) throw new Error("an agent_events broadcast refetched the task timeline");
  if (!one(viewNode, (node) => node.id === "view-task", "updated task view").textContent.includes("git")) throw new Error("the task-scoped event tail was not merged into the cached timeline");

  timelineEnvelope = {
    status: { ingestion: "unavailable", reason: "the event store is unreadable" },
    events: [],
  };
  await go("#/task/resting-mate");
  await settle();
  await settle();
  const unavailableTimeline = one(viewNode, (node) => node.id === "view-task", "task with unavailable timeline");
  if (!unavailableTimeline.textContent.includes("Activity cannot be recorded: the event store is unreadable")) throw new Error("an unavailable task timeline lost its failure notice");
  if (unavailableTimeline.textContent.includes("No events are recorded for this task")) throw new Error("an unavailable task timeline rendered as calmly empty");

  await go("#/task/delivered-one");
  const completedTask = one(viewNode, (node) => node.id === "view-task", "completed task view");
  if (completedTask.textContent.includes("/home/captain")) throw new Error("a completed task project path reached the page");
  if (!completedTask.textContent.includes("merged") || !completedTask.textContent.includes("Dashboard rebuild")) throw new Error("the normalized completion PR or work item did not render");

  await go("#/task/queued-a");
  const queuedTask = one(viewNode, (node) => node.id === "view-task", "queued task view");
  if (!queuedTask.textContent.includes("firstmate") || queuedTask.textContent.includes("/home/captain")) throw new Error("the normalized queued project label did not render safely");

  eventSources[0].listeners.backlog({ data: JSON.stringify({
    ...backlogEnvelope,
    backlog: { ...backlogEnvelope.backlog, records: [...backlogEnvelope.backlog.records, { id: "just-done", title: "Just delivered", state: "done", repo: "/home/captain/projects/firstmate", kind: "ship", order: 3 }] },
  }) });
  await go("#/task/just-done");
  const doneTransition = one(viewNode, (node) => node.id === "view-task", "done backlog transition");
  if (!doneTransition.textContent.includes("Just delivered") || doneTransition.textContent.includes("No such task") || doneTransition.textContent.includes("/home/captain")) throw new Error("a Done transition disappeared before History caught up");

  eventSources[0].listeners.history({ data: JSON.stringify({
    ...historyEnvelope,
    history: { ...historyEnvelope.history, truncated: true, total: 90 },
  }) });
  await go("#/task/not-recorded");
  const boundedLookup = one(viewNode, (node) => node.id === "view-task", "bounded task lookup").textContent;
  if (!boundedLookup.includes("Task lookup unavailable") || boundedLookup.includes("No such task")) throw new Error(`a truncated completion read became conclusive negative evidence: ${boundedLookup}`);

  eventSources[0].listeners.history({ data: JSON.stringify({
    ...historyEnvelope,
    status: { phase: "last_good", stale: true, error: { message: "history refresh failed" } },
    history: { ...historyEnvelope.history, truncated: true, total: 90 },
  }) });
  await go("#/task/delivered-one");
  const staleCompletedTask = one(viewNode, (node) => node.id === "view-task", "stale completed task").textContent;
  if (!staleCompletedTask.includes("last known good completion history")) throw new Error(`a task found in stale History lost its disclosure: ${staleCompletedTask}`);
  await go("#/history");
  const staleHistory = one(viewNode, (node) => node.id === "view-history", "stale history view").textContent;
  if (!staleHistory.includes("last known good completion history") || !staleHistory.includes("showing 3 of 90 completed records")) throw new Error(`History did not disclose stale bounded data: ${staleHistory}`);

  eventSources[0].listeners.backlog({ data: JSON.stringify({
    schema: "fm-dashboard-backlog.v1",
    status: { phase: "unavailable", stale: false, error: { message: "backlog refresh failed" } },
    backlog: { present: false, records: [] },
  }) });
  await go("#/backlog");
  const failedBacklog = one(viewNode, (node) => node.id === "view-backlog", "failed backlog view").textContent;
  if (!failedBacklog.includes("Backlog unavailable") || failedBacklog.includes("Nothing queued yet")) throw new Error(`an unreadable backlog rendered as a calm empty queue: ${failedBacklog}`);

  // --- an unreadable fleet is never the calm first-run page -------------------
  const push = (payload) => eventSources[0].listeners.snapshot({ data: JSON.stringify(payload) });
  push({ schema: "fm-dashboard-envelope.v1", status: { phase: "unavailable", stale: false, error: { kind: "server_unreachable", message: "HTTP 503" } }, snapshot: null });
  await go("#/task/not-recorded");
  const failedLookup = one(viewNode, (node) => node.id === "view-task", "failed task lookup").textContent;
  if (!failedLookup.includes("Task lookup unavailable") || failedLookup.includes("No such task")) throw new Error(`a failed source became negative task evidence: ${failedLookup}`);
  await go("#/needs");
  if (verdict.textContent !== "Fleet unavailable") throw new Error(`an unreachable fleet read as: ${verdict.textContent}`);
  if (byId.get("vdot").className !== "vdot vd-unknown") throw new Error(`the unavailable verdict dot is not the hollow unknown: ${byId.get("vdot").className}`);
  let needsText = one(viewNode, (node) => node.id === "view-needs", "needs view").textContent;
  if (needsText.includes("Nothing has run yet") || needsText.includes("Nothing needs you")) throw new Error(`an unreachable fleet rendered as a calm page: ${needsText}`);
  if (!needsText.includes("HTTP 503") || !needsText.includes("Retrying automatically.")) throw new Error(`the failure was not disclosed with its retry story: ${needsText}`);

  // --- a stale service unit says polling is paused, not retrying --------------
  push({ schema: "fm-dashboard-envelope.v1", status: { phase: "unavailable", stale: false, error: { kind: "service_unit_outdated", message: "rerun bin/fm-dashboard-install.sh" } }, snapshot: null });
  await settle();
  needsText = one(viewNode, (node) => node.id === "view-needs", "needs view").textContent;
  if (!needsText.includes("Snapshot polling is paused until the service is reinstalled.")) throw new Error(`the stale unit's paused polling was not explained: ${needsText}`);
  if (needsText.includes("Retrying automatically.")) throw new Error(`the stale unit falsely claimed automatic retries: ${needsText}`);
}).catch((error) => { console.error(error); process.exit(1); });
NODE
  pass "each route renders its view alone with the others absent, History displays every record, and an unreadable fleet is disclosed rather than rendered calm"
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
    this.tagName = String(tagName).toUpperCase();
    this.children = [];
    this.attributes = {};
    this.className = "";
    this.dataset = {};
    this.id = "";
    this.listeners = {};
    this.value = "";
    this.hidden = false;
    this.parent = null;
    this.style = { properties: {}, setProperty(name, value) { this.properties[name] = value; } };
    this._text = String(text);
    const node = this;
    this.classList = {
      add(...names) { for (const name of names) if (!node.classNames().includes(name)) node.className = `${node.className} ${name}`.trim(); },
      remove(...names) { node.className = node.classNames().filter((existing) => !names.includes(existing)).join(" "); },
      toggle(name, force) {
        const has = node.classNames().includes(name);
        const want = force === undefined ? !has : Boolean(force);
        if (want && !has) node.classList.add(name);
        if (!want && has) node.classList.remove(name);
        return want;
      },
      contains(name) { return node.classNames().includes(name); },
    };
  }

  classNames() { return this.className.split(/\s+/).filter(Boolean); }
  get options() { return this.children; }
  get textContent() { return this._text + this.children.map((child) => child.textContent).join(""); }
  set textContent(value) { this._text = String(value ?? ""); this.children = []; }

  append(...children) {
    for (const child of children) {
      if (child === null || child === undefined) continue;
      const node = typeof child === "string" ? new FakeNode("#text", child) : child;
      node.parent = this;
      this.children.push(node);
    }
  }

  replaceChildren(...children) {
    this._text = "";
    for (const child of this.children) child.parent = null;
    this.children = [];
    this.append(...children);
  }

  setAttribute(name, value) { this.attributes[name] = String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  addEventListener(name, listener) { this.listeners[name] = listener; }
  getBoundingClientRect() { return this.rect ?? { top: 0, bottom: 0, height: 0 }; }
  matchesSelector(selector) {
    if (selector.startsWith("#")) return this.id === selector.slice(1);
    if (selector.startsWith(".")) return this.classNames().includes(selector.slice(1));
    return this.tagName === selector.toUpperCase();
  }

  querySelector(selector) {
    for (const child of this.children) {
      if (child.matchesSelector(selector)) return child;
      const hit = child.querySelector(selector);
      if (hit) return hit;
    }
    return null;
  }

  closest(selector) {
    let node = this;
    while (node) {
      if (node.matchesSelector && node.matchesSelector(selector)) return node;
      node = node.parent;
    }
    return null;
  }
}

const byId = new Map();
function staticNode(tag, id, className = "") {
  const node = new FakeNode(tag);
  node.id = id;
  node.className = className;
  byId.set(id, node);
  return node;
}
staticNode("div", "app", "app");
staticNode("main", "view", "main");
staticNode("span", "vdot", "vdot");
staticNode("span", "verdict", "verdict");
staticNode("div", "segbar", "segbar");
staticNode("span", "stalenote", "stalenote");
staticNode("span", "staleno-txt");
staticNode("span", "navbadge", "navbadge");
staticNode("span", "tabbadge", "tabbadge");
for (const buttonId of ["theme-button", "notify-button"]) {
  const button = staticNode("button", buttonId, "iconbtn");
  button.append(Object.assign(new FakeNode("span"), { className: "nlabel" }));
}

const document = {
  documentElement: new FakeNode("html"),
  getElementById: (id) => byId.get(id) ?? null,
  querySelector: (selector) => {
    const compound = selector.match(/^#([\w-]+)\s+\.([\w-]+)$/);
    if (compound) return byId.get(compound[1])?.querySelector(`.${compound[2]}`) ?? null;
    if (selector.startsWith("#")) return byId.get(selector.slice(1)) ?? null;
    return null;
  },
  querySelectorAll: () => [],
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
    card: { column: "needs_decision" },
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
  window: { innerWidth: 390, innerHeight: 844, scrollY: 0, location: { hash: "" }, addEventListener() {}, scrollTo() {}, history: { back() {} } },
  requestAnimationFrame: (frame) => { frame(); return 0; },
  EventSource: FakeEventSource,
  Notification: FakeNotification,
  fetch: async (url) => ({ ok: true, json: async () => (url.startsWith("/api/snapshot") ? envelopeWith(["already-waiting"]) : {}) }),
  localStorage: { getItem: (key) => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
});

import(pathToFileURL(process.argv[2]).href).then(() => new Promise((resolve) => setImmediate(resolve))).then(() => {
  const push = (envelope) => streamed({ data: JSON.stringify(envelope) });
  if (byId.get("notify-button").textContent !== "Alerts on") {
    throw new Error(`a granted saved preference did not restore the alert control: ${byId.get("notify-button").textContent}`);
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
  if (!alert.title.includes("needs you")) throw new Error(`the alert did not say something needs the captain: ${alert.title}`);
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
  local case_root runs
  command -v flock >/dev/null 2>&1 || { echo "skip: flock not found"; return; }
  case_root=$(make_runtime timeout)
  printf 'hung\n' > "$case_root/control/mode"
  start_fixture_server "$case_root" 0.15 0.1
  wait_for_expression "$case_root" '.status.error.kind == "timed_out"'
  sleep 0.02
  runs=$(wc -l < "$case_root/control/executions")
  [ "$runs" -eq 1 ] || fail "a poll arriving mid-snapshot queued an immediate catch-up run ($runs runs)"
  sleep 0.25
  [ ! -e "$case_root/control/overlap" ] || fail "snapshot executions overlapped while timeout and poll triggers raced"
  stop_server
  pass "a caller arriving mid-snapshot gets the completed result and the next poll waits a full interval"
}

# A stale service unit must be diagnosed before the snapshot command turns its
# missing scratch grant into an opaque mktemp failure. INVOCATION_ID plus a
# matching SYSTEMD_EXEC_PID is the newer-systemd boundary, with exact cgroup
# membership covering older versions that do not provide that variable.
test_stale_service_unit_is_actionable() {
  local case_root classified
  classified=$(printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/firstmate-dashboard.service\n' \
    | node "$SERVER" --check-service-unit-cgroup)
  [ "$classified" = service ] || fail "a unified cgroup did not identify the installed dashboard service"
  classified=$(printf '5:name=systemd:/user.slice/user-1000.slice/user@1000.service/firstmate-dashboard.service\n' \
    | node "$SERVER" --check-service-unit-cgroup)
  [ "$classified" = service ] || fail "a legacy cgroup did not identify the installed dashboard service"
  classified=$(printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/not-firstmate-dashboard.service\n' \
    | node "$SERVER" --check-service-unit-cgroup)
  [ "$classified" = other ] || fail "a different unit was misidentified as the installed dashboard service"

  case_root=$(make_runtime inherited-systemd-context)
  TEST_PORT=$(free_port)
  INVOCATION_ID=fixture-parent-invocation \
    FM_HOME="$case_root/home" \
    FM_DASHBOARD_PORT="$TEST_PORT" \
    FM_DASHBOARD_TIMEOUT_SECONDS=1 \
    FM_DASHBOARD_POLL_SECONDS=1 \
    DASH_TEST_CONTROL="$case_root/control" \
    node "$case_root/runtime/bin/fm-dashboard-server.mjs" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_expression "$case_root" '.status.phase == "ready"'
  stop_server

  case_root=$(make_runtime stale-unit)
  TEST_PORT=$(free_port)
  INVOCATION_ID=fixture-invocation \
    FM_HOME="$case_root/home" \
    FM_DASHBOARD_PORT="$TEST_PORT" \
    FM_DASHBOARD_TIMEOUT_SECONDS=1 \
    FM_DASHBOARD_POLL_SECONDS=1 \
    DASH_TEST_CONTROL="$case_root/control" \
    sh -c 'SYSTEMD_EXEC_PID=$$; export SYSTEMD_EXEC_PID; exec node "$1"' sh \
      "$case_root/runtime/bin/fm-dashboard-server.mjs" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_expression "$case_root" '.status.phase == "unavailable" and .status.error.kind == "service_unit_outdated" and (.status.error.message | contains("rerun bin/fm-dashboard-install.sh"))'
  [ ! -e "$case_root/control/executions" ] || fail "the stale unit still launched a snapshot instead of reporting its repair"
  stop_server
  pass "old and new systemd identify a stale installed unit without misclassifying inherited context"
}

test_first_run_failures_are_explicit() {
  local case_root backlog
  case_root=$(make_runtime malformed)
  printf 'malformed\n' > "$case_root/control/mode"
  start_fixture_server "$case_root" 1 1
  wait_for_expression "$case_root" '.status.phase == "unavailable" and .status.error.kind == "malformed_json" and .snapshot == null'
  backlog=$(curl -fsS "http://127.0.0.1:$TEST_PORT/api/backlog")
  printf '%s' "$backlog" | jq -e '.status.phase == "unavailable" and .backlog == null' >/dev/null \
    || fail "a failed snapshot fabricated an empty backlog: $backlog"
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
  # Ingesting agent events is the one write this process performs, and it must
  # land in the dashboard's own store outside the home rather than anywhere the
  # fleet owns. Accepting a real event inside the fingerprinted window is what
  # makes that a proof rather than a claim about an idle server.
  curl -fsS -o /dev/null -X POST "http://127.0.0.1:$TEST_PORT/events" \
    -H "Authorization: Bearer $EVENT_TOKEN" \
    -H "X-Firstmate-Source: fingerprint-task/claude" \
    -H "Content-Type: application/json" \
    -d "{\"schema\":\"fm-agent-event.v1\",\"events\":[{\"event_id\":\"fp1\",\"task_id\":\"fingerprint-task\",\"harness\":\"claude\",\"type\":\"turn_ended\",\"occurred_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}" \
    || fail "dashboard refused an authenticated event during the read-only proof"
  sleep 0.3
  after=$(fleet_fingerprint "$case_root/home")
  stop_server
  [ "$after" = "$before" ] || fail "dashboard changed data, state, or projects while reading the real snapshot contract"
  [ -s "$case_root/events.db" ] || fail "the accepted event did not reach the dashboard's own store"
  case "$case_root/events.db" in
    "$case_root/home"/*) fail "the agent-event store was placed inside the operational home" ;;
  esac
  pass "filesystem fingerprinting proves zero dashboard writes across fleet-owned directories while events are accepted"
}

test_installer_writes_hardened_user_service() {
  local case_root unit env_file out pinned_db granted
  case_root="$TMP_ROOT/install"
  mkdir -p "$case_root/config" "$case_root/home"
  # The store is overridden and the instrumentation config is left to be derived,
  # so both halves of the pinning are exercised: the one the installer was told
  # and the one it had to work out for itself. tests/lib.sh exports a neutral
  # FM_DASHBOARD_EVENTS_CONFIG for every suite, which is dropped here for exactly
  # that reason.
  out=$(env -u FM_DASHBOARD_EVENTS_CONFIG \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
    FM_DASHBOARD_EVENT_DB="$case_root/store/events.db" "$INSTALLER" \
    --allow-worktree \
    --fm-home "$case_root/fleet" --port 18878 --poll 3 --timeout 4 --stale 9 --no-start)
  unit="$case_root/config/systemd/user/firstmate-dashboard.service"
  env_file="$case_root/config/firstmate/dashboard.env"
  [ -f "$unit" ] && [ -f "$env_file" ] || fail "installer did not create the user service and environment"
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_ADDRESS="127.0.0.1"' "installer lost the loopback default"
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_POLL_SECONDS="3"' "installer lost the poll interval"
  assert_contains "$(cat "$unit")" 'ProtectHome=read-only' "service does not enforce a read-only home mount"
  assert_contains "$(cat "$unit")" 'Restart=always' "service does not recover after a clean process exit"
  assert_contains "$(cat "$unit")" 'Environment=FM_DASHBOARD_UNIT_CONTRACT=runtime-scratch-v1' \
    "service does not carry the startup contract used to detect an outdated unit"
  assert_contains "$(cat "$unit")" 'WantedBy=default.target' "service is not boot-persistent"
  assert_contains "$out" "Service not started (--no-start)." "installer did not honor its no-start boundary"

  # The unit's one writable path and the store the service will actually open
  # must be the same directory. The service does not inherit this shell's
  # environment - systemd's user manager imports neither FM_DASHBOARD_EVENT_DB
  # nor XDG_STATE_HOME - so a path left to be re-derived at runtime lands
  # outside the grant, under ProtectHome=read-only, and every event is refused
  # for the life of the process.
  pinned_db=$(sed -n 's/^FM_DASHBOARD_EVENT_DB="\(.*\)"$/\1/p' "$env_file")
  granted=$(sed -n 's/^ReadWritePaths=-//p' "$unit")
  [ "$pinned_db" = "$case_root/store/events.db" ] \
    || fail "the installer did not pin the resolved event store into the environment: [$pinned_db]"
  printf '%s\n' "$granted" | grep -qxF "${pinned_db%/*}" \
    || fail "the unit grants [$granted] while the service would open a store in [${pinned_db%/*}]"
  assert_contains "$(cat "$env_file")" \
    "FM_DASHBOARD_EVENTS_CONFIG=\"$case_root/config/firstmate/dashboard-events.json\"" \
    "the installer did not pin the shared instrumentation configuration"
  pass "installer configures a hardened boot-persistent user service without sudo"
}

# The hardened unit pairs ProtectSystem=strict with ProtectHome=read-only.
# Together they leave no writable scratch path - /tmp, /var/tmp, /usr/tmp, and
# $HOME are all read-only - and three panels have now been broken by it: token
# usage exited "disk I/O error", semantic search could not mktemp, and durable
# history silently returned zero of sixty-one records because bash could not
# write the temp file a here-string larger than a pipe buffer needs.
#
# The unit therefore grants scratch once, and this case pins the SHAPE of that
# grant, because the obvious shape is the wrong one. PrivateTmp=yes also clears
# the failure, and it is refused here: it substitutes a private tmpfs for the
# shared /tmp, and the fleet's tmux server socket lives at /tmp/tmux-$UID. The
# snapshot this service runs probes endpoints through that socket, so a private
# /tmp would trade these panels for every live task reading as "endpoint
# absent" - the same false-absence defect, moved to the primary view.
# RuntimeDirectory= adds a writable directory without replacing /tmp, so both
# halves hold at once, and the TMPDIR pointing at it is what makes the grant
# reach a caller that just runs mktemp.
#
# The reader half is pinned in the same case deliberately: SQLite temp storage
# stays in memory whether or not this unit grants anything, because a reader
# that never asks the filesystem for scratch cannot be denied it, including
# outside this unit. Each half is what keeps the other from becoming
# load-bearing, so a future pass that drops one is told what it just changed.
# docs/verification/dashboard-service-unit.md records the reproductions.
test_installer_preserves_exposure_configuration() {
  local case_root env_file password
  case_root="$TMP_ROOT/install-preserve"
  mkdir -p "$case_root/config" "$case_root/home"
  password='fixture-password-strong'
  printf '%s\n' "$password" | env -u FM_DASHBOARD_ADDRESS -u FM_DASHBOARD_TRUSTED_PROXIES \
    -u FM_DASHBOARD_AUTH_FILE -u FM_HOME \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" "$INSTALLER" \
    --allow-worktree --fm-home "$case_root/fleet" --set-password \
    --address 192.0.2.10 --trusted-proxy 192.0.2.20 --no-start >/dev/null
  env_file="$case_root/config/firstmate/dashboard.env"

  env -u FM_DASHBOARD_ADDRESS -u FM_DASHBOARD_TRUSTED_PROXIES \
    -u FM_DASHBOARD_AUTH_FILE -u FM_HOME \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" "$INSTALLER" \
    --allow-worktree --no-start >/dev/null
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_ADDRESS="192.0.2.10"' \
    "a repair with no flags reset the installed bind address"
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_TRUSTED_PROXIES="192.0.2.20"' \
    "a repair with no flags cleared the installed trusted proxy"

  env -u FM_DASHBOARD_ADDRESS -u FM_DASHBOARD_TRUSTED_PROXIES \
    -u FM_DASHBOARD_AUTH_FILE -u FM_HOME \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" "$INSTALLER" \
    --allow-worktree --address 192.0.2.11 --trusted-proxy 192.0.2.21 --no-start >/dev/null
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_ADDRESS="192.0.2.11"' \
    "an explicit address did not replace the installed bind"
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_TRUSTED_PROXIES="192.0.2.21"' \
    "the first explicit trusted proxy did not replace the installed list"
  assert_not_contains "$(cat "$env_file")" '192.0.2.20,192.0.2.21' \
    "an explicit trusted proxy appended to stale installed configuration"
  pass "repair preserves installed exposure settings and explicit flags replace them"
}

test_unit_grants_scratch_without_hiding_tmp_and_opener_keeps_temps_in_memory() {
  local case_root unit out directives directives_file probe runtime_dir
  case_root="$TMP_ROOT/install-sqlite-scratch"
  mkdir -p "$case_root/config" "$case_root/home"
  out=$(env -u FM_DASHBOARD_EVENTS_CONFIG \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
    FM_DASHBOARD_EVENT_DB="$case_root/store/events.db" "$INSTALLER" \
    --allow-worktree \
    --fm-home "$case_root/fleet" --port 18879 --poll 3 --timeout 4 --stale 9 --no-start)
  unit="$case_root/config/systemd/user/firstmate-dashboard.service"
  [ -f "$unit" ] || fail "installer did not create the user service: $out"
  # Assertions run against the directives alone, so a comment that merely names
  # a property cannot answer for the property itself.
  directives_file="$case_root/directives"
  grep -v '^[[:space:]]*#' "$unit" > "$directives_file"
  directives=$(cat "$directives_file")
  assert_contains "$directives" 'ProtectSystem=strict' "unit lost ProtectSystem=strict"
  assert_contains "$directives" 'ProtectHome=read-only' "unit lost ProtectHome=read-only"
  assert_not_contains "$directives" 'PrivateTmp=yes' \
    "unit hides the shared /tmp, which is where the fleet's tmux server socket lives"

  # The grant and the TMPDIR are asserted together and against the same name: a
  # RuntimeDirectory nothing points TMPDIR at is a writable directory no caller
  # finds, which is indistinguishable from having no grant at all.
  runtime_dir=$(sed -n 's/^RuntimeDirectory=//p' "$directives_file")
  [ -n "$runtime_dir" ] \
    || fail "unit grants no scratch directory, so every panel that needs a temp file fails under its own hardening"
  case "$runtime_dir" in
    /*) fail "RuntimeDirectory must be relative to the manager's runtime root; systemd refuses [$runtime_dir]" ;;
  esac
  assert_contains "$directives" "Environment=TMPDIR=%t/$runtime_dir" \
    "unit grants a scratch directory but points TMPDIR somewhere else, so mktemp still lands on the read-only hierarchy"
  # systemd creates a RuntimeDirectory 0755 unless told otherwise, which is a
  # wider posture than the UMask=0077 two lines below states for everything the
  # service writes into it. Stated here so the scratch space does not depend on
  # the runtime root's own permissions to be private.
  assert_contains "$directives" 'RuntimeDirectoryMode=0700' \
    "unit leaves the scratch directory on systemd's 0755 default while the service writes into it under UMask=0077"

  # The reader half, asserted where it actually takes effect rather than by
  # reading the source: a readOnly open must report temp_store 2 (MEMORY), and a
  # writable open must be left on the default, because a writer's temp storage
  # can be large and it always has a writable data/ to spend it in.
  probe=$(node --input-type=module -e '
    const { pathToFileURL } = await import("node:url");
    const { openStore, closeStore } = await import(pathToFileURL(process.argv[1]).href);
    const migrations = [{ version: 1, statements: ["CREATE TABLE t (x INTEGER)"] }];
    const dbPath = process.argv[2];
    const writer = openStore(dbPath, migrations);
    process.stdout.write("writer=" + writer.prepare("PRAGMA temp_store").get().temp_store + "\n");
    closeStore(writer);
    const reader = openStore(dbPath, migrations, { create: false, readOnly: true });
    process.stdout.write("reader=" + reader.prepare("PRAGMA temp_store").get().temp_store + "\n");
  ' "$ROOT/bin/fm-telemetry-store.mjs" "$case_root/probe.db" 2>/dev/null) \
    || fail "the shared store opener could not be probed for its temp-store setting"
  assert_contains "$probe" 'reader=2' \
    "the readOnly open does not keep SQLite temp storage in memory, so a sandbox with no writable scratch path fails the read"
  assert_contains "$probe" 'writer=0' \
    "the writable open no longer leaves temp storage on the SQLite default"
  pass "the unit grants scratch without hiding the shared /tmp and the read-only opener keeps SQLite temps in memory"
}

wait_for_history() {  # <case-root> <jq-expression>
  local case_root=$1 expression=$2
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    curl -fsS "http://127.0.0.1:$TEST_PORT/api/history" > "$case_root/history.json" || true
    if jq -e "$expression" "$case_root/history.json" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  fail "dashboard history condition did not arrive ($expression): $(cat "$case_root/history.json" 2>/dev/null)"
}

# A completed task, recorded exactly the way a real one is: metadata, brief,
# terminal status event, backlog row, and a retained report, published through
# the real completion-manifest writer.
seed_completed_task() {  # <home> <id> <kind> <title> [pr-url]
  local home=$1 id=$2 kind=$3 title=$4 pr=${5:-}
  mkdir -p "$home/state" "$home/data/$id"
  {
    printf 'window=%s\n' "fm:$id"
    printf 'kind=%s\n' "$kind"
    printf 'project=firstmate\n'
    printf 'harness=codex\n'
    printf 'model=gpt-5.6-terra\n'
    printf 'effort=medium\n'
    printf 'mode=no-mistakes\n'
    printf 'yolo=off\n'
    printf 'backend=tmux\n'
    [ -n "$pr" ] && printf 'pr=%s\n' "$pr"
  } > "$home/state/$id.meta"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf 'working: started\ndone: finished the work\n' > "$home/state/$id.status"
  printf -- '- [x] %s - %s (since 2026-08-01)\n' "$id" "$title" >> "$home/data/backlog.md"
  FM_HOME="$home" "$ROOT/bin/fm-outcome-manifest.sh" write "$id" >/dev/null \
    || fail "could not publish the completion record for $id"
}

# Exactly what cleanup and backlog pruning leave behind: the durable completion
# record and the retained report, and nothing else.
retire_completed_task() {  # <home> <id>
  local home=$1 id=$2
  rm -f "$home/state/$id.meta" "$home/state/$id.status"
  grep -v -- "- \[x\] $id - " "$home/data/backlog.md" > "$home/data/backlog.md.next" || true
  mv "$home/data/backlog.md.next" "$home/data/backlog.md"
}

test_history_survives_teardown_and_backlog_pruning() {
  local case_root home report
  case_root="$TMP_ROOT/history-durable"
  home="$case_root/home"
  mkdir -p "$home/data" "$home/state" "$home/projects"

  seed_completed_task "$home" "old-scout" scout "Investigate the slow merge poll"
  report="$home/data/old-scout/report.md"
  cat > "$report" <<'MD'
# Findings

The **root cause** is a stale cache, see [issue 16](https://github.com/o/r/issues/16).

<script>alert(1)</script>

[bad](javascript:alert(1))
MD
  # Republish so the manifest records the retained report.
  FM_HOME="$home" "$ROOT/bin/fm-outcome-manifest.sh" write "old-scout" >/dev/null \
    || fail "could not republish the completion record with its report"
  seed_completed_task "$home" "old-ship" ship "Land the merge poll fix" "https://github.com/o/r/pull/42"

  # Cleanup removed the volatile records and the recent-work list has pruned
  # both rows away. Only the durable completion records remain.
  retire_completed_task "$home" "old-scout"
  retire_completed_task "$home" "old-ship"
  [ -f "$home/state/old-scout.meta" ] && fail "the test did not actually remove the volatile task record"
  grep -q "old-scout" "$home/data/backlog.md" && fail "the test did not actually prune the recent-work list"

  start_real_server "$case_root"
  wait_for_history "$case_root" '.status.phase == "ready" and (.history.records | length) == 2'

  jq -e '[.history.records[] | select(.task_id == "old-scout")] | length == 1' "$case_root/history.json" >/dev/null \
    || fail "a completed investigation stopped being browsable after cleanup and pruning"
  jq -e '.history.records[] | select(.task_id == "old-scout")
         | .title == "Investigate the slow merge poll" and .kind == "scout"
           and .harness == "codex" and .model == "gpt-5.6-terra" and .effort == "medium"
           and .report.present == true' "$case_root/history.json" >/dev/null \
    || fail "the retained investigation lost its title, dispatch metadata, or report pointer"
  jq -e '.history.records[] | select(.task_id == "old-ship")
         | .pr.url == "https://github.com/o/r/pull/42" and .outcome.state == "done"' "$case_root/history.json" >/dev/null \
    || fail "a done task lost its complete pull request URL or its outcome"
  jq -e '.usage.available == false and (.usage.reason | length) > 0' "$case_root/history.json" >/dev/null \
    || fail "absent token usage did not render as an explained unavailable"

  curl -fsS "http://127.0.0.1:$TEST_PORT/api/report?task=old-scout" > "$case_root/report.json" \
    || fail "the retained report could not be read after cleanup"
  jq -e '.present == true and (.text | contains("root cause")) and .truncated == false' "$case_root/report.json" >/dev/null \
    || fail "the retained report was not served intact"
  # The server hands the browser raw Markdown; nothing is interpreted here.
  jq -e '.text | contains("<script>alert(1)</script>")' "$case_root/report.json" >/dev/null \
    || fail "the report body was altered in transit instead of being rendered safely in the browser"
  stop_server
  pass "completed work stays browsable after cleanup and recent-work pruning, with its report intact"
}

test_report_reads_cannot_select_a_path() {
  local case_root home status
  case_root="$TMP_ROOT/history-paths"
  home="$case_root/home"
  mkdir -p "$home/data" "$home/state" "$home/projects" "$home/secret"
  printf 'top secret\n' > "$home/secret/report.md"
  seed_completed_task "$home" "with-report" scout "Has a report"
  printf 'a real report\n' > "$home/data/with-report/report.md"
  FM_HOME="$home" "$ROOT/bin/fm-outcome-manifest.sh" write "with-report" >/dev/null
  seed_completed_task "$home" "no-report" ship "Has no report"
  retire_completed_task "$home" "with-report"
  retire_completed_task "$home" "no-report"

  # A task whose completion record claims a report, whose file is a symlink out
  # of the data directory. The link must not be followed.
  seed_completed_task "$home" "linked" scout "Points elsewhere"
  printf 'placeholder\n' > "$home/data/linked/report.md"
  FM_HOME="$home" "$ROOT/bin/fm-outcome-manifest.sh" write "linked" >/dev/null
  rm -f "$home/data/linked/report.md"
  ln -s "$home/secret/report.md" "$home/data/linked/report.md"
  retire_completed_task "$home" "linked"

  start_real_server "$case_root"
  wait_for_history "$case_root" '(.history.records | length) == 3'

  for probe in "../../etc/passwd" "..%2f..%2fetc%2fpasswd" "with-report/../../secret" ".ssh" "with report" ""; do
    status=$(curl -s -o "$case_root/probe.json" -w '%{http_code}' \
      "http://127.0.0.1:$TEST_PORT/api/report?task=$(printf '%s' "$probe" | jq -sRr @uri)")
    [ "$status" = "400" ] || [ "$status" = "404" ] \
      || fail "a report read for '$probe' answered $status instead of refusing"
    jq -e '.present == false' "$case_root/probe.json" >/dev/null \
      || fail "a refused report read for '$probe' did not say so"
    grep -q "top secret" "$case_root/probe.json" && fail "a report read for '$probe' returned content outside the data directory"
  done

  status=$(curl -s -o "$case_root/unknown.json" -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/report?task=never-existed")
  [ "$status" = "404" ] || fail "an unrecorded task answered $status instead of 404"
  jq -e '.reason == "unknown_task"' "$case_root/unknown.json" >/dev/null || fail "an unrecorded task did not name its reason"

  status=$(curl -s -o "$case_root/none.json" -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/report?task=no-report")
  [ "$status" = "404" ] || fail "a task with no retained report answered $status instead of 404"
  jq -e '.reason == "no_retained_report"' "$case_root/none.json" >/dev/null || fail "a task with no report did not name its reason"

  status=$(curl -s -o "$case_root/linked.json" -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/report?task=linked")
  [ "$status" = "404" ] || fail "a symlinked report answered $status instead of refusing"
  grep -q "top secret" "$case_root/linked.json" && fail "a symlinked report leaked content from outside the data directory"
  jq -e '.reason == "report_missing"' "$case_root/linked.json" >/dev/null || fail "a symlinked report did not explain itself"

  curl -fsS "http://127.0.0.1:$TEST_PORT/api/report?task=with-report" > "$case_root/ok.json" \
    || fail "a legitimate report read failed"
  jq -e '.present == true and (.text | contains("a real report"))' "$case_root/ok.json" >/dev/null \
    || fail "a legitimate report was not served"
  stop_server
  pass "report reads select only among recorded tasks and never follow a path out of the data directory"
}

test_a_huge_report_is_bounded_and_says_so() {
  local case_root home
  case_root="$TMP_ROOT/history-huge"
  home="$case_root/home"
  mkdir -p "$home/data" "$home/state" "$home/projects"
  seed_completed_task "$home" "huge" scout "Very long report"
  node -e 'process.stdout.write("x".repeat(300000))' > "$home/data/huge/report.md"
  FM_HOME="$home" "$ROOT/bin/fm-outcome-manifest.sh" write "huge" >/dev/null
  retire_completed_task "$home" "huge"

  TEST_PORT=$(free_port)
  FM_HOME="$home" FM_DASHBOARD_PORT="$TEST_PORT" FM_DASHBOARD_TIMEOUT_SECONDS=6 \
    FM_DASHBOARD_POLL_SECONDS=1 FM_DASHBOARD_REPORT_MAX_BYTES=4096 \
    node "$SERVER" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_history "$case_root" '(.history.records | length) == 1'

  curl -fsS "http://127.0.0.1:$TEST_PORT/api/report?task=huge" > "$case_root/report.json" || fail "the oversized report was not served"
  jq -e '.truncated == true and (.text | length) == 4096 and .bytes == 300000 and .max_bytes == 4096' "$case_root/report.json" >/dev/null \
    || fail "an oversized report was not bounded, or did not disclose that it was cut short"
  stop_server
  pass "an oversized report is bounded to the configured limit and discloses the truncation"
}

test_usage_totals_are_presence_gated() {
  local case_root runtime home
  case_root="$TMP_ROOT/history-usage"
  runtime="$case_root/runtime"
  home="$case_root/home"
  mkdir -p "$runtime/bin" "$runtime/assets/dashboard" "$home/data" "$home/state" "$home/projects"
  cp "$SERVER" "$runtime/bin/fm-dashboard-server.mjs"
  # The server imports its event store, which imports the shared telemetry
  # store discipline. A fixture runtime that copied only the server would fail
  # to start for a reason unrelated to the case under test.
  cp "$ROOT/bin/fm-event-store.mjs" "$ROOT/bin/fm-telemetry-store.mjs" "$runtime/bin/"
  cp "$ROOT/assets/dashboard/"* "$runtime/assets/dashboard/"
  cat > "$runtime/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-fleet-snapshot.v1","tasks":[],"card_precedence":[]}\n'
SH
  cat > "$runtime/bin/fm-outcome-manifest.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-outcome-history.v1","records":[{"schema":"fm-outcome-manifest.v1","task_id":"paid","report":{"path":null,"present":false}}],"total":1,"shown":1,"truncated":false,"malformed":[]}\n'
SH
  chmod +x "$runtime/bin/fm-fleet-snapshot.sh" "$runtime/bin/fm-outcome-manifest.sh"

  # No collector installed at all: unavailable with a reason, never a zero.
  TEST_PORT=$(free_port)
  FM_HOME="$home" FM_DASHBOARD_PORT="$TEST_PORT" FM_DASHBOARD_POLL_SECONDS=1 \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$case_root/absent.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_history "$case_root" '.status.phase == "ready"'
  jq -e '.usage.available == false and .usage.collection == "absent" and (.usage.reason | test("not collected")) and (.usage.tasks | length) == 0' "$case_root/history.json" >/dev/null \
    || fail "an absent usage collector did not render as an explained unavailable"
  stop_server

  # A collector that reports totals: the totals are carried through.
  node "$ROOT/bin/fm-usage.mjs" migrate --home "$home" >/dev/null \
    || fail "the present usage case could not create a store"
  cat > "$runtime/bin/fm-usage.mjs" <<'SH'
#!/usr/bin/env node
process.stdout.write(JSON.stringify({
  schema: "fm-usage-report.v1",
  by: "task",
  rows: [
    { key: "paid", events: 4, sessions: 1, input_tokens: 10, output_tokens: 5, total_tokens: 15, cost: { estimated: 0.25, currency: "USD", unpriced_events: 0 } },
    { key: "../escape", total_tokens: 99 },
  ],
}) + "\n");
SH
  chmod +x "$runtime/bin/fm-usage.mjs"
  TEST_PORT=$(free_port)
  FM_HOME="$home" FM_DASHBOARD_PORT="$TEST_PORT" FM_DASHBOARD_POLL_SECONDS=1 \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$case_root/present.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_history "$case_root" '.usage.available == true'
  jq -e '.usage.collection == "ready" and .usage.tasks.paid.total_tokens == 15 and .usage.tasks.paid.cost.estimated == 0.25' "$case_root/history.json" >/dev/null \
    || fail "attributed usage totals were not carried into the history document"
  jq -e '.usage.tasks | has("../escape") | not' "$case_root/history.json" >/dev/null \
    || fail "a usage row with an unsafe task name was accepted"
  stop_server

  # An output this dashboard does not recognize is unavailable, never guessed at.
  printf '#!/usr/bin/env node\nprocess.stdout.write(JSON.stringify({schema:"fm-usage-report.v99",rows:[]}))\n' > "$runtime/bin/fm-usage.mjs"
  TEST_PORT=$(free_port)
  FM_HOME="$home" FM_DASHBOARD_PORT="$TEST_PORT" FM_DASHBOARD_POLL_SECONDS=1 \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$case_root/unknown.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_history "$case_root" '.usage.available == false and .usage.collection == "operational" and (.usage.reason | test("supported schema"))'
  jq -e '.usage.available == false and .usage.collection == "operational" and (.usage.reason | test("supported schema"))' "$case_root/history.json" >/dev/null \
    || fail "an unrecognized usage report was not refused as unavailable"

  # A usage read that failed never takes history with it.
  jq -e '(.history.records | length) == 1' "$case_root/history.json" >/dev/null \
    || fail "history stopped working when the usage read did"
  stop_server

  # And a dashboard told not to read usage at all is `disabled`, not a collector
  # that failed: the off switch is answered before the collector is consulted,
  # so nothing here can be mistaken for something to fix. The v99 collector left
  # in place above is what makes that ordering visible rather than assumed.
  TEST_PORT=$(free_port)
  FM_HOME="$home" FM_DASHBOARD_PORT="$TEST_PORT" FM_DASHBOARD_POLL_SECONDS=1 \
    FM_DASHBOARD_USAGE=off \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$case_root/off.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_history "$case_root" '.usage.collection == "disabled"'
  jq -e '.usage.available == false and (.usage.reason | test("disabled")) and (.usage.tasks | length) == 0 and (.history.records | length) == 1' \
    "$case_root/history.json" >/dev/null \
    || fail "a dashboard told not to read usage did not render as explicitly disabled"
  stop_server
  pass "token usage is presence-gated and renders as unavailable rather than zero"
}

# A usage read can fail operationally two ways, and both are transients rather
# than facts about this home. The store has writers - teardown refreshes it on
# every archive, bootstrap on every locked session start - and each holds it in
# WAL for the length of its window, so a writer that exits without closing
# leaves behind a store whose wal-index the service cannot build without write
# access to data/. Separately, a sandbox that leaves SQLite no writable scratch
# path fails the read with "disk I/O error" against a healthy store - which is
# why bin/fm-telemetry-store.mjs pins PRAGMA temp_store = MEMORY on its readOnly
# open, so that half can no longer arise from any sandbox at all. Dropping
# every card's real totals for the length of either would report a transient as
# an operator action item, at the moment a captain is most likely to be looking.
# The last good read is retained and labelled instead, the way a failed snapshot
# refresh keeps its last good snapshot.
test_a_failed_usage_read_keeps_the_last_good_one() {
  local case_root runtime home
  case_root="$TMP_ROOT/history-usage-stale"
  runtime="$case_root/runtime"
  home="$case_root/home"
  mkdir -p "$runtime/bin" "$runtime/assets/dashboard" "$home/data" "$home/state" "$home/projects"
  cp "$SERVER" "$runtime/bin/fm-dashboard-server.mjs"
  cp "$ROOT/bin/fm-event-store.mjs" "$ROOT/bin/fm-telemetry-store.mjs" "$runtime/bin/"
  cp "$ROOT/assets/dashboard/"* "$runtime/assets/dashboard/"
  cat > "$runtime/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-fleet-snapshot.v1","tasks":[],"card_precedence":[]}\n'
SH
  cat > "$runtime/bin/fm-outcome-manifest.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-outcome-history.v1","records":[{"schema":"fm-outcome-manifest.v1","task_id":"paid","report":{"path":null,"present":false}}],"total":1,"shown":1,"truncated":false,"malformed":[]}\n'
SH
  chmod +x "$runtime/bin/fm-fleet-snapshot.sh" "$runtime/bin/fm-outcome-manifest.sh"
  node "$ROOT/bin/fm-usage.mjs" migrate --home "$home" >/dev/null \
    || fail "the retained usage case could not create a store"
  # A collector that answers once and then fails every later read, which is the
  # shape a writer holding the store in WAL produces. The marker file is what
  # makes the first read the good one without depending on timing.
  cat > "$runtime/bin/fm-usage.mjs" <<SH
#!/usr/bin/env node
import fs from "node:fs";
const marker = "$case_root/read-once";
if (fs.existsSync(marker)) {
  process.stderr.write("database is locked\n");
  process.exit(1);
}
fs.writeFileSync(marker, "");
process.stdout.write(JSON.stringify({
  schema: "fm-usage-report.v1",
  by: "task",
  rows: [{ key: "paid", events: 4, sessions: 1, input_tokens: 10, output_tokens: 5, total_tokens: 15 }],
}) + "\n");
SH
  chmod +x "$runtime/bin/fm-usage.mjs"
  TEST_PORT=$(free_port)
  FM_HOME="$home" FM_DASHBOARD_PORT="$TEST_PORT" FM_DASHBOARD_POLL_SECONDS=1 \
    FM_DASHBOARD_HISTORY_POLL_SECONDS=1 \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_history "$case_root" '.usage.available == true'
  jq -e '.usage.stale == false and .usage.tasks.paid.total_tokens == 15' "$case_root/history.json" >/dev/null \
    || fail "the first usage read was not carried through as a fresh one"
  wait_for_history "$case_root" '.usage.stale == true'
  jq -e '.usage.available == true and .usage.collection == "ready" and .usage.tasks.paid.total_tokens == 15 and (.usage.reason | test("could not be read"))' \
    "$case_root/history.json" >/dev/null \
    || fail "a failed usage read dropped the totals it should have retained"
  stop_server
  pass "a usage read that failed keeps the last good totals and says the newest read did not land"
}

test_usage_without_store_file_is_absent_not_operational() {
  local case_root runtime home
  case_root="$TMP_ROOT/history-usage-absent-store"
  runtime="$case_root/runtime"
  home="$case_root/home"
  mkdir -p "$runtime/bin" "$runtime/assets/dashboard" "$home/data" "$home/state" "$home/projects"
  cp "$SERVER" "$runtime/bin/fm-dashboard-server.mjs"
  cp "$ROOT/bin/fm-event-store.mjs" "$ROOT/bin/fm-telemetry-store.mjs" "$runtime/bin/"
  cp "$ROOT/assets/dashboard/"* "$runtime/assets/dashboard/"
  cat > "$runtime/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-fleet-snapshot.v1","tasks":[],"card_precedence":[]}\n'
SH
  cat > "$runtime/bin/fm-outcome-manifest.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-outcome-history.v1","records":[],"total":0,"shown":0,"truncated":false,"malformed":[]}\n'
SH
  cat > "$runtime/bin/fm-usage.mjs" <<'SH'
#!/usr/bin/env node
process.stderr.write("should not run\n");
process.exit(1);
SH
  chmod +x "$runtime/bin/"*.sh "$runtime/bin/fm-usage.mjs"
  TEST_PORT=$(free_port)
  FM_HOME="$home" FM_DASHBOARD_PORT="$TEST_PORT" FM_DASHBOARD_POLL_SECONDS=1 \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_history "$case_root" '.usage.available == false and .usage.collection == "absent" and (.usage.reason | test("not collected"))'
  jq -e '.usage.available == false and (.usage.reason | test("not collected"))' "$case_root/history.json" >/dev/null \
    || fail "a missing store did not classify usage as absent"
  stop_server
  pass "a home without a usage store is absent rather than operational"
}

test_usage_reads_a_read_only_store_through_node() {
  local case_root runtime home claude_root
  case_root="$TMP_ROOT/history-usage-ro"
  runtime="$case_root/runtime"
  home="$case_root/home"
  claude_root="$case_root/claude"
  mkdir -p "$runtime/bin" "$runtime/assets/dashboard" "$home/data" "$home/state" "$home/projects" "$claude_root/-slot" "$case_root/codex"
  cp "$SERVER" "$runtime/bin/fm-dashboard-server.mjs"
  cp "$ROOT/bin/fm-event-store.mjs" "$ROOT/bin/fm-telemetry-store.mjs" "$ROOT/bin/fm-usage.mjs" "$runtime/bin/"
  cp "$ROOT/assets/dashboard/"* "$runtime/assets/dashboard/"
  cat > "$runtime/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-fleet-snapshot.v1","tasks":[],"card_precedence":[]}\n'
SH
  cat > "$runtime/bin/fm-outcome-manifest.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-outcome-history.v1","records":[{"schema":"fm-outcome-manifest.v1","task_id":"paid","report":{"path":null,"present":false}}],"total":1,"shown":1,"truncated":false,"malformed":[]}\n'
SH
  chmod +x "$runtime/bin/fm-fleet-snapshot.sh" "$runtime/bin/fm-outcome-manifest.sh"
  printf '%s\n' '{"type":"assistant","sessionId":"session-ro","cwd":"'"$home"'/wt","timestamp":"2026-08-01T10:00:00Z","message":{"id":"msg_ro","model":"claude-opus-5","usage":{"input_tokens":4,"output_tokens":6,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
    > "$claude_root/-slot/session.jsonl"
  FM_USAGE_CLAUDE_ROOT="$claude_root" FM_USAGE_CODEX_ROOT="$case_root/codex" \
    node "$runtime/bin/fm-usage.mjs" ingest --home "$home" >/dev/null \
    || fail "the read-only usage case could not build a store"
  # Hardened before anything reads it, and with no sidecars in place: a read
  # taken while data/ was still writable would leave usage.db-wal and
  # usage.db-shm behind, and the service's read-only open would then succeed on
  # a wal-index the ProtectHome=read-only home has no way to create.
  if [ -e "$home/data/usage.db-wal" ] || [ -e "$home/data/usage.db-shm" ]; then
    fail "the read-only usage case started from a WAL store the service could not open"
  fi
  chmod -R a-w "$home/data"
  TEST_PORT=$(free_port)
  FM_HOME="$home" FM_DASHBOARD_PORT="$TEST_PORT" FM_DASHBOARD_POLL_SECONDS=1 \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_history "$case_root" '.usage.available == true'
  jq -e '.usage.collection == "ready"' "$case_root/history.json" >/dev/null \
    || fail "a read-only store did not classify usage as ready"
  chmod -R u+w "$home/data" 2>/dev/null || true
  stop_server
  pass "the dashboard reads token usage through node against a read-only data directory"
}

test_history_streams_and_isolates_bad_records() {
  local case_root runtime home sse_log
  case_root="$TMP_ROOT/history-stream"
  runtime="$case_root/runtime"
  home="$case_root/home"
  mkdir -p "$runtime/bin" "$runtime/assets/dashboard" "$home/data" "$home/state" "$home/projects" "$case_root/control"
  cp "$SERVER" "$runtime/bin/fm-dashboard-server.mjs"
  # The server imports its event store, which imports the shared telemetry
  # store discipline. A fixture runtime that copied only the server would fail
  # to start for a reason unrelated to the case under test.
  cp "$ROOT/bin/fm-event-store.mjs" "$ROOT/bin/fm-telemetry-store.mjs" "$runtime/bin/"
  cp "$ROOT/assets/dashboard/"* "$runtime/assets/dashboard/"
  cat > "$runtime/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-fleet-snapshot.v1","tasks":[],"card_precedence":[]}\n'
SH
  cat > "$runtime/bin/fm-outcome-manifest.sh" <<'SH'
#!/usr/bin/env bash
cat "${DASH_TEST_CONTROL:?}/history.json"
SH
  chmod +x "$runtime/bin/fm-fleet-snapshot.sh" "$runtime/bin/fm-outcome-manifest.sh"
  printf '{"schema":"fm-outcome-history.v1","records":[],"total":0,"shown":0,"truncated":false,"malformed":[{"id":"legacy","path":"/h/data/legacy/outcome.json","reason":"unexpected_fields"}]}\n' \
    > "$case_root/control/history.json"

  TEST_PORT=$(free_port)
  FM_HOME="$home" FM_DASHBOARD_PORT="$TEST_PORT" FM_DASHBOARD_POLL_SECONDS=1 \
    FM_DASHBOARD_HISTORY_POLL_SECONDS=1 DASH_TEST_CONTROL="$case_root/control" \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$case_root"
  wait_for_history "$case_root" '.status.phase == "ready"'
  # An unreadable record is disclosed by id and reason rather than dropped, so
  # "nothing completed" and "one record is unusable" stay distinguishable.
  jq -e '(.history.malformed | length) == 1 and .history.malformed[0].id == "legacy"' "$case_root/history.json" >/dev/null \
    || fail "an unreadable completion record was not disclosed"

  sse_log="$case_root/sse.log"
  curl --max-time 5 -Ns "http://127.0.0.1:$TEST_PORT/api/events" > "$sse_log" 2>/dev/null &
  SSE_PID=$!
  sleep 0.3
  printf '{"schema":"fm-outcome-history.v1","records":[{"schema":"fm-outcome-manifest.v1","task_id":"streamed","report":{"path":null,"present":false}}],"total":1,"shown":1,"truncated":false,"malformed":[]}\n' \
    > "$case_root/control/history.json"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    grep -q "streamed" "$sse_log" && break
    sleep 0.2
  done
  kill "$SSE_PID" 2>/dev/null || true
  SSE_PID=
  grep -q "^event: history" "$sse_log" || fail "the event stream carried no history event"
  grep -q "streamed" "$sse_log" || fail "newly completed work did not reach the browser without a reload"
  stop_server
  pass "completed work streams to the browser and unreadable records stay disclosed"
}

test_the_bind_address_is_a_numeric_address
test_sse_poll_and_last_good
test_stale_transition_streams_without_refresh
test_browser_renders_exclusive_views_and_honest_states
test_browser_alerts_only_for_new_inbox_items
test_timeout_is_single_flight
test_stale_service_unit_is_actionable
test_first_run_failures_are_explicit
test_real_snapshot_makes_zero_fleet_writes
test_history_survives_teardown_and_backlog_pruning
test_report_reads_cannot_select_a_path
test_a_huge_report_is_bounded_and_says_so
test_usage_totals_are_presence_gated
test_usage_without_store_file_is_absent_not_operational
test_a_failed_usage_read_keeps_the_last_good_one
test_usage_reads_a_read_only_store_through_node
test_history_streams_and_isolates_bad_records
test_installer_writes_hardened_user_service
test_installer_preserves_exposure_configuration
test_unit_grants_scratch_without_hiding_tmp_and_opener_keeps_temps_in_memory
fm_assert_no_user_event_store_leak "$USER_EVENT_STORE_BEFORE"
pass "no agent-event store was created outside this suite's own temp space"
printf '\nall fm-dashboard tests passed\n'
