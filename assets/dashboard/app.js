// app.js - the Firstmate fleet dashboard application.
//
// Six destinations behind a hash router (#/needs, #/fleet, #/backlog,
// #/history, #/knowledge, #/task/<id>), rebuilt from the approved design in
// data/dashboard-design/Firstmate Fleet.dc.html. One view is rendered at a
// time: the router resolves exactly one view (router.js owns that contract)
// and this module mounts only that view's DOM, so the others are absent from
// the document rather than hidden.
//
// The data policy lives in the sibling modules (inbox.js, history.js,
// backlog.js, gbrain.js, events.js); this file owns presentation and wiring.
// display.js owns the convention that record values become labels before they
// reach the DOM, so no filesystem path renders on any view.

import { buildInbox, formatAge, prReadiness, REASON_KINDS } from "./inbox.js";
import { buildHistory, formatDuration, formatTokens, HISTORY_LIMITS } from "./history.js";
import { buildTimeline, clockLabel, mergeTaskBackfill, outcomeTone, sourceNotice, timelineNotice, typeLabel } from "./events.js";
import { noticeSentence, renderMarkdown, safeUrl } from "./markdown.js";
import { buildGBrainHealth, GBRAIN_HEALTHY_SOURCE_STATES, searchFailure, searchReasonLabel } from "./gbrain.js";
import { hashFor, parseHash, TASK_VIEW, viewRoute } from "./router.js";
import { label } from "./display.js";
import { buildBacklog, BACKLOG_LIMITS } from "./backlog.js";
import { displayError, displaySafeEnvelope } from "./errors.js";

const ui = {
  app: document.getElementById("app"),
  view: document.getElementById("view"),
  vdot: document.getElementById("vdot"),
  verdict: document.getElementById("verdict"),
  segbar: document.getElementById("segbar"),
  stalenote: document.getElementById("stalenote"),
  staleText: document.getElementById("staleno-txt"),
  navbadge: document.getElementById("navbadge"),
  tabbadge: document.getElementById("tabbadge"),
  navButtons: new Map(),
  themeButton: document.getElementById("theme-button"),
  notifyButton: document.getElementById("notify-button"),
};

for (const button of document.querySelectorAll("[data-route]")) {
  const route = button.dataset.route;
  if (!ui.navButtons.has(route)) ui.navButtons.set(route, []);
  ui.navButtons.get(route).push(button);
  button.addEventListener("click", () => { window.location.hash = hashFor(viewRoute(route)); });
}

// --- fleet column ladder ----------------------------------------------------
//
// The snapshot resolves every task to exactly one card.column against its own
// card_precedence; these are the presentation facts for each column key. The
// order here mirrors card_precedence so the board reads highest-priority first.

const COLUMN_DEFS = [
  { key: "needs_decision", label: "Needs decision", tone: "amber" },
  { key: "blocked", label: "Blocked", tone: "red" },
  { key: "parked", label: "Parked", tone: "grey" },
  { key: "failed", label: "Failed", tone: "red" },
  { key: "review", label: "In review", tone: "blue" },
  { key: "done", label: "Done", tone: "green" },
  { key: "waiting", label: "Waiting", tone: "grey" },
  { key: "active", label: "Active", tone: "green" },
  { key: "secondmate", label: "Secondmates", tone: "blue" },
  { key: "idle", label: "Idle", tone: "grey" },
];

// Presentation for inbox reason kinds: shape carries the meaning, tone follows
// the policy module's REASON_KINDS so the two cannot drift on severity.
const REASON_PRESENTATION = {
  decision: { glyph: "g-decision" },
  credential: { glyph: "g-cred" },
  blocked: { glyph: "g-blocked" },
  failed: { glyph: "g-failed" },
  pr_attention: { glyph: "g-blocked" },
  merge_ready: { glyph: "g-review" },
  review_ready: { glyph: "g-review" },
  pr_unknown: { glyph: "g-unknown" },
};

const BACKLOG_TABS = [
  { key: "all", label: "All" },
  { key: "in_flight", label: "In flight" },
  { key: "queued", label: "Queued" },
  { key: "held", label: "Held" },
  { key: "blocked", label: "Blocked" },
];

const HISTORY_RANGES = [
  { key: "7d", label: "7d", days: 7 },
  { key: "30d", label: "30d", days: 30 },
  { key: "90d", label: "90d", days: 90 },
  { key: "all", label: "All time", days: null },
];

const state = {
  route: parseHash(window.location.hash),
  envelope: null,
  history: { envelope: null, epoch: 0, filters: { query: "", project: "", outcome: "" }, range: "30d", page: 0 },
  backlog: { envelope: null, filters: { query: "", project: "", kind: "", prio: "" }, tab: "all", page: 0 },
  fleet: { filters: [] },
  gbrain: { health: null, query: "", limit: 8, searched: false, payload: null, error: null, busy: false, healthOpen: false },
  task: { reports: new Map(), timelines: new Map() },
  events: null,
  routeEpoch: 0,
  controlCommit: 0,
  notifyEnabled: false,
  seenInboxIds: null,
};

// --- dom helpers ------------------------------------------------------------

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null && text !== "") node.append(document.createTextNode(text));
  return node;
}

// Every view's root carries a stable id (#view-needs, #view-fleet, ...) so a
// test or browser check can assert the router's contract structurally: the
// active view's id is on the page and every other view id is absent.
function viewRoot(name) {
  const node = element("div");
  node.id = `view-${name}`;
  return node;
}

function persistentControlIds(node) {
  const ids = [];
  if (node?.tagName === "INPUT" && node.type === "search" && node.id) ids.push(node.id);
  for (const child of node?.childNodes || []) ids.push(...persistentControlIds(child));
  return ids;
}

function refreshMountedView(current, fresh) {
  const committedValue = current.tagName === "INPUT"
    && current.type === "search"
    && current.id === fresh.id
    && current.dataset.valueCommit !== fresh.dataset.valueCommit;
  current.className = fresh.className;
  for (const key of Object.keys(current.dataset)) {
    if (!(key in fresh.dataset)) delete current.dataset[key];
  }
  for (const [key, value] of Object.entries(fresh.dataset)) current.dataset[key] = value;

  if (current.tagName === "INPUT" && current.type === "search" && current.id === fresh.id) {
    current.placeholder = fresh.placeholder;
    current.maxLength = fresh.maxLength;
    if (committedValue) current.value = fresh.value;
    return;
  }

  let index = 0;
  for (const freshChild of [...fresh.childNodes]) {
    const ids = persistentControlIds(freshChild);
    const children = [...current.childNodes];
    if (ids.length) {
      const match = children.slice(index).find((child) => {
        const currentIds = persistentControlIds(child);
        return ids.every((id) => currentIds.includes(id));
      });
      if (match) {
        const cursor = current.childNodes[index] || null;
        if (match !== cursor) current.insertBefore(match, cursor);
        refreshMountedView(match, freshChild);
      } else {
        current.insertBefore(freshChild, current.childNodes[index] || null);
      }
    } else {
      const cursor = current.childNodes[index] || null;
      if (cursor && persistentControlIds(cursor).length) current.insertBefore(freshChild, cursor);
      else if (cursor) current.replaceChild(freshChild, cursor);
      else current.append(freshChild);
    }
    index += 1;
  }
  while (current.childNodes.length > index) current.removeChild(current.childNodes[index]);
}

function stampControlCommit(node) {
  if (node?.tagName === "INPUT" && node.type === "search" && node.id) node.dataset.valueCommit = String(state.controlCommit);
  for (const child of node?.childNodes || []) stampControlCommit(child);
}

function commitControlValues(update) {
  update();
  state.controlCommit += 1;
  render();
}

function dot(tone) { return element("span", tone === "unknown" ? "ring" : `dot d-${tone}`); }

function glyph(kind, tone) {
  const presentation = REASON_PRESENTATION[kind] || REASON_PRESENTATION.decision;
  const def = REASON_KINDS[kind] || { tone: "unknown", label: kind };
  const useTone = tone || def.tone;
  const wrap = element("span", `g ${presentation.glyph}`);
  if (useTone && useTone !== "unknown") wrap.classList.add(`t-${useTone}`);
  return { node: wrap, label: def.label, tone: useTone };
}

function fmtAge(seconds) {
  if (!Number.isFinite(seconds)) return null;
  return formatAge(seconds);
}

function ageChip(seconds, known = true) {
  if (!known || !Number.isFinite(seconds)) return element("span", "agechip age-unknown", "age unknown");
  const minutes = seconds / 60;
  const cls = minutes >= 240 ? "age-hot" : minutes >= 60 ? "age-warm" : "";
  return element("span", `agechip ${cls}`.trim(), formatAge(seconds));
}

function pageHead(eyebrow, title, note) {
  const head = element("div", "page-hd");
  const row = element("div", "page-hd-row");
  const text = element("div");
  text.append(element("span", "page-eyebrow", eyebrow));
  text.append(element("h1", "page-h", title));
  row.append(text);
  if (note) row.append(element("p", "refresh-note", note));
  head.append(row);
  return head;
}

function emptyState({ tone = "green", ring = false, big, facts, teach, action }) {
  const box = element("div", "empty");
  box.append(ring ? element("span", "ring") : dot(tone));
  box.append(element("div", "empty-big", big));
  if (facts) box.append(element("div", "empty-facts", facts));
  if (teach) box.append(element("p", "empty-teach", teach));
  if (action) box.append(action);
  return box;
}

function notice(tone, heading, detail) {
  const node = element("div", `notice${tone === "red" ? " error" : ""}`);
  node.append(tone === "unknown" ? element("span", "ring") : dot(tone));
  const body = element("div");
  if (heading) body.append(element("span", "nhead", `${heading} `));
  body.append(document.createTextNode(detail));
  node.append(body);
  return node;
}

function markdownDom(node) {
  if (node.text !== undefined) return document.createTextNode(node.text);
  const dom = element(node.tag, MARKDOWN_CLASS_FOR[node.tag] || "");
  if (node.href) dom.setAttribute("href", safeUrl(node.href) || "#");
  for (const child of node.children || []) dom.append(markdownDom(child));
  return dom;
}

const MARKDOWN_CLASS_FOR = {
  h1: "", h2: "", h3: "", h4: "", p: "", ul: "", ol: "", li: "",
  code: "", pre: "", blockquote: "", a: "", strong: "", em: "", hr: "",
};

// --- theme, alerts ----------------------------------------------------------

function setTheme(theme, persist = false) {
  document.documentElement.dataset.theme = theme;
  // Only an explicit toggle persists: initialization writes nothing, so "no
  // stored preference" stays a real state and a later browser import of the
  // operator's storage cannot fossilize a default they never chose.
  if (persist) { try { localStorage.setItem("fm-dashboard-theme", theme); } catch {} }
  const text = document.querySelector("#theme-button .nlabel");
  if (text) text.textContent = theme === "dark" ? "Light mode" : "Dark mode";
}

function toggleTheme() {
  setTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light", true);
}

function initializeTheme() {
  // Dark is the root identity, and light is reached only by an explicit
  // choice: with no stored preference the page is dark whatever the system
  // says, the same default the fleet's shipped dashboard has always had.
  let saved = null;
  try { saved = localStorage.getItem("fm-dashboard-theme"); } catch {}
  setTheme(saved === "light" || saved === "dark" ? saved : "dark");
  ui.themeButton.addEventListener("click", toggleTheme);
}

function notificationsSupported() {
  return typeof Notification === "function";
}

function paintNotifyButton() {
  const supported = notificationsSupported();
  const label = !supported ? "Alerts unavailable" : state.notifyEnabled ? "Alerts on" : "Alerts off";
  const text = document.querySelector("#notify-button .nlabel");
  if (text) text.textContent = label;
  ui.notifyButton.disabled = !supported;
  ui.notifyButton.setAttribute("aria-pressed", String(state.notifyEnabled));
}

async function toggleNotifications() {
  if (!notificationsSupported()) return;
  if (state.notifyEnabled) {
    state.notifyEnabled = false;
  } else {
    let permission = Notification.permission;
    if (permission === "default") {
      try { permission = await Notification.requestPermission(); } catch { permission = "denied"; }
    }
    state.notifyEnabled = permission === "granted";
  }
  try { localStorage.setItem("fm-dashboard-alerts", state.notifyEnabled ? "on" : "off"); } catch {}
  paintNotifyButton();
}

function initializeNotifications() {
  let saved = null;
  try { saved = localStorage.getItem("fm-dashboard-alerts"); } catch {}
  state.notifyEnabled = saved === "on" && notificationsSupported() && Notification.permission === "granted";
  ui.notifyButton.addEventListener("click", () => void toggleNotifications());
  paintNotifyButton();
}

function announceNewItems(items, observed) {
  // A render that carried no snapshot saw nothing, so it cannot be the
  // baseline: its empty inbox must not turn every waiting item into an alert.
  if (!observed) return;
  const ids = new Set(items.map((item) => item.id));
  if (state.seenInboxIds === null) {
    state.seenInboxIds = ids;
    return;
  }
  const fresh = items.filter((item) => !state.seenInboxIds.has(item.id));
  state.seenInboxIds = ids;
  if (!fresh.length || !state.notifyEnabled || !notificationsSupported() || Notification.permission !== "granted") return;
  for (const item of fresh.slice(0, 3)) {
    try {
      new Notification("Firstmate: an item needs you", { body: `${item.title}\n${item.reasons[0].text}`, tag: `fm-inbox-${item.id}` });
    } catch { return; }
  }
}

// --- verdict strip ----------------------------------------------------------

function snapshotTasks() {
  return Array.isArray(state.envelope?.snapshot?.tasks) ? state.envelope.snapshot.tasks : [];
}

function verdictFacts() {
  const status = state.envelope?.status;
  // An unreadable fleet is not a fleet that has done nothing: "unavailable"
  // renders as its own explicit state, never as the calm first-run page.
  const unavailable = status?.phase === "unavailable";
  const firstRun = !unavailable && (!state.envelope?.snapshot || status?.phase === "first_run");
  const inbox = firstRun || unavailable ? { items: [], counts: { total: 0, decisions: 0, credentials: 0, blocked: 0, failed: 0, review_ready: 0, merge_ready: 0, unknown: 0 } } : buildInbox(state.envelope.snapshot);
  const amber = inbox.counts.decisions + inbox.counts.credentials + inbox.counts.review_ready + inbox.counts.merge_ready;
  const red = inbox.counts.blocked + inbox.counts.failed;
  return { firstRun, unavailable, inbox, amber, red, stale: status?.stale === true };
}

// The plain-words sentence for a snapshot that could not be read, with the one
// error kind whose polling really does stop called out honestly.
function snapshotFailureText(error) {
  const failure = displayError(error, "snapshot_failed");
  const detail = failure.message ? `: ${failure.message}` : "";
  const followup = failure.kind === "service_unit_outdated"
    ? " Snapshot polling is paused until the service is reinstalled."
    : " Retrying automatically.";
  return `The fleet snapshot could not be read${detail}.${followup}`;
}

function renderVerdict() {
  const { firstRun, unavailable, inbox, amber, red, stale } = verdictFacts();
  ui.app.dataset.stale = stale ? "true" : "false";

  let text;
  let tone;
  // The specific sentences require a real count of their own kind: an inbox
  // whose items are all unknown-toned (say, an unreadable PR state) must read
  // as items needing you, never as "0 decisions waiting".
  if (unavailable) { text = "Fleet unavailable"; tone = "unknown"; }
  else if (firstRun) { text = "Nothing has run yet"; tone = "grey"; }
  else if (inbox.counts.total === 0) { text = "Nothing needs you"; tone = "green"; }
  else if (red === 0 && amber > 0) { text = `${amber} ${amber === 1 ? "decision" : "decisions"} waiting`; tone = "amber"; }
  else if (amber === 0 && red > 0) { text = `${red} ${red === 1 ? "task" : "tasks"} blocked`; tone = "red"; }
  else { text = `${inbox.counts.total} ${inbox.counts.total === 1 ? "item needs" : "items need"} you`; tone = "amber"; }

  ui.vdot.className = `vdot ${stale || tone === "unknown" ? "vd-unknown" : `vd-${tone}`}`;
  ui.verdict.className = `verdict${!stale && tone !== "grey" && tone !== "unknown" ? ` t-${tone}` : ""}`;
  ui.verdict.textContent = text;

  const tasks = snapshotTasks();
  const segments = tasks.map((task) => {
    const def = COLUMN_DEFS.find((column) => column.key === task?.card?.column) || COLUMN_DEFS[COLUMN_DEFS.length - 1];
    return element("span", `seg seg--${def.tone}`);
  });
  ui.segbar.replaceChildren(...(segments.length ? segments : [element("span", "seg")]));

  const age = state.envelope?.status?.last_success_age_seconds;
  ui.stalenote.hidden = !stale;
  if (stale) ui.staleText.textContent = `data ${fmtAge(age) || "age unknown"} old · refresh failing`;

  const badge = inbox.counts.total;
  for (const node of [ui.navbadge, ui.tabbadge]) {
    node.hidden = badge === 0;
    node.textContent = String(badge);
  }
}

function publishStickyHeight() {
  const height = ui.app.querySelector(".vstrip")?.getBoundingClientRect().height;
  if (Number.isFinite(height) && height > 0) document.documentElement.style.setProperty("--vstrip-h", `${Math.ceil(height)}px`);
}

// --- Needs you --------------------------------------------------------------

function needsCard(item) {
  const primary = item.reasons[0];
  const def = REASON_KINDS[primary.kind] || { tone: "amber", label: "Decision" };
  const card = element("article", "card");
  card.setAttribute("data-task", item.id);

  const top = element("div", "card-top");
  const badge = element("span", `kind t-${def.tone === "unknown" ? "grey" : def.tone}`);
  badge.append(glyph(primary.kind, def.tone).node, document.createTextNode(def.label));
  top.append(badge);
  if (item.project) top.append(element("span", "proj", label(item.project)));
  top.append(ageChip(item.age_seconds, item.age_known));
  card.append(top);

  card.append(element("h3", "card-title", item.title));
  card.append(element("p", "card-ask", primary.text));

  const extra = [];
  if (item.pr?.url) {
    const line = element("button", "card-linkline", `${item.pr.verdict || "pull request"} · open`);
    line.type = "button";
    line.addEventListener("click", (event) => { event.stopPropagation(); window.open(item.pr.url, "_blank", "noopener"); });
    extra.push(line);
  }
  if (item.reasons.length > 1) {
    const more = item.reasons.slice(1).map((reason) => (REASON_KINDS[reason.kind] || { label: reason.kind }).label);
    extra.push(element("div", "card-id", `also: ${more.join(", ")}`));
  }
  extra.push(element("div", "card-id", item.id));
  const wrap = element("div", "card-extra");
  wrap.append(...extra);
  card.append(wrap);

  card.addEventListener("click", () => { window.location.hash = hashFor({ view: TASK_VIEW, taskId: item.id }); });
  return card;
}

function renderNeeds() {
  const { firstRun, unavailable, inbox } = verdictFacts();
  const status = state.envelope?.status;
  const note = unavailable
    ? "snapshot refresh failing"
    : status?.last_success_at
      ? `${status.refreshing ? "Refreshing · " : ""}updated ${formatAge(status.last_success_age_seconds)} ago`
      : status?.refreshing ? "Taking the first snapshot" : "Waiting for the first snapshot";

  const view = viewRoot("needs");
  view.append(pageHead("Queue · oldest first", "Needs you", note));

  if (unavailable) {
    view.append(notice("red", "Fleet snapshot unavailable.", snapshotFailureText(status?.error)));
    view.append(emptyState({
      ring: true,
      big: "The fleet cannot be read.",
      teach: "Until the snapshot can be read again, nothing on this page is a claim about the fleet.",
    }));
    return view;
  }

  if (firstRun) {
    view.append(emptyState({
      ring: true,
      big: "Nothing yet.",
      teach: "When the fleet starts work, anything that needs your decision - approvals, credential requests, blocked tasks, review-ready pull requests - appears here as a card, oldest first. Everything else stays quiet.",
    }));
    return view;
  }

  if (inbox.items.length) {
    const cards = element("div", "cards");
    cards.append(...inbox.items.map(needsCard));
    view.append(cards);
    return view;
  }

  const activeCount = snapshotTasks().filter((task) => (task?.card?.column || "active") === "active").length;
  view.append(emptyState({
    big: "Nothing needs you.",
    facts: `${activeCount || "No"} ${activeCount === 1 ? "task" : "tasks"} under way · last check ${formatAge(status?.last_success_age_seconds)} ago`,
  }));
  return view;
}

// --- Fleet -------------------------------------------------------------------

function taskRow(task) {
  const def = COLUMN_DEFS.find((column) => column.key === task?.card?.column) || COLUMN_DEFS[COLUMN_DEFS.length - 1];
  const row = element("button", "trow");
  row.type = "button";
  row.append(element("div", "trow-title", task.backlog?.title || task.id));
  const meta = element("div", "trow-meta");
  const project = task.project ? label(task.project) : null;
  if (project) meta.append(element("span", "", project));
  const detail = [task.harness, task.model].filter(Boolean).join(" · ");
  meta.append(element("span", "mid", detail || task.id));
  meta.append(element("span", "age", fmtAge(task.spawn_age_seconds) || "age unknown"));
  row.append(meta);
  row.addEventListener("click", () => { window.location.hash = hashFor({ view: TASK_VIEW, taskId: task.id }); });
  return row;
}

function fleetColumns() {
  const tasks = snapshotTasks();
  return COLUMN_DEFS
    .map((def) => ({ def, items: tasks.filter((task) => (task?.card?.column || "idle") === def.key) }))
    .filter((column) => column.items.length > 0);
}

function renderFleet() {
  const view = viewRoot("fleet");
  const { unavailable } = verdictFacts();
  const status = state.envelope?.status;
  const note = unavailable
    ? "snapshot refresh failing"
    : status?.last_success_at
      ? `${status.refreshing ? "Refreshing · " : ""}updated ${formatAge(status.last_success_age_seconds)} ago`
      : status?.refreshing ? "Taking the first snapshot" : "Waiting for the first snapshot";
  view.append(pageHead("Live board", "Fleet", note));

  if (unavailable) {
    view.append(notice("red", "Fleet snapshot unavailable.", snapshotFailureText(status?.error)));
    view.append(emptyState({
      ring: true,
      big: "The fleet cannot be read.",
      teach: "Until the snapshot can be read again, nothing on this page is a claim about the fleet.",
    }));
    return view;
  }

  const tasks = snapshotTasks();
  if (!state.envelope?.snapshot) {
    view.append(emptyState({
      ring: true,
      big: "No workers yet.",
      teach: "Once workers pick up tasks, this board shows every one of them grouped by state - needs decision, blocked, parked, failed, in review, active, idle - with live counts on the filters above.",
    }));
    return view;
  }

  const columns = fleetColumns();
  const counts = new Map(columns.map((column) => [column.def.key, column.items.length]));
  const filters = state.fleet.filters;
  const shown = columns.filter((column) => filters.length === 0 || filters.includes(column.def.key));
  const visibleTotal = shown.reduce((sum, column) => sum + column.items.length, 0);

  const chips = element("div", "filters");
  const allChip = element("button", `fchip${filters.length === 0 ? " is-on" : ""}`);
  allChip.type = "button";
  allChip.append(document.createTextNode(`All `), element("span", "cnt", String(tasks.length)));
  allChip.addEventListener("click", () => { state.fleet.filters = []; render(); });
  chips.append(allChip);
  for (const column of columns) {
    const chip = element("button", `fchip${filters.includes(column.def.key) ? " is-on" : ""}`);
    chip.type = "button";
    chip.append(dot(column.def.tone), document.createTextNode(` ${column.def.label} `), element("span", "cnt", String(counts.get(column.def.key))));
    chip.addEventListener("click", () => {
      state.fleet.filters = filters.includes(column.def.key)
        ? filters.filter((key) => key !== column.def.key)
        : [...filters, column.def.key];
      render();
    });
    chips.append(chip);
  }
  view.append(chips);

  if (visibleTotal > 0) {
    const board = element("div", "board");
    for (const { def, items } of shown) {
      const col = element("section", "col");
      const head = element("div", "col-h");
      head.append(dot(def.tone), document.createTextNode(def.label), element("span", "cnt", String(items.length)));
      col.append(head);
      col.append(...items.map(taskRow));
      if (def.key === "needs_decision") {
        const link = element("button", "col-link", "Answer in Needs you →");
        link.type = "button";
        link.addEventListener("click", () => { window.location.hash = hashFor(viewRoute("needs")); });
        col.append(link);
      }
      board.append(col);
    }
    view.append(board);
    return view;
  }

  if (tasks.length === 0) {
    view.append(emptyState({
      ring: true,
      big: "No workers yet.",
      teach: "Once workers pick up tasks, this board shows every one of them grouped by state - needs decision, blocked, parked, failed, in review, active, idle - with live counts on the filters above.",
    }));
    return view;
  }

  const clear = element("button", "fchip", "Clear filter");
  clear.type = "button";
  clear.addEventListener("click", () => { state.fleet.filters = []; render(); });
  view.append(emptyState({
    big: "Filtered to nothing.",
    facts: `${tasks.length} ${tasks.length === 1 ? "task" : "tasks"} hidden by the current filter`,
    action: clear,
  }));
  return view;
}

// --- Backlog -----------------------------------------------------------------

// A facet key is a record value, and a record value is sometimes a clone path.
// option.value reflects a content attribute, so writing the key there would put
// that path in the document as surely as a text node would. The option carries
// its position instead and the change handler resolves the key from the list
// the options were built from, which keeps filtering exact on the raw value
// while the only project string the page renders is the one label() returned.
function backlogSelect(name, value, options, change) {
  const select = element("select", "fsel");
  select.name = name;
  const keyed = Object.entries(options).filter(([key]) => key !== "all");
  const all = element("option", "", options.all);
  all.value = "";
  select.append(all);
  keyed.forEach(([, optionLabel], index) => {
    const opt = element("option", "", optionLabel);
    opt.value = String(index);
    select.append(opt);
  });
  const current = value === null || value === undefined ? "" : String(value);
  const selected = keyed.findIndex(([key]) => key === current);
  select.value = selected === -1 ? "" : String(selected);
  select.addEventListener("change", () => {
    const chosen = select.value === "" ? null : keyed[Number(select.value)];
    change(chosen ? chosen[0] : "");
  });
  return select;
}

function renderBacklog() {
  const view = viewRoot("backlog");
  const status = state.backlog.envelope?.status;
  const note = status?.phase === "unavailable"
    ? "backlog read failing"
    : status?.last_success_at
      ? `${status.refreshing ? "Refreshing · " : ""}read ${formatAge(status.last_success_age_seconds)} ago`
      : status?.refreshing ? "Taking the first backlog read" : "Waiting for the first backlog read";
  view.append(pageHead("Queue · read-only", "Backlog", note));

  const built = buildBacklog(state.backlog.envelope, { ...state.backlog.filters, tab: state.backlog.tab, page: state.backlog.page });
  state.backlog.page = built.page.index;

  if (built.readState === "pending") {
    view.append(emptyState({ ring: true, big: "Reading the queue.", teach: "Waiting for the first backlog read to finish." }));
    return view;
  }
  if (built.readState === "unavailable") {
    view.append(notice("red", "Backlog unavailable.", built.error.text));
    view.append(emptyState({
      ring: true,
      big: "The queue cannot be read.",
      teach: "Until the backlog can be read again, nothing on this page is a claim about the queue.",
    }));
    return view;
  }
  if (built.readState === "absent") {
    view.append(emptyState({
      ring: true,
      big: "Nothing queued yet.",
      teach: "As Firstmate plans work, every queued item lands here with its project, kind, priority and - for anything held or blocked - the reason. The queue is read-only: ordering is Firstmate's job.",
    }));
    return view;
  }

  if (built.error) view.append(notice(built.error.tone === "red" ? "red" : "amber", null, built.error.text));
  if (!built.present) {
    view.append(emptyState({
      ring: true,
      big: "Nothing queued yet.",
      teach: "As Firstmate plans work, every queued item lands here with its project, kind, priority and - for anything held or blocked - the reason. The queue is read-only: ordering is Firstmate's job.",
    }));
    return view;
  }

  const toolbar = element("div", "toolbar");
  const search = element("input", "search");
  search.type = "search";
  search.id = "backlog-search";
  search.name = "backlog-search";
  search.placeholder = "Search title, project, id…";
  search.maxLength = BACKLOG_LIMITS.maxQueryChars;
  search.value = state.backlog.filters.query;
  search.addEventListener("input", () => { state.backlog.filters.query = search.value; state.backlog.page = 0; render(); });
  toolbar.append(search);
  toolbar.append(backlogSelect("project", state.backlog.filters.project, { all: "All projects", ...Object.fromEntries(built.facets.project.map((value) => [value, label(value)])) }, (value) => {
    state.backlog.filters.project = value; state.backlog.page = 0; render();
  }));
  toolbar.append(backlogSelect("kind", state.backlog.filters.kind, { all: "All kinds", ...Object.fromEntries(built.facets.kind.map((value) => [value, value])) }, (value) => {
    state.backlog.filters.kind = value; state.backlog.page = 0; render();
  }));
  toolbar.append(backlogSelect("prio", state.backlog.filters.prio, { all: "Any priority", ...Object.fromEntries(built.facets.prio.map((value) => [value, `P${value}`])) }, (value) => {
    state.backlog.filters.prio = value; state.backlog.page = 0; render();
  }));
  view.append(toolbar);

  const tabs = element("div", "tabs");
  for (const tab of BACKLOG_TABS) {
    const count = built.tabs[tab.key];
    if (count === null) continue;
    const button = element("button", `tab${state.backlog.tab === tab.key ? " is-active" : ""}`);
    button.type = "button";
    button.append(document.createTextNode(`${tab.label} `), element("span", "cnt", String(count)));
    button.addEventListener("click", () => { state.backlog.tab = tab.key; state.backlog.page = 0; render(); });
    tabs.append(button);
  }
  view.append(tabs);

  if (built.rows.length) {
    const rows = element("div", "rows");
    for (const row of built.rows) {
      const rrow = element("button", "rrow");
      rrow.type = "button";
      rrow.append(dot(row.tone));
      const main = element("div", "rmain");
      main.append(element("div", "rtitle", row.title));
      const meta = element("div", "rmeta");
      meta.append(element("span", row.stateTone === "red" ? "t-red" : row.stateTone === "amber" ? "t-amber" : "t-grey", row.stateLabel));
      if (row.project) meta.append(element("span", "", label(row.project)));
      if (row.kind) meta.append(element("span", "", row.kind));
      meta.append(element("span", "mid", row.id));
      main.append(meta);
      if (row.reason) main.append(element("div", `rreason ${row.stateTone === "red" ? "t-red" : "t-amber"}`, row.reason));
      rrow.append(main);
      const right = element("div", "rright");
      if (row.prio !== null) right.append(element("span", `prio${row.prio === 0 ? " p0" : ""}`, `P${row.prio}`));
      const age = element("span", `rage${row.ageHot ? " age-hot" : ""}`);
      age.textContent = row.age || "age unknown";
      right.append(age);
      rrow.append(right);
      rrow.addEventListener("click", () => { window.location.hash = hashFor({ view: TASK_VIEW, taskId: row.id }); });
      rows.append(rrow);
    }
    view.append(rows);
    view.append(pager(built.page, (delta) => { state.backlog.page = built.page.index + delta; render(); }));
  } else if (built.queueTotal > 0) {
    const clear = element("button", "fchip", "Clear search & filters");
    clear.type = "button";
    clear.addEventListener("click", () => {
      commitControlValues(() => {
        state.backlog.filters = { query: "", project: "", kind: "", prio: "" };
        state.backlog.tab = "all";
        state.backlog.page = 0;
      });
    });
    view.append(emptyState({
      big: "Filtered to nothing.",
      facts: `${built.queueTotal} ${built.queueTotal === 1 ? "item" : "items"} hidden by search and filters`,
      action: clear,
    }));
  } else {
    view.append(emptyState({
      ring: true,
      big: "The queue is empty.",
      teach: "The backlog was read successfully and contains no current work.",
    }));
  }

  view.append(element("div", "ronote", "Read-only - ordering and state changes are Firstmate's"));
  return view;
}

function pager(page, step) {
  const nav = element("nav", "pager");
  nav.setAttribute("aria-label", "Pages");
  nav.append(element("span", "pginfo", page.matched ? `${page.first}–${page.last} of ${page.matched}` : `0 of ${page.matched}`));
  const prev = element("button", `pgbtn${page.index === 0 ? " is-off" : ""}`, "← Prev");
  prev.type = "button";
  prev.addEventListener("click", () => step(-1));
  const next = element("button", `pgbtn${page.index >= page.pages - 1 ? " is-off" : ""}`, "Next →");
  next.type = "button";
  next.addEventListener("click", () => step(1));
  nav.append(prev, next);
  return nav;
}

// --- History -----------------------------------------------------------------

function renderHistory() {
  const view = viewRoot("history");
  const status = state.history.envelope?.status;
  const range = HISTORY_RANGES.find((entry) => entry.key === state.history.range) || HISTORY_RANGES[1];
  const from = range.days ? new Date(Date.now() - range.days * 86_400_000).toISOString().slice(0, 10) : "";
  const built = buildHistory(state.history.envelope, { ...state.history.filters, from, page: state.history.page, pageSize: HISTORY_LIMITS.defaultPageSize });
  state.history.page = built.page.index;
  const unavailable = built.readState === "unavailable";
  const note = unavailable
    ? "history read failing"
    : status?.last_success_at
      ? `${status.refreshing ? "Refreshing · " : ""}read ${formatAge(status.last_success_age_seconds)} ago`
      : status?.refreshing ? "Taking the first history read" : "Waiting for the first history read";
  view.append(pageHead("Delivered · newest first", "History", note));

  if (built.readState === "pending") {
    view.append(emptyState({ ring: true, big: "Reading completed work.", teach: "Waiting for the first history read to finish." }));
    return view;
  }
  if (unavailable) {
    view.append(notice("red", "Completed-work history unavailable.", `The completion records could not be read${status?.error?.message ? `: ${status.error.message}` : ""}. Retrying automatically.`));
    view.append(emptyState({
      ring: true,
      big: "Delivered work cannot be read.",
      teach: "Until the completion records can be read again, nothing on this page is a claim about what was delivered.",
    }));
    return view;
  }

  if (built.readState === "stale") {
    view.append(notice("amber", null, `Showing the last known good completion history: ${status?.error?.message || "the newest read did not land"}.`));
  }
  if (built.truncated) {
    const total = built.record_total === null ? "more completed work" : `${built.record_total} completed records`;
    view.append(notice("amber", null, `This read is bounded: showing ${built.page.total} of ${total}.`));
  }
  if (built.malformed.length) {
    // Named, never a bare count: an unreadable record silently missing from
    // the list is the failure this disclosure exists to end.
    const named = built.malformed.map((entry) => `${entry.id} (${entry.explanation})`).join("; ");
    view.append(notice("amber", null, `${built.malformed.length} completion ${built.malformed.length === 1 ? "record" : "records"} could not be read: ${named}.`));
  }
  if (built.usage.available && built.usage.stale) {
    view.append(notice("amber", null, `Showing the last known good token usage read: ${built.usage.reason || "the newest read did not land"}.`));
  }

  if (built.empty && !state.history.envelope?.history) {
    view.append(emptyState({
      ring: true,
      big: "Nothing delivered yet.",
      teach: "Completed work lands here with its outcome, duration and what it cost - the fleet's receipt trail.",
    }));
    return view;
  }

  const delivered = built.stats.counts.done;
  const stats = element("div", "stats");
  for (const [key, value] of [
    ["Delivered", String(delivered)],
    ["Failed", String(built.stats.counts.failed)],
    ["Tokens", built.stats.tokens.available ? formatTokens(built.stats.tokens.total) : "unavailable"],
    ["Median duration", built.stats.median_duration_seconds !== null ? formatDuration({ known: true, seconds: built.stats.median_duration_seconds }) : "unknown"],
  ]) {
    const stat = element("div", "stat");
    stat.append(element("span", "stat-k", key), element("span", "stat-v", value));
    stats.append(stat);
  }
  view.append(stats);

  const toolbar = element("div", "toolbar");
  const search = element("input", "search");
  search.type = "search";
  search.id = "history-search";
  search.name = "history-search";
  search.placeholder = "Search delivered work…";
  search.maxLength = HISTORY_LIMITS.maxQueryChars;
  search.value = state.history.filters.query;
  search.addEventListener("input", () => { state.history.filters.query = search.value; state.history.page = 0; render(); });
  toolbar.append(search);
  toolbar.append(backlogSelect("project", state.history.filters.project, { all: "All projects", ...Object.fromEntries(built.facets.project.map((value) => [value, label(value)])) }, (value) => {
    state.history.filters.project = value; state.history.page = 0; render();
  }));
  toolbar.append(backlogSelect("outcome", state.history.filters.outcome, { all: "Any outcome", ...Object.fromEntries(built.facets.outcome.map((value) => [value, (OUTCOME_LABELS[value] || value).toLowerCase()])) }, (value) => {
    state.history.filters.outcome = value; state.history.page = 0; render();
  }));
  for (const entry of HISTORY_RANGES) {
    const chip = element("button", `fchip${state.history.range === entry.key ? " is-on" : ""}`, entry.label);
    chip.type = "button";
    chip.addEventListener("click", () => { state.history.range = entry.key; state.history.page = 0; render(); });
    toolbar.append(chip);
  }
  view.append(toolbar);

  if (built.page.matched) {
    const rows = element("div", "rows");
    for (const row of built.rows) {
      const rrow = element("button", "rrow");
      rrow.type = "button";
      const def = { done: "g-review", failed: "g-failed", discarded: "g-blocked", retired: "g-blocked", unknown: "g-unknown" }[row.outcome.state] || "g-unknown";
      rrow.append(element("span", `g ${def} t-${row.outcome.tone === "unknown" ? "grey" : row.outcome.tone}`));
      const main = element("div", "rmain");
      main.append(element("div", "rtitle", row.title || row.id));
      const meta = element("div", "rmeta");
      meta.append(element("span", `t-${row.outcome.tone === "unknown" ? "grey" : row.outcome.tone}`, row.outcome.label.toLowerCase()));
      if (row.kind) meta.append(element("span", "", row.kind));
      meta.append(element("span", "mid", row.project ? label(row.project) : ""));
      main.append(meta);
      rrow.append(main);
      const right = element("div", "rright");
      right.append(element("span", "hdur", formatDuration(row.duration)));
      right.append(element("span", "hcost", row.usage?.available && Number.isFinite(row.usage?.totals?.total_tokens) ? formatTokens(row.usage.totals.total_tokens) : "unavailable"));
      right.append(element("span", "rage", row.completed_millis ? formatAge((Date.now() - row.completed_millis) / 1000) : "unknown"));
      rrow.append(right);
      rrow.addEventListener("click", () => { window.location.hash = hashFor({ view: TASK_VIEW, taskId: row.id }); });
      rows.append(rrow);
    }
    view.append(rows);
    view.append(pager(built.page, (delta) => { state.history.page = built.page.index + delta; render(); }));
  } else if (built.page.total > 0) {
    const clear = element("button", "fchip", "Clear search & filters");
    clear.type = "button";
    clear.addEventListener("click", () => {
      commitControlValues(() => {
        state.history.filters = { query: "", project: "", outcome: "" };
        state.history.range = "all";
        state.history.page = 0;
      });
    });
    view.append(emptyState({
      big: "Filtered to nothing.",
      facts: `${built.page.total} completed ${built.page.total === 1 ? "item" : "items"} hidden by search and filters`,
      action: clear,
    }));
  } else {
    view.append(emptyState({
      ring: true,
      big: "Nothing delivered yet.",
      teach: "Completed work lands here with its outcome, duration and what it cost - the fleet's receipt trail.",
    }));
  }
  return view;
}

const OUTCOME_LABELS = {
  done: "Done",
  failed: "Failed",
  discarded: "Discarded",
  retired: "Retired",
  unknown: "Outcome unknown",
};

// --- Knowledge ---------------------------------------------------------------

function renderKnowledge() {
  const view = viewRoot("knowledge");
  const health = buildGBrainHealth(state.gbrain.health);
  view.append(pageHead("Captured knowledge", "Knowledge"));

  if (health.noBrain) {
    view.append(emptyState({
      ring: true,
      big: "Knowledge is not configured.",
      teach: "This install has no knowledge store attached. When one is configured, the fleet's accumulated notes - runbooks, postmortems, decisions and their reasons - become searchable here. Nothing is broken; there is simply nothing to search.",
    }));
    return view;
  }

  const hero = element("div", "khero");
  hero.append(element("span", "page-eyebrow", "Search what the fleet knows"));
  const search = element("input", "ksearch");
  search.type = "search";
  search.id = "knowledge-search";
  search.name = "knowledge-search";
  search.placeholder = "Search captured reports and notes…";
  search.maxLength = 1024;
  search.value = state.gbrain.query;
  search.addEventListener("keydown", (event) => {
    if (event.key === "Enter") { state.gbrain.query = search.value; void runKnowledgeSearch(); }
  });
  hero.append(search);
  const hint = state.gbrain.searched
    ? `${state.gbrain.payload?.results?.length ?? 0} ${state.gbrain.error ? "results unavailable" : "matches"}`
    : "the brain may take a few seconds on a cold index";
  hero.append(element("span", "khint", hint));
  view.append(hero);

  const healthBox = element("div", "health");
  const healthButton = element("button", "health-h");
  healthButton.type = "button";
  healthButton.setAttribute("aria-expanded", String(state.gbrain.healthOpen));
  const nominal = health.cards.filter((card) => card.tone === "green").length;
  const unreadable = health.cards.filter((card) => card.tone === "unknown").length;
  // No cards means the health envelope never arrived, which is an unknown, not
  // a clean bill: the hollow ring, never the green dot.
  healthButton.append(
    health.cards.length === 0 || health.cards.some((card) => card.tone === "unknown") ? element("span", "ring") : dot("green"),
    document.createTextNode(` ${health.cards.length === 0 ? "health unread" : `${nominal} ${nominal === 1 ? "system" : "systems"} nominal${unreadable ? ` · ${unreadable} unreadable` : ""}`}`),
    element("span", "chev", state.gbrain.healthOpen ? "▲" : "▼"),
  );
  healthButton.addEventListener("click", () => { state.gbrain.healthOpen = !state.gbrain.healthOpen; render(); });
  healthBox.append(healthButton);
  if (state.gbrain.healthOpen) {
    const list = element("div", "health-list");
    for (const card of health.cards) {
      const row = element("div", "hsys");
      row.append(card.tone === "unknown" ? element("span", "ring") : dot(card.tone));
      row.append(document.createTextNode(card.label));
      row.append(element("span", "hstat", card.value));
      row.title = card.detail || "";
      list.append(row);
    }
    healthBox.append(list);
  }
  view.append(healthBox);

  const results = element("div", "krows");
  if (state.gbrain.error) {
    results.append(notice(state.gbrain.error.tone === "red" ? "red" : "amber", null, state.gbrain.error.text));
  } else if (state.gbrain.searched && state.gbrain.payload) {
    const payload = state.gbrain.payload;
    const failed = (payload.sources || []).filter((row) => !GBRAIN_HEALTHY_SOURCE_STATES.has(row.state));
    if (failed.length) {
      results.append(notice(failed.some((row) => row.state === "failed") ? "red" : "amber", "Some corpora did not answer.", ` ${failed.map((row) => `${row.source}: ${row.detail || row.state}`).join("; ")}`));
    }
    for (const row of payload.results || []) {
      const card = element("article", "krow");
      card.append(element("div", "kk", row.title || "Untitled"));
      if (row.excerpt) card.append(element("div", "ksnip", row.excerpt));
      const meta = [row.source, row.stale === true ? "stale" : null, typeof row.score === "number" ? `score ${row.score.toFixed(3)}` : null].filter(Boolean);
      card.append(element("div", "kmeta", meta.join(" · ")));
      results.append(card);
    }
    if (!payload.results?.length) {
      const clear = element("button", "fchip", "Clear search");
      clear.type = "button";
      clear.addEventListener("click", () => {
        commitControlValues(() => {
          state.gbrain.query = "";
          state.gbrain.searched = false;
          state.gbrain.payload = null;
        });
      });
      results.append(emptyState({
        big: "No notes match.",
        facts: `searched the captured corpora · 0 matches`,
        action: clear,
      }));
    }
  } else if (state.gbrain.searched) {
    results.append(notice("amber", null, "The search has not answered yet."));
  } else {
    results.append(emptyState({
      ring: true,
      big: "Nothing learned yet.",
      teach: "As the fleet works it writes down what it learns - runbooks, postmortems, decisions and their reasons. Those notes become searchable here.",
    }));
  }
  view.append(results);
  return view;
}

async function runKnowledgeSearch() {
  const query = state.gbrain.query.trim();
  if (query.length < 2) {
    state.gbrain.error = { tone: "amber", text: searchReasonLabel("query_too_short") };
    state.gbrain.searched = true;
    state.gbrain.payload = null;
    render();
    return;
  }
  state.gbrain.busy = true;
  state.gbrain.error = null;
  try {
    const response = await fetch("/api/gbrain/search", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query, limit: state.gbrain.limit }),
      cache: "no-store",
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload?.schema !== "fm-gbrain-search.v1") {
      const reason = payload?.reason || (response.ok ? "unsupported_schema" : `http_${response.status}`);
      const failure = displayError({ kind: reason, message: payload?.detail }, reason);
      state.gbrain.error = searchFailure(failure.kind) || { tone: "red", text: searchReasonLabel(failure.kind) };
      state.gbrain.payload = null;
    } else {
      state.gbrain.payload = payload;
    }
  } catch (error) {
    const failure = displayError(error, "server_unreachable");
    state.gbrain.error = { tone: "red", text: `The search could not be sent: ${failure.message}` };
    state.gbrain.payload = null;
  } finally {
    state.gbrain.searched = true;
    state.gbrain.busy = false;
    render();
  }
}

// --- Task detail --------------------------------------------------------------

function kvRow(key, value) {
  const cell = element("div", "kv");
  cell.append(element("span", "kv-k", key), element("span", "kv-v", value ?? "unknown"));
  return cell;
}

function taskWorkItems(value) {
  const references = Array.isArray(value) ? value : Array.isArray(value?.references) ? value.references : [];
  return references.filter((reference) => reference && typeof reference === "object").map((reference) => ({
    forge: reference.forge || null,
    url: reference.url || null,
    label: reference.label || reference.enrichment?.title || reference.url || null,
  }));
}

function liveTaskRecord(task) {
  const column = COLUMN_DEFS.find((entry) => entry.key === task?.card?.column);
  const readiness = prReadiness(task);
  return {
    id: task.id,
    source: "live",
    raw: task,
    title: task.backlog?.title || task.id,
    project: task.project || null,
    kind: task.kind || null,
    harness: task.harness || null,
    model: task.model || null,
    mode: task.mode || null,
    age: fmtAge(task.spawn_age_seconds) || null,
    completed: null,
    raised: null,
    current: {
      label: column?.label || "Unknown",
      tone: column?.tone || "unknown",
      reason: task.current_state?.detail || task.current_state?.raw || "The worker is live; no finer detail is recorded.",
    },
    pr: readiness.url ? { url: readiness.url, tone: readiness.tone, label: readiness.label, checks: readiness.fields?.checks || null } : null,
    reportPresent: false,
    reportKey: null,
    workItems: taskWorkItems(task.work_items),
  };
}

function historyTaskRecord(record) {
  const checks = record.pr?.fields?.find((field) => field.name === "checks")?.value || null;
  return {
    id: record.id,
    source: "history",
    raw: record,
    title: record.title || record.id,
    project: record.project,
    kind: record.kind,
    harness: record.harness,
    model: record.model,
    mode: record.mode,
    age: null,
    completed: record.timestamps?.completed || null,
    raised: null,
    current: {
      label: record.outcome?.label || "Outcome unknown",
      tone: record.outcome?.tone || "unknown",
      reason: record.outcome?.detail || "The completion record carries no outcome detail.",
    },
    pr: record.pr?.present ? { url: record.pr.url, tone: record.pr.tone || "unknown", label: record.pr.state || "unknown", checks } : null,
    reportPresent: record.report?.present === true,
    reportKey: reportKeyFor(record),
    workItems: taskWorkItems(record.work_items),
  };
}

// What a cached report is a cache OF. History republishes on every poll, twice,
// with the records usually unchanged, so identity has to come from the record
// rather than from the arrival of a push: the same key means the retained
// report the server would serve is the same file, and the cached body stays on
// the page untouched.
function reportKeyFor(record) {
  if (record?.report?.present !== true) return null;
  return [record.report.path || "", record.timestamps?.completed || "", record.id || ""].join("|");
}

function backlogTaskRecord(record) {
  return {
    id: record.id,
    source: "backlog",
    raw: record,
    title: record.title || record.id,
    project: record.project,
    kind: record.kind,
    harness: null,
    model: null,
    mode: null,
    age: null,
    completed: null,
    raised: record.since,
    current: {
      label: record.stateLabel,
      tone: record.stateTone,
      reason: record.reason || "This item is waiting in the queue.",
    },
    pr: null,
    reportPresent: false,
    reportKey: null,
    workItems: [],
  };
}

function snapshotReadState() {
  if (!state.envelope) return "pending";
  if (state.envelope.status?.phase === "unavailable") return "unavailable";
  if (state.envelope.status?.phase === "first_run" && state.envelope.status?.refreshing === true) return "pending";
  if (state.envelope.status?.phase === "last_good" && state.envelope.snapshot) return "stale";
  if (!state.envelope.snapshot) return "absent";
  return "ready";
}

function readStatus(readState, envelope) {
  if (readState === "ready" || (readState === "absent" && envelope?.status?.phase === "ready")) return "fresh";
  if (readState === "stale") return "stale";
  if (readState === "unavailable") return "failed";
  return "pending";
}

function taskReadSource(name, readState, envelope, records, conclusive = true) {
  const status = readStatus(readState, envelope);
  const error = envelope?.status?.error?.message || null;
  const reason = status === "failed"
    ? error || "the read failed"
    : status === "stale"
      ? error || "only a last known good read is available"
      : status === "pending"
        ? "the read has not completed"
        : null;
  return {
    name,
    status,
    conclusive: status === "fresh" && conclusive,
    records,
    reason,
    notice: status === "stale" ? `This task comes from the last known good ${name}: ${reason}.` : null,
  };
}

function taskLookup(taskId) {
  const history = buildHistory(state.history.envelope, {});
  const backlog = buildBacklog(state.backlog.envelope, {});
  const sources = [
    taskReadSource("fleet snapshot", snapshotReadState(), state.envelope, snapshotTasks(), true),
    taskReadSource("completion history", history.readState, state.history.envelope, history.allRecords, !history.truncated && history.malformed.length === 0),
    taskReadSource("backlog", backlog.readState, state.backlog.envelope, backlog.taskRecords, true),
  ];

  const historySource = sources[1];
  if (historySource.status === "fresh" && !historySource.conclusive) {
    const reasons = [];
    if (history.truncated) reasons.push("the archive read is truncated");
    if (history.malformed.length) reasons.push("some completion records are unreadable");
    historySource.reason = reasons.join(" and ");
  }

  const found = [
    { source: sources[0], record: sources[0].records.find((task) => task?.id === taskId), normalize: liveTaskRecord },
    { source: sources[1], record: sources[1].records.find((record) => record.id === taskId), normalize: historyTaskRecord },
    { source: sources[2], record: sources[2].records.find((record) => record.id === taskId), normalize: backlogTaskRecord },
  ].find((candidate) => candidate.record);
  if (found) return { phase: "found", task: found.normalize(found.record), notice: found.source.notice };

  const uncertain = sources.filter((source) => source.status !== "fresh" || !source.conclusive);
  if (uncertain.some((source) => source.status === "failed" || source.status === "stale")) return { phase: "unavailable", sources: uncertain };
  if (uncertain.some((source) => source.status === "pending")) return { phase: "pending", sources: uncertain };
  if (uncertain.length) return { phase: "unavailable", sources: uncertain };
  return { phase: "missing", sources };
}

// One retained report per task visited, each up to the server's report byte
// limit, so the cache is bounded rather than growing for the life of the tab.
// The open task is never the eviction candidate: it is the entry the page is
// rendering from, and dropping it would refetch what is already on screen.
const REPORT_CACHE_LIMIT = 12;

function evictTaskReports() {
  for (const taskId of state.task.reports.keys()) {
    if (state.task.reports.size <= REPORT_CACHE_LIMIT) return;
    if (taskId === state.route.taskId) continue;
    state.task.reports.delete(taskId);
  }
}

// A report is cached against the completion record it came from, so an
// unchanged record never costs a request however often history republishes.
// A read that FAILED is a different fact from a read that answered: it stays
// on the page as the failure it was, but it is retryable, and the two things
// that make it retryable are the two that can change the answer - revisiting
// the route, and a later history push. Neither a re-render nor a fleet
// broadcast spends a request, which is what keeps reportPanel's fetch-on-every
// -render from becoming a loop against a server that is refusing.
async function fetchTaskReport(taskId, reportKey = null, routeEpoch = state.routeEpoch) {
  let entry = state.task.reports.get(taskId);
  if (!entry) {
    entry = { loading: false, payload: null, reportKey: null, failed: false, routeEpoch: -1, historyEpoch: -1 };
    state.task.reports.set(taskId, entry);
    evictTaskReports();
  }
  if (entry.loading) return entry;
  if (entry.reportKey === reportKey) {
    const retryable = entry.failed
      && (entry.routeEpoch !== routeEpoch || entry.historyEpoch !== state.history.epoch);
    if (!retryable) return entry;
  }
  entry.loading = true;
  entry.reportKey = reportKey;
  entry.routeEpoch = routeEpoch;
  entry.historyEpoch = state.history.epoch;
  try {
    const response = await fetch(`/api/report?task=${encodeURIComponent(taskId)}`, { cache: "no-store" });
    const payload = await response.json().catch(() => ({}));
    entry.payload = payload;
    entry.failed = payload?.schema !== "fm-dashboard-report.v1" || payload.present !== true;
  } catch (error) {
    entry.payload = { schema: null, error: displayError(error, "server_unreachable") };
    entry.failed = true;
  }
  entry.loading = false;
  if (state.route.view === TASK_VIEW && state.route.taskId === taskId) render();
  return entry;
}

async function fetchTaskTimeline(taskId, routeEpoch = state.routeEpoch, force = false) {
  let entry = state.task.timelines.get(taskId);
  if (!entry) {
    entry = { loading: false, envelope: null, failed: false, retryArmed: true, routeEpoch: -1 };
    state.task.timelines.set(taskId, entry);
  }
  if (entry.loading || (!force && entry.routeEpoch === routeEpoch)) return entry;
  // Arriving here unforced means the route was (re)visited, which is one of the
  // two things that hands a failed entry a fresh retry; the other is recovery.
  if (!force) entry.retryArmed = true;
  entry.loading = true;
  entry.routeEpoch = routeEpoch;
  try {
    const response = await fetch(`/api/timeline?task=${encodeURIComponent(taskId)}`, { cache: "no-store" });
    const envelope = displaySafeEnvelope(await response.json().catch(() => null));
    if (!response.ok || envelope?.schema !== "fm-dashboard-timeline.v1") throw new Error("timeline unavailable");
    const retained = { task: taskId, events: Array.isArray(envelope.events) ? envelope.events : [] };
    entry.envelope = {
      ...envelope,
      events: mergeTaskBackfill(Array.isArray(entry.envelope?.events) ? entry.envelope.events : [], retained, taskId),
    };
    entry.failed = false;
    entry.retryArmed = true;
  } catch {
    entry.failed = true;
  }
  entry.loading = false;
  if (state.route.view === TASK_VIEW && state.route.taskId === taskId) render();
  return entry;
}

// A failed backfill is worth one more read, not one per broadcast. The retry is
// armed by a route visit or by a read that succeeded, spent by a single healthy
// ready frame for the task currently open, and not rearmed by anything else, so
// an endpoint that stays unreachable costs one request however busy the fleet
// stream is - mergeTaskBackfill's no-HTTP-per-broadcast invariant survives the
// failure path as well as the healthy one.
function retryFailedTaskTimeline(taskId, entry, envelope) {
  if (!entry.failed || !entry.retryArmed) return;
  if (envelope?.status?.ingestion !== "ready") return;
  if (state.route.view !== TASK_VIEW || state.route.taskId !== taskId) return;
  entry.retryArmed = false;
  void fetchTaskTimeline(taskId, state.routeEpoch, true);
}

function reportPanel(taskId, present, live = null, reportKey = null) {
  const panel = element("section", "panel");
  panel.dataset.loadState = "settled";
  panel.append(element("div", "panel-h", "Report"));
  if (!present) {
    panel.append(element("p", "state-reason", live?.kind === "scout"
      ? "This scout is still writing its report. The deliverable becomes readable here once the work completes and its completion record is published."
      : "No report was retained for this task."));
    return panel;
  }
  void fetchTaskReport(taskId, reportKey);
  const entry = state.task.reports.get(taskId);
  // A revalidation behind a report already on the page is not a load: the body
  // stays rendered and the panel stays settled, so a history push that changed
  // nothing cannot blink the report out and back twice a minute.
  if (!entry || (entry.loading && !entry.payload)) {
    panel.dataset.loadState = "loading";
    panel.append(element("p", "state-reason", "Loading the report…"));
    return panel;
  }
  const payload = entry.payload;
  if (!payload || payload.schema !== "fm-dashboard-report.v1" || payload.present !== true) {
    panel.append(element("p", "state-reason", "The report could not be loaded."));
    return panel;
  }
  const rendered = renderMarkdown(payload.text);
  const body = element("div", "report");
  for (const noticeKind of rendered.notices) body.append(element("p", "state-reason", noticeSentence(noticeKind)));
  if (payload.truncated === true) body.append(element("p", "state-reason", `This report is longer than what is shown here; the beginning is rendered.`));
  for (const node of rendered.nodes) body.append(markdownDom(node));
  panel.append(body);
  return panel;
}

function activityPanel(taskId, task) {
  const panel = element("section", "panel");
  panel.dataset.loadState = "settled";
  panel.append(element("div", "panel-h", "Activity"));
  let entry = state.task.timelines.get(taskId);
  if (!entry || entry.routeEpoch !== state.routeEpoch) {
    void fetchTaskTimeline(taskId);
    entry = state.task.timelines.get(taskId);
  }
  if (!entry || (entry.loading && !entry.envelope)) {
    panel.dataset.loadState = "loading";
    panel.append(element("p", "state-reason", "Loading the recorded events…"));
    return panel;
  }
  // The durable backfill (/api/timeline reads the store) merged with the live
  // fleet tail, so an event that arrived after the backfill was fetched is on
  // the page before the next refetch lands. events.js owns the merge rule.
  const backfill = { task: taskId, events: Array.isArray(entry.envelope?.events) ? entry.envelope.events : [] };
  const merged = mergeTaskBackfill(Array.isArray(state.events?.events) ? state.events.events : [], backfill, taskId);
  const built = buildTimeline({ events: merged }, { task: taskId });
  const statusEnvelope = entry.failed
    ? { status: { ingestion: "unavailable", reason: "the stored task timeline could not be read" } }
    : entry.envelope;
  const status = timelineNotice(statusEnvelope, merged.length, built.rows.length);
  if (status.text) panel.append(notice(status.tone, null, status.text));
  if (!built.rows.length) {
    const source = task ? sourceNotice(task, statusEnvelope) : null;
    if (source) panel.append(element("p", "state-reason", source));
    return panel;
  }
  for (const row of built.rows) {
    const line = element("div", "tl-row");
    const clock = element("span", "tl-t", clockLabel(row.at));
    clock.title = row.at;
    const what = [typeLabel(row.type), row.tool, row.summary].filter(Boolean).join(" · ");
    line.append(clock, element("span", "tl-e", what));
    // An outcome-bearing row always shows its verdict, and an outcome nobody
    // observed is an explicit dashed unknown, never a bare row that reads as
    // fine beside a green one (events.js owns that normalization).
    if (row.outcome) line.append(element("span", `chip ${outcomeTone(row.outcome)}`, row.outcome));
    panel.append(line);
  }
  if (built.truncated) {
    panel.append(element("p", "state-reason", `Showing the newest ${built.rows.length} of ${built.total} recorded events.`));
  }
  return panel;
}

function prPanel(url, summary) {
  const panel = element("section", "panel");
  panel.append(element("div", "panel-h", "Pull request"));
  if (!url) {
    panel.append(element("p", "state-reason", "No pull request is linked to this task."));
    return panel;
  }
  const line = element("div", "pr-line");
  const link = element("a", "", url);
  link.href = safeUrl(url) || "#";
  link.target = "_blank";
  link.rel = "noopener";
  line.append(link);
  panel.append(line);
  if (summary) {
    const stateLine = element("div", "pr-line");
    stateLine.append(element("span", `t-${summary.tone === "unknown" ? "grey" : summary.tone}`, summary.label));
    if (summary.checks) stateLine.append(element("span", "", ` · checks ${summary.checks}`));
    panel.append(stateLine);
  }
  return panel;
}

function renderTask() {
  const taskId = state.route.taskId;
  const view = viewRoot("task");
  view.dataset.settled = "false";

  const back = element("button", "tk-back", "← Back");
  back.type = "button";
  back.addEventListener("click", () => window.history.back());
  view.append(back);

  const lookup = taskLookup(taskId);
  if (lookup.phase === "pending") {
    view.append(pageHead("Task", "Looking this task up…"));
    view.append(emptyState({ ring: true, big: "Reading the fleet records.", teach: "The live workers, the completed-work archive, and the queue are being read; this page fills in as each answers." }));
    return view;
  }
  if (lookup.phase === "unavailable") {
    const detail = lookup.sources.map((source) => `${source.name}${source.reason ? `: ${source.reason}` : ""}`).join("; ");
    view.append(pageHead("Task", "Task lookup unavailable"));
    view.append(notice("red", null, `This task cannot be ruled in or out because ${detail}.`));
    view.append(emptyState({ ring: true, big: "The available records are not conclusive.", teach: "Incomplete, failed, or stale evidence is not proof that a task does not exist. The dashboard keeps refreshing these reads." }));
    view.dataset.settled = "true";
    return view;
  }
  if (lookup.phase === "missing") {
    view.append(pageHead("Task", "No such task"));
    view.append(emptyState({
      ring: true,
      big: "This task is not in any record this dashboard reads.",
      teach: "It is not a live worker, not a completed record, and not a queued item. A task that was cleaned up before publishing a completion record leaves no trace to show.",
    }));
    view.dataset.settled = "true";
    return view;
  }

  const task = lookup.task;
  const title = task.title || taskId;
  view.append(pageHead("Task", null));
  const head = view.querySelector(".page-h");
  head.textContent = title;
  head.closest(".page-hd").append(element("div", "card-id", taskId));
  if (lookup.notice) view.append(notice("amber", null, lookup.notice));

  const strip = element("div", "kvstrip");
  strip.append(kvRow("Project", task.project ? label(task.project) : null));
  strip.append(kvRow("Kind", task.kind));
  strip.append(kvRow("Runtime · model", [task.harness, task.model].filter(Boolean).join(" · ") || null));
  strip.append(kvRow("Delivery", task.mode));
  if (task.age) strip.append(kvRow("Age", task.age));
  else if (task.completed) strip.append(kvRow("Completed", task.completed.slice(0, 10)));
  else if (task.raised) strip.append(kvRow("Raised", task.raised));
  view.append(strip);

  const grid = element("div", "tk-grid");
  const mainCol = element("div", "tkcol");
  const sideCol = element("div", "tkcol");

  const statePanel = element("section", "panel");
  statePanel.append(element("div", "panel-h", "Current state"));
  const statebar = element("div", "statebar");
  const stateWord = task.current.label;
  const stateTone = task.current.tone;
  const stateReason = task.current.reason;
  statebar.append(stateTone === "unknown" ? element("span", "ring") : dot(stateTone), element("span", `state-word t-${stateTone}`, stateWord));
  statePanel.append(statebar);
  statePanel.append(element("p", "state-reason", stateReason));

  const inboxItem = verdictFacts().inbox.items.find((item) => item.id === taskId);
  if (inboxItem) {
    const answer = element("button", "inline-link", "Answer in Needs you →");
    answer.type = "button";
    answer.addEventListener("click", () => { window.location.hash = hashFor(viewRoute("needs")); });
    statePanel.append(answer);
  }
  mainCol.append(statePanel);

  // /api/report serves the durable completion records, so the report panel
  // exists only for a task that has one. A live scout still writes its report
  // to the task's own directory, but that is not exposed over HTTP until the
  // completion record publishes it - saying so beats a panel that 404s.
  const report = reportPanel(taskId, task.reportPresent, task.source === "live" ? task : null, task.reportKey);
  mainCol.append(report);

  if (task.pr) sideCol.append(prPanel(task.pr.url, task.pr));

  const workItems = task.workItems;
  if (workItems.length) {
    const panel = element("section", "panel");
    panel.append(element("div", "panel-h", "Linked items"));
    for (const reference of workItems) {
      const row = element("div", "linkrow");
      row.append(dot("grey"), document.createTextNode(reference.forge ? `${reference.forge}: ` : ""));
      const label_ = reference.label || reference.url || "linked item";
      if (reference.url && safeUrl(reference.url)) {
        const link = element("a", "", label_);
        link.href = safeUrl(reference.url);
        link.target = "_blank";
        link.rel = "noopener";
        row.append(link);
      } else {
        row.append(document.createTextNode(label_));
      }
      panel.append(row);
    }
    sideCol.append(panel);
  }

  const activity = activityPanel(taskId, task.source === "live" ? task.raw : null);
  sideCol.append(activity);

  grid.append(mainCol, sideCol);
  view.append(grid);
  view.dataset.settled = String(report.dataset.loadState === "settled" && activity.dataset.loadState === "settled");
  return view;
}

// --- router mounting ----------------------------------------------------------

const VIEW_RENDERERS = {
  needs: renderNeeds,
  fleet: renderFleet,
  backlog: renderBacklog,
  history: renderHistory,
  knowledge: renderKnowledge,
  [TASK_VIEW]: renderTask,
};

function render() {
  const route = state.route;
  renderVerdict();
  publishStickyHeight();

  for (const [name, buttons] of ui.navButtons) {
    for (const button of buttons) {
      const active = route.view === name;
      button.classList.toggle("is-active", active);
      if (active) button.setAttribute("aria-current", "page");
      else button.removeAttribute("aria-current");
    }
  }

  const renderer = VIEW_RENDERERS[route.view] || renderNeeds;
  const fresh = renderer();
  stampControlCommit(fresh);
  // The entry animation belongs to arriving at a view, not to a data refresh:
  // every push re-renders, and cards that re-fade on each one read as flicker.
  // Tracked as data-view, because data-route names the navigation controls and
  // the container must never match a [data-route] selector.
  ui.view.classList.toggle("settled", ui.view.dataset.view === route.view);
  ui.view.dataset.view = route.view;
  const mounted = ui.view.firstElementChild;
  const currentControls = mounted ? persistentControlIds(mounted) : [];
  const freshControls = persistentControlIds(fresh);
  if (mounted?.id === fresh.id && currentControls.length && currentControls.length === freshControls.length && currentControls.every((id) => freshControls.includes(id))) {
    refreshMountedView(mounted, fresh);
  } else {
    ui.view.replaceChildren(fresh);
  }
}

function onRouteChange() {
  const route = parseHash(window.location.hash);
  if (route.view === state.route.view && route.taskId === state.route.taskId) return;
  state.route = route;
  state.routeEpoch += 1;
  if (route.view !== TASK_VIEW) window.scrollTo({ top: 0 });
  render();
}

// --- data plumbing -------------------------------------------------------------

async function fetchJson(url, schema) {
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) throw Object.assign(new Error(`HTTP ${response.status}`), { kind: "http_error" });
  const envelope = await response.json();
  if (schema && envelope.schema !== schema) throw Object.assign(new Error(`unsupported envelope ${envelope.schema}`), { kind: "unsupported_envelope" });
  return displaySafeEnvelope(envelope);
}

function unavailableEnvelope(schema, error) {
  return { schema, status: { phase: "unavailable", refreshing: false, stale: false, error: displayError(error, "server_unreachable") } };
}

async function fetchSnapshot() {
  try {
    const envelope = await fetchJson("/api/snapshot", "fm-dashboard-envelope.v1");
    state.envelope = envelope;
    announceNewItems(buildInbox(envelope.snapshot).items, Boolean(envelope.snapshot));
  } catch (error) {
    state.envelope = unavailableEnvelope("fm-dashboard-envelope.v1", error);
  }
  render();
}

// Every history read enters through here, so the epoch that a failed report
// read waits on cannot drift from the envelope it was derived against.
function adoptHistory(envelope) {
  state.history.envelope = envelope;
  state.history.epoch += 1;
}

async function fetchHistory() {
  try {
    adoptHistory(await fetchJson("/api/history", "fm-dashboard-history.v1"));
  } catch (error) {
    adoptHistory(unavailableEnvelope("fm-dashboard-history.v1", error));
  }
  render();
}

async function fetchBacklog() {
  try {
    state.backlog.envelope = await fetchJson("/api/backlog", "fm-dashboard-backlog.v1");
  } catch (error) {
    state.backlog.envelope = unavailableEnvelope("fm-dashboard-backlog.v1", error);
  }
  render();
}

async function fetchGBrainHealth() {
  try {
    state.gbrain.health = await fetchJson("/api/gbrain/health", "fm-gbrain-health.v1");
  } catch (error) {
    state.gbrain.health = unavailableEnvelope("fm-gbrain-health.v1", error);
  }
  render();
}

function connectEvents() {
  let events;
  try {
    events = new EventSource("/api/events");
  } catch {
    return;
  }
  events.addEventListener("snapshot", (event) => {
    try {
      const envelope = displaySafeEnvelope(JSON.parse(event.data));
      if (envelope.schema === "fm-dashboard-envelope.v1") {
        state.envelope = envelope;
        // A push that carried no snapshot saw nothing, so it must not become
        // the alert baseline (announceNewItems owns that rule).
        announceNewItems(buildInbox(envelope.snapshot).items, Boolean(envelope.snapshot));
        render();
      }
    } catch {}
  });
  events.addEventListener("history", (event) => {
    try {
      const envelope = displaySafeEnvelope(JSON.parse(event.data));
      if (envelope.schema === "fm-dashboard-history.v1") {
        adoptHistory(envelope);
        render();
      }
    } catch {}
  });
  events.addEventListener("backlog", (event) => {
    try {
      const envelope = displaySafeEnvelope(JSON.parse(event.data));
      if (envelope.schema === "fm-dashboard-backlog.v1") {
        state.backlog.envelope = envelope;
        render();
      }
    } catch {}
  });
  events.addEventListener("agent_events", (event) => {
    try {
      const envelope = displaySafeEnvelope(JSON.parse(event.data));
      if (envelope.schema === "fm-dashboard-events.v1") {
        state.events = envelope;
        for (const [taskId, entry] of state.task.timelines) {
          if (entry.loading) continue;
          const backfill = { task: taskId, events: Array.isArray(entry.envelope?.events) ? entry.envelope.events : [] };
          entry.envelope = {
            ...(entry.envelope || {}),
            task: taskId,
            status: envelope.status || entry.envelope?.status,
            instrumented_harnesses: envelope.instrumented_harnesses || entry.envelope?.instrumented_harnesses,
            events: mergeTaskBackfill(Array.isArray(envelope.events) ? envelope.events : [], backfill, taskId),
          };
          retryFailedTaskTimeline(taskId, entry, envelope);
        }
        if (state.route.view === TASK_VIEW) render();
      }
    } catch {}
  });
  events.addEventListener("gbrain_health", (event) => {
    try {
      const envelope = displaySafeEnvelope(JSON.parse(event.data));
      if (envelope.schema === "fm-gbrain-health.v1") {
        state.gbrain.health = envelope;
        render();
      }
    } catch {}
  });
}

// --- start ----------------------------------------------------------------------

window.addEventListener("hashchange", onRouteChange);
initializeTheme();
initializeNotifications();
render();
void fetchSnapshot();
void fetchHistory();
void fetchBacklog();
void fetchGBrainHealth();
connectEvents();
