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
  usage: { available: false, reason: "disabled", collection: "disabled", tasks: {}, projects: {} },
});
check("a disabled read is not a fault", disabled.fault === false);

// A ready read with project rows keeps unattributed on screen and sorts by tokens.
const ready = buildUsage({
  schema: "fm-dashboard-history.v1",
  usage: {
    available: true,
    reason: null,
    collection: "ready",
    source: "fm-usage-report.v1",
    stale: false,
    tasks: {},
    projects: {
      firstmate: { events: 100, sessions: 2, total_tokens: 1000 },
      "(unknown)": { events: 50, sessions: 5, total_tokens: 500 },
      "(firstmate supervision)": { events: 200, sessions: 1, total_tokens: 2000 },
      "ark-business": { events: 10, sessions: 1, total_tokens: 100 },
    },
  },
});
equal("a ready envelope renders rows", ready.shape, "rows");
equal("first place is the largest project", ready.rows[0].key, "(firstmate supervision)");
equal("second place is the next largest", ready.rows[1].key, "firstmate");
equal("unattributed is kept in the rows", ready.rows[2].key, "(unknown)");
check("percentage for the largest row is computed", ready.rows[0].share === (2000 / 3600 * 100));
check("total tokens sum every row", ready.total_tokens === 3600);
check("total events sum every row", ready.total_events === 360);

// The helper that decides how to label a row must not invent project names.
equal("supervision gets a readable label", projectLabel("(firstmate supervision)"), "Firstmate supervision");
equal("unknown gets a readable label", projectLabel("(unknown)"), "Unattributed");
equal("a real project keeps its name", projectLabel("ark-business"), "ark-business");
check("supervision is amber-toned", projectTone("(firstmate supervision)") === "amber");
check("unknown is grey-toned", projectTone("(unknown)") === "grey");
check("a real project is blue-toned", projectTone("ark-business") === "blue");
check("unattributed key detection works", isUnattributed("(unknown)") === true);
check("real projects are not unattributed", isUnattributed("firstmate") === false);

// A stale read is still available and keeps its totals.
const stale = buildUsage({
  usage: {
    available: true,
    reason: null,
    collection: "ready",
    stale: true,
    tasks: {},
    projects: { firstmate: { events: 1, total_tokens: 10 } },
  },
});
check("a stale read is still ready-shaped", stale.shape === "rows");
check("a stale read is marked stale", stale.stale === true);

if (failures.length) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exit(1);
}
console.log("dashboard usage view behavior verified");
})();
NODE

printf '\nall fm-dashboard-usage tests passed\n'
