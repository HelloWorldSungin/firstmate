// usage.js - per-project token usage policy for the dashboard.
//
// This page is the single executable copy of the per-project usage view. It
// reads the project rollup the server already fetched, keeps the unattributed
// share visible, and never renders a missing or failed read as a zero.
//
// Ranking is by "work tokens" (input + output), not raw total_tokens. Cache
// reads are real spend but they are replayed context, not new work, so a row
// that is mostly cache must not dominate the headline ranking.

import { formatTokens } from "./history.js";
import { label } from "./display.js";

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function positiveInteger(value) {
  return typeof value === "number" && Number.isFinite(value) && Number.isInteger(value) && value >= 0 ? value : null;
}

// The keys the usage collector uses for spend that is not attributed to any
// project. They are rendered as rows like any other so the share of spend that
// is unknown stays on screen rather than vanishing from percentages.
const UNATTRIBUTED_KEYS = new Set(["(unknown)", "(unattributed)"]);

function isUnattributed(key) {
  return UNATTRIBUTED_KEYS.has(text(key));
}

function projectTone(key) {
  if (key === "(firstmate supervision)") return "amber";
  if (isUnattributed(key)) return "grey";
  return "blue";
}

function projectLabel(key) {
  if (key === "(firstmate supervision)") {
    return "Firstmate supervision";
  }
  if (isUnattributed(key)) {
    return "Unattributed";
  }
  // A project value can still arrive path-shaped from a record this rollup did
  // not resolve. display.js owns the rule that no filesystem path renders as a
  // name, and a project's label is its final segment.
  return label(key) || key;
}

function workTokens(totals) {
  const input = positiveInteger(totals?.input_tokens) || 0;
  const output = positiveInteger(totals?.output_tokens) || 0;
  return input + output;
}

// The project rollup's own read state. The server reports it separately from
// the per-task one because a project read that missed says nothing about the
// task totals History renders; an envelope from a server that carries only the
// single combined state is read as that state for both.
function projectRead(usage) {
  if (!usage) return null;
  const read = usage.projects_read && typeof usage.projects_read === "object" ? usage.projects_read : usage;
  return {
    available: read.available === true,
    reason: text(read.reason),
    collection: text(read.collection),
    stale: read.stale === true,
  };
}

// A failed read and a read still on its way are opposite claims, and only the
// envelope's own status can tell them apart: /api/history failing produces an
// envelope with no usage rollup at all, which is a read that did not land
// rather than one that has not finished.
function usageReadState(envelope, read) {
  if (!envelope) return "pending";
  const status = envelope.status && typeof envelope.status === "object" ? envelope.status : null;
  if (text(status?.phase) === "unavailable") return "unavailable";
  if (text(status?.phase) === "first_run" && status?.refreshing === true) return "pending";
  if (!read) return "unavailable";
  return read.available ? "ready" : "unavailable";
}

/** Build the usage view from the server's fm-dashboard-history.v1 envelope. */
export function buildUsage(envelope) {
  const usage = envelope?.usage && typeof envelope.usage === "object" ? envelope.usage : null;
  const read = projectRead(usage);
  const readState = usageReadState(envelope, read);

  const projectMap = usage?.projects && typeof usage.projects === "object" ? usage.projects : {};
  const entries = Object.entries(projectMap);
  let totalTokens = 0;
  let totalWork = 0;
  let totalEvents = 0;
  for (const [, totals] of entries) {
    totalTokens += positiveInteger(totals?.total_tokens) || 0;
    totalWork += workTokens(totals);
    totalEvents += positiveInteger(totals?.events) || 0;
  }

  const rows = [];
  for (const [key, totals] of entries) {
    const tokens = positiveInteger(totals?.total_tokens);
    const events = positiveInteger(totals?.events);
    const sessions = positiveInteger(totals?.sessions);
    const work = workTokens(totals);
    rows.push({
      key: text(key) || "unknown",
      tokens: tokens ?? 0,
      work,
      events: events ?? 0,
      sessions: sessions ?? 0,
      share: totalWork > 0 ? Math.round((work / totalWork) * 10000) / 100 : null,
    });
  }
  rows.sort((left, right) => right.work - left.work);

  let shape;
  if (readState === "pending") shape = "pending";
  else if (readState === "unavailable") shape = "unavailable";
  else if (rows.length === 0) shape = "empty";
  else shape = "rows";

  return {
    readState,
    shape,
    rows,
    total_tokens: totalTokens,
    total_work: totalWork,
    total_events: totalEvents,
    reason: read?.reason || "",
    collection: read?.collection || "",
    stale: read?.stale === true,
    fault: read !== null && !read.available && read.collection === "operational",
  };
}

export { formatTokens, isUnattributed, projectLabel, projectTone };
