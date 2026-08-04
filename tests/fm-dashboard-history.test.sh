#!/usr/bin/env bash
# Behavior tests for the dashboard's completed-work history and its sanitized
# report renderer.
#
# The renderer cases are the point of this file. A retained report is arbitrary
# content written by a worker, so "our current reports look fine" proves
# nothing: every case below feeds the renderer content that is actively trying
# to execute script, smuggle a dangerous URL protocol, or exhaust the browser,
# and asserts what comes out. docs/dashboard.md owns the human statement of the
# policy these cases pin.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

node - "$ROOT/assets/dashboard/markdown.js" "$ROOT/assets/dashboard/history.js" <<'NODE' || fail "dashboard history and report rendering behavior failed"
const { pathToFileURL } = require("node:url");

(async () => {
const markdown = await import(pathToFileURL(process.argv[2]).href);
const history = await import(pathToFileURL(process.argv[3]).href);
const { renderMarkdown, safeUrl, MARKDOWN_TAGS, MARKDOWN_CLASSES } = markdown;
const { buildHistory, historyRow, formatDuration, formatTokens, normalizeQuery } = history;

const failures = [];
function check(label, condition, detail = "") {
  if (!condition) failures.push(`${label}${detail ? `: ${detail}` : ""}`);
}
function equal(label, actual, expected) {
  check(label, actual === expected, `expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
}

// Walk a rendered tree the way app.js's DOM builder does, so a case can assert
// about every node the browser would create.
function walk(nodes, visit) {
  for (const node of nodes) {
    visit(node);
    if (Array.isArray(node.children)) walk(node.children, visit);
  }
}
function tags(result) {
  const seen = [];
  walk(result.nodes, (node) => { if (node.tag) seen.push(node.tag); });
  return seen;
}
function textOf(result) {
  let out = "";
  walk(result.nodes, (node) => { if (typeof node.text === "string") out += node.text; });
  return out;
}
function hrefs(result) {
  const out = [];
  walk(result.nodes, (node) => { if (node.tag === "a") out.push(node.href); });
  return out;
}
function noticeKinds(result) {
  return result.notices.map((notice) => notice.kind).sort();
}

// --- script and unsafe HTML are never markup ---------------------------------

const scriptCases = [
  `<script>alert(1)</script>`,
  `<img src=x onerror="alert(1)">`,
  `<iframe src="https://evil.example/"></iframe>`,
  `<svg><animate onbegin=alert(1) attributeName=x dur=1s>`,
  `<a href="https://ok.example" onclick="alert(1)">click</a>`,
  `<div style="position:fixed;inset:0">overlay</div>`,
  `<style>body{display:none}</style>`,
  `<object data="javascript:alert(1)"></object>`,
  `<math><mtext><table><mglyph><style><img src=x onerror=alert(1)>`,
  `<!--[if IE]><script>alert(1)</script><![endif]-->`,
  `<textarea><script>alert(1)</script>`,
];
for (const source of scriptCases) {
  const result = renderMarkdown(source);
  const emitted = tags(result);
  const forbidden = emitted.filter((tag) => !MARKDOWN_TAGS.has(tag));
  check(`no tag outside the allowlist for ${source.slice(0, 28)}`, forbidden.length === 0, forbidden.join(","));
  check(`no script element for ${source.slice(0, 28)}`, !emitted.includes("script"), emitted.join(","));
  check(`no img element for ${source.slice(0, 28)}`, !emitted.includes("img"), emitted.join(","));
  // Raw HTML survives as literal text, which is the whole guarantee: the
  // characters reach the reader, the markup never does.
  check(`raw markup stays literal text for ${source.slice(0, 28)}`,
    textOf(result).includes(source.split("\n")[0].slice(0, 12)), textOf(result));
}

// Every node an attacker could hope to decorate carries no attribute but href.
const attributeProbe = renderMarkdown(`[x](https://ok.example)\n\n![y](https://ok.example/i.png)\n\n\`code\``);
walk(attributeProbe.nodes, (node) => {
  if (!node.tag) return;
  const keys = Object.keys(node).filter((key) => !["tag", "children", "href", "className"].includes(key));
  check("a rendered node carries no attribute beyond tag, children, href, and className", keys.length === 0, keys.join(","));
  if (node.className !== undefined) {
    check("a class name comes from the closed vocabulary", MARKDOWN_CLASSES.has(node.className), String(node.className));
  }
});

// --- dangerous URL protocols are refused, visibly ----------------------------

const dangerous = [
  "javascript:alert(1)",
  "JaVaScRiPt:alert(1)",
  "  javascript:alert(1)",
  "java\tscript:alert(1)",
  "java\nscript:alert(1)",
  "jav\u0000ascript:alert(1)",
  "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==",
  "data:image/svg+xml;base64,PHN2Zy8+",
  "vbscript:msgbox(1)",
  "file:///etc/passwd",
  "blob:https://evil.example/1234",
  "about:blank",
  "//evil.example/path",
  "/api/report?task=x",
  "../../etc/passwd",
];
for (const raw of dangerous) {
  equal(`safeUrl refuses ${JSON.stringify(raw)}`, safeUrl(raw), null);
  const result = renderMarkdown(`[label](${raw})`);
  equal(`no link is produced for ${JSON.stringify(raw)}`, hrefs(result).length, 0);
  check(`the label survives as text for ${JSON.stringify(raw)}`, textOf(result).includes("label"), textOf(result));
  // A destination containing a line break is not a link in the first place, so
  // there is nothing to disclose; every destination that does parse as a link
  // and is then refused must say so, because a silently dropped link would
  // leave the reader believing the report said something it did not.
  if (!raw.includes("\n")) {
    check(`the refusal is disclosed for ${JSON.stringify(raw)}`,
      result.notices.some((notice) => notice.kind === "blocked_link"), JSON.stringify(result.notices));
    check(`the refusal is visible in the rendered text for ${JSON.stringify(raw)}`,
      /link removed/.test(textOf(result)), textOf(result));
  }
}

for (const raw of ["https://ok.example/a", "http://ok.example/a", "mailto:crew@example.com"]) {
  equal(`safeUrl allows ${raw}`, safeUrl(raw), raw);
  equal(`a permitted protocol links for ${raw}`, hrefs(renderMarkdown(`[label](${raw})`))[0], raw);
}

// An autolink and a bare URL travel the same policy as a bracketed link.
equal("an angle autolink is linked", hrefs(renderMarkdown("<https://ok.example/x>"))[0], "https://ok.example/x");
equal("a bare url is linked", hrefs(renderMarkdown("see https://ok.example/x for detail"))[0], "https://ok.example/x");
equal("an angle autolink with a refused protocol produces no link",
  hrefs(renderMarkdown("<javascript:alert(1)>")).length, 0);

// An image never becomes an <img>: the page's own policy forbids remote images,
// and a broken-image icon would read as a corrupt report rather than as policy.
const image = renderMarkdown("![a diagram](https://ok.example/d.png)");
check("an image is not an img element", !tags(image).includes("img"), tags(image).join(","));
equal("an image becomes a link", hrefs(image)[0], "https://ok.example/d.png");
check("an image keeps its alt text", textOf(image).includes("a diagram"), textOf(image));
const badImage = renderMarkdown("![x](javascript:alert(1))");
equal("an image with a refused protocol produces no link", hrefs(badImage).length, 0);
check("a refused image is disclosed", noticeKinds(badImage).includes("blocked_image"), JSON.stringify(badImage.notices));

// --- malformed markup terminates and stays inert -----------------------------

const malformed = [
  "```\nunclosed fence\n",
  "~~~\nunclosed tilde fence",
  "[unbalanced](",
  "[[[[[[[[[[nested",
  "**".repeat(500),
  "`".repeat(500),
  "> ".repeat(200) + "deep quote",
  "- ".repeat(400) + "item",
  "| a | b |\n| --- |\n| 1 |",
  "#".repeat(80) + " heading",
  "\u0000\u0001\u0002 control bytes \u007f",
  "*".repeat(2000) + "text",
  "![](" + "(".repeat(200),
];
for (const source of malformed) {
  let result = null;
  const started = Date.now();
  try {
    result = renderMarkdown(source);
  } catch (error) {
    check(`malformed input does not throw for ${JSON.stringify(source.slice(0, 24))}`, false, error.message);
    continue;
  }
  check(`malformed input renders for ${JSON.stringify(source.slice(0, 24))}`, Array.isArray(result.nodes));
  check(`malformed input terminates quickly for ${JSON.stringify(source.slice(0, 24))}`, Date.now() - started < 4_000, `${Date.now() - started}ms`);
  const forbidden = tags(result).filter((tag) => !MARKDOWN_TAGS.has(tag));
  check(`malformed input emits no unexpected tag for ${JSON.stringify(source.slice(0, 24))}`, forbidden.length === 0, forbidden.join(","));
}

// --- an enormous report is bounded, and says so ------------------------------

const huge = `${"paragraph text\n\n".repeat(60_000)}`;
const started = Date.now();
const bounded = renderMarkdown(huge);
check("an enormous report renders within a few seconds", Date.now() - started < 10_000, `${Date.now() - started}ms`);
check("an enormous report is bounded", bounded.truncated.chars || bounded.truncated.lines || bounded.truncated.nodes, JSON.stringify(bounded.truncated));
check("an enormous report discloses that it was cut short",
  result_has_truncation_notice(bounded), JSON.stringify(noticeKinds(bounded)));
function result_has_truncation_notice(result) {
  return noticeKinds(result).some((kind) => kind.endsWith("_truncated"));
}
check("an enormous report emits a bounded node count", tags(bounded).length <= 12_001, String(tags(bounded).length));

// --- ordinary Markdown still renders ------------------------------------------

const ordinary = renderMarkdown([
  "# Findings",
  "",
  "The **root cause** is a `null` check, see [issue 16](https://github.com/o/r/issues/16).",
  "",
  "- first",
  "- second",
  "",
  "1. step one",
  "2. step two",
  "",
  "> a quoted conclusion",
  "",
  "| field | value |",
  "| --- | --- |",
  "| kind | scout |",
  "",
  "```sh",
  "echo <script>not markup</script>",
  "```",
].join("\n"));
const ordinaryTags = tags(ordinary);
for (const tag of ["h1", "p", "strong", "code", "a", "ul", "li", "ol", "blockquote", "table", "th", "td", "pre"]) {
  check(`ordinary markdown renders ${tag}`, ordinaryTags.includes(tag), ordinaryTags.join(","));
}
equal("ordinary markdown keeps its link", hrefs(ordinary)[0], "https://github.com/o/r/issues/16");
check("a fenced block keeps hostile-looking content as text",
  textOf(ordinary).includes("echo <script>not markup</script>"), textOf(ordinary));
equal("ordinary markdown reports nothing removed", ordinary.notices.length, 0);

// ---------------------------------------------------------------------------
// History records
// ---------------------------------------------------------------------------

function manifest(id, overrides = {}) {
  return {
    schema: "fm-outcome-manifest.v1",
    task_id: id,
    home: "/home/captain/firstmate",
    title: `${id} title`,
    project: "firstmate",
    kind: "ship",
    mode: "no-mistakes",
    yolo: "off",
    harness: "codex",
    model: "gpt-5.6-terra",
    effort: "medium",
    timestamps: { created: "2026-08-01T00:00:00Z", started: "2026-08-01T01:00:00Z", completed: "2026-08-02T03:00:00Z" },
    timestamp_sources: { created: "brief_mtime", started: "meta_mtime", completed: "manifest_write" },
    outcome: { state: "done", detail: "PR merged", source: "status_event", forced: false },
    pr: {
      url: "https://github.com/o/r/pull/9", provider: "github", host: "github.com", path: "o/r", number: 9, head: null,
      status: { state: "merged", draft: false, review: "approved", checks: "passing", mergeable: "mergeable", head: null, observed_at: "2026-08-02T02:55:00Z", source: "github" },
    },
    report: { path: "/home/captain/firstmate/data/" + id + "/report.md", present: false },
    attribution: { backend: "tmux", endpoint: { target: null, task_id: null }, worktree: null, task_tmp: null, traceparent: null, secondmate_home: null },
    work_items: { schema: "fm-work-items.v1", references: [] },
    gbrain: { status: "absent", receipt: null, observed_at: null, detail: null },
    recorded_at: "2026-08-02T03:00:00Z",
    ...overrides,
  };
}

function envelope(records, extra = {}) {
  return {
    schema: "fm-dashboard-history.v1",
    status: { phase: "ready", refreshing: false, stale: false, error: null },
    config: { record_limit: 500 },
    history: { schema: "fm-outcome-history.v1", records, total: records.length, shown: records.length, truncated: false, malformed: [], ...extra.history },
    usage: extra.usage ?? null,
  };
}

// A completed task carries its full dispatch identity and the complete PR URL.
const oneRow = buildHistory(envelope([manifest("alpha")])).rows[0];
equal("a completed task keeps its harness", oneRow.harness, "codex");
equal("a completed task keeps its model", oneRow.model, "gpt-5.6-terra");
equal("a completed task keeps its effort", oneRow.effort, "medium");
equal("a completed task shows the complete pull request URL", oneRow.pr.url, "https://github.com/o/r/pull/9");
equal("a merged pull request reads as merged", oneRow.pr.state, "merged");
equal("a recorded observation is marked observed", oneRow.pr.observed, true);
equal("a completed task computes its duration", oneRow.duration.seconds, 93_600);
equal("a completed task formats its duration", formatDuration(oneRow.duration), "1.1d");

// A manifest whose start was never recorded says unknown, not zero.
const noStart = buildHistory(envelope([manifest("beta", {
  timestamps: { created: null, started: null, completed: "2026-08-02T03:00:00Z" },
  timestamp_sources: { created: null, started: null, completed: "manifest_write" },
})])).rows[0];
equal("a missing start renders as an unknown duration", formatDuration(noStart.duration), "unknown");
equal("a missing start is not treated as known", noStart.duration.known, false);

// A pull request with no recorded observation is never shown as a reading.
const unobserved = buildHistory(envelope([manifest("gamma", {
  pr: { ...manifest("gamma").pr, status: { state: "unknown", draft: null, review: "unknown", checks: "unknown", mergeable: "unknown", head: null, observed_at: null, source: "absent" } },
})])).rows[0];
equal("an unobserved pull request is not marked observed", unobserved.pr.observed, false);
equal("an unobserved pull request state is unknown", unobserved.pr.state, "unknown");
equal("an unobserved pull request tone is unknown", unobserved.pr.tone, "unknown");

// --- usage is unavailable, never zero ----------------------------------------

const noUsage = buildHistory(envelope([manifest("alpha")])).rows[0];
equal("usage with no collector is unavailable", noUsage.usage.available, false);
equal("usage with no collector has no totals", noUsage.usage.totals, null);
check("usage with no collector states a reason", Boolean(noUsage.usage.reason), JSON.stringify(noUsage.usage));
equal("an unavailable total never formats as a number", formatTokens(noUsage.usage.totals?.total_tokens), "unavailable");

const collectorNoRow = buildHistory(envelope([manifest("alpha")], { usage: { available: true, reason: null, tasks: {} } })).rows[0];
equal("a collected home with no attributed row is still unavailable", collectorNoRow.usage.available, false);
check("an unattributed task explains itself", /attributed/.test(collectorNoRow.usage.reason), collectorNoRow.usage.reason);

const withUsage = buildHistory(envelope([manifest("alpha")], {
  usage: { available: true, reason: null, tasks: { alpha: { total_tokens: 1_250_000, input_tokens: 900_000, output_tokens: 350_000, events: 12, sessions: 2 } } },
})).rows[0];
equal("attributed usage is available", withUsage.usage.available, true);
equal("attributed usage keeps its total", withUsage.usage.totals.total_tokens, 1_250_000);
equal("attributed usage formats compactly", formatTokens(withUsage.usage.totals.total_tokens), "1.25M");
// A real zero and an unreadable field must not collapse into each other.
const zeroUsage = buildHistory(envelope([manifest("alpha")], {
  usage: { available: true, reason: null, tasks: { alpha: { total_tokens: 0 } } },
})).rows[0];
equal("a genuine zero total stays available", zeroUsage.usage.available, true);
equal("a genuine zero total renders as zero", formatTokens(zeroUsage.usage.totals.total_tokens), "0");
const brokenUsage = buildHistory(envelope([manifest("alpha")], {
  usage: { available: true, reason: null, tasks: { alpha: { total_tokens: "lots" } } },
})).rows[0];
equal("an unreadable total is unavailable rather than zero", brokenUsage.usage.available, false);

// --- corrupt and old-schema records are isolated with a warning ---------------

const damaged = buildHistory(envelope([manifest("alpha")], {
  history: {
    malformed: [
      { id: "legacy-task", path: "/h/data/legacy-task/outcome.json", reason: "unexpected_fields" },
      { id: "broken-task", path: "/h/data/broken-task/outcome.json", reason: "unreadable_or_wrong_schema" },
    ],
  },
}));
equal("an unreadable record is disclosed, not dropped", damaged.malformed.length, 2);
check("an unreadable record explains itself in plain words",
  damaged.malformed.every((entry) => entry.explanation.length > 20), JSON.stringify(damaged.malformed));
equal("a readable record still renders alongside", damaged.rows.length, 1);

// --- filters, bounded search, and pagination ---------------------------------

const many = [];
for (let index = 0; index < 60; index += 1) {
  many.push(manifest(`task-${String(index).padStart(2, "0")}`, {
    project: index % 2 ? "firstmate" : "arknode",
    harness: index % 3 ? "codex" : "claude",
    model: index % 3 ? "gpt-5.6-terra" : "opus",
    outcome: { state: index % 5 ? "done" : "failed", detail: null, source: "status_event", forced: false },
    timestamps: { created: null, started: null, completed: `2026-0${(index % 3) + 1}-0${(index % 9) + 1}T00:00:00Z` },
    timestamp_sources: { created: null, started: null, completed: "manifest_write" },
    work_items: { schema: "fm-work-items.v1", references: index === 7 ? [{ url: "https://github.com/o/r/issues/16", forge: "github", host: "github.com", path: "o/r", owner: "o", repo: "r", number: 16, kind: "issue", origin: "explicit", enrichment: { title: "Browse completed work", state: "open", observed_at: null, source: null } }] : [] },
  }));
}
const paged = buildHistory(envelope(many), { page: 0, pageSize: 25 });
equal("the first page is bounded by the page size", paged.rows.length, 25);
equal("pagination reports the total", paged.page.matched, 60);
equal("pagination reports the page count", paged.page.pages, 3);
equal("the last page holds the remainder", buildHistory(envelope(many), { page: 2, pageSize: 25 }).rows.length, 10);
// A page index past the end resolves to the last page rather than an empty view.
equal("an out-of-range page clamps", buildHistory(envelope(many), { page: 99, pageSize: 25 }).page.index, 2);

equal("a project filter narrows the set", buildHistory(envelope(many), { project: "arknode" }).page.matched, 30);
equal("a harness filter narrows the set", buildHistory(envelope(many), { harness: "claude" }).page.matched, 20);
equal("an outcome filter narrows the set", buildHistory(envelope(many), { outcome: "failed" }).page.matched, 12);
equal("a date floor narrows the set", buildHistory(envelope(many), { from: "2026-03-01" }).page.matched, 20);
equal("a date ceiling narrows the set", buildHistory(envelope(many), { to: "2026-01-31" }).page.matched, 20);
check("facets are offered from the records themselves",
  buildHistory(envelope(many)).facets.project.join(",") === "arknode,firstmate",
  buildHistory(envelope(many)).facets.project.join(","));

// Search covers the safe indexed fields, including the linked work item, and is
// bounded rather than unbounded free text.
equal("search matches a task id", buildHistory(envelope(many), { query: "task-07" }).page.matched, 1);
equal("search matches a linked work item", buildHistory(envelope(many), { query: "issues/16" }).page.matched, 1);
equal("search matches a work item title", buildHistory(envelope(many), { query: "browse completed" }).page.matched, 1);
equal("search is case insensitive", buildHistory(envelope(many), { query: "TASK-07" }).page.matched, 1);
equal("search that matches nothing returns nothing", buildHistory(envelope(many), { query: "no such thing" }).page.matched, 0);
equal("a search term is bounded", normalizeQuery("x".repeat(400)).length, 120);
// A search term is a literal substring, never a pattern the reader could turn
// into an expensive or surprising match.
equal("search does not interpret regular expressions", buildHistory(envelope(many), { query: ".*" }).page.matched, 0);

// --- work items, reports, and the semantic-search gate ------------------------

const withItem = buildHistory(envelope([manifest("alpha", {
  work_items: { schema: "fm-work-items.v1", references: [
    { url: "https://gitea.example/o/r/issues/4", forge: "gitea", host: "gitea.example", path: "o/r", owner: "o", repo: "r", number: 4, kind: "issue", origin: "explicit", enrichment: { title: null, state: null, observed_at: null, source: null } },
    { url: "https://unknown.example/tickets/7", forge: "unknown", host: "unknown.example", path: null, owner: null, repo: null, number: null, kind: null, origin: "explicit", enrichment: { title: null, state: null, observed_at: null, source: null } },
  ] },
})])).rows[0];
equal("a linked work item is carried into history", withItem.work_items.length, 2);
equal("an unenriched work item keeps its full URL", withItem.work_items[0].url, "https://gitea.example/o/r/issues/4");
// An unsupported forge is still a link back to what motivated the work.
equal("an unsupported forge is still carried", withItem.work_items[1].forge, "unknown");
equal("work without an item renders cleanly", buildHistory(envelope([manifest("alpha")])).rows[0].work_items.length, 0);

const scout = buildHistory(envelope([manifest("scout-task", {
  kind: "scout",
  report: { path: "/h/data/scout-task/report.md", present: true },
  gbrain: { status: "captured", receipt: "abc123", observed_at: "2026-08-02T03:00:00Z", detail: null },
})])).rows[0];
equal("a retained report is offered", scout.report.present, true);
equal("a captured report is marked captured", scout.gbrain.status, "captured");

const gate = buildHistory(envelope([manifest("alpha")]));
equal("semantic search is absent by default", gate.semantic_search.available, false);
equal("semantic search reports nothing captured", gate.semantic_search.captured_records, 0);
check("history is usable with semantic search absent", gate.rows.length === 1, JSON.stringify(gate.page));
equal("a captured report is counted for the search gate",
  buildHistory(envelope([manifest("s", { gbrain: { status: "captured", receipt: "r", observed_at: "2026-08-02T03:00:00Z", detail: null } })])).semantic_search.captured_records, 1);

// --- an empty and an unavailable history are different facts ------------------

const empty = buildHistory(envelope([]));
equal("an empty history is empty", empty.empty, true);
equal("an empty history has no rows", empty.rows.length, 0);
const missing = buildHistory({ schema: "fm-dashboard-history.v1", status: { phase: "unavailable", error: { kind: "command_missing", message: "gone" } }, history: null, usage: null });
equal("an unavailable history has no rows either", missing.rows.length, 0);
equal("an unavailable history reports no records read", missing.record_total, null);

// The archive says when more completed work exists than was read, so the view
// never implies the fleet has only ever finished this much.
const truncated = buildHistory(envelope(many, { history: { truncated: true, total: 900 } }));
equal("a bounded read is disclosed", truncated.truncated, true);
equal("a bounded read reports the stored total", truncated.record_total, 900);

// --- a record with almost nothing in it still renders --------------------------
const sparse = historyRow({ schema: "fm-outcome-manifest.v1", task_id: "sparse", timestamps: {}, outcome: {}, pr: {}, report: {} }, null);
equal("a sparse record keeps its id", sparse.id, "sparse");
equal("a sparse record has no title rather than an invented one", sparse.title, null);
equal("a sparse record has an unknown outcome", sparse.outcome.state, "unknown");
equal("a sparse record has no pull request", sparse.pr.present, false);
equal("a sparse record has an unknown duration", formatDuration(sparse.duration), "unknown");

if (failures.length) {
  console.error(`${failures.length} history behavior failure(s):`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log("dashboard history and report rendering behavior verified");
})().catch((error) => { console.error(error); process.exit(1); });
NODE

pass "history records, filters, pagination, and the sanitized report renderer behave"
