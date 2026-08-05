#!/usr/bin/env node
// fm-dashboard-server.mjs - read-only loopback dashboard over fm-fleet-snapshot.sh.
//
// Configuration is environment-only:
//   FM_HOME                            operational home passed to every command
//   FM_DASHBOARD_ADDRESS               127.0.0.1 or ::1 (default 127.0.0.1)
//   FM_DASHBOARD_PORT                  listen port (default 8787)
//   FM_DASHBOARD_POLL_SECONDS          periodic refresh interval (default 5)
//   FM_DASHBOARD_TIMEOUT_SECONDS       hard snapshot deadline (default 15)
//   FM_DASHBOARD_STALE_SECONDS         last-good stale threshold (default 30)
//   FM_DASHBOARD_HISTORY_LIMIT         completion records read per refresh (default 500)
//   FM_DASHBOARD_HISTORY_POLL_SECONDS  history refresh interval (default 60)
//   FM_DASHBOARD_REPORT_MAX_BYTES      report bytes returned per request (default 262144)
//   FM_DASHBOARD_USAGE                 auto|off - presence-gated usage read (default auto)
//   FM_DASHBOARD_EVENTS                auto|off - agent-event ingestion (default auto)
//   FM_DASHBOARD_EVENTS_CONFIG         producer/server shared config file with the
//                                      ingest token (default
//                                      $XDG_CONFIG_HOME/firstmate/dashboard-events.json)
//   FM_DASHBOARD_EVENT_DB              agent-event store path override
//   FM_DASHBOARD_EVENT_RETENTION_HOURS,
//   FM_DASHBOARD_EVENT_MAX_ROWS,
//   FM_DASHBOARD_EVENT_MAX_ROWS_PER_TASK,
//   FM_DASHBOARD_EVENT_SKEW_SECONDS    agent-event retention and replay caps
//
// Every executable and argument list is fixed. This process never accepts a
// command, argument, fleet path, or shell fragment over HTTP. /api/report takes
// a task id, and that id can only ever select among the ids the current durable
// history already published with a retained report - never a caller-supplied
// path.
//
// Completed work is served from the durable completion manifests, which is why
// history survives cleanup and Done-backlog pruning. The token-usage read and
// the semantic-search affordance are both presence-gated: history is fully
// usable with neither present.
//
// POST /events is the ONE write this process performs, and it writes only to the
// dashboard's own agent-event store outside the operational home
// (bin/fm-event-store.mjs owns that path and why). Nothing under data/, state/,
// or projects/ is ever written, which tests/fm-dashboard.test.sh proves by
// fingerprinting those directories around a live server that is accepting
// events. The endpoint is authenticated, byte-capped, deadline-bounded, and
// rate-limited per source before a request body is read at all.

import { spawn } from "node:child_process";
import { readFileSync as fsReadFileSync, statSync as fsStatSync, watch } from "node:fs";
import { lstat, open, readFile, realpath, stat } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { timingSafeEqual } from "node:crypto";
import os from "node:os";
import { fileURLToPath } from "node:url";

import {
  DEFAULT_LIMITS as EVENT_DEFAULTS,
  EventStore,
  INSTRUMENTED_HARNESSES,
  limitsFromEnv as eventLimitsFromEnv,
  resolveStorePath as resolveEventStorePath,
  sanitizeEvent,
  WIRE_SCHEMA as EVENT_WIRE_SCHEMA,
} from "./fm-event-store.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(SCRIPT_DIR, "..");
const SNAPSHOT_COMMAND = path.join(SCRIPT_DIR, "fm-fleet-snapshot.sh");
const HISTORY_COMMAND = path.join(SCRIPT_DIR, "fm-outcome-manifest.sh");
const USAGE_COMMAND = path.join(SCRIPT_DIR, "fm-usage.mjs");
const ASSET_DIR = path.join(ROOT, "assets", "dashboard");
const EXPECTED_SCHEMA = "fm-fleet-snapshot.v1";
const ENVELOPE_SCHEMA = "fm-dashboard-envelope.v1";
const HISTORY_ENVELOPE_SCHEMA = "fm-dashboard-history.v1";
const HISTORY_SCHEMA = "fm-outcome-history.v1";
const USAGE_SCHEMA = "fm-usage-report.v1";
const REPORT_SCHEMA = "fm-dashboard-report.v1";
const EVENTS_ENVELOPE_SCHEMA = "fm-dashboard-events.v1";
const TIMELINE_SCHEMA = "fm-dashboard-timeline.v1";
const INGEST_SCHEMA = "fm-dashboard-ingest.v1";
// One posted document may carry a small batch, and nothing larger is read off
// the socket. A producer that has more to say sends another request.
const EVENT_BODY_MAX_BYTES = 16 * 1024;
const EVENT_BATCH_MAX = 32;
// A body that has not finished arriving by this deadline is abandoned, so a
// stalled or trickling writer cannot hold a request handler open.
const EVENT_BODY_DEADLINE_MS = 2_000;
// The declared source header, read before any body byte, so rate limiting and
// refusal both happen without parsing anything.
const EVENT_SOURCE_PATTERN = /^([A-Za-z0-9_-][A-Za-z0-9._-]{0,127})\/([a-z][a-z0-9-]{0,31})$/;
const EVENT_RATE = { sourceCapacity: 60, sourceRefillPerSecond: 20, globalCapacity: 600, globalRefillPerSecond: 200 };
// Live events are pushed on a short coalescing timer instead of once per accepted
// batch, so a busy fleet cannot turn one browser into a firehose.
const EVENT_BROADCAST_MS = 250;
const STDOUT_LIMIT = 16 * 1024 * 1024;
const STDERR_LIMIT = 64 * 1024;
const SSE_HEARTBEAT_MS = 15_000;
const FILE_DEBOUNCE_MS = 150;
// Exactly bin/fm-pr-lib.sh's fm_task_id_path_safe rule, bounded: no leading dot
// and no character outside the path-safe set, so a validated id can never climb
// out of the data directory.
const TASK_ID_PATTERN = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$/;
// The numeric usage fields this dashboard understands. Anything else the
// collector reports is ignored rather than guessed at.
const USAGE_FIELDS = ["events", "sessions", "input_tokens", "output_tokens",
  "cache_read_tokens", "cache_write_tokens", "reasoning_tokens", "total_tokens"];

const STATIC_FILES = new Map([
  ["/", ["index.html", "text/html; charset=utf-8"]],
  ["/index.html", ["index.html", "text/html; charset=utf-8"]],
  ["/app.js", ["app.js", "text/javascript; charset=utf-8"]],
  ["/inbox.js", ["inbox.js", "text/javascript; charset=utf-8"]],
  ["/history.js", ["history.js", "text/javascript; charset=utf-8"]],
  ["/events.js", ["events.js", "text/javascript; charset=utf-8"]],
  ["/markdown.js", ["markdown.js", "text/javascript; charset=utf-8"]],
  ["/styles.css", ["styles.css", "text/css; charset=utf-8"]],
  ["/favicon.svg", ["favicon.svg", "image/svg+xml"]],
]);

function positiveNumber(name, fallback, { integer = false, maximum = Infinity } = {}) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0 || value > maximum || (integer && !Number.isInteger(value))) {
    throw new Error(`${name} must be a positive${integer ? " integer" : " number"}`);
  }
  return value;
}

function resolveConfig() {
  const address = process.env.FM_DASHBOARD_ADDRESS || "127.0.0.1";
  if (!new Set(["127.0.0.1", "::1"]).has(address)) {
    throw new Error("FM_DASHBOARD_ADDRESS must name a loopback address");
  }
  const usage = process.env.FM_DASHBOARD_USAGE || "auto";
  if (!new Set(["auto", "off"]).has(usage)) {
    throw new Error("FM_DASHBOARD_USAGE must be auto or off");
  }
  const events = process.env.FM_DASHBOARD_EVENTS || "auto";
  if (!new Set(["auto", "off"]).has(events)) {
    throw new Error("FM_DASHBOARD_EVENTS must be auto or off");
  }
  const fmHome = path.resolve(process.env.FM_HOME || ROOT);
  const configRoot = process.env.XDG_CONFIG_HOME || path.join(process.env.HOME || os.homedir(), ".config");
  return {
    fmHome,
    dataDir: path.join(fmHome, "data"),
    address,
    usage,
    events,
    eventsConfigFile: process.env.FM_DASHBOARD_EVENTS_CONFIG
      || path.join(configRoot, "firstmate", "dashboard-events.json"),
    eventStorePath: resolveEventStorePath(fmHome),
    eventLimits: eventLimitsFromEnv(),
    port: positiveNumber("FM_DASHBOARD_PORT", 8787, { integer: true, maximum: 65_535 }),
    pollMs: positiveNumber("FM_DASHBOARD_POLL_SECONDS", 5) * 1000,
    timeoutMs: positiveNumber("FM_DASHBOARD_TIMEOUT_SECONDS", 15) * 1000,
    staleMs: positiveNumber("FM_DASHBOARD_STALE_SECONDS", 30) * 1000,
    historyLimit: positiveNumber("FM_DASHBOARD_HISTORY_LIMIT", 500, { integer: true, maximum: 100_000 }),
    historyPollMs: positiveNumber("FM_DASHBOARD_HISTORY_POLL_SECONDS", 60) * 1000,
    reportMaxBytes: positiveNumber("FM_DASHBOARD_REPORT_MAX_BYTES", 262_144, { integer: true, maximum: 16 * 1024 * 1024 }),
  };
}

function safeText(value, limit = 4_000) {
  return String(value || "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, limit);
}

function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function killProcessTree(child) {
  if (!child) return;
  try {
    if (process.platform === "win32") child.kill("SIGKILL");
    else process.kill(-child.pid, "SIGKILL");
  } catch {
    try { child.kill("SIGKILL"); } catch {}
  }
}

// One JSON-producing child run, with a hard deadline, bounded capture, and a
// kind-tagged failure. Both the fleet snapshot and the durable history read go
// through here so a slow, huge, or broken command fails the same way in both.
function runJsonCommand(command, args, { timeoutMs, env, register = () => {} }) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let timedOut = false;
    let stdoutBytes = 0;
    let stderrBytes = 0;
    const stdout = [];
    const stderr = [];
    const child = spawn(command, args, {
      cwd: ROOT,
      env,
      detached: process.platform !== "win32",
      stdio: ["ignore", "pipe", "pipe"],
    });
    register(child);

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      register(null, child);
      if (error) reject(error);
      else resolve(value);
    };

    const timer = setTimeout(() => {
      timedOut = true;
      killProcessTree(child);
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes <= STDOUT_LIMIT) stdout.push(chunk);
      else killProcessTree(child);
    });
    child.stderr.on("data", (chunk) => {
      if (stderrBytes >= STDERR_LIMIT) return;
      const remaining = STDERR_LIMIT - stderrBytes;
      stderr.push(chunk.subarray(0, remaining));
      stderrBytes += Math.min(chunk.length, remaining);
    });
    child.on("error", (error) => {
      const kind = error.code === "ENOENT" ? "command_missing" : "command_error";
      finish(Object.assign(new Error(error.message), { kind }));
    });
    child.on("close", (code, signal) => {
      const stderrText = Buffer.concat(stderr).toString("utf8");
      if (timedOut) {
        finish(Object.assign(new Error(`command exceeded ${timeoutMs / 1000}s deadline`), {
          kind: "timed_out",
          stderr: stderrText,
        }));
        return;
      }
      if (stdoutBytes > STDOUT_LIMIT) {
        finish(Object.assign(new Error("command output exceeded the safe size limit"), {
          kind: "output_too_large",
          stderr: stderrText,
        }));
        return;
      }
      if (code !== 0) {
        finish(Object.assign(new Error(`command exited ${code ?? signal ?? "unknown"}`), {
          kind: "exit_nonzero",
          stderr: stderrText,
        }));
        return;
      }
      try {
        finish(null, JSON.parse(Buffer.concat(stdout).toString("utf8")));
      } catch (error) {
        finish(Object.assign(new Error(`command returned malformed JSON: ${error.message}`), {
          kind: "malformed_json",
          stderr: stderrText,
        }));
      }
    });
  });
}

function errorRecord(error, fallback) {
  return {
    kind: error.kind || fallback,
    message: safeText(error.message) || fallback,
    stderr: safeText(error.stderr),
    at: nowIso(),
  };
}

// The one set of connected browsers. The snapshot and the history each push
// their own named event onto it, so a browser holds a single stream.
class SseClients {
  constructor() {
    this.set = new Set();
    this.sources = new Map();
    this.sequence = 0;
  }

  register(name, envelope) {
    this.sources.set(name, envelope);
  }

  frame(name) {
    this.sequence += 1;
    return `id: ${this.sequence}\nevent: ${name}\ndata: ${JSON.stringify(this.sources.get(name)())}\n\n`;
  }

  send(name) {
    if (!this.sources.has(name)) return;
    const payload = this.frame(name);
    for (const response of this.set) {
      if (response.writableEnded || response.writableLength > 1024 * 1024) {
        response.end();
        this.set.delete(response);
      } else {
        response.write(payload);
      }
    }
  }

  add(response) {
    this.set.add(response);
    response.write("retry: 1000\n");
    for (const name of this.sources.keys()) response.write(this.frame(name));
  }

  remove(response) {
    this.set.delete(response);
  }

  stop() {
    for (const response of this.set) response.end();
    this.set.clear();
  }
}

// Durable completed-work history, refreshed on its own slower cadence because a
// completion manifest changes only when a task finishes. The optional token
// usage read is attached here so the browser gets one consistent document.
class HistoryState {
  constructor(config, clients) {
    this.config = config;
    this.clients = clients;
    this.lastGood = null;
    this.usage = { available: false, reason: "token usage has not been read yet", source: null, tasks: {} };
    this.lastSuccessAt = null;
    this.lastSuccessAtMs = null;
    this.lastAttemptAt = null;
    this.lastError = null;
    this.refreshing = false;
    this.pending = false;
    this.stopped = false;
    this.timer = null;
    this.activeChild = null;
    this.index = new Map();
  }

  envelope() {
    const ageMs = this.lastSuccessAtMs === null ? null : Math.max(0, Date.now() - this.lastSuccessAtMs);
    let phase = "first_run";
    if (this.lastGood && this.lastError) phase = "last_good";
    else if (this.lastGood) phase = "ready";
    else if (this.lastError) phase = "unavailable";
    return {
      schema: HISTORY_ENVELOPE_SCHEMA,
      status: {
        phase,
        refreshing: this.refreshing,
        stale: Boolean(this.lastGood && this.lastError),
        last_attempt_at: this.lastAttemptAt,
        last_success_at: this.lastSuccessAt,
        last_success_age_seconds: ageMs === null ? null : Math.floor(ageMs / 1000),
        error: this.lastError,
      },
      config: {
        record_limit: this.config.historyLimit,
        poll_interval_seconds: this.config.historyPollMs / 1000,
        report_max_bytes: this.config.reportMaxBytes,
      },
      history: this.lastGood,
      usage: this.usage,
    };
  }

  // The retained-report allowlist. /api/report can only reach a task that the
  // current durable history published with report.present, which is what keeps
  // a caller-supplied id from selecting an arbitrary file.
  reportRecord(id) {
    return this.index.get(id) || null;
  }

  reindex() {
    this.index = new Map();
    for (const record of this.lastGood?.records || []) {
      const id = typeof record?.task_id === "string" ? record.task_id : "";
      if (id) this.index.set(id, record);
    }
  }

  trigger() {
    if (this.stopped) return;
    if (this.refreshing) {
      this.pending = true;
      return;
    }
    void this.refresh();
  }

  async refresh() {
    if (this.refreshing || this.stopped) return;
    this.refreshing = true;
    this.lastAttemptAt = nowIso();
    this.clients.send("history");
    try {
      const document = await runJsonCommand(HISTORY_COMMAND, ["list", "--limit", String(this.config.historyLimit)], {
        timeoutMs: this.config.timeoutMs,
        env: { ...process.env, FM_HOME: this.config.fmHome },
        register: (child, previous) => {
          if (child) this.activeChild = child;
          else if (this.activeChild === previous) this.activeChild = null;
        },
      });
      if (!document || document.schema !== HISTORY_SCHEMA) {
        const actual = document && typeof document.schema === "string" ? document.schema : "missing";
        throw Object.assign(new Error(`expected ${HISTORY_SCHEMA}, received ${actual}`), { kind: "unsupported_schema" });
      }
      this.lastGood = document;
      this.reindex();
      this.lastSuccessAtMs = Date.now();
      this.lastSuccessAt = new Date(this.lastSuccessAtMs).toISOString().replace(/\.\d{3}Z$/, "Z");
      this.lastError = null;
      this.usage = await this.readUsage();
    } catch (error) {
      this.lastError = errorRecord(error, "history_refresh_failed");
    } finally {
      this.refreshing = false;
      this.clients.send("history");
      if (this.pending && !this.stopped) {
        this.pending = false;
        queueMicrotask(() => this.trigger());
      }
    }
  }

  // Token usage is an optional integration owned elsewhere. Its absence, its
  // failure, and an output this dashboard does not recognize all resolve to the
  // same honest answer: unavailable with a reason. None of them ever becomes a
  // zero, because a zero would read as "this task cost nothing".
  async readUsage() {
    if (this.config.usage === "off") {
      return { available: false, reason: "token usage reads are disabled for this dashboard", source: null, tasks: {} };
    }
    try {
      await stat(USAGE_COMMAND);
    } catch {
      return { available: false, reason: "token usage is not collected in this home", source: null, tasks: {} };
    }
    let document;
    try {
      document = await runJsonCommand(USAGE_COMMAND, ["report", "--by", "task", "--limit", String(this.config.historyLimit)], {
        timeoutMs: this.config.timeoutMs,
        env: { ...process.env, FM_HOME: this.config.fmHome },
        register: (child, previous) => {
          if (child) this.activeChild = child;
          else if (this.activeChild === previous) this.activeChild = null;
        },
      });
    } catch (error) {
      return { available: false, reason: `token usage could not be read (${safeText(error.kind || "failed")})`, source: null, tasks: {} };
    }
    if (!document || document.schema !== USAGE_SCHEMA || !Array.isArray(document.rows)) {
      return { available: false, reason: "the token usage report is not a supported schema version", source: null, tasks: {} };
    }
    const tasks = {};
    for (const row of document.rows) {
      const key = typeof row?.key === "string" ? row.key.trim() : "";
      if (!key || !TASK_ID_PATTERN.test(key)) continue;
      const totals = {};
      for (const field of USAGE_FIELDS) {
        if (typeof row[field] === "number" && Number.isFinite(row[field]) && row[field] >= 0) totals[field] = row[field];
      }
      if (typeof row?.cost?.estimated === "number" && Number.isFinite(row.cost.estimated)) {
        totals.cost = {
          estimated: row.cost.estimated,
          currency: typeof row.cost.currency === "string" ? safeText(row.cost.currency, 16) : null,
          unpriced_events: typeof row.cost.unpriced_events === "number" ? row.cost.unpriced_events : null,
        };
      }
      tasks[key] = totals;
    }
    return { available: true, reason: null, source: USAGE_SCHEMA, tasks };
  }

  start() {
    this.timer = setInterval(() => this.trigger(), this.config.historyPollMs);
    this.trigger();
  }

  stop() {
    this.stopped = true;
    killProcessTree(this.activeChild);
    clearInterval(this.timer);
  }
}

// A refilling token bucket. Rate limiting has to be decided before a body is
// read, so it must cost no more than arithmetic on one small map entry.
class RateLimiter {
  constructor(capacity, refillPerSecond, maxKeys = 512) {
    this.capacity = capacity;
    this.refillPerSecond = refillPerSecond;
    this.maxKeys = maxKeys;
    this.buckets = new Map();
  }

  allow(key, now = Date.now()) {
    let bucket = this.buckets.get(key);
    if (!bucket) {
      // An unbounded key space would let a hostile source grow this map instead
      // of hitting the limit. The oldest entry is dropped once the map is full,
      // which at worst gives a long-idle source a fresh bucket.
      if (this.buckets.size >= this.maxKeys) {
        const oldest = this.buckets.keys().next().value;
        this.buckets.delete(oldest);
      }
      bucket = { tokens: this.capacity, at: now };
      this.buckets.set(key, bucket);
    }
    const elapsed = Math.max(0, now - bucket.at) / 1000;
    bucket.tokens = Math.min(this.capacity, bucket.tokens + elapsed * this.refillPerSecond);
    bucket.at = now;
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }
}

// The agent-event timeline: the authenticated ingest boundary, the dashboard's
// own store, and the live tail the browser renders.
//
// Ingestion is presence-gated on the shared config file that carries the token.
// With no config there is no token, so the endpoint accepts nothing and every
// harness degrades to "no event source" - which is also exactly what removing
// the instrumentation leaves behind.
class EventsState {
  constructor(config, clients) {
    this.config = config;
    this.clients = clients;
    this.store = null;
    this.storeError = null;
    this.token = null;
    this.tokenCheckedAtMs = 0;
    this.tokenMtimeMs = null;
    this.tail = [];
    this.lastEventAt = null;
    this.counters = { accepted: 0, duplicate: 0, rejected: 0, throttled: 0, unauthorized: 0, oversized: 0 };
    this.rejections = {};
    this.sourceLimiter = new RateLimiter(EVENT_RATE.sourceCapacity, EVENT_RATE.sourceRefillPerSecond);
    this.globalLimiter = new RateLimiter(EVENT_RATE.globalCapacity, EVENT_RATE.globalRefillPerSecond, 1);
    this.broadcastTimer = null;
    this.stopped = false;
  }

  get enabled() {
    return this.config.events !== "off";
  }

  // The token is re-read when its file changes, so rotating it does not need a
  // restart, and a check costs one stat at most once a second.
  readToken() {
    if (!this.enabled) return null;
    const now = Date.now();
    if (now - this.tokenCheckedAtMs < 1000) return this.token;
    this.tokenCheckedAtMs = now;
    let info;
    try {
      info = fsStatSync(this.config.eventsConfigFile);
    } catch {
      this.token = null;
      this.tokenMtimeMs = null;
      return null;
    }
    if (this.tokenMtimeMs === info.mtimeMs && this.token) return this.token;
    this.tokenMtimeMs = info.mtimeMs;
    try {
      const parsed = JSON.parse(fsReadFileSync(this.config.eventsConfigFile, "utf8"));
      const token = typeof parsed?.token === "string" ? parsed.token.trim() : "";
      this.token = token.length >= 16 ? token : null;
    } catch {
      this.token = null;
    }
    return this.token;
  }

  openStore() {
    if (this.store || this.storeError || !this.enabled) return this.store;
    try {
      this.store = new EventStore(this.config.eventStorePath, this.config.eventLimits);
      this.tail = this.store.tail();
      this.lastEventAt = this.tail[0]?.occurred_at ?? null;
    } catch (error) {
      this.storeError = errorRecord(error, "event_store_unavailable");
    }
    return this.store;
  }

  status() {
    if (!this.enabled) {
      return { ingestion: "off", reason: "agent-event ingestion is disabled for this dashboard" };
    }
    if (this.storeError) {
      return { ingestion: "unavailable", reason: this.storeError.message, error: this.storeError };
    }
    if (!this.readToken()) {
      return { ingestion: "disabled", reason: "no instrumentation is configured in this home, so no agent reports events" };
    }
    return { ingestion: "ready", reason: null };
  }

  envelope() {
    return {
      schema: EVENTS_ENVELOPE_SCHEMA,
      status: {
        ...this.status(),
        last_event_at: this.lastEventAt,
        counters: { ...this.counters },
        rejections: { ...this.rejections },
      },
      config: {
        retention_hours: this.config.eventLimits.retentionHours,
        max_rows: this.config.eventLimits.maxRows,
        max_rows_per_task: this.config.eventLimits.maxRowsPerTask,
        tail_limit: EVENT_DEFAULTS.tailLimit,
        batch_max: EVENT_BATCH_MAX,
        body_max_bytes: EVENT_BODY_MAX_BYTES,
      },
      instrumented_harnesses: INSTRUMENTED_HARNESSES,
      events: this.tail,
    };
  }

  countRejection(reason) {
    this.counters.rejected += 1;
    this.rejections[reason] = (this.rejections[reason] || 0) + 1;
  }

  scheduleBroadcast() {
    if (this.stopped || this.broadcastTimer) return;
    this.broadcastTimer = setTimeout(() => {
      this.broadcastTimer = null;
      this.clients.send("agent_events");
    }, EVENT_BROADCAST_MS);
  }

  accept(events, receivedAt) {
    const store = this.openStore();
    if (!store) return null;
    const result = store.insert(events, receivedAt);
    if (result.stored > 0) {
      store.prune(Math.floor(Date.now() / 1000));
      this.tail = store.tail();
      this.lastEventAt = this.tail[0]?.occurred_at ?? null;
      this.scheduleBroadcast();
    }
    this.counters.accepted += result.stored;
    this.counters.duplicate += result.duplicate;
    return result;
  }

  timeline(taskId) {
    const store = this.openStore();
    if (!store) return [];
    return taskId ? store.forTask(taskId) : store.tail();
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.broadcastTimer);
    this.store?.close();
  }
}

class DashboardState {
  constructor(config, clients, history) {
    this.config = config;
    this.clients = clients;
    this.history = history;
    this.lastGood = null;
    this.lastSuccessAt = null;
    this.lastSuccessAtMs = null;
    this.lastAttemptAt = null;
    this.lastError = null;
    this.refreshing = false;
    this.pending = false;
    this.watchers = [];
    this.fileTimer = null;
    this.pollTimer = null;
    this.heartbeatTimer = null;
    this.staleTimer = null;
    this.stopped = false;
    this.activeChild = null;
    this.durablePending = false;
  }

  envelope() {
    const ageMs = this.lastSuccessAtMs === null ? null : Math.max(0, Date.now() - this.lastSuccessAtMs);
    const ageSeconds = ageMs !== null
      ? Math.floor(ageMs / 1000)
      : null;
    const thresholdStale = ageMs !== null && ageMs >= this.config.staleMs;
    const stale = this.lastGood !== null && (this.lastError !== null || thresholdStale);
    let phase = "first_run";
    if (this.lastGood && stale) phase = "last_good";
    else if (this.lastGood) phase = "ready";
    else if (this.lastError) phase = "unavailable";
    return {
      schema: ENVELOPE_SCHEMA,
      sequence: this.clients.sequence,
      status: {
        phase,
        refreshing: this.refreshing,
        stale,
        last_attempt_at: this.lastAttemptAt,
        last_success_at: this.lastSuccessAt,
        last_success_age_seconds: ageSeconds,
        error: this.lastError,
      },
      config: {
        poll_interval_seconds: this.config.pollMs / 1000,
        timeout_seconds: this.config.timeoutMs / 1000,
        stale_threshold_seconds: this.config.staleMs / 1000,
      },
      snapshot: this.lastGood,
    };
  }

  broadcast() {
    this.clients.send("snapshot");
  }

  scheduleStaleTransition() {
    clearTimeout(this.staleTimer);
    this.staleTimer = null;
    if (this.stopped || !this.lastGood || this.lastError || this.lastSuccessAtMs === null) return;
    const remaining = this.lastSuccessAtMs + this.config.staleMs - Date.now();
    this.staleTimer = setTimeout(() => {
      this.staleTimer = null;
      if (this.stopped || !this.lastGood || this.lastError || this.lastSuccessAtMs === null) return;
      if (Date.now() < this.lastSuccessAtMs + this.config.staleMs) {
        this.scheduleStaleTransition();
        return;
      }
      this.broadcast();
    }, Math.min(Math.max(0, remaining), 2_147_483_647));
  }

  trigger(source, durable = false) {
    if (this.stopped) return;
    if (source === "file") {
      // Only data/ can carry a completion manifest. state/<id>.status is
      // appended continuously by every live agent, so a shared trigger would
      // keep re-reading the whole durable archive for events that cannot
      // change it.
      if (durable) this.durablePending = true;
      clearTimeout(this.fileTimer);
      this.fileTimer = setTimeout(() => this.trigger("file-debounced"), FILE_DEBOUNCE_MS);
      return;
    }
    // A completion manifest lands under data/, so the same debounced
    // notification is what makes newly finished work appear in history without
    // a reload. Sharing the debounce keeps a burst of writes from turning into
    // a burst of history reads.
    if (source === "file-debounced" && this.durablePending) {
      this.durablePending = false;
      this.history?.trigger();
    }
    if (this.refreshing) {
      this.pending = true;
      return;
    }
    void this.refresh();
  }

  async refresh() {
    if (this.refreshing || this.stopped) return;
    this.refreshing = true;
    this.lastAttemptAt = nowIso();
    this.broadcast();
    try {
      const snapshot = await this.runSnapshot();
      if (!snapshot || snapshot.schema !== EXPECTED_SCHEMA) {
        const actual = snapshot && typeof snapshot.schema === "string" ? snapshot.schema : "missing";
        throw Object.assign(new Error(`expected ${EXPECTED_SCHEMA}, received ${actual}`), {
          kind: "unsupported_schema",
        });
      }
      this.lastGood = snapshot;
      this.lastSuccessAtMs = Date.now();
      this.lastSuccessAt = new Date(this.lastSuccessAtMs).toISOString().replace(/\.\d{3}Z$/, "Z");
      this.lastError = null;
    } catch (error) {
      this.lastError = errorRecord(error, "snapshot_failed");
    } finally {
      this.refreshing = false;
      this.scheduleStaleTransition();
      this.broadcast();
      if (this.pending && !this.stopped) {
        this.pending = false;
        queueMicrotask(() => this.trigger("coalesced"));
      }
    }
  }

  runSnapshot() {
    return runJsonCommand(SNAPSHOT_COMMAND, ["--json"], {
      timeoutMs: this.config.timeoutMs,
      env: { ...process.env, FM_HOME: this.config.fmHome },
      register: (child, previous) => {
        if (child) this.activeChild = child;
        else if (this.activeChild === previous) this.activeChild = null;
      },
    });
  }

  async start() {
    this.pollTimer = setInterval(() => this.trigger("poll"), this.config.pollMs);
    this.heartbeatTimer = setInterval(() => {
      for (const response of this.clients.set) response.write(`: heartbeat ${Date.now()}\n\n`);
    }, SSE_HEARTBEAT_MS);
    for (const name of ["data", "state", "projects"]) {
      const directory = path.join(this.config.fmHome, name);
      try {
        const info = await stat(directory);
        if (!info.isDirectory()) continue;
        const watcher = watch(directory, { persistent: false }, () => this.trigger("file", name === "data"));
        watcher.on("error", () => {});
        this.watchers.push(watcher);
      } catch {
        // Missing first-run directories are expected; polling remains authoritative.
      }
    }
    this.trigger("startup");
  }

  stop() {
    this.stopped = true;
    killProcessTree(this.activeChild);
    clearInterval(this.pollTimer);
    clearInterval(this.heartbeatTimer);
    clearTimeout(this.fileTimer);
    clearTimeout(this.staleTimer);
    for (const watcher of this.watchers) watcher.close();
  }
}

function securityHeaders(response) {
  response.setHeader("Content-Security-Policy", "default-src 'self'; connect-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("X-Frame-Options", "DENY");
}

async function serveStatic(request, response) {
  const pathname = new URL(request.url, "http://loopback.invalid").pathname;
  const entry = STATIC_FILES.get(pathname);
  if (!entry) return false;
  const [filename, contentType] = entry;
  try {
    const content = await readFile(path.join(ASSET_DIR, filename));
    response.writeHead(200, { "Content-Type": contentType, "Cache-Control": "no-cache" });
    response.end(content);
  } catch {
    response.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("dashboard asset unavailable\n");
  }
  return true;
}

function sendJson(response, status, body) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  response.end(`${JSON.stringify(body)}\n`);
}

// Serve one retained scout report as raw Markdown for the browser to render.
//
// The task id is the only caller-supplied input, and it can select nothing on
// its own: it must match the path-safe pattern AND name a task the current
// durable history already published with a retained report. The file path is
// then derived from this server's own data directory, never from the manifest's
// recorded path, which was written by whichever home completed the task. The
// resolved file must be a regular file that still lives inside that directory,
// so neither a symlink nor a manifest from elsewhere can point the read out.
async function serveReport(request, response, history, config) {
  const id = new URL(request.url, "http://loopback.invalid").searchParams.get("task") || "";
  if (!TASK_ID_PATTERN.test(id) || id.includes("..")) {
    sendJson(response, 400, { schema: REPORT_SCHEMA, task_id: null, present: false, reason: "invalid_task_id" });
    return;
  }
  if (!history.lastGood) {
    sendJson(response, 503, { schema: REPORT_SCHEMA, task_id: id, present: false, reason: "history_unavailable" });
    return;
  }
  const record = history.reportRecord(id);
  if (!record) {
    sendJson(response, 404, { schema: REPORT_SCHEMA, task_id: id, present: false, reason: "unknown_task" });
    return;
  }
  if (record?.report?.present !== true) {
    sendJson(response, 404, { schema: REPORT_SCHEMA, task_id: id, present: false, reason: "no_retained_report" });
    return;
  }

  const file = path.join(config.dataDir, id, "report.md");
  let size = 0;
  let truncated = false;
  let text;
  // The containment check and the read that trusts it belong to the same
  // guarded block. Cleanup can remove the directory between them, and a read
  // that failed after the check would otherwise reject with nobody to catch it.
  try {
    const info = await lstat(file);
    if (!info.isFile()) throw new Error("not a regular file");
    const [resolved, dataRoot] = await Promise.all([realpath(file), realpath(config.dataDir)]);
    if (resolved !== path.join(dataRoot, id, "report.md")) throw new Error("resolved outside the data directory");
    size = info.size;
    truncated = size > config.reportMaxBytes;
    if (truncated) {
      const handle = await open(file, "r");
      try {
        const buffer = Buffer.alloc(config.reportMaxBytes);
        const { bytesRead } = await handle.read(buffer, 0, config.reportMaxBytes, 0);
        text = new TextDecoder("utf-8").decode(buffer.subarray(0, bytesRead));
      } finally {
        await handle.close();
      }
    } else {
      text = new TextDecoder("utf-8").decode(await readFile(file));
    }
  } catch {
    sendJson(response, 404, {
      schema: REPORT_SCHEMA,
      task_id: id,
      present: false,
      // The manifest says a report was retained and the file is gone, is no
      // longer a plain file, or cannot be read. That is a fact worth showing,
      // not a blank panel.
      reason: "report_missing",
      recorded_path: typeof record.report.path === "string" ? record.report.path : null,
    });
    return;
  }

  sendJson(response, 200, {
    schema: REPORT_SCHEMA,
    task_id: id,
    present: true,
    bytes: size,
    truncated,
    max_bytes: config.reportMaxBytes,
    recorded_path: typeof record.report.path === "string" ? record.report.path : null,
    text,
  });
}

// Constant-time comparison over equal-length buffers, so a wrong token never
// leaks how much of it was right.
function tokenMatches(presented, expected) {
  if (typeof presented !== "string" || typeof expected !== "string") return false;
  const a = Buffer.from(presented, "utf8");
  const b = Buffer.from(expected, "utf8");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

// Read a bounded body under a deadline, refusing as soon as either bound is
// crossed rather than after the fact. Returns null once the response has been
// answered, so the caller stops.
function readBoundedBody(request, response) {
  return new Promise((resolve) => {
    let bytes = 0;
    const chunks = [];
    let settled = false;
    const finish = (value, status, body) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      request.removeAllListeners("data");
      request.removeAllListeners("end");
      request.removeAllListeners("error");
      if (status) {
        sendJson(response, status, body);
        request.destroy();
        resolve(null);
        return;
      }
      resolve(value);
    };
    const timer = setTimeout(
      () => finish(null, 408, { schema: INGEST_SCHEMA, accepted: 0, reason: "body_deadline" }),
      EVENT_BODY_DEADLINE_MS,
    );
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > EVENT_BODY_MAX_BYTES) {
        finish(null, 413, { schema: INGEST_SCHEMA, accepted: 0, reason: "body_too_large", max_bytes: EVENT_BODY_MAX_BYTES });
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => finish(Buffer.concat(chunks).toString("utf8")));
    request.on("error", () => finish(null, 400, { schema: INGEST_SCHEMA, accepted: 0, reason: "read_failed" }));
  });
}

// POST /events - the authenticated agent-event ingest boundary.
//
// The cheap refusals come first and cost no body read: ingestion off, no
// configured token, a wrong or missing bearer token, a malformed source header,
// and a throttled source are all answered before a single body byte is
// accepted. Only then is a bounded, deadline-limited body read, and only
// allowlisted fields of it are ever looked at.
async function serveIngest(request, response, events) {
  if (!events.enabled) {
    sendJson(response, 503, { schema: INGEST_SCHEMA, accepted: 0, reason: "ingestion_off" });
    request.destroy();
    return;
  }
  const expected = events.readToken();
  if (!expected) {
    sendJson(response, 503, { schema: INGEST_SCHEMA, accepted: 0, reason: "ingestion_not_configured" });
    request.destroy();
    return;
  }
  const authorization = request.headers.authorization;
  const presented = typeof authorization === "string" && authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : "";
  if (!tokenMatches(presented, expected)) {
    events.counters.unauthorized += 1;
    response.setHeader("WWW-Authenticate", "Bearer");
    sendJson(response, 401, { schema: INGEST_SCHEMA, accepted: 0, reason: "unauthorized" });
    request.destroy();
    return;
  }
  const declared = String(request.headers["x-firstmate-source"] || "");
  const source = EVENT_SOURCE_PATTERN.exec(declared);
  if (!source) {
    sendJson(response, 400, { schema: INGEST_SCHEMA, accepted: 0, reason: "invalid_source_header" });
    request.destroy();
    return;
  }
  const [, sourceTask, sourceHarness] = source;
  if (!events.globalLimiter.allow("global") || !events.sourceLimiter.allow(declared)) {
    events.counters.throttled += 1;
    response.setHeader("Retry-After", "1");
    sendJson(response, 429, { schema: INGEST_SCHEMA, accepted: 0, reason: "rate_limited" });
    request.destroy();
    return;
  }
  const declaredLength = Number(request.headers["content-length"]);
  if (Number.isFinite(declaredLength) && declaredLength > EVENT_BODY_MAX_BYTES) {
    events.counters.oversized += 1;
    sendJson(response, 413, { schema: INGEST_SCHEMA, accepted: 0, reason: "body_too_large", max_bytes: EVENT_BODY_MAX_BYTES });
    request.destroy();
    return;
  }

  const raw = await readBoundedBody(request, response);
  if (raw === null) {
    events.counters.oversized += 1;
    return;
  }
  let document;
  try {
    document = JSON.parse(raw);
  } catch {
    events.countRejection("malformed_json");
    sendJson(response, 400, { schema: INGEST_SCHEMA, accepted: 0, reason: "malformed_json" });
    return;
  }
  if (!document || document.schema !== EVENT_WIRE_SCHEMA || !Array.isArray(document.events)) {
    events.countRejection("unsupported_schema");
    sendJson(response, 400, { schema: INGEST_SCHEMA, accepted: 0, reason: "unsupported_schema", expected: EVENT_WIRE_SCHEMA });
    return;
  }
  if (document.events.length === 0 || document.events.length > EVENT_BATCH_MAX) {
    events.countRejection("invalid_batch_size");
    sendJson(response, 400, { schema: INGEST_SCHEMA, accepted: 0, reason: "invalid_batch_size", batch_max: EVENT_BATCH_MAX });
    return;
  }

  const nowEpoch = Math.floor(Date.now() / 1000);
  const accepted = [];
  const rejected = [];
  for (const candidate of document.events) {
    const result = sanitizeEvent(candidate, { nowEpoch, skewSeconds: events.config.eventLimits.skewSeconds });
    if (result.rejected) {
      events.countRejection(result.rejected);
      rejected.push(result.rejected);
      continue;
    }
    // The declared source is what was rate-limited, so an event that claims a
    // different task or harness would spend someone else's budget.
    if (result.event.task_id !== sourceTask || result.event.harness !== sourceHarness) {
      events.countRejection("source_mismatch");
      rejected.push("source_mismatch");
      continue;
    }
    accepted.push(result.event);
  }

  if (accepted.length === 0) {
    sendJson(response, 422, { schema: INGEST_SCHEMA, accepted: 0, duplicate: 0, rejected });
    return;
  }
  let stored;
  try {
    stored = events.accept(accepted, nowIso());
  } catch (error) {
    sendJson(response, 503, { schema: INGEST_SCHEMA, accepted: 0, reason: "store_write_failed", detail: safeText(error.message) });
    return;
  }
  if (!stored) {
    sendJson(response, 503, { schema: INGEST_SCHEMA, accepted: 0, reason: "store_unavailable" });
    return;
  }
  sendJson(response, 202, { schema: INGEST_SCHEMA, accepted: stored.stored, duplicate: stored.duplicate, rejected });
}

function serveTimeline(request, response, events) {
  const requested = new URL(request.url, "http://loopback.invalid").searchParams.get("task") || "";
  if (requested && (!TASK_ID_PATTERN.test(requested) || requested.includes(".."))) {
    sendJson(response, 400, { schema: TIMELINE_SCHEMA, task_id: null, events: [], reason: "invalid_task_id" });
    return;
  }
  sendJson(response, 200, {
    schema: TIMELINE_SCHEMA,
    task_id: requested || null,
    status: events.status(),
    instrumented_harnesses: INSTRUMENTED_HARNESSES,
    events: events.timeline(requested || null),
  });
}

async function main() {
  const config = resolveConfig();
  const clients = new SseClients();
  const history = new HistoryState(config, clients);
  const events = new EventsState(config, clients);
  const state = new DashboardState(config, clients, history);
  clients.register("snapshot", () => state.envelope());
  clients.register("history", () => history.envelope());
  clients.register("agent_events", () => events.envelope());
  const server = http.createServer(async (request, response) => {
    securityHeaders(response);
    const pathname = new URL(request.url, "http://loopback.invalid").pathname;
    if (request.method === "POST" && pathname === "/events") {
      await serveIngest(request, response, events);
      return;
    }
    if (request.method !== "GET") {
      response.writeHead(405, { Allow: "GET, POST", "Content-Type": "text/plain; charset=utf-8" });
      response.end("method not allowed\n");
      return;
    }
    if (pathname === "/api/snapshot") {
      response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      response.end(`${JSON.stringify(state.envelope())}\n`);
      return;
    }
    if (pathname === "/api/history") {
      response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      response.end(`${JSON.stringify(history.envelope())}\n`);
      return;
    }
    if (pathname === "/api/report") {
      await serveReport(request, response, history, config);
      return;
    }
    if (pathname === "/api/timeline") {
      serveTimeline(request, response, events);
      return;
    }
    if (pathname === "/api/events") {
      response.writeHead(200, {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-store",
        Connection: "keep-alive",
      });
      clients.add(response);
      request.on("close", () => clients.remove(response));
      return;
    }
    if (await serveStatic(request, response)) return;
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("not found\n");
  });

  server.on("error", (error) => {
    console.error(`fm-dashboard: ${safeText(error.message)}`);
    process.exitCode = 1;
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.port, config.address, resolve);
  });
  server.removeAllListeners("error");
  server.on("error", (error) => console.error(`fm-dashboard: ${safeText(error.message)}`));
  await state.start();
  history.start();
  console.log(`fm-dashboard: listening on http://${config.address.includes(":") ? `[${config.address}]` : config.address}:${config.port}`);

  const shutdown = () => {
    state.stop();
    history.stop();
    events.stop();
    clients.stop();
    server.close(() => process.exit(0));
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

// Every request handler is an async callback, so a rejection one of them fails
// to catch would reach Node's default --unhandled-rejections=throw and take the
// whole view down. A read-only loopback dashboard reports the request it could
// not answer and keeps serving the rest.
process.on("unhandledRejection", (error) => {
  console.error(`fm-dashboard: unhandled rejection: ${safeText(error instanceof Error ? error.message : String(error))}`);
});

// One non-serving mode: print where this configuration would keep its
// agent-event store. The installer needs that path to grant the hardened user
// service write access to exactly that directory and nothing else, and a single
// owner of the rule beats two programs deriving it.
if (process.argv.includes("--event-store-path")) {
  const fmHome = path.resolve(process.env.FM_HOME || ROOT);
  console.log(resolveEventStorePath(fmHome));
} else {
  main().catch((error) => {
    console.error(`fm-dashboard: ${safeText(error.message)}`);
    process.exit(1);
  });
}
