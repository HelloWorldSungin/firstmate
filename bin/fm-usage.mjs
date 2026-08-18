#!/usr/bin/env node
// fm-usage.mjs - the fleet's token-usage store, harness collectors, and rollups.
//
// Usage:
//   fm-usage.mjs ingest [--home <dir>] [--claude-root <dir>] [--codex-root <dir>]
//   fm-usage.mjs report --by task|project|harness|model|day [--limit <n>] [--since <iso>]
//   fm-usage.mjs burn [--bucket hour|day] [--buckets <n>]
//   fm-usage.mjs attribution
//   fm-usage.mjs sessions [--task <id>]
//   fm-usage.mjs migrate
//
// Every subcommand prints one JSON object on stdout. Only `ingest` and
// `migrate` write; the rest are read-only queries.
//
// WHAT THIS OWNS
//
//   data/usage.db                 the versioned SQLite store (schema below)
//   state/<id>.usage-sessions     schema fm-usage-sessions.v1 - the live
//                                 session-to-task map for one task, published
//                                 while the task is live so that
//                                 bin/fm-outcome-manifest.sh can carry it into
//                                 data/<id>/outcome.json BEFORE teardown removes
//                                 state/<id>.meta. Usage that loses its task at
//                                 cleanup is worthless, so this handoff is the
//                                 point of the whole attribution chain.
//
// docs/usage-accounting.md owns the stored contract, the attribution ladder, and
// the cost-estimate posture. docs/fleet-data-contracts.md owns the manifest
// field that carries attribution past teardown.
//
// NO TRANSCRIPT CONTENT. The collectors read only enumerated identity, model,
// timestamp, working-directory, and numeric token fields out of each source
// line. Prompts, responses, tool arguments, tool results, reasoning text, and
// credential-bearing values are never extracted, so they can never be stored.
//
// IDEMPOTENCE. Every event carries a stable identity derived from its source
// content, and ingestion inserts with that identity as the primary key. Repeated
// scans, restarts, transcript rotation, a wiped store rebuilt from the same
// sources, and two overlapping collector windows all converge on the same rows.
//
// Node 22 or newer is required for the built-in node:sqlite module, the same
// runtime floor the dashboard already carries.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

// The store discipline - opening, migrating, sanitizing, and normalizing - is
// shared with the fleet's other telemetry store rather than re-decided here.
// fm-telemetry-store.mjs's header owns why the two stores are separate files and
// what they hold in common.
import {
  cleanToken,
  closeStoreOnSignals,
  count,
  digest,
  isoToEpoch,
  ISO_RE,
  normalizeIso,
  openStore as openTelemetryStore,
  readJsonFile,
  writeJsonFile,
} from "./fm-telemetry-store.mjs";

const COLLECTOR_VERSION = "fm-usage.1";
const SESSIONS_SCHEMA = "fm-usage-sessions.v1";
const RATES_SCHEMA = "fm-usage-rates.v1";
// The manifest carries at most this many sessions per task, so a long-running
// task with many resumed sessions cannot grow an unbounded durable record.
const MAX_TASK_SESSIONS = 64;
const MAX_BURN_BUCKETS = 168;
const SUPERVISION_PROJECT = "(firstmate supervision)";

const USAGE = `usage: fm-usage.mjs ingest [--home <dir>] [--db <path>]
                          [--claude-root <dir>] [--codex-root <dir>]
                          [--rates <path>] [--no-sessions]
       fm-usage.mjs report --by task|project|harness|model|day
                          [--limit <n>] [--since <iso>]
       fm-usage.mjs burn [--bucket hour|day] [--buckets <n>]
       fm-usage.mjs attribution
       fm-usage.mjs sessions [--task <id>]
       fm-usage.mjs migrate

ingest scans the Claude Code and Codex session records on this machine, stores
every token-usage event under a stable identity, attributes each event to the
task that produced it, and publishes the per-task session map the outcome
manifest carries past teardown. It never reads prompts, responses, or tool
arguments.

The other subcommands are read-only projections of the store and print JSON.

Environment:
  FM_HOME                  operational home (default: the tracked code root)
  FM_USAGE_DB              store path (default: <home>/data/usage.db)
  FM_USAGE_CLAUDE_ROOT     Claude transcript root (default: ~/.claude/projects,
                           honoring CLAUDE_CONFIG_DIR)
  FM_USAGE_CODEX_ROOT      Codex rollout root (default: ~/.codex/sessions,
                           honoring CODEX_HOME)
  FM_USAGE_RATES           cost-rate file (default: <home>/config/usage-rates.json)
  FM_USAGE_NOW             ISO-8601 UTC stamp used instead of the wall clock
`;

// ---------------------------------------------------------------------------
// Project registry and path-based attribution
// ---------------------------------------------------------------------------
//
// A session may run in a task worktree that is no longer held by a live task
// and was never bound durably. When the working directory is still a git
// checkout whose origin matches a registered project, the event can be
// credited to that project without inventing a task identity. The project
// registry is the captain's data/projects.md; the match is against the
// checkout's actual remote URL, not against path-shaped strings, so a
// directory that merely looks like a project cannot create a phantom row.

function normalizeTrackerUrl(value) {
  const text = cleanToken(value, 240);
  if (!text) return null;
  const colon = text.indexOf(":");
  if (colon <= 0) return null;
  return text.slice(colon + 1);
}

function loadProjectRegistry(home) {
  const file = path.join(home, "data", "projects.md");
  const byUrl = new Map();
  const names = new Set();
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return { byUrl, names };
  }
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line.startsWith("- ")) continue;
    const nameMatch = /^- (\S+)/.exec(line);
    if (!nameMatch) continue;
    const name = cleanToken(nameMatch[1], 120);
    if (!name) continue;
    names.add(name);
    const trackerIndex = line.indexOf("tracker=");
    if (trackerIndex < 0) continue;
    let tracker = line.slice(trackerIndex + 8);
    const endIndex = tracker.search(/[\s\]]/);
    if (endIndex >= 0) tracker = tracker.slice(0, endIndex);
    const normalized = normalizeTrackerUrl(tracker);
    if (!normalized || normalized === "none") continue;
    byUrl.set(normalized, name);
  }
  return { byUrl, names };
}

function findGitRoot(cwd) {
  let current = path.resolve(cwd);
  while (true) {
    const gitPath = path.join(current, ".git");
    try {
      const info = fs.statSync(gitPath);
      if (info.isDirectory() || info.isFile()) return current;
    } catch {}
    const parent = path.dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

function readGitConfig(gitRoot) {
  let configPath = path.join(gitRoot, ".git", "config");
  try {
    const gitDot = fs.readFileSync(path.join(gitRoot, ".git"), "utf8").trim();
    const match = /^gitdir:\s*(.+)$/m.exec(gitDot);
    if (match) configPath = path.resolve(gitRoot, match[1].trim(), "config");
  } catch {
    // .git is a directory; configPath is already correct.
  }
  try {
    return fs.readFileSync(configPath, "utf8");
  } catch {
    return null;
  }
}

function parseGitRemote(configText, remoteName = "origin") {
  const lines = configText.split("\n");
  let inSection = false;
  for (const raw of lines) {
    const line = raw.trim();
    const section = /^\[remote "([^"]+)"\]\s*$/.exec(line);
    if (section) {
      inSection = section[1] === remoteName;
      continue;
    }
    if (inSection) {
      const url = /^url\s*=\s*(.+?)\s*$/.exec(line);
      if (url) return url[1].trim();
    }
  }
  return null;
}

function normalizeGitUrl(url) {
  if (!url) return null;
  let text = url.trim().replace(/\.git$/, "");
  if (text.startsWith("https://") || text.startsWith("http://")) {
    const withoutScheme = text.slice(text.indexOf("://") + 3);
    const slash = withoutScheme.indexOf("/");
    if (slash < 0) return null;
    const host = withoutScheme.slice(0, slash).replace(/:\d+$/, "");
    return `${host}${withoutScheme.slice(slash)}`;
  }
  if (text.startsWith("git@")) {
    const rest = text.slice(4);
    const colon = rest.indexOf(":");
    if (colon < 0) return null;
    const host = rest.slice(0, colon).replace(/:\d+$/, "");
    return `${host}/${rest.slice(colon + 1)}`;
  }
  if (text.startsWith("ssh://")) {
    let rest = text.slice(6);
    if (rest.startsWith("git@")) rest = rest.slice(4);
    const slash = rest.indexOf("/");
    if (slash < 0) return null;
    const host = rest.slice(0, slash).replace(/:\d+$/, "");
    return `${host}${rest.slice(slash)}`;
  }
  return null;
}

function resolveProjectAt(registry, homeRoot, cwd, { allowSupervision = false } = {}) {
  if (!cwd) return null;
  const gitRoot = findGitRoot(cwd);
  if (!gitRoot) return null;
  const config = readGitConfig(gitRoot);
  if (!config) return null;
  const remote = parseGitRemote(config, "origin");
  const normalized = normalizeGitUrl(remote);
  if (!normalized || !registry.byUrl.has(normalized)) return null;
  const project = registry.byUrl.get(normalized);
  if (allowSupervision && path.resolve(cwd) === homeRoot) {
    return { project: SUPERVISION_PROJECT, method: "firstmate_supervision", confidence: "low" };
  }
  return { project, method: "project_path", confidence: "low" };
}

function candidateProjectFromClonePath(homeRoot, cwd) {
  const resolved = path.resolve(cwd);
  if (resolved === homeRoot) return "firstmate";
  const projectsPrefix = path.join(homeRoot, "projects") + path.sep;
  if (resolved.startsWith(projectsPrefix)) {
    const relative = resolved.slice(projectsPrefix.length);
    const name = relative.split(path.sep)[0];
    return name || null;
  }
  // Treehouse pool copies follow .treehouse/<name>-<hash>/<n>/<name>[/<subpath>].
  const treehouseMatch = /\/\.treehouse\/[^/]+-\w+\/\d+\/([^/]+)/.exec(resolved);
  if (treehouseMatch) return treehouseMatch[1];
  return null;
}

function buildPathResolver(home, registry) {
  const cache = new Map();
  const homeRoot = path.resolve(home);
  return {
    // For events with no task identity: resolve the directory to a project
    // name, or to the supervision category when the directory IS the firstmate
    // home and no task claims the session.
    fromPath(cwd) {
      if (!cwd) return null;
      const key = `path:${cwd}`;
      if (cache.has(key)) return cache.get(key);
      const result = resolveProjectAt(registry, homeRoot, cwd, { allowSupervision: true });
      cache.set(key, result);
      return result;
    },
    // For events already attributed to a task: normalize the worktree path to
    // the registered project name. The supervision category never applies here
    // because a task binding is the distinguishing signal. Git remote is tried
    // first; when a clone uses an SSH alias that does not match the registry's
    // canonical host, the directory name under projects/ or the treehouse pool
    // is accepted only if it names a real registered project.
    fromWorktree(worktree) {
      if (!worktree) return null;
      const key = `worktree:${worktree}`;
      if (cache.has(key)) return cache.get(key);
      let project = null;
      const remote = resolveProjectAt(registry, homeRoot, worktree, { allowSupervision: false });
      if (remote) {
        project = remote.project;
      } else {
        const candidate = candidateProjectFromClonePath(homeRoot, worktree);
        if (candidate && registry.names.has(candidate)) project = candidate;
      }
      cache.set(key, project);
      return project;
    },
  };
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function nowIso() {
  const pinned = process.env.FM_USAGE_NOW;
  if (pinned && ISO_RE.test(pinned)) return normalizeIso(pinned);
  return normalizeIso(new Date().toISOString());
}

function die(message, code = 1) {
  console.error(`fm-usage: ${message}`);
  process.exit(code);
}

// ---------------------------------------------------------------------------
// Store: versioned schema and migrations
// ---------------------------------------------------------------------------
//
// Every migration is append-only and runs inside one transaction against
// PRAGMA user_version, so an older store upgrades in place and a newer store is
// refused rather than silently downgraded.
//
// Raw columns hold exactly what a source reported. Derived columns - the token
// total, the attribution decision, and the cost estimate - are recomputed from
// raw columns and can be rebuilt at any time without re-reading a transcript.

const MIGRATIONS = [
  {
    version: 1,
    statements: [
      `CREATE TABLE usage_event (
         event_id           TEXT PRIMARY KEY,
         harness            TEXT NOT NULL,
         source_kind        TEXT NOT NULL,
         source_path        TEXT NOT NULL,
         source_ordinal     INTEGER NOT NULL,
         session_id         TEXT NOT NULL,
         occurred_at        TEXT NOT NULL,
         occurred_epoch     INTEGER NOT NULL,
         model              TEXT,
         cwd                TEXT,
         input_tokens       INTEGER NOT NULL DEFAULT 0,
         output_tokens      INTEGER NOT NULL DEFAULT 0,
         cache_read_tokens  INTEGER NOT NULL DEFAULT 0,
         cache_write_tokens INTEGER NOT NULL DEFAULT 0,
         reasoning_tokens   INTEGER NOT NULL DEFAULT 0,
         total_tokens       INTEGER NOT NULL DEFAULT 0,
         task_id            TEXT,
         project            TEXT,
         attribution_method TEXT NOT NULL DEFAULT 'unknown',
         attribution_confidence TEXT NOT NULL DEFAULT 'none',
         ingested_at        TEXT NOT NULL,
         collector_version  TEXT NOT NULL
       )`,
      `CREATE INDEX usage_event_session ON usage_event (harness, session_id)`,
      `CREATE INDEX usage_event_task ON usage_event (task_id)`,
      `CREATE INDEX usage_event_time ON usage_event (occurred_epoch)`,
      `CREATE TABLE usage_session (
         harness       TEXT NOT NULL,
         session_id    TEXT NOT NULL,
         source_kind   TEXT NOT NULL,
         cwd           TEXT,
         first_seen    TEXT NOT NULL,
         last_seen     TEXT NOT NULL,
         event_count   INTEGER NOT NULL DEFAULT 0,
         PRIMARY KEY (harness, session_id)
       )`,
      // The durable session-to-task map. A binding recorded while the task was
      // live outlives the task's runtime records, which is what makes usage
      // survive teardown.
      `CREATE TABLE usage_binding (
         harness     TEXT NOT NULL,
         session_id  TEXT NOT NULL,
         task_id     TEXT NOT NULL,
         project     TEXT,
         worktree    TEXT,
         source      TEXT NOT NULL,
         recorded_at TEXT NOT NULL,
         PRIMARY KEY (harness, session_id)
       )`,
      // Task facts an attribution or rollup read still needs once state/<id>.meta
      // is gone. Sourced from live metadata first and from the durable outcome
      // manifest afterwards.
      `CREATE TABLE usage_task (
         task_id      TEXT PRIMARY KEY,
         project      TEXT,
         kind         TEXT,
         harness      TEXT,
         model        TEXT,
         effort       TEXT,
         worktree     TEXT,
         started_at   TEXT,
         completed_at TEXT,
         outcome      TEXT,
         source       TEXT NOT NULL,
         updated_at   TEXT NOT NULL
       )`,
      `CREATE TABLE usage_source (
         source_path       TEXT PRIMARY KEY,
         source_kind       TEXT NOT NULL,
         size_bytes        INTEGER NOT NULL,
         mtime_ms       INTEGER NOT NULL,
         head_digest       TEXT NOT NULL,
         events_seen       INTEGER NOT NULL DEFAULT 0,
         malformed_lines   INTEGER NOT NULL DEFAULT 0,
         last_scanned_at   TEXT NOT NULL
       )`,
      // Cost is an optional, versioned estimate that is absent by default. A
      // subscription seat is not API dollars, so an unpriced event keeps its
      // tokens and simply has no row here.
      `CREATE TABLE usage_cost_estimate (
         event_id      TEXT PRIMARY KEY REFERENCES usage_event(event_id) ON DELETE CASCADE,
         rate_version  TEXT NOT NULL,
         currency      TEXT NOT NULL,
         estimated_cost REAL NOT NULL,
         computed_at   TEXT NOT NULL
       )`,
    ],
  },
];

const SCHEMA_VERSION = MIGRATIONS[MIGRATIONS.length - 1].version;

// One opener for both fleet telemetry stores. fm-telemetry-store.mjs owns the
// busy timeout, the WAL switch, the transactional PRAGMA user_version
// migration, and the private file mode; this collector only names the schema
// its own store carries.
function openStore(dbPath, options) {
  return openTelemetryStore(dbPath, MIGRATIONS, options);
}

// ---------------------------------------------------------------------------
// Source scanning
// ---------------------------------------------------------------------------

function listFiles(root, depth = 4) {
  const found = [];
  const walk = (dir, level) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (level < depth) walk(full, level + 1);
      } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        found.push(full);
      }
    }
  };
  walk(root, 0);
  return found.sort();
}

// A source is re-read whenever its size, mtime, or first bytes changed since the
// last scan. Rotation and truncation both change one of those, and a full
// re-parse is safe because event identity - not file position - is what keeps
// ingestion idempotent.
function sourceChanged(db, file, kind) {
  let stat;
  try {
    stat = fs.statSync(file);
  } catch {
    return null;
  }
  let head = "";
  try {
    const fd = fs.openSync(file, "r");
    const buffer = Buffer.alloc(Math.min(4096, stat.size));
    fs.readSync(fd, buffer, 0, buffer.length, 0);
    fs.closeSync(fd);
    head = digest(buffer);
  } catch {
    return null;
  }
  const previous = db
    .prepare("SELECT size_bytes, mtime_ms, head_digest FROM usage_source WHERE source_path = ?")
    .get(file);
  const mtime = Math.floor(stat.mtimeMs);
  const unchanged =
    previous &&
    previous.size_bytes === stat.size &&
    previous.mtime_ms === mtime &&
    previous.head_digest === head;
  return { kind, size: stat.size, mtime, head, unchanged: Boolean(unchanged) };
}

async function eachLine(file, handler) {
  const stream = fs.createReadStream(file, { encoding: "utf8" });
  const lines = readline.createInterface({ input: stream, crlfDelay: Infinity });
  let ordinal = 0;
  try {
    for await (const line of lines) {
      ordinal += 1;
      if (!line.trim()) continue;
      let parsed;
      try {
        parsed = JSON.parse(line);
      } catch {
        handler(null, ordinal);
        continue;
      }
      handler(parsed, ordinal);
    }
  } finally {
    lines.close();
    stream.destroy();
  }
}

// ---------------------------------------------------------------------------
// Adapters
// ---------------------------------------------------------------------------
//
// An adapter turns one source line into zero or one usage event. Both adapters
// below return the same event shape, which is the interface an OpenCode or Pi
// adapter implements later without touching the store, the attribution ladder,
// or the rollups. An adapter returns SKIPPED - not null - for a line that did
// carry a usage payload it could not use, so a harness that renames a field
// cannot look like a harness that simply produced no usage.

const SKIPPED = Symbol("skipped");

// Harnesses disagree about whether a cached-input count is a SUBSET of the input
// count or a bucket beside it, and reading the same column two ways is how a
// by-harness or by-model rollup stops being comparable. The store therefore has
// one convention - input_tokens, cache_read_tokens, and cache_write_tokens are
// mutually exclusive, and total_tokens is their sum plus output - and every
// adapter names the convention its own source uses. A later OpenCode or Pi
// adapter has to make that choice explicitly rather than inherit whichever one
// happened to be assumed here.
const TOKEN_CONVENTIONS = {
  // input, cache read, and cache write are already disjoint buckets. Claude Code
  // reports this: a real transcript shows input_tokens: 2 beside
  // cache_read_input_tokens: 17684 for one response.
  disjoint: (raw) => raw.input,
  // the cached part of the input is reported INSIDE the input count, so the
  // harness's own total is input + output. Codex reports this: a real rollout
  // shows total_token_usage {input 21418, cached_input 11008, output 284,
  // total 21702}. The cached part is removed from input here so it is counted
  // exactly once, and the stored total matches what Codex itself reports.
  cached_input_within_input: (raw) => raw.input - raw.cacheRead,
};

function normalizeTokens(convention, raw) {
  const resolveInput = TOKEN_CONVENTIONS[convention];
  if (!resolveInput) throw new Error(`unknown token convention: ${convention}`);
  const input = count(raw.input);
  const output = count(raw.output);
  const cacheRead = count(raw.cacheRead);
  const cacheWrite = count(raw.cacheWrite);
  const uncachedInput = Math.max(0, resolveInput({ input, output, cacheRead, cacheWrite }));
  return {
    input_tokens: uncachedInput,
    output_tokens: output,
    cache_read_tokens: cacheRead,
    cache_write_tokens: cacheWrite,
    // Reasoning tokens are a subset of the output count in both harnesses, so
    // they are kept as a memo column and never enter the total.
    reasoning_tokens: count(raw.reasoning),
    total_tokens: uncachedInput + output + cacheRead + cacheWrite,
  };
}

// Claude Code writes one JSONL transcript per session under
// <root>/<slugified-cwd>/<session>.jsonl. Assistant lines carry message.usage.
//
// The same API response is written to the transcript more than once - once per
// streamed update, and again in a resumed or compacted transcript - each time
// with a fresh line uuid and the SAME usage numbers. Summing lines would
// multiply a turn's cost several times over, so the API message id is the event
// identity and the first write wins.
function claudeEvent(line, file, ordinal) {
  if (!line || line.type !== "assistant" || !line.message) return null;
  const usage = line.message.usage;
  if (!usage || typeof usage !== "object") return null;
  const occurred = normalizeIso(line.timestamp);
  if (!occurred) return SKIPPED;
  const native =
    cleanToken(line.message.id) || cleanToken(line.requestId) || cleanToken(line.uuid);
  if (!native) return SKIPPED;
  const session = cleanToken(line.sessionId) || cleanToken(line.session_id) || "unknown";
  // Claude reports input, cache read, and cache creation as disjoint buckets.
  const tokens = normalizeTokens("disjoint", {
    input: usage.input_tokens,
    output: usage.output_tokens,
    cacheRead: usage.cache_read_input_tokens,
    cacheWrite: usage.cache_creation_input_tokens,
    reasoning: 0,
  });
  // A usage payload this adapter can read no tokens out of is a field change,
  // not an empty response: it is reported rather than dropped silently.
  if (tokens.total_tokens === 0) return SKIPPED;
  return {
    event_id: `claude:${native}`,
    harness: "claude",
    source_kind: "claude-jsonl",
    source_path: file,
    source_ordinal: ordinal,
    session_id: session,
    occurred_at: occurred,
    model: cleanToken(line.message.model),
    cwd: cleanToken(line.cwd, 480),
    ...tokens,
  };
}

// Codex writes one rollout JSONL per session under <root>/<yyyy>/<mm>/<dd>/.
// Its token_count events report cumulative totals for the session plus the last
// turn's usage, so this adapter stores the monotonic growth of the cumulative
// counter rather than trusting a per-turn field that repeats when only rate
// limits refresh. A counter that moves backwards means the stream restarted, so
// the reported last-turn usage is taken instead.
//
// Identity is the rollout file's own name plus the event's ordinal within it: a
// re-read reproduces it exactly, a resumed session writes a separate rollout,
// and a copied file dedupes against the original rather than doubling it.
function codexEvent(line, file, ordinal, stream) {
  if (!line || line.type !== "event_msg" || !line.payload) return null;
  if (line.payload.type !== "token_count") return null;
  const info = line.payload.info;
  if (!info || typeof info !== "object") return SKIPPED;
  const occurred = normalizeIso(line.timestamp);
  if (!occurred) return SKIPPED;

  const total = info.total_token_usage || {};
  const last = info.last_token_usage || {};
  const cumulative = {
    input: count(total.input_tokens),
    output: count(total.output_tokens),
    cacheRead: count(total.cached_input_tokens),
    cacheWrite: count(total.cache_write_input_tokens),
    reasoning: count(total.reasoning_output_tokens),
  };
  const previous = stream.cumulative;
  let delta;
  if (
    cumulative.input >= previous.input &&
    cumulative.output >= previous.output &&
    cumulative.cacheRead >= previous.cacheRead &&
    cumulative.cacheWrite >= previous.cacheWrite &&
    cumulative.reasoning >= previous.reasoning
  ) {
    delta = {
      input: cumulative.input - previous.input,
      output: cumulative.output - previous.output,
      cacheRead: cumulative.cacheRead - previous.cacheRead,
      cacheWrite: cumulative.cacheWrite - previous.cacheWrite,
      reasoning: cumulative.reasoning - previous.reasoning,
    };
    stream.cumulative = cumulative;
  } else {
    delta = {
      input: count(last.input_tokens),
      output: count(last.output_tokens),
      cacheRead: count(last.cached_input_tokens),
      cacheWrite: count(last.cache_write_input_tokens),
      reasoning: count(last.reasoning_output_tokens),
    };
    stream.cumulative = cumulative;
  }
  // Codex counts its cached input inside its input count, so the growth is
  // converted to the store's disjoint columns here.
  const tokens = normalizeTokens("cached_input_within_input", delta);
  // A turn that added no tokens is the ordinary rate-limit-only refresh, not a
  // field this adapter failed to read.
  if (tokens.total_tokens === 0) return null;

  stream.tokenEvents += 1;
  const stem = path.basename(file).replace(/\.jsonl$/, "");
  return {
    event_id: `codex:${stem}:${stream.tokenEvents}`,
    harness: "codex",
    source_kind: "codex-rollout",
    source_path: file,
    source_ordinal: ordinal,
    session_id: stream.sessionId || "unknown",
    occurred_at: occurred,
    model: stream.model,
    cwd: stream.cwd,
    ...tokens,
  };
}

// Session identity, working directory, and model come from the rollout's own
// header and turn-context lines. Nothing else in those lines is read.
function codexStreamUpdate(line, stream) {
  if (!line || !line.payload) return;
  if (line.type === "session_meta") {
    stream.sessionId = cleanToken(line.payload.session_id) || stream.sessionId;
    stream.cwd = cleanToken(line.payload.cwd, 480) || stream.cwd;
  } else if (line.type === "turn_context") {
    stream.cwd = cleanToken(line.payload.cwd, 480) || stream.cwd;
    stream.model = cleanToken(line.payload.model) || stream.model;
  }
}

// ---------------------------------------------------------------------------
// Ingestion
// ---------------------------------------------------------------------------

async function collect(db, roots, stamp) {
  const summary = {
    files_scanned: 0,
    files_skipped_unchanged: 0,
    files_unreadable: 0,
    events_new: 0,
    events_duplicate: 0,
    // A line that carried a usage payload an adapter could not use: an
    // unparseable timestamp, no usable identity, or no readable counter. It is
    // counted so a harness that changes one of those fields cannot report
    // events_new: 0 with malformed_lines: 0 and look healthy while collecting
    // nothing.
    events_skipped: 0,
    malformed_lines: 0,
  };
  const insert = db.prepare(`INSERT OR IGNORE INTO usage_event (
      event_id, harness, source_kind, source_path, source_ordinal, session_id,
      occurred_at, occurred_epoch, model, cwd, input_tokens, output_tokens,
      cache_read_tokens, cache_write_tokens, reasoning_tokens, total_tokens,
      ingested_at, collector_version)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  const rememberSource = db.prepare(`INSERT INTO usage_source
      (source_path, source_kind, size_bytes, mtime_ms, head_digest,
       events_seen, malformed_lines, last_scanned_at)
    VALUES (?,?,?,?,?,?,?,?)
    ON CONFLICT(source_path) DO UPDATE SET
      size_bytes = excluded.size_bytes, mtime_ms = excluded.mtime_ms,
      head_digest = excluded.head_digest, events_seen = excluded.events_seen,
      malformed_lines = excluded.malformed_lines,
      last_scanned_at = excluded.last_scanned_at`);

  const files = [
    ...listFiles(roots.claude, 2).map((file) => ({ file, kind: "claude-jsonl" })),
    ...listFiles(roots.codex, 5).map((file) => ({ file, kind: "codex-rollout" })),
  ];

  for (const { file, kind } of files) {
    const state = sourceChanged(db, file, kind);
    if (!state) {
      summary.files_unreadable += 1;
      continue;
    }
    if (state.unchanged) {
      summary.files_skipped_unchanged += 1;
      continue;
    }
    const stream = {
      sessionId: null,
      cwd: null,
      model: null,
      tokenEvents: 0,
      cumulative: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0 },
    };
    const events = [];
    let malformed = 0;
    let skipped = 0;
    try {
      await eachLine(file, (line, ordinal) => {
        if (line === null) {
          malformed += 1;
          return;
        }
        let event = null;
        if (kind === "claude-jsonl") {
          event = claudeEvent(line, file, ordinal);
        } else {
          codexStreamUpdate(line, stream);
          event = codexEvent(line, file, ordinal, stream);
        }
        if (event === SKIPPED) skipped += 1;
        else if (event) events.push(event);
      });
    } catch {
      // An unreadable or vanishing source is a fact about that source, never a
      // reason to abandon the scan or to lose totals already stored.
      summary.files_unreadable += 1;
      continue;
    }
    summary.files_scanned += 1;
    summary.malformed_lines += malformed;
    summary.events_skipped += skipped;

    db.exec("BEGIN");
    try {
      for (const event of events) {
        const result = insert.run(
          event.event_id,
          event.harness,
          event.source_kind,
          event.source_path,
          event.source_ordinal,
          event.session_id,
          event.occurred_at,
          isoToEpoch(event.occurred_at),
          event.model,
          event.cwd,
          event.input_tokens,
          event.output_tokens,
          event.cache_read_tokens,
          event.cache_write_tokens,
          event.reasoning_tokens,
          // The adapter owns the total, because only the adapter knows whether
          // its harness reported those columns as disjoint or nested.
          event.total_tokens,
          stamp,
          COLLECTOR_VERSION,
        );
        if (result.changes > 0) summary.events_new += 1;
        else summary.events_duplicate += 1;
      }
      rememberSource.run(file, kind, state.size, state.mtime, state.head, events.length, malformed, stamp);
      db.exec("COMMIT");
    } catch {
      db.exec("ROLLBACK");
      summary.files_unreadable += 1;
    }
  }

  rebuildSessions(db);
  return summary;
}

// A derived table is rebuilt in place, so its wipe and its repopulation commit
// together: a failure between them would leave an empty usage_session, which is
// the only thing bindLiveSessions reads, and that run would bind nothing and
// publish no session map while the store still reported success.
function rebuildSessions(db) {
  db.exec("BEGIN");
  try {
    db.exec(`DELETE FROM usage_session`);
    db.exec(`INSERT INTO usage_session
        (harness, session_id, source_kind, cwd, first_seen, last_seen, event_count)
      SELECT harness, session_id, MIN(source_kind), MAX(cwd),
             MIN(occurred_at), MAX(occurred_at), COUNT(*)
      FROM usage_event GROUP BY harness, session_id`);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Task facts: live metadata now, durable manifest afterwards
// ---------------------------------------------------------------------------

function metaValue(text, key) {
  let found = null;
  for (const line of text.split("\n")) {
    if (line.startsWith(`${key}=`)) found = line.slice(key.length + 1);
  }
  return cleanToken(found, 480);
}

function syncTasks(db, dirs, stamp) {
  const upsert = db.prepare(`INSERT INTO usage_task
      (task_id, project, kind, harness, model, effort, worktree, started_at,
       completed_at, outcome, source, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(task_id) DO UPDATE SET
      -- A source that does not report a fact does not erase it: the live
      -- metadata and the durable manifest each know things the other may not.
      -- This merge describes ONE occupancy of a task id; see restartOccupancy.
      project = COALESCE(excluded.project, usage_task.project),
      kind = COALESCE(excluded.kind, usage_task.kind),
      harness = COALESCE(excluded.harness, usage_task.harness),
      model = COALESCE(excluded.model, usage_task.model),
      effort = COALESCE(excluded.effort, usage_task.effort),
      worktree = COALESCE(excluded.worktree, usage_task.worktree),
      -- Task metadata is appended to after dispatch, so its mtime drifts later
      -- than the moment the worker started. The earliest stamp ever observed is
      -- kept so a later rewrite cannot orphan the task's own early usage.
      started_at = MIN(COALESCE(excluded.started_at, usage_task.started_at),
                       COALESCE(usage_task.started_at, excluded.started_at)),
      completed_at = COALESCE(excluded.completed_at, usage_task.completed_at),
      outcome = COALESCE(excluded.outcome, usage_task.outcome),
      source = excluded.source,
      updated_at = excluded.updated_at`);
  const bind = db.prepare(`INSERT INTO usage_binding
      (harness, session_id, task_id, project, worktree, source, recorded_at)
    VALUES (?,?,?,?,?,?,?)
    ON CONFLICT(harness, session_id) DO UPDATE SET
      task_id = excluded.task_id, project = excluded.project,
      worktree = excluded.worktree, source = excluded.source,
      recorded_at = excluded.recorded_at`);
  // A task id is an operator-supplied slug, and data/<id>/ outlives teardown, so
  // the same slug can be dispatched again long after an earlier task of that
  // name finished. A row describes ONE occupancy: observing an id live again
  // while its row describes a finished occupancy starts the row over, because
  // merging two lifetimes would hand the new task the old one's closed window
  // and orphan every token it goes on to spend. Within one occupancy the merge
  // above still holds, which is what keeps the anti-drift MIN on started_at.
  const restartOccupancy = db.prepare(`UPDATE usage_task
      SET project = NULL, kind = NULL, harness = NULL, model = NULL, effort = NULL,
          worktree = NULL, started_at = NULL, completed_at = NULL, outcome = NULL
    WHERE task_id = ? AND source <> 'meta'`);

  const counts = { live: 0, archived: 0, live_records_gone: 0, bindings_from_manifest: 0 };
  const state = dirs.state;
  const data = dirs.data;

  // Live tasks first: state/<id>.meta is the only structured record while a task
  // is running, and its mtime is when the worker started. Liveness is a fact
  // about THIS run - the ids seen below - and never a column left behind by an
  // earlier one, because a worktree the pool has already recycled must not stay
  // claimed by the task that used to hold it.
  const liveIds = new Set();
  let entries = [];
  let stateReadable = true;
  try {
    entries = fs.readdirSync(state, { withFileTypes: true });
  } catch {
    entries = [];
    stateReadable = false;
  }
  // Restarting a row and re-describing it are one change, so they commit
  // together: a failure between them would leave a task with no worktree and no
  // window, matching nothing until a later run repaired it.
  db.exec("BEGIN");
  try {
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".meta")) continue;
      const id = entry.name.slice(0, -".meta".length);
      const file = path.join(state, entry.name);
      let text;
      let started = null;
      try {
        text = fs.readFileSync(file, "utf8");
        started = normalizeIso(new Date(fs.statSync(file).mtimeMs).toISOString());
      } catch {
        continue;
      }
      restartOccupancy.run(id);
      upsert.run(
        id,
        metaValue(text, "project"),
        metaValue(text, "kind") || "ship",
        metaValue(text, "harness"),
        metaValue(text, "model"),
        metaValue(text, "effort"),
        metaValue(text, "worktree"),
        started,
        null,
        null,
        "meta",
        stamp,
      );
      liveIds.add(id);
      counts.live += 1;
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }

  // Completed tasks: the durable manifest is the only record left once teardown
  // has removed the volatile ones, and it carries the sessions that were bound
  // while the task was live.
  let taskDirs = [];
  try {
    taskDirs = fs.readdirSync(data, { withFileTypes: true });
  } catch {
    taskDirs = [];
  }
  for (const dir of taskDirs) {
    if (!dir.isDirectory()) continue;
    const manifest = readJsonFile(path.join(data, dir.name, "outcome.json"));
    if (!manifest || manifest.schema !== "fm-outcome-manifest.v1") continue;
    if (manifest.task_id !== dir.name) continue;
    const attribution = manifest.attribution || {};
    // A meta record seen in THIS run wins over the manifest for the same id: the
    // task is running now, whatever an earlier archive says. Otherwise the
    // manifest supersedes whatever a previous run recorded, which is what stamps
    // completion onto a row that was written while the task was still live.
    if (!liveIds.has(dir.name)) {
      upsert.run(
        manifest.task_id,
        cleanToken(manifest.project, 480),
        cleanToken(manifest.kind) || "ship",
        cleanToken(manifest.harness),
        cleanToken(manifest.model),
        cleanToken(manifest.effort),
        cleanToken(attribution.worktree, 480),
        normalizeIso(manifest.timestamps?.started),
        normalizeIso(manifest.timestamps?.completed),
        cleanToken(manifest.outcome?.state),
        "manifest",
        stamp,
      );
      counts.archived += 1;
    }
    for (const session of Array.isArray(attribution.sessions) ? attribution.sessions : []) {
      const harness = cleanToken(session?.harness, 40);
      const sessionId = cleanToken(session?.session_id);
      if (!harness || !sessionId) continue;
      bind.run(
        harness,
        sessionId,
        manifest.task_id,
        cleanToken(manifest.project, 480),
        cleanToken(attribution.worktree, 480),
        "outcome_manifest",
        stamp,
      );
      counts.bindings_from_manifest += 1;
    }
  }

  // A task whose live records are gone is not live any more, even when no
  // manifest ever superseded its row. Retiring it here is what stops a torn-down
  // task from claiming a pool slot it no longer holds; the moment its absence
  // was first observed bounds the claim, so its own earlier usage still matches
  // while a later task's does not. A state directory that could not be read at
  // all is unknown, not empty, and retires nothing.
  if (stateReadable) {
    const live = [...liveIds];
    const retired = db
      .prepare(`UPDATE usage_task
          SET source = 'meta_gone', completed_at = COALESCE(completed_at, ?), updated_at = ?
        WHERE source = 'meta'${live.length ? ` AND task_id NOT IN (${live.map(() => "?").join(",")})` : ""}`)
      .run(stamp, stamp, ...live);
    counts.live_records_gone = Number(retired.changes);
  }
  return counts;
}

// A session belongs to a task when its working directory is that task's isolated
// worktree while the task holds it. Worktree paths are recycled across tasks, so
// the task's own lifetime bounds the claim and an overlapping claim is refused
// rather than guessed. This binding is recorded durably as soon as it is
// observed, which is what lets the manifest carry it past teardown.
function bindLiveSessions(db, stamp) {
  const bind = db.prepare(`INSERT INTO usage_binding
      (harness, session_id, task_id, project, worktree, source, recorded_at)
    VALUES (?,?,?,?,?,?,?)
    ON CONFLICT(harness, session_id) DO NOTHING`);
  const sessions = db.prepare(`SELECT s.harness, s.session_id, s.cwd, s.first_seen, s.last_seen
    FROM usage_session s
    LEFT JOIN usage_binding b ON b.harness = s.harness AND b.session_id = s.session_id
    WHERE b.task_id IS NULL AND s.cwd IS NOT NULL`).all();
  let bound = 0;
  for (const session of sessions) {
    // Only a task whose runtime records still exist can be observed live. A
    // match against an archived task is the same evidence as the post-hoc
    // worktree ladder below and must not be promoted to a high-confidence
    // binding by being recorded here.
    const candidates = matchTasksByWorktree(db, session.cwd, session.last_seen, session.first_seen, {
      liveOnly: true,
    });
    if (candidates.length !== 1) continue;
    const task = candidates[0];
    bind.run(session.harness, session.session_id, task.task_id, task.project, task.worktree, "live_worktree", stamp);
    bound += 1;
  }
  return bound;
}

function matchTasksByWorktree(db, cwd, atIso, fromIso = null, { liveOnly = false } = {}) {
  if (!cwd) return [];
  const at = isoToEpoch(atIso);
  const from = fromIso ? isoToEpoch(fromIso) : at;
  if (at === null) return [];
  const rows = db
    .prepare(
      `SELECT task_id, project, worktree, started_at, completed_at FROM usage_task
       WHERE worktree IS NOT NULL${liveOnly ? " AND source = 'meta'" : ""}`,
    )
    .all();
  return rows.filter((row) => {
    if (cwd !== row.worktree && !cwd.startsWith(`${row.worktree}/`)) return false;
    const started = row.started_at ? isoToEpoch(row.started_at) : null;
    const completed = row.completed_at ? isoToEpoch(row.completed_at) : null;
    // A task's own dispatch and completion stamps bound the claim. Time alone
    // never attributes anything: the exact worktree match is required first.
    if (started !== null && at < started && from < started) return false;
    if (completed !== null && from > completed) return false;
    return true;
  });
}

// Attribution is derived, so it is recomputed from scratch on every ingest and
// never drifts from the bindings and task records it is built on.
function attributeEvents(db, home) {
  const update = db.prepare(`UPDATE usage_event
    SET task_id = ?, project = ?, attribution_method = ?, attribution_confidence = ?
    WHERE event_id = ?`);
  const bindings = new Map();
  for (const row of db.prepare("SELECT * FROM usage_binding").all()) {
    bindings.set(`${row.harness}\u001f${row.session_id}`, row);
  }
  const events = db
    .prepare("SELECT event_id, harness, session_id, cwd, occurred_at FROM usage_event")
    .all();
  const registry = loadProjectRegistry(home);
  const resolvePath = buildPathResolver(home, registry);
  db.exec("BEGIN");
  try {
    // The reset belongs inside the same transaction as the re-derivation. A
    // failure between the two - a second writer past the busy timeout, a full
    // disk - would otherwise commit the reset and roll back only the rebuild,
    // leaving every stored event unattributed until a later run succeeded.
    db.exec(
      "UPDATE usage_event SET task_id = NULL, project = NULL, attribution_method = 'unknown', attribution_confidence = 'none'",
    );
    for (const event of events) {
      const binding = bindings.get(`${event.harness}\u001f${event.session_id}`);
      if (binding) {
        // The binding's own project field is the task metadata's project,
        // which is currently a clone path. Normalize it to the registered
        // project name when the worktree resolves, but keep the task identity.
        const project = resolvePath.fromWorktree(binding.worktree || event.cwd) || binding.project;
        update.run(binding.task_id, project, "session_binding", "high", event.event_id);
        continue;
      }
      const candidates = matchTasksByWorktree(db, event.cwd, event.occurred_at);
      if (candidates.length === 1) {
        const task = candidates[0];
        const project = resolvePath.fromWorktree(task.worktree) || task.project;
        update.run(task.task_id, project, "worktree_window", "medium", event.event_id);
      } else if (candidates.length > 1) {
        update.run(null, null, "ambiguous", "none", event.event_id);
        continue;
      }
      // No binding and no single task claims this worktree. If the directory
      // itself resolves to a registered project through its git origin, credit
      // the event to that project while leaving task_id null. A path that
      // merely looks like a project cannot create a phantom row because the
      // match is against the registry, not the path string.
      const resolved = resolvePath.fromPath(event.cwd);
      if (resolved) {
        update.run(null, resolved.project, resolved.method, resolved.confidence, event.event_id);
      }
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

// The live session map for each task that still has runtime records, published
// where bin/fm-outcome-manifest.sh reads it. Teardown removes the sidecar with
// the rest of the task's volatile state, by which time the manifest has already
// carried its contents into durable history.
function publishTaskSessions(db, dirs, stamp) {
  const state = dirs.state;
  let entries = [];
  try {
    entries = fs.readdirSync(state, { withFileTypes: true });
  } catch {
    return 0;
  }
  const query = db.prepare(`SELECT b.harness, b.session_id, s.source_kind, s.first_seen, s.last_seen
    FROM usage_binding b
    LEFT JOIN usage_session s ON s.harness = b.harness AND s.session_id = b.session_id
    WHERE b.task_id = ?
    ORDER BY s.last_seen DESC, b.session_id ASC
    LIMIT ${MAX_TASK_SESSIONS}`);
  let published = 0;
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".meta")) continue;
    const id = entry.name.slice(0, -".meta".length);
    const sessions = query.all(id).map((row) => ({
      harness: row.harness,
      session_id: row.session_id,
      source_kind: row.source_kind || "unknown",
    }));
    if (sessions.length === 0) continue;
    const written = writeJsonFile(path.join(state, `${id}.usage-sessions`), {
      schema: SESSIONS_SCHEMA,
      task_id: id,
      recorded_at: stamp,
      sessions,
    });
    if (written) published += 1;
  }
  return published;
}

// ---------------------------------------------------------------------------
// Optional versioned cost estimate
// ---------------------------------------------------------------------------
//
// Absent rates are the default and mean "cost unknown", never "cost zero". A
// subscription seat's tokens are not API dollars, so every projection reports
// tokens whether or not an estimate exists.

function loadRates(file) {
  const doc = readJsonFile(file);
  if (!doc || doc.schema !== RATES_SCHEMA) return null;
  const version = cleanToken(doc.rate_version, 40);
  const currency = cleanToken(doc.currency, 8);
  if (!version || !currency || !doc.models || typeof doc.models !== "object") return null;
  const models = new Map();
  for (const [model, rate] of Object.entries(doc.models)) {
    const name = cleanToken(model);
    if (!name || !rate || typeof rate !== "object") continue;
    models.set(name, {
      input: Number(rate.input) || 0,
      output: Number(rate.output) || 0,
      cache_read: Number(rate.cache_read) || 0,
      cache_write: Number(rate.cache_write) || 0,
    });
  }
  if (models.size === 0) return null;
  return { version, currency, models };
}

function applyCost(db, rates, stamp) {
  const insert = rates
    ? db.prepare(`INSERT INTO usage_cost_estimate
        (event_id, rate_version, currency, estimated_cost, computed_at) VALUES (?,?,?,?,?)`)
    : null;
  const events = rates
    ? db
        .prepare(`SELECT event_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
                  FROM usage_event`)
        .all()
    : [];
  let priced = 0;
  let unpriced = 0;
  // The estimate is rebuilt in place, so clearing it and repricing commit
  // together: a failure between them would report a null cost on every rollup
  // despite a valid rate file, which reads as "cost unknown" rather than as the
  // failure it is.
  db.exec("BEGIN");
  try {
    db.exec("DELETE FROM usage_cost_estimate");
    for (const event of events) {
      const rate = event.model ? rates.models.get(event.model) : null;
      if (!rate) {
        unpriced += 1;
        continue;
      }
      // Rates are per million tokens, the unit every vendor publishes.
      const cost =
        (event.input_tokens * rate.input +
          event.output_tokens * rate.output +
          event.cache_read_tokens * rate.cache_read +
          event.cache_write_tokens * rate.cache_write) /
        1_000_000;
      insert.run(event.event_id, rates.version, rates.currency, cost, stamp);
      priced += 1;
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  if (!rates) return { rate_version: null, currency: null, events_priced: 0, events_unpriced: null };
  return {
    rate_version: rates.version,
    currency: rates.currency,
    events_priced: priced,
    events_unpriced: unpriced,
  };
}

// ---------------------------------------------------------------------------
// Read-only projections
// ---------------------------------------------------------------------------

const GROUPINGS = {
  task: "COALESCE(e.task_id, '(unattributed)')",
  project: "COALESCE(e.project, '(unknown)')",
  harness: "e.harness",
  model: "COALESCE(e.model, '(unknown)')",
  day: "substr(e.occurred_at, 1, 10)",
};

function rollup(db, by, { limit = 50, since = null } = {}) {
  const expression = GROUPINGS[by];
  const where = since ? "WHERE e.occurred_at >= ?" : "";
  const rows = db
    .prepare(`SELECT ${expression} AS key,
        COUNT(*) AS events,
        COUNT(DISTINCT e.harness || e.session_id) AS sessions,
        SUM(e.input_tokens) AS input_tokens,
        SUM(e.output_tokens) AS output_tokens,
        SUM(e.cache_read_tokens) AS cache_read_tokens,
        SUM(e.cache_write_tokens) AS cache_write_tokens,
        SUM(e.reasoning_tokens) AS reasoning_tokens,
        SUM(e.total_tokens) AS total_tokens,
        SUM(c.estimated_cost) AS estimated_cost,
        COUNT(c.event_id) AS priced_events,
        MAX(c.rate_version) AS rate_version,
        MAX(c.currency) AS currency
      FROM usage_event e
      LEFT JOIN usage_cost_estimate c ON c.event_id = e.event_id
      ${where}
      GROUP BY key
      ORDER BY total_tokens DESC, key ASC
      LIMIT ?`)
    .all(...(since ? [since, limit] : [limit]));
  return rows.map((row) => ({
    key: row.key,
    events: row.events,
    sessions: row.sessions,
    input_tokens: row.input_tokens ?? 0,
    output_tokens: row.output_tokens ?? 0,
    cache_read_tokens: row.cache_read_tokens ?? 0,
    cache_write_tokens: row.cache_write_tokens ?? 0,
    reasoning_tokens: row.reasoning_tokens ?? 0,
    total_tokens: row.total_tokens ?? 0,
    // An estimate is reported only for the events that actually carry one, and
    // stays null when no rate version priced any of them.
    cost: row.priced_events
      ? {
          estimated: row.estimated_cost,
          currency: row.currency,
          rate_version: row.rate_version,
          priced_events: row.priced_events,
          unpriced_events: row.events - row.priced_events,
        }
      : null,
  }));
}

function attributionReport(db) {
  const totals = db
    .prepare(`SELECT COUNT(*) AS events, SUM(total_tokens) AS tokens,
        SUM(CASE WHEN task_id IS NOT NULL THEN 1 ELSE 0 END) AS attributed_events,
        SUM(CASE WHEN task_id IS NOT NULL THEN total_tokens ELSE 0 END) AS attributed_tokens
      FROM usage_event`)
    .get();
  const byMethod = db
    .prepare(`SELECT attribution_method AS method, attribution_confidence AS confidence,
        COUNT(*) AS events, SUM(total_tokens) AS tokens
      FROM usage_event GROUP BY method, confidence ORDER BY events DESC`)
    .all();
  const events = totals.events ?? 0;
  const attributed = totals.attributed_events ?? 0;
  const tokens = totals.tokens ?? 0;
  const attributedTokens = totals.attributed_tokens ?? 0;
  const percent = (part, whole) => (whole > 0 ? Math.round((part / whole) * 10000) / 100 : null);
  return {
    events,
    attributed_events: attributed,
    unattributed_events: events - attributed,
    percent_events_attributed: percent(attributed, events),
    total_tokens: tokens,
    attributed_tokens: attributedTokens,
    unattributed_tokens: tokens - attributedTokens,
    percent_tokens_attributed: percent(attributedTokens, tokens),
    by_method: byMethod.map((row) => ({
      method: row.method,
      confidence: row.confidence,
      events: row.events,
      tokens: row.tokens ?? 0,
    })),
  };
}

function burnSeries(db, bucket, buckets, stamp) {
  const width = bucket === "day" ? 86400 : 3600;
  const now = isoToEpoch(stamp);
  const start = now - width * buckets;
  // The bucket width is an integer LITERAL, not a bound parameter: node:sqlite
  // binds a JavaScript number as REAL, and SQLite's `/` on a REAL is floating
  // division, so a bound width silently loses the integer floor that defines a
  // bucket and every event lands in a bucket of its own. `width` comes from the
  // two-value enum above, so interpolating it carries no injection surface.
  const rows = db
    .prepare(`SELECT (occurred_epoch / ${width}) * ${width} AS bucket_start,
        COUNT(*) AS events, SUM(total_tokens) AS total_tokens,
        SUM(output_tokens) AS output_tokens
      FROM usage_event WHERE occurred_epoch >= ?
      GROUP BY bucket_start ORDER BY bucket_start ASC`)
    .all(start);
  const series = rows.map((row) => ({
    bucket_start: new Date(row.bucket_start * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"),
    events: row.events,
    total_tokens: row.total_tokens ?? 0,
    output_tokens: row.output_tokens ?? 0,
    tokens_per_hour: Math.round(((row.total_tokens ?? 0) / width) * 3600),
  }));
  return { bucket, buckets, width_seconds: width, series };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const options = {};
  const rest = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--no-sessions") {
      options.sessions = false;
    } else if (arg.startsWith("--")) {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith("--")) die(`${arg} needs a value`, 2);
      options[arg.slice(2).replace(/-/g, "_")] = value;
      index += 1;
    } else {
      rest.push(arg);
    }
  }
  return { options, rest };
}

function resolveHome(options) {
  if (options.home) return path.resolve(options.home);
  if (process.env.FM_HOME) return path.resolve(process.env.FM_HOME);
  // fileURLToPath, not the URL's pathname: a checkout under a path containing a
  // space or a '#' stays percent-encoded in the latter and would resolve the
  // store under a directory that does not exist.
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
}

function resolvePaths(options) {
  const home = resolveHome(options);
  const claudeConfig = process.env.CLAUDE_CONFIG_DIR
    ? process.env.CLAUDE_CONFIG_DIR.split(",")[0]
    : path.join(os.homedir(), ".claude");
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  // The same state and data overrides the rest of firstmate honors, so a caller
  // that already resolved a home's directories - teardown, or a test harness -
  // reaches exactly the records it means to.
  const state = path.resolve(process.env.FM_STATE_OVERRIDE || path.join(home, "state"));
  const data = path.resolve(process.env.FM_DATA_OVERRIDE || path.join(home, "data"));
  return {
    home,
    state,
    data,
    db: path.resolve(options.db || process.env.FM_USAGE_DB || path.join(data, "usage.db")),
    claude: path.resolve(
      options.claude_root || process.env.FM_USAGE_CLAUDE_ROOT || path.join(claudeConfig, "projects"),
    ),
    codex: path.resolve(
      options.codex_root || process.env.FM_USAGE_CODEX_ROOT || path.join(codexHome, "sessions"),
    ),
    rates: path.resolve(
      options.rates || process.env.FM_USAGE_RATES || path.join(home, "config", "usage-rates.json"),
    ),
  };
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

async function main() {
  const [command, ...argv] = process.argv.slice(2);
  if (!command || command === "-h" || command === "--help") {
    process.stdout.write(USAGE);
    process.exit(command ? 0 : 2);
  }
  const { options } = parseArgs(argv);
  const paths = resolvePaths(options);
  const stamp = nowIso();

  if (command === "ingest" || command === "migrate") {
    let db;
    try {
      db = openStore(paths.db);
    } catch (error) {
      die(`could not open the usage store: ${error.message}`);
    }
    // Every exit from the writer path closes through closeStore, including the
    // ones a raised error takes and the ones a bounded caller's SIGTERM takes: a
    // run that left the store in WAL would be a run the read-only dashboard
    // cannot open at all, and both bootstrap and teardown end a refresh that
    // outran its budget with exactly that signal.
    const closeUsageStore = closeStoreOnSignals(db);
    try {
      if (command === "migrate") {
        emit({ schema_version: SCHEMA_VERSION, store: paths.db });
        return;
      }
      const collected = await collect(db, { claude: paths.claude, codex: paths.codex }, stamp);
      const tasks = syncTasks(db, paths, stamp);
      const bound = bindLiveSessions(db, stamp);
      // Each derived stage is atomic on its own, so a failure in one must not
      // silently skip the ones after it - publishing the session map is what lets
      // a task's usage survive the cleanup that is about to run. Every failure is
      // named in the summary and in the exit status instead of vanishing into
      // teardown's best-effort call.
      const failures = [];
      const stage = (name, run, fallback) => {
        try {
          return run();
        } catch (error) {
          failures.push({ stage: name, detail: String(error?.message ?? error).slice(0, 240) });
          return fallback;
        }
      };
      stage("attribution", () => attributeEvents(db, paths.home), null);
      const cost = stage("cost", () => applyCost(db, loadRates(paths.rates), stamp), {
        rate_version: null,
        currency: null,
        events_priced: 0,
        events_unpriced: null,
      });
      const published =
        options.sessions === false ? 0 : stage("task_sessions", () => publishTaskSessions(db, paths, stamp), 0);
      const attribution = stage("attribution_report", () => attributionReport(db), null);
      emit({
        schema: "fm-usage-ingest.v1",
        store: paths.db,
        schema_version: SCHEMA_VERSION,
        collected,
        tasks,
        sessions_bound: bound,
        task_session_maps_published: published,
        cost,
        attribution,
        failures,
        completed_at: stamp,
      });
      if (failures.length > 0) process.exitCode = 1;
    } finally {
      closeUsageStore();
    }
    return;
  }

  let db;
  try {
    db = openStore(paths.db, { create: false, readOnly: true });
  } catch (error) {
    die(`could not open the usage store: ${error.message}`);
  }
  if (!db) die(`no usage store at ${paths.db}; run "fm-usage.mjs ingest" first`);

  if (command === "report") {
    const by = options.by;
    if (!by || !GROUPINGS[by]) die(`--by must be one of ${Object.keys(GROUPINGS).join(", ")}`, 2);
    const limit = Number(options.limit || 50);
    if (!Number.isInteger(limit) || limit <= 0) die("--limit must be a positive integer", 2);
    const since = options.since ? normalizeIso(options.since) : null;
    if (options.since && !since) die("--since must be an ISO-8601 UTC stamp", 2);
    emit({ schema: "fm-usage-report.v1", by, since, rows: rollup(db, by, { limit, since }) });
  } else if (command === "burn") {
    const bucket = options.bucket || "hour";
    if (bucket !== "hour" && bucket !== "day") die("--bucket must be hour or day", 2);
    const buckets = Number(options.buckets || 24);
    if (!Number.isInteger(buckets) || buckets <= 0 || buckets > MAX_BURN_BUCKETS) {
      die(`--buckets must be between 1 and ${MAX_BURN_BUCKETS}`, 2);
    }
    emit({ schema: "fm-usage-burn.v1", ...burnSeries(db, bucket, buckets, stamp) });
  } else if (command === "attribution") {
    emit({ schema: "fm-usage-attribution.v1", ...attributionReport(db) });
  } else if (command === "sessions") {
    const rows = options.task
      ? db
          .prepare(`SELECT s.harness, s.session_id, s.source_kind, s.cwd, s.first_seen, s.last_seen,
              s.event_count, b.task_id, b.source AS binding_source
            FROM usage_session s
            LEFT JOIN usage_binding b ON b.harness = s.harness AND b.session_id = s.session_id
            WHERE b.task_id = ? ORDER BY s.last_seen DESC`)
          .all(options.task)
      : db
          .prepare(`SELECT s.harness, s.session_id, s.source_kind, s.cwd, s.first_seen, s.last_seen,
              s.event_count, b.task_id, b.source AS binding_source
            FROM usage_session s
            LEFT JOIN usage_binding b ON b.harness = s.harness AND b.session_id = s.session_id
            ORDER BY s.last_seen DESC`)
          .all();
    emit({ schema: "fm-usage-sessions-report.v1", task: options.task || null, sessions: rows });
  } else {
    process.stderr.write(USAGE);
    process.exit(2);
  }
  db.close();
}

// An unhandled rejection would exit with a bare stack trace and no explanation,
// which is worth nothing to an operator and less to teardown's best-effort call.
try {
  await main();
} catch (error) {
  die(String(error?.message ?? error));
}
