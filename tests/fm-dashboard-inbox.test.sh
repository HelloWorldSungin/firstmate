#!/usr/bin/env bash
# Behavior tests for the dashboard captain inbox and fleet health policy.
#
# Every case drives assets/dashboard/inbox.js through its exported browser API
# with fm-fleet-snapshot.v1 shaped fixtures. The rule under test throughout is
# that uncertainty never renders as good news: a missing, stale, or unreadable
# field must resolve to an explicit unknown, never to a passing verdict.
# docs/dashboard-inbox-policy.md owns the policy these cases pin.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

MODULE="$ROOT/assets/dashboard/inbox.js"

node - "$MODULE" <<'NODE' || fail "dashboard inbox policy behavior failed"
const { pathToFileURL } = require("node:url");

(async () => {
const { buildHealth, buildInbox, formatAge, prReadiness, POLICY } = await import(pathToFileURL(process.argv[2]).href);

const failures = [];
function check(label, condition, detail = "") {
  if (!condition) failures.push(`${label}${detail ? `: ${detail}` : ""}`);
}
function equal(label, actual, expected) {
  check(label, actual === expected, `expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
}

const PR_URL = "https://github.com/HelloWorldSungin/firstmate/pull/31";

function task(id, overrides = {}) {
  return {
    id,
    kind: "ship",
    project: "firstmate",
    backlog: { title: `${id} title` },
    current_state: { state: "working", detail: "Implementing" },
    endpoint: { exists: true, status: "unknown" },
    paths: { status_log: { last_event_age_seconds: 60 } },
    pr: { url: null, status: {}, status_age_seconds: null, status_freshness: "absent" },
    work_items: [],
    hints: { open_decisions: [] },
    card: { column: "active", action: "supervise" },
    ...overrides,
  };
}

function pr(status, { age = 30, freshness = "cached", url = PR_URL } = {}) {
  return { url, status, status_age_seconds: age, status_freshness: freshness, number: 31 };
}

const GREEN = { state: "open", review: "approved", checks: "passing", mergeable: "mergeable" };

// --- a pull request is green only when every normalized field agrees --------

equal("all three agreeing fields are merge ready",
  prReadiness(task("t", { pr: pr(GREEN) })).verdict, "merge_ready");
equal("merge ready is the only green open verdict",
  prReadiness(task("t", { pr: pr(GREEN) })).tone, "green");

for (const [field, value] of [["review", "review_required"], ["checks", "pending"], ["mergeable", "blocked"]]) {
  const readiness = prReadiness(task("t", { pr: pr({ ...GREEN, [field]: value }) }));
  check(`a non-agreeing ${field} is never merge ready`, readiness.verdict !== "merge_ready", readiness.verdict);
  check(`a non-agreeing ${field} is never green`, readiness.tone !== "green", readiness.tone);
}

equal("failing checks are a red verdict",
  prReadiness(task("t", { pr: pr({ ...GREEN, checks: "failing" }) })).verdict, "checks_failing");
equal("a conflicting merge is a red verdict",
  prReadiness(task("t", { pr: pr({ ...GREEN, mergeable: "conflicting" }) })).verdict, "conflicting");
equal("requested changes are an amber verdict",
  prReadiness(task("t", { pr: pr({ ...GREEN, review: "changes_requested" }) })).verdict, "changes_requested");

// checks: none is a definite reading, but never a passing one.
const noChecks = prReadiness(task("t", { pr: pr({ ...GREEN, checks: "none" }) }));
equal("no reported checks downgrades merge ready to review ready", noChecks.verdict, "review_ready");
check("no reported checks states its caveat", noChecks.caveats.includes("no checks reported"), JSON.stringify(noChecks.caveats));

// --- missing, stale, and unreadable provider data render as unknown ---------

const noObservation = prReadiness(task("t", { pr: pr({}, { freshness: "absent" }) }));
equal("an unobserved pull request is unknown", noObservation.verdict, "unknown");
equal("an unobserved pull request is not green", noObservation.tone, "unknown");
check("an unobserved pull request names every unreadable field",
  noObservation.unknown_fields.join(",") === "state,review,checks,mergeable", noObservation.unknown_fields.join(","));

for (const missing of ["state", "review", "checks", "mergeable"]) {
  const partial = { ...GREEN };
  delete partial[missing];
  const absent = prReadiness(task("t", { pr: pr(partial) }));
  equal(`an absent ${missing} field renders unknown`, absent.verdict, "unknown");
  check(`an absent ${missing} field is named`, absent.unknown_fields.includes(missing), absent.unknown_fields.join(","));
  check(`an absent ${missing} field still renders every field as a word`,
    Object.values(absent.fields).every((value) => typeof value === "string" && value.length > 0),
    JSON.stringify(absent.fields));

  const explicit = prReadiness(task("t", { pr: pr({ ...GREEN, [missing]: "unknown" }) }));
  equal(`an explicit unknown ${missing} renders unknown`, explicit.verdict, "unknown");

  const garbage = prReadiness(task("t", { pr: pr({ ...GREEN, [missing]: "definitely-fine" }) }));
  equal(`an out-of-enumeration ${missing} renders unknown`, garbage.verdict, "unknown");
}

const stale = prReadiness(task("t", { pr: pr(GREEN, { age: POLICY.prStatusMaxAgeSeconds + 1 }) }));
equal("an observation past the freshness limit withdraws its verdict", stale.verdict, "unknown");
check("a stale observation is marked stale", stale.stale === true);
// A withdrawn verdict withdraws its fields too, or the card still prints
// "checks passing" in confident styling for a reading nobody believes.
check("a stale observation renders no field as passing",
  Object.values(stale.fields).every((value) => value === "unknown"), JSON.stringify(stale.fields));
check("a stale observation names every withdrawn field",
  stale.unknown_fields.join(",") === "state,review,checks,mergeable", stale.unknown_fields.join(","));
const ageless = prReadiness(task("t", { pr: pr(GREEN, { age: null }) }));
equal("an observation with no readable age renders unknown", ageless.verdict, "unknown");
check("an observation with no readable age renders no field as passing",
  Object.values(ageless.fields).every((value) => value === "unknown"), JSON.stringify(ageless.fields));
const overridden = prReadiness(task("t", { pr: pr(GREEN, { age: 5_000 }) }), { prStatusMaxAgeSeconds: 10_000 });
equal("a widened freshness limit is honoured", overridden.verdict, "merge_ready");

// --- a terminal pull request stays terminal at any age ----------------------

const staleMerged = prReadiness(task("t", { pr: pr({ ...GREEN, state: "merged" }, { age: POLICY.prStatusMaxAgeSeconds + 1 }) }));
equal("a stale merged pull request is still merged", staleMerged.verdict, "merged");
equal("a monotonic terminal state survives its own staleness", staleMerged.fields.state, "merged");
check("a stale merged pull request still withdraws its perishable fields",
  ["review", "checks", "mergeable"].every((name) => staleMerged.fields[name] === "unknown"), JSON.stringify(staleMerged.fields));
equal("a stale closed pull request is still closed",
  prReadiness(task("t", { pr: pr({ ...GREEN, state: "closed" }, { age: 86_400 }) })).verdict, "closed");
equal("a stale draft is not terminal and withdraws normally",
  prReadiness(task("t", { pr: pr({ ...GREEN, state: "draft" }, { age: POLICY.prStatusMaxAgeSeconds + 1 }) })).verdict, "unknown");

equal("a bare pull-request URL alone is never ready",
  prReadiness(task("t", { pr: { url: PR_URL } })).verdict, "unknown");

// --- inbox membership ------------------------------------------------------

function inboxOf(tasks, backlog = []) {
  return buildInbox({ tasks, backlog: { records: backlog } });
}

const membership = inboxOf([
  task("merge-ready", { pr: pr(GREEN) }),
  task("review-ready", { pr: pr({ ...GREEN, review: "review_required" }) }),
  task("pr-unknown", { pr: pr({}, { freshness: "absent" }) }),
  task("pr-pending", { pr: pr({ ...GREEN, checks: "pending", review: "review_required" }) }),
  task("pr-draft", { pr: pr({ ...GREEN, state: "draft" }) }),
  task("pr-merged", { pr: pr({ ...GREEN, state: "merged" }) }),
  task("pr-closed", { pr: pr({ ...GREEN, state: "closed" }) }),
  task("quiet", {}),
]);
const present = membership.items.map((item) => item.id).sort();
equal("only actionable and unknown pull requests reach the inbox",
  present.join(","), "merge-ready,pr-unknown,review-ready");

const settled = inboxOf([
  task("landed", { card: { column: "done" }, pr: pr({ ...GREEN, state: "merged" }, { age: POLICY.prStatusMaxAgeSeconds * 4 }) }),
  task("abandoned", { card: { column: "done" }, pr: pr({ ...GREEN, state: "closed" }, { age: POLICY.prStatusMaxAgeSeconds * 4 }) }),
]);
equal("an aged terminal pull request never reopens an inbox item", settled.items.length, 0);

// --- full text and full URLs ----------------------------------------------

const longDecision = "Should the retention window stay at 40 records, or drop to 20 so the manifest history fits one screen on a phone? Either is defensible and I do not want to guess.";
const decided = inboxOf([task("decide", {
  hints: { open_decisions: [{ key: "retention", verb: "needs-decision", summary: longDecision }] },
  pr: pr(GREEN),
})]);
equal("an open decision produces one item", decided.items.length, 1);
equal("decision text is rendered in full", decided.items[0].reasons[0].text, longDecision);
equal("the full https pull-request URL is preserved", decided.items[0].pr.url, PR_URL);

// --- deduplication ---------------------------------------------------------

const overlapping = inboxOf([task("busy", {
  current_state: { state: "failed", detail: "The pipeline stopped at review" },
  hints: {
    open_decisions: [
      { key: "shape", verb: "needs-decision", summary: "Pick the API shape" },
      { key: "creds", verb: "blocked", summary: "The forge rejected the token; I need a login" },
    ],
  },
  pr: pr({ ...GREEN, checks: "failing" }),
})]);
equal("overlapping signals collapse into one item", overlapping.items.length, 1);
const reasons = overlapping.items[0].reasons.map((reason) => reason.kind);
equal("every overlapping reason is preserved, severity first",
  reasons.join(","), "decision,credential,failed,pr_attention");
check("the credential blocker is reclassified, not duplicated", reasons.filter((kind) => kind === "credential").length === 1, reasons.join(","));
equal("the highest-severity reason names the item", overlapping.items[0].primary, "decision");
equal("a red reason wins the item tone", overlapping.items[0].tone, "red");

const plainBlocker = inboxOf([task("stuck", {
  hints: { open_decisions: [{ key: "default", verb: "blocked", summary: "The upstream branch moved under me" }] },
})]);
equal("a blocker with no credential language stays a blocker", plainBlocker.items[0].reasons[0].kind, "blocked");

// --- captain-held backlog rows --------------------------------------------

const held = inboxOf([], [
  { id: "pick-retention", title: "Pick the retention window", hold_reason: "waiting on the captain", hold_kind: "captain", captain_actionable: true, repo: "firstmate" },
  { id: "not-held", title: "Ordinary queued row", captain_actionable: false },
]);
equal("a captain-held backlog row becomes an inbox item", held.items.length, 1);
equal("a captain-held row has no live worker identity", held.items[0].task_id, null);
equal("a captain-held row renders its hold reason", held.items[0].reasons[0].text, "waiting on the captain");
check("a captain-held row with no recorded date still has no readable age", held.items[0].age_known === false);

// The date the backlog does record is the date the row was RAISED, so the card
// names that and never claims to know how long a hold has stood.
const dated = inboxOf([], [
  { id: "dated", title: "Pick the bind address", hold_reason: "waiting on the captain", hold_kind: "captain", captain_actionable: true, since: "2026-07-29", since_age_seconds: 1_106_623 },
]);
equal("a dated captain-held row carries a readable age", dated.items[0].age_known, true);
equal("a dated captain-held row ages from the recorded date", dated.items[0].age_seconds, 1_106_623);
equal("a captain-held age names the date it came from", dated.items[0].age_source, "raised");

// A decision that has waited three weeks must outrank one raised this morning.
// Without an age every decision ties and the order collapses to alphabetical,
// which is the one order an inbox must not have.
const waited = inboxOf([], [
  { id: "z-oldest", title: "Oldest", hold_reason: "held", hold_kind: "captain", captain_actionable: true, since_age_seconds: 1_800_000 },
  { id: "a-newest", title: "Newest", hold_reason: "held", hold_kind: "captain", captain_actionable: true, since_age_seconds: 3_600 },
  { id: "m-middle", title: "Middle", hold_reason: "held", hold_kind: "captain", captain_actionable: true, since_age_seconds: 900_000 },
]);
equal("the longest-waiting decision sorts first regardless of id",
  waited.items.map((item) => item.id).join(","), "z-oldest,m-middle,a-newest");

// A backlog date is day-granular and a live event age is to the second, so an
// item carrying both must be aged by whichever evidence has waited longest.
const bothAges = inboxOf(
  [task("mixed", { paths: { status_log: { last_event_age_seconds: 60 } }, hints: { open_decisions: [{ key: "k", verb: "needs-decision", summary: "live" }] } })],
  [{ id: "mixed", title: "Same thread", hold_reason: "held", hold_kind: "captain", captain_actionable: true, since_age_seconds: 500_000 }],
);
equal("a merged item is aged by its oldest evidence", bothAges.items[0].age_seconds, 500_000);
equal("and names that evidence", bothAges.items[0].age_source, "raised");

// A row with an unusable date must not become a fabricated zero.
for (const [label, value] of [["null", null], ["absent", undefined], ["empty", ""], ["negative", -1], ["not a number", "soon"]]) {
  const bad = inboxOf([], [{ id: "bad", title: "Bad", hold_reason: "held", hold_kind: "captain", captain_actionable: true, since_age_seconds: value }]);
  equal(`an unusable ${label} date stays age unknown`, bad.items[0].age_known, false);
}

const merged = inboxOf(
  [task("dual", { hints: { open_decisions: [{ key: "k", verb: "needs-decision", summary: "live decision" }] } })],
  [{ id: "dual", title: "Same thread", hold_reason: "held for the captain", hold_kind: "captain", captain_actionable: true }],
);
equal("a backlog hold merges into its live task item", merged.items.length, 1);
equal("both sources survive the merge", merged.items[0].reasons.length, 2);

// --- ordering --------------------------------------------------------------

const ordered = inboxOf([
  task("recent", { paths: { status_log: { last_event_age_seconds: 30 } }, hints: { open_decisions: [{ key: "a", verb: "needs-decision", summary: "recent" }] } }),
  task("ancient", { paths: { status_log: { last_event_age_seconds: 9_000 } }, hints: { open_decisions: [{ key: "b", verb: "needs-decision", summary: "ancient" }] } }),
  task("middle", { paths: { status_log: { last_event_age_seconds: 900 } }, hints: { open_decisions: [{ key: "c", verb: "needs-decision", summary: "middle" }] } }),
  task("ageless", { paths: { status_log: {} }, hints: { open_decisions: [{ key: "d", verb: "needs-decision", summary: "ageless" }] } }),
]);
equal("unknown ages sort first, then oldest evidence first",
  ordered.items.map((item) => item.id).join(","), "ageless,ancient,middle,recent");
equal("a status-derived age names its evidence", ordered.items[1].age_source, "last update");
equal("a pull-request age names its evidence",
  inboxOf([task("p", { pr: pr(GREEN) })]).items[0].age_source, "status observed");

// --- badge counts ----------------------------------------------------------

const counted = inboxOf([
  task("d", { hints: { open_decisions: [{ key: "a", verb: "needs-decision", summary: "choose" }] } }),
  task("c", { hints: { open_decisions: [{ key: "b", verb: "blocked", summary: "needs a password reset" }] } }),
  task("m", { pr: pr(GREEN) }),
  task("u", { pr: pr({}, { freshness: "absent" }) }),
]);
equal("badge totals count items, not reasons", counted.counts.total, 4);
equal("decisions are counted", counted.counts.decisions, 1);
equal("credential requests are counted", counted.counts.credentials, 1);
equal("merge-ready pull requests are counted", counted.counts.merge_ready, 1);
equal("unknown pull requests are counted", counted.counts.unknown, 1);

// --- health strip ----------------------------------------------------------

function health(snapshot, envelope = { status: { phase: "ready", last_success_age_seconds: 1 } }) {
  const built = buildHealth(snapshot, envelope);
  return { overall: built.overall, byId: Object.fromEntries(built.signals.map((signal) => [signal.id, signal])) };
}
// The tolerated-quiet window a real snapshot carries in
// supervision.watcher.quiet_allowance_seconds, which bin/fm-supervision-lib.sh
// owns and bin/fm-watch.sh measures a busy worker's last completed turn
// against. This module holds no seconds constant of its own, so the fixture
// has to supply the window the same way the snapshot does.
const QUIET_ALLOWANCE = 3_600;
const QUIET_AMBER = QUIET_ALLOWANCE * POLICY.activityAmberFraction;

function fleet(overrides = {}) {
  return {
    tasks: [],
    main_inventory: { valid: true, orphan_in_flight: [] },
    supervision: {
      watcher: {
        present: true,
        age_seconds: 5,
        grace_seconds: 120,
        // The window bin/fm-supervision-lib.sh owns and the snapshot publishes.
        // Task activity judges quiet against this and never a constant of its
        // own, so the fixture supplies it exactly as a real snapshot does.
        quiet_allowance_seconds: QUIET_ALLOWANCE,
        stale: false,
      },
      afk: { active: false },
    },
    ...overrides,
  };
}

equal("a beating watcher inside its window is green", health(fleet()).byId.supervision.tone, "green");
equal("a healthy fleet reads healthy", health(fleet()).overall.label, "Healthy");
equal("a watcher past half its grace window is amber",
  health(fleet({ supervision: { watcher: { present: true, age_seconds: 61, grace_seconds: 120, stale: false }, afk: { active: false } } })).byId.supervision.tone, "amber");
equal("a snapshot-declared stale watcher is red",
  health(fleet({ supervision: { watcher: { present: true, age_seconds: 500, grace_seconds: 120, stale: true }, afk: { active: false } } })).byId.supervision.tone, "red");
equal("a stopped watcher with no beacon is red",
  health(fleet({ supervision: { watcher: { present: false }, afk: { active: false } } })).byId.supervision.tone, "red");
equal("a beacon with no readable age is unknown, not green",
  health(fleet({ supervision: { watcher: { present: true, grace_seconds: 120, stale: false }, afk: { active: false } } })).byId.supervision.tone, "unknown");

equal("away mode is amber",
  health(fleet({ supervision: { watcher: { present: true, age_seconds: 5, grace_seconds: 120, stale: false }, afk: { active: true } } })).byId.away.tone, "amber");

const dead = health(fleet({ tasks: [task("gone", { endpoint: { exists: false, status: "absent" } })] }));
equal("a task whose runtime endpoint is gone is red", dead.byId.workers.tone, "red");
equal("a dead worker makes the fleet need attention", dead.overall.label, "Attention needed");

const deadMate = health(fleet({ tasks: [task("mate", { kind: "secondmate", endpoint: { exists: true, status: "dead" } })] }));
equal("a dead secondmate agent is red", deadMate.byId.secondmates.tone, "red");
const unknownMate = health(fleet({ tasks: [task("mate", { kind: "secondmate", endpoint: { exists: true, status: "unknown" } })] }));
equal("an unreadable secondmate agent is unknown, not green", unknownMate.byId.secondmates.tone, "unknown");
equal("a present endpoint on an ordinary task counts as present",
  health(fleet({ tasks: [task("worker", { endpoint: { exists: true, status: "unknown" } })] })).byId.workers.tone, "green");

const orphaned = health(fleet({ main_inventory: { valid: false, reason: "in-flight backlog item has no child metadata: ghost", orphan_in_flight: ["ghost"] } }));
equal("an orphaned in-flight item is red", orphaned.byId.inventory.tone, "red");
check("the orphan is named", orphaned.byId.inventory.detail.includes("ghost"), orphaned.byId.inventory.detail);
equal("a missing inventory check is unknown, not green",
  health(fleet({ main_inventory: undefined })).byId.inventory.tone, "unknown");

equal("a slow fleet is amber",
  health(fleet({ tasks: [task("slow", { paths: { status_log: { last_event_age_seconds: QUIET_AMBER } } })] })).byId.events.tone, "amber");
equal("a stopped fleet is red",
  health(fleet({ tasks: [task("stopped", { paths: { status_log: { last_event_age_seconds: QUIET_ALLOWANCE } } })] })).byId.events.tone, "red");
equal("an unreadable event age is unknown, not green",
  health(fleet({ tasks: [task("silent", { paths: { status_log: {} } })] })).byId.events.tone, "unknown");
equal("a completed task no longer counts against activity",
  health(fleet({ tasks: [task("landed", { card: { column: "done" }, paths: { status_log: { last_event_age_seconds: 99_999 } } })] })).byId.events.tone, "green");

// --- quiet the crew brief instructs is not degradation ---------------------
//
// This is the defect the signal shipped with. The generated brief tells every
// worker to append only on phase changes a supervisor would act on, and a
// single long agent step in this fleet runs tens of minutes, so a healthy
// worker is INSTRUCTED to say nothing for far longer than the 900s the strip
// used to alarm at. The two cases below are the two ways a task can be quiet
// and demonstrably fine, and both must read green at a duration that used to
// read amber or red.
//
// The window itself is not this module's to pick. Both cases would fail if a
// seconds constant came back here and drifted below the window supervision
// applies to the same silence.

const INSTRUCTED_QUIET = 2_400; // 40 minutes: past the old 900s amber, inside one long step.

// 1. Caught in the act. The snapshot's reconciled current state came from a
//    live source - the validation run's own step, or the harness's busy verdict
//    this refresh - so the task is not quiet, it is working.
const observedQuiet = health(fleet({ tasks: [task("deep-in-a-step", {
  current_state: { state: "working", source: "pane", detail: "harness busy (claude-hook)" },
  paths: { status_log: { last_event_age_seconds: INSTRUCTED_QUIET } },
})] }));
equal("a task observed working is not aged on its reporting silence", observedQuiet.byId.events.tone, "green");
equal("and the fleet it is the only member of reads healthy", observedQuiet.overall.label, "Healthy");
check("the card says why it was not aged",
  observedQuiet.byId.events.detail.includes("live state reading"), observedQuiet.byId.events.detail);

// 2. Between steps. Nothing live could be read, but the runtime completed a
//    turn recently, which is activity the worker never had to report.
const turnedRecently = health(fleet({ tasks: [task("between-steps", {
  current_state: { state: "unknown", source: "run-attribution", detail: "run on another branch" },
  paths: {
    status_log: { last_event_age_seconds: INSTRUCTED_QUIET },
    turn_ended: { present: true, last_turn_age_seconds: 90 },
  },
})] }));
equal("a recent completed turn answers for a quiet status log", turnedRecently.byId.events.tone, "green");
check("and the age shown is the activity, not the reporting silence",
  turnedRecently.byId.events.value === `oldest ${formatAge(90)}`, turnedRecently.byId.events.value);

// The exemption is bounded exactly as supervision bounds it: a busy worker is
// excused until its last completed turn reaches the window, not forever.
equal("a task observed working with no turn inside the window is amber",
  health(fleet({ tasks: [task("busy-but-turnless", {
    current_state: { state: "working", source: "pane", detail: "harness busy (claude-hook)" },
    paths: { status_log: { last_event_age_seconds: QUIET_ALLOWANCE } },
  })] })).byId.events.tone, "amber");

// A remembered reading is not a live one. run-step-degraded replays a step the
// lookup could not re-confirm, so it must not buy the exemption a busy verdict
// buys - otherwise an unreachable daemon silently excuses the whole fleet.
equal("a replayed run step does not excuse quiet",
  health(fleet({ tasks: [task("remembered", {
    current_state: { state: "working", source: "run-step-degraded", detail: "run lookup unavailable" },
    paths: { status_log: { last_event_age_seconds: QUIET_ALLOWANCE } },
  })] })).byId.events.tone, "red");

// A current-state read this snapshot could not take is the same: it names its
// own failure rather than reporting a state, and it excuses nothing.
equal("a timed-out current-state read does not excuse quiet",
  health(fleet({ tasks: [task("unread", {
    current_state: { state: "unknown", source: "timeout", detail: "the current-state read did not finish" },
    paths: { status_log: { last_event_age_seconds: QUIET_ALLOWANCE } },
  })] })).byId.events.tone, "red");

// The window is the snapshot's to state. Without it there is no threshold to
// judge against, and inventing one here is the defect; an unjudgeable reading
// is unknown, never a pass.
const noWindow = health(fleet({
  tasks: [task("quiet", { paths: { status_log: { last_event_age_seconds: 30 } } })],
  supervision: { watcher: { present: true, age_seconds: 5, grace_seconds: 120, stale: false }, afk: { active: false } },
}));
equal("a snapshot with no tolerated-quiet window cannot judge activity", noWindow.byId.events.tone, "unknown");
equal("and the fleet is not summarized as healthy", noWindow.overall.label, "Partly unknown");

// --- a declared wait is not silence ---------------------------------------
//
// The snapshot decides what counts as a declared wait with bin/fm-classify-lib.sh,
// the same vocabulary the supervision watcher uses, and reports it as
// hints.last_event_declared_wait. This module reads that verdict and never
// reimplements it.

function waitingTask(id, ageSeconds) {
  return task(id, {
    card: { column: "waiting", action: "recheck" },
    hints: { open_decisions: [], last_event_declared_wait: true },
    paths: { status_log: { last_event_age_seconds: ageSeconds } },
  });
}

const parked = health(fleet({ tasks: [waitingTask("parked-a", 228_489), waitingTask("parked-b", 213_981)] }));
equal("a fleet of declared waits is not a stalled fleet", parked.byId.events.tone, "green");
check("a declared wait is reported as its own state, not as an age",
  parked.byId.events.value === "2 waiting by design", parked.byId.events.value);
check("the longest declared wait is still stated", parked.byId.events.detail.includes(formatAge(228_489)), parked.byId.events.detail);
equal("a home whose only quiet was declared reads healthy", parked.overall.label, "Healthy");

// The property the elapsed-time check was protecting survives: a task that went
// quiet WITHOUT declaring it still turns the signal.
const mixed = health(fleet({ tasks: [
  waitingTask("parked", 228_489),
  task("silent", { paths: { status_log: { last_event_age_seconds: QUIET_ALLOWANCE } } }),
] }));
equal("an undeclared silence still turns the signal red", mixed.byId.events.tone, "red");
check("the red verdict comes from the undeclared task alone",
  mixed.byId.events.value === `oldest ${formatAge(QUIET_ALLOWANCE)}`, mixed.byId.events.value);
check("the declared waits are still accounted for", mixed.byId.events.detail.includes("1 further task"), mixed.byId.events.detail);

equal("an undeclared silence past the amber threshold is amber",
  health(fleet({ tasks: [waitingTask("parked", 500_000), task("slow", { paths: { status_log: { last_event_age_seconds: QUIET_AMBER } } })] })).byId.events.tone, "amber");

// The declaration is a positive claim. Anything short of it - an older snapshot
// that never carried the field, a null, a string - keeps the strict verdict,
// because an unproven declaration must not excuse a silent task.
for (const [label, value] of [["absent", undefined], ["null", null], ["a string", "true"], ["false", false]]) {
  const unproven = health(fleet({ tasks: [task("quiet", {
    hints: { open_decisions: [], last_event_declared_wait: value },
    paths: { status_log: { last_event_age_seconds: QUIET_ALLOWANCE } },
  })] }));
  equal(`an ${label} declaration does not excuse a silent task`, unproven.byId.events.tone, "red");
}

// An unreadable age on a working task is still unknown; a declared wait beside
// it neither hides that nor invents an age of its own.
const unreadableBeside = health(fleet({ tasks: [waitingTask("parked", 228_489), task("silent", { paths: { status_log: {} } })] }));
equal("an unreadable working-task age stays unknown", unreadableBeside.byId.events.tone, "unknown");
const agelessWait = health(fleet({ tasks: [waitingTask("parked", null)] }));
equal("a declared wait with no readable age is still not a stalled fleet", agelessWait.byId.events.tone, "green");
check("and states no duration it cannot read",
  agelessWait.byId.events.detail === "Every live task declared its own wait. Nothing has gone quiet without saying so.",
  agelessWait.byId.events.detail);

// --- a parked agent was exited on purpose ---------------------------------
//
// Parking a captain-gated task exits its agent deliberately, so its absent
// endpoint is the runbook working rather than a worker that died. Workers reads
// the SAME hints.last_event_declared_wait verdict Task activity reads, so the
// pause vocabulary stays defined once in bin/fm-classify-lib.sh.

function parkedWorker(id, ageSeconds = 228_489) {
  return task(id, {
    card: { column: "waiting", action: "recheck" },
    endpoint: { exists: false, status: "absent" },
    hints: { open_decisions: [], last_event_declared_wait: true },
    paths: { status_log: { last_event_age_seconds: ageSeconds } },
  });
}

const parkedOnly = health(fleet({ tasks: [parkedWorker("parked-a"), parkedWorker("parked-b")] }));
equal("a deliberately parked agent is not a missing worker", parkedOnly.byId.workers.tone, "green");
check("parked workers are reported as waiting, not counted gone",
  parkedOnly.byId.workers.value === "2 waiting by design", parkedOnly.byId.workers.value);
check("and the waiting tasks are named rather than silently hidden",
  parkedOnly.byId.workers.detail.includes("parked-a") && parkedOnly.byId.workers.detail.includes("parked-b"),
  parkedOnly.byId.workers.detail);
equal("a home whose only absent endpoints were parked reads healthy", parkedOnly.overall.label, "Healthy");

const parkedBesideLive = health(fleet({ tasks: [parkedWorker("parked"), task("busy")] }));
equal("a parked agent beside a live one is still green", parkedBesideLive.byId.workers.tone, "green");
check("the live worker is still counted present",
  parkedBesideLive.byId.workers.value === "1 present · 0 gone · 0 unknown · 1 waiting",
  parkedBesideLive.byId.workers.value);

// The exclusion runs in both directions. A declared wait whose endpoint is still
// PRESENT is dropped from the counts too: whatever that endpoint currently says
// is not evidence about fleet health, so counting it present would let the card
// read on a fact it deliberately stopped trusting.
const parkedHoldingEndpoint = health(fleet({ tasks: [waitingTask("parked-with-endpoint", 228_489), task("busy")] }));
equal("a declared wait with a present endpoint does not colour the card",
  parkedHoldingEndpoint.byId.workers.tone, "green");
check("and is counted as waiting rather than as a second present worker",
  parkedHoldingEndpoint.byId.workers.value === "1 present · 0 gone · 0 unknown · 1 waiting",
  parkedHoldingEndpoint.byId.workers.value);

// The genuine alarm this signal exists for must survive. A worker that vanished
// without declaring anything is red even while a declared wait sits beside it.
const vanished = health(fleet({ tasks: [
  parkedWorker("parked"),
  task("vanished", { endpoint: { exists: false, status: "absent" } }),
] }));
equal("a worker that vanished without declaring a wait is still red", vanished.byId.workers.tone, "red");
check("the red verdict names the undeclared task alone",
  vanished.byId.workers.detail.startsWith("No runtime endpoint for vanished,"), vanished.byId.workers.detail);
check("and the declared wait is not counted gone",
  vanished.byId.workers.value === "0 present · 1 gone · 0 unknown · 1 waiting", vanished.byId.workers.value);
equal("an undeclared vanished worker still needs attention", vanished.overall.label, "Attention needed");

// More than one worker can vanish at once, and the qualifier has to cover every
// name in the list rather than reading as attaching to the last one. A captain
// who parses "vanished-a, vanished-b, which declared no wait" as qualifying
// vanished-b alone concludes the exact opposite of the truth about vanished-a,
// which is the distinction this card exists to draw.
const vanishedPair = health(fleet({ tasks: [
  parkedWorker("parked"),
  task("vanished-a", { endpoint: { exists: false, status: "absent" } }),
  task("vanished-b", { endpoint: { exists: false, status: "absent" } }),
] }));
equal("two workers that vanished without declaring a wait are still red", vanishedPair.byId.workers.tone, "red");
check("the qualifier covers every named worker, not just the last",
  vanishedPair.byId.workers.detail.startsWith("No runtime endpoint for vanished-a, vanished-b, none of which declared a wait."),
  vanishedPair.byId.workers.detail);
check("and the declared wait is still accounted for beside them",
  vanishedPair.byId.workers.value === "0 present · 2 gone · 0 unknown · 1 waiting", vanishedPair.byId.workers.value);

// The declaration is a positive claim here too: anything short of `true` keeps
// the strict endpoint verdict, so an unproven declaration cannot hide a death.
for (const [label, value] of [["absent", undefined], ["null", null], ["a string", "true"], ["false", false]]) {
  const unproven = health(fleet({ tasks: [task("gone", {
    endpoint: { exists: false, status: "absent" },
    hints: { open_decisions: [], last_event_declared_wait: value },
  })] }));
  equal(`an ${label} declaration does not excuse a missing endpoint`, unproven.byId.workers.tone, "red");
}

// An unreadable endpoint on a working task is still unknown, and a declared wait
// beside it neither hides that nor turns it green.
const unreadableEndpoint = health(fleet({ tasks: [
  parkedWorker("parked"),
  task("murky", { endpoint: { exists: null, status: "unknown" } }),
] }));
equal("an unreadable working endpoint stays unknown", unreadableEndpoint.byId.workers.tone, "unknown");

// A secondmate reports only when it is asked to do something, so its silence is
// health, not a stalled task. It is answered for by its own signal instead.
const idleMate = health(fleet({ tasks: [task("mate", {
  kind: "secondmate",
  endpoint: { exists: true, status: "alive" },
  card: { column: "secondmate", action: "route_work" },
  paths: { status_log: { last_event_age_seconds: QUIET_ALLOWANCE * 2 } },
})] }));
equal("an idle secondmate never counts as a stalled task", idleMate.byId.events.tone, "green");
equal("a secondmate answers through its own signal", idleMate.byId.secondmates.tone, "green");
equal("a home holding only an idle secondmate reads healthy", idleMate.overall.label, "Healthy");

// --- uncertainty never summarizes as healthy -------------------------------

const partly = health(fleet({ main_inventory: undefined }));
equal("one unknown reading blocks a healthy summary", partly.overall.tone, "unknown");
equal("an unknown fleet says so", partly.overall.label, "Partly unknown");

const staleEnvelope = { status: { phase: "last_good", last_success_age_seconds: 400, stale: true } };
const unverified = health(fleet({ tasks: [task("gone", { endpoint: { exists: false, status: "absent" } })] }), staleEnvelope);
equal("a stale snapshot demotes its green readings to unknown", unverified.byId.supervision.tone, "unknown");
check("a demoted reading says why", unverified.byId.supervision.detail.includes("Unverified"), unverified.byId.supervision.detail);
equal("a stale snapshot keeps a red reading red", unverified.byId.workers.tone, "red");
equal("the first-run snapshot signal is unknown, not green",
  health(fleet(), { status: { phase: "first_run" } }).byId.snapshot.tone, "unknown");
equal("an unavailable snapshot is red",
  health(fleet(), { status: { phase: "unavailable", error: { message: "snapshot exited 7" } } }).byId.snapshot.tone, "red");

// --- degenerate input ------------------------------------------------------

const empty = buildInbox(null);
equal("a null snapshot yields no items", empty.items.length, 0);
equal("a null snapshot yields a zero total", empty.counts.total, 0);
const nothing = buildHealth(null, null);
check("a null snapshot is never summarized as healthy",
  nothing.overall.tone !== "green" && nothing.overall.label !== "Healthy", nothing.overall.label);
equal("a null snapshot reports no supervision", nothing.signals.find((signal) => signal.id === "supervision").tone, "red");

if (failures.length) {
  for (const failure of failures) console.error(`  - ${failure}`);
  console.error(`${failures.length} inbox policy assertion(s) failed`);
  process.exit(1);
}
})().catch((error) => { console.error(error); process.exit(1); });
NODE

pass "pull-request readiness is green only when normalized checks, review, and mergeability agree"
pass "missing, stale, and out-of-enumeration provider data render as explicit unknown"
pass "merged and closed pull requests stay terminal at any observation age"
pass "inbox items deduplicate overlapping signals, keep full text, and sort oldest evidence first"
pass "health signals produce the documented states and never summarize uncertainty as healthy"
