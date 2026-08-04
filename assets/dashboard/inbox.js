// inbox.js - captain inbox and fleet health policy.
//
// docs/dashboard-inbox-policy.md owns the human statement of this policy: what
// makes a pull request green, what turns each health signal amber or red, and
// how overlapping signals deduplicate into one item. This module is the single
// executable copy of it. The browser app renders what these functions return
// and decides nothing on its own.
//
// One invariant holds everywhere below: uncertainty is never rendered as good
// news. A missing, stale, or unreadable field resolves to an explicit `unknown`
// verdict carrying its own reason - never to a passing value, and never to an
// absent field the eye reads as fine.
//
// Every input comes from `fm-fleet-snapshot.v1` and the dashboard envelope.
// Nothing here contacts a forge or re-reads fleet state.

export const POLICY = {
  // A normalized PR observation older than this is no longer evidence of the
  // current state, so it renders as unknown rather than as its last reading.
  prStatusMaxAgeSeconds: 900,
  // Age of the newest event on a live task before the fleet reads as slow.
  eventAmberSeconds: 900,
  eventRedSeconds: 3_600,
  // Fraction of the watcher's own grace window that turns supervision amber.
  watcherAmberFraction: 0.5,
};

const PR_ENUMS = {
  state: new Set(["open", "draft", "closed", "merged", "unknown"]),
  review: new Set(["approved", "changes_requested", "review_required", "none", "unknown"]),
  checks: new Set(["passing", "failing", "pending", "none", "unknown"]),
  mergeable: new Set(["mergeable", "conflicting", "blocked", "unknown"]),
};

// Item tones rank worst-first so overlapping reasons resolve to one colour.
// `unknown` deliberately outranks `green`: a reading we could not take must
// never summarize as a passing one.
const ITEM_TONE_RANK = { green: 0, blue: 1, unknown: 2, amber: 3, red: 4 };
const HEALTH_TONE_RANK = { green: 0, unknown: 1, amber: 2, red: 3 };

const REASON_KINDS = {
  decision: { rank: 1, tone: "amber", label: "Decision" },
  credential: { rank: 2, tone: "amber", label: "Credential" },
  blocked: { rank: 3, tone: "red", label: "Blocked" },
  failed: { rank: 4, tone: "red", label: "Failed" },
  pr_attention: { rank: 5, tone: "red", label: "Pull request" },
  merge_ready: { rank: 6, tone: "green", label: "Merge ready" },
  review_ready: { rank: 7, tone: "blue", label: "Review ready" },
  pr_unknown: { rank: 8, tone: "unknown", label: "Status unknown" },
};

// Reclassifies an ALREADY OPEN decision or blocker whose own text says it is
// waiting on a credential or a login. It never opens an item of its own.
const CREDENTIAL_PATTERN =
  /\b(credentials?|log in|logged in|login|sign in|signed in|password|passphrase|api key|access token|auth token|token expired|re-?auth\w*|authenticat\w*|authoriz\w*|unauthorized|401|403|2fa|mfa|otp|ssh key|gpg key|permission denied|not logged in)\b/i;

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

// Only a real number is an age. `Number(null)` and `Number("")` are both 0, and
// silently reading a missing field as "zero seconds old" is exactly the kind of
// invented freshness this module exists to prevent.
function finiteAge(value) {
  if (typeof value !== "number" && typeof value !== "string") return null;
  if (typeof value === "string" && value.trim() === "") return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function enumToken(value, allowed) {
  const token = text(value);
  return token && token !== "unknown" && allowed.has(token) ? token : null;
}

function worst(tones, rank) {
  let winner = null;
  for (const tone of tones) {
    if (winner === null || (rank[tone] ?? 0) > (rank[winner] ?? 0)) winner = tone;
  }
  return winner;
}

/**
 * Humanized age, shared with the browser app so a duration never reads one way
 * on a card and another way on the health strip.
 */
export function formatAge(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "unknown";
  if (seconds < 60) return `${Math.round(seconds)}s`;
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h ${Math.floor((seconds % 3_600) / 60)}m`;
  return `${Math.floor(seconds / 86_400)}d ${Math.floor((seconds % 86_400) / 3_600)}h`;
}

function terminalColumn(task) {
  return task?.card?.column === "done";
}

// The tasks the fleet is actually working on right now. A secondmate is live
// but not work: it reports only when it is asked to do something, so an idle
// one is healthy and must never be counted as a task that has gone quiet.
function liveWorkTasks(tasks) {
  return tasks.filter((task) => !terminalColumn(task) && text(task?.kind) !== "secondmate");
}

/**
 * Normalized pull-request readiness for one task.
 *
 * The verdict is derived only from the cached normalized observation. A PR URL
 * on its own proves nothing and never produces a ready verdict.
 */
export function prReadiness(task, options = {}) {
  const maxAge = finiteAge(options.prStatusMaxAgeSeconds) ?? POLICY.prStatusMaxAgeSeconds;
  const url = text(task?.pr?.url);
  const base = {
    url: url || null,
    number: Number.isFinite(Number(task?.pr?.number)) ? Number(task.pr.number) : null,
    age_seconds: finiteAge(task?.pr?.status_age_seconds),
    freshness: text(task?.pr?.status_freshness) || "absent",
    fields: { state: "unknown", review: "unknown", checks: "unknown", mergeable: "unknown" },
    unknown_fields: ["state", "review", "checks", "mergeable"],
    caveats: [],
    stale: false,
  };
  if (!url) {
    return { ...base, verdict: "none", tone: "unknown", label: "No pull request", detail: "This task has no recorded pull request." };
  }

  const status = task?.pr?.status && typeof task.pr.status === "object" ? task.pr.status : {};
  const resolved = {
    state: enumToken(status.state, PR_ENUMS.state),
    review: enumToken(status.review, PR_ENUMS.review),
    checks: enumToken(status.checks, PR_ENUMS.checks),
    mergeable: enumToken(status.mergeable, PR_ENUMS.mergeable),
  };
  const unknownFields = Object.keys(resolved).filter((name) => resolved[name] === null);
  const fields = Object.fromEntries(Object.keys(resolved).map((name) => [name, resolved[name] ?? "unknown"]));
  const stale = base.age_seconds === null || base.age_seconds > maxAge;
  const shared = { ...base, fields, unknown_fields: unknownFields, stale };

  // A withdrawn reading renders exactly like one that was never taken: every
  // value it reported goes back to `unknown`, so no chip states a fact in
  // confident styling that the verdict above it has already disowned. `keep`
  // names the fields whose truth age cannot undo.
  const withdraw = (keep = []) => {
    const held = Object.fromEntries(keep.map((name) => [name, resolved[name]]));
    const blanked = { ...base.fields, ...held };
    return {
      ...shared,
      fields: blanked,
      unknown_fields: Object.keys(blanked).filter((name) => blanked[name] === "unknown"),
    };
  };

  if (base.freshness !== "cached") {
    return {
      ...withdraw(),
      verdict: "unknown",
      tone: "unknown",
      label: "Status unknown",
      detail: "No normalized review, check, or mergeability observation has been recorded for this pull request.",
    };
  }

  // `merged` and `closed` are monotonic, so age cannot make them untrue. They
  // settle before the freshness gate: a landed pull request stays terminal
  // instead of reappearing as an unknown the captain can do nothing about.
  // Only the state survives the withdrawal, because the other three fields are
  // as perishable here as anywhere else.
  if (resolved.state === "merged" || resolved.state === "closed") {
    const settled = stale ? withdraw(["state"]) : shared;
    return resolved.state === "merged"
      ? { ...settled, verdict: "merged", tone: "green", label: "Merged", detail: "This pull request has landed." }
      : { ...settled, verdict: "closed", tone: "unknown", label: "Closed", detail: "This pull request was closed without merging." };
  }

  if (stale) {
    return {
      ...withdraw(),
      verdict: "unknown",
      tone: "unknown",
      label: "Status unknown",
      detail: base.age_seconds === null
        ? "The recorded observation has no readable age, so its verdict cannot be trusted."
        : `The recorded observation is older than the ${formatAge(maxAge)} freshness limit, so its verdict is no longer current.`,
    };
  }
  if (unknownFields.length) {
    return {
      ...shared,
      verdict: "unknown",
      tone: "unknown",
      label: "Status unknown",
      detail: `The forge did not report ${unknownFields.join(", ")}, so this pull request cannot be called ready.`,
    };
  }

  if (resolved.state === "draft") {
    return { ...shared, verdict: "draft", tone: "unknown", label: "Draft", detail: "This pull request is still a draft." };
  }

  const caveats = [];
  if (resolved.checks === "none") caveats.push("no checks reported");
  if (resolved.mergeable === "blocked") caveats.push("merging blocked by branch protection");
  if (resolved.review === "none") caveats.push("no review requested");
  const withCaveats = { ...shared, caveats };

  if (resolved.checks === "failing") {
    return { ...withCaveats, verdict: "checks_failing", tone: "red", label: "Checks failing", detail: "Checks are failing on this pull request." };
  }
  if (resolved.mergeable === "conflicting") {
    return { ...withCaveats, verdict: "conflicting", tone: "red", label: "Conflicting", detail: "This pull request conflicts with its target branch." };
  }
  if (resolved.review === "changes_requested") {
    return { ...withCaveats, verdict: "changes_requested", tone: "amber", label: "Changes requested", detail: "A reviewer requested changes on this pull request." };
  }
  if (resolved.checks === "pending") {
    return { ...withCaveats, verdict: "checks_pending", tone: "amber", label: "Checks running", detail: "Checks are still running on this pull request." };
  }
  if (resolved.checks === "passing" && resolved.review === "approved" && resolved.mergeable === "mergeable") {
    return { ...withCaveats, verdict: "merge_ready", tone: "green", label: "Merge ready", detail: "Checks pass, review is approved, and the forge reports it mergeable." };
  }
  return {
    ...withCaveats,
    verdict: "review_ready",
    tone: "blue",
    label: "Review ready",
    detail: resolved.checks === "passing"
      ? "Checks pass and this pull request is waiting on review."
      : "This pull request is waiting on review; no checks reported a passing result.",
  };
}

function reasonFrom(kind, { text: body, key = null, source, ageSeconds = null, ageSource = null, tone = null }) {
  const definition = REASON_KINDS[kind];
  return {
    kind,
    rank: definition.rank,
    tone: tone || definition.tone,
    label: definition.label,
    text: body,
    key,
    source,
    age_seconds: ageSeconds,
    age_source: ageSource,
  };
}

function classifyOpenDecision(entry) {
  const verb = text(entry?.verb);
  const summary = text(entry?.summary);
  if (CREDENTIAL_PATTERN.test(summary)) return "credential";
  if (verb === "blocked") return "blocked";
  return "decision";
}

function taskReasons(task, options) {
  const reasons = [];
  const eventAge = finiteAge(task?.paths?.status_log?.last_event_age_seconds);
  const decisions = Array.isArray(task?.hints?.open_decisions) ? task.hints.open_decisions : [];
  for (const entry of decisions) {
    const summary = text(entry?.summary);
    reasons.push(reasonFrom(classifyOpenDecision(entry), {
      text: summary || "This item was opened with no summary text.",
      key: text(entry?.key) || null,
      source: `status ${text(entry?.verb) || "event"}`,
      ageSeconds: eventAge,
      ageSource: "last update",
    }));
  }
  if (text(task?.current_state?.state) === "failed") {
    reasons.push(reasonFrom("failed", {
      text: text(task?.current_state?.detail) || "The worker reported a failure with no detail.",
      source: "current state",
      ageSeconds: eventAge,
      ageSource: "last update",
    }));
  }

  const readiness = prReadiness(task, options);
  const prAge = readiness.age_seconds;
  if (["checks_failing", "conflicting", "changes_requested"].includes(readiness.verdict)) {
    reasons.push(reasonFrom("pr_attention", {
      text: readiness.detail,
      source: "pull request",
      tone: readiness.tone,
      ageSeconds: prAge,
      ageSource: "status observed",
    }));
  } else if (readiness.verdict === "merge_ready" || readiness.verdict === "review_ready") {
    reasons.push(reasonFrom(readiness.verdict, {
      text: readiness.detail,
      source: "pull request",
      ageSeconds: prAge,
      ageSource: "status observed",
    }));
  } else if (readiness.verdict === "unknown") {
    reasons.push(reasonFrom("pr_unknown", {
      text: readiness.detail,
      source: "pull request",
      ageSeconds: prAge,
      ageSource: "status observed",
    }));
  }
  return { reasons, readiness };
}

function finalizeItem(item) {
  item.reasons.sort((left, right) => left.rank - right.rank || left.kind.localeCompare(right.kind));
  const primary = item.reasons[0];
  item.primary = primary.kind;
  item.label = primary.label;
  item.tone = worst(item.reasons.map((reason) => reason.tone), ITEM_TONE_RANK);
  const ages = item.reasons.map((reason) => reason.age_seconds).filter((age) => age !== null);
  item.age_known = ages.length > 0;
  item.age_seconds = item.age_known ? Math.max(...ages) : null;
  item.age_source = item.age_known
    ? item.reasons.find((reason) => reason.age_seconds === item.age_seconds).age_source
    : null;
  item.rank = primary.rank;
  return item;
}

/**
 * The captain inbox: one deduplicated item per task or captain-held backlog
 * row, carrying every reason it is here.
 *
 * Items sort oldest evidence first, because the longest-waiting item is the one
 * most likely to have been forgotten. An item whose age cannot be read sorts
 * ahead of every dated one rather than being quietly filed at the bottom.
 */
export function buildInbox(snapshot, options = {}) {
  const tasks = Array.isArray(snapshot?.tasks) ? snapshot.tasks : [];
  const items = new Map();

  for (const task of tasks) {
    const id = text(task?.id);
    if (!id) continue;
    const { reasons, readiness } = taskReasons(task, options);
    if (!reasons.length) continue;
    items.set(id, {
      id,
      task_id: id,
      kind: text(task?.kind) || "task",
      project: text(task?.project) || null,
      title: text(task?.backlog?.title) || id,
      reasons,
      pr: readiness.url ? readiness : null,
      work_items: Array.isArray(task?.work_items) ? task.work_items : [],
      column: text(task?.card?.column) || null,
      action: text(task?.card?.action) || null,
      source: "task",
    });
  }

  // Captain-gated backlog rows are decisions with no live worker behind them.
  // A row whose task is already in the inbox merges into that one item so the
  // captain never sees the same thread twice.
  const records = Array.isArray(snapshot?.backlog?.records) ? snapshot.backlog.records : [];
  for (const record of records) {
    if (record?.captain_actionable !== true) continue;
    const id = text(record?.id);
    if (!id) continue;
    const reason = reasonFrom("decision", {
      text: text(record?.hold_reason) || "This backlog item is held for the captain with no recorded reason.",
      key: text(record?.hold_kind) || null,
      source: "backlog hold",
    });
    const existing = items.get(id);
    if (existing) {
      existing.reasons.push(reason);
      continue;
    }
    items.set(id, {
      id,
      task_id: null,
      kind: "backlog",
      project: text(record?.repo) || null,
      title: text(record?.title) || id,
      reasons: [reason],
      pr: null,
      work_items: [],
      column: null,
      action: null,
      source: "backlog",
    });
  }

  const list = [...items.values()].map(finalizeItem).sort((left, right) => {
    if (left.age_known !== right.age_known) return left.age_known ? 1 : -1;
    if (left.age_known && left.age_seconds !== right.age_seconds) return right.age_seconds - left.age_seconds;
    return left.rank - right.rank || left.id.localeCompare(right.id);
  });

  const has = (kind) => (item) => item.reasons.some((reason) => reason.kind === kind);
  return {
    items: list,
    counts: {
      total: list.length,
      decisions: list.filter(has("decision")).length,
      credentials: list.filter(has("credential")).length,
      blocked: list.filter(has("blocked")).length,
      failed: list.filter((item) => has("failed")(item) || has("pr_attention")(item)).length,
      merge_ready: list.filter(has("merge_ready")).length,
      review_ready: list.filter(has("review_ready")).length,
      unknown: list.filter(has("pr_unknown")).length,
    },
  };
}

function watcherSignal(supervision) {
  const watcher = supervision?.watcher;
  const grace = finiteAge(watcher?.grace_seconds);
  const age = finiteAge(watcher?.age_seconds);
  const tooltip = "The supervision watcher touches a liveness beacon every poll. A stopped watcher means wake events are no longer reaching Firstmate.";
  if (!watcher || watcher.present !== true) {
    return { id: "supervision", label: "Supervision", tone: "red", value: "not running", detail: "No watcher liveness beacon exists in this home.", tooltip };
  }
  if (age === null) {
    return { id: "supervision", label: "Supervision", tone: "unknown", value: "unknown", detail: "The beacon exists but its age could not be read.", tooltip };
  }
  if (watcher.stale === true) {
    return { id: "supervision", label: "Supervision", tone: "red", value: `${formatAge(age)} since last beat`, detail: `The beacon has not moved within its ${grace === null ? "configured" : formatAge(grace)} grace window.`, tooltip };
  }
  if (grace !== null && age >= grace * POLICY.watcherAmberFraction) {
    return { id: "supervision", label: "Supervision", tone: "amber", value: `${formatAge(age)} since last beat`, detail: `Past half of the ${formatAge(grace)} grace window.`, tooltip };
  }
  return { id: "supervision", label: "Supervision", tone: "green", value: `${formatAge(age)} since last beat`, detail: "The watcher is beating within its grace window.", tooltip };
}

function awaySignal(supervision) {
  const afk = supervision?.afk;
  const tooltip = "Away mode hands routine supervision to the away daemon and batches escalations. It never widens approval authority.";
  if (!afk || typeof afk !== "object") {
    return { id: "away", label: "Away mode", tone: "unknown", value: "unknown", detail: "This home reported no away-mode record.", tooltip };
  }
  if (afk.active === true) {
    return { id: "away", label: "Away mode", tone: "amber", value: "on", detail: "Routine wakes are handled by the away daemon and escalations arrive batched.", tooltip };
  }
  return { id: "away", label: "Away mode", tone: "green", value: "off", detail: "Every wake is handled at full responsiveness.", tooltip };
}

function snapshotSignal(envelope) {
  const status = envelope?.status;
  const tooltip = "How fresh the underlying fleet snapshot is. Every other signal on this strip is only as current as this one.";
  const age = finiteAge(status?.last_success_age_seconds);
  const suffix = age === null ? "" : ` (${formatAge(age)} old)`;
  if (status?.phase === "ready") {
    return { id: "snapshot", label: "Snapshot", tone: "green", value: `fresh${suffix}`, detail: "The last refresh succeeded within the freshness threshold.", tooltip };
  }
  if (status?.phase === "last_good") {
    return { id: "snapshot", label: "Snapshot", tone: "amber", value: `stale${suffix}`, detail: "Showing the last known good snapshot; refreshes continue automatically.", tooltip };
  }
  if (status?.phase === "unavailable") {
    return { id: "snapshot", label: "Snapshot", tone: "red", value: "unavailable", detail: text(status?.error?.message) || "No valid fleet snapshot is available.", tooltip };
  }
  return { id: "snapshot", label: "Snapshot", tone: "unknown", value: "waiting", detail: "The first fleet snapshot has not completed yet.", tooltip };
}

function eventSignal(tasks) {
  const live = liveWorkTasks(tasks);
  const tooltip = `How long ago the slowest live task last reported anything. Secondmates are excluded because an idle one is healthy. Amber past ${formatAge(POLICY.eventAmberSeconds)}, red past ${formatAge(POLICY.eventRedSeconds)}.`;
  if (!live.length) {
    return { id: "events", label: "Task activity", tone: "green", value: "no live tasks", detail: "Nothing is under way in this home.", tooltip };
  }
  const ages = live.map((task) => finiteAge(task?.paths?.status_log?.last_event_age_seconds));
  const unreadable = live.filter((task, index) => ages[index] === null).map((task) => text(task?.id)).filter(Boolean);
  if (unreadable.length) {
    return { id: "events", label: "Task activity", tone: "unknown", value: "unknown", detail: `No readable event age for ${unreadable.join(", ")}.`, tooltip };
  }
  const oldest = Math.max(...ages);
  const tone = oldest >= POLICY.eventRedSeconds ? "red" : oldest >= POLICY.eventAmberSeconds ? "amber" : "green";
  return { id: "events", label: "Task activity", tone, value: `oldest ${formatAge(oldest)}`, detail: `${live.length} live task${live.length === 1 ? "" : "s"}; the slowest last reported ${formatAge(oldest)} ago.`, tooltip };
}

// The snapshot answers two different questions with one field. For a secondmate
// it reports whether the AGENT is alive, so anything short of `alive` is not a
// live return channel. For every other task it reports only whether the runtime
// ENDPOINT is present, so a present endpoint is the strongest true statement
// available and `unknown` stays unknown rather than being read either way.
function bucketLiveness(tasks, { agentAuthoritative }) {
  const buckets = { alive: [], dead: [], unknown: [] };
  for (const task of tasks) {
    const status = text(task?.endpoint?.status);
    const id = text(task?.id) || "unnamed";
    if (status === "alive") buckets.alive.push(id);
    else if (status === "dead" || status === "absent" || task?.endpoint?.exists === false) buckets.dead.push(id);
    else if (!agentAuthoritative && task?.endpoint?.exists === true) buckets.alive.push(id);
    else buckets.unknown.push(id);
  }
  return buckets;
}

function workerSignal(tasks) {
  const live = liveWorkTasks(tasks);
  const tooltip = "Whether each live task's recorded runtime endpoint is still there. The snapshot reports agent liveness only for secondmates, so ordinary tasks report endpoint presence.";
  if (!live.length) {
    return { id: "workers", label: "Workers", tone: "green", value: "none live", detail: "No live task has a runtime endpoint to check.", tooltip };
  }
  const buckets = bucketLiveness(live, { agentAuthoritative: false });
  const value = `${buckets.alive.length} present · ${buckets.dead.length} gone · ${buckets.unknown.length} unknown`;
  if (buckets.dead.length) {
    return { id: "workers", label: "Workers", tone: "red", value, detail: `No runtime endpoint for ${buckets.dead.join(", ")}.`, tooltip };
  }
  if (buckets.unknown.length) {
    return { id: "workers", label: "Workers", tone: "unknown", value, detail: `Endpoint presence could not be read for ${buckets.unknown.join(", ")}.`, tooltip };
  }
  return { id: "workers", label: "Workers", tone: "green", value, detail: "Every live task's runtime endpoint is present.", tooltip };
}

function secondmateSignal(tasks) {
  const mates = tasks.filter((task) => text(task?.kind) === "secondmate");
  const tooltip = "Registered secondmates and whether their agent is still alive. An idle secondmate is healthy; a dead one has lost its return channel.";
  if (!mates.length) {
    return { id: "secondmates", label: "Secondmates", tone: "green", value: "none", detail: "No secondmate is registered in this home.", tooltip };
  }
  const buckets = bucketLiveness(mates, { agentAuthoritative: true });
  const value = `${buckets.alive.length} live · ${buckets.dead.length} dead · ${buckets.unknown.length} unknown`;
  if (buckets.dead.length) {
    return { id: "secondmates", label: "Secondmates", tone: "red", value, detail: `No live agent for ${buckets.dead.join(", ")}.`, tooltip };
  }
  if (buckets.unknown.length) {
    return { id: "secondmates", label: "Secondmates", tone: "unknown", value, detail: `Agent liveness could not be read for ${buckets.unknown.join(", ")}.`, tooltip };
  }
  return { id: "secondmates", label: "Secondmates", tone: "green", value, detail: "Every registered secondmate is answering.", tooltip };
}

function inventorySignal(snapshot) {
  const inventory = snapshot?.main_inventory;
  const tooltip = "Whether the backlog and the live task records still agree. An orphan is an in-flight backlog item with no worker record behind it.";
  if (!inventory || typeof inventory !== "object") {
    return { id: "inventory", label: "Inventory", tone: "unknown", value: "unknown", detail: "This snapshot reported no inventory check.", tooltip };
  }
  const orphans = Array.isArray(inventory.orphan_in_flight) ? inventory.orphan_in_flight.map(text).filter(Boolean) : [];
  if (orphans.length) {
    return { id: "inventory", label: "Inventory", tone: "red", value: `${orphans.length} orphaned`, detail: `In-flight with no worker record: ${orphans.join(", ")}.`, tooltip };
  }
  if (inventory.valid !== true) {
    return { id: "inventory", label: "Inventory", tone: "red", value: "inconsistent", detail: text(inventory.reason) || "The backlog and live task records disagree.", tooltip };
  }
  return { id: "inventory", label: "Inventory", tone: "green", value: "consistent", detail: "Every in-flight backlog item has a matching worker record.", tooltip };
}

/**
 * The fleet health strip.
 *
 * When the snapshot itself is stale or unavailable, every reading better than
 * red is demoted to unknown: those values were true at the last refresh and are
 * unverified now. Red readings survive, because an old alarm is still an alarm.
 */
export function buildHealth(snapshot, envelope) {
  const tasks = Array.isArray(snapshot?.tasks) ? snapshot.tasks : [];
  const snapshotState = snapshotSignal(envelope);
  const others = [
    watcherSignal(snapshot?.supervision),
    eventSignal(tasks),
    workerSignal(tasks),
    secondmateSignal(tasks),
    inventorySignal(snapshot),
    awaySignal(snapshot?.supervision),
  ];
  const unverified = snapshotState.tone === "amber" || snapshotState.tone === "red";
  const signals = [snapshotState, ...others.map((signal) => (
    unverified && signal.tone !== "red"
      ? { ...signal, tone: "unknown", detail: `${signal.detail} Unverified while the snapshot is ${snapshotState.value}.` }
      : signal
  ))];

  const tone = worst(signals.map((signal) => signal.tone), HEALTH_TONE_RANK) || "unknown";
  const label = tone === "red" ? "Attention needed"
    : tone === "amber" ? "Degraded"
      : tone === "unknown" ? "Partly unknown"
        : "Healthy";
  return { overall: { tone, label }, signals };
}
