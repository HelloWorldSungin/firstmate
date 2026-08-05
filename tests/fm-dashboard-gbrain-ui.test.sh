#!/usr/bin/env bash
# Behavior tests for the dashboard GBrain panel rendering: the data layer
# the page consumes, the failure reasons the search results render with,
# and the way the panel degrades when one path is broken while another
# stays up.
#
# The data layer is the part under test here. It is pure: every value is
# derived from one envelope and the assertions never need a DOM. The
# rendering layer (paintGBrainPanel, paintGBrainSearchResults) is
# exercised by a real browser through chrome-devtools-axi on a live
# dashboard; this file pins the page contract so a refactor cannot drop
# or rewrite a field without breaking a test.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

MODULE="$ROOT/assets/dashboard/gbrain.js"

node - "$MODULE" <<'NODE' || fail "dashboard gbraintron panel data behavior failed"
const { pathToFileURL } = require("node:url");

(async () => {
const { buildGBrainHealth, searchFailure, searchReasonLabel } = await import(pathToFileURL(process.argv[2]).href);

const failures = [];
function check(label, condition, detail = "") {
  if (!condition) failures.push(`${label}${detail ? `: ${detail}` : ""}`);
}
function equal(label, actual, expected) {
  check(label, actual === expected, `expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
}
function deepEqual(label, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  check(label, a === e, a !== e ? `expected ${e}, received ${a}` : "");
}

// --- the configured home ---------------------------------------------------
//
// A configured home returns one card per panel layer. The labels are the
// operator's vocabulary; the order matters because the strip wraps
// left-to-right on a narrow screen and the reading order must be stable
// at every width.

const configuredEnvelope = {
  schema: "fm-gbrain-health.v1",
  status: { phase: "ready", last_success_at: "2026-08-05T21:07:59Z", last_success_age_seconds: 60 },
  config: { query_max_bytes: 1024, result_limit_max: 16 },
  health: {
    schema: "fm-gbrain-health.v1",
    home: "/home/firstmate",
    configured: true,
    version: "v0.42.69.0",
    index: { state: "ok", detail: "/home/firstmate/data/gbrain/pglite" },
    retrieval: {
      state: "ok",
      embedding: { state: "ok", model: "embed-test", endpoint: "http://127.0.0.1:11434/v1", detail: "ok" },
      reranker: { state: "ok", model: "rerank-test", endpoint: "http://127.0.0.1:8081/v1", detail: "ok" },
      main_brain: { state: "absent", model: null, endpoint: null, detail: "no main brain configured" },
    },
    synthesis: { state: "ok", model: "synth-test", endpoint: "http://127.0.0.1:9999/v1", detail: "ok" },
    capture: { enabled: true, archived: 81, pending: 0, failed: 0, unreadable: 0, last_capture_at: "2026-08-05T21:07:59Z", last_error: null },
    maintenance: { state: "ready", detail: null },
  },
};
{
  const view = buildGBrainHealth(configuredEnvelope);
  equal("configured home renders six cards", view.cards.length, 6);
  equal("configured home overall tone is green", view.overall.tone, "green");
  deepEqual("configured home card order", view.cards.map((c) => c.label),
    ["Brain", "Index", "Retrieval", "Synthesis", "Capture", "Maintenance"]);
  // The Brain card carries the version, not a state the operator reads
  // elsewhere - the version is the one fact the panel can quote verbatim.
  const brain = view.cards.find((c) => c.label === "Brain");
  equal("brain card carries the version", brain.value, "v0.42.69.0");
  equal("brain card tone is green", brain.tone, "green");
}

// --- the no-brain home -----------------------------------------------------
//
// A home without config/gbrain.json is configured: false and renders one
// card that says so. The dashboard must NOT invent a brain on this state.

const noBrainEnvelope = {
  schema: "fm-gbrain-health.v1",
  status: { phase: "ready" },
  config: { query_max_bytes: 1024, result_limit_max: 16 },
  health: {
    schema: "fm-gbrain-health.v1",
    home: "/home/firstmate",
    configured: false,
    version: null,
    index: { state: "absent", detail: "no brain configured" },
    retrieval: { state: "absent" },
    synthesis: { state: "unconfigured" },
    capture: { enabled: false, archived: 0, pending: 0, failed: 0, unreadable: 0 },
    maintenance: { state: "ready" },
  },
};
{
  const view = buildGBrainHealth(noBrainEnvelope);
  equal("no-brain home renders one card", view.cards.length, 1);
  equal("no-brain home sets noBrain flag", view.noBrain, true);
  equal("no-brain home overall tone is unknown", view.overall.tone, "unknown");
  equal("no-brain home card says not configured", view.cards[0].value, "not configured");
}

// --- degraded embedding with healthy synthesis -----------------------------
//
// The panel's two retrieval paths are read independently. A degraded local
// embedding does NOT flip synthesis to degraded, because synthesis is the
// hosted provider and local search keeps working. The panel must show that
// distinction at a glance.

const degradedEnvelope = {
  schema: "fm-gbrain-health.v1",
  status: { phase: "ready" },
  config: { query_max_bytes: 1024, result_limit_max: 16 },
  health: {
    schema: "fm-gbrain-health.v1",
    home: "/home/firstmate",
    configured: true,
    version: "v0.42.69.0",
    index: { state: "ok", detail: "ok" },
    retrieval: {
      state: "degraded",
      embedding: { state: "degraded", model: "embed-test", endpoint: "http://127.0.0.1:11434/v1", detail: "no answer at http://127.0.0.1:11434/v1" },
      reranker: { state: "ok", model: "rerank-test", endpoint: "http://127.0.0.1:8081/v1", detail: "ok" },
      main_brain: { state: "absent", model: null, endpoint: null, detail: "no main brain configured" },
    },
    synthesis: { state: "ok", model: "synth-test", endpoint: "http://127.0.0.1:9999/v1", detail: "ok" },
    capture: { enabled: true, archived: 10, pending: 0, failed: 0, unreadable: 0, last_capture_at: null, last_error: null },
    maintenance: { state: "ready", detail: null },
  },
};
{
  const view = buildGBrainHealth(degradedEnvelope);
  const tones = view.cards.map((c) => c.tone);
  // Brain / Index / Retrieval / Synthesis / Capture / Maintenance.
  // Retrieval flips amber because the embedding is degraded; synthesis stays
  // green because hosted synthesis is up.
  deepEqual("degraded embedding only flips retrieval", tones,
    ["green", "green", "amber", "green", "green", "green"]);
}

// --- degraded synthesis with healthy retrieval -----------------------------
//
// The inverse: a degraded hosted synthesis provider leaves local search
// unaffected.

const degradedSynthesisEnvelope = {
  schema: "fm-gbrain-health.v1",
  status: { phase: "ready" },
  config: { query_max_bytes: 1024, result_limit_max: 16 },
  health: {
    schema: "fm-gbrain-health.v1",
    home: "/home/firstmate",
    configured: true,
    version: "v0.42.69.0",
    index: { state: "ok", detail: "ok" },
    retrieval: { state: "ok", embedding: { state: "ok" }, reranker: { state: "ok" }, main_brain: { state: "absent", model: null, endpoint: null, detail: "no main brain configured" } },
    synthesis: { state: "degraded", model: "synth-test", endpoint: "http://127.0.0.1:9999/v1", detail: "no answer at http://127.0.0.1:9999/v1" },
    capture: { enabled: true, archived: 10, pending: 0, failed: 0, unreadable: 0, last_capture_at: null, last_error: null },
    maintenance: { state: "ready", detail: null },
  },
};
{
  const view = buildGBrainHealth(degradedSynthesisEnvelope);
  const tones = view.cards.map((c) => c.tone);
  // Retrieval stays green; only Synthesis flips amber.
  deepEqual("degraded synthesis only flips synthesis", tones,
    ["green", "green", "green", "amber", "green", "green"]);
}

// --- capture with pending and failed ---------------------------------------
//
// Capture pending and failed counts surface on the panel and color the
// card. The dashboard is the only place these counts are visible at a
// glance.

const captureIssuesEnvelope = {
  schema: "fm-gbrain-health.v1",
  status: { phase: "ready" },
  config: { query_max_bytes: 1024, result_limit_max: 16 },
  health: {
    schema: "fm-gbrain-health.v1",
    home: "/home/firstmate",
    configured: true,
    version: "v0.42.69.0",
    index: { state: "ok", detail: "ok" },
    retrieval: { state: "ok" },
    synthesis: { state: "ok" },
    capture: { enabled: true, archived: 5, pending: 3, failed: 1, unreadable: 0, last_capture_at: null, last_error: "brain refused: index is locked" },
    maintenance: { state: "ready", detail: null },
  },
};
{
  const view = buildGBrainHealth(captureIssuesEnvelope);
  const captureCard = view.cards.find((c) => c.label === "Capture");
  // failed > 0 takes precedence over pending; the operator reads red first.
  equal("capture tone when failed > 0", captureCard.tone, "red");
  equal("capture value when failed > 0", captureCard.value, "degraded");
  // The detail carries every count plus the last error so the operator
  // sees the retry queue without opening the durable outbox.
  check("capture detail shows archived count", captureCard.detail.includes("5 archived"));
  check("capture detail shows pending count", captureCard.detail.includes("3 pending"));
  check("capture detail shows failed count", captureCard.detail.includes("1 failed"));
  check("capture detail shows last error", captureCard.detail.includes("brain refused: index is locked"));
}

// --- capture with only pending (no failures) -------------------------------

const capturePendingEnvelope = {
  schema: "fm-gbrain-health.v1",
  status: { phase: "ready" },
  config: { query_max_bytes: 1024, result_limit_max: 16 },
  health: {
    schema: "fm-gbrain-health.v1",
    home: "/home/firstmate",
    configured: true,
    version: "v0.42.69.0",
    index: { state: "ok", detail: "ok" },
    retrieval: { state: "ok" },
    synthesis: { state: "ok" },
    capture: { enabled: true, archived: 10, pending: 4, failed: 0, unreadable: 0, last_capture_at: null, last_error: null },
    maintenance: { state: "ready", detail: null },
  },
};
{
  const view = buildGBrainHealth(capturePendingEnvelope);
  const captureCard = view.cards.find((c) => c.label === "Capture");
  equal("capture tone when pending > 0", captureCard.tone, "amber");
  equal("capture value when pending > 0", captureCard.value, "pending");
}

// --- the operator's upgrade announcement ------------------------------------

const upgradingEnvelope = {
  schema: "fm-gbrain-health.v1",
  status: { phase: "ready" },
  config: { query_max_bytes: 1024, result_limit_max: 16 },
  health: {
    schema: "fm-gbrain-health.v1",
    home: "/home/firstmate",
    configured: true,
    version: "v0.42.69.0",
    index: { state: "ok", detail: "ok" },
    retrieval: { state: "ok" },
    synthesis: { state: "ok" },
    capture: { enabled: true, archived: 0, pending: 0, failed: 0, unreadable: 0, last_capture_at: null, last_error: null },
    maintenance: { state: "upgrading", detail: "rebuild embedding index for v0.43" },
  },
};
{
  const view = buildGBrainHealth(upgradingEnvelope);
  const maintenanceCard = view.cards.find((c) => c.label === "Maintenance");
  equal("maintenance tone when upgrading", maintenanceCard.tone, "amber");
  equal("maintenance value when upgrading", maintenanceCard.value, "upgrading");
  equal("maintenance detail is verbatim", maintenanceCard.detail, "rebuild embedding index for v0.43");
}

// --- search failure reasons render with the operator's vocabulary ---------
//
// Every reason the server returns is mapped to a label the operator reads.
// Amber is reserved for "wait and try again"; red is reserved for a
// permanent or hostile failure.

const reasonExpectations = [
  ["query_too_short", "amber"],
  ["query_too_large", "red"],
  ["body_too_large", "red"],
  ["body_deadline", "red"],
  ["malformed_json", "red"],
  ["missing_query", "red"],
  ["invalid_limit", "red"],
  ["search_busy", "amber"],
  ["timed_out", "amber"],
  ["no_corpus_answered", "amber"],
  ["search_failed", "red"],
  ["unsupported_schema", "red"],
];
for (const [reason, expectedTone] of reasonExpectations) {
  const label = searchReasonLabel(reason);
  check(`reason ${reason} has a label`, typeof label === "string" && label.length > 0);
  const failure = searchFailure(reason, "test detail");
  equal(`reason ${reason} tone`, failure.tone, expectedTone);
  check(`reason ${reason} failure carries detail`, failure.text.includes("test detail"));
}

// A missing or unknown reason returns the generic "could not be answered".
{
  const label = searchReasonLabel("totally_made_up_reason");
  check("unknown reason returns generic label", label === "The search could not be answered.");
  const failure = searchFailure("totally_made_up_reason");
  equal("unknown reason tone is red", failure.tone, "red");
}

// --- the panel never invents a brain when the envelope is malformed --------

{
  const view = buildGBrainHealth(null);
  equal("null envelope returns no cards", view.cards.length, 0);
  equal("null envelope returns unknown tone", view.overall.tone, "unknown");
}
{
  const view = buildGBrainHealth({ schema: "fm-gbrain-health.v1", status: {}, config: {}, health: null });
  equal("null health returns no cards", view.cards.length, 0);
}

// --- capture detail is robust to missing fields -----------------------------

{
  const view = buildGBrainHealth({
    schema: "fm-gbrain-health.v1",
    status: { phase: "ready" },
    config: { query_max_bytes: 1024, result_limit_max: 16 },
    health: {
      schema: "fm-gbrain-health.v1",
      configured: true,
      version: "v0.42.69.0",
      index: { state: "ok", detail: "ok" },
      retrieval: { state: "ok" },
      synthesis: { state: "ok" },
      capture: { enabled: true, archived: undefined, pending: undefined, failed: undefined, unreadable: undefined, last_capture_at: undefined, last_error: undefined },
      maintenance: { state: "ready", detail: null },
    },
  });
  const captureCard = view.cards.find((c) => c.label === "Capture");
  check("capture detail renders with missing fields", captureCard.detail.includes("0 archived") && captureCard.detail.includes("no successful capture"));
}

if (failures.length) {
  for (const f of failures) console.error(`not ok - ${f}`);
  process.exit(1);
}
console.log("dashboard gbraintron panel data verified");
})();
NODE