import { buildHealth, buildInbox, formatAge } from "./inbox.js";

const ui = {
  signals: document.querySelector("#signals"),
  badges: document.querySelector("#badges"),
  navBadge: document.querySelector("#nav-badge"),
  healthStrip: document.querySelector("#health-strip"),
  inboxList: document.querySelector("#inbox-list"),
  notices: document.querySelector("#notice-region"),
  refreshNote: document.querySelector("#refresh-note"),
  filterForm: document.querySelector("#filter-form"),
  filterCount: document.querySelector("#filter-count"),
  clearFilters: document.querySelector("#clear-filters"),
  mateList: document.querySelector("#secondmate-list"),
  mateCount: document.querySelector("#secondmate-count"),
  kanban: document.querySelector("#kanban"),
  themeButtons: [document.querySelector("#theme-button"), document.querySelector("#phone-theme-button")],
  notifyButtons: [document.querySelector("#notify-button"), document.querySelector("#phone-notify-button")],
};

const columnLabels = {
  needs_decision: "Needs decision",
  blocked: "Blocked",
  parked: "Gate parked",
  failed: "Failed",
  review: "PR review",
  done: "Done",
  waiting: "Waiting",
  active: "Active",
  secondmate: "Secondmate",
  idle: "Idle",
};

const columnTones = {
  needs_decision: "amber",
  blocked: "red",
  parked: "amber",
  failed: "red",
  review: "green",
  done: "grey",
  waiting: "amber",
  active: "blue",
  secondmate: "blue",
  idle: "grey",
};

const badgeOrder = [
  ["decisions", "Decisions", "amber"],
  ["credentials", "Credentials", "amber"],
  ["blocked", "Blocked", "red"],
  ["failed", "Failing", "red"],
  ["merge_ready", "Merge ready", "green"],
  ["review_ready", "Review ready", "blue"],
  ["unknown", "PR unknown", "unknown"],
];

const state = {
  envelope: null,
  filters: { project: "", harness: "", model: "", kind: "", state: "" },
  eventSource: null,
  reconnectTimer: null,
  reconnectMs: 1_000,
  notifyEnabled: false,
  seenInboxIds: null,
};

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

function replaceChildren(parent, children) {
  parent.replaceChildren(...children.filter(Boolean));
}

function dot(tone) {
  return element("span", `dot ${tone || "grey"}`);
}

function titleFor(task) {
  return task?.backlog?.title || task?.id || "Untitled task";
}

function taskState(task) {
  return task?.card?.column || "";
}

function taskMatches(task) {
  return Object.entries(state.filters).every(([key, selected]) => {
    if (!selected) return true;
    const actual = key === "state" ? taskState(task) : String(task?.[key] || "");
    return actual === selected;
  });
}

function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  try { localStorage.setItem("fm-dashboard-theme", theme); } catch {}
  ui.themeButtons[0].textContent = theme === "dark" ? "Light mode" : "Dark mode";
  ui.themeButtons[1].setAttribute("aria-label", `Switch to ${theme === "dark" ? "light" : "dark"} mode`);
}

function toggleTheme() {
  setTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light");
}

function initializeTheme() {
  let saved = null;
  try { saved = localStorage.getItem("fm-dashboard-theme"); } catch {}
  const preferred = matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  setTheme(saved === "light" || saved === "dark" ? saved : preferred);
  for (const button of ui.themeButtons) button.addEventListener("click", toggleTheme);
}

// Notifications are entirely client-side: the server never learns that a
// browser wants them, and a denied or unsupported permission simply leaves the
// control off rather than degrading anything else on the page.
function notificationsSupported() {
  return typeof Notification === "function";
}

function paintNotifyButtons() {
  const supported = notificationsSupported();
  const label = !supported ? "Alerts unavailable" : state.notifyEnabled ? "Alerts on" : "Alerts off";
  ui.notifyButtons[0].textContent = label;
  ui.notifyButtons[0].disabled = !supported;
  for (const button of ui.notifyButtons) {
    button.setAttribute("aria-pressed", String(state.notifyEnabled));
    if (button !== ui.notifyButtons[0]) button.setAttribute("aria-label", `${label}. Toggle desktop alerts for new inbox items.`);
  }
  ui.notifyButtons[1].disabled = !supported;
  ui.notifyButtons[1].textContent = state.notifyEnabled ? "☀" : "☾";
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
  paintNotifyButtons();
}

function initializeNotifications() {
  let saved = null;
  try { saved = localStorage.getItem("fm-dashboard-alerts"); } catch {}
  state.notifyEnabled = saved === "on" && notificationsSupported() && Notification.permission === "granted";
  for (const button of ui.notifyButtons) button.addEventListener("click", () => void toggleNotifications());
  paintNotifyButtons();
}

function announceNewItems(items) {
  const ids = new Set(items.map((item) => item.id));
  if (state.seenInboxIds === null) {
    // The first render is the baseline; everything already waiting is not new.
    state.seenInboxIds = ids;
    return;
  }
  const fresh = items.filter((item) => !state.seenInboxIds.has(item.id));
  state.seenInboxIds = ids;
  if (!fresh.length || !state.notifyEnabled || !notificationsSupported() || Notification.permission !== "granted") return;
  for (const item of fresh.slice(0, 3)) {
    try {
      new Notification(`Firstmate: ${item.label}`, { body: `${item.title}\n${item.reasons[0].text}`, tag: `fm-inbox-${item.id}` });
    } catch {
      return;
    }
  }
  if (fresh.length > 3) {
    try {
      new Notification("Firstmate: more items need you", { body: `${fresh.length - 3} further inbox items appeared.`, tag: "fm-inbox-overflow" });
    } catch {}
  }
}

function renderSignals(health) {
  const overall = element("div", `signal overall ${health.overall.tone}`);
  overall.append(dot(health.overall.tone), element("span", "label", "FLEET"), element("span", "", health.overall.label));
  const chips = health.signals.map((signal) => {
    const item = element("div", "signal");
    item.title = `${signal.detail} ${signal.tooltip}`;
    item.append(dot(signal.tone));
    item.append(element("span", "label", signal.label.toUpperCase()));
    item.append(element("span", "", signal.value));
    return item;
  });
  replaceChildren(ui.signals, [overall, ...chips]);
}

function renderHealthStrip(health) {
  replaceChildren(ui.healthStrip, health.signals.map((signal) => {
    const card = element("div", `health-card ${signal.tone}`);
    card.title = signal.tooltip;
    const head = element("div", "health-head");
    head.append(dot(signal.tone), element("span", "label", signal.label.toUpperCase()));
    card.append(head);
    card.append(element("strong", "health-value", signal.value));
    card.append(element("p", "health-detail", signal.detail));
    return card;
  }));
}

function renderBadges(counts) {
  const chips = badgeOrder
    .filter(([key]) => counts[key] > 0)
    .map(([key, label, tone]) => {
      const badge = element("span", `badge ${tone}`);
      badge.append(element("strong", "", String(counts[key])), element("span", "", label));
      return badge;
    });
  if (!chips.length) chips.push(element("span", "badge quiet", "Nothing needs you"));
  replaceChildren(ui.badges, chips);
  ui.navBadge.textContent = String(counts.total);
  ui.navBadge.hidden = counts.total === 0;
}

function fieldChips(readiness) {
  const list = element("div", "pr-fields");
  for (const name of ["state", "review", "checks", "mergeable"]) {
    const value = readiness.fields[name];
    const chip = element("span", `pr-field ${value === "unknown" ? "unknown" : ""}`.trim());
    chip.append(element("span", "key", name), element("span", "value", value));
    list.append(chip);
  }
  return list;
}

function prPanel(readiness) {
  const panel = element("div", `pr-panel ${readiness.tone}`);
  const head = element("div", "pr-head");
  head.append(dot(readiness.tone), element("span", "label", readiness.label.toUpperCase()));
  const observed = readiness.freshness === "cached" && readiness.age_seconds !== null
    ? `observed ${formatAge(readiness.age_seconds)} ago`
    : "never observed";
  head.append(element("span", "pr-observed", observed));
  panel.append(head);
  panel.append(fieldChips(readiness));
  const link = element("a", "pr-link", readiness.url);
  link.href = readiness.url;
  link.target = "_blank";
  link.rel = "noreferrer";
  panel.append(link);
  for (const caveat of readiness.caveats) panel.append(element("p", "pr-caveat", `Caveat: ${caveat}`));
  return panel;
}

function inboxCard(item) {
  const card = element("article", `inbox-card ${item.tone}`);
  card.setAttribute("aria-label", `${item.label}: ${item.title}`);

  const head = element("div", "inbox-head");
  head.append(dot(item.tone));
  head.append(element("span", "pill", item.label));
  if (item.project) head.append(element("span", "pill project-pill", item.project));
  const age = element("span", `age ${item.age_known ? "" : "unknown"}`.trim(),
    item.age_known ? `${formatAge(item.age_seconds)} · ${item.age_source}` : "age unknown");
  head.append(age);
  card.append(head);

  card.append(element("h3", "", item.title));
  card.append(element("div", "task-id", item.task_id ? item.task_id : `backlog item ${item.id}`));

  const reasons = element("div", "reasons");
  for (const reason of item.reasons) {
    const row = element("div", `reason ${reason.tone}`);
    const label = element("div", "reason-label");
    label.append(dot(reason.tone), element("span", "", reason.label));
    if (reason.key) label.append(element("code", "reason-key", reason.key));
    label.append(element("span", "reason-source", reason.source));
    row.append(label);
    // Full text, never truncated: a half-shown decision is a decision the
    // captain has to go and look up somewhere else.
    row.append(element("p", "reason-text", reason.text));
    reasons.append(row);
  }
  card.append(reasons);

  if (item.pr) card.append(prPanel(item.pr));

  for (const reference of item.work_items) {
    const link = workItemLink(reference);
    if (link) card.append(link);
  }
  if (item.action) {
    const action = element("div", "card-action");
    action.append(element("span", "label", "ACTION"), element("code", "", item.action));
    card.append(action);
  }
  return card;
}

function renderInbox(inbox, envelope) {
  if (!inbox.items.length) {
    const empty = element("div", "inbox-empty");
    const waiting = envelope?.status?.phase !== "ready" && envelope?.status?.phase !== "last_good";
    empty.append(dot(waiting ? "amber" : "green"));
    const copy = element("div");
    copy.append(element("strong", "", waiting ? "No inbox yet" : "Nothing needs you"));
    copy.append(element("p", "", waiting
      ? "The captain inbox appears once a fleet snapshot is available. Until then this list is empty because nothing has been read, not because nothing is waiting."
      : "No open decision, blocker, failure, credential request, or review-ready pull request is outstanding in this home."));
    empty.append(copy);
    replaceChildren(ui.inboxList, [empty]);
    return;
  }
  replaceChildren(ui.inboxList, inbox.items.map(inboxCard));
}

function renderNotices(envelope) {
  const status = envelope?.status;
  if (!status) {
    replaceChildren(ui.notices, []);
    return;
  }
  if (status.phase === "first_run") {
    const notice = element("div", "notice");
    notice.append(dot("amber"), element("div", "", "Waiting for the first fleet snapshot. The inbox and board will populate automatically."));
    replaceChildren(ui.notices, [notice]);
    return;
  }
  if (status.error) {
    const notice = element("div", `notice ${envelope.snapshot ? "" : "error"}`.trim());
    const copy = element("div");
    const heading = status.stale ? "Showing the last known good snapshot" : "Fleet snapshot unavailable";
    copy.append(element("strong", "", heading));
    copy.append(document.createTextNode(`${status.error.kind}: ${status.error.message}. Retrying automatically.`));
    if (status.error.stderr) copy.append(element("code", "", ` ${status.error.stderr}`));
    notice.append(dot(status.stale ? "amber" : "red"), copy);
    replaceChildren(ui.notices, [notice]);
    return;
  }
  if (status.stale) {
    const notice = element("div", "notice");
    notice.append(dot("amber"), element("div", "", `Snapshot is ${formatAge(status.last_success_age_seconds)} old. Liveness and ages are unverified until refresh recovers.`));
    replaceChildren(ui.notices, [notice]);
    return;
  }
  replaceChildren(ui.notices, []);
}

function valuesFor(tasks, key) {
  return [...new Set(tasks.map((task) => key === "state" ? taskState(task) : String(task?.[key] || "")).filter(Boolean))]
    .sort((left, right) => left.localeCompare(right));
}

function syncSelect(select, values, key) {
  const selected = state.filters[key];
  const first = select.options[0];
  replaceChildren(select, [first, ...values.map((value) => {
    const option = element("option", "", key === "state" ? (columnLabels[value] || value) : value);
    option.value = value;
    return option;
  })]);
  select.value = values.includes(selected) ? selected : "";
  if (!values.includes(selected)) state.filters[key] = "";
}

function renderFilters(tasks) {
  for (const key of Object.keys(state.filters)) {
    syncSelect(ui.filterForm.elements[key], valuesFor(tasks, key), key);
  }
  const count = Object.values(state.filters).filter(Boolean).length;
  ui.filterCount.textContent = count ? `(${count} active)` : "";
}

function endpointLiveness(task) {
  const status = task?.endpoint?.status;
  if (status === "alive") return "alive";
  if (status === "dead" || status === "absent") return "dead";
  if (status === "unknown") return "unknown";
  return task?.endpoint?.exists === false ? "dead" : "unknown";
}

function endpointTone(task) {
  const liveness = endpointLiveness(task);
  return liveness === "alive" ? "green" : liveness === "dead" ? "red" : "grey";
}

function endpointLabel(task) {
  const status = task?.endpoint?.status;
  if (["alive", "dead", "absent", "unknown"].includes(status)) return status;
  if (task?.endpoint?.exists === true) return "present";
  if (task?.endpoint?.exists === false) return "absent";
  return "unknown";
}

function actionMetadata(task, className = "card-action") {
  const action = task?.card?.action;
  if (typeof action !== "string" || !action) return null;
  const metadata = element("div", className);
  metadata.append(element("span", "label", "ACTION"), element("code", "", action));
  return metadata;
}

function workItemLabel(reference) {
  const number = reference?.number ? `#${reference.number}` : "";
  return [reference?.path || reference?.repo || reference?.owner, number].filter(Boolean).join("");
}

function workItemLink(reference) {
  if (!reference?.url) return null;
  const liveState = reference.forge !== "unknown" && ["open", "closed", "merged"].includes(reference?.enrichment?.state);
  const link = element("a", `work-link ${liveState ? "" : "plain"}`.trim());
  link.href = reference.url;
  link.target = "_blank";
  link.rel = "noreferrer";
  link.title = reference?.enrichment?.title || reference.url;
  link.append(element("span", "host", reference.host || reference.forge || "link"));
  link.append(element("span", "path", workItemLabel(reference) || reference.url));
  if (liveState) link.append(element("span", "item-state", reference.enrichment.state));
  return link;
}

function taskCard(task) {
  const column = taskState(task);
  const card = element("article", `card ${column}`);
  card.setAttribute("aria-label", `${task.id}: ${titleFor(task)}`);
  const head = element("div", "card-head");
  head.append(element("span", "pill", `${task.kind || "task"}`));
  if (task.project) head.append(element("span", "pill project-pill", task.project));
  head.append(dot(endpointTone(task)));
  head.append(element("span", "age", `${formatAge(task?.paths?.status_log?.last_event_age_seconds)} ago`));
  card.append(head);
  card.append(element("div", "task-id", task.id));
  card.append(element("h3", "", titleFor(task)));

  const dispatch = [task.harness, task.model, task.effort].filter(Boolean).join(" · ");
  card.append(element("div", "dispatch", dispatch || "dispatch metadata unavailable"));
  const detail = task?.current_state?.detail || task?.current_state?.state || task?.card?.reason || "No state detail";
  card.append(element("div", "detail", detail));
  const action = actionMetadata(task);
  if (action) card.append(action);

  const endpoint = element("div", "endpoint");
  endpoint.append(dot(endpointTone(task)));
  endpoint.append(document.createTextNode(`endpoint ${endpointLabel(task)}`));
  card.append(endpoint);

  if (task?.pr?.url) {
    const link = element("a", "pr-link", task.pr.url);
    link.href = task.pr.url;
    link.target = "_blank";
    link.rel = "noreferrer";
    card.append(link);
  }

  const references = Array.isArray(task.work_items) ? task.work_items : [];
  for (const reference of references) {
    const link = workItemLink(reference);
    if (link) card.append(link);
  }
  return card;
}

function renderSecondmates(tasks) {
  const mates = tasks.filter((task) => task.kind === "secondmate" && taskMatches(task));
  ui.mateCount.textContent = String(mates.length);
  if (!mates.length) {
    replaceChildren(ui.mateList, [element("div", "empty-inline", "None registered in this view")]);
    return;
  }
  replaceChildren(ui.mateList, mates.map((task) => {
    const mate = element("article", "mate");
    mate.append(dot(endpointTone(task)));
    mate.append(element("strong", "", task.id));
    mate.append(element("span", "pill", columnLabels[taskState(task)] || taskState(task) || "unknown"));
    const detail = [task.harness, task.model, task.effort, task.current_state?.detail].filter(Boolean).join(" · ");
    mate.append(element("small", "", detail || "No current detail"));
    const action = actionMetadata(task, "mate-action");
    if (action) mate.append(action);
    return mate;
  }));
}

function emptyBoard(phase) {
  const panel = element("div", "empty-board");
  panel.append(dot(phase === "first_run" || phase === "unavailable" ? "amber" : "green"));
  panel.append(element("h2", "", phase === "first_run" ? "Waiting for the first snapshot" : phase === "unavailable" ? "Fleet unavailable" : "Fleet is empty"));
  panel.append(element("p", "", phase === "first_run"
    ? "The snapshot command has not completed yet. Tasks will appear here without a page reload."
    : phase === "unavailable"
      ? "The server cannot produce a valid fleet snapshot yet. Its error is shown above and refreshes continue automatically."
      : "No task metadata is present. The board is read-only and will show work as soon as Firstmate starts it."));
  return panel;
}

function renderBoard(snapshot, envelope) {
  const allTasks = Array.isArray(snapshot?.tasks) ? snapshot.tasks : [];
  renderFilters(allTasks);
  renderSecondmates(allTasks);
  const mainTasks = allTasks.filter((task) => task.kind !== "secondmate" && taskMatches(task));
  const precedence = Array.isArray(snapshot?.card_precedence) ? snapshot.card_precedence.filter((column) => column !== "secondmate") : [];
  if (!snapshot || (!allTasks.length && envelope?.status?.phase !== "ready" && envelope?.status?.phase !== "last_good")) {
    replaceChildren(ui.kanban, [emptyBoard(envelope?.status?.phase)]);
    return;
  }
  if (!allTasks.length) {
    replaceChildren(ui.kanban, [emptyBoard("ready")]);
    return;
  }
  replaceChildren(ui.kanban, precedence.map((columnName) => {
    const tasks = mainTasks.filter((task) => taskState(task) === columnName);
    const section = element("section", `column ${["needs_decision", "blocked", "failed"].includes(columnName) ? "attention" : ""}`.trim());
    section.setAttribute("aria-labelledby", `column-${columnName}`);
    const head = element("div", "column-head");
    head.append(dot(columnTones[columnName]));
    const title = element("h2", "", columnLabels[columnName] || columnName);
    title.id = `column-${columnName}`;
    head.append(title, element("span", "count", String(tasks.length)));
    section.append(head);
    if (tasks.length) section.append(...tasks.map(taskCard));
    else section.append(element("div", "empty-column", mainTasks.length ? "Nothing here" : "No matching tasks"));
    return section;
  }));
}

function render(envelope) {
  state.envelope = envelope;
  const snapshot = envelope?.snapshot;
  const health = buildHealth(snapshot, envelope);
  const inbox = buildInbox(snapshot);
  renderSignals(health);
  renderHealthStrip(health);
  renderBadges(inbox.counts);
  renderInbox(inbox, envelope);
  announceNewItems(inbox.items);
  renderNotices(envelope);
  const status = envelope?.status;
  ui.refreshNote.textContent = status?.last_success_at
    ? `${status.refreshing ? "Refreshing · " : ""}updated ${formatAge(status.last_success_age_seconds)} ago`
    : status?.refreshing ? "Taking the first snapshot" : "Waiting for the first snapshot";
  renderBoard(snapshot, envelope);
}

async function fetchSnapshot() {
  try {
    const response = await fetch("/api/snapshot", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const envelope = await response.json();
    if (envelope.schema !== "fm-dashboard-envelope.v1") throw new Error("unsupported dashboard envelope");
    render(envelope);
  } catch (error) {
    render({
      schema: "fm-dashboard-envelope.v1",
      status: { phase: "unavailable", stale: false, error: { kind: "server_unreachable", message: error.message } },
      snapshot: null,
    });
  }
}

function connectEvents() {
  clearTimeout(state.reconnectTimer);
  state.eventSource?.close();
  const source = new EventSource("/api/events");
  state.eventSource = source;
  source.addEventListener("open", () => { state.reconnectMs = 1_000; });
  source.addEventListener("snapshot", (event) => {
    try {
      const envelope = JSON.parse(event.data);
      if (envelope.schema === "fm-dashboard-envelope.v1") render(envelope);
    } catch {
      source.close();
    }
  });
  source.addEventListener("error", () => {
    source.close();
    const delay = state.reconnectMs;
    state.reconnectMs = Math.min(state.reconnectMs * 2, 30_000);
    state.reconnectTimer = setTimeout(connectEvents, delay + Math.floor(Math.random() * 250));
  });
}

ui.filterForm.addEventListener("change", () => {
  for (const key of Object.keys(state.filters)) state.filters[key] = ui.filterForm.elements[key].value;
  renderBoard(state.envelope?.snapshot, state.envelope);
});

ui.clearFilters.addEventListener("click", () => {
  for (const key of Object.keys(state.filters)) state.filters[key] = "";
  renderBoard(state.envelope?.snapshot, state.envelope);
});

initializeTheme();
initializeNotifications();
void fetchSnapshot();
connectEvents();
