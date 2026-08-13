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
  // Fraction of the watcher's own grace window that turns supervision amber.
  watcherAmberFraction: 0.5,
  // Fraction of supervision's own tolerated-quiet window that turns Task
  // activity amber. There is deliberately no seconds constant beside it: the
  // window itself arrives on the snapshot as
  // `supervision.watcher.quiet_allowance_seconds`, exactly as the grace window
  // above does, so this module cannot hold a second opinion about how long a
  // working task may reasonably stay quiet.
  activityAmberFraction: 0.5,
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

function plural(count) {
  return count === 1 ? "" : "s";
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
    // `since_age_seconds` ages the date the row was RAISED, which is the only
    // date the backlog records: `since` is written at creation and is not
    // rewritten when the row goes on hold, so this reason is labelled "raised"
    // rather than claiming to know how long a hold has stood. A row with no
    // readable date keeps a null age and still renders "age unknown", because a
    // missing date must not become a fabricated zero.
    const reason = reasonFrom("decision", {
      text: text(record?.hold_reason) || "This backlog item is held for the captain with no recorded reason.",
      key: text(record?.hold_kind) || null,
      source: "backlog hold",
      ageSeconds: finiteAge(record?.since_age_seconds),
      ageSource: "raised",
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
  if (!watcher || typeof watcher !== "object") {
    return { id: "supervision", label: "Supervision", tone: "unknown", value: "unknown", detail: "This snapshot carries no watcher liveness reading.", tooltip };
  }
  if (watcher.present !== true) {
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

// A task that declared its own quiet has not gone quiet. The snapshot makes
// that judgement server-side through `hints.last_event_declared_wait`, which
// bin/fm-classify-lib.sh decides with the same declared-wait vocabulary the
// supervision watcher uses, so this module never carries a second copy of what
// counts as a pause and the two surfaces cannot drift apart on it.
//
// A field that is absent or not exactly `true` reads as NOT declared. An older
// or partial snapshot therefore keeps the strict elapsed-time verdict rather
// than being quietly excused: an undeclared silence is what this signal exists
// to catch, and uncertainty about the declaration is not good news.
function declaredWait(task) {
  return task?.hints?.last_event_declared_wait === true;
}

// Task activity and Workers ask different questions but must split the fleet on
// the declaration identically, so they split it here once. Two copies of this
// filter is the same drift this module reads a single server-side verdict to
// avoid, one level up.
function splitDeclaredWaits(live) {
  return {
    waiting: live.filter(declaredWait),
    working: live.filter((task) => !declaredWait(task)),
  };
}

// The `current_state.source` values whose verdict is a reading taken NOW.
// bin/fm-crew-state.sh owns the list: `run-step` is the validation run's own
// current step, and `pane` is the harness's own busy verdict. Everything else
// it can answer with is a memory or an absence - `run-step-degraded` replays a
// remembered step after a lookup failure, `run-attribution` means a run was
// found but could not be tied to this task, `status-log` is the append-only
// event log this signal already reads, and `timeout`, `not-attempted`,
// `row-unavailable` and `none` are readings that were not taken: the first ran
// past its bound, the second could not be started at all, and the third names a
// task row the snapshot could not build. None of those is evidence that a task
// is doing something right now, so none of them excuses quiet.
const LIVE_STATE_SOURCES = new Set(["run-step", "pane"]);

// Whether the snapshot got a definite answer about this task from one of those
// sources. A definite answer accounts for the task's quiet whatever the answer
// was: `working` and `parked` say what it is doing, and `done` and `failed` are
// conditions the inbox and the board already carry. `unknown` is not an answer.
function stateReadLive(task) {
  const state = text(task?.current_state?.state);
  return LIVE_STATE_SOURCES.has(text(task?.current_state?.source)) && state !== "" && state !== "unknown";
}

// How long ago this task last did anything the snapshot can see, from three
// clocks in order: its last status append, its last turn-boundary wake, and - only
// when neither of those exists - how long ago it was dispatched.
//
// The status log alone is a REPORTING cadence, not an activity one. The crew
// brief instructs workers to append only on phase changes a supervisor would
// act on, so a healthy task is meant to be silent for long stretches, and
// ageing that log alone measures obedience. A turn-boundary wake is an activity
// timestamp the runtime produces on its own, whatever the worker chooses to
// report, so the newer of the two is the honest answer to "when did anything
// last happen here". A task whose harness leaves no turn marker still ages on
// its status log exactly as before.
//
// The dispatch time is last because it is not an activity timestamp at all: it
// is when the task STARTED, which only bounds a task that has not yet produced
// either real clock. Supervision bounds the same case the same way, so a task
// that has reported nothing and completed nothing still has a clock and the
// exemption a live reading buys stays bounded for it too. Without it a worker
// that hung inside its very first tool call could never colour the strip,
// however long it hung.
//
// `spawn_age_seconds` ages the `spawned_at` stamp recorded at dispatch, not the
// mtime of `state/<id>.meta`. The file is rewritten by firstmate's own routine
// actions - recording a PR, flipping a kind, appending a decision review - so
// its mtime would reset a hung task's only clock and re-buy it a full quiet
// window. That is the same exemption hole in a different place, which is why
// the snapshot publishes the recorded value instead.
//
// `bin/fm-watch.sh`'s `busy_turn_over_age` does age the meta FILE, and that is
// correct for what it asks: it bounds how long a BUSY PANE may go with no
// turn-boundary wake, it owns that choice, and it must not be changed to match this.
function activityAge(task) {
  const reported = [
    finiteAge(task?.paths?.status_log?.last_event_age_seconds),
    finiteAge(task?.paths?.turn_ended?.last_turn_age_seconds),
  ].filter((age) => age !== null);
  if (reported.length) return Math.min(...reported);
  return finiteAge(task?.spawn_age_seconds);
}

function eventSignal(tasks, supervision) {
  const live = liveWorkTasks(tasks);
  // Supervision's own tolerated-quiet window, not a constant of this module's.
  // The watcher measures a working task's latest turn-boundary wake against it
  // before treating the quiet as worth inspecting, and the strip asks the same
  // question, so asking it against a different number is how two surfaces come
  // to disagree about one fleet.
  const allowance = finiteAge(supervision?.watcher?.quiet_allowance_seconds);
  const windowText = allowance === null ? "its" : `the ${formatAge(allowance)}`;
  const tooltip = `Whether any live task has gone quiet without a live reason. A task the snapshot got a live state reading for - its validation run's own step, or its harness busy this refresh - is not aged on elapsed time, because a long step is meant to be silent. Everything else is aged on the newer of its last report and its last completed turn - or, when it has neither yet, on when it was spawned - against ${windowText} window supervision itself allows before quiet is worth inspecting: amber past half of it, red past all of it. A task parked on a declared pause or a captain hold is counted separately, because its quiet was announced, and secondmates are excluded because an idle one is healthy.`;
  if (!live.length) {
    return { id: "events", label: "Task activity", tone: "green", value: "no live tasks", detail: "Nothing is under way in this home.", tooltip };
  }

  const { waiting, working } = splitDeclaredWaits(live);

  // Declared waits are reported as their own state rather than folded silently
  // into a passing reading. How long a declared wait has stood is the useful
  // fact about it; elapsed time alone is not, and colouring it would make the
  // strip redder every day a decision correctly sits with the captain.
  if (!working.length) {
    const waits = waiting.map((task) => finiteAge(task?.paths?.status_log?.last_event_age_seconds)).filter((age) => age !== null);
    const longest = waits.length ? Math.max(...waits) : null;
    return {
      id: "events",
      label: "Task activity",
      tone: "green",
      value: `${waiting.length} waiting by design`,
      detail: longest === null
        ? "Every live task declared its own wait. Nothing has gone quiet without saying so."
        : `Every live task declared its own wait; the longest has been waiting ${formatAge(longest)}. Nothing has gone quiet without saying so.`,
      tooltip,
    };
  }

  const waitingNote = waiting.length ? ` ${waiting.length} further task${plural(waiting.length)} declared a wait and ${waiting.length === 1 ? "is" : "are"} not counted here.` : "";

  // Without the window there is no threshold to judge against, and inventing
  // one here is the defect this signal was built out of. An unjudgeable reading
  // is unknown, never a pass.
  if (allowance === null) {
    return {
      id: "events",
      label: "Task activity",
      tone: "unknown",
      value: "unknown",
      detail: `This snapshot carries no tolerated-quiet window, so how long ${working.length} working task${plural(working.length)} may reasonably stay quiet cannot be judged.${waitingNote}`,
      tooltip,
    };
  }

  // A task the snapshot got a live answer about is accounted for, however long
  // its log has been quiet. That exemption is bounded exactly as supervision
  // bounds it: a live reading buys the task the window and no more, so a pane
  // that renders busy while its foreground call has hung cannot hide behind it.
  const accounted = working.filter(stateReadLive);
  const silent = working.filter((task) => !stateReadLive(task));
  const accountedNote = accounted.length
    ? ` ${accounted.length} task${plural(accounted.length)} had a live state reading this refresh and ${accounted.length === 1 ? "is" : "are"} not aged here.`
    : "";

  // A working task with no readable clock cannot be judged, and that holds
  // whether or not the snapshot got a live reading for it. A live reading says
  // what a task is doing now, never for how long, so the window it buys needs a
  // clock exactly as an unobserved task's quiet does. Dropping the clockless
  // ones from the bound instead is what made this exemption unbounded, and an
  // exemption that can never expire is a pass dressed as a measurement.
  const ageOf = (list) => list.map((task) => ({ task, age: activityAge(task) }));
  const silentAged = ageOf(silent);
  const accountedAged = ageOf(accounted);
  const unreadable = [...silentAged, ...accountedAged]
    .filter((entry) => entry.age === null)
    .map((entry) => text(entry.task?.id))
    .filter(Boolean);
  if (unreadable.length) {
    return {
      id: "events",
      label: "Task activity",
      tone: "unknown",
      value: "unknown",
      detail: `No readable activity age for ${unreadable.join(", ")}, so how long ${unreadable.length === 1 ? "it has" : "they have"} been quiet cannot be judged.${waitingNote}`,
      tooltip,
    };
  }

  const silentAges = silentAged.map((entry) => entry.age);
  const accountedAges = accountedAged.map((entry) => entry.age);
  const silentOldest = silentAges.length ? Math.max(...silentAges) : null;
  const accountedOldest = accountedAges.length ? Math.max(...accountedAges) : null;
  const overdue = accountedOldest !== null && accountedOldest >= allowance;
  // The number here is activityAge, the newest of three clocks, so the sentence
  // says "did nothing" rather than naming any one of them. Claiming a turn
  // boundary for a figure that may have come from a status append would put the
  // exact conflation of reporting cadence with activity that this signal was
  // rebuilt to remove back into the operator-facing copy.
  const overdueDetail = `the slowest has recorded no activity in ${formatAge(accountedOldest)}, past the ${formatAge(allowance)} supervision allows before that is worth inspecting`;

  if (silentOldest === null) {
    // Every working task answered, so there is no quiet to judge.
    return {
      id: "events",
      label: "Task activity",
      tone: overdue ? "amber" : "green",
      value: `${accounted.length} accounted for`,
      detail: overdue
        ? `Every working task had a live state reading, but ${overdueDetail}.${waitingNote}`
        : `Every working task had a live state reading this refresh, so nothing is quiet without a live reason.${waitingNote}`,
      tooltip,
    };
  }

  const tone = silentOldest >= allowance ? "red"
    : silentOldest >= allowance * POLICY.activityAmberFraction || overdue ? "amber"
      : "green";
  const value = accounted.length
    ? `oldest ${formatAge(silentOldest)} · ${accounted.length} accounted for`
    : `oldest ${formatAge(silentOldest)}`;
  const overdueNote = overdue ? ` Among the tasks that did answer, ${overdueDetail}.` : "";
  return {
    id: "events",
    label: "Task activity",
    tone,
    value,
    detail: `${silent.length} working task${plural(silent.length)} had no live state reading; the quietest last did anything ${formatAge(silentOldest)} ago, against the ${formatAge(allowance)} supervision allows.${overdueNote}${accountedNote}${waitingNote}`,
    tooltip,
  };
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

// A missing endpoint answers two different questions depending on whether the
// task declared a wait. Parking a captain-gated task EXITS its agent on purpose,
// so its absent endpoint is the expected outcome, not a worker that died; a task
// that went quiet without declaring anything and lost its endpoint is the real
// alarm this signal exists to raise. What parking IS - fleet operating practice
// rather than a procedure this repo defines - is owned by
// docs/dashboard-inbox-policy.md.
//
// The declared-wait verdict is the same `hints.last_event_declared_wait` that
// Task activity reads, so both cards ask bin/fm-classify-lib.sh the one question
// and this module still carries no second copy of the pause vocabulary. That
// verdict is authoritative over the `data/<id>/parked.md` note a park also
// leaves behind: the status declaration is what the watcher acts on and what
// fm-crew-state.sh reconciles, while parked.md is an operator note no tracked
// code reads or retracts, so a resumed task would keep a stale one on disk.
//
// Declared waits are excluded from the endpoint buckets in both directions
// rather than counted present: whatever their endpoint currently is, it is not
// evidence about fleet health, and an absent one is expected.
function workerSignal(tasks) {
  const live = liveWorkTasks(tasks);
  const tooltip = "Whether each live task that has not declared a wait still has its recorded runtime endpoint. A task parked on a declared pause or a captain hold is counted separately, because parking exits its agent on purpose. The snapshot reports agent liveness only for secondmates, so ordinary tasks report endpoint presence.";
  if (!live.length) {
    return { id: "workers", label: "Workers", tone: "green", value: "none live", detail: "No live task has a runtime endpoint to check.", tooltip };
  }

  const { waiting, working } = splitDeclaredWaits(live);
  const waitingIds = waiting.map((task) => text(task?.id) || "unnamed");
  const waitingClause = waiting.length
    ? `${waiting.length} task${plural(waiting.length)} declared a wait and ${waiting.length === 1 ? "is" : "are"} not counted here, so an exited agent is expected: ${waitingIds.join(", ")}.`
    : "";

  if (!working.length) {
    return {
      id: "workers",
      label: "Workers",
      tone: "green",
      value: `${waiting.length} waiting by design`,
      detail: `No live task is working. ${waitingClause}`,
      tooltip,
    };
  }

  const buckets = bucketLiveness(working, { agentAuthoritative: false });
  const counts = `${buckets.alive.length} present · ${buckets.dead.length} gone · ${buckets.unknown.length} unknown`;
  const value = waiting.length ? `${counts} · ${waiting.length} waiting` : counts;
  const suffix = waitingClause ? ` ${waitingClause}` : "";
  if (buckets.dead.length) {
    const undeclared = buckets.dead.length === 1 ? "which declared no wait" : "none of which declared a wait";
    return { id: "workers", label: "Workers", tone: "red", value, detail: `No runtime endpoint for ${buckets.dead.join(", ")}, ${undeclared}.${suffix}`, tooltip };
  }
  if (buckets.unknown.length) {
    return { id: "workers", label: "Workers", tone: "unknown", value, detail: `Endpoint presence could not be read for ${buckets.unknown.join(", ")}.${suffix}`, tooltip };
  }
  return { id: "workers", label: "Workers", tone: "green", value, detail: `Every working task's runtime endpoint is present.${suffix}`, tooltip };
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
    eventSignal(tasks, snapshot?.supervision),
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
