// gbraintron.js - the read-only GBrain health panel and semantic search box.
//
// The brain is optional. A home without a brain reports configured: false and
// renders a single card that says so, which is the normal state of a fleet
// that has not adopted GBrain. A stopped, slow, or unconfigured brain
// degrades the panel, never the dashboard.
//
// Every value on this page is textContent; nothing in a stored brain document
// can become markup because the only path from server to DOM is
// textContent. Search results are rendered with the same createElement
// discipline app.js uses elsewhere, and their slug, title, score, and
// excerpt are read through the closed vocabulary below; anything the server
// marked unknown or absent is rendered as the literal word "unknown" rather
// than dropped, so a hostile wrapper cannot make a result invisible.

export const GBRAIN_HEALTH_SCHEMA = "fm-gbrain-health.v1";
export const GBRAIN_SEARCH_SCHEMA = "fm-gbrain-search.v1";

const TONE_RANK = { green: 0, blue: 1, unknown: 2, amber: 3, red: 4 };

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function element(tag, className, textContent) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (textContent !== undefined && textContent !== null) node.textContent = textContent;
  return node;
}

function worstTone(tones) {
  let winner = null;
  for (const tone of tones) {
    if (winner === null || (TONE_RANK[tone] ?? 0) > (TONE_RANK[winner] ?? 0)) winner = tone;
  }
  return winner;
}

function ageLabel(ageSeconds) {
  if (typeof ageSeconds !== "number" || !Number.isFinite(ageSeconds) || ageSeconds < 0) return "unknown";
  if (ageSeconds < 60) return `${Math.round(ageSeconds)}s ago`;
  if (ageSeconds < 3_600) return `${Math.floor(ageSeconds / 60)}m ago`;
  if (ageSeconds < 86_400) return `${Math.floor(ageSeconds / 3_600)}h ago`;
  return `${Math.floor(ageSeconds / 86_400)}d ago`;
}

function healthCard({ label, tone, value, detail, tooltip }) {
  const card = element("article", `health-card ${tone || "unknown"}`);
  card.setAttribute("aria-label", `${label}: ${value}`);
  if (tooltip) card.title = tooltip;
  const head = element("div", "health-head");
  head.append(element("span", "dot", tone || "unknown"));
  head.append(element("span", "label", label.toUpperCase()));
  card.append(head);
  card.append(element("strong", "health-value", value));
  card.append(element("p", "health-detail", detail));
  return card;
}

// --- the panel itself -------------------------------------------------------

// The panel renders six readings, each its own card so the panel keeps
// working when the wrapper hands back partial data:
//   - configured: presence of the brain
//   - index: initialized vs not yet bootstrapped
//   - retrieval: ok / degraded / absent, with the embedding / reranker /
//     main-brain subcards each rated independently
//   - synthesis: hosted provider, distinct from local retrieval
//   - capture: archived / pending / failed from the durable outbox
//   - maintenance: ready / upgrading / reindexing
// Every value below is one observation, with no inference between them: a
// degraded embedding degrades retrieval but leaves synthesis and capture
// alone, which is what the operator needs to tell which path is broken.
export function buildGBrainHealth(envelope) {
  if (!envelope || typeof envelope !== "object") {
    return { cards: [], overall: { tone: "unknown", label: "GBrain" }, reason: "no health envelope received" };
  }
  const status = envelope.status || {};
  const cfg = envelope.config || {};
  const h = envelope.health || {};

  if (!h.configured) {
    return {
      cards: [healthCard({
        label: "Brain",
        tone: "unknown",
        value: "not configured",
        detail: text(h.index?.detail) || "This home has no GBrain configured; the brain is optional and absence is a normal state.",
      })],
      overall: { tone: "unknown", label: "GBrain" },
      reason: "no brain configured",
      noBrain: true,
    };
  }

  const cards = [];
  cards.push(healthCard({
    label: "Brain",
    tone: "green",
    value: text(h.version) || "configured",
    detail: `index at ${text(h.index?.detail) || "an unknown path"}`,
    tooltip: "GBrain is configured for this home. The version is the pinned release recorded in docs.",
  }));

  const indexState = text(h.index?.state) || "unknown";
  cards.push(healthCard({
    label: "Index",
    tone: indexState === "ok" ? "green" : indexState === "absent" ? "amber" : "unknown",
    value: indexState,
    detail: indexState === "ok" ? text(h.index?.detail) : (text(h.index?.detail) || "the brain has not been bootstrapped yet"),
    tooltip: "Whether the local PGLite index exists. absent means this home has not run the initial bootstrap.",
  }));

  const retrieval = h.retrieval || {};
  const retrievalState = text(retrieval.state) || "unknown";
  const embedding = retrieval.embedding || {};
  const reranker = retrieval.reranker || {};
  const mainBrain = retrieval.main_brain || {};
  cards.push(healthCard({
    label: "Retrieval",
    tone: retrievalState === "ok" ? "green" : retrievalState === "degraded" ? "amber" : retrievalState === "absent" ? "unknown" : "unknown",
    value: retrievalState,
    detail: [
      `${text(embedding.model) || "no embedding model"} @ ${text(embedding.endpoint) || "no endpoint"}`,
      `${text(reranker.model) || "no reranker model"} @ ${text(reranker.endpoint) || "no endpoint"}`,
      `${text(mainBrain.state) || "no main brain"}: ${text(mainBrain.detail) || ""}`,
    ].filter(Boolean).join(" / "),
    tooltip: "Local search uses embedding + reranker; the main-brain read is the optional cross-home share.",
  }));

  const synthesis = h.synthesis || {};
  const synthState = text(synthesis.state) || "unknown";
  cards.push(healthCard({
    label: "Synthesis",
    tone: synthState === "ok" ? "green" : synthState === "degraded" ? "amber" : "unknown",
    value: synthState,
    detail: `${text(synthesis.model) || "no model"} @ ${text(synthesis.endpoint) || "no endpoint"}: ${text(synthesis.detail) || ""}`,
    tooltip: "The hosted synthesis provider. Degraded means search keeps working but 'think' is unavailable.",
  }));

  const capture = h.capture || {};
  const captureState = capture.enabled === false ? "off" : capture.failed > 0 ? "degraded" : capture.pending > 0 ? "pending" : "ready";
  const captureDetail = capture.enabled === false
    ? text(capture.detail) || "no brain configured for capture"
    : [
        `${capture.archived ?? 0} archived`,
        `${capture.pending ?? 0} pending`,
        `${capture.failed ?? 0} failed`,
        capture.last_capture_at ? `last captured ${ageLabel((Date.parse(capture.last_capture_at) - Date.now()) / 1000)}` : "no successful capture",
      ].join(" / ") + (capture.last_error ? ` · last error: ${text(capture.last_error)}` : "");
  cards.push(healthCard({
    label: "Capture",
    tone: captureState === "ready" ? "green" : captureState === "pending" ? "amber" : captureState === "degraded" ? "red" : "unknown",
    value: captureState,
    detail: captureDetail,
    tooltip: "The durable capture outbox. archived are in the brain; pending are queued; failed need a manual retry.",
  }));

  const maintenance = h.maintenance || {};
  const maintenanceState = text(maintenance.state) || "ready";
  cards.push(healthCard({
    label: "Maintenance",
    tone: maintenanceState === "ready" ? "green" : "amber",
    value: maintenanceState,
    detail: text(maintenance.detail) || (maintenanceState === "ready" ? "operator has not announced an upgrade or reindex" : "operator has set FM_GBRAIN_MAINTENANCE_STATE"),
    tooltip: "Set FM_GBRAIN_MAINTENANCE_STATE to upgrading or reindexing while the brain is paused for care.",
  }));

  const tones = cards.map((card) => {
    const m = (card.className.match(/health-card (\w+)/) || [])[1];
    return m;
  });
  const overall = { tone: worstTone(tones) || "unknown", label: "GBrain" };
  return { cards, overall, status, config: cfg, noBrain: false };
}

export function paintGBrainPanel(elements, envelope) {
  const { panel, strip, notice, searchForm, searchInput, searchButton, results, config } = elements;
  const view = buildGBrainHealth(envelope);
  replaceChildren(strip, view.cards);

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
    noticeText = `Read ${ageLabel(status.last_success_age_seconds)} ago`;
    noticeTone = "info";
  }
  if (noticeText) {
    const node = element("div", `notice ${noticeTone === "red" ? "error" : noticeTone === "amber" ? "" : "info"}`.trim());
    node.append(element("span", "dot", noticeTone === "red" ? "red" : noticeTone === "amber" ? "amber" : "blue"));
    node.append(element("div", "", noticeText));
    replaceChildren(notice, [node]);
  } else {
    replaceChildren(notice, []);
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
    // Replace any prior hint so the panel never accumulates them.
    const prior = searchForm.parentNode?.querySelector(".gbraintron-hint");
    if (prior) prior.remove();
    hint.classList.add("gbraintron-hint");
    searchForm.insertAdjacentElement("afterend", hint);
  } else if (searchForm) {
    const prior = searchForm.parentNode?.querySelector(".gbraintron-hint");
    if (prior) prior.remove();
  }
  if (results) replaceChildren(results, []);
  return view;
}

export function paintGBrainSearchResults(elements, payload, error) {
  const { results } = elements;
  if (error) {
    const node = element("div", `notice ${error.tone === "red" ? "error" : "amber"}`.trim());
    node.append(element("span", "dot", error.tone === "red" ? "red" : "amber"));
    node.append(element("div", "", error.text));
    replaceChildren(results, [node]);
    return;
  }
  if (!payload || !Array.isArray(payload.results) || payload.results.length === 0) {
    const empty = element("div", "inbox-empty");
    const copy = element("div");
    copy.append(element("strong", "", "No matches"));
    copy.append(element("p", "", `The brain answered the question "${text(payload?.query) || ""}" with nothing in the captured reports. Widen the search or capture more.`));
    empty.append(element("span", "dot", "green"), copy);
    replaceChildren(results, [empty]);
    return;
  }
  const sources = Array.isArray(payload.sources) ? payload.sources : [];
  const failedSources = sources.filter((row) => row.state !== "ok" && row.state !== "absent" && row.state !== "unconfigured");
  const cards = [];
  if (failedSources.length) {
    const header = element("div", `notice ${failedSources.some((s) => s.state === "failed") ? "error" : "amber"}`.trim());
    header.append(element("span", "dot", failedSources.some((s) => s.state === "failed") ? "red" : "amber"));
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
  replaceChildren(results, cards);
}

export function searchFailure(reason, detail) {
  const tone = reason === "timed_out" || reason === "no_corpus_answered" || reason === "search_busy" ? "amber" : "red";
  return { tone, text: `${searchReasonLabel(reason)}${detail ? `: ${detail}` : ""}` };
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
    case "timed_out": return "The brain did not answer within the search timeout.";
    case "no_corpus_answered": return "No corpus answered the search.";
    case "search_failed":
    case "unsupported_schema":
    default: return "The search could not be answered.";
  }
}

function replaceChildren(parent, children) {
  if (!parent) return;
  parent.replaceChildren(...(children || []).filter(Boolean));
}