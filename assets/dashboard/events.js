// events.js - the live per-agent activity timeline.
//
// This module is the single executable copy of the timeline policy:
// what an event row says, how a task's own timeline is selected out of the
// fleet-wide stream, and what a harness with no adapter is told.
//
// It builds plain data. app.js turns that data into nodes with createElement
// and textContent, so nothing here can put markup on the page even if the
// server's own allowlist were ever to let something through.

export const EVENT_LIMITS = {
  // How many rows the view draws at once. The server's live tail is already
  // bounded; this is the second bound, so a task with a long timeline cannot
  // make the page unresponsive.
  maxRows: 300,
};

// The lifecycle vocabulary, in the words a reader thinks in rather than the
// wire's. An unknown type is shown verbatim rather than dropped, because a
// newer producer talking to an older page should still be legible.
const TYPE_LABELS = {
  session_start: "Session started",
  prompt_submitted: "Prompt submitted",
  tool_started: "Tool started",
  tool_finished: "Tool finished",
  turn_ended: "Turn ended",
  session_end: "Session ended",
  notification: "Notification",
};

const TYPE_TONES = {
  session_start: "blue",
  prompt_submitted: "blue",
  tool_started: "grey",
  tool_finished: "grey",
  turn_ended: "green",
  session_end: "grey",
  notification: "amber",
};

const OUTCOME_TONES = { ok: "green", error: "red", blocked: "amber", unknown: "unknown" };

export function typeLabel(type) {
  return TYPE_LABELS[type] || String(type || "event");
}

export function typeTone(type) {
  return TYPE_TONES[type] || "grey";
}

export function outcomeTone(outcome) {
  return OUTCOME_TONES[outcome] || "unknown";
}

function sortedUnique(values) {
  return [...new Set(values.filter((value) => typeof value === "string" && value))].sort();
}

// The status sentence the reader actually needs. Ingestion has four honest
// answers and none of them is an empty list: "nothing can be reported",
// "nothing has happened yet", and "nothing matches what you asked for" are
// three different facts and are worded as three.
//
// The counts are deliberately separate. A filtered view that is empty while the
// fleet is busy must not claim that no events have arrived.
export function timelineNotice(envelope, streamCount, shownCount = streamCount) {
  const status = envelope?.status;
  if (!status) return { tone: "amber", text: "The activity stream has not been read yet." };
  if (status.ingestion === "off") {
    return { tone: "grey", text: "Activity reporting is switched off for this dashboard." };
  }
  if (status.ingestion === "unavailable") {
    return { tone: "red", text: `Activity cannot be recorded: ${status.reason || "the event store could not be opened"}.` };
  }
  if (status.ingestion === "disabled") {
    return {
      tone: "grey",
      text: "No agent reports activity in this home. Run bin/fm-dashboard-instrument.sh enable, then dispatch work; agents already running keep their current wiring.",
    };
  }
  if (streamCount === 0) {
    return { tone: "grey", text: "Activity reporting is on. No events have arrived yet." };
  }
  if (shownCount === 0) {
    return { tone: "grey", text: "No events match these filters." };
  }
  return { tone: "green", text: null };
}

// A task is only silent for a reason worth stating. A harness with no adapter
// is a known gap, not a fault, and saying so is the difference between "this is
// broken" and "this one does not report".
export function sourceNotice(task, envelope) {
  if (!task) return null;
  const instrumented = envelope?.instrumented_harnesses || [];
  const harness = typeof task.harness === "string" ? task.harness : "";
  if (!harness) return null;
  const base = harness.replace(/-signed$/, "");
  if (instrumented.includes(base)) return null;
  return `${harness} has no event source, so this task reports no activity. Harnesses with an adapter: ${instrumented.join(", ") || "none"}.`;
}

// A selected task's backfilled rows, merged into the live stream at render
// time.
//
// The stream is a bounded fleet-wide tail that every broadcast replaces
// wholesale, so backfilled rows cannot be merged INTO it: the next accepted
// event anywhere in the fleet would discard them, and a task whose events have
// already scrolled out of the tail would flash onto the page and vanish. They
// live in their own slot keyed by the task they were fetched for, and are
// merged here instead - which also means a broadcast costs no HTTP request,
// however busy the fleet is.
export function mergeTaskBackfill(events, backfill, taskId) {
  const rows = Array.isArray(events) ? [...events] : [];
  if (!taskId || backfill?.task !== taskId || !Array.isArray(backfill.events)) return rows;
  const known = new Set(rows.map((event) => event?.event_id));
  for (const event of backfill.events) {
    if (!event || known.has(event.event_id)) continue;
    known.add(event.event_id);
    rows.push(event);
  }
  return rows;
}

export function buildTimeline(envelope, filters = {}) {
  const events = Array.isArray(envelope?.events) ? envelope.events : [];
  const rows = [];
  for (const event of events) {
    if (!event || typeof event !== "object") continue;
    if (filters.task && event.task_id !== filters.task) continue;
    if (filters.harness && event.harness !== filters.harness) continue;
    if (filters.type && event.type !== filters.type) continue;
    rows.push({
      id: String(event.event_id ?? ""),
      task: String(event.task_id ?? ""),
      harness: String(event.harness ?? ""),
      type: String(event.type ?? ""),
      tool: typeof event.tool === "string" ? event.tool : null,
      outcome: typeof event.outcome === "string" ? event.outcome : null,
      summary: typeof event.summary === "string" ? event.summary : null,
      session: typeof event.session_id === "string" ? event.session_id : null,
      at: String(event.occurred_at ?? ""),
      epoch: Number.isFinite(event.occurred_epoch) ? event.occurred_epoch : 0,
    });
  }
  // Newest first, with the stored order as the tie-break so two events in the
  // same second keep the order they were accepted in rather than shuffling on
  // every render.
  rows.sort((a, b) => b.epoch - a.epoch);
  const truncated = rows.length > EVENT_LIMITS.maxRows;
  return {
    rows: rows.slice(0, EVENT_LIMITS.maxRows),
    total: rows.length,
    truncated,
    choices: {
      task: sortedUnique(events.map((event) => event?.task_id)),
      harness: sortedUnique(events.map((event) => event?.harness)),
      type: sortedUnique(events.map((event) => event?.type)),
    },
  };
}

// A short clock label. The full instant stays available as the row's title
// attribute, so the compact column never costs the reader the exact time.
export function clockLabel(iso) {
  if (typeof iso !== "string" || iso.length < 20) return "";
  return iso.slice(11, 19);
}
