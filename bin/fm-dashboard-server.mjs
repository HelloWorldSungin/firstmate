#!/usr/bin/env node
// fm-dashboard-server.mjs - read-only dashboard over fm-fleet-snapshot.sh.
//
// Configuration is environment-only:
//   FM_HOME                            operational home passed to every command
//   FM_DASHBOARD_ADDRESS               numeric bind address (default 127.0.0.1).
//                                      Anything other than 127.0.0.1 or ::1
//                                      refuses to start without credentials.
//   FM_DASHBOARD_AUTH                  auto|off - off is loopback-only (default auto)
//   FM_DASHBOARD_AUTH_FILE             credentials file with the salted password
//                                      digest (default
//                                      $XDG_CONFIG_HOME/firstmate/dashboard-auth.json)
//   FM_DASHBOARD_TRUSTED_PROXIES       comma-separated numeric addresses or CIDR
//                                      ranges whose X-Forwarded-For this server
//                                      believes when deciding which client an
//                                      authentication attempt is throttled as
//                                      (default empty: no forwarded header is
//                                      read and the peer address is the client)
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
// Endpoints: GET / (the app), GET /api/snapshot (fleet state), GET
// /api/history (durable completion records with usage), GET /api/backlog
// (the full backlog record set, read-only, derived from the same snapshot
// parse), GET /api/report?task=<id> (a retained report from durable history),
// GET /api/timeline (recorded agent events), GET /api/gbrain/health, POST
// /api/gbrain/search, GET /api/events (SSE), POST /events (ingest).
//
// Every executable and flag list is fixed. This process never accepts a
// command, a flag, a fleet path, or a shell fragment over HTTP. /api/report
// takes a task id, and that id can only ever select among the ids the current
// durable history already published with a retained report - never a
// caller-supplied path. POST /api/gbrain/search takes the operator's query,
// which is the one caller-supplied value that reaches a child at all: it is
// size-capped and handed to the fixed fm-recall.sh wrapper as bounded argv
// elements after --, so it can never become a flag, a path, or shell syntax.
//
// Completed work is served from the durable completion manifests, which is why
// history survives cleanup and Done-backlog pruning. The token-usage read and
// the semantic-search affordance are both presence-gated: history is fully
// usable with neither present.
//
// Exposure is opt-in and it is never a bind-address change alone. Loopback stays
// the default, and a bind beyond loopback refuses to start unless credentials
// are configured, so the reachable-from-the-network case and the authenticated
// case cannot come apart. docs/dashboard-remote-access.md owns the posture.
//
// POST /events is the ONE write this process performs, and it writes only to the
// dashboard's own agent-event store outside the operational home
// (bin/fm-event-store.mjs owns that path and why). Nothing under data/, state/,
// or projects/ is ever written, which tests/fm-dashboard.test.sh proves by
// fingerprinting those directories around a live server that is accepting
// events. The endpoint is authenticated, byte-capped, deadline-bounded, and
// rate-limited per source before a request body is read at all.
//
// The one thing written under an operational home is written by a child rather
// than here: a GBrain search updates the index it reads, so the installed unit
// grants data/gbrain/ and nothing else under data/.
// docs/dashboard-events.md owns that grant and why it does not widen the rule
// above.

import { spawn } from "node:child_process";
import { accessSync as fsAccessSync, constants as fsConstants, readFileSync as fsReadFileSync, statSync as fsStatSync, watch } from "node:fs";
import { lstat, open, readFile, realpath, stat } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import { createHash, randomBytes, scrypt, timingSafeEqual } from "node:crypto";
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
import { displayError } from "../assets/dashboard/errors.js";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(SCRIPT_DIR, "..");
const SNAPSHOT_COMMAND = path.join(SCRIPT_DIR, "fm-fleet-snapshot.sh");
const HISTORY_COMMAND = path.join(SCRIPT_DIR, "fm-outcome-manifest.sh");
const USAGE_COMMAND = path.join(SCRIPT_DIR, "fm-usage.mjs");
const USAGE_DB_FILE = "usage.db";
const ASSET_DIR = path.join(ROOT, "assets", "dashboard");
const EXPECTED_SCHEMA = "fm-fleet-snapshot.v1";
const ENVELOPE_SCHEMA = "fm-dashboard-envelope.v1";
const HISTORY_ENVELOPE_SCHEMA = "fm-dashboard-history.v1";
const BACKLOG_ENVELOPE_SCHEMA = "fm-dashboard-backlog.v1";
const HISTORY_SCHEMA = "fm-outcome-history.v1";
const USAGE_SCHEMA = "fm-usage-report.v1";
const REPORT_SCHEMA = "fm-dashboard-report.v1";
const EVENTS_ENVELOPE_SCHEMA = "fm-dashboard-events.v1";
const TIMELINE_SCHEMA = "fm-dashboard-timeline.v1";
const INGEST_SCHEMA = "fm-dashboard-ingest.v1";
const AUTH_SCHEMA = "fm-dashboard-auth.v1";
const AUTH_DENIAL_SCHEMA = "fm-dashboard-access.v1";
const SERVICE_UNIT_NAME = "firstmate-dashboard.service";
const SERVICE_UNIT_CONTRACT = "runtime-scratch-v1";
const AUTH_REALM = "Firstmate fleet dashboard";
// The two addresses that reach nothing off this host. Every other bind is an
// exposure, and exposure is gated on configured credentials.
const LOOPBACK_ADDRESSES = new Set(["127.0.0.1", "::1"]);
// The binds that already answer on 127.0.0.1 without a second listener: either
// wildcard, loopback itself, and every other spelling of those. net.BlockList
// does the parsing, so ::, 0:0:0:0:0:0:0:0 and ::ffff:0.0.0.0 are one answer.
const LOOPBACK_COVERING_BINDS = new net.BlockList();
LOOPBACK_COVERING_BINDS.addAddress("127.0.0.1", "ipv4");
LOOPBACK_COVERING_BINDS.addAddress("0.0.0.0", "ipv4");
LOOPBACK_COVERING_BINDS.addAddress("::", "ipv6");
// Deriving a key is deliberately expensive, so a wrong password must cost the
// client a budget before it costs this process a derivation. Absent credentials
// spend nothing: an unauthenticated first request is how every browser starts.
const AUTH_RATE = { clientCapacity: 8, clientRefillPerSecond: 0.1 };
// The work this process will do at once, rather than the rate at which it may
// be asked. A rate budget shared by every client is a budget any one of them
// can hold empty, which turns "throttle the guesser" into "lock the operator
// out"; a bound on concurrent derivations protects the same CPU and still
// admits a correct credential as soon as the machine has a moment for it. Four
// matches Node's default worker pool, which is what scrypt runs on.
const AUTH_DERIVATION_MAX = 4;
// The one header a forwarded client address is read from, and only from a peer
// the operator has named as a proxy. RFC 7239 Forwarded is deliberately not
// read: supporting one header exactly beats supporting two approximately, and
// the reverse proxies this dashboard is deployed behind send this one.
const FORWARDED_FOR_HEADER = "x-forwarded-for";
// A verified Authorization header is remembered by digest for this long, so one
// page load does not pay for one key derivation per asset. Only successes are
// remembered; a wrong password is re-derived and re-charged every time.
const AUTH_SESSION_MS = 5 * 60 * 1000;
const AUTH_SESSION_MAX = 64;
// scrypt's memory cost is 128 * N * r bytes. These bounds keep a hand-edited
// credentials file from turning every request into a memory exhaustion, and the
// explicit ceiling keeps the default parameters clear of Node's own default.
const AUTH_SCRYPT_MAXMEM = 256 * 1024 * 1024;
const AUTH_SCRYPT_LIMITS = { maxN: 1 << 17, maxR: 16, maxP: 4, minKeylen: 16, maxKeylen: 64 };
const AUTH_SCRYPT_COST = { N: 16_384, r: 8, p: 1, keylen: 32 };
const AUTH_USERNAME_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;
const AUTH_PASSWORD_MIN = 12;
// Every refusal that comes from the credentials file names the one command that
// puts a usable one back, because a refusal an operator cannot act on leaves
// them with a closed dashboard and no next step.
const AUTH_RECOVERY = "run bin/fm-dashboard-install.sh --set-password to restore it";
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

// --- GBrain panel: read-only health + search -------------------------------
//
// The GBrain panel is presence-gated: a home without a brain reports
// configured: false and renders as "no brain configured", which is the
// normal state of a fleet that has not adopted GBrain. Stopped, slow, or
// unconfigured brains degrade the panel, never the dashboard. Auth is the
// same authorize() gate every other browser route uses; the ingestion
// endpoint is the one route that does not pass through it.
const GBRAIN_HEALTH_SCHEMA = "fm-gbrain-health.v1";
const GBRAIN_SEARCH_SCHEMA = "fm-gbrain-search.v1";
const GBRAIN_RECALL_COMMAND = path.join(SCRIPT_DIR, "fm-recall.sh");
// bin/fm-recall.sh's exit status for "this command could not create the working
// files it needs, so no corpus was ever asked".
const GBRAIN_RECALL_SETUP_FAILED_EXIT = 5;
// A search query longer than this is refused before it touches the wrapper.
// GBrain's own embedder was sized for short questions, and a 4 KB body is a
// pathological operator error or a probing attack.
const GBRAIN_QUERY_MAX_BYTES = 1024;
// The search wrapper returns up to fm-recall's per-corpus limit; cap here so
// one question cannot pull a corpus's worth of bodies into the page.
const GBRAIN_SEARCH_MAX_LIMIT = 16;
// One in-flight semantic search at a time. A second search the operator fires
// before the first returns is queued at the input boundary by Node's own
// server backpressure; the gate is what protects the GBrain child from
// being asked to do unbounded work for one browser.
const GBRAIN_SEARCH_MAX_INFLIGHT = 1;
// Each search gets this many seconds in total. The dashboard's own polling
// deadline is longer; a search that needs the full window is itself a sign the
// brain is slow, and the operator will see degraded in the next health read.
const GBRAIN_SEARCH_TIMEOUT_SECONDS = 12;
// --scope all makes fm-recall read two corpora, and its --timeout bounds EACH
// retrieval call rather than the run. Divide the total across the legs so the
// wrapper always gets to print its per-source verdict - the only surface that
// says WHICH corpus was unreachable, and the one that carries the local
// results that did come back - instead of being killed mid-read.
const GBRAIN_SEARCH_LEGS = 2;
const GBRAIN_SEARCH_CALL_TIMEOUT_SECONDS = Math.max(1, Math.floor(GBRAIN_SEARCH_TIMEOUT_SECONDS / GBRAIN_SEARCH_LEGS));
// bin/fm-gbrain-health.sh refuses a budget above this.
const GBRAIN_HEALTH_MAX_TIMEOUT_SECONDS = 60;
// Seconds held back between the health child's own probe budget and the
// deadline this process kills it at. Without the margin a brain that
// black-holes every probe is killed before it can print, and the panel reports
// "unavailable" instead of the structured degraded snapshot.
const GBRAIN_HEALTH_TIMEOUT_MARGIN_SECONDS = 2;
// A search query whose trim is empty after collapse is refused; the brain
// ranks no real document against nothing.
const GBRAIN_QUERY_MIN_LENGTH = 2;
// One source row's state, narrowed to the values the panel renders. This is
// bin/fm-recall.sh's closed vocabulary; same-as-local is the alias row a home
// that owns the main brain emits for the main corpus, and dropping it here
// would rewrite a healthy read into "unknown" and paint a false failure.
const GBRAIN_SOURCE_STATES = new Set(["ok", "degraded", "absent", "failed", "unconfigured", "same-as-local", "unknown"]);
const GBRAIN_SOURCE_NAMES = new Set(["local", "main"]);
// One RESULT ROW's provenance state, which is a different vocabulary from the
// corpus states above: it describes one captured page against the live source
// it was composed from. bin/fm-recall.sh owns it, including which of these
// count as stale - that boolean arrives already decided and is passed through
// rather than re-derived here, so the rule has one owner.
const GBRAIN_PAGE_SOURCE_STATES = new Set(["current", "drifted", "uncompared", "missing", "snapshot", "unknown"]);
const GBRAIN_NON_ERROR_SOURCE_STATES = new Set(["ok", "absent", "unconfigured", "same-as-local"]);

const STATIC_FILES = new Map([
  ["/", ["index.html", "text/html; charset=utf-8"]],
  ["/index.html", ["index.html", "text/html; charset=utf-8"]],
  ["/app.js", ["app.js", "text/javascript; charset=utf-8"]],
  ["/inbox.js", ["inbox.js", "text/javascript; charset=utf-8"]],
  ["/history.js", ["history.js", "text/javascript; charset=utf-8"]],
  ["/usage.js", ["usage.js", "text/javascript; charset=utf-8"]],
  ["/backlog.js", ["backlog.js", "text/javascript; charset=utf-8"]],
  ["/router.js", ["router.js", "text/javascript; charset=utf-8"]],
  ["/display.js", ["display.js", "text/javascript; charset=utf-8"]],
  ["/errors.js", ["errors.js", "text/javascript; charset=utf-8"]],
  ["/events.js", ["events.js", "text/javascript; charset=utf-8"]],
  ["/markdown.js", ["markdown.js", "text/javascript; charset=utf-8"]],
  ["/gbrain.js", ["gbrain.js", "text/javascript; charset=utf-8"]],
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

// Where the credentials live, resolved once so the serving path and the
// installer's usability check can never disagree about which file they mean.
function resolveAuthFile() {
  const configRoot = process.env.XDG_CONFIG_HOME || path.join(process.env.HOME || os.homedir(), ".config");
  return process.env.FM_DASHBOARD_AUTH_FILE || path.join(configRoot, "firstmate", "dashboard-auth.json");
}

// The proxies whose forwarded client address this server will believe.
//
// Empty by default, and empty means no forwarded header is read at all: a
// request's identity is then the address it arrived from, which is what this
// server has always done. Trust is never acquired by upgrading, only by an
// operator naming an address or a range.
function resolveTrustedProxies() {
  const entries = (process.env.FM_DASHBOARD_TRUSTED_PROXIES || "").split(/[,\s]+/).filter(Boolean);
  const list = new net.BlockList();
  for (const entry of entries) {
    const range = /^(.+)\/(\d{1,3})$/.exec(entry);
    const address = range ? range[1] : entry;
    const family = net.isIPv4(address) ? "ipv4" : (net.isIPv6(address) ? "ipv6" : null);
    if (!family) {
      throw new Error(`FM_DASHBOARD_TRUSTED_PROXIES must be numeric addresses or CIDR ranges: ${entry}`);
    }
    if (!range) {
      list.addAddress(address, family);
      continue;
    }
    const prefix = Number(range[2]);
    // A zero prefix trusts every address there is, which is not a narrower
    // allowlist but the absence of one, so it is refused rather than honoured.
    if (!Number.isInteger(prefix) || prefix < 1 || prefix > (family === "ipv4" ? 32 : 128)) {
      throw new Error(`FM_DASHBOARD_TRUSTED_PROXIES has an unusable prefix length: ${entry}`);
    }
    list.addSubnet(address, prefix, family);
  }
  return { entries, list };
}

// The installer stamps every generated unit with this server's runtime
// contract. A service launched by systemd without the stamp is an older unit,
// not an ordinary command failure: polling it forever only exposes the first
// denied mktemp while hiding the repair. INVOCATION_ID is inherited by every
// descendant. Newer managers identify the process they launched directly;
// older managers are identified through the service's kernel cgroup.
function cgroupContainsServiceUnit(cgroup) {
  return String(cgroup).split(/\r?\n/).some((line) => {
    const firstColon = line.indexOf(":");
    const secondColon = line.indexOf(":", firstColon + 1);
    if (firstColon < 0 || secondColon < 0) return false;
    return line.slice(secondColon + 1).split("/").includes(SERVICE_UNIT_NAME);
  });
}

function isDashboardServiceProcess() {
  if (!process.env.INVOCATION_ID) return false;
  if (process.env.SYSTEMD_EXEC_PID) return process.env.SYSTEMD_EXEC_PID === String(process.pid);
  try {
    return cgroupContainsServiceUnit(fsReadFileSync("/proc/self/cgroup", "utf8"));
  } catch {
    return false;
  }
}

function serviceUnitContractError() {
  if (!isDashboardServiceProcess()) return null;
  const repair = "rerun bin/fm-dashboard-install.sh; it preserves the installed dashboard settings unless an option overrides them";
  if (process.env.FM_DASHBOARD_UNIT_CONTRACT !== SERVICE_UNIT_CONTRACT) {
    return Object.assign(new Error(`the installed firstmate-dashboard.service is out of date and has no current scratch-space contract; ${repair}`), {
      kind: "service_unit_outdated",
    });
  }
  const scratch = process.env.TMPDIR || "";
  try {
    if (!scratch || !fsStatSync(scratch).isDirectory()) throw new Error("not a directory");
    fsAccessSync(scratch, fsConstants.W_OK);
  } catch {
    return Object.assign(new Error(`the installed firstmate-dashboard.service has no writable TMPDIR despite its scratch-space contract; ${repair}`), {
      kind: "service_unit_outdated",
    });
  }
  return null;
}

function resolveConfig() {
  const address = process.env.FM_DASHBOARD_ADDRESS || "127.0.0.1";
  // Only numeric addresses. A hostname would make what this process is
  // reachable on depend on name resolution, which is not a thing an operator
  // can read off the configuration they wrote.
  if (net.isIP(address) === 0) {
    throw new Error("FM_DASHBOARD_ADDRESS must be a numeric IPv4 or IPv6 address");
  }
  const auth = process.env.FM_DASHBOARD_AUTH || "auto";
  if (!new Set(["auto", "off"]).has(auth)) {
    throw new Error("FM_DASHBOARD_AUTH must be auto or off");
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
    loopback: LOOPBACK_ADDRESSES.has(address),
    auth,
    authFile: resolveAuthFile(),
    trustedProxies: resolveTrustedProxies(),
    usage,
    events,
    eventsConfigFile: process.env.FM_DASHBOARD_EVENTS_CONFIG
      || path.join(configRoot, "firstmate", "dashboard-events.json"),
    eventStorePath: resolveEventStorePath(fmHome),
    eventLimits: eventLimitsFromEnv(),
    serviceUnitError: serviceUnitContractError(),
    port: positiveNumber("FM_DASHBOARD_PORT", 8787, { integer: true, maximum: 65_535 }),
    pollMs: positiveNumber("FM_DASHBOARD_POLL_SECONDS", 5) * 1000,
    timeoutMs: positiveNumber("FM_DASHBOARD_TIMEOUT_SECONDS", 15) * 1000,
    staleMs: positiveNumber("FM_DASHBOARD_STALE_SECONDS", 30) * 1000,
    historyLimit: positiveNumber("FM_DASHBOARD_HISTORY_LIMIT", 500, { integer: true, maximum: 100_000 }),
    historyPollMs: positiveNumber("FM_DASHBOARD_HISTORY_POLL_SECONDS", 60) * 1000,
    reportMaxBytes: positiveNumber("FM_DASHBOARD_REPORT_MAX_BYTES", 262_144, { integer: true, maximum: 16 * 1024 * 1024 }),
  };
}

function coversLoopback(address) {
  return LOOPBACK_COVERING_BINDS.check(address, net.isIPv4(address) ? "ipv4" : "ipv6");
}

// One address, in the one spelling this server keys buckets by, or null when
// the text is not an address at all. A port, brackets, an interface zone, and
// the IPv4-mapped IPv6 form all name the same client, and a client that could
// hold two buckets by spelling itself two ways is a client that is not
// throttled.
function normalizeAddress(value) {
  if (typeof value !== "string") return null;
  let text = value.trim();
  if (!text) return null;
  const bracketed = /^\[(.+)\](?::\d{1,5})?$/.exec(text);
  if (bracketed) text = bracketed[1];
  const zone = text.indexOf("%");
  if (zone > 0) text = text.slice(0, zone);
  if (net.isIP(text) === 0) {
    const withPort = /^([^:]+):\d{1,5}$/.exec(text);
    if (withPort) text = withPort[1];
  }
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(text);
  if (mapped) text = mapped[1];
  if (net.isIP(text) === 0) return null;
  return net.isIPv4(text) ? text : text.toLowerCase();
}

function isTrustedProxy(config, address) {
  if (!address || config.trustedProxies.entries.length === 0) return false;
  return config.trustedProxies.list.check(address, net.isIPv4(address) ? "ipv4" : "ipv6");
}

// Which client a request is throttled as.
//
// With no trusted proxy configured no forwarded header is read at all and the
// peer address is the identity. A forwarded chain is read only when the peer
// itself is an allowlisted proxy, because a header from anyone else is text the
// client wrote about itself. It is then walked from the peer end, discarding
// the entries allowlisted proxies contributed, and the first untrusted entry is
// the client: every entry to the left of that one is whatever the client chose
// to claim, so reading the leftmost is how per-client throttling becomes no
// throttling at all.
//
// A request whose client cannot be established is refused rather than being
// given a shared identity. One shared bucket is a bucket anyone can hold empty,
// which is the same failure-as-a-benign-value shape as an open dashboard.
function resolveClientIdentity(request, config) {
  const peer = normalizeAddress(request.socket?.remoteAddress);
  if (!peer) return null;
  if (!isTrustedProxy(config, peer)) return peer;
  const header = request.headers[FORWARDED_FOR_HEADER];
  const raw = Array.isArray(header) ? header.join(",") : (header ?? "");
  if (String(raw).trim() === "") return peer;
  const entries = String(raw).split(",");
  let leftmost = null;
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const address = normalizeAddress(entries[index]);
    if (!address) return null;
    leftmost = address;
    if (!isTrustedProxy(config, address)) return address;
  }
  return leftmost;
}

function safeText(value, limit = 4_000) {
  return String(value || "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, limit);
}

// The per-task and per-project rollups are two reads of the same store, and one
// of them failing says nothing about the other. The top-level fields are the
// task rollup's own read state - History's per-task token column is derived
// from them - and `projects_read` carries the project rollup's, so a project
// read that missed cannot darken every task's totals. A shared precondition
// (usage switched off, no collector, no store) sets both to the same answer,
// which is what the defaults express.
function usageEnvelope({
  available,
  reason,
  collection,
  source,
  tasks,
  projects,
  stale = false,
  projectsAvailable = available,
  projectsReason = reason,
  projectsCollection = collection,
  projectsStale = stale,
}) {
  return {
    available: Boolean(available),
    reason: reason ? safeText(reason) : null,
    collection: collection ? safeText(collection, 32) : null,
    source: source ? safeText(source, 64) : null,
    stale: Boolean(stale),
    tasks: tasks && typeof tasks === "object" ? tasks : {},
    projects: projects && typeof projects === "object" ? projects : {},
    projects_read: {
      available: Boolean(projectsAvailable),
      reason: projectsReason ? safeText(projectsReason) : null,
      collection: projectsCollection ? safeText(projectsCollection, 32) : null,
      stale: Boolean(projectsStale),
    },
  };
}

// One rollup's retention decision, applied identically to both halves: an
// available read becomes the new last good, a non-operational failure drops the
// retained read because it is a fact about this home rather than a read that
// missed, and an operational failure keeps the last good read labelled stale.
function retainRollup(fresh, lastGood) {
  if (fresh.available) return { result: fresh, lastGood: fresh };
  if (fresh.collection !== "operational" || !lastGood) return { result: fresh, lastGood: null };
  return { result: { ...lastGood, stale: true, reason: fresh.reason }, lastGood };
}

// The dashboard reads both per-task and per-project rollups. Both share the
// same numeric fields and the same rule that a missing or malformed value is
// omitted rather than read as zero.
function usageTotalsFromRow(row) {
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
  return totals;
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
          // Carried separately from the message because callers whose command
          // documents distinct failure states need to tell them apart, and
          // parsing them back out of the sentence would be a second contract.
          exitCode: typeof code === "number" ? code : null,
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

// Raw error text is kept OUT of every client payload, not thrown away.
// displayError() carries the underlying message and stderr on a non-enumerable
// `diagnostic`, so what a browser or a posting agent receives is only the
// display-safe sentence, and this is the sink that keeps the reason readable by
// an operator. Every server-side displayError call goes through here, the
// per-source GBrain failures and the ingest refusal included, so the
// retrievability rule holds on all of them rather than on the polling paths
// alone.
//
// Remembered per SOURCE rather than per kind, and cleared by that source's own
// next success. A source failing every poll therefore says so once, while the
// same failure returning after a recovery says so again - on a service that
// runs for weeks, that recurrence is the thing worth reading, and dedup that
// never expires would have swallowed it.
const loggedDiagnostics = new Map();

function logDiagnostic(source, record) {
  const diagnostic = record?.diagnostic || {};
  const detail = [safeText(diagnostic.message, 500), safeText(diagnostic.stderr, 500)]
    .filter(Boolean)
    .join(" | ");
  const line = `fm-dashboard: ${source}: ${record?.kind || "unknown"}: ${detail || record?.message || ""}`;
  if (loggedDiagnostics.get(source) !== line) {
    loggedDiagnostics.set(source, line);
    console.error(line);
  }
  return record;
}

function clearDiagnostic(source) {
  loggedDiagnostics.delete(source);
}

function errorRecord(source, error, fallback) {
  return logDiagnostic(source, displayError(error, fallback, { at: nowIso() }));
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
    this.lastGoodUsage = null;
    this.lastGoodProjects = null;
    this.usage = usageEnvelope({
      available: false,
      reason: "token usage has not been read yet",
      collection: "absent",
      source: null,
      tasks: {},
    });
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
      clearDiagnostic("history");
      this.usage = this.retainUsage(await this.readUsage());
    } catch (error) {
      this.lastError = errorRecord("history", error, "history_refresh_failed");
    } finally {
      this.refreshing = false;
      this.clients.send("history");
      if (this.pending && !this.stopped) {
        this.pending = false;
        queueMicrotask(() => this.trigger());
      }
    }
  }

  // Token usage keeps its last good read the way history keeps its last good
  // document, and for the same reason: a read that MISSED is not the same fact
  // as a read that came back empty. The collector can fail operationally for
  // two genuinely different reasons:
  //
  //   1. The store has writers - teardown refreshes it on every archive,
  //      bootstrap on every locked session start - and every one of them holds
  //      it in WAL for the length of its window: fm-telemetry-store.mjs
  //      openStore enables WAL on a writable open and closeStore checkpoints
  //      and switches back to DELETE. The at-rest DELETE shape is what makes
  //      this service's read-only open possible at all, so a writer that exits
  //      without closing leaves the store in WAL with no wal-index a reader
  //      can build without write access to data/, and every read exits
  //      non-zero until a writer closes cleanly again. This is live, not
  //      hypothetical - the DELETE journal mode the store is normally found in
  //      is the outcome that mechanism is guarded against, not evidence it
  //      cannot happen.
  //
  //   2. The collector's host sandbox leaves SQLite no writable scratch path
  //      for the temp file a read-only query needs. This unit combines
  //      ProtectSystem=strict with ProtectHome=read-only, which between them
  //      refuse /tmp, /var/tmp, $HOME, and every other path SQLite's unix VFS
  //      falls back to, and the collector exits "disk I/O error" against a
  //      perfectly healthy store. That one is answered in the reader rather
  //      than in the sandbox: bin/fm-telemetry-store.mjs sets
  //      PRAGMA temp_store = MEMORY on its readOnly open, so the collector
  //      never asks the filesystem for scratch space and no unit, drop-in, or
  //      stand-alone invocation can deny it. docs/verification/dashboard-service-unit.md
  //      pins the reproduced combination.
  //
  // Either way the panel must keep showing the last good read rather than
  // drawing every completed card as an operator action item, at the moment a
  // captain is most likely to be looking: teardown refreshes the store
  // immediately before the record that triggered it appears in History.
  //
  // Only an operational failure retains. "absent" and "disabled" are facts about
  // this home rather than a read that missed - a deleted store or a dashboard
  // with usage reads switched off must not keep serving totals from before - so
  // they drop the retained read instead of hiding behind it.
  //
  // Each rollup retains on its own, so a project read that missed while the
  // task read landed keeps serving fresh task totals rather than dragging them
  // into the failure.
  retainUsage(fresh) {
    const task = retainRollup(
      { available: fresh.available, reason: fresh.reason, collection: fresh.collection, source: fresh.source, rows: fresh.tasks, stale: false },
      this.lastGoodUsage,
    );
    const project = retainRollup(
      {
        available: fresh.projects_read.available,
        reason: fresh.projects_read.reason,
        collection: fresh.projects_read.collection,
        source: fresh.source,
        rows: fresh.projects,
        stale: false,
      },
      this.lastGoodProjects,
    );
    this.lastGoodUsage = task.lastGood;
    this.lastGoodProjects = project.lastGood;
    return usageEnvelope({
      available: task.result.available,
      reason: task.result.reason,
      collection: task.result.collection,
      source: task.result.source || project.result.source,
      stale: task.result.stale,
      tasks: task.result.rows,
      projects: project.result.rows,
      projectsAvailable: project.result.available,
      projectsReason: project.result.reason,
      projectsCollection: project.result.collection,
      projectsStale: project.result.stale,
    });
  }

  // Token usage is an optional integration owned elsewhere. Its absence, its
  // failure, and an output this dashboard does not recognize all resolve to the
  // same honest answer: unavailable with a reason. None of them ever becomes a
  // zero, because a zero would read as "this task cost nothing".
  //
  // History reads the per-task rollup and Usage reads the per-project one. They
  // are two reads of the same store, so each is taken and reported on its own:
  // whichever one lands is served, and the one that missed says so.
  async readUsage() {
    const blocked = await this.usageUnavailableForThisHome();
    if (blocked) {
      return usageEnvelope({
        available: false,
        reason: blocked.reason,
        collection: blocked.collection,
        source: null,
        tasks: {},
        projects: {},
      });
    }
    const tasks = await this.readUsageRollup("task", (key) => TASK_ID_PATTERN.test(key));
    const projects = await this.readUsageRollup("project", () => true);
    return usageEnvelope({
      available: tasks.available,
      reason: tasks.reason,
      collection: tasks.collection,
      source: tasks.available || projects.available ? USAGE_SCHEMA : null,
      tasks: tasks.rows,
      projects: projects.rows,
      projectsAvailable: projects.available,
      projectsReason: projects.reason,
      projectsCollection: projects.collection,
    });
  }

  // The conditions that are facts about this home rather than a read that
  // missed. They apply to both rollups, because neither can be taken at all.
  async usageUnavailableForThisHome() {
    if (this.config.usage === "off") {
      return { reason: "token usage reads are disabled for this dashboard", collection: "disabled" };
    }
    for (const target of [USAGE_COMMAND, path.join(this.config.dataDir, USAGE_DB_FILE)]) {
      try {
        await stat(target);
      } catch {
        return { reason: "token usage is not collected in this home", collection: "absent" };
      }
    }
    return null;
  }

  async readUsageRollup(by, accepts) {
    const subject = by === "project" ? "per-project token usage" : "token usage";
    let document;
    try {
      document = await runJsonCommand(process.execPath, [USAGE_COMMAND, "report", "--by", by, "--limit", String(this.config.historyLimit)], {
        timeoutMs: this.config.timeoutMs,
        env: { ...process.env, FM_HOME: this.config.fmHome },
        register: (child, previous) => {
          if (child) this.activeChild = child;
          else if (this.activeChild === previous) this.activeChild = null;
        },
      });
    } catch (error) {
      return { available: false, reason: `${subject} could not be read (${safeText(error.kind || "failed")})`, collection: "operational", rows: {} };
    }
    // An output this dashboard does not recognize is a failed read, never an
    // empty fleet: serving it as available with no rows would draw a zero claim
    // over a collector whose answer was never understood.
    if (!document || document.schema !== USAGE_SCHEMA || !Array.isArray(document.rows)) {
      return { available: false, reason: `the ${subject} report is not a supported schema version`, collection: "operational", rows: {} };
    }
    const rows = {};
    for (const row of document.rows) {
      const key = typeof row?.key === "string" ? safeText(row.key, 200) : "";
      if (!key || !accepts(key)) continue;
      rows[key] = usageTotalsFromRow(row);
    }
    return { available: true, reason: null, collection: "ready", rows };
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

  // A budget that is spent before the work it protects has to be given back
  // when the work turns out to have been legitimate, or the budget throttles
  // the users it exists to keep serving rather than the attempts against them.
  refund(key) {
    const bucket = this.buckets.get(key);
    if (bucket) bucket.tokens = Math.min(this.capacity, bucket.tokens + 1);
  }
}

// How many key derivations this process will have in flight at once. Full is a
// momentary state that clears in milliseconds rather than a budget a client can
// hold at zero, so every caller gets in as soon as there is capacity for them,
// however hard someone else is guessing.
class DerivationGate {
  constructor(limit) {
    this.limit = limit;
    this.active = 0;
  }

  enter() {
    if (this.active >= this.limit) return false;
    this.active += 1;
    return true;
  }

  leave() {
    this.active = Math.max(0, this.active - 1);
  }
}

function scryptAsync(password, salt, keylen, cost) {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, keylen, { ...cost, maxmem: AUTH_SCRYPT_MAXMEM }, (error, derived) => {
      if (error) reject(error);
      else resolve(derived);
    });
  });
}

// Compare two strings without letting their length or contents steer the
// timing. Hashing first is what makes unequal lengths comparable at all.
function digestEquals(a, b) {
  return timingSafeEqual(
    createHash("sha256").update(String(a), "utf8").digest(),
    createHash("sha256").update(String(b), "utf8").digest(),
  );
}

// The credentials file holds a salted scrypt digest and never the password.
// Every field is validated here, including the work factors, because a file
// this process reads on every restart must not be able to turn a login into a
// memory or CPU exhaustion.
function parseCredential(parsed) {
  if (!parsed || parsed.schema !== AUTH_SCHEMA) {
    throw new Error(`expected ${AUTH_SCHEMA}`);
  }
  if (parsed.kdf !== "scrypt") throw new Error("the only supported key derivation is scrypt");
  const username = typeof parsed.username === "string" ? parsed.username : "";
  if (!AUTH_USERNAME_PATTERN.test(username)) throw new Error("the stored username is not a supported value");
  const salt = Buffer.from(typeof parsed.salt === "string" ? parsed.salt : "", "base64");
  const hash = Buffer.from(typeof parsed.hash === "string" ? parsed.hash : "", "base64");
  if (salt.length < 16) throw new Error("the stored salt is too short");
  const cost = parsed.cost || {};
  const N = Number(cost.N);
  const r = Number(cost.r);
  const p = Number(cost.p);
  const keylen = Number(cost.keylen);
  if (!Number.isInteger(N) || N < 2 || N > AUTH_SCRYPT_LIMITS.maxN || (N & (N - 1)) !== 0) {
    throw new Error("the stored scrypt N is not a supported power of two");
  }
  if (!Number.isInteger(r) || r < 1 || r > AUTH_SCRYPT_LIMITS.maxR) throw new Error("the stored scrypt r is out of range");
  if (!Number.isInteger(p) || p < 1 || p > AUTH_SCRYPT_LIMITS.maxP) throw new Error("the stored scrypt p is out of range");
  if (!Number.isInteger(keylen) || keylen < AUTH_SCRYPT_LIMITS.minKeylen || keylen > AUTH_SCRYPT_LIMITS.maxKeylen) {
    throw new Error("the stored key length is out of range");
  }
  if (hash.length !== keylen) throw new Error("the stored digest does not match the stored key length");
  return { username, salt, hash, cost: { N, r, p }, keylen };
}

function parseBasicCredentials(header) {
  if (typeof header !== "string" || !/^Basic\s/i.test(header)) return null;
  const encoded = header.slice(header.indexOf(" ") + 1).trim();
  if (!encoded) return null;
  const decoded = Buffer.from(encoded, "base64").toString("utf8");
  const separator = decoded.indexOf(":");
  if (separator < 0) return null;
  return { username: decoded.slice(0, separator), password: decoded.slice(separator + 1), header };
}

// Dashboard authentication, presence-gated on a private credentials file the
// operator creates with bin/fm-dashboard-install.sh --set-password.
//
// Two rules make exposure safe to reason about. A bind beyond loopback refuses
// to start without a usable credential, so reachability and authentication
// cannot be configured apart. And once a credential has been required or seen,
// enforcement is sticky: a credentials file that is missing its private mode,
// corrupted, or gone answers 503 rather than reverting to an open dashboard,
// because the operator's last expressed intent was authentication. That holds
// whichever side of process start the file broke on.
class AuthState {
  constructor(config) {
    this.config = config;
    this.credential = null;
    this.error = null;
    this.enforced = false;
    this.checkedAtMs = 0;
    this.signature = null;
    this.sessions = new Map();
    this.clientLimiter = new RateLimiter(AUTH_RATE.clientCapacity, AUTH_RATE.clientRefillPerSecond, 1024);
    this.derivations = new DerivationGate(AUTH_DERIVATION_MAX);
  }

  // Re-read when the file changes, so rotating a password does not need a
  // restart, at the cost of one stat per second at most.
  read({ force = false } = {}) {
    if (this.config.auth === "off") return null;
    const now = Date.now();
    if (!force && now - this.checkedAtMs < 1000) return this.credential;
    this.checkedAtMs = now;
    let info;
    try {
      info = fsStatSync(this.config.authFile);
    } catch {
      this.signature = null;
      this.credential = null;
      this.error = null;
      this.sessions.clear();
      return null;
    }
    // The signature carries the mode and the inode as well as the modification
    // time, because chmod and a replacing rename both change what this file
    // means without necessarily changing when it was last written.
    const signature = `${info.mtimeMs}:${info.ctimeMs}:${info.size}:${info.mode}:${info.ino}`;
    if (this.signature === signature && (this.credential || this.error)) return this.credential;
    this.signature = signature;
    this.credential = null;
    this.error = null;
    this.sessions.clear();
    // A credentials file that is there is the operator's expressed intent to
    // authenticate, so enforcement starts at presence and not at a successful
    // parse. "I could not read the credentials" and "there are no credentials"
    // are not the same answer, and only the second is safe to serve openly: a
    // file this process cannot use has to close the dashboard whether it broke
    // before this process started or while it was running.
    this.enforced = true;
    // A credentials file other users can read is not a credential. Refusing is
    // the only answer that does not quietly accept a weaker secret than the
    // operator was told they had.
    if ((info.mode & 0o077) !== 0) {
      this.error = `the dashboard credentials file must not be readable by other users: ${this.config.authFile} - ${AUTH_RECOVERY}`;
      return null;
    }
    try {
      this.credential = parseCredential(JSON.parse(fsReadFileSync(this.config.authFile, "utf8")));
    } catch (error) {
      this.error = `the dashboard credentials file ${this.config.authFile} could not be used (${safeText(error.message)}) - ${AUTH_RECOVERY}`;
    }
    return this.credential;
  }

  sessionKey(header) {
    return createHash("sha256").update(header, "utf8").digest("base64");
  }

  remember(header) {
    if (this.sessions.size >= AUTH_SESSION_MAX) {
      this.sessions.delete(this.sessions.keys().next().value);
    }
    this.sessions.set(this.sessionKey(header), Date.now() + AUTH_SESSION_MS);
  }

  recalls(header) {
    const key = this.sessionKey(header);
    const expiry = this.sessions.get(key);
    if (expiry === undefined) return false;
    if (expiry <= Date.now()) {
      this.sessions.delete(key);
      return false;
    }
    return true;
  }

  async verify(presented) {
    const credential = this.credential;
    if (!credential) return false;
    const derived = await scryptAsync(presented.password, credential.salt, credential.keylen, credential.cost);
    // Both comparisons always run, so a wrong username and a wrong password are
    // not distinguishable by how long the answer took.
    const sameUser = digestEquals(presented.username, credential.username);
    const sameSecret = derived.length === credential.hash.length && timingSafeEqual(derived, credential.hash);
    return sameUser && sameSecret;
  }
}

// The one authentication gate, in front of every browser-facing route.
//
// POST /events is deliberately not behind it: that endpoint carries its own
// bearer token, and the local reporting hooks that post to it know that token
// and nothing else.
async function authorize(request, response, auth) {
  const credential = auth.read();
  if (!credential) {
    if (!auth.enforced) return true;
    sendJson(response, 503, {
      schema: AUTH_DENIAL_SCHEMA,
      reason: "credentials_unavailable",
      detail: safeText(auth.error)
        || `the dashboard credentials file ${auth.config.authFile} is no longer there - ${AUTH_RECOVERY}`,
    });
    return false;
  }
  const presented = parseBasicCredentials(request.headers.authorization);
  if (!presented) {
    response.setHeader("WWW-Authenticate", `Basic realm="${AUTH_REALM}", charset="UTF-8"`);
    sendJson(response, 401, { schema: AUTH_DENIAL_SCHEMA, reason: "authentication_required" });
    return false;
  }
  if (auth.recalls(presented.header)) return true;
  const client = resolveClientIdentity(request, auth.config);
  if (!client) {
    sendJson(response, 403, {
      schema: AUTH_DENIAL_SCHEMA,
      reason: "client_unidentified",
      detail: "this request carries no client address this server can throttle by, so it cannot be authenticated",
    });
    return false;
  }
  // The charge is the guessing client's own, spent before the derivation it
  // buys and returned when the credential turns out to have been the right one.
  // Only failed attempts keep what they spent, and they only ever spend their
  // own budget, so no client can guess another one out of the dashboard.
  if (!auth.clientLimiter.allow(client)) {
    response.setHeader("Retry-After", "30");
    sendJson(response, 429, { schema: AUTH_DENIAL_SCHEMA, reason: "too_many_attempts" });
    return false;
  }
  if (!auth.derivations.enter()) {
    auth.clientLimiter.refund(client);
    response.setHeader("Retry-After", "1");
    sendJson(response, 503, { schema: AUTH_DENIAL_SCHEMA, reason: "verification_capacity" });
    return false;
  }
  let verified;
  try {
    verified = await auth.verify(presented);
  } finally {
    auth.derivations.leave();
  }
  if (verified) {
    auth.clientLimiter.refund(client);
    auth.remember(presented.header);
    return true;
  }
  response.setHeader("WWW-Authenticate", `Basic realm="${AUTH_REALM}", charset="UTF-8"`);
  sendJson(response, 401, { schema: AUTH_DENIAL_SCHEMA, reason: "invalid_credentials" });
  return false;
}

// A browser will not attach an Authorization header to a cross-site request
// without a CORS grant this server never issues, so the ingest endpoint has no
// ambient-credential path to abuse. This refuses the cross-origin attempt
// anyway, before any body is read, so the boundary does not rest on that
// reasoning staying true. A producer that is not a browser sends no Origin.
function sameOriginRequest(request) {
  const origin = request.headers.origin;
  if (typeof origin !== "string" || origin === "" || origin === "null") return true;
  try {
    return new URL(origin).host === String(request.headers.host || "");
  } catch {
    return false;
  }
}

// The agent-event timeline: the authenticated ingest boundary, the dashboard's
// own store, and the live tail the browser renders.
//
// Ingestion is presence-gated on the shared config file that carries the token.
// With no config there is no token, so the endpoint accepts nothing and every
// harness degrades to "no event source" - which is also exactly what removing
// the instrumentation leaves behind.

// --- GBrain state ------------------------------------------------------------
//
// The GBrain panel reads two things: a fresh health snapshot every time the
// panel renders, and one search result when the operator fires a query.
// Health is delegated to bin/fm-gbrain-health.sh, which is the single owner
// of the shape and the bounded probe behaviour. Search delegates to
// bin/fm-recall.sh with the read-only scopes the per-home scoping config
// already enforces; this process never reads a credential and never opens
// a token endpoint.
//
// Both reads are bounded, both fail closed, and both leave the dashboard's
// other panels untouched on any failure. The refresh cadence is the history
// poll, not the snapshot poll: a health read shells out to a probe that can
// take seconds, so it rides the slower of the two intervals and the panel
// says how old the last successful read is.
class GBrainState {
  constructor(config, clients) {
    this.config = config;
    this.clients = clients;
    this.lastGood = null;
    this.lastSuccessAtMs = null;
    this.lastSuccessAt = null;
    this.lastAttemptAt = null;
    this.lastError = null;
    this.refreshing = false;
    this.pending = false;
    this.timer = null;
    this.activeChild = null;
    this.searchesInFlight = 0;
    this.searchTimer = null;
    this.stopped = false;
  }

  envelope() {
    const ageMs = this.lastSuccessAtMs === null ? null : Math.max(0, Date.now() - this.lastSuccessAtMs);
    const stale = this.lastGood !== null && this.lastError !== null;
    let phase = "first_run";
    if (this.lastGood && stale) phase = "last_good";
    else if (this.lastGood) phase = "ready";
    else if (this.lastError) phase = "unavailable";
    return {
      schema: GBRAIN_HEALTH_SCHEMA,
      status: {
        phase,
        refreshing: this.refreshing,
        stale,
        last_attempt_at: this.lastAttemptAt,
        last_success_at: this.lastSuccessAt,
        last_success_age_seconds: ageMs === null ? null : Math.floor(ageMs / 1000),
        error: this.lastError,
      },
      config: {
        // The panel never sets its own deadline; the snapshot path sets the
        // cap and the operator can lower it, but it cannot be longer than the
        // polling deadline without breaking the snapshot's contract.
        health_timeout_seconds: Math.floor(this.config.timeoutMs / 1000),
        search_timeout_seconds: GBRAIN_SEARCH_TIMEOUT_SECONDS,
        query_max_bytes: GBRAIN_QUERY_MAX_BYTES,
        result_limit_max: GBRAIN_SEARCH_MAX_LIMIT,
      },
      health: this.lastGood,
    };
  }

  broadcast() {
    this.clients.send("gbrain_health");
  }

  trigger() {
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
      const document = await this.runHealth();
      if (!document || document.schema !== GBRAIN_HEALTH_SCHEMA) {
        const actual = document && typeof document.schema === "string" ? document.schema : "missing";
        throw Object.assign(new Error(`expected ${GBRAIN_HEALTH_SCHEMA}, received ${actual}`), { kind: "unsupported_schema" });
      }
      this.lastGood = document;
      this.lastSuccessAtMs = Date.now();
      this.lastSuccessAt = new Date(this.lastSuccessAtMs).toISOString().replace(/\.\d{3}Z$/, "Z");
      this.lastError = null;
      clearDiagnostic("gbrain-health");
    } catch (error) {
      this.lastError = errorRecord("gbrain-health", error, "gbrain_health_unavailable");
    } finally {
      this.refreshing = false;
      this.broadcast();
      if (this.pending && !this.stopped) {
        this.pending = false;
        queueMicrotask(() => this.trigger());
      }
    }
  }

  // The child's own probe budget has to land strictly inside the deadline this
  // process kills it at, or the exact case the panel exists to render - a brain
  // whose endpoints do not answer - produces no document at all.
  healthBudgetSeconds() {
    const outer = Math.floor(this.config.timeoutMs / 1000);
    return Math.max(1, Math.min(GBRAIN_HEALTH_MAX_TIMEOUT_SECONDS, outer - GBRAIN_HEALTH_TIMEOUT_MARGIN_SECONDS));
  }

  runHealth() {
    return runJsonCommand(path.join(SCRIPT_DIR, "fm-gbrain-health.sh"), ["--json", "--timeout", String(this.healthBudgetSeconds())], {
      timeoutMs: this.config.timeoutMs,
      env: { ...process.env, FM_HOME: this.config.fmHome },
      register: (child, previous) => {
        if (child) this.activeChild = child;
        else if (this.activeChild === previous) this.activeChild = null;
      },
    });
  }

  async search(query, limit) {
    if (this.searchesInFlight >= GBRAIN_SEARCH_MAX_INFLIGHT) {
      throw Object.assign(new Error("a semantic search is already in progress; wait for it to return"), { kind: "search_busy" });
    }
    const trimmed = String(query || "").trim();
    if (trimmed.length < GBRAIN_QUERY_MIN_LENGTH) {
      throw Object.assign(new Error(`a search query must be at least ${GBRAIN_QUERY_MIN_LENGTH} characters`), { kind: "query_too_short" });
    }
    if (Buffer.byteLength(trimmed, "utf8") > GBRAIN_QUERY_MAX_BYTES) {
      throw Object.assign(new Error(`a search query must not exceed ${GBRAIN_QUERY_MAX_BYTES} bytes`), { kind: "query_too_large" });
    }
    const n = Math.max(1, Math.min(GBRAIN_SEARCH_MAX_LIMIT, Number(limit) || 8));
    this.searchesInFlight += 1;
    const env = { ...process.env, FM_HOME: this.config.fmHome };
    try {
      // The query is passed as one argv element, never as part of a command
      // string or shell substitution. A hostile query is a string of bytes to
      // search for; nothing more. --scope all lets a fleet with a shared main
      // brain read both corpora, and is refused by the wrapper when the main
      // brain is unconfigured.
      const args = ["search", "--json", "--scope", "all", "--limit", String(n), "--timeout", String(GBRAIN_SEARCH_CALL_TIMEOUT_SECONDS), "--"];
      for (const word of trimmed.split(/\s+/)) args.push(word);
      const document = await runJsonCommand(GBRAIN_RECALL_COMMAND, args, {
        timeoutMs: (GBRAIN_SEARCH_TIMEOUT_SECONDS + 1) * 1000,
        env,
        register: (child, previous) => {
          if (child) this.searchTimer = child;
          else if (this.searchTimer === previous) this.searchTimer = null;
        },
      });
      if (!document || document.schema !== "fm-recall.v1") {
        const actual = document && typeof document.schema === "string" ? document.schema : "missing";
        throw Object.assign(new Error(`expected fm-recall.v1, received ${actual}`), { kind: "unsupported_schema" });
      }
      // The wrapper's results are trusted text from the brain's archive.
      // Anything that arrived beyond the closed vocabulary here is dropped
      // before it reaches the page; this is the second of two independent
      // reasons a stored document cannot become markup.
      const results = Array.isArray(document.results) ? document.results : [];
      const sources = Array.isArray(document.sources) ? document.sources : [];
      const cleanedResults = results.slice(0, n).map((row) => {
        const sourceState = GBRAIN_PAGE_SOURCE_STATES.has(row?.source_state) ? row.source_state : "unknown";
        const capturedAt = typeof row?.captured_at === "string" ? safeText(row.captured_at, 40) : null;
        const sourceUpdatedAt = typeof row?.source_updated_at === "string" ? safeText(row.source_updated_at, 40) : null;
        return {
          source: typeof row?.source === "string" ? row.source : null,
          slug: typeof row?.slug === "string" ? row.slug : null,
          title: typeof row?.title === "string" ? safeText(row.title, 400) : "",
          score: typeof row?.score === "number" && Number.isFinite(row.score) ? row.score : null,
          excerpt: typeof row?.excerpt === "string" ? safeText(row.excerpt, 4000) : "",
          stale: row?.stale === true,
          captured_at: capturedAt,
          source_state: sourceState,
          source_kind: row?.source_kind === "task" || row?.source_kind === "note" ? row.source_kind : null,
          source_id: typeof row?.source_id === "string" ? safeText(row.source_id, 80) : null,
          source_updated_at: sourceUpdatedAt,
        };
      });
      const cleanedSources = sources.map((row) => {
        const source = GBRAIN_SOURCE_NAMES.has(row?.source) ? row.source : "unknown";
        const state = GBRAIN_SOURCE_STATES.has(row?.state) ? row.state : "unknown";
        const kind = source === "local"
          ? "gbrain_local_source_failed"
          : source === "main" ? "gbrain_main_source_failed" : "gbrain_source_failed";
        const path = `gbrain-source-${source}`;
        let failure = null;
        if (GBRAIN_NON_ERROR_SOURCE_STATES.has(state)) clearDiagnostic(path);
        else failure = logDiagnostic(path, displayError({ kind, message: typeof row?.detail === "string" ? row.detail : null }, kind));
        return {
          source,
          state,
          brain: typeof row?.brain === "string" ? safeText(row.brain, 240) : null,
          results: typeof row?.results === "number" && Number.isFinite(row.results) ? row.results : 0,
          detail: failure?.message || (typeof row?.detail === "string" ? safeText(row.detail, 240) : null),
        };
      });
      const answerKind = document?.answer?.kind === "nearest" || document?.answer?.kind === "none"
        ? document.answer.kind
        : null;
      const answerNotice = typeof document?.answer?.notice === "string"
        ? safeText(document.answer.notice, 800)
        : null;
      return {
        schema: GBRAIN_SEARCH_SCHEMA,
        generated: nowIso(),
        query: trimmed,
        limit: n,
        home: typeof document.home === "string" ? document.home : this.config.fmHome,
        sources: cleanedSources,
        results: cleanedResults,
        answer: answerKind ? { kind: answerKind, notice: answerNotice || "" } : null,
      };
    } catch (error) {
      const kind = error.kind || "search_failed";
      if (kind === "exit_nonzero") {
        // fm-recall separates "every corpus was asked and none answered" from
        // "the search never started", and the panel has to keep them apart:
        // the first is a fact about the brain, the second is a fact about this
        // service's environment, and only one of them is the operator's to
        // read as an answer. bin/fm-recall.sh's header owns the statuses.
        if (error.exitCode === GBRAIN_RECALL_SETUP_FAILED_EXIT) {
          throw Object.assign(new Error(safeText(error.stderr) || "the search could not start"), {
            kind: "search_setup_failed",
          });
        }
        throw Object.assign(new Error(safeText(error.message) || "search failed"), { kind: "no_corpus_answered" });
      }
      if (kind === "timed_out") {
        throw Object.assign(new Error("the brain did not answer within the search timeout"), { kind: "timed_out" });
      }
      throw Object.assign(new Error(safeText(error.message) || "search failed"), { kind });
    } finally {
      this.searchesInFlight -= 1;
    }
  }

  start() {
    this.timer = setInterval(() => this.trigger(), this.config.historyPollMs);
    this.trigger();
  }

  stop() {
    this.stopped = true;
    killProcessTree(this.activeChild);
    killProcessTree(this.searchTimer);
    clearInterval(this.timer);
  }
}

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
    // Each counter names one outcome and only that outcome. An operator reads
    // `oversized` to decide whether to raise the body cap, so a producer that
    // is timing out or resetting its connection must not be reported there.
    this.counters = {
      accepted: 0, duplicate: 0, rejected: 0, throttled: 0, unauthorized: 0,
      oversized: 0, timed_out: 0, read_failed: 0,
    };
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

  // Presence-gated exactly like the rest of this feature, on CREATION. The
  // store is the dashboard's own file OUTSIDE the operational home, so a
  // dashboard with no configured ingest token must not materialize one: a
  // store nothing can write would leave a directory in the operator's state
  // root just for having been connected to, and a file that exists reads as
  // collection whether or not anything was collected.
  //
  // Opening a store that is already there is the other act, and it is a read.
  // Turning instrumentation off stops collection; it does not withdraw access
  // to what was already collected, which is what bin/fm-dashboard-instrument.sh
  // disable promises and what docs/dashboard-events.md records. Storing stays
  // impossible without a token regardless: serveIngest refuses before it reads
  // a body byte, and that is the only route into accept().
  openStore() {
    if (this.store || this.storeError || !this.enabled) return this.store;
    try {
      this.store = this.readToken()
        ? new EventStore(this.config.eventStorePath, this.config.eventLimits)
        : EventStore.openExisting(this.config.eventStorePath, this.config.eventLimits);
    } catch (error) {
      this.storeError = errorRecord("event-store", error, "event_store_unavailable");
      return this.store;
    }
    if (!this.store) return null;
    clearDiagnostic("event-store");
    this.tail = this.store.tail();
    this.lastEventAt = this.tail[0]?.occurred_at ?? null;
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
      return {
        ingestion: "disabled",
        reason: "no instrumentation is configured in this home, so nothing new is collected; events already stored stay readable until they age out",
      };
    }
    return { ingestion: "ready", reason: null };
  }

  envelope() {
    // The tail is only populated by opening the store, so an envelope built
    // before the first POST or timeline read would report an empty stream on a
    // freshly started server whose store is full. The browser connects to the
    // stream and fetches the timeline together, and the frame the stream pushes
    // on connect wins, so an unopened store here shows the reader "no events
    // have arrived yet" until the next accepted event. An unconfigured
    // dashboard opens nothing here; it has no events to be authoritative about.
    this.openStore();
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
    this.refreshing = false;
    this.watchers = [];
    this.fileTimer = null;
    this.pollTimer = null;
    this.heartbeatTimer = null;
    this.staleTimer = null;
    this.stopped = false;
    this.activeChild = null;
    this.durablePending = false;
    this.lastError = config.serviceUnitError ? errorRecord("service-unit", config.serviceUnitError, "service_unit_outdated") : null;
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
    // The backlog view is derived from the same fleet snapshot parse, so it
    // moves exactly when the snapshot does. It has its own topic because the
    // Backlog page consumes its own envelope: the full record set is queue
    // data the inbox deliberately narrows to captain-actionable rows.
    this.clients.send("backlog");
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
    // A trigger that arrives during a read gets the last completed envelope.
    // It is deliberately not queued: starting again immediately after a slow
    // read turns a short poll interval into permanent CPU saturation. The next
    // poll is scheduled from completion, and a later file event may refresh
    // sooner, so freshness is bounded without overlap or catch-up bursts.
    if (this.refreshing || this.config.serviceUnitError) return;
    clearTimeout(this.pollTimer);
    this.pollTimer = null;
    void this.refresh();
  }

  schedulePoll() {
    clearTimeout(this.pollTimer);
    this.pollTimer = null;
    if (this.stopped || this.config.serviceUnitError) return;
    this.pollTimer = setTimeout(() => {
      this.pollTimer = null;
      this.trigger("poll");
    }, this.config.pollMs);
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
      clearDiagnostic("snapshot");
    } catch (error) {
      this.lastError = errorRecord("snapshot", error, "snapshot_failed");
    } finally {
      this.refreshing = false;
      this.scheduleStaleTransition();
      this.broadcast();
      this.schedulePoll();
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
    if (this.config.serviceUnitError) {
      this.lastAttemptAt = nowIso();
      this.broadcast();
    } else {
      this.trigger("startup");
    }
  }

  stop() {
    this.stopped = true;
    killProcessTree(this.activeChild);
    clearTimeout(this.pollTimer);
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
// crossed rather than after the fact. Resolves { body } when the whole body
// arrived, or { failed } naming which bound was crossed once the response has
// been answered - three different operational facts, so the caller can count
// them as three rather than calling a timing-out producer an oversized one.
const BODY_FAILURE_COUNTER = {
  body_too_large: "oversized",
  body_deadline: "timed_out",
  read_failed: "read_failed",
};

function readBoundedBody(request, response) {
  return new Promise((resolve) => {
    let bytes = 0;
    const chunks = [];
    let settled = false;
    const refuse = (status, failed, body) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      request.removeAllListeners("data");
      request.removeAllListeners("end");
      request.removeAllListeners("error");
      sendJson(response, status, body);
      request.destroy();
      resolve({ failed });
    };
    const done = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ body: value });
    };
    const timer = setTimeout(
      () => refuse(408, "body_deadline", { schema: INGEST_SCHEMA, accepted: 0, reason: "body_deadline" }),
      EVENT_BODY_DEADLINE_MS,
    );
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > EVENT_BODY_MAX_BYTES) {
        refuse(413, "body_too_large", { schema: INGEST_SCHEMA, accepted: 0, reason: "body_too_large", max_bytes: EVENT_BODY_MAX_BYTES });
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => done(Buffer.concat(chunks).toString("utf8")));
    request.on("error", () => refuse(400, "read_failed", { schema: INGEST_SCHEMA, accepted: 0, reason: "read_failed" }));
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

  const read = await readBoundedBody(request, response);
  if (read.failed) {
    events.counters[BODY_FAILURE_COUNTER[read.failed]] += 1;
    return;
  }
  let document;
  try {
    document = JSON.parse(read.body);
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
    clearDiagnostic("event-ingest");
  } catch (error) {
    const failure = logDiagnostic("event-ingest", displayError(error, "store_write_failed"));
    sendJson(response, 503, { schema: INGEST_SCHEMA, accepted: 0, reason: failure.kind, detail: failure.message });
    return;
  }
  if (!stored) {
    sendJson(response, 503, { schema: INGEST_SCHEMA, accepted: 0, reason: "store_unavailable" });
    return;
  }
  sendJson(response, 202, { schema: INGEST_SCHEMA, accepted: stored.stored, duplicate: stored.duplicate, rejected });
}

// Read a bounded JSON body for the search endpoint. The body is small: one
// query string and one limit. The byte cap is well above the largest valid
// input, so a real request never trips it; a giant body is a probing attempt
// and is refused before the brain sees it. Same shape as the ingest reader
// but with a separate cap and a much tighter deadline: a search has to come
// back inside the dashboard's polling window or it never renders at all.
const SEARCH_BODY_MAX_BYTES = 4096;
const SEARCH_BODY_DEADLINE_MS = 4_000;

function readSearchBody(request, response) {
  return new Promise((resolve) => {
    let bytes = 0;
    const chunks = [];
    let settled = false;
    const refuse = (status, body) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      request.removeAllListeners("data");
      request.removeAllListeners("end");
      request.removeAllListeners("error");
      sendJson(response, status, body);
      request.destroy();
      resolve({ failed: true });
    };
    const timer = setTimeout(
      () => refuse(408, { schema: GBRAIN_SEARCH_SCHEMA, results: [], reason: "body_deadline" }),
      SEARCH_BODY_DEADLINE_MS,
    );
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > SEARCH_BODY_MAX_BYTES) {
        refuse(413, { schema: GBRAIN_SEARCH_SCHEMA, results: [], reason: "body_too_large", max_bytes: SEARCH_BODY_MAX_BYTES });
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ body: Buffer.concat(chunks).toString("utf8") });
    });
    request.on("error", () => refuse(400, { schema: GBRAIN_SEARCH_SCHEMA, results: [], reason: "read_failed" }));
  });
}

// POST /api/gbrain/search - the read-only GBrain search endpoint.
//
// The dashboard fires this when the operator types a question and presses
// return. Every value above the wrapper boundary is a structured JSON
// document; nothing on this path can pick a command, pick an argument, or
// pick a fleet path, and the wrapper itself never interpolates the query
// into a shell. A body that cannot be parsed as JSON or that fails the
// shape below is refused before the wrapper runs.
async function serveGBrainSearch(request, response, gbraintron) {
  const read = await readSearchBody(request, response);
  if (read.failed) return;
  let document;
  try {
    document = JSON.parse(read.body || "{}");
  } catch {
    sendJson(response, 400, { schema: GBRAIN_SEARCH_SCHEMA, results: [], reason: "malformed_json" });
    return;
  }
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    sendJson(response, 400, { schema: GBRAIN_SEARCH_SCHEMA, results: [], reason: "malformed_json" });
    return;
  }
  if (typeof document.query !== "string") {
    sendJson(response, 400, { schema: GBRAIN_SEARCH_SCHEMA, results: [], reason: "missing_query" });
    return;
  }
  if (document.limit !== undefined && (!Number.isFinite(document.limit) || !Number.isInteger(document.limit) || document.limit < 1)) {
    sendJson(response, 400, { schema: GBRAIN_SEARCH_SCHEMA, results: [], reason: "invalid_limit" });
    return;
  }
  try {
    const payload = await gbraintron.search(document.query, document.limit);
    clearDiagnostic("gbrain-search");
    sendJson(response, 200, payload);
  } catch (error) {
    const status = error.kind === "timed_out" ? 504
      : error.kind === "search_busy" ? 429
        : error.kind === "query_too_short" || error.kind === "query_too_large" ? 400
          : error.kind === "no_corpus_answered" || error.kind === "search_setup_failed" ? 503
            : 502;
    const failure = logDiagnostic("gbrain-search", displayError(error, error.kind || "search_failed"));
    sendJson(response, status, {
      schema: GBRAIN_SEARCH_SCHEMA,
      results: [],
      reason: failure.kind,
      detail: failure.message,
    });
  }
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
  const auth = new AuthState(config);
  auth.read({ force: true });
  // The exposure gate. A bind beyond loopback is refused here, before the
  // socket exists, so there is no window in which the dashboard is reachable
  // off this host without a credential behind it.
  if (!config.loopback) {
    if (config.auth === "off") {
      throw new Error(`FM_DASHBOARD_AUTH=off is only supported on a loopback bind, not ${config.address}`);
    }
    if (auth.error) throw new Error(auth.error);
    if (!auth.credential) {
      throw new Error(`binding ${config.address} beyond loopback requires dashboard credentials in ${config.authFile} - run bin/fm-dashboard-install.sh --set-password`);
    }
    auth.enforced = true;
  }
  const clients = new SseClients();
  const history = new HistoryState(config, clients);
  const events = new EventsState(config, clients);
  const gbraintron = new GBrainState(config, clients);
  const state = new DashboardState(config, clients, history);
  clients.register("snapshot", () => state.envelope());
  // The backlog envelope shares the snapshot's status and refresh cadence -
  // it IS a view of the snapshot's backlog section, never a second parse of
  // data/backlog.md. One owner for the file format, one freshness story.
  const backlogEnvelope = () => {
    const envelope = state.envelope();
    return {
      schema: BACKLOG_ENVELOPE_SCHEMA,
      status: envelope.status,
      config: envelope.config,
      backlog: envelope.snapshot?.backlog && typeof envelope.snapshot.backlog === "object"
        ? envelope.snapshot.backlog
        : null,
    };
  };
  clients.register("backlog", backlogEnvelope);
  clients.register("history", () => history.envelope());
  clients.register("agent_events", () => events.envelope());
  clients.register("gbrain_health", () => gbraintron.envelope());
  const handler = async (request, response) => {
    securityHeaders(response);
    const pathname = new URL(request.url, "http://loopback.invalid").pathname;
    if (request.method === "POST" && pathname === "/events") {
      if (!sameOriginRequest(request)) {
        sendJson(response, 403, { schema: INGEST_SCHEMA, accepted: 0, reason: "cross_origin" });
        request.destroy();
        return;
      }
      await serveIngest(request, response, events);
      return;
    }
    // The GBrain search endpoint is POST-only and is gated by the same
    // authorize() handler the GET routes use, so it stays behind the same
    // authentication boundary as the rest of the browser-facing surface. On a
    // loopback bind with no credentials file authorize() passes everything, so
    // the same-origin refusal the ingest route uses is what keeps another page
    // in the operator's browser from spending the brain's one search slot.
    if (pathname === "/api/gbrain/search") {
      if (request.method !== "POST") {
        response.writeHead(405, { Allow: "POST", "Content-Type": "text/plain; charset=utf-8" });
        response.end("method not allowed\n");
        return;
      }
      if (!sameOriginRequest(request)) {
        sendJson(response, 403, { schema: GBRAIN_SEARCH_SCHEMA, results: [], reason: "cross_origin" });
        request.destroy();
        return;
      }
      if (!(await authorize(request, response, auth))) return;
      await serveGBrainSearch(request, response, gbraintron);
      return;
    }
    if (!(await authorize(request, response, auth))) return;
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
    if (pathname === "/api/backlog") {
      response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      response.end(`${JSON.stringify(backlogEnvelope())}\n`);
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
    if (pathname === "/api/gbrain/health") {
      response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      response.end(`${JSON.stringify(gbraintron.envelope())}\n`);
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
  };

  // An exposed bind still keeps loopback. The reporting hooks post their events
  // to the loopback dashboard and nowhere else, and a browser on this host
  // reaches it the same way, so binding only the outward address would take
  // both away in exchange for the one that was added. Loopback is not an
  // exposure, and every listener answers through the same handler, so the same
  // authentication applies to all of them.
  //
  // A wildcard bind is already answering there, so it gets no companion: the
  // second listener would be a second socket on an address this process holds,
  // and the service would fail to start on the very configuration the installer
  // permits with a warning.
  const addresses = [config.address];
  if (!config.loopback && !coversLoopback(config.address)) addresses.push("127.0.0.1");
  const servers = [];
  for (const address of addresses) {
    const server = http.createServer(handler);
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(config.port, address, resolve);
    });
    server.removeAllListeners("error");
    server.on("error", (error) => console.error(`fm-dashboard: ${safeText(error.message)}`));
    servers.push(server);
  }
  await state.start();
  history.start();
  gbraintron.start();
  const access = auth.enforced ? "authenticated" : "no authentication configured (loopback only)";
  const shown = addresses.map((address) => (address.includes(":") ? `[${address}]` : address));
  const trusted = config.trustedProxies.entries.length
    ? `, forwarded client addresses trusted from ${config.trustedProxies.entries.join(" ")}`
    : ", no trusted proxy (clients are throttled by the address they arrive from)";
  console.log(`fm-dashboard: listening on ${shown.map((a) => `http://${a}:${config.port}`).join(" and ")} - ${access}${trusted}`);

  let shuttingDown = false;
  const shutdown = (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.error(`fm-dashboard: received ${signal}; shutting down cleanly`);
    state.stop();
    history.stop();
    events.stop();
    gbraintron.stop();
    clients.stop();
    let remaining = servers.length;
    for (const server of servers) {
      server.close(() => {
        remaining -= 1;
        if (remaining === 0) process.exit(0);
      });
    }
  };
  process.once("SIGINT", () => shutdown("SIGINT"));
  process.once("SIGTERM", () => shutdown("SIGTERM"));
  process.once("beforeExit", (code) => {
    console.error(`fm-dashboard: event loop drained unexpectedly with exit code ${code}; treating the clean exit as a failure`);
    process.exitCode = 1;
  });
}

// Every request handler is an async callback, so a rejection one of them fails
// to catch would reach Node's default --unhandled-rejections=throw and take the
// whole view down. A read-only loopback dashboard reports the request it could
// not answer and keeps serving the rest.
process.on("unhandledRejection", (error) => {
  console.error(`fm-dashboard: unhandled rejection: ${safeText(error instanceof Error ? error.message : String(error))}`);
});

// Turn one password into the credentials document the server verifies against.
//
// The password arrives on standard input and never in an argument vector, so it
// is not in the process table, a shell history, or a systemd log while it is
// being set. Only the derived digest is ever printed, and the caller is what
// gives the result its restrictive mode.
async function hashPasswordMode(argv) {
  const flag = argv.indexOf("--username");
  const username = flag >= 0 ? argv[flag + 1] : "captain";
  if (!AUTH_USERNAME_PATTERN.test(String(username || ""))) {
    throw new Error("--username must be 1-64 characters of letters, digits, dot, dash, or underscore");
  }
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const password = Buffer.concat(chunks).toString("utf8").replace(/\r?\n$/, "");
  if (password.length < AUTH_PASSWORD_MIN) {
    throw new Error(`the dashboard password must be at least ${AUTH_PASSWORD_MIN} characters`);
  }
  const salt = randomBytes(16);
  const { keylen, ...cost } = AUTH_SCRYPT_COST;
  const hash = await scryptAsync(password, salt, keylen, cost);
  console.log(JSON.stringify({
    schema: AUTH_SCHEMA,
    username,
    kdf: "scrypt",
    salt: salt.toString("base64"),
    hash: hash.toString("base64"),
    cost: { ...cost, keylen },
  }, null, 2));
}

// Answer whether the credentials on disk are ones this server could serve
// behind, and print the username they carry when they are.
//
// The installer gates exposure on this rather than on the file existing,
// because a file that is there but group-readable, truncated, or written with
// work factors this server will not accept is not a credential: accepting it as
// one writes a unit for a service that cannot come up. One owner of the rule is
// the only way the two gates cannot drift apart.
function checkCredentialsMode(argv) {
  const flag = argv.indexOf("--auth-file");
  const authFile = flag >= 0 && argv[flag + 1] ? argv[flag + 1] : resolveAuthFile();
  const auth = new AuthState({ auth: "auto", authFile });
  auth.read({ force: true });
  if (auth.error) throw new Error(auth.error);
  if (!auth.credential) {
    throw new Error(`there are no dashboard credentials in ${authFile} - ${AUTH_RECOVERY}`);
  }
  console.log(auth.credential.username);
}

// The non-serving modes, and the rule that an argument this version does not
// know is refused rather than ignored.
//
// Ignoring one means serving, so a caller probing for a mode a checkout does
// not have would get an HTTP listener where it expected one line of output, and
// wait for a stdout that never closes. Nothing but a mode flag and its value is
// accepted, and no argument at all still serves.
const SERVER_MODES = new Set(["--event-store-path", "--check-credentials", "--check-trusted-proxies", "--check-service-unit-cgroup", "--hash-password"]);
const SERVER_MODE_VALUES = new Set(["--auth-file", "--username"]);

function parseServerMode(argv) {
  const modes = [];
  let values = 0;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (SERVER_MODES.has(argument)) {
      modes.push(argument);
      continue;
    }
    if (SERVER_MODE_VALUES.has(argument)) {
      if (index + 1 >= argv.length) throw new Error(`${argument} requires a value`);
      values += 1;
      index += 1;
      continue;
    }
    throw new Error(`unrecognised argument: ${argument}`);
  }
  if (modes.length > 1) throw new Error(`only one of ${[...SERVER_MODES].join(", ")} may be given at a time`);
  if (modes.length === 0 && values > 0) throw new Error("a value option was given with no mode to use it");
  return modes[0] || null;
}

// The first mode prints where this configuration would keep its agent-event
// store: the installer needs that path to grant the hardened user service write
// access to exactly that directory and nothing else, and a single owner of the
// rule beats two programs deriving it. The second reports whether the stored
// credentials are usable, the third echoes the trusted-proxy allowlist this
// server would honour, the fourth classifies supplied cgroup evidence, and the
// fifth derives a password digest to store.
let serverMode = null;
try {
  serverMode = parseServerMode(process.argv.slice(2));
} catch (error) {
  console.error(`fm-dashboard: ${safeText(error.message)}`);
  process.exit(2);
}
if (serverMode === "--event-store-path") {
  const fmHome = path.resolve(process.env.FM_HOME || ROOT);
  console.log(resolveEventStorePath(fmHome));
} else if (serverMode === "--check-credentials") {
  try {
    checkCredentialsMode(process.argv);
  } catch (error) {
    console.error(`fm-dashboard: ${safeText(error.message)}`);
    process.exit(1);
  }
} else if (serverMode === "--check-trusted-proxies") {
  try {
    console.log(resolveTrustedProxies().entries.join(","));
  } catch (error) {
    console.error(`fm-dashboard: ${safeText(error.message)}`);
    process.exit(1);
  }
} else if (serverMode === "--check-service-unit-cgroup") {
  console.log(cgroupContainsServiceUnit(fsReadFileSync(0, "utf8")) ? "service" : "other");
} else if (serverMode === "--hash-password") {
  hashPasswordMode(process.argv).catch((error) => {
    console.error(`fm-dashboard: ${safeText(error.message)}`);
    process.exit(1);
  });
} else {
  main().catch((error) => {
    console.error(`fm-dashboard: ${safeText(error.message)}`);
    process.exit(1);
  });
}
