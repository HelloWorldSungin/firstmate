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
const { buildGBrainHealth, searchFailure, searchReasonLabel, GBRAIN_HEALTHY_SOURCE_STATES, paintGBrainPanel, paintGBrainSearchResults } = await import(pathToFileURL(process.argv[2]).href);

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
  // The card's value is the aggregate "degraded", so its detail names the
  // failed leg without publishing its raw probe diagnostics.
  const retrieval = view.cards.find((c) => c.label === "Retrieval");
  check("degraded embedding states its outcome",
    retrieval.detail.includes("embed-test: degraded"),
    retrieval.detail);
  check("healthy reranker states no reason",
    retrieval.detail.includes("rerank-test /"),
    retrieval.detail);
}

// --- a degraded reranker with a healthy embedding ---------------------------
//
// The two local legs fail differently: a dead embedding takes hybrid search
// out, a dead reranker only drops the reranked ordering. The panel keeps that
// distinction by attributing each reason to its own leg.

{
  const view = buildGBrainHealth({
    ...degradedEnvelope,
    health: {
      ...degradedEnvelope.health,
      retrieval: {
        state: "degraded",
        embedding: { state: "ok", model: "embed-test", endpoint: "http://127.0.0.1:11434/v1", detail: "ok" },
        reranker: { state: "degraded", model: "rerank-test", endpoint: "http://127.0.0.1:8081/v1", detail: "no answer at http://127.0.0.1:8081/v1; search falls back to non-reranked ordering" },
        main_brain: { state: "absent", model: null, endpoint: null, detail: "no main brain configured" },
      },
    },
  });
  const retrieval = view.cards.find((c) => c.label === "Retrieval");
  check("degraded reranker states its outcome",
    retrieval.detail.includes("rerank-test: degraded"),
    retrieval.detail);
  check("healthy embedding states no reason",
    retrieval.detail.includes("embed-test /"),
    retrieval.detail);
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
    capture: { enabled: true, archived: 5, pending: 3, failed: 1, unreadable: 0, last_capture_at: null, last_error: "Remove /home/firstmate/data/.gbrain-lock" },
    maintenance: { state: "ready", detail: null },
  },
};
{
  const view = buildGBrainHealth(captureIssuesEnvelope);
  const captureCard = view.cards.find((c) => c.label === "Capture");
  // failed > 0 takes precedence over pending; the operator reads red first.
  equal("capture tone when failed > 0", captureCard.tone, "red");
  equal("capture value when failed > 0", captureCard.value, "degraded");
  check("capture detail shows archived count", captureCard.detail.includes("5 archived"));
  check("capture detail shows pending count", captureCard.detail.includes("3 pending"));
  check("capture detail shows failed count", captureCard.detail.includes("1 failed"));
  check("capture detail maps the last error", captureCard.detail.includes("the last capture attempt failed"));
  check("capture detail keeps raw diagnostics off the display model", !captureCard.detail.includes("/home/") && !captureCard.detail.includes(".gbrain-lock"));
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

// --- the last successful capture is readable as an age ---------------------
//
// The panel exists to surface the last successful capture, so the age has to
// read as an age. The timestamp is computed from now rather than pinned, so
// the assertion measures the arithmetic instead of the calendar.

{
  const capturedAt = new Date(Date.now() - 90_000).toISOString().replace(/\.\d{3}Z$/, "Z");
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
      capture: { enabled: true, archived: 81, pending: 0, failed: 0, unreadable: 0, last_capture_at: capturedAt, last_error: null },
      maintenance: { state: "ready", detail: null },
    },
  });
  const captureCard = view.cards.find((c) => c.label === "Capture");
  check("last capture reads as an elapsed age", captureCard.detail.includes("last captured 1m ago"),
    `received ${JSON.stringify(captureCard.detail)}`);
  check("last capture is never rendered as unknown", !captureCard.detail.includes("last captured unknown"));
}

// --- capture on a configured home whose index is not bootstrapped ----------
//
// enabled: false on a CONFIGURED home means the local index has not been
// bootstrapped, which docs/dashboard.md calls a normal state. It must not read
// as "no brain configured" - the Brain card beside it says the opposite - and
// the counts the health object carries must still be visible.

{
  const view = buildGBrainHealth({
    schema: "fm-gbrain-health.v1",
    status: { phase: "ready" },
    config: { query_max_bytes: 1024, result_limit_max: 16 },
    health: {
      schema: "fm-gbrain-health.v1",
      configured: true,
      version: "v0.42.69.0",
      index: { state: "absent", detail: "this home has no initialized brain at /home/firstmate/data/gbrain/pglite" },
      retrieval: { state: "ok" },
      synthesis: { state: "ok" },
      capture: {
        enabled: false, archived: 0, pending: 7, failed: 0, unreadable: 0, last_capture_at: null, last_error: null,
        detail: "the local index at /home/firstmate is not bootstrapped, so captured documents wait in the durable outbox",
      },
      maintenance: { state: "ready", detail: null },
    },
  });
  const captureCard = view.cards.find((c) => c.label === "Capture");
  equal("un-bootstrapped capture value is off", captureCard.value, "off");
  check("un-bootstrapped capture keeps its counts", captureCard.detail.includes("7 pending"),
    `received ${JSON.stringify(captureCard.detail)}`);
  check("un-bootstrapped capture does not claim no brain", !captureCard.detail.includes("no brain configured"));
  check("un-bootstrapped capture names the reason", captureCard.detail.includes("not bootstrapped"));
}

// --- source states that are not failures ------------------------------------
//
// same-as-local is what bin/fm-recall.sh emits for the main corpus on the home
// that OWNS the main brain: the local row already carried that read. Treating
// it as a corpus that did not answer paints a false failure banner on every
// search that home runs.

{
  check("same-as-local is not a failed corpus", GBRAIN_HEALTHY_SOURCE_STATES.has("same-as-local"));
  check("ok is not a failed corpus", GBRAIN_HEALTHY_SOURCE_STATES.has("ok"));
  check("degraded is a failed corpus", !GBRAIN_HEALTHY_SOURCE_STATES.has("degraded"));
  check("failed is a failed corpus", !GBRAIN_HEALTHY_SOURCE_STATES.has("failed"));
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
  equal("maintenance detail names the state", maintenanceCard.detail, "maintenance is upgrading");
}

// --- search failure reasons render with the operator's vocabulary ---------
//
// Every reason the server returns is mapped to a label the operator reads.
// Amber is reserved for "wait and try again"; red is reserved for a
// permanent or hostile failure.

const GENERIC_REASON_LABEL = "The search could not be answered.";
// The two reasons that are deliberately answered with the generic sentence,
// because neither tells the operator anything the sentence does not. Naming
// them here is what lets every other row assert it has its OWN label: a reason
// that quietly falls through to the default is a reason the operator was told
// nothing about, which is the regression this table exists to catch.
const genericLabelReasons = new Set(["search_failed", "unsupported_schema"]);

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
  // Red, not amber: unlike the amber reasons this one will not clear by trying
  // again, because the service is missing something it needs. An amber tone
  // would tell the operator to retry a search that cannot start.
  ["search_setup_failed", "red"],
  ["search_failed", "red"],
  ["unsupported_schema", "red"],
  ["cross_origin", "red"],
];
for (const [reason, expectedTone] of reasonExpectations) {
  const label = searchReasonLabel(reason);
  check(`reason ${reason} has a label`, typeof label === "string" && label.length > 0);
  equal(`reason ${reason} label is its own rather than the generic one`,
    label === GENERIC_REASON_LABEL, genericLabelReasons.has(reason));
  const failure = searchFailure(reason, "test detail");
  equal(`reason ${reason} tone`, failure.tone, expectedTone);
  check(`reason ${reason} failure carries detail`, failure.text.includes("test detail"));
}

// The setup-failure label is pinned verbatim because its whole job is to say
// nothing about the brain: this search never reached one, and a sentence about
// corpora would send the operator to inspect an index that was never consulted.
equal("search_setup_failed says the search never started",
  searchReasonLabel("search_setup_failed"),
  "The search could not start, so nothing was asked of the brain.");

// A missing or unknown reason returns the generic "could not be answered".
{
  const label = searchReasonLabel("totally_made_up_reason");
  check("unknown reason returns generic label", label === "The search could not be answered.");
  const failure = searchFailure("totally_made_up_reason");
  equal("unknown reason tone is red", failure.tone, "red");
}

// A detail that only restates the label is not printed twice. The server
// answers a timeout with the same sentence in lowercase, and the page falls
// back to the label itself when the server sent no detail, so both paths would
// otherwise render the sentence, a colon, and the sentence again.
{
  const label = searchReasonLabel("timed_out");
  const failure = searchFailure("timed_out", "the brain did not answer within the search timeout");
  equal("a detail that restates the label is dropped", failure.text, label);
  const echoed = searchFailure("search_busy", searchReasonLabel("search_busy"));
  equal("the label echoed back as a detail is dropped", echoed.text, searchReasonLabel("search_busy"));
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

// --- the rendering layer paints tones as classes, not as text ---------------
//
// The tone is what colours the 8px circle through .dot.green / .dot.amber /
// .dot.red / .dot.blue / .dot.unknown. Passing it as textContent instead loses
// every colour AND prints the word inside the dot, over the label beside it.
// A browser is the only place that shows it, so the shim below pins it here.

{
  class FakeNode {
    constructor(tagName, text = "") {
      this.tagName = tagName.toUpperCase();
      this.children = [];
      this.attributes = {};
      this.className = "";
      this._text = String(text);
    }

    get textContent() { return this._text + this.children.map((child) => child.textContent).join(""); }
    set textContent(value) { this._text = String(value ?? ""); this.children = []; }

    append(...children) {
      for (const child of children) {
        if (child === null || child === undefined) continue;
        this.children.push(typeof child === "string" ? new FakeNode("#text", child) : child);
      }
    }

    replaceChildren(...children) { this.children = []; this._text = ""; this.append(...children); }
    setAttribute(name, value) { this.attributes[name] = String(value); }
  }
  globalThis.document = {
    createElement: (tagName) => new FakeNode(tagName),
    createTextNode: (value) => new FakeNode("#text", value),
  };

  // Every dot the panel can paint, reachable from one render each: the six
  // health cards, the health notice, the search-failure notice, the empty
  // result, and the partial-corpus header.
  const dots = (root) => {
    const found = [];
    const walk = (node) => {
      if (typeof node.className === "string" && node.className.split(" ").includes("dot")) found.push(node);
      for (const child of node.children) walk(child);
    };
    walk(root);
    return found;
  };

  const strip = new FakeNode("div");
  const notice = new FakeNode("div");
  const results = new FakeNode("div");
  const elements = { strip, notice, results, config: { query_max_bytes: 1024, result_limit_max: 16 } };

  paintGBrainPanel(elements, {
    ...configuredEnvelope,
    status: { phase: "ready", last_success_at: "2026-08-05T21:07:59Z", last_success_age_seconds: 0 },
  });
  const cardDots = dots(strip);
  equal("every health card paints one dot", cardDots.length, 6);
  deepEqual("health card dots carry their tone as a class", cardDots.map((d) => d.className),
    ["dot green", "dot green", "dot green", "dot green", "dot green", "dot green"]);
  check("no health card dot carries text", cardDots.every((d) => d.textContent === ""),
    `received ${JSON.stringify(cardDots.map((d) => d.textContent))}`);
  deepEqual("card labels are not overprinted by a tone", strip.children.map((card) => card.children[0].textContent),
    ["BRAIN", "INDEX", "RETRIEVAL", "SYNTHESIS", "CAPTURE", "MAINTENANCE"]);

  // ageLabel already says "ago"; the notice must not say it twice.
  equal("a fresh read is announced once", notice.textContent.replace(/^\s+/, ""), "Read 0s ago");
  deepEqual("the health notice dot carries its tone as a class", dots(notice).map((d) => d.className), ["dot blue"]);

  paintGBrainSearchResults(elements, null, searchFailure("timed_out", "the brain did not answer within the search timeout"));
  deepEqual("the search failure dot carries its tone as a class", dots(results).map((d) => d.className), ["dot amber"]);
  equal("the search failure sentence is printed once", results.textContent, searchReasonLabel("timed_out"));

  paintGBrainSearchResults(elements, { schema: "fm-gbrain-search.v1", query: "nothing", results: [], sources: [], answer: { kind: "none", notice: "No indexed match. That is absence of a match in this brain, not evidence that the queried thing is absent." } }, null);
  deepEqual("the empty-result dot carries its tone as a class", dots(results).map((d) => d.className), ["dot green"]);
  check("an empty result is framed as no indexed match", results.textContent.includes("No indexed match"),
    `received ${JSON.stringify(results.textContent)}`);
  check("an empty result is not a negative about the world", !results.textContent.includes("does not exist") && !results.textContent.includes("No matches"),
    `received ${JSON.stringify(results.textContent)}`);

  paintGBrainSearchResults(elements, {
    schema: "fm-gbrain-search.v1",
    query: "anything",
    results: [{ source: "local", slug: "task/one", title: "One", score: 0.5, excerpt: "body" }],
    sources: [{ source: "main", state: "failed", detail: "the main brain refused the read" }],
  }, null);
  deepEqual("the partial-corpus dot carries its tone as a class", dots(results).map((d) => d.className), ["dot red"]);

  // --- a routine health repaint does not erase the search ------------------
  //
  // The panel repaints on every health broadcast, which arrives on the health
  // poll with no user action behind it. The results region belongs to the
  // search, so a repaint must leave the operator's results - and the failure
  // notice a degraded search left behind - exactly where they were.

  paintGBrainSearchResults(elements, {
    schema: "fm-gbrain-search.v1",
    query: "fleet supervision",
    answer: { kind: "nearest", notice: "These are the nearest indexed pages, not answers." },
    results: [
      { source: "local", slug: "task/one", title: "One", score: 0.5, excerpt: "body" },
      { source: "local", slug: "task/two", title: "Two", score: 0.4, excerpt: "body" },
    ],
    sources: [],
  }, null);
  equal("a search paints the framing notice plus one card per result", results.children.length, 3);
  paintGBrainPanel(elements, configuredEnvelope);
  equal("a routine health repaint keeps the search results", results.children.length, 3);
  check("the kept results are the same cards", results.textContent.includes("task/one") && results.textContent.includes("task/two"),
    `received ${JSON.stringify(results.textContent)}`);
  check("returned rows are framed as nearest pages", results.textContent.includes("nearest indexed pages"),
    `received ${JSON.stringify(results.textContent)}`);

  paintGBrainSearchResults(elements, {
    schema: "fm-gbrain-search.v1",
    query: "Does the BZ-SIM ratchet feature apply to AGS?",
    answer: { kind: "nearest", notice: "These are the nearest indexed pages, not answers." },
    results: [{
      source: "local", slug: "task/bzsim-ratchet-fix-side-effects", title: "BZ-SIM ratchet",
      score: 0.49, excerpt: "AGS has a code-proven zero-Value problem", stale: true,
      captured_at: "2026-08-11T20:39:46Z", source_state: "drifted", source_updated_at: "2026-08-11T21:25:41Z",
    }],
    sources: [],
  }, null);
  check("a drifted page is marked stale", results.textContent.includes("stale"),
    `received ${JSON.stringify(results.textContent)}`);
  check("a drifted page shows its capture date", results.textContent.includes("2026-08-11T20:39:46Z"),
    `received ${JSON.stringify(results.textContent)}`);
  check("a drifted page says the live source wins", results.textContent.includes("live source wins"),
    `received ${JSON.stringify(results.textContent)}`);

  paintGBrainSearchResults(elements, null, searchFailure("timed_out", "the brain did not answer within the search timeout"));
  paintGBrainPanel(elements, configuredEnvelope);
  equal("a routine health repaint keeps a search failure notice", results.textContent, searchReasonLabel("timed_out"));

  // A brain that goes unconfigured disables the search, and results from a
  // search that can no longer be repeated are the one thing worth clearing.
  paintGBrainPanel(elements, noBrainEnvelope);
  equal("losing the brain clears the stale results", results.children.length, 0);
}

if (failures.length) {
  for (const f of failures) console.error(`not ok - ${f}`);
  process.exit(1);
}
console.log("dashboard gbraintron panel data verified");
})();
NODE

printf '\nall fm-dashboard-gbrain-ui tests passed\n'
