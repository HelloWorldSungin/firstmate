#!/usr/bin/env bash
# Behavior tests for the dashboard's per-project usage view.
#
# The view must keep the unattributed share on screen, never render a failed
# read as a zero, and sort projects by their token totals. docs/dashboard.md
# owns the human statement of the policy these cases pin.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

node - "$ROOT/assets/dashboard/usage.js" <<'NODE' || fail "dashboard usage view behavior failed"
const { pathToFileURL } = require("node:url");

(async () => {
const usageModule = await import(pathToFileURL(process.argv[2]).href);
const { buildUsage, isUnattributed, projectLabel, projectTone, formatTokens } = usageModule;

const failures = [];
function check(label, condition, detail = "") {
  if (!condition) failures.push(`${label}${detail ? `: ${detail}` : ""}`);
}
function equal(label, actual, expected) {
  check(label, actual === expected, `expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
}

// A missing usage envelope is pending, not empty and not zero.
const pending = buildUsage(null);
equal("a missing envelope is pending", pending.shape, "pending");
check("pending has no rows", pending.rows.length === 0);

// A failed read renders as unavailable with a reason, never as zero rows.
const failed = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "ready", refreshing: false },
  usage: {
    available: false,
    reason: "the store is locked",
    collection: "operational",
    source: null,
    stale: false,
    tasks: {},
    projects: {},
  },
});
equal("a failed read is unavailable", failed.shape, "unavailable");
equal("a failed read carries its reason", failed.reason, "the store is locked");
check("a failed read is flagged as a fault", failed.fault === true);
check("a failed read has no rows", failed.rows.length === 0);

// A disabled read is unavailable but not a fault.
const disabled = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "ready", refreshing: false },
  usage: { available: false, reason: "token usage reads are disabled for this dashboard", collection: "disabled", tasks: {}, projects: {} },
});
check("a disabled read is not a fault", disabled.fault === false);
// A home that collects nothing and a read that missed are opposite claims: the
// page draws an alarm for one and calm copy for the other, so the model has to
// keep them apart rather than folding both into "unavailable".
equal("a disabled read is absent, not a failed read", disabled.shape, "absent");
const absent = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "ready", refreshing: false },
  usage: { available: false, reason: "token usage is not collected in this home", collection: "absent", tasks: {}, projects: {} },
});
equal("a home with no collector is absent", absent.shape, "absent");
check("a home with no collector is not a fault", absent.fault === false);
// The fault state is the one a reader can act on, and it is the state the page
// keys its alarm on, so it must survive as its own answer.
equal("an operational failure is unavailable", failed.readState, "unavailable");
check("an operational failure is the state the alarm is keyed on", failed.fault === true);
// A collection this page does not recognize is not quietly called calm.
const unknownCollection = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "ready", refreshing: false },
  usage: { available: false, reason: "who knows", collection: "something-new", tasks: {}, projects: {} },
});
equal("an unrecognized collection state is unavailable", unknownCollection.shape, "unavailable");

// A history read that failed outright carries no usage rollup at all. That is a
// read that did not land, not a read still on its way: rendering it as pending
// would promise a number that is never coming.
const failedHistory = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "unavailable", refreshing: false, stale: false, error: { kind: "server_unreachable" } },
});
equal("a failed history read is unavailable, not pending", failedHistory.shape, "unavailable");
equal("a failed history read has no rows", failedHistory.rows.length, 0);

// The first poll of a fresh server has not answered yet, which IS pending.
const firstRun = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "first_run", refreshing: true, stale: false },
  usage: { available: false, reason: "token usage has not been read yet", collection: "absent", tasks: {}, projects: {} },
});
equal("the first read in flight is pending", firstRun.shape, "pending");

// The per-task and per-project rollups are separate reads. A project read that
// missed is unavailable here even though the task totals landed, and the task
// totals stay available for History.
const projectFailed = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "ready", refreshing: false },
  usage: {
    available: true,
    reason: null,
    collection: "ready",
    source: "fm-usage-report.v1",
    stale: false,
    tasks: { paid: { events: 2, total_tokens: 30 } },
    projects: {},
    projects_read: { available: false, reason: "the store is locked", collection: "operational", stale: false },
  },
});
equal("a failed project read is unavailable", projectFailed.shape, "unavailable");
equal("a failed project read carries its own reason", projectFailed.reason, "the store is locked");
check("a failed project read is a fault", projectFailed.fault === true);

// The mirror case: the task read missed and the project read landed, so the
// project rows are still shown.
const taskFailed = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "ready", refreshing: false },
  usage: {
    available: false,
    reason: "token usage could not be read (exit_nonzero)",
    collection: "operational",
    source: "fm-usage-report.v1",
    stale: false,
    tasks: {},
    projects: { firstmate: { events: 1, sessions: 1, input_tokens: 3, output_tokens: 2, total_tokens: 5 } },
    projects_read: { available: true, reason: null, collection: "ready", stale: false },
  },
});
equal("a failed task read does not darken the project rows", taskFailed.shape, "rows");
check("a landed project read is not a fault", taskFailed.fault === false);

// A ready read with project rows keeps unattributed on screen and sorts by
// work tokens (input + output), not raw total_tokens. A row that is large only
// because of cache reads must not dominate the ranking.
const ready = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "ready", refreshing: false },
  usage: {
    available: true,
    reason: null,
    collection: "ready",
    source: "fm-usage-report.v1",
    stale: false,
    tasks: {},
    projects: {
      firstmate: { events: 100, sessions: 2, input_tokens: 400, output_tokens: 100, cache_read_tokens: 0, cache_write_tokens: 0, total_tokens: 500 },
      "(unknown)": { events: 50, sessions: 5, input_tokens: 200, output_tokens: 50, cache_read_tokens: 0, cache_write_tokens: 0, total_tokens: 250 },
      "(firstmate supervision)": { events: 200, sessions: 1, input_tokens: 50, output_tokens: 10, cache_read_tokens: 1940, cache_write_tokens: 0, total_tokens: 2000 },
      "ark-business": { events: 10, sessions: 1, input_tokens: 40, output_tokens: 10, cache_read_tokens: 0, cache_write_tokens: 0, total_tokens: 50 },
    },
  },
});
equal("a ready envelope renders rows", ready.shape, "rows");
equal("first place is the largest by work tokens", ready.rows[0].key, "firstmate");
equal("supervision with high cache but low work is ranked lower", ready.rows[1].key, "(unknown)");
equal("unattributed is kept in the rows", ready.rows[2].key, "(firstmate supervision)");
check("percentage for the largest row is computed from work tokens", Math.abs(ready.rows[0].share - (500 / 860 * 100)) < 0.01);
check("total tokens sum every row", ready.total_tokens === 2800);
check("total work tokens sum every row", ready.total_work === 860);
check("total events sum every row", ready.total_events === 360);
// The unattributed and supervision rows are spend, not projects.
equal("the project count excludes the unattributed and supervision rows", ready.project_count, 2);
check("every row is still rendered", ready.rows.length === 4);

// The helper that decides how to label a row must not invent project names.
equal("supervision gets a readable label", projectLabel("(firstmate supervision)"), "Firstmate supervision");
equal("unknown gets a readable label", projectLabel("(unknown)"), "Unattributed");
equal("a real project keeps its name", projectLabel("ark-business"), "ark-business");
// A project value that arrives path-shaped never renders as a host path.
equal("a clone path renders as its project name", projectLabel("/home/sungin/projects/demo"), "demo");
equal("a trailing slash contributes nothing", projectLabel("/home/sungin/projects/demo/"), "demo");
check("supervision is amber-toned", projectTone("(firstmate supervision)") === "amber");
check("unknown is grey-toned", projectTone("(unknown)") === "grey");
check("a real project is blue-toned", projectTone("ark-business") === "blue");
check("unattributed key detection works", isUnattributed("(unknown)") === true);
check("real projects are not unattributed", isUnattributed("firstmate") === false);

// A stale read is still available and keeps its totals.
const stale = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "ready", refreshing: false },
  usage: {
    available: true,
    reason: "the store is locked",
    collection: "ready",
    stale: true,
    tasks: {},
    projects: { firstmate: { events: 1, total_tokens: 10 } },
  },
});
check("a stale read is still ready-shaped", stale.shape === "rows");
check("a stale read is marked stale", stale.stale === true);

// The history poll itself can go stale. The server only refreshes the usage
// rollup on a successful history read, so a last_good envelope is serving usage
// of that same vintage and the page has to say so rather than present it fresh.
const lastGood = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "last_good", refreshing: false, stale: true, error: { kind: "history_refresh_failed" } },
  usage: {
    available: true,
    reason: null,
    collection: "ready",
    stale: false,
    tasks: {},
    projects: { firstmate: { events: 1, sessions: 1, input_tokens: 6, output_tokens: 4, total_tokens: 10 } },
    projects_read: { available: true, reason: null, collection: "ready", stale: false },
  },
});
equal("a last-good envelope still renders its rows", lastGood.shape, "rows");
check("a last-good envelope is disclosed as stale", lastGood.stale === true);

// A phase this page does not recognize is a document it cannot read. Neither
// "pending" nor "absent" would be true, and both would read as reassurance.
const unknownPhase = buildUsage({
  schema: "fm-dashboard-history.v1",
  status: { phase: "something-new", refreshing: false },
  usage: {
    available: true,
    reason: null,
    collection: "ready",
    stale: false,
    tasks: {},
    projects: { firstmate: { events: 1, total_tokens: 10 } },
    projects_read: { available: true, reason: null, collection: "ready", stale: false },
  },
});
equal("an unrecognized envelope phase is unavailable", unknownPhase.shape, "unavailable");

if (failures.length) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exit(1);
}
console.log("dashboard usage view behavior verified");
})();
NODE

printf '\nall fm-dashboard-usage tests passed\n'
