#!/usr/bin/env bash
# Behavior tests for the dashboard's hash router (assets/dashboard/router.js).
#
# The contract under test is mutual exclusivity: a route resolves to EXACTLY
# ONE view, and inactiveViews() names every view that must be absent for it.
# Both directions are asserted, because a router test that only checks the
# active view passes just as well against a page that renders every section
# at once - the shape this rebuild exists to end.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

node - "$ROOT/assets/dashboard/router.js" <<'NODE' || fail "dashboard router contract failed"
const { pathToFileURL } = require("node:url");

(async () => {
const router = await import(pathToFileURL(process.argv[2]).href);
const { VIEWS, DEFAULT_VIEW, TASK_VIEW, parseHash, hashFor, viewRoute, taskRoute, activeViews, inactiveViews } = router;

const failures = [];
function check(label, condition, detail = "") {
  if (!condition) failures.push(`${label}${detail ? `: ${detail}` : ""}`);
}
function equal(label, actual, expected) {
  check(label, JSON.stringify(actual) === JSON.stringify(expected),
    `expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
}

const ALL = [...VIEWS, TASK_VIEW];

// --- every hash resolves to exactly one view, and the rest are inactive ------
for (const view of VIEWS) {
  equal(`#/${view} parses to its view`, parseHash(`#/${view}`), { view });
  const active = activeViews(`#/${view}`);
  equal(`#/${view} activates exactly one view`, active, [view]);
  const inactive = inactiveViews(`#/${view}`);
  equal(`#/${view} deactivates every other view`, inactive.slice().sort(), ALL.filter((v) => v !== view).sort());
  check(`#/${view} active and inactive views are disjoint`, !inactive.includes(active[0]));
  equal(`#/${view} active plus inactive covers every view`, [...active, ...inactive].sort(), ALL.slice().sort());
}

// --- the task detail route carries its id and excludes the five pages --------
equal("a task hash parses to the task view with its id", parseHash("#/task/fm-abc.1_x-2"), { view: TASK_VIEW, taskId: "fm-abc.1_x-2" });
equal("the task route activates only the task view", activeViews("#/task/fm-abc"), [TASK_VIEW]);
equal("the task route deactivates all five pages", inactiveViews("#/task/fm-abc").slice().sort(), VIEWS.slice().sort());

// --- garbage lands on the default view, never a blank page -------------------
for (const hash of ["", "#", "#/", "#nonsense", "#/nonsense", "#inbox", "#/task/", "#/task/../../etc", "#/task/%2e%2e", "#/needs/extra?x=1", null, undefined, 42]) {
  const route = parseHash(hash);
  equal(`garbage hash ${JSON.stringify(String(hash))} lands on the default view`, route.view, DEFAULT_VIEW);
  equal(`garbage hash ${JSON.stringify(String(hash))} still activates exactly one view`, activeViews(route).length, 1);
}

// --- a task id that would escape the id alphabet is refused ------------------
check("a traversal-shaped task id does not parse as a task route", parseHash("#/task/a/b").view !== TASK_VIEW);
equal("taskRoute refuses an empty id", taskRoute(""), null);
equal("taskRoute refuses a dot-leading id", taskRoute(".hidden"), null);
equal("taskRoute accepts a real id", taskRoute("fm-x1"), { view: TASK_VIEW, taskId: "fm-x1" });
equal("taskRoute accepts a dash-leading id", taskRoute("-fm-x1"), { view: TASK_VIEW, taskId: "-fm-x1" });
equal("taskRoute accepts an underscore-leading id", taskRoute("_fm-x1"), { view: TASK_VIEW, taskId: "_fm-x1" });
equal("parseHash accepts a dash-leading id", parseHash("#/task/-fm-x1"), { view: TASK_VIEW, taskId: "-fm-x1" });
equal("taskRoute accepts the 128-character limit", taskRoute(`_${"a".repeat(127)}`)?.view, TASK_VIEW);
equal("taskRoute refuses 129 characters", taskRoute(`_${"a".repeat(128)}`), null);
equal("taskRoute refuses traversal pairs", taskRoute("fm..x"), null);

// --- canonical hashes round-trip ---------------------------------------------
for (const view of VIEWS) equal(`hashFor round-trips #/${view}`, hashFor(parseHash(`#/${view}`)), `#/${view}`);
equal("hashFor round-trips a task route", hashFor(parseHash("#/task/fm-abc")), "#/task/fm-abc");
equal("hashFor of nothing is the default view", hashFor(null), `#/${DEFAULT_VIEW}`);
equal("viewRoute refuses an unknown view", viewRoute("nonsense"), null);

if (failures.length) {
  console.error(`${failures.length} router contract failure(s):`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log("dashboard router contract verified");
})().catch((error) => { console.error(error); process.exit(1); });
NODE

pass "a route resolves to exactly one view and names every view that must be absent"
printf '\nall fm-dashboard-router tests passed\n'
