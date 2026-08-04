// history.js - completed-work history policy for the dashboard.
//
// History is built from the durable completion manifests in data/<id>/outcome.json
// (schema fm-outcome-manifest.v1, aggregated as fm-outcome-history.v1 by
// bin/fm-outcome-lib.sh), never from volatile task metadata and never from the
// Done backlog. That is the point of the view: cleanup removes state/<id>.meta
// and the backlog keeps only its recent Done entries, so anything sourced from
// either would quietly lose a task that finished last month. docs/dashboard.md
// states this for humans; docs/fleet-data-contracts.md owns the manifest fields.
//
// One invariant, shared with inbox.js: uncertainty is never rendered as good
// news. A missing usage total is `unavailable`, never 0. An unknown duration is
// `unknown`, never a dash the eye reads as instant. A manifest that could not be
// read is disclosed with its reason, never dropped from the count.
//
// This module deliberately computes NO pull-request readiness verdict. Readiness
// is a live judgment about work that still needs the captain, and inbox.js owns
// that policy in full. History shows the observation that was recorded at
// completion time, with its age and its unknowns intact, so the two views cannot
// drift into two different definitions of green.

export const HISTORY_LIMITS = {
  maxQueryChars: 120,
  pageSizes: [25, 50, 100],
  defaultPageSize: 25,
  maxDetailChars: 400,
};

const OUTCOME_TONES = {
  done: "green",
  failed: "red",
  discarded: "amber",
  retired: "grey",
  unknown: "unknown",
};

const OUTCOME_LABELS = {
  done: "Done",
  failed: "Failed",
  discarded: "Discarded",
  retired: "Retired",
  unknown: "Outcome unknown",
};

const PR_STATE_TONES = {
  merged: "green",
  open: "blue",
  draft: "grey",
  closed: "grey",
  unknown: "unknown",
};

const MALFORMED_REASONS = {
  not_a_regular_file: "the completion record is not a regular file",
  too_large: "the completion record is larger than the safe read bound",
  unreadable_or_wrong_schema: "the completion record could not be read, or is not a supported schema version",
  unexpected_fields: "the completion record carries fields this schema version does not define",
  invalid_values: "the completion record has values this schema version does not accept",
};

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function isoMillis(value) {
  const stamp = text(value);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(stamp)) return null;
  const millis = Date.parse(stamp);
  return Number.isFinite(millis) ? millis : null;
}

function positiveInteger(value) {
  return typeof value === "number" && Number.isFinite(value) && Number.isInteger(value) && value >= 0 ? value : null;
}

// A duration only exists when both ends were actually recorded. The manifest is
// explicit that `started` can be absent, and a task with no start is not a task
// that took zero seconds.
function duration(record) {
  const started = isoMillis(record?.timestamps?.started);
  const completed = isoMillis(record?.timestamps?.completed);
  if (started === null || completed === null || completed < started) {
    return { known: false, seconds: null, reason: started === null ? "no recorded start" : "recorded start is after completion" };
  }
  return { known: true, seconds: Math.round((completed - started) / 1000), reason: null };
}

function prSummary(record) {
  const url = text(record?.pr?.url);
  if (!url) return { present: false };
  const status = record?.pr?.status && typeof record.pr.status === "object" ? record.pr.status : {};
  const state = text(status.state) || "unknown";
  const observedAt = text(status.observed_at) || null;
  const source = text(status.source) || "absent";
  const fields = ["state", "review", "checks", "mergeable"].map((name) => ({
    name,
    value: text(status[name]) || "unknown",
  }));
  return {
    present: true,
    url,
    number: positiveInteger(record?.pr?.number),
    host: text(record?.pr?.host) || null,
    state,
    tone: PR_STATE_TONES[state] || "unknown",
    // `absent` means no observation was ever recorded for this pull request, which
    // is a different fact from an observation that said "unknown".
    observed: source !== "absent" && Boolean(observedAt),
    observed_at: observedAt,
    fields,
  };
}

// Usage totals are presence-gated on both sides: the collector may not exist in
// this home at all, and a task the collector never attributed has no row. Both
// render as `unavailable` with the reason, never as zero.
function usageFor(id, usage) {
  if (!usage || usage.available !== true) {
    return { available: false, reason: text(usage?.reason) || "token usage is not collected in this home", totals: null };
  }
  const row = usage.tasks && typeof usage.tasks === "object" ? usage.tasks[id] : null;
  if (!row || typeof row !== "object") {
    return { available: false, reason: "no token usage was attributed to this task", totals: null };
  }
  const totals = {};
  for (const field of ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens", "total_tokens", "events", "sessions"]) {
    totals[field] = positiveInteger(row[field]);
  }
  if (totals.total_tokens === null) {
    return { available: false, reason: "the collected usage record has no readable total", totals: null };
  }
  const estimated = typeof row?.cost?.estimated === "number" && Number.isFinite(row.cost.estimated) ? row.cost.estimated : null;
  return {
    available: true,
    reason: null,
    totals,
    cost: estimated === null ? null : {
      estimated,
      currency: text(row.cost.currency) || null,
      unpriced_events: positiveInteger(row.cost.unpriced_events),
    },
  };
}

function workItems(record) {
  const references = Array.isArray(record?.work_items?.references) ? record.work_items.references : [];
  return references.filter((reference) => text(reference?.url)).map((reference) => ({
    url: text(reference.url),
    forge: text(reference.forge) || "unknown",
    host: text(reference.host) || null,
    path: text(reference.path) || null,
    number: positiveInteger(reference.number),
    kind: text(reference.kind) || null,
    enrichment: reference.enrichment && typeof reference.enrichment === "object" ? reference.enrichment : {},
  }));
}

// Only these fields are indexed for text search. Report bodies are deliberately
// excluded: searching them means reading every retained report on every
// keystroke, and semantic search over report content is a separate integration.
function searchIndex(record, items) {
  return [
    record.task_id,
    record.title,
    record.project,
    record.kind,
    record.harness,
    record.model,
    record.mode,
    record?.outcome?.state,
    record?.outcome?.detail,
    record?.pr?.url,
    ...items.map((item) => item.url),
    ...items.map((item) => item.enrichment?.title),
  ].map((value) => text(value).toLowerCase()).filter(Boolean).join("   ");
}

/** One manifest as the view renders it. Never invents a value the record lacks. */
export function historyRow(record, usage) {
  const id = text(record?.task_id);
  const items = workItems(record);
  const state = text(record?.outcome?.state) || "unknown";
  const completed = text(record?.timestamps?.completed) || null;
  return {
    id,
    title: text(record?.title) || null,
    project: text(record?.project) || null,
    kind: text(record?.kind) || "ship",
    mode: text(record?.mode) || null,
    yolo: text(record?.yolo) || null,
    harness: text(record?.harness) || null,
    model: text(record?.model) || null,
    effort: text(record?.effort) || null,
    outcome: {
      state,
      label: OUTCOME_LABELS[state] || OUTCOME_LABELS.unknown,
      tone: OUTCOME_TONES[state] || "unknown",
      detail: text(record?.outcome?.detail).slice(0, HISTORY_LIMITS.maxDetailChars) || null,
      forced: record?.outcome?.forced === true,
      source: text(record?.outcome?.source) || "none",
    },
    timestamps: {
      created: text(record?.timestamps?.created) || null,
      started: text(record?.timestamps?.started) || null,
      completed,
    },
    // The manifest records where each timestamp came from rather than implying a
    // precision it does not have, so the view can say "from the backlog date".
    timestamp_sources: {
      created: text(record?.timestamp_sources?.created) || null,
      started: text(record?.timestamp_sources?.started) || null,
      completed: text(record?.timestamp_sources?.completed) || null,
    },
    completed_millis: isoMillis(completed),
    completed_date: completed ? completed.slice(0, 10) : null,
    duration: duration(record),
    pr: prSummary(record),
    report: {
      present: record?.report?.present === true,
      path: text(record?.report?.path) || null,
    },
    work_items: items,
    gbrain: {
      status: text(record?.gbrain?.status) || "absent",
      receipt: text(record?.gbrain?.receipt) || null,
    },
    usage: usageFor(id, usage),
    search_index: searchIndex(record || {}, items),
  };
}

function facetValues(rows, key) {
  return [...new Set(rows.map((row) => (key === "outcome" ? row.outcome.state : row[key])).filter(Boolean))]
    .sort((left, right) => left.localeCompare(right));
}

function matches(row, view) {
  if (view.project && row.project !== view.project) return false;
  if (view.harness && row.harness !== view.harness) return false;
  if (view.model && row.model !== view.model) return false;
  if (view.kind && row.kind !== view.kind) return false;
  if (view.outcome && row.outcome.state !== view.outcome) return false;
  if (view.from && (!row.completed_date || row.completed_date < view.from)) return false;
  if (view.to && (!row.completed_date || row.completed_date > view.to)) return false;
  if (view.query) return row.search_index.includes(view.query);
  return true;
}

/** The search term as it is actually applied: bounded, lowercased, literal. */
export function normalizeQuery(raw) {
  return text(raw).slice(0, HISTORY_LIMITS.maxQueryChars).toLowerCase();
}

/**
 * Build the history view from the server's fm-dashboard-history.v1 envelope.
 * `view` carries the active filters, the search query, the page index, and the
 * page size; everything else is derived from the durable records.
 */
export function buildHistory(envelope, view = {}) {
  const document = envelope?.history && typeof envelope.history === "object" ? envelope.history : null;
  const records = Array.isArray(document?.records) ? document.records : [];
  const usage = envelope?.usage && typeof envelope.usage === "object" ? envelope.usage : null;
  const rows = records.map((record) => historyRow(record, usage)).filter((row) => row.id);

  const facets = {
    project: facetValues(rows, "project"),
    harness: facetValues(rows, "harness"),
    model: facetValues(rows, "model"),
    kind: facetValues(rows, "kind"),
    outcome: facetValues(rows, "outcome"),
  };
  // A facet filter whose value no longer appears in anything that was read can
  // never match, and a record can leave the read set at any time - by ageing
  // past the record limit or by turning up malformed. Dropping it here, before
  // the view is derived, is what keeps the controls and the list describing the
  // same frame: a select reading "All projects" above an empty list would be
  // the view contradicting itself.
  const facetFilter = (key, raw) => {
    const value = text(raw);
    return facets[key].includes(value) ? value : "";
  };
  const active = {
    project: facetFilter("project", view.project),
    harness: facetFilter("harness", view.harness),
    model: facetFilter("model", view.model),
    kind: facetFilter("kind", view.kind),
    outcome: facetFilter("outcome", view.outcome),
    from: text(view.from),
    to: text(view.to),
    query: normalizeQuery(view.query),
  };
  const filtered = rows.filter((row) => matches(row, active));

  const size = HISTORY_LIMITS.pageSizes.includes(view.pageSize) ? view.pageSize : HISTORY_LIMITS.defaultPageSize;
  const pages = Math.max(1, Math.ceil(filtered.length / size));
  const index = Math.min(Math.max(Number.isInteger(view.page) ? view.page : 0, 0), pages - 1);
  const start = index * size;
  const visible = filtered.slice(start, start + size);

  const malformed = (Array.isArray(document?.malformed) ? document.malformed : []).map((entry) => ({
    id: text(entry?.id) || "unknown record",
    path: text(entry?.path) || null,
    reason: text(entry?.reason) || "unknown",
    explanation: MALFORMED_REASONS[text(entry?.reason)] || "the completion record could not be used",
  }));

  const captured = rows.filter((row) => row.gbrain.status === "captured").length;

  return {
    rows: visible,
    facets,
    filters: active,
    page: {
      index,
      size,
      pages,
      first: filtered.length ? start + 1 : 0,
      last: Math.min(start + size, filtered.length),
      matched: filtered.length,
      total: rows.length,
    },
    // `truncated` is the archive's own statement that more completed work exists
    // than this read returned, so the view can say so instead of implying the
    // fleet has only ever finished this much.
    truncated: document?.truncated === true,
    record_total: positiveInteger(document?.total),
    malformed,
    usage: {
      available: usage?.available === true,
      reason: text(usage?.reason) || null,
      source: text(usage?.source) || null,
    },
    // Semantic search over report content is a separate integration. Until it
    // exists this is a presence gate and nothing else: history is fully usable
    // with it absent, and the panel only claims what is actually captured.
    semantic_search: {
      available: false,
      captured_records: captured,
      reason: captured
        ? "reports are captured for semantic search, but this dashboard has no search integration yet"
        : "no completed report has been captured for semantic search",
    },
    empty: rows.length === 0,
  };
}

/** Compact token count for a card, e.g. 1.2M. */
export function formatTokens(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return "unavailable";
  if (value < 1_000) return String(value);
  if (value < 1_000_000) return `${(value / 1_000).toFixed(1)}k`;
  return `${(value / 1_000_000).toFixed(2)}M`;
}

/** Compact duration for a card, or an explicit unknown. */
export function formatDuration(entry) {
  if (!entry?.known || typeof entry.seconds !== "number") return "unknown";
  const seconds = entry.seconds;
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3_600) return `${Math.round(seconds / 60)}m`;
  if (seconds < 86_400) return `${(seconds / 3_600).toFixed(1)}h`;
  return `${(seconds / 86_400).toFixed(1)}d`;
}
