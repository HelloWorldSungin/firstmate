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
const SUPERVISION_KEY = "(firstmate supervision)";

// Every phase bin/fm-dashboard-server.mjs's HistoryState.envelope() can report,
// plus the "unavailable" one app.js synthesises when /api/history itself fails.
// A phase outside this set is a document this page cannot read, and saying so
// is the only honest answer: guessing "pending" would promise a number that is
// never coming, and guessing "absent" would claim this home collects nothing.
const ENVELOPE_PHASES = new Set(["first_run", "ready", "last_good", "unavailable"]);

// The two collection states that are facts about this home rather than a read
// that missed. Everything else - "operational" and anything this page does not
// recognize - is a failure and is disclosed as one.
const CALM_COLLECTIONS = new Set(["absent", "disabled"]);

function isUnattributed(key) {
  return UNATTRIBUTED_KEYS.has(text(key));
}

function isProject(key) {
  return !isUnattributed(key) && text(key) !== SUPERVISION_KEY;
}

function projectTone(key) {
  if (key === SUPERVISION_KEY) return "amber";
  if (isUnattributed(key)) return "grey";
  return "blue";
}

function projectLabel(key) {
  if (key === SUPERVISION_KEY) {
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

// The five answers this page can give, decided from the envelope's own phase
// first and the rollup's state second. A failed read, a read still on its way,
// a home that collects nothing and a retained read are four different claims,
// and the renderer needs them apart: only one of them is an alarm.
//
// The phase is asked first because it is the only thing that can tell a read
// that did not land from a read that has not finished - /api/history failing
// produces an envelope with no usage rollup at all.
function usageReadState(envelope, read) {
  if (!envelope) return "pending";
  const status = envelope.status && typeof envelope.status === "object" ? envelope.status : null;
  const phase = text(status?.phase);
  if (!ENVELOPE_PHASES.has(phase)) return "unavailable";
  if (phase === "unavailable") return "unavailable";
  // The first poll has not answered yet, so there is nothing to be right or
  // wrong about: this is the one state that is neither a claim nor an alarm.
  if (phase === "first_run") return "pending";
  if (!read) return "unavailable";
  if (!read.available) return CALM_COLLECTIONS.has(read.collection) ? "absent" : "unavailable";
  // A retained read on either side: the server kept its last good rollup, or
  // the history poll itself is serving its last good envelope, which freezes
  // the usage read at that same vintage.
  return read.stale || phase === "last_good" ? "stale" : "ready";
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
  if (readState === "pending" || readState === "unavailable" || readState === "absent") shape = readState;
  else if (rows.length === 0) shape = "empty";
  else shape = "rows";

  return {
    readState,
    shape,
    rows,
    // The unattributed and supervision rows are spend, not projects: they are
    // kept on screen so the percentages stay honest, and counted apart so the
    // headline says how many projects this fleet actually worked on.
    project_count: rows.filter((row) => isProject(row.key)).length,
    total_tokens: totalTokens,
    total_work: totalWork,
    total_events: totalEvents,
    reason: read?.reason || "",
    collection: read?.collection || "",
    stale: readState === "stale",
    // The one failure a reader can act on: this home collects usage and the
    // read missed anyway. It is what the renderer's alarm copy is keyed on, so
    // a home that simply collects nothing never draws one.
    fault: read !== null && !read.available && read.collection === "operational",
  };
}

export { formatTokens, isProject, isUnattributed, projectLabel, projectTone, SUPERVISION_KEY };
