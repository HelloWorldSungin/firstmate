// fm-telemetry-store.mjs - the one store discipline the fleet's telemetry uses.
//
// Firstmate keeps two telemetry stores, and they are two files for a reason
// rather than by accident:
//
//   data/usage.db  the token-usage store (bin/fm-usage.mjs, docs/usage-accounting.md).
//                  It lives under the operational home because the collector is a
//                  fleet-side program that already reads and writes there.
//   the agent-event store (bin/fm-event-store.mjs, docs/dashboard-events.md).
//                  It lives OUTSIDE the operational home because its only writer
//                  is the dashboard, and the dashboard's whole safety posture is
//                  that it writes nothing a fleet program owns. Its user service
//                  runs under ProtectSystem=strict and ProtectHome=read-only, so
//                  putting events in data/usage.db would mean granting that
//                  service write access to the fleet's data directory - which is
//                  exactly the guarantee the dashboard exists without.
//
// What the two stores DO share is this module: one opener, one migration
// discipline, one set of value sanitizers, one timestamp normalizer. A field
// sanitized here means the same thing in both stores, and a rollup can join them
// on task_id because both spell a task id, a harness, and an instant the same
// way. Adding a third telemetry surface means adding a migration list, not
// another opinion about how a store behaves.
//
// Node 22 or newer is required for the built-in node:sqlite module.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

// node:sqlite emits an ExperimentalWarning on import under Node 22. Replace the
// default printer with one that drops exactly that warning, so a routine
// collector or dashboard run keeps a clean stderr while every other warning
// still prints.
process.removeAllListeners("warning");
process.on("warning", (warning) => {
  if (warning.name === "ExperimentalWarning" && /SQLite/i.test(warning.message)) return;
  console.error(`${warning.name}: ${warning.message}`);
});
const { DatabaseSync } = await import("node:sqlite");

// How long a writer waits for another writer to get out of the way. Telemetry
// writer windows overlap by design - a collector on a cadence, teardown's
// best-effort call for the task it is about to archive, a dashboard accepting a
// burst of events - so losing a race has to mean waiting, never "database is
// locked" with nothing recorded at all.
export const BUSY_TIMEOUT_MS = 10000;

export const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

// One canonical second-resolution UTC form, so identity and ordering never
// depend on whether a source wrote milliseconds.
export function normalizeIso(value) {
  if (typeof value !== "string" || !ISO_RE.test(value)) return null;
  const epoch = Date.parse(value);
  if (!Number.isFinite(epoch)) return null;
  return new Date(Math.floor(epoch / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function isoToEpoch(value) {
  const epoch = Date.parse(value);
  return Number.isFinite(epoch) ? Math.floor(epoch / 1000) : null;
}

// Non-negative integer or 0. Source counters are copied verbatim when they are
// well-formed and dropped to 0 when they are not, so one malformed field never
// poisons a total.
export function count(value) {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

// One control-character-free, length-capped line, or null. Every string a
// telemetry writer stores passes through here, so no source line can carry a
// control character or an unbounded value into a store.
export function cleanToken(value, max = 128) {
  if (typeof value !== "string") return null;
  const trimmed = value.replace(/[\u0000-\u001f\u007f]/g, "").trim();
  if (!trimmed || trimmed.length > max) return null;
  return trimmed;
}

export function digest(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function readJsonFile(file) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile()) return null;
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

// Atomic, private publication: same-directory temp file, mode 0600, rename. A
// reader sees the previous complete document or the new one, never a torn one.
export function writeJsonFile(file, value) {
  const dir = path.dirname(file);
  const tmp = path.join(dir, `.fm-telemetry.${process.pid}.${crypto.randomBytes(4).toString("hex")}`);
  try {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(tmp, `${JSON.stringify(value)}\n`, { mode: 0o600 });
    fs.renameSync(tmp, file);
    return true;
  } catch {
    try {
      fs.rmSync(tmp, { force: true });
    } catch {
      /* the temp file is already gone */
    }
    return false;
  }
}

// A synchronous pause. Store opening happens before any asynchronous stage can
// start, so the one place that has to wait waits synchronously.
export function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// PRAGMA journal_mode does NOT honor the busy timeout: SQLite takes the brief
// exclusive lock that switching a store to WAL needs without ever calling the
// busy handler, so a second writer creating the same store gets SQLITE_BUSY back
// in well under a millisecond however long the timeout is. The switch is
// therefore retried explicitly on the same budget. Only the first open of a
// store can contend at all - a store that is already in WAL needs no lock to be
// told it is in WAL, which is why steady-state overlapping runs never wait here.
function enableWalMode(db) {
  const deadline = Date.now() + BUSY_TIMEOUT_MS;
  for (;;) {
    try {
      db.exec("PRAGMA journal_mode = WAL");
      return;
    } catch (error) {
      const busy = /\b(locked|busy)\b/i.test(String(error?.message ?? error));
      if (!busy || Date.now() >= deadline) throw error;
      sleepMs(20);
    }
  }
}

// Every migration is append-only and runs inside one transaction against
// PRAGMA user_version, so an older store upgrades in place and a newer store is
// refused rather than silently downgraded.
export function migrate(db, migrations) {
  const target = migrations[migrations.length - 1].version;
  const version = () => db.prepare("PRAGMA user_version").get().user_version ?? 0;
  const opening = version();
  if (opening > target) {
    throw new Error(`store schema version ${opening} is newer than this program understands (${target})`);
  }
  for (const migration of migrations) {
    if (migration.version <= opening) continue;
    // BEGIN IMMEDIATE, and the version is re-read inside that write transaction:
    // two writers opening the same new store both read version 0 outside any
    // transaction, so the one that arrives second must observe the winner's
    // committed version and skip a migration already applied rather than re-run
    // its CREATE TABLEs and die on "table already exists".
    db.exec("BEGIN IMMEDIATE");
    try {
      if (version() >= migration.version) {
        db.exec("COMMIT");
        continue;
      }
      for (const statement of migration.statements) db.exec(statement);
      db.exec(`PRAGMA user_version = ${migration.version}`);
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  }
}

// Open one telemetry store against its own migration list. With create false a
// store that does not exist yet is reported as absent rather than conjured, so a
// read-only consumer never creates the file it was only asking about.
//
// readOnly opens for query-only consumers such as the dashboard service, which
// runs under ProtectHome=read-only and must not attempt WAL setup or migration
// writes against data/usage.db even though it never mutates fleet state itself.
export function openStore(dbPath, migrations, { create = true, readOnly = false } = {}) {
  const dir = path.dirname(dbPath);
  if (create) fs.mkdirSync(dir, { recursive: true });
  if (!create && !fs.existsSync(dbPath)) return null;
  const db = readOnly ? new DatabaseSync(dbPath, { readOnly: true }) : new DatabaseSync(dbPath);
  // The busy timeout is installed FIRST, before anything that can contend, so
  // every later statement waits for a competing writer instead of failing.
  db.exec(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
  if (readOnly) {
    db.exec("PRAGMA foreign_keys = ON");
    const target = migrations[migrations.length - 1].version;
    const version = db.prepare("PRAGMA user_version").get().user_version ?? 0;
    if (version > target) {
      throw new Error(`store schema version ${version} is newer than this program understands (${target})`);
    }
    if (version < target) {
      throw new Error(`store schema version ${version} is older than this program understands (${target}); run ingest or migrate`);
    }
    return db;
  }
  enableWalMode(db);
  db.exec("PRAGMA foreign_keys = ON");
  migrate(db, migrations);
  try {
    fs.chmodSync(dbPath, 0o600);
  } catch {
    /* a store on a filesystem without modes stays usable */
  }
  return db;
}
