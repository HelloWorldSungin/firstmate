// backlog.js - the read-only queue policy for the dashboard's Backlog page.
//
// The records come from GET /api/backlog, which serves the same full
// fm-fleet-snapshot.sh backlog parse the fleet state reads (one owner for the
// file format). This module derives the page's view model: the current queue
// (every record that is not Done - delivered work belongs to History), the
// state tabs, the facets, the search, and the pagination.
//
// The page is read-only by contract, so nothing here computes an action:
// ordering is preserved exactly as the backlog file records it, because that
// order IS Firstmate's queue decision.
//
// Invariants shared with history.js: an unknown age is never a fabricated
// zero, a record this page cannot read is counted and disclosed rather than
// silently dropped, and the three empty shapes stay distinct - no backlog at
// all (first run), a queue with nothing matching (filtered), and a queue that
// is genuinely empty all render differently.

export const BACKLOG_LIMITS = {
  maxQueryChars: 120,
  pageSize: 25,
};

// The state tabs, owned here with the counts that fill them so the renderer
// cannot ask for a tab this module never counts.
export const BACKLOG_TAB_KEYS = ["all", "in_flight", "queued", "held", "blocked"];

const STATE_PRESENTATION = {
  in_flight: { label: "in flight", tone: "green", tab: "in_flight" },
  queued: { label: "queued", tone: "grey", tab: "queued" },
  held: { label: "held", tone: "amber", tab: "held" },
  blocked: { label: "blocked", tone: "red", tab: "blocked" },
  done: { label: "done", tone: "green", tab: null },
};

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function finiteAge(seconds) {
  return Number.isFinite(seconds) && seconds >= 0 ? seconds : null;
}

function formatAge(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return null;
  if (seconds < 60) return `${Math.round(seconds)}s`;
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h`;
  return `${Math.floor(seconds / 86_400)}d`;
}

function backlogReadState(envelope, document) {
  if (!envelope) return "pending";
  if (envelope.status?.phase === "unavailable") return "unavailable";
  if (envelope.status?.phase === "first_run" && envelope.status?.refreshing === true) return "pending";
  if (envelope.status?.phase === "last_good" && document) return "stale";
  if (!document || document.present !== true) return "absent";
  return "ready";
}

/** The display row for one backlog record, or null for one with no id. */
function backlogRow(record) {
  const id = text(record?.id);
  if (!id) return null;
  // Done rows are History's content, not the queue's: a completed item leaves
  // this page the moment its state flips, which is also what the backlog file
  // itself does when Done entries are pruned.
  if (text(record?.state) === "done") {
    const donePresentation = STATE_PRESENTATION.done;
    return {
      id,
      title: text(record?.title) || id,
      project: text(record?.repo) || null,
      kind: text(record?.kind) || null,
      since: text(record?.since) || null,
      sinceAgeSeconds: null,
      age: null,
      ageHot: false,
      prio: null,
      state: "done",
      stateLabel: donePresentation.label,
      stateTone: donePresentation.tone,
      tone: donePresentation.tone,
      reason: null,
      order: Number.isFinite(record?.order) ? record.order : Number.MAX_SAFE_INTEGER,
    };
  }
  const held = text(record?.hold_reason) || record?.hold_reason != null;
  // Still-blocked is the fleet's own answer, never the raw blocked-by token: a
  // blocker that has since been delivered leaves the id on the row, and the
  // snapshot resolves exactly that into unresolved_blocker_ids. Reading the
  // token instead would paint a runnable item red until someone edited the
  // file, which is the opposite of what the queue is for.
  const blocked = (record?.unresolved_blocker_ids || []).length > 0;
  const key = held ? "held" : blocked ? "blocked" : (text(record?.state) === "in_flight" ? "in_flight" : "queued");
  const presentation = STATE_PRESENTATION[key];
  const reason = key === "held"
    ? text(record?.hold_reason) || null
    : key === "blocked" ? text(record?.blocked_reason) || null : null;
  const priority = record?.priority;
  const prioRaw = priority !== null && priority !== undefined && priority !== "" && Number.isFinite(Number(priority))
    ? Number(priority)
    : null;
  const ageSeconds = finiteAge(record?.since_age_seconds);
  return {
    id,
    title: text(record?.title) || id,
    project: text(record?.repo) || null,
    kind: text(record?.kind) || null,
    since: text(record?.since) || null,
    sinceAgeSeconds: ageSeconds,
    age: ageSeconds === null ? null : formatAge(ageSeconds),
    ageHot: ageSeconds !== null && ageSeconds >= 240 * 60,
    prio: prioRaw !== null && prioRaw >= 0 && prioRaw <= 9 ? prioRaw : null,
    state: key,
    stateLabel: presentation.label,
    stateTone: presentation.tone,
    tone: presentation.tone,
    reason,
    order: Number.isFinite(record?.order) ? record.order : Number.MAX_SAFE_INTEGER,
  };
}

function facetValues(rows, key) {
  return [...new Set(rows.map((row) => row[key]).filter((value) => value !== null && value !== ""))]
    .sort((left, right) => String(left).localeCompare(String(right), undefined, { numeric: true }));
}

/**
 * Build the Backlog page view from the server's fm-dashboard-backlog.v1
 * envelope. `view` carries the search query, the project/kind/priority facet
 * choices, the state tab, and the page index.
 */
export function buildBacklog(envelope, view = {}) {
  const document = envelope?.backlog && typeof envelope.backlog === "object" ? envelope.backlog : null;
  const records = Array.isArray(document?.records) ? document.records : [];
  const parsed = records.map((record) => ({ record, row: backlogRow(record) }));
  const allRows = parsed.map((entry) => entry.row).filter(Boolean);
  // A current row the parse could not turn into a queue item is queued work
  // this page would otherwise hide. Done rows are History's, so an unreadable
  // one there is not a claim this page makes.
  const unreadable = parsed.filter((entry) => !entry.row && text(entry.record?.state) !== "done").length;
  const queue = allRows
    .filter((row) => row.state !== "done")
    .sort((left, right) => left.order - right.order || left.id.localeCompare(right.id));

  const status = envelope?.status;
  const readState = backlogReadState(envelope, document);
  const error = readState === "unavailable"
    ? { tone: "red", text: `The backlog could not be read: ${text(status.error?.message) || "unknown reason"}. Retrying automatically.` }
    : readState === "stale"
      ? { tone: "amber", text: `Showing the last known good backlog read: ${text(status.error?.message) || "the newest read did not land"}.` }
    : null;

  const query = text(view.query).slice(0, BACKLOG_LIMITS.maxQueryChars).toLowerCase();
  const project = text(view.project);
  const kind = text(view.kind);
  const prio = text(view.prio);

  const base = queue.filter((row) =>
    (!project || row.project === project)
    && (!kind || row.kind === kind)
    && (!prio || String(row.prio) === prio)
    && (!query || `${row.title} ${row.project ?? ""} ${row.id}`.toLowerCase().includes(query)));

  const tab = text(view.tab) || "all";
  const tabs = {};
  for (const key of BACKLOG_TAB_KEYS) {
    tabs[key] = key === "all" ? base.length : base.filter((row) => row.state === key).length;
  }
  const effectiveTab = tabs[tab] === undefined ? "all" : tab;
  const filtered = (effectiveTab === "all" ? base : base.filter((row) => row.state === effectiveTab));

  const pages = Math.max(1, Math.ceil(filtered.length / BACKLOG_LIMITS.pageSize));
  const index = Math.min(Math.max(Number.isInteger(view.page) ? view.page : 0, 0), pages - 1);
  const start = index * BACKLOG_LIMITS.pageSize;
  const rows = filtered.slice(start, start + BACKLOG_LIMITS.pageSize);

  return {
    readState,
    present: document?.present === true,
    error,
    unreadable,
    queueTotal: queue.length,
    total: base.length,
    tabs,
    facets: {
      project: facetValues(queue, "project"),
      kind: facetValues(queue, "kind"),
      prio: facetValues(queue, "prio"),
    },
    rows,
    page: {
      index,
      pages,
      first: filtered.length ? start + 1 : 0,
      last: Math.min(start + BACKLOG_LIMITS.pageSize, filtered.length),
      matched: filtered.length,
      total: queue.length,
    },
    allRecords: queue,
    taskRecords: allRows,
  };
}
