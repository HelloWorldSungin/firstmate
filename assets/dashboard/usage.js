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
  return key;
}

function workTokens(totals) {
  const input = positiveInteger(totals?.input_tokens) || 0;
  const output = positiveInteger(totals?.output_tokens) || 0;
  return input + output;
}

/** Build the usage view from the server's fm-dashboard-history.v1 envelope. */
export function buildUsage(envelope) {
  const usage = envelope?.usage && typeof envelope.usage === "object" ? envelope.usage : null;
  let readState;
  if (!usage) {
    readState = "pending";
  } else if (usage.available === true) {
    readState = "ready";
  } else {
    readState = "unavailable";
  }

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
    reason: text(usage?.reason),
    collection: text(usage?.collection),
    stale: usage?.stale === true,
    fault: usage?.available !== true && text(usage?.collection) === "operational",
  };
}

export { formatTokens, isUnattributed, projectLabel, projectTone };
