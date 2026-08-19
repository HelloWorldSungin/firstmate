// gbrain.js - the read-only GBrain health panel and semantic search box.
//
// The brain is optional. A home without a brain reports configured: false and
// renders a single card that says so, which is the normal state of a fleet
// that has not adopted GBrain. A stopped, slow, or unconfigured brain
// degrades the panel, never the dashboard.
//
// Every health value is normalized into a display model before it reaches a
// text node or attribute. Search results are rendered with the same
// createElement discipline app.js uses elsewhere, and their slug, title,
// score, and excerpt are read through the closed vocabulary below; anything
// the server marked unknown or absent is rendered as the literal word
// "unknown" rather than dropped, so a hostile wrapper cannot make a result
// invisible.
//
// No page loads these paint functions: index.html loads /app.js alone, and
// assets/dashboard/app.js imports this module's data layer without them. The
// Knowledge view there is the renderer a captain sees, so a result row's
// capture date and live-source state are rendered there alone rather than in
// a second copy here. Issue 170 owns whether this rendering layer is removed
// with its tests or covered.
//
// The data layer below returns plain objects; the rendering layer turns
// them into DOM nodes. Tests exercise the data layer without needing a
// DOM, and the rendering layer is the only thing that touches
// createElement.

import { pathTail } from "./display.js";

export const GBRAIN_HEALTH_SCHEMA = "fm-gbrain-health.v1";
export const GBRAIN_SEARCH_SCHEMA = "fm-gbrain-search.v1";

const TONE_RANK = { green: 0, blue: 1, unknown: 2, amber: 3, red: 4 };

// The source states that mean "this corpus answered, or had nothing to
// answer with". Everything else is a corpus that did not answer and is worth
// telling the operator about.
export const GBRAIN_HEALTHY_SOURCE_STATES = new Set(["ok", "absent", "unconfigured", "same-as-local"]);

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function stateValue(value, allowed, fallback = "unknown") {
  const candidate = text(value);
  return allowed.includes(candidate) ? candidate : fallback;
}

function worstTone(tones) {
  let winner = null;
  for (const tone of tones) {
    if (winner === null || (TONE_RANK[tone] ?? 0) > (TONE_RANK[winner] ?? 0)) winner = tone;
  }
  return winner;
}

// The retrieval card's value is the aggregate state, so it cannot say which
// leg went. Each leg that is not ok therefore carries its own reason, the same
// way the synthesis card carries its detail - a dead embedding takes hybrid
// search out, a dead reranker only drops the reranked ordering, and the
// operator needs to tell those apart.
function retrievalLeg(head, probe) {
  const state = stateValue(probe?.state, ["ok", "degraded", "absent", "unavailable", "same-as-local"]);
  if (!state || state === "ok") return head;
  return `${head}: ${state}`;
}

function ageLabel(ageSeconds) {
  if (typeof ageSeconds !== "number" || !Number.isFinite(ageSeconds) || ageSeconds < 0) return "unknown";
  if (ageSeconds < 60) return `${Math.round(ageSeconds)}s ago`;
  if (ageSeconds < 3_600) return `${Math.floor(ageSeconds / 60)}m ago`;
  if (ageSeconds < 86_400) return `${Math.floor(ageSeconds / 3_600)}h ago`;
  return `${Math.floor(ageSeconds / 86_400)}d ago`;
}

// --- the data layer ---------------------------------------------------------
//
// The data layer never touches the DOM. Every value below is one observation
// of the health envelope; nothing is inferred between observations, so a
// degraded embedding degrades retrieval but leaves synthesis and capture
// alone, which is what the operator needs to tell which path is broken.

export function buildGBrainHealth(envelope) {
  if (!envelope || typeof envelope !== "object" || !envelope.health || typeof envelope.health !== "object") {
    return { cards: [], overall: { tone: "unknown", label: "GBrain" }, reason: "no health envelope received" };
  }
  const status = envelope.status || {};
  const cfg = envelope.config || {};
  const h = envelope.health;

  if (!h.configured) {
    return {
      cards: [{
        label: "Brain",
        tone: "unknown",
        value: "not configured",
        detail: "This home has no GBrain configured; the brain is optional and absence is a normal state.",
        tooltip: "",
      }],
      overall: { tone: "unknown", label: "GBrain" },
      reason: "no brain configured",
      noBrain: true,
    };
  }

  const cards = [];
  cards.push({
    label: "Brain",
    tone: "green",
    value: pathTail(h.version) || "configured",
    detail: `index at ${pathTail(h.index?.detail) || "an unknown location"}`,
    tooltip: "GBrain is configured for this home. The version is the pinned release recorded in docs.",
  });

  const indexState = stateValue(h.index?.state, ["ok", "absent"]);
  cards.push({
    label: "Index",
    tone: indexState === "ok" ? "green" : indexState === "absent" ? "amber" : "unknown",
    value: indexState,
    detail: indexState === "ok" ? (pathTail(h.index?.detail) || "the index location is unknown") : (pathTail(h.index?.detail) || "the brain has not been bootstrapped yet"),
    tooltip: "Whether the local PGLite index exists. absent means this home has not run the initial bootstrap.",
  });

  const retrieval = h.retrieval || {};
  const retrievalState = stateValue(retrieval.state, ["ok", "degraded", "absent"]);
  const embedding = retrieval.embedding || {};
  const reranker = retrieval.reranker || {};
  const mainBrain = retrieval.main_brain || {};
  cards.push({
    label: "Retrieval",
    tone: retrievalState === "ok" ? "green" : retrievalState === "degraded" ? "amber" : retrievalState === "absent" ? "unknown" : "unknown",
    value: retrievalState,
    detail: [
      retrievalLeg(pathTail(embedding.model) || "no embedding model", embedding),
      retrievalLeg(pathTail(reranker.model) || "no reranker model", reranker),
      `main brain: ${stateValue(mainBrain.state, ["ok", "degraded", "absent", "unavailable", "same-as-local"])}`,
    ].filter(Boolean).join(" / "),
    tooltip: "Local search uses embedding + reranker; the main-brain read is the optional cross-home share.",
  });

  const synthesis = h.synthesis || {};
  const synthState = stateValue(synthesis.state, ["ok", "degraded", "absent", "unconfigured"]);
  cards.push({
    label: "Synthesis",
    tone: synthState === "ok" ? "green" : synthState === "degraded" ? "amber" : "unknown",
    value: synthState,
    detail: `${pathTail(synthesis.model) || "no model"}: ${synthState}`,
    tooltip: "The hosted synthesis provider. Degraded means search keeps working but 'think' is unavailable.",
  });

  // This card is only reached on a configured home, so capture.enabled: false
  // never means "no brain" here - it means the local index has not been
  // bootstrapped yet and captured documents are still sitting in the durable
  // outbox. The counts are what the operator needs in either case, so they are
  // always rendered and the reason is appended rather than replacing them.
  const capture = h.capture || {};
  const captureState = capture.enabled === false ? "off" : capture.failed > 0 ? "degraded" : capture.pending > 0 ? "pending" : "ready";
  const captureDetail = [
    `${capture.archived ?? 0} archived`,
    `${capture.pending ?? 0} pending`,
    `${capture.failed ?? 0} failed`,
    capture.last_capture_at ? `last captured ${ageLabel((Date.now() - Date.parse(capture.last_capture_at)) / 1000)}` : "no successful capture",
  ].join(" / ")
    + (capture.enabled === false
      ? " · the local index is not bootstrapped, so captured documents wait in the outbox"
      : "")
    + (capture.last_error ? " · the last capture attempt failed" : "");
  cards.push({
    label: "Capture",
    tone: captureState === "ready" ? "green" : captureState === "pending" ? "amber" : captureState === "degraded" ? "red" : "unknown",
    value: captureState,
    detail: captureDetail,
    tooltip: "The durable capture outbox. archived are in the brain; pending are queued; failed need a manual retry.",
  });

  const maintenance = h.maintenance || {};
  const maintenanceState = stateValue(maintenance.state, ["ready", "upgrading", "reindexing"], "ready");
  cards.push({
    label: "Maintenance",
    tone: maintenanceState === "ready" ? "green" : "amber",
    value: maintenanceState,
    detail: maintenanceState === "ready" ? "operator has not announced an upgrade or reindex" : `maintenance is ${maintenanceState}`,
    tooltip: "Set FM_GBRAIN_MAINTENANCE_STATE to upgrading or reindexing while the brain is paused for care.",
  });

  const tones = cards.map((card) => card.tone);
  const overall = { tone: worstTone(tones) || "unknown", label: "GBrain" };
  return { cards, overall, status, config: cfg, noBrain: false };
}

// --- the rendering layer ----------------------------------------------------
//
// The rendering layer is the only code in this file that creates DOM nodes.
// It reads from the data layer above, so the data layer can be exercised in
// node without a DOM, and the rendering layer only touches the parts it has
// to. Both element() and replaceChildren() are deliberately small.

function element(tag, className, textContent) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (textContent !== undefined && textContent !== null) node.textContent = textContent;
  return node;
}

// A tone is a class, never text. .dot.green / .dot.amber / .dot.red /
// .dot.blue / .dot.unknown are what colour the 8px circle, so a tone passed as
// textContent would both lose the colour and print the word inside the dot,
// on top of the label beside it. Same shape as app.js's dot().
function dot(tone) {
  return element("span", `dot ${tone || "unknown"}`);
}

// Every card this panel paints matches app.js's ANCHOR_SELECTOR, so wholesale
// replacement disconnects whatever the reader was anchored to. The host passes
// its own anchor-aware replaceChildren in through elements; the fallback below
// is what a DOM-only fixture with no host gets.
function replaceChildren(parent, children) {
  if (!parent) return;
  parent.replaceChildren(...(children || []).filter(Boolean));
}

function replacerFor(elements) {
  const host = elements?.replaceChildren;
  if (typeof host !== "function") return replaceChildren;
  return (parent, children) => {
    if (!parent) return;
    host(parent, (children || []).filter(Boolean));
  };
}

function healthCardNode({ label, tone, value, detail, tooltip }) {
  const card = element("article", `health-card ${tone || "unknown"}`);
  card.setAttribute("aria-label", `${label}: ${value}`);
  if (tooltip) card.title = tooltip;
  const head = element("div", "health-head");
  head.append(dot(tone));
  head.append(element("span", "label", label.toUpperCase()));
  card.append(head);
  card.append(element("strong", "health-value", value));
  card.append(element("p", "health-detail", detail));
  return card;
}

export function paintGBrainPanel(elements, envelope) {
  const { panel, strip, notice, searchForm, searchInput, searchButton, results, config } = elements;
  const put = replacerFor(elements);
  const view = buildGBrainHealth(envelope);
  put(strip, view.cards.map(healthCardNode));

  const status = view.status || {};
  let noticeText = "";
  let noticeTone = "info";
  if (status.phase === "first_run") {
    noticeText = "Waiting for the first GBrain health read.";
    noticeTone = "amber";
  } else if (status.phase === "unavailable") {
    noticeText = `GBrain health is unavailable: ${text(status.error?.message) || "unknown reason"}. Retrying automatically.`;
    noticeTone = "red";
  } else if (status.stale) {
    noticeText = `Showing the last known good GBrain health (${ageLabel(status.last_success_age_seconds)} old). Refreshes continue automatically.`;
    noticeTone = "amber";
  } else if (view.noBrain) {
    noticeText = "No GBrain is configured for this home. The brain is optional; absence is a normal state and does not affect fleet supervision.";
    noticeTone = "info";
  } else if (status.last_success_at) {
    noticeText = `Read ${ageLabel(status.last_success_age_seconds)}`;
    noticeTone = "info";
  }
  if (noticeText) {
    const node = element("div", `notice ${noticeTone === "red" ? "error" : noticeTone === "amber" ? "" : "info"}`.trim());
    node.append(dot(noticeTone === "red" ? "red" : noticeTone === "amber" ? "amber" : "blue"));
    node.append(element("div", "", noticeText));
    put(notice, [node]);
  } else {
    put(notice, []);
  }

  // Search affordances are gated on a configured home. The cap on input length
  // is the dashboard's first line of defence against an oversized body; the
  // server's byte cap is the second. Each property access is gated on the
  // element existing, so a partial page (a fixture, a future layout that
  // omits the search) renders the health strip without throwing.
  const searchDisabled = view.noBrain === true;
  if (searchInput) {
    searchInput.disabled = searchDisabled;
    searchInput.maxLength = config?.query_max_bytes || 1024;
    searchInput.placeholder = searchDisabled
      ? "no brain configured"
      : "search captured reports and notes";
  }
  if (searchButton) searchButton.disabled = searchDisabled;

  // The hint lives next to the search affordance, not above it, so the
  // affordance is the first thing a reader reaches.
  const hint = searchDisabled ? null : element("p", "empty-inline", `up to ${config?.result_limit_max || 16} results; the brain may take a few seconds on a cold index`);
  if (searchForm && hint) {
    const prior = searchForm.parentNode?.querySelector(".gbraintron-hint");
    if (prior) prior.remove();
    hint.classList.add("gbraintron-hint");
    searchForm.insertAdjacentElement("afterend", hint);
  } else if (searchForm) {
    const prior = searchForm.parentNode?.querySelector(".gbraintron-hint");
    if (prior) prior.remove();
  }
  // The results region belongs to the search, not to the health read. A
  // routine repaint arrives on every health broadcast - about once a minute -
  // and must leave whatever the operator is reading alone, results and search
  // failure notices alike. The one transition that makes prior results
  // meaningless is the brain going unconfigured, because the search that
  // produced them can no longer be repeated.
  if (results && searchDisabled) put(results, []);
  return view;
}

export function paintGBrainSearchResults(elements, payload, error) {
  const { results } = elements;
  const put = replacerFor(elements);
  if (error) {
    const node = element("div", `notice ${error.tone === "red" ? "error" : "amber"}`.trim());
    node.append(dot(error.tone === "red" ? "red" : "amber"));
    node.append(element("div", "", error.text));
    put(results, [node]);
    return;
  }
  if (!payload || !Array.isArray(payload.results) || payload.results.length === 0) {
    const empty = element("div", "inbox-empty");
    const copy = element("div");
    copy.append(element("strong", "", "No indexed match"));
    copy.append(element("p", "", payload?.answer?.notice || "No indexed match. That is absence of a match in this brain, not evidence that the queried thing is absent."));
    empty.append(dot("green"), copy);
    put(results, [empty]);
    return;
  }
  // same-as-local is not a failure: it is the alias row a home that owns the
  // main brain emits for the main corpus, whose read the local row already
  // carried.
  const sources = Array.isArray(payload.sources) ? payload.sources : [];
  const failedSources = sources.filter((row) => !GBRAIN_HEALTHY_SOURCE_STATES.has(row.state));
  const cards = [];
  if (payload.answer?.notice) {
    const note = element("p", "empty-inline");
    note.textContent = text(payload.answer.notice);
    cards.push(note);
  }
  if (failedSources.length) {
    const header = element("div", `notice ${failedSources.some((s) => s.state === "failed") ? "error" : "amber"}`.trim());
    header.append(dot(failedSources.some((s) => s.state === "failed") ? "red" : "amber"));
    const inner = element("div", "");
    inner.append(element("strong", "", "Some corpora did not answer"));
    inner.append(document.createTextNode(` ${failedSources.map((s) => `${s.source}: ${text(s.detail) || s.state}`).join("; ")}`));
    header.append(inner);
    cards.push(header);
  }
  for (const row of payload.results) {
    const card = element("article", "history-card blue");
    card.setAttribute("aria-label", `${text(row.title) || "untitled"} (${text(row.slug) || "no slug"})`);
    const head = element("div", "card-head");
    head.append(element("span", "pill", text(row.source) || "unknown"));
    if (typeof row.score === "number" && Number.isFinite(row.score)) {
      head.append(element("span", "pill quiet", `score ${row.score.toFixed(3)}`));
    }
    if (row.stale === true) head.append(element("span", "chip amber", "stale"));
    card.append(head);
    card.append(element("div", "task-id", text(row.slug) || "no slug"));
    card.append(element("h3", "", text(row.title) || "Untitled"));
    if (row.excerpt) card.append(element("div", "detail", row.excerpt));
    cards.push(card);
  }
  put(results, cards);
}

export function searchFailure(reason, detail) {
  // Amber is reserved for "wait and try again" - a transient fault the
  // operator can recover from. Red is reserved for a permanent or hostile
  // failure, including anything that looks like a malformed request.
  // search_setup_failed stays red: unlike the amber reasons it will not clear
  // by trying again, because the service is missing something it needs.
  const tone = (reason === "timed_out" || reason === "no_corpus_answered" || reason === "search_busy" || reason === "query_too_short") ? "amber" : "red";
  const label = searchReasonLabel(reason);
  // The detail is free text from the server and does not always add anything:
  // the timeout reason restates this very sentence in lowercase, and the page
  // falls back to the label itself when the server sent no detail at all.
  // Appending either prints the same sentence twice, so a detail that carries
  // no new information is dropped rather than stuttered.
  const restatesLabel = normalizeSentence(detail) === normalizeSentence(label);
  return { tone, text: `${label}${detail && !restatesLabel ? `: ${detail}` : ""}` };
}

function normalizeSentence(value) {
  return text(value).toLowerCase().replace(/[.\s]+$/, "");
}

export function searchReasonLabel(reason) {
  switch (reason) {
    case "query_too_short": return "The query was too short to search.";
    case "query_too_large": return "The query exceeded the search size limit.";
    case "body_too_large": return "The search body exceeded the server limit.";
    case "body_deadline": return "The search body did not arrive in time.";
    case "malformed_json": return "The search body was not valid JSON.";
    case "missing_query": return "The search body did not include a query field.";
    case "invalid_limit": return "The search limit must be a positive integer.";
    case "search_busy": return "Another search is already running.";
    case "cross_origin": return "The search was refused as a cross-origin request.";
    case "timed_out": return "The brain did not answer within the search timeout.";
    case "no_corpus_answered": return "No corpus answered the search.";
    // Deliberately says nothing about the brain. This search never reached one,
    // so any sentence about corpora would be an answer the dashboard does not
    // have - and the operator would go looking at their brain instead of at
    // the service that could not start the search.
    case "search_setup_failed": return "The search could not start, so nothing was asked of the brain.";
    case "search_failed":
    case "unsupported_schema":
    default: return "The search could not be answered.";
  }
}
