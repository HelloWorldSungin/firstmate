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
const { buildHealth, buildInbox, prReadiness, POLICY } = await import(pathToFileURL(process.argv[2]).href);

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
check("a captain-held row has no readable age", held.items[0].age_known === false);

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
function fleet(overrides = {}) {
  return {
    tasks: [],
    main_inventory: { valid: true, orphan_in_flight: [] },
    supervision: {
      watcher: { present: true, age_seconds: 5, grace_seconds: 120, stale: false },
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
  health(fleet({ tasks: [task("slow", { paths: { status_log: { last_event_age_seconds: POLICY.eventAmberSeconds } } })] })).byId.events.tone, "amber");
equal("a stopped fleet is red",
  health(fleet({ tasks: [task("stopped", { paths: { status_log: { last_event_age_seconds: POLICY.eventRedSeconds } } })] })).byId.events.tone, "red");
equal("an unreadable event age is unknown, not green",
  health(fleet({ tasks: [task("silent", { paths: { status_log: {} } })] })).byId.events.tone, "unknown");
equal("a completed task no longer counts against activity",
  health(fleet({ tasks: [task("landed", { card: { column: "done" }, paths: { status_log: { last_event_age_seconds: 99_999 } } })] })).byId.events.tone, "green");

// A secondmate reports only when it is asked to do something, so its silence is
// health, not a stalled task. It is answered for by its own signal instead.
const idleMate = health(fleet({ tasks: [task("mate", {
  kind: "secondmate",
  endpoint: { exists: true, status: "alive" },
  card: { column: "secondmate", action: "route_work" },
  paths: { status_log: { last_event_age_seconds: POLICY.eventRedSeconds * 2 } },
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
