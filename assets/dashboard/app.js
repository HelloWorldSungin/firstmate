import { buildHealth, buildInbox, formatAge } from "./inbox.js";
import { buildHistory, formatDuration, formatTokens, HISTORY_LIMITS } from "./history.js";
import { buildTimeline, clockLabel, outcomeTone, sourceNotice, timelineNotice, typeLabel, typeTone } from "./events.js";
import { MARKDOWN_CLASSES, MARKDOWN_TAGS, noticeSentence, renderMarkdown, safeUrl } from "./markdown.js";

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
  historyForm: document.querySelector("#history-form"),
  historyFilterCount: document.querySelector("#history-filter-count"),
  historyClear: document.querySelector("#history-clear"),
  historyNote: document.querySelector("#history-note"),
  historyWarnings: document.querySelector("#history-warnings"),
  historySummary: document.querySelector("#history-summary"),
  historyList: document.querySelector("#history-list"),
  historyPager: document.querySelector("#history-pager"),
  activityForm: document.querySelector("#activity-form"),
  activityFilterCount: document.querySelector("#activity-filter-count"),
  activityClear: document.querySelector("#activity-clear"),
  activityNote: document.querySelector("#activity-note"),
  activityNotices: document.querySelector("#activity-notices"),
  activityList: document.querySelector("#activity-list"),
  reportDialog: document.querySelector("#report-dialog"),
  reportTask: document.querySelector("#report-task"),
  reportTitle: document.querySelector("#report-title"),
  reportNotices: document.querySelector("#report-notices"),
  reportBody: document.querySelector("#report-body"),
  reportClose: document.querySelector("#report-close"),
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
  ["failed", "Needs attention", "red"],
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
  history: {
    envelope: null,
    filters: { query: "", project: "", harness: "", model: "", kind: "", outcome: "", from: "", to: "" },
    page: 0,
    pageSize: HISTORY_LIMITS.defaultPageSize,
  },
  activity: {
    envelope: null,
    filters: { task: "", harness: "", type: "" },
  },
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
  ui.notifyButtons[1].textContent = state.notifyEnabled ? "🔔" : "🔕";
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

function announceNewItems(items, observed) {
  // A render that carried no snapshot saw nothing, so it cannot be the
  // baseline: treating its empty inbox as "what was already there" would make
  // every waiting item alert as new the moment the first snapshot arrives.
  if (!observed) return;
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

  // The per-agent timeline is one click from the card it belongs to, because a
  // fleet-wide stream is where you look afterwards and a single agent's own
  // sequence is what you want while it is working.
  const timeline = element("button", "card-timeline", "Timeline");
  timeline.type = "button";
  timeline.addEventListener("click", () => showTaskTimeline(task.id));
  card.append(timeline);
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

// ---------------------------------------------------------------------------
// Completed-work history
// ---------------------------------------------------------------------------

// The only path from report text to the page. Every node is built with
// createElement and createTextNode against markdown.js's tag allowlist, the
// class name must be one of its closed vocabulary, and `href` is re-validated
// here even though the parser already applied the same policy. No other
// attribute is ever set, so an `onerror` or `style` carried by a crafted node
// cannot reach the DOM. There is no innerHTML on this path by construction.
// --- activity -------------------------------------------------------------
//
// Every value below reaches the page through textContent. The server already
// refuses anything that is not an allowlisted token, so this is the second of
// two independent reasons a stored event can never become markup.

function activityRow(row) {
  const item = element("li", "activity-row");
  item.title = row.at;
  item.append(element("span", "activity-time", clockLabel(row.at)));

  const body = element("div", "activity-body");
  const head = element("div", "activity-head");
  head.append(dot(typeTone(row.type)));
  head.append(element("strong", "", typeLabel(row.type)));
  if (row.tool) head.append(element("span", "activity-tool", row.tool));
  if (row.outcome) {
    const outcome = element("span", `chip ${outcomeTone(row.outcome)}`, row.outcome);
    head.append(outcome);
  }
  body.append(head);

  const meta = [row.task, row.harness].filter(Boolean).join(" · ");
  if (meta) body.append(element("div", "activity-meta", meta));
  if (row.summary) body.append(element("div", "activity-summary", row.summary));
  item.append(body);
  return item;
}

function syncActivitySelect(key, values) {
  const select = ui.activityForm.elements[key];
  const selected = state.activity.filters[key];
  const first = select.options[0];
  replaceChildren(select, [first, ...values.map((value) => {
    const option = element("option", "", key === "type" ? typeLabel(value) : value);
    option.value = value;
    return option;
  })]);
  // A filter whose value is no longer in the stream is kept in the list rather
  // than silently cleared, so a reader watching one agent does not get pulled
  // back to the whole fleet the moment that agent goes quiet.
  if (selected && !values.includes(selected)) {
    const option = element("option", "", key === "type" ? typeLabel(selected) : selected);
    option.value = selected;
    select.append(option);
  }
  select.value = selected;
}

function renderActivity() {
  const envelope = state.activity.envelope;
  const view = buildTimeline(envelope, state.activity.filters);
  for (const key of Object.keys(state.activity.filters)) syncActivitySelect(key, view.choices[key]);
  const active = Object.values(state.activity.filters).filter(Boolean).length;
  ui.activityFilterCount.textContent = active ? `(${active} active)` : "";

  const notices = [];
  const streamCount = Array.isArray(envelope?.events) ? envelope.events.length : 0;
  const notice = timelineNotice(envelope, streamCount, view.total);
  if (notice.text) notices.push(historyWarning(notice.tone, "", notice.text));
  if (view.truncated) {
    notices.push(historyWarning("amber", "Showing the most recent events only",
      ` ${view.total} events match and the newest ${view.rows.length} are drawn.`));
  }
  const selected = state.activity.filters.task;
  if (selected) {
    const task = (state.envelope?.snapshot?.tasks || []).find((entry) => entry?.id === selected);
    const gap = sourceNotice(task, envelope);
    if (gap) notices.push(historyWarning("amber", "", gap));
  }
  replaceChildren(ui.activityNotices, notices);
  replaceChildren(ui.activityList, view.rows.map(activityRow));

  // Same shape as every other refresh note on the page: a relative age, not a
  // raw stamp. The exact instant stays on each row's own title.
  const newest = view.rows[0]?.epoch;
  ui.activityNote.textContent = newest
    ? `${view.total} event${view.total === 1 ? "" : "s"} · newest ${formatAge(Math.max(0, Math.floor(Date.now() / 1000) - newest))} ago`
    : "No events to show";
}

function markdownDom(node) {
  if (typeof node?.text === "string") return document.createTextNode(node.text);
  if (!node || !MARKDOWN_TAGS.has(node.tag)) return document.createTextNode("");
  const el = document.createElement(node.tag);
  if (typeof node.className === "string" && MARKDOWN_CLASSES.has(node.className)) el.className = node.className;
  if (node.tag === "a") {
    const href = safeUrl(node.href);
    if (!href) return document.createTextNode(plainText(node));
    el.setAttribute("href", href);
    el.setAttribute("target", "_blank");
    el.setAttribute("rel", "noreferrer noopener");
  }
  for (const child of Array.isArray(node.children) ? node.children : []) el.append(markdownDom(child));
  return el;
}

function plainText(node) {
  if (typeof node?.text === "string") return node.text;
  return (Array.isArray(node?.children) ? node.children : []).map(plainText).join("");
}

function ageSince(millis) {
  if (typeof millis !== "number") return null;
  return Math.max(0, Math.floor((Date.now() - millis) / 1000));
}

function historyWarning(tone, heading, detail) {
  const notice = element("div", `notice ${tone === "red" ? "error" : ""}`.trim());
  const copy = element("div");
  copy.append(element("strong", "", heading));
  copy.append(document.createTextNode(detail));
  notice.append(dot(tone), copy);
  return notice;
}

function renderHistoryWarnings(view, envelope) {
  const notices = [];
  const status = envelope?.status;
  if (status?.error) {
    notices.push(historyWarning(envelope?.history ? "amber" : "red",
      envelope?.history ? "Showing the last completed-work records that could be read" : "Completed-work history unavailable",
      ` ${status.error.kind}: ${status.error.message}. Retrying automatically.`));
  }
  if (view.truncated) {
    notices.push(historyWarning("amber", "More completed work exists than is shown",
      ` This view reads the most recent ${envelope?.config?.record_limit ?? "bounded set of"} completion records; ${view.record_total ?? "more"} are stored. Narrow the filters or raise the record limit to see older work.`));
  }
  if (view.malformed.length) {
    const notice = element("div", "notice");
    const copy = element("div");
    copy.append(element("strong", "", `${view.malformed.length} completion record${view.malformed.length === 1 ? "" : "s"} could not be read`));
    copy.append(document.createTextNode(" These tasks completed but their durable records are unusable, so they are missing from the list below rather than absent from history."));
    const list = element("ul", "malformed-list");
    for (const entry of view.malformed) {
      const item = element("li");
      item.append(element("code", "", entry.id));
      item.append(document.createTextNode(` ${entry.explanation}`));
      if (entry.path) item.append(element("code", "quiet-path", entry.path));
      list.append(item);
    }
    copy.append(list);
    notice.append(dot("amber"), copy);
    notices.push(notice);
  }
  replaceChildren(ui.historyWarnings, notices);
}

function usagePanel(row) {
  const panel = element("div", `usage-panel ${row.usage.available ? "" : "unknown"}`.trim());
  panel.append(element("span", "label", "USAGE"));
  if (!row.usage.available) {
    // Never a blank cell and never a zero: "unavailable" and "nothing happened"
    // are different facts.
    panel.append(element("span", "usage-total", "unavailable"));
    panel.append(element("span", "usage-reason", row.usage.reason));
    return panel;
  }
  panel.append(element("span", "usage-total", `${formatTokens(row.usage.totals.total_tokens)} tokens`));
  const parts = [
    ["in", row.usage.totals.input_tokens],
    ["out", row.usage.totals.output_tokens],
    ["cache read", row.usage.totals.cache_read_tokens],
    ["reasoning", row.usage.totals.reasoning_tokens],
  ].filter(([, value]) => typeof value === "number");
  for (const [name, value] of parts) {
    const chip = element("span", "usage-part");
    chip.append(element("span", "key", name), element("span", "value", formatTokens(value)));
    panel.append(chip);
  }
  if (row.usage.cost) {
    panel.append(element("span", "usage-part", `≈ ${row.usage.cost.estimated.toFixed(2)} ${row.usage.cost.currency || ""}`.trim()));
  }
  return panel;
}

function historyPrPanel(row) {
  const panel = element("div", `pr-panel ${row.pr.tone}`);
  const head = element("div", "pr-head");
  head.append(dot(row.pr.tone), element("span", "label", row.pr.state.toUpperCase()));
  head.append(element("span", "pr-observed", row.pr.observed
    ? `recorded ${row.pr.observed_at}`
    : "no status was recorded at completion"));
  panel.append(head);
  const fields = element("div", "pr-fields");
  for (const field of row.pr.fields) {
    const chip = element("span", `pr-field ${field.value === "unknown" ? "unknown" : ""}`.trim());
    chip.append(element("span", "key", field.name), element("span", "value", field.value));
    fields.append(chip);
  }
  panel.append(fields);
  // Always the complete https URL, never a bare number.
  const link = element("a", "pr-link", row.pr.url);
  link.href = row.pr.url;
  link.target = "_blank";
  link.rel = "noreferrer";
  panel.append(link);
  return panel;
}

function historyCard(row) {
  const card = element("article", `history-card ${row.outcome.tone}`);
  card.setAttribute("aria-label", `${row.outcome.label}: ${row.title || row.id}`);

  const head = element("div", "card-head");
  head.append(dot(row.outcome.tone));
  head.append(element("span", "pill", row.outcome.label));
  head.append(element("span", "pill", row.kind));
  if (row.project) head.append(element("span", "pill project-pill", row.project));
  const age = ageSince(row.completed_millis);
  head.append(element("span", "age", row.timestamps.completed
    ? `${row.timestamps.completed}${age === null ? "" : ` · ${formatAge(age)} ago`}`
    : "completion time unknown"));
  card.append(head);

  card.append(element("div", "task-id", row.id));
  card.append(element("h3", "", row.title || "No recorded title"));

  const dispatch = [row.harness, row.model, row.effort].filter(Boolean).join(" · ");
  card.append(element("div", "dispatch", dispatch || "dispatch metadata unavailable"));

  const meta = element("div", "history-meta");
  meta.append(element("span", "", `took ${formatDuration(row.duration)}`));
  if (row.mode) meta.append(element("span", "", `delivery ${row.mode}`));
  if (row.yolo) meta.append(element("span", "", `autonomy ${row.yolo}`));
  if (row.outcome.forced) meta.append(element("span", "warn", "cleaned up with unlanded work discarded"));
  if (row.outcome.state === "unknown") meta.append(element("span", "warn", `final result not recorded (${row.outcome.source})`));
  card.append(meta);

  if (row.outcome.detail) card.append(element("div", "detail", row.outcome.detail));

  if (row.pr.present) card.append(historyPrPanel(row));

  for (const reference of row.work_items) {
    const link = workItemLink(reference);
    if (link) card.append(link);
  }

  card.append(usagePanel(row));

  const actions = element("div", "history-actions");
  if (row.report.present) {
    const button = element("button", "report-button", "Read report");
    button.type = "button";
    button.addEventListener("click", () => void openReport(row));
    actions.append(button);
  } else if (row.kind === "scout") {
    actions.append(element("span", "quiet", "No report was retained for this investigation"));
  }
  if (row.gbrain.status === "captured") actions.append(element("span", "pill quiet", "captured for search"));
  card.append(actions);
  return card;
}

function renderHistoryPager(view) {
  if (view.page.pages <= 1) {
    replaceChildren(ui.historyPager, []);
    return;
  }
  const previous = element("button", "pager-button", "Newer");
  previous.type = "button";
  previous.disabled = view.page.index === 0;
  previous.addEventListener("click", () => { state.history.page = view.page.index - 1; renderHistory(); });
  const next = element("button", "pager-button", "Older");
  next.type = "button";
  next.disabled = view.page.index >= view.page.pages - 1;
  next.addEventListener("click", () => { state.history.page = view.page.index + 1; renderHistory(); });
  replaceChildren(ui.historyPager, [
    previous,
    element("span", "pager-label", `Page ${view.page.index + 1} of ${view.page.pages}`),
    next,
  ]);
}

function renderHistoryFilters(view) {
  for (const key of ["project", "harness", "model", "kind", "outcome"]) {
    const select = ui.historyForm.elements[key];
    const values = view.facets[key];
    // buildHistory has already dropped a filter whose value left the facets, so
    // the control shows exactly what the list below it was built from.
    const selected = view.filters[key];
    state.history.filters[key] = selected;
    const first = select.options[0];
    replaceChildren(select, [first, ...values.map((value) => {
      const option = element("option", "", value);
      option.value = value;
      return option;
    })]);
    select.value = selected;
  }
  const count = Object.values(view.filters).filter(Boolean).length;
  ui.historyFilterCount.textContent = count ? `(${count} active)` : "";
}

function renderHistory() {
  const envelope = state.history.envelope;
  const view = buildHistory(envelope, { ...state.history.filters, page: state.history.page, pageSize: state.history.pageSize });
  state.history.page = view.page.index;
  renderHistoryFilters(view);
  renderHistoryWarnings(view, envelope);

  const status = envelope?.status;
  ui.historyNote.textContent = status?.last_success_at
    ? `${status.refreshing ? "Refreshing · " : ""}read ${formatAge(status.last_success_age_seconds)} ago`
    : status?.refreshing ? "Taking the first history read" : "Waiting for the first history read";

  const summary = element("div", "summary-line");
  if (view.page.matched) {
    summary.append(element("strong", "", `${view.page.first}-${view.page.last} of ${view.page.matched}`));
    summary.append(document.createTextNode(view.page.matched === view.page.total
      ? " completed records"
      : ` completed records matching, from ${view.page.total} read`));
  } else {
    summary.append(element("strong", "", "No matching completed records"));
  }
  if (view.usage.available) summary.append(element("span", "quiet", "token usage attributed where collected"));
  else summary.append(element("span", "quiet", `token usage unavailable: ${view.usage.reason || "not collected"}`));
  if (view.semantic_search.captured_records) {
    summary.append(element("span", "quiet", `${view.semantic_search.captured_records} report${view.semantic_search.captured_records === 1 ? "" : "s"} captured for semantic search, which this view does not yet offer`));
  }
  replaceChildren(ui.historySummary, [summary]);

  if (!view.page.matched) {
    const empty = element("div", "inbox-empty");
    const waiting = !envelope?.history;
    empty.append(dot(waiting ? "amber" : "green"));
    const copy = element("div");
    copy.append(element("strong", "", waiting ? "No history yet" : view.empty ? "Nothing has completed in this home" : "Nothing matches these filters"));
    copy.append(element("p", "", waiting
      ? "Completed work appears once the durable completion records have been read. Until then this list is empty because nothing has been read, not because nothing has finished."
      : view.empty
        ? "No task has published a completion record here yet. Completed work stays listed after cleanup and after the recent-work list is pruned."
        : "Clear or widen the filters to see the rest of the retained history."));
    empty.append(copy);
    replaceChildren(ui.historyList, [empty]);
  } else {
    replaceChildren(ui.historyList, view.rows.map(historyCard));
  }
  renderHistoryPager(view);
}

function reportNotice(tone, message) {
  const notice = element("div", `notice ${tone === "red" ? "error" : ""}`.trim());
  notice.append(dot(tone), element("div", "", message));
  return notice;
}

const REPORT_FAILURES = {
  invalid_task_id: "That task name is not one this dashboard will look up.",
  history_unavailable: "The completed-work records have not been read yet, so the report cannot be located.",
  unknown_task: "This task is no longer in the completed-work records that were read.",
  no_retained_report: "This task's completion record says no report was retained.",
  report_missing: "The completion record says a report was retained, but the file is missing or is no longer a plain file.",
};

async function openReport(row) {
  ui.reportTask.textContent = `${row.id}${row.project ? ` · ${row.project}` : ""}`;
  ui.reportTitle.textContent = row.title || row.id;
  replaceChildren(ui.reportNotices, [reportNotice("amber", "Loading the report.")]);
  replaceChildren(ui.reportBody, []);
  if (typeof ui.reportDialog.showModal === "function") ui.reportDialog.showModal();
  else ui.reportDialog.setAttribute("open", "");

  let payload;
  try {
    const response = await fetch(`/api/report?task=${encodeURIComponent(row.id)}`, { cache: "no-store" });
    payload = await response.json();
  } catch (error) {
    replaceChildren(ui.reportNotices, [reportNotice("red", `The report could not be loaded: ${error.message}`)]);
    return;
  }
  if (!payload || payload.schema !== "fm-dashboard-report.v1" || payload.present !== true) {
    const reason = REPORT_FAILURES[payload?.reason] || "The report could not be loaded.";
    const notices = [reportNotice("red", reason)];
    if (payload?.recorded_path) notices.push(reportNotice("amber", `The completion record points at ${payload.recorded_path}.`));
    replaceChildren(ui.reportNotices, notices);
    return;
  }

  const rendered = renderMarkdown(payload.text);
  const notices = [];
  if (payload.truncated) {
    notices.push(reportNotice("amber",
      `This report is ${payload.bytes} bytes and only the first ${payload.max_bytes} are shown. The full file is at ${payload.recorded_path || "its recorded path"}.`));
  }
  for (const notice of rendered.notices) notices.push(reportNotice("amber", noticeSentence(notice)));
  replaceChildren(ui.reportNotices, notices);
  replaceChildren(ui.reportBody, rendered.nodes.map(markdownDom));
}

function closeReport() {
  if (typeof ui.reportDialog.close === "function") ui.reportDialog.close();
  else ui.reportDialog.removeAttribute("open");
  replaceChildren(ui.reportBody, []);
  replaceChildren(ui.reportNotices, []);
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
  announceNewItems(inbox.items, Boolean(snapshot));
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

function renderHistoryEnvelope(envelope) {
  state.history.envelope = envelope;
  renderHistory();
}

async function fetchHistory() {
  try {
    const response = await fetch("/api/history", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const envelope = await response.json();
    if (envelope.schema !== "fm-dashboard-history.v1") throw new Error("unsupported history envelope");
    renderHistoryEnvelope(envelope);
  } catch (error) {
    renderHistoryEnvelope({
      schema: "fm-dashboard-history.v1",
      status: { phase: "unavailable", refreshing: false, stale: false, error: { kind: "server_unreachable", message: error.message } },
      history: null,
      usage: null,
    });
  }
}

function renderActivityEnvelope(envelope) {
  state.activity.envelope = envelope;
  renderActivity();
}

async function fetchActivity() {
  try {
    const response = await fetch("/api/timeline", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    if (payload.schema !== "fm-dashboard-timeline.v1") throw new Error("unsupported timeline envelope");
    renderActivityEnvelope({
      schema: "fm-dashboard-events.v1",
      status: { ...payload.status, last_event_at: payload.events?.[0]?.occurred_at ?? null },
      instrumented_harnesses: payload.instrumented_harnesses,
      events: payload.events,
    });
  } catch (error) {
    renderActivityEnvelope({
      schema: "fm-dashboard-events.v1",
      status: { ingestion: "unavailable", reason: error.message },
      instrumented_harnesses: [],
      events: [],
    });
  }
}

// One agent's own timeline. The live stream carries a bounded fleet-wide tail,
// so a task whose events have already scrolled out of it is fetched from the
// store rather than shown as empty.
async function showTaskTimeline(taskId) {
  state.activity.filters = { task: taskId, harness: "", type: "" };
  renderActivity();
  window.location.hash = "#activity";
  try {
    const response = await fetch(`/api/timeline?task=${encodeURIComponent(taskId)}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    if (payload.schema !== "fm-dashboard-timeline.v1" || state.activity.filters.task !== taskId) return;
    const known = new Set((state.activity.envelope?.events || []).map((event) => event?.event_id));
    const merged = [...(state.activity.envelope?.events || [])];
    for (const event of payload.events || []) if (!known.has(event?.event_id)) merged.push(event);
    renderActivityEnvelope({ ...state.activity.envelope, events: merged });
  } catch {
    // The live stream is still authoritative for what has arrived since; a
    // failed backfill narrows the view rather than breaking it.
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
  source.addEventListener("history", (event) => {
    try {
      const envelope = JSON.parse(event.data);
      if (envelope.schema === "fm-dashboard-history.v1") renderHistoryEnvelope(envelope);
    } catch {
      source.close();
    }
  });
  source.addEventListener("agent_events", (event) => {
    try {
      const envelope = JSON.parse(event.data);
      if (envelope.schema === "fm-dashboard-events.v1") renderActivityEnvelope(envelope);
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

function readHistoryForm() {
  for (const key of Object.keys(state.history.filters)) {
    state.history.filters[key] = ui.historyForm.elements[key].value;
  }
  const size = Number(ui.historyForm.elements.pageSize.value);
  state.history.pageSize = HISTORY_LIMITS.pageSizes.includes(size) ? size : HISTORY_LIMITS.defaultPageSize;
  // Any change to what is being asked for restarts at the newest page, so the
  // reader is never left looking at page 7 of a three-page result.
  state.history.page = 0;
  renderHistory();
}

ui.historyForm.addEventListener("change", readHistoryForm);
ui.historyForm.addEventListener("input", (event) => {
  if (event.target?.name === "query") readHistoryForm();
});
ui.historyForm.addEventListener("submit", (event) => event.preventDefault());

ui.historyClear.addEventListener("click", () => {
  for (const key of Object.keys(state.history.filters)) {
    state.history.filters[key] = "";
    ui.historyForm.elements[key].value = "";
  }
  state.history.pageSize = HISTORY_LIMITS.defaultPageSize;
  ui.historyForm.elements.pageSize.value = String(HISTORY_LIMITS.defaultPageSize);
  state.history.page = 0;
  renderHistory();
});

ui.reportClose.addEventListener("click", closeReport);
ui.reportDialog.addEventListener("close", () => {
  replaceChildren(ui.reportBody, []);
  replaceChildren(ui.reportNotices, []);
});

ui.activityForm.addEventListener("change", () => {
  for (const key of Object.keys(state.activity.filters)) {
    state.activity.filters[key] = ui.activityForm.elements[key].value;
  }
  renderActivity();
});
ui.activityForm.addEventListener("submit", (event) => event.preventDefault());

ui.activityClear.addEventListener("click", () => {
  for (const key of Object.keys(state.activity.filters)) {
    state.activity.filters[key] = "";
    ui.activityForm.elements[key].value = "";
  }
  renderActivity();
});

initializeTheme();
initializeNotifications();
void fetchSnapshot();
void fetchHistory();
void fetchActivity();
renderHistory();
renderActivity();
connectEvents();
