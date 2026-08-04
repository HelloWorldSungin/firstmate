// markdown.js - the sanitized Markdown pipeline for retained scout reports.
//
// A retained report is arbitrary content written by a worker, so this module
// treats every byte of it as hostile. It is the single executable owner of what
// a report is allowed to become on screen; docs/dashboard.md states the same
// policy for humans.
//
// THE STRUCTURAL GUARANTEE. This module never produces an HTML string, and the
// browser never parses one. `renderMarkdown` returns a tree of plain objects,
// and the renderer in app.js builds it with createElement, createTextNode, and
// an attribute allowlist. There is no innerHTML, no insertAdjacentHTML, no
// template parsing, and no HTML sanitizer to outsmart anywhere on this path.
// Raw HTML in the source is therefore never markup: `<script>` reaches the page
// as the literal seven characters a reader sees, because the only way text can
// leave here is inside a {text} node.
//
// THE URL POLICY. A link survives only when it is absolute and its scheme is
// allowlisted (http, https, mailto). Everything else - javascript:, data:,
// vbscript:, file:, blob:, an unknown scheme, a protocol-relative //host, a
// relative path pointing back at the dashboard - is refused, and the refusal is
// VISIBLE: the label stays as text next to a marker naming what was removed.
// A silently dropped link would leave a reader believing the report said
// something it did not. ASCII whitespace and control characters are stripped
// before the scheme is read, because a URL parser ignores them and a naive
// prefix check does not.
//
// IMAGES ARE NEVER <img>. The dashboard's Content-Security-Policy allows
// img-src 'self', so a remote image cannot load anyway; rendering one would
// only produce a broken-image icon that reads as a corrupt report rather than
// as policy. An image becomes a labeled external link instead, which also keeps
// report content from acting as a tracking pixel.
//
// BOUNDS. Characters, lines, emitted nodes, block nesting, and per-block inline
// length are all capped, and every truncation is disclosed in `notices` rather
// than quietly shortening the document.

export const MARKDOWN_LIMITS = {
  maxChars: 400_000,
  maxLines: 8_000,
  maxNodes: 12_000,
  maxDepth: 8,
  maxInlineChars: 8_000,
  maxUrlLength: 2_000,
  maxNoticeSamples: 5,
};

// The only schemes a report may link to, and the only ones the DOM builder will
// accept back when it re-validates before setting an attribute.
export const LINK_SCHEMES = new Set(["http", "https", "mailto"]);

// Every tag this module can emit. app.js refuses anything outside this set.
export const MARKDOWN_TAGS = new Set([
  "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote",
  "pre", "code", "em", "strong", "del", "a", "hr", "br", "span",
  "table", "thead", "tbody", "tr", "th", "td",
]);

// Class names are a closed vocabulary, never derived from report content.
export const MARKDOWN_CLASSES = new Set(["md-blocked", "md-image-link", "md-code-block"]);

const ESCAPABLE = new Set([..."\\`*_{}[]()#+-.!|~<>\""]);
const FENCE = /^([ ]{0,3})(`{3,}|~{3,})\s*([^`]*)$/;
const ATX = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/;
const RULE = /^ {0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$/;
const BULLET = /^( {0,3})([-*+])(\s+)(.*)$/;
const ORDERED = /^( {0,3})(\d{1,9})([.)])(\s+)(.*)$/;
const TABLE_DELIMITER = /^ {0,3}\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/;
const BLOCKQUOTE = /^ {0,3}>\s?(.*)$/;

class Budget {
  constructor(limits) {
    this.limits = limits;
    this.nodes = 0;
    this.notices = new Map();
    this.truncated = { chars: false, lines: false, nodes: false, inline: false };
  }

  // Returns false once the node budget is spent, so a caller stops emitting
  // instead of building a tree the browser cannot lay out.
  spend() {
    if (this.nodes >= this.limits.maxNodes) {
      this.truncated.nodes = true;
      return false;
    }
    this.nodes += 1;
    return true;
  }

  note(kind, sample) {
    let notice = this.notices.get(kind);
    if (!notice) {
      notice = { kind, count: 0, samples: [] };
      this.notices.set(kind, notice);
    }
    notice.count += 1;
    if (sample && notice.samples.length < this.limits.maxNoticeSamples && !notice.samples.includes(sample)) {
      notice.samples.push(sample);
    }
  }
}

function textNode(value) {
  return { text: value };
}

function elementNode(tag, children, extra = {}) {
  return { tag, children, ...extra };
}

// The scheme of a URL as a URL parser would read it, or null when the reference
// is not absolute. Whitespace and control characters are removed first: a
// parser ignores them, so `java\tscript:alert(1)` is a javascript: URL no
// matter how innocent the raw bytes look.
export function urlScheme(raw) {
  if (typeof raw !== "string") return null;
  const stripped = raw.replace(/[\u0000-\u0020\u007f-\u009f]/g, "");
  if (!stripped || stripped.startsWith("//")) return null;
  const match = /^([A-Za-z][A-Za-z0-9+.\-]*):/.exec(stripped);
  return match ? match[1].toLowerCase() : null;
}

// The URL a link or image may use, or null when policy refuses it. Callers must
// treat null as "show the label as text and say what was removed", never as
// "drop it".
export function safeUrl(raw, limits = MARKDOWN_LIMITS) {
  if (typeof raw !== "string") return null;
  const stripped = raw.replace(/[\u0000-\u0020\u007f-\u009f]/g, "");
  if (!stripped || stripped.length > limits.maxUrlLength) return null;
  const scheme = urlScheme(stripped);
  if (!scheme || !LINK_SCHEMES.has(scheme)) return null;
  return stripped;
}

function blockedMarker(raw, budget, kind) {
  const scheme = urlScheme(raw);
  budget.note(kind, scheme ? `${scheme}:` : "relative or malformed reference");
  if (!budget.spend()) return null;
  const label = scheme ? `link removed: ${scheme}: is not an allowed protocol` : "link removed: not an absolute http, https, or mailto URL";
  return elementNode("span", [textNode(` [${label}] `)], { className: "md-blocked" });
}

// ---------------------------------------------------------------------------
// Inline parsing
// ---------------------------------------------------------------------------

function codeSpanAt(source, start) {
  let open = 0;
  while (source[start + open] === "`") open += 1;
  const fence = "`".repeat(open);
  const from = start + open;
  let search = from;
  for (;;) {
    const index = source.indexOf(fence, search);
    if (index === -1) return null;
    if (source[index + open] === "`") {
      search = index + open;
      while (source[search] === "`") search += 1;
      continue;
    }
    let content = source.slice(from, index);
    if (content.length > 2 && content.startsWith(" ") && content.endsWith(" ") && content.trim() !== "") {
      content = content.slice(1, -1);
    }
    return { content, next: index + open };
  }
}

// A bracketed label with its matching close bracket, honoring nesting and
// escapes. Returns null for an unbalanced `[`, which then stays literal.
function bracketSpan(source, start) {
  let depth = 0;
  for (let index = start; index < source.length; index += 1) {
    const character = source[index];
    if (character === "\\") { index += 1; continue; }
    if (character === "[") depth += 1;
    else if (character === "]") {
      depth -= 1;
      if (depth === 0) return { label: source.slice(start + 1, index), next: index + 1 };
    }
  }
  return null;
}

// The `(destination "title")` half of a link. The destination stops at the
// first unescaped space so a title cannot smuggle itself into the URL.
function destinationSpan(source, start) {
  if (source[start] !== "(") return null;
  let depth = 0;
  for (let index = start; index < source.length; index += 1) {
    const character = source[index];
    if (character === "\\") { index += 1; continue; }
    if (character === "(") depth += 1;
    else if (character === ")") {
      depth -= 1;
      if (depth === 0) {
        const inner = source.slice(start + 1, index).trim();
        const angled = /^<([^>]*)>/.exec(inner);
        const destination = angled ? angled[1] : inner.split(/\s+/, 1)[0] || "";
        return { destination, next: index + 1 };
      }
    }
    if (character === "\n") return null;
  }
  return null;
}

function emphasisAt(source, start, marker, run) {
  const fence = marker.repeat(run);
  let search = start + run;
  for (;;) {
    const index = source.indexOf(fence, search);
    if (index === -1) return null;
    if (source[index - 1] === "\\") { search = index + run; continue; }
    if (index === start + run) { search = index + run; continue; }
    // A longer run than requested belongs to a wider emphasis span.
    if (run === 1 && source[index + 1] === marker) { search = index + run + 1; continue; }
    return { content: source.slice(start + run, index), next: index + fence.length };
  }
}

const URL_TRAILING = /[.,;:!?'")\]}]+$/;

function bareUrlAt(source, start) {
  const rest = source.slice(start);
  if (!/^https?:\/\/[^\s<>]/.test(rest)) return null;
  let end = start;
  while (end < source.length && !/[\s<>]/.test(source[end])) end += 1;
  let raw = source.slice(start, end);
  const trimmed = raw.replace(URL_TRAILING, "");
  // Keep a trailing `)` only when the URL itself opened the parenthesis.
  if (trimmed !== raw) {
    const opens = (trimmed.match(/\(/g) || []).length;
    const closes = (trimmed.match(/\)/g) || []).length;
    raw = opens > closes && raw[trimmed.length] === ")" ? `${trimmed})` : trimmed;
  }
  return raw ? { raw, next: start + raw.length } : null;
}

function linkNode(destination, children, budget, kind) {
  const href = safeUrl(destination, budget.limits);
  if (!href) return { blocked: blockedMarker(destination, budget, kind) };
  if (!budget.spend()) return { blocked: null };
  return { node: elementNode("a", children, { href }) };
}

function parseInline(source, budget, depth) {
  const out = [];
  let buffer = "";
  let index = 0;
  const flush = () => {
    if (!buffer) return;
    if (budget.spend()) out.push(textNode(buffer));
    buffer = "";
  };
  const push = (node) => { if (node) out.push(node); };

  let text = source;
  if (text.length > budget.limits.maxInlineChars) {
    text = text.slice(0, budget.limits.maxInlineChars);
    budget.truncated.inline = true;
    budget.note("inline_truncated", null);
  }

  while (index < text.length) {
    const character = text[index];

    if (character === "\\" && ESCAPABLE.has(text[index + 1])) {
      buffer += text[index + 1];
      index += 2;
      continue;
    }

    if (character === "`") {
      const span = codeSpanAt(text, index);
      if (span) {
        flush();
        if (budget.spend()) push(elementNode("code", budget.spend() ? [textNode(span.content)] : []));
        index = span.next;
        continue;
      }
    }

    // An image becomes a labeled link, never an <img>: see the header.
    if (character === "!" && text[index + 1] === "[") {
      const label = bracketSpan(text, index + 1);
      const destination = label ? destinationSpan(text, label.next) : null;
      if (label && destination) {
        flush();
        const alt = label.label.trim() || "image";
        const result = linkNode(destination.destination, budget.spend() ? [textNode(`${alt} (image)`)] : [], budget, "blocked_image");
        if (result.node) {
          result.node.className = "md-image-link";
          push(result.node);
        } else {
          if (budget.spend()) push(textNode(`${alt} (image)`));
          push(result.blocked);
        }
        index = destination.next;
        continue;
      }
    }

    if (character === "[") {
      const label = bracketSpan(text, index);
      const destination = label ? destinationSpan(text, label.next) : null;
      if (label && destination) {
        flush();
        const children = depth < budget.limits.maxDepth ? parseInline(label.label, budget, depth + 1) : [];
        const result = linkNode(destination.destination, children, budget, "blocked_link");
        if (result.node) push(result.node);
        else {
          for (const child of children) push(child);
          push(result.blocked);
        }
        index = destination.next;
        continue;
      }
    }

    if (character === "<") {
      const close = text.indexOf(">", index);
      const inner = close === -1 ? "" : text.slice(index + 1, close);
      if (inner && !/[\s<]/.test(inner) && urlScheme(inner)) {
        flush();
        const result = linkNode(inner, budget.spend() ? [textNode(inner)] : [], budget, "blocked_link");
        if (result.node) push(result.node);
        else {
          if (budget.spend()) push(textNode(inner));
          push(result.blocked);
        }
        index = close + 1;
        continue;
      }
      // Anything else starting with `<` is literal text, including every HTML
      // tag a report might contain. This is the whole raw-HTML story.
    }

    if ((character === "*" || character === "_" || character === "~") && depth < budget.limits.maxDepth) {
      const doubled = text[index + 1] === character;
      const run = character === "~" ? (doubled ? 2 : 0) : (doubled ? 2 : 1);
      if (run) {
        const span = emphasisAt(text, index, character, run);
        if (span && span.content.trim()) {
          flush();
          const tag = character === "~" ? "del" : run === 2 ? "strong" : "em";
          if (budget.spend()) push(elementNode(tag, parseInline(span.content, budget, depth + 1)));
          index = span.next;
          continue;
        }
      }
    }

    if ((character === "h") && (index === 0 || /[\s(<]/.test(text[index - 1]))) {
      const bare = bareUrlAt(text, index);
      if (bare) {
        flush();
        const result = linkNode(bare.raw, budget.spend() ? [textNode(bare.raw)] : [], budget, "blocked_link");
        if (result.node) push(result.node);
        else {
          if (budget.spend()) push(textNode(bare.raw));
          push(result.blocked);
        }
        index = bare.next;
        continue;
      }
    }

    buffer += character;
    index += 1;
  }
  flush();
  return out;
}

// ---------------------------------------------------------------------------
// Block parsing
// ---------------------------------------------------------------------------

function fenceCloses(line, fence) {
  const match = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(line);
  return Boolean(match) && match[1][0] === fence[0] && match[1].length >= fence.length;
}

function splitRow(line) {
  const trimmed = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  const cells = [];
  let cell = "";
  for (let index = 0; index < trimmed.length; index += 1) {
    const character = trimmed[index];
    if (character === "\\" && trimmed[index + 1] === "|") { cell += "|"; index += 1; continue; }
    if (character === "|") { cells.push(cell.trim()); cell = ""; continue; }
    cell += character;
  }
  cells.push(cell.trim());
  return cells;
}

function parseBlocks(lines, budget, depth) {
  const out = [];
  let index = 0;
  const push = (node) => { if (node) out.push(node); };

  while (index < lines.length) {
    const line = lines[index];

    if (!line.trim()) { index += 1; continue; }

    const fence = FENCE.exec(line);
    if (fence) {
      const marker = fence[2];
      const body = [];
      index += 1;
      while (index < lines.length && !fenceCloses(lines[index], marker)) {
        body.push(lines[index]);
        index += 1;
      }
      if (index < lines.length) index += 1;
      if (budget.spend() && budget.spend() && budget.spend()) {
        push(elementNode("pre", [elementNode("code", [textNode(body.join("\n"))])], { className: "md-code-block" }));
      }
      continue;
    }

    if (RULE.test(line)) {
      if (budget.spend()) push(elementNode("hr", []));
      index += 1;
      continue;
    }

    const heading = ATX.exec(line);
    if (heading) {
      const level = Math.min(6, heading[1].length);
      if (budget.spend()) push(elementNode(`h${level}`, parseInline(heading[2], budget, 0)));
      index += 1;
      continue;
    }

    if (BLOCKQUOTE.test(line)) {
      const body = [];
      while (index < lines.length && (BLOCKQUOTE.test(lines[index]) || (body.length && lines[index].trim()))) {
        const quoted = BLOCKQUOTE.exec(lines[index]);
        body.push(quoted ? quoted[1] : lines[index]);
        index += 1;
      }
      if (budget.spend()) {
        push(elementNode("blockquote", depth < budget.limits.maxDepth ? parseBlocks(body, budget, depth + 1) : []));
      }
      continue;
    }

    const bullet = BULLET.exec(line);
    const ordered = ORDERED.exec(line);
    if ((bullet || ordered) && !RULE.test(line)) {
      const isOrdered = Boolean(ordered && !bullet);
      const items = [];
      while (index < lines.length) {
        const itemMatch = isOrdered ? ORDERED.exec(lines[index]) : BULLET.exec(lines[index]);
        if (!itemMatch) {
          // A blank line inside a list keeps the list open; anything else ends it.
          if (!lines[index].trim() && index + 1 < lines.length
            && (isOrdered ? ORDERED.test(lines[index + 1]) : BULLET.test(lines[index + 1]))) {
            index += 1;
            continue;
          }
          break;
        }
        const indent = itemMatch[1].length + (isOrdered ? itemMatch[2].length + 1 + itemMatch[4].length : 1 + itemMatch[3].length);
        const body = [isOrdered ? itemMatch[5] : itemMatch[4]];
        index += 1;
        while (index < lines.length && lines[index].trim()
          && !(isOrdered ? ORDERED.test(lines[index]) : BULLET.test(lines[index]))
          && !FENCE.test(lines[index]) && !ATX.test(lines[index])) {
          body.push(lines[index].slice(Math.min(indent, lines[index].length - lines[index].trimStart().length)));
          index += 1;
        }
        items.push(body);
      }
      if (budget.spend()) {
        const children = [];
        for (const body of items) {
          if (!budget.spend()) break;
          const content = depth < budget.limits.maxDepth
            ? parseBlocks(body, budget, depth + 1)
            : [];
          // A single-paragraph item reads better unwrapped, and matches how
          // reports are written.
          const unwrapped = content.length === 1 && content[0].tag === "p" ? content[0].children : content;
          children.push(elementNode("li", unwrapped));
        }
        push(elementNode(isOrdered ? "ol" : "ul", children));
      }
      continue;
    }

    if (line.includes("|") && index + 1 < lines.length && TABLE_DELIMITER.test(lines[index + 1])) {
      const header = splitRow(line);
      index += 2;
      const rows = [];
      while (index < lines.length && lines[index].includes("|") && lines[index].trim()) {
        rows.push(splitRow(lines[index]));
        index += 1;
      }
      // Every row and every cell is a node, so each one is metered. A document
      // that is nothing but pipe characters would otherwise emit a cell per
      // source column and walk straight past the node cap.
      if (budget.spend() && budget.spend() && budget.spend() && budget.spend()) {
        const headCells = [];
        for (const cell of header) {
          if (!budget.spend()) break;
          headCells.push(elementNode("th", parseInline(cell, budget, 0)));
        }
        const bodyRows = [];
        for (const row of rows) {
          if (!budget.spend()) break;
          const cells = [];
          for (const cell of row.slice(0, header.length)) {
            if (!budget.spend()) break;
            cells.push(elementNode("td", parseInline(cell, budget, 0)));
          }
          bodyRows.push(elementNode("tr", cells));
        }
        push(elementNode("table", [
          elementNode("thead", [elementNode("tr", headCells)]),
          elementNode("tbody", bodyRows),
        ]));
      }
      continue;
    }

    if (/^ {4,}\S/.test(line)) {
      const body = [];
      while (index < lines.length && (/^ {4,}/.test(lines[index]) || !lines[index].trim())) {
        if (!lines[index].trim() && !(index + 1 < lines.length && /^ {4,}\S/.test(lines[index + 1]))) break;
        body.push(lines[index].slice(4));
        index += 1;
      }
      if (budget.spend() && budget.spend() && budget.spend()) {
        push(elementNode("pre", [elementNode("code", [textNode(body.join("\n"))])], { className: "md-code-block" }));
      }
      continue;
    }

    const paragraph = [];
    while (index < lines.length && lines[index].trim()
      && !FENCE.test(lines[index]) && !ATX.test(lines[index]) && !RULE.test(lines[index])
      && !BLOCKQUOTE.test(lines[index]) && !BULLET.test(lines[index]) && !ORDERED.test(lines[index])) {
      paragraph.push(lines[index].trim());
      index += 1;
    }
    if (!paragraph.length) { index += 1; continue; }
    if (budget.spend()) push(elementNode("p", parseInline(paragraph.join("\n"), budget, 0)));
  }
  return out;
}

/**
 * Parse Markdown into the node tree app.js builds with createElement.
 * Returns { nodes, notices, truncated }. Every refusal and every truncation is
 * reported in `notices` so the view can say what it removed.
 */
export function renderMarkdown(source, options = {}) {
  const limits = { ...MARKDOWN_LIMITS, ...options };
  const budget = new Budget(limits);
  let text = typeof source === "string" ? source : "";
  if (text.length > limits.maxChars) {
    text = text.slice(0, limits.maxChars);
    budget.truncated.chars = true;
  }
  // Normalize line endings and strip the control characters that have no place
  // in a rendered document; a lone \r would otherwise split a block oddly.
  text = text.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "");
  let lines = text.split("\n");
  if (lines.length > limits.maxLines) {
    lines = lines.slice(0, limits.maxLines);
    budget.truncated.lines = true;
  }
  const nodes = parseBlocks(lines, budget, 0);
  if (budget.truncated.chars) budget.note("source_truncated", null);
  if (budget.truncated.lines) budget.note("lines_truncated", null);
  if (budget.truncated.nodes) budget.note("nodes_truncated", null);
  return { nodes, notices: [...budget.notices.values()], truncated: budget.truncated };
}

const NOTICE_TEXT = {
  blocked_link: "link removed because its protocol is not allowed",
  blocked_image: "image removed because its address is not an allowed http or https URL",
  source_truncated: "the report was longer than this view renders and was cut short",
  lines_truncated: "the report had more lines than this view renders",
  nodes_truncated: "the report was too large to render in full",
  inline_truncated: "one very long paragraph was cut short",
};

/** One human sentence for a notice, for the view to show above the report. */
export function noticeSentence(notice) {
  const base = NOTICE_TEXT[notice.kind] || "part of the report was not rendered";
  const scope = notice.count > 1 ? `${notice.count} times: ` : "";
  const samples = notice.samples.length ? ` (${notice.samples.join(", ")})` : "";
  return `${scope}${base}${samples}`;
}
