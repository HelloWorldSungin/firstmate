#!/usr/bin/env node
// fm-event-store.mjs - the dashboard's own agent-event store and its one
// server-side redaction boundary.
//
// Usage:
//   fm-event-store.mjs path                  print the resolved store path
//   fm-event-store.mjs stats                 counts, oldest and newest, per harness
//   fm-event-store.mjs list [--task <id>] [--limit <n>]
//   fm-event-store.mjs prune                 apply the retention caps now
//
// Every subcommand prints one JSON object on stdout. Only `prune` writes.
//
// WHERE THIS LIVES, AND WHY NOT UNDER THE OPERATIONAL HOME
//
// The dashboard is read-only towards the fleet: nothing it runs writes into
// data/, state/, or projects/, and tests/fm-dashboard.test.sh proves it by
// fingerprinting those directories around a live server. Its installed user
// service is hardened to match (ProtectSystem=strict, ProtectHome=read-only).
// An event store under data/ would have to break both - the fingerprint proof
// and the service's write isolation - so the store lives outside the home
// entirely, keyed by the home it describes:
//
//   $FM_DASHBOARD_EVENT_DB, or
//   ${XDG_STATE_HOME:-~/.local/state}/firstmate/dashboard-events/<home-slug>/events.db
//
// The slug carries the home's basename for a human plus a digest of its
// absolute path for uniqueness, so a main home and a secondmate home never
// share a store.
//
// It is still the fleet's telemetry store in every way that matters:
// fm-telemetry-store.mjs owns the opening, migration, sanitizing, and
// timestamp discipline that data/usage.db also uses, and both spell task_id,
// harness, session_id, and an instant the same way, so the two join on a task.
//
// WHAT A STORED EVENT MAY CONTAIN
//
// Only the fields below, each rebuilt from scratch under its own pattern. A
// posted document's other keys are not stored, not echoed, and not logged -
// they are simply never read. Prompts, responses, tool arguments, tool
// results, file contents, environment values, and absolute paths have no field
// to arrive in: `summary` refuses the characters a path or an assignment needs,
// refuses any unbroken run long enough to be a token, and refuses known
// credential shapes outright. docs/dashboard-events.md owns this contract and
// tests/fm-dashboard-events.test.sh seeds credential- and path-shaped values at
// both boundaries to keep it honest.
//
// WHICH PREDICATE GUARDS WHICH FIELD
//
// Redaction here is allowlist-based per FIELD: a field is admitted by its own
// pattern, and that pattern is the redaction. Two credential predicates exist
// because a field's own pattern can only constrain shape, not semantics:
//
//   hasCredentialPrefix  the named vendor shapes only. Cheap, exact, no false
//                        positives, and therefore safe on every field.
//   looksLikeCredential  hasCredentialPrefix OR a long mixed letter-and-digit
//                        run. A content-scanning denylist, and it belongs only
//                        on a value whose semantics an allowlist cannot pin
//                        down. In this schema that is exactly one field.
//
// `summary` is the only free-form value, so it carries both. `tool` is an
// identifier with known-safe semantics whose allowlist (TOOL_PATTERN) already
// is its redaction, and it carries the prefix check alone: a tool name is one
// unbroken run by construction, so the entropy rule would classify any MCP tool
// name of 24 or more characters containing a digit as a credential and silently
// blank the very field the timeline exists to show. There is deliberately no
// run-length or entropy rule for tool names at all - a long camelCase name such
// as SlackSendMessageToChannel must survive.
//
// Accepted residual: an unprefixed high-entropy token placed in `tool` by a
// hostile authenticated POST would be stored. Reaching that needs the ingest
// token, the value still has to satisfy TOOL_PATTERN, and closing it would take
// exactly the run-length rule that breaks real tool names.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { cleanToken, digest, isoToEpoch, normalizeIso, openStore } from "./fm-telemetry-store.mjs";

export const WIRE_SCHEMA = "fm-agent-event.v1";
export const STORE_KIND = "fm-event-store";

// The harness-agnostic lifecycle vocabulary. A harness adapter translates its
// own native event into one of these; adding the fifth or sixth harness adds an
// adapter, never a wire field.
export const EVENT_TYPES = new Set([
  "session_start",
  "prompt_submitted",
  "tool_started",
  "tool_finished",
  "turn_ended",
  "session_end",
  "notification",
]);

export const EVENT_OUTCOMES = new Set(["ok", "error", "blocked", "unknown"]);

// The harnesses that ship an event adapter today. Everything else degrades to
// "no event source" in the view rather than looking like a silent failure.
export const INSTRUMENTED_HARNESSES = ["claude", "opencode"];

// Exactly bin/fm-pr-lib.sh's fm_task_id_path_safe rule, bounded.
const TASK_ID_PATTERN = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$/;
const HARNESS_PATTERN = /^[a-z][a-z0-9-]{0,31}$/;
const SESSION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const TOOL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$/;
const EVENT_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
// A summary may use only these characters. No slash or backslash, so an
// absolute path cannot survive; no equals, at-sign, or plus, so an assignment,
// an address, and base64 padding cannot either.
const SUMMARY_ALLOWED = /^[A-Za-z0-9 .,_:#()-]+$/;
const SUMMARY_MAX = 80;
// A human summary has spaces. A token does not, which is why an unbroken run
// this long is refused rather than trusted.
const SUMMARY_RUN_MAX = 15;

// Known credential shapes, plus one length-and-mixture rule for the ones that
// have no recognizable prefix. Deliberately conservative: this is the last line
// behind the character allowlist, not the first.
const CREDENTIAL_PREFIXES = [
  /\bsk-[A-Za-z0-9]/,
  /\bgh[pousr]_[A-Za-z0-9]/,
  /\bgithub_pat_/,
  /\bglpat-/,
  /\bxox[abprs]-/,
  /\bAKIA[A-Z0-9]/,
  /\bASIA[A-Z0-9]/,
  /\bAIza[A-Za-z0-9]/,
  /-----BEGIN/,
];
const HIGH_ENTROPY_RUN = /[A-Za-z0-9+/=_-]{24,}/;

// The named vendor shapes only. Safe on any field, because a value that carries
// one of these prefixes is a credential whatever field it arrived in.
export function hasCredentialPrefix(value) {
  if (typeof value !== "string" || !value) return false;
  for (const pattern of CREDENTIAL_PREFIXES) if (pattern.test(value)) return true;
  return false;
}

// The prefixes plus the entropy rule. For free-form values only - see the
// header on why an identifier field must not carry this.
export function looksLikeCredential(value) {
  if (hasCredentialPrefix(value)) return true;
  if (typeof value !== "string" || !value) return false;
  const run = value.match(HIGH_ENTROPY_RUN);
  // Length alone is not evidence: a long identifier of only letters and
  // underscores is a tool name, while a long run mixing letters and digits is
  // what a key looks like.
  return Boolean(run && /[A-Za-z]/.test(run[0]) && /[0-9]/.test(run[0]));
}

function matched(value, pattern, max = 128) {
  const token = cleanToken(value, max);
  if (token === null) return null;
  return pattern.test(token) ? token : null;
}

export function safeSummary(value) {
  const token = cleanToken(value, SUMMARY_MAX);
  if (token === null) return null;
  const collapsed = token.replace(/\s+/g, " ").trim();
  if (!collapsed || collapsed.length > SUMMARY_MAX) return null;
  if (!SUMMARY_ALLOWED.test(collapsed)) return null;
  for (const run of collapsed.split(" ")) {
    if (run.length > SUMMARY_RUN_MAX) return null;
  }
  if (looksLikeCredential(collapsed)) return null;
  return collapsed;
}

export function safeTool(value) {
  const token = matched(value, TOOL_PATTERN, 64);
  if (token === null) return null;
  return hasCredentialPrefix(token) ? null : token;
}

// One posted event becomes one stored row, or a named rejection. Nothing is
// carried over from the input document except the fields named here.
export function sanitizeEvent(raw, { nowEpoch, skewSeconds }) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { rejected: "not_an_object" };

  const taskId = matched(raw.task_id, TASK_ID_PATTERN);
  if (!taskId) return { rejected: "invalid_task_id" };
  const harness = matched(raw.harness, HARNESS_PATTERN, 32);
  if (!harness) return { rejected: "invalid_harness" };
  const type = typeof raw.type === "string" && EVENT_TYPES.has(raw.type) ? raw.type : null;
  if (!type) return { rejected: "invalid_type" };

  const occurredAt = normalizeIso(typeof raw.occurred_at === "string" ? raw.occurred_at : "");
  if (!occurredAt) return { rejected: "invalid_occurred_at" };
  const occurredEpoch = isoToEpoch(occurredAt);
  // A replayed event is one whose own instant is outside the window a live
  // producer could be reporting from. It is refused by its timestamp rather
  // than only deduplicated by its id, so a captured-and-resent batch with fresh
  // ids cannot repopulate a timeline hours later.
  if (occurredEpoch < nowEpoch - skewSeconds) return { rejected: "stale" };
  if (occurredEpoch > nowEpoch + 60) return { rejected: "future" };

  // The producer supplies identity so a retry is the same event. A producer
  // that omits it gets a content-derived one, which still collapses an exact
  // duplicate. The fields are joined on NUL because no allowlisted value can
  // contain one, so two different events can never digest to the same string by
  // rearranging where one field ends and the next begins. It is written as an
  // escape rather than as a literal byte: a literal NUL in the source makes git
  // treat the whole file as binary, and a file that cannot be diffed cannot be
  // reviewed.
  const suppliedId = matched(raw.event_id, EVENT_ID_PATTERN);
  const tool = safeTool(raw.tool);
  const outcome = typeof raw.outcome === "string" && EVENT_OUTCOMES.has(raw.outcome) ? raw.outcome : null;
  const summary = safeSummary(raw.summary);
  const sessionId = matched(raw.session_id, SESSION_PATTERN);
  const eventId = suppliedId
    || digest([taskId, harness, type, occurredAt, tool ?? "", outcome ?? "", summary ?? ""].join("\u0000")).slice(0, 32);

  return {
    event: {
      event_id: eventId,
      task_id: taskId,
      harness,
      session_id: sessionId,
      type,
      tool,
      outcome,
      summary,
      occurred_at: occurredAt,
      occurred_epoch: occurredEpoch,
    },
  };
}

const MIGRATIONS = [
  {
    version: 1,
    statements: [
      `CREATE TABLE agent_event (
         event_id       TEXT PRIMARY KEY,
         task_id        TEXT NOT NULL,
         harness        TEXT NOT NULL,
         session_id     TEXT,
         type           TEXT NOT NULL,
         tool           TEXT,
         outcome        TEXT,
         summary        TEXT,
         occurred_at    TEXT NOT NULL,
         occurred_epoch INTEGER NOT NULL,
         received_at    TEXT NOT NULL,
         received_epoch INTEGER NOT NULL
       )`,
      `CREATE INDEX agent_event_task ON agent_event (task_id, occurred_epoch)`,
      `CREATE INDEX agent_event_time ON agent_event (occurred_epoch)`,
    ],
  },
];

export const SCHEMA_VERSION = MIGRATIONS[MIGRATIONS.length - 1].version;

export const DEFAULT_LIMITS = {
  retentionHours: 168,
  maxRows: 50_000,
  maxRowsPerTask: 2_000,
  skewSeconds: 300,
  tailLimit: 200,
  taskLimit: 500,
};

function slugForHome(fmHome) {
  const resolved = path.resolve(fmHome);
  const base = path.basename(resolved).replace(/[^A-Za-z0-9._-]/g, "-").slice(0, 40) || "home";
  return `${base}-${digest(resolved).slice(0, 12)}`;
}

// The store path is derived, never taken from a request. An explicit override
// exists for the installer and for tests; nothing reachable over HTTP can
// influence it.
export function resolveStorePath(fmHome, env = process.env) {
  const explicit = env.FM_DASHBOARD_EVENT_DB;
  if (explicit) return path.resolve(explicit);
  const stateRoot = env.XDG_STATE_HOME || path.join(env.HOME || os.homedir(), ".local", "state");
  return path.join(stateRoot, "firstmate", "dashboard-events", slugForHome(fmHome), "events.db");
}

export class EventStore {
  constructor(dbPath, limits = {}) {
    this.path = dbPath;
    this.limits = { ...DEFAULT_LIMITS, ...limits };
    this.db = openStore(dbPath, MIGRATIONS);
    this.statements = {
      insert: this.db.prepare(
        `INSERT OR IGNORE INTO agent_event
           (event_id, task_id, harness, session_id, type, tool, outcome, summary,
            occurred_at, occurred_epoch, received_at, received_epoch)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ),
      tail: this.db.prepare(
        `SELECT * FROM agent_event ORDER BY occurred_epoch DESC, rowid DESC LIMIT ?`,
      ),
      forTask: this.db.prepare(
        `SELECT * FROM agent_event WHERE task_id = ? ORDER BY occurred_epoch DESC, rowid DESC LIMIT ?`,
      ),
      total: this.db.prepare("SELECT COUNT(*) AS rows FROM agent_event"),
      byHarness: this.db.prepare(
        "SELECT harness, COUNT(*) AS rows FROM agent_event GROUP BY harness ORDER BY harness",
      ),
      byTask: this.db.prepare(
        `SELECT task_id, COUNT(*) AS rows, MAX(occurred_at) AS newest
           FROM agent_event GROUP BY task_id ORDER BY newest DESC LIMIT 200`,
      ),
      span: this.db.prepare("SELECT MIN(occurred_at) AS oldest, MAX(occurred_at) AS newest FROM agent_event"),
      pruneAge: this.db.prepare("DELETE FROM agent_event WHERE occurred_epoch < ?"),
      pruneRows: this.db.prepare(
        `DELETE FROM agent_event WHERE rowid IN (
           SELECT rowid FROM agent_event ORDER BY occurred_epoch DESC, rowid DESC LIMIT -1 OFFSET ?)`,
      ),
      pruneTask: this.db.prepare(
        `DELETE FROM agent_event WHERE rowid IN (
           SELECT rowid FROM agent_event WHERE task_id = ?
            ORDER BY occurred_epoch DESC, rowid DESC LIMIT -1 OFFSET ?)`,
      ),
      tasksOverCap: this.db.prepare(
        "SELECT task_id FROM agent_event GROUP BY task_id HAVING COUNT(*) > ?",
      ),
    };
    // A cached row count, so prune() can decide whether a cap can even be
    // crossed without asking the table. It is exact while this process is the
    // only writer, and a deletion by another process (the prune subcommand) can
    // only leave it high - which costs an unnecessary scan and never a missed
    // one. See prune() for what it buys.
    this.rows = this.statements.total.get().rows;
    this.storedSinceTaskScan = 0;
  }

  // One transaction per accepted batch: either every event in it is stored or
  // none is, so a browser never sees half a turn.
  insert(events, receivedAt) {
    const receivedEpoch = isoToEpoch(receivedAt);
    let stored = 0;
    let duplicate = 0;
    this.db.exec("BEGIN IMMEDIATE");
    try {
      for (const event of events) {
        const result = this.statements.insert.run(
          event.event_id, event.task_id, event.harness, event.session_id, event.type,
          event.tool, event.outcome, event.summary, event.occurred_at, event.occurred_epoch,
          receivedAt, receivedEpoch,
        );
        if (result.changes > 0) stored += 1;
        else duplicate += 1;
      }
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    this.rows += stored;
    this.storedSinceTaskScan += stored;
    return { stored, duplicate };
  }

  // Retention is enforced by the writer rather than by a separate sweeper, so a
  // store cannot grow without bound just because nobody ran a cleanup command.
  //
  // The age sweep is index-bounded and runs every time. The other two
  // statements are not: the total-row cap and the per-task cap each scan the
  // whole table, which at the default caps is on the order of 100k index
  // entries per accepted batch, synchronously, in the process that also serves
  // snapshots and SSE. They therefore run only when the cached row count says a
  // cap can actually be crossed, and the per-task scan runs at most once per
  // maxRowsPerTask/8 stored rows rather than once per accepted batch.
  //
  // What that costs is a bounded overshoot, and it is deliberately zero for the
  // small caps a test pins: the store may hold up to maxRows/64 rows over the
  // total cap, and a task up to maxRowsPerTask/8 rows over its own, both
  // rounded down. `full` forces both scans for the prune subcommand, whose
  // whole job is to apply the caps exactly, now.
  prune(nowEpoch, { full = false } = {}) {
    let removed = 0;
    const cutoff = nowEpoch - this.limits.retentionHours * 3600;
    const rowSlack = Math.floor(this.limits.maxRows / 64);
    const taskScanEvery = Math.floor(this.limits.maxRowsPerTask / 8);
    this.db.exec("BEGIN IMMEDIATE");
    try {
      removed += this.statements.pruneAge.run(cutoff).changes;
      if (full || this.rows - removed > this.limits.maxRows + rowSlack) {
        removed += this.statements.pruneRows.run(this.limits.maxRows).changes;
      }
      if (full || (this.rows - removed > this.limits.maxRowsPerTask
        && this.storedSinceTaskScan >= taskScanEvery)) {
        this.storedSinceTaskScan = 0;
        for (const row of this.statements.tasksOverCap.all(this.limits.maxRowsPerTask)) {
          removed += this.statements.pruneTask.run(row.task_id, this.limits.maxRowsPerTask).changes;
        }
      }
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    this.rows = Math.max(0, this.rows - removed);
    return removed;
  }

  tail(limit = this.limits.tailLimit) {
    return this.statements.tail.all(Math.max(1, Math.min(limit, this.limits.tailLimit)));
  }

  forTask(taskId, limit = this.limits.taskLimit) {
    if (!TASK_ID_PATTERN.test(taskId)) return [];
    return this.statements.forTask.all(taskId, Math.max(1, Math.min(limit, this.limits.taskLimit)));
  }

  stats() {
    const span = this.statements.span.get() || {};
    return {
      store: this.path,
      schema_version: SCHEMA_VERSION,
      rows: this.statements.total.get().rows,
      oldest: span.oldest ?? null,
      newest: span.newest ?? null,
      harnesses: this.statements.byHarness.all(),
      tasks: this.statements.byTask.all(),
      limits: this.limits,
    };
  }

  close() {
    try {
      this.db.close();
    } catch {
      /* an already-closed store needs no closing */
    }
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const USAGE = `usage: fm-event-store.mjs path
       fm-event-store.mjs stats
       fm-event-store.mjs list [--task <id>] [--limit <n>]
       fm-event-store.mjs prune

The dashboard's agent-event store. Every subcommand prints one JSON object;
only prune writes. docs/dashboard-events.md owns the stored contract.

Environment:
  FM_HOME                                 operational home the store describes
  FM_DASHBOARD_EVENT_DB                   explicit store path
  FM_DASHBOARD_EVENT_RETENTION_HOURS      age cap (default 168)
  FM_DASHBOARD_EVENT_MAX_ROWS             total row cap (default 50000)
  FM_DASHBOARD_EVENT_MAX_ROWS_PER_TASK    per-task row cap (default 2000)
`;

export function limitsFromEnv(env = process.env) {
  const read = (name, fallback, maximum) => {
    const raw = env[name];
    if (raw === undefined || raw === "") return fallback;
    const value = Number(raw);
    if (!Number.isInteger(value) || value <= 0 || value > maximum) {
      throw new Error(`${name} must be a positive integer no greater than ${maximum}`);
    }
    return value;
  };
  return {
    retentionHours: read("FM_DASHBOARD_EVENT_RETENTION_HOURS", DEFAULT_LIMITS.retentionHours, 8760),
    maxRows: read("FM_DASHBOARD_EVENT_MAX_ROWS", DEFAULT_LIMITS.maxRows, 5_000_000),
    maxRowsPerTask: read("FM_DASHBOARD_EVENT_MAX_ROWS_PER_TASK", DEFAULT_LIMITS.maxRowsPerTask, 1_000_000),
    skewSeconds: read("FM_DASHBOARD_EVENT_SKEW_SECONDS", DEFAULT_LIMITS.skewSeconds, 86_400),
  };
}

function runCli(argv) {
  const command = argv[0];
  if (!command || command === "-h" || command === "--help") {
    process.stdout.write(USAGE);
    return 0;
  }
  const fmHome = path.resolve(process.env.FM_HOME || path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."));
  const storePath = resolveStorePath(fmHome);
  if (command === "path") {
    process.stdout.write(`${JSON.stringify({ schema: `${STORE_KIND}-path.v1`, path: storePath })}\n`);
    return 0;
  }
  if (!["stats", "list", "prune"].includes(command)) {
    process.stderr.write(`fm-event-store: unknown command: ${command}\n${USAGE}`);
    return 2;
  }
  if (command !== "prune" && !fs.existsSync(storePath)) {
    process.stdout.write(`${JSON.stringify({
      schema: `${STORE_KIND}-${command}.v1`, store: storePath, present: false, rows: 0, events: [],
    })}\n`);
    return 0;
  }

  let task = null;
  let limit = 100;
  for (let index = 1; index < argv.length; index += 1) {
    if (argv[index] === "--task" && argv[index + 1]) { task = argv[index + 1]; index += 1; continue; }
    if (argv[index] === "--limit" && argv[index + 1]) { limit = Number(argv[index + 1]); index += 1; continue; }
    process.stderr.write(`fm-event-store: unknown option: ${argv[index]}\n${USAGE}`);
    return 2;
  }
  if (!Number.isInteger(limit) || limit <= 0) {
    process.stderr.write("fm-event-store: --limit must be a positive integer\n");
    return 2;
  }

  const store = new EventStore(storePath, limitsFromEnv());
  try {
    if (command === "stats") {
      process.stdout.write(`${JSON.stringify({ schema: `${STORE_KIND}-stats.v1`, present: true, ...store.stats() })}\n`);
      return 0;
    }
    if (command === "prune") {
      const removed = store.prune(Math.floor(Date.now() / 1000), { full: true });
      process.stdout.write(`${JSON.stringify({
        schema: `${STORE_KIND}-prune.v1`, store: storePath, removed, rows: store.stats().rows,
      })}\n`);
      return 0;
    }
    const events = task ? store.forTask(task, limit) : store.tail(Math.min(limit, DEFAULT_LIMITS.tailLimit));
    process.stdout.write(`${JSON.stringify({
      schema: `${STORE_KIND}-list.v1`, store: storePath, present: true, task, rows: events.length, events,
    })}\n`);
    return 0;
  } finally {
    store.close();
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    process.exitCode = runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`fm-event-store: ${error.message}\n`);
    process.exitCode = 1;
  }
}
