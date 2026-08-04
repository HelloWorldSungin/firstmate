#!/usr/bin/env node
// fm-dashboard-server.mjs - read-only loopback dashboard over fm-fleet-snapshot.sh.
//
// Configuration is environment-only:
//   FM_HOME                         operational home passed to the snapshot command
//   FM_DASHBOARD_ADDRESS            127.0.0.1 or ::1 (default 127.0.0.1)
//   FM_DASHBOARD_PORT               listen port (default 8787)
//   FM_DASHBOARD_POLL_SECONDS       periodic refresh interval (default 5)
//   FM_DASHBOARD_TIMEOUT_SECONDS    hard snapshot deadline (default 15)
//   FM_DASHBOARD_STALE_SECONDS      last-good stale threshold (default 30)
//
// The executable and argument list are fixed. This process never accepts a
// command, argument, fleet path, or shell fragment over HTTP.

import { spawn } from "node:child_process";
import { watch } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(SCRIPT_DIR, "..");
const SNAPSHOT_COMMAND = path.join(SCRIPT_DIR, "fm-fleet-snapshot.sh");
const ASSET_DIR = path.join(ROOT, "assets", "dashboard");
const EXPECTED_SCHEMA = "fm-fleet-snapshot.v1";
const ENVELOPE_SCHEMA = "fm-dashboard-envelope.v1";
const STDOUT_LIMIT = 16 * 1024 * 1024;
const STDERR_LIMIT = 64 * 1024;
const SSE_HEARTBEAT_MS = 15_000;
const FILE_DEBOUNCE_MS = 150;

const STATIC_FILES = new Map([
  ["/", ["index.html", "text/html; charset=utf-8"]],
  ["/index.html", ["index.html", "text/html; charset=utf-8"]],
  ["/app.js", ["app.js", "text/javascript; charset=utf-8"]],
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
  return {
    fmHome: path.resolve(process.env.FM_HOME || ROOT),
    address,
    port: positiveNumber("FM_DASHBOARD_PORT", 8787, { integer: true, maximum: 65_535 }),
    pollMs: positiveNumber("FM_DASHBOARD_POLL_SECONDS", 5) * 1000,
    timeoutMs: positiveNumber("FM_DASHBOARD_TIMEOUT_SECONDS", 15) * 1000,
    staleMs: positiveNumber("FM_DASHBOARD_STALE_SECONDS", 30) * 1000,
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

class DashboardState {
  constructor(config) {
    this.config = config;
    this.lastGood = null;
    this.lastSuccessAt = null;
    this.lastSuccessAtMs = null;
    this.lastAttemptAt = null;
    this.lastError = null;
    this.refreshing = false;
    this.pending = false;
    this.sequence = 0;
    this.clients = new Set();
    this.watchers = [];
    this.fileTimer = null;
    this.pollTimer = null;
    this.heartbeatTimer = null;
    this.staleTimer = null;
    this.stopped = false;
    this.activeChild = null;
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
      sequence: this.sequence,
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
    this.sequence += 1;
    const payload = `id: ${this.sequence}\nevent: snapshot\ndata: ${JSON.stringify(this.envelope())}\n\n`;
    for (const response of this.clients) {
      if (response.writableEnded || response.writableLength > 1024 * 1024) {
        response.end();
        this.clients.delete(response);
      } else {
        response.write(payload);
      }
    }
  }

  addClient(response) {
    this.clients.add(response);
    response.write("retry: 1000\n");
    response.write(`id: ${this.sequence}\nevent: snapshot\ndata: ${JSON.stringify(this.envelope())}\n\n`);
  }

  removeClient(response) {
    this.clients.delete(response);
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

  trigger(source) {
    if (this.stopped) return;
    if (source === "file") {
      clearTimeout(this.fileTimer);
      this.fileTimer = setTimeout(() => this.trigger("file-debounced"), FILE_DEBOUNCE_MS);
      return;
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
      this.lastError = {
        kind: error.kind || "snapshot_failed",
        message: safeText(error.message) || "snapshot refresh failed",
        stderr: safeText(error.stderr),
        at: nowIso(),
      };
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
    return new Promise((resolve, reject) => {
      let settled = false;
      let timedOut = false;
      let stdoutBytes = 0;
      let stderrBytes = 0;
      const stdout = [];
      const stderr = [];
      const child = spawn(SNAPSHOT_COMMAND, ["--json"], {
        cwd: ROOT,
        env: { ...process.env, FM_HOME: this.config.fmHome },
        detached: process.platform !== "win32",
        stdio: ["ignore", "pipe", "pipe"],
      });
      this.activeChild = child;

      const finish = (error, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (this.activeChild === child) this.activeChild = null;
        if (error) reject(error);
        else resolve(value);
      };

      const timer = setTimeout(() => {
        timedOut = true;
        killProcessTree(child);
      }, this.config.timeoutMs);

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
          finish(Object.assign(new Error(`snapshot exceeded ${this.config.timeoutMs / 1000}s deadline`), {
            kind: "timed_out",
            stderr: stderrText,
          }));
          return;
        }
        if (stdoutBytes > STDOUT_LIMIT) {
          finish(Object.assign(new Error("snapshot output exceeded the safe size limit"), {
            kind: "output_too_large",
            stderr: stderrText,
          }));
          return;
        }
        if (code !== 0) {
          finish(Object.assign(new Error(`snapshot exited ${code ?? signal ?? "unknown"}`), {
            kind: "exit_nonzero",
            stderr: stderrText,
          }));
          return;
        }
        try {
          finish(null, JSON.parse(Buffer.concat(stdout).toString("utf8")));
        } catch (error) {
          finish(Object.assign(new Error(`snapshot returned malformed JSON: ${error.message}`), {
            kind: "malformed_json",
            stderr: stderrText,
          }));
        }
      });
    });
  }

  async start() {
    this.pollTimer = setInterval(() => this.trigger("poll"), this.config.pollMs);
    this.heartbeatTimer = setInterval(() => {
      for (const response of this.clients) response.write(`: heartbeat ${Date.now()}\n\n`);
    }, SSE_HEARTBEAT_MS);
    for (const directory of ["data", "state", "projects"].map((name) => path.join(this.config.fmHome, name))) {
      try {
        const info = await stat(directory);
        if (!info.isDirectory()) continue;
        const watcher = watch(directory, { persistent: false }, () => this.trigger("file"));
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
    for (const response of this.clients) response.end();
    this.clients.clear();
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

async function main() {
  const config = resolveConfig();
  const state = new DashboardState(config);
  const server = http.createServer(async (request, response) => {
    securityHeaders(response);
    if (request.method !== "GET") {
      response.writeHead(405, { Allow: "GET", "Content-Type": "text/plain; charset=utf-8" });
      response.end("method not allowed\n");
      return;
    }
    const pathname = new URL(request.url, "http://loopback.invalid").pathname;
    if (pathname === "/api/snapshot") {
      response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      response.end(`${JSON.stringify(state.envelope())}\n`);
      return;
    }
    if (pathname === "/api/events") {
      response.writeHead(200, {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-store",
        Connection: "keep-alive",
      });
      state.addClient(response);
      request.on("close", () => state.removeClient(response));
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
  console.log(`fm-dashboard: listening on http://${config.address.includes(":") ? `[${config.address}]` : config.address}:${config.port}`);

  const shutdown = () => {
    state.stop();
    server.close(() => process.exit(0));
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

main().catch((error) => {
  console.error(`fm-dashboard: ${safeText(error.message)}`);
  process.exit(1);
});
