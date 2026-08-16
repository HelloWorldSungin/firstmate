#!/usr/bin/env bash
# Behavior tests for the dashboard's Backlog page policy (backlog.js) and its
# GET /api/backlog endpoint.
#
# The endpoint case runs the REAL server over the REAL fm-fleet-snapshot.sh
# backlog parse of a real data/backlog.md, seeded with more records than the
# compact fleet listing truncates at, because the whole point of the endpoint
# is the full record set: a fixture envelope that happened to be small would
# prove nothing about the page the truncation bug motivated.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-dashboard-backlog)
# shellcheck disable=SC2034 # Snapshot is asserted by fm_user_event_store_snapshot's lib caller.
USER_EVENT_STORE_BEFORE=$(fm_user_event_store_snapshot)
SERVER_PID=

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

# --- the page policy: queue shape, tabs, filters, pagination -----------------

node - "$ROOT/assets/dashboard/backlog.js" <<'NODE' || fail "dashboard backlog page policy failed"
const { pathToFileURL } = require("node:url");

(async () => {
const { buildBacklog, BACKLOG_LIMITS } = await import(pathToFileURL(process.argv[2]).href);

const failures = [];
function check(label, condition, detail = "") {
  if (!condition) failures.push(`${label}${detail ? `: ${detail}` : ""}`);
}
function equal(label, actual, expected) {
  check(label, JSON.stringify(actual) === JSON.stringify(expected),
    `expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
}

function envelope(records, status = { phase: "ready" }) {
  return { schema: "fm-dashboard-backlog.v1", status, backlog: { present: true, records } };
}

// --- the three empty shapes stay distinct ------------------------------------
equal("no envelope at all is not a present backlog", buildBacklog(null, {}).present, false);
equal("no envelope is a pending read", buildBacklog(null, {}).readState, "pending");
check("no envelope carries no error", buildBacklog(null, {}).error === null);
const unavailable = buildBacklog({ schema: "fm-dashboard-backlog.v1", status: { phase: "unavailable", error: { message: "the read failed" } } }, {});
equal("an unreadable backlog is not a present backlog", unavailable.present, false);
equal("an unreadable backlog has its own read state", unavailable.readState, "unavailable");
check("an unreadable backlog is disclosed as unreadable", unavailable.error !== null && unavailable.error.text.includes("the read failed"));
const absent = buildBacklog({ schema: "fm-dashboard-backlog.v1", status: { phase: "first_run" }, backlog: { present: false, records: [] } }, {});
equal("a first-run absent backlog has its own read state", absent.readState, "absent");
equal("an in-progress first read stays pending", buildBacklog({ schema: "fm-dashboard-backlog.v1", status: { phase: "first_run", refreshing: true }, backlog: null }).readState, "pending");
const genuinelyEmpty = buildBacklog(envelope([]), {});
equal("a successfully read empty backlog stays present", genuinelyEmpty.present, true);
equal("a successfully read empty backlog is ready", genuinelyEmpty.readState, "ready");

// --- done rows belong to History, not the queue ------------------------------
const mixed = buildBacklog(envelope([
  { id: "a1", title: "Queued thing", state: "queued", order: 1 },
  { id: "a2", title: "Delivered thing", state: "done", order: 2 },
  { id: "a3", title: "Held thing", state: "queued", hold_reason: "waiting on the captain", order: 3 },
  { id: "a4", title: "Blocked thing", state: "queued", blocked_by: "a1", blocked_reason: "needs a1 first", order: 4 },
  { id: "a5", title: "Running thing", state: "in_flight", order: 5 },
]), {});
equal("a done row leaves the queue", mixed.queueTotal, 4);
equal("a done transition remains available to task lookup", mixed.taskRecords.find((row) => row.id === "a2")?.state, "done");
equal("the All tab counts the whole current queue", mixed.tabs.all, 4);
equal("a held row lands on the Held tab", mixed.tabs.held, 1);
equal("a blocked row lands on the Blocked tab", mixed.tabs.blocked, 1);
equal("an in-flight row lands on the In flight tab", mixed.tabs.in_flight, 1);
equal("the rest stay queued", mixed.tabs.queued, 1);
const held = mixed.rows.find((row) => row.id === "a3");
check("a held row carries its reason", held && held.reason === "waiting on the captain");
check("a held row is toned amber", held && held.stateTone === "amber");
const blocked = mixed.rows.find((row) => row.id === "a4");
check("a blocked row carries its reason", blocked && blocked.reason === "needs a1 first");
check("a blocked row is toned red", blocked && blocked.stateTone === "red");

// --- file order IS the queue order -------------------------------------------
equal("rows keep the backlog file's own order", mixed.rows.map((row) => row.id), ["a1", "a3", "a4", "a5"]);

// --- filtered-to-nothing stays distinct from genuinely empty -----------------
const filtered = buildBacklog(envelope([
  { id: "b1", title: "Alpha", state: "queued", repo: "proj-a", order: 1 },
  { id: "b2", title: "Beta", state: "queued", repo: "proj-b", order: 2 },
]), { query: "no such thing" });
equal("a search that matches nothing still knows the queue size", filtered.queueTotal, 2);
equal("a search that matches nothing matches nothing", filtered.page.matched, 0);
check("the backlog stays present while filtered to nothing", filtered.present);

// --- facets come from the queue, search is title+project+id ------------------
equal("project facet values", filtered.facets.project, ["proj-a", "proj-b"]);
const byId = buildBacklog(envelope([
  { id: "c-needle-1", title: "Alpha", state: "queued", order: 1 },
  { id: "c2", title: "Beta", state: "queued", order: 2 },
]), { query: "needle" });
equal("search matches ids too", byId.rows.map((row) => row.id), ["c-needle-1"]);

// --- an unknown age is disclosed, never a fabricated zero --------------------
const ages = buildBacklog(envelope([
  { id: "d1", title: "Dated", state: "queued", since_age_seconds: 3600, order: 1 },
  { id: "d2", title: "Undated", state: "queued", order: 2 },
]), {});
equal("a known age renders", ages.rows[0].age, "1h");
equal("an unknown age is null, not zero", ages.rows[1].age, null);
const priorities = buildBacklog(envelope([
  { id: "p0", title: "Explicit", state: "queued", priority: 0, order: 1 },
  { id: "missing", title: "Missing", state: "queued", priority: null, order: 2 },
  { id: "blank", title: "Blank", state: "queued", priority: "", order: 3 },
]), {});
equal("only an explicit zero becomes P0", priorities.rows.map((row) => row.prio), [0, null, null]);
equal("the priority facet excludes missing values", priorities.facets.prio, [0]);

// --- pagination bounds -------------------------------------------------------
const many = envelope(Array.from({ length: BACKLOG_LIMITS.pageSize * 2 + 3 }, (_, index) => (
  { id: `e${String(index).padStart(3, "0")}`, title: `Item ${index}`, state: "queued", order: index }
)));
const pageLast = buildBacklog(many, { page: 99 });
equal("a page index past the end clamps to the last page", pageLast.page.index, 2);
equal("the last page carries the remainder", pageLast.rows.length, 3);
equal("page bounds are one-based and honest", [pageLast.page.first, pageLast.page.last], [BACKLOG_LIMITS.pageSize * 2 + 1, BACKLOG_LIMITS.pageSize * 2 + 3]);
const pageNegative = buildBacklog(many, { page: -5 });
equal("a negative page index clamps to the first page", pageNegative.page.index, 0);

if (failures.length) {
  console.error(`${failures.length} backlog policy failure(s):`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log("dashboard backlog page policy verified");
})().catch((error) => { console.error(error); process.exit(1); });
NODE

pass "the backlog page policy keeps queue order, distinct empty shapes, honest ages, and bounded pages"

# --- GET /api/backlog serves the full record set through the real parse ------

test_backlog_endpoint_serves_the_full_record_set() {
  local home port body count ids
  home="$TMP_ROOT/endpoint/home"
  mkdir -p "$home/data" "$home/state" "$home/projects"
  {
    printf '## In flight\n'
    printf -- '- [ ] flight-1 - The one in flight (repo: proj-live, kind: fix)\n'
    printf '\n## Queued\n'
    # More records than the compact fleet listing truncates at (80), because
    # serving the FULL set is the endpoint's reason to exist.
    local index
    for index in $(seq 1 90); do
      printf -- '- [ ] queued-%03d - Queued item %d (repo: proj-%d, kind: chore, priority: %d, since 2026-08-01)\n' \
        "$index" "$index" $((index % 3)) $((index % 4))
    done
    printf -- '- [ ] held-1 - The held one (repo: proj-h, hold: waiting on the captain)\n'
    printf '\n## Done\n'
    printf -- '- [x] done-1 - The delivered one (repo: proj-d, done 2026-08-10)\n'
  } > "$home/data/backlog.md"

  port=$(free_port)
  FM_DASHBOARD_ADDRESS=127.0.0.1 \
  FM_DASHBOARD_PORT=$port \
  FM_DASHBOARD_AUTH=off \
  FM_DASHBOARD_EVENTS=off \
  FM_DASHBOARD_USAGE=off \
  FM_DASHBOARD_TIMEOUT_SECONDS=8 \
  FM_DASHBOARD_POLL_SECONDS=1 \
  FM_HOME="$home" \
  node "$ROOT/bin/fm-dashboard-server.mjs" >"$TMP_ROOT/endpoint/server.log" 2>&1 &
  SERVER_PID=$!

  local attempt=0
  body=
  while [ "$attempt" -lt 40 ]; do
    if body=$(curl -fsS "http://127.0.0.1:$port/api/backlog" 2>/dev/null) \
      && [ "$(printf '%s' "$body" | jq -r '.status.phase')" = ready ]; then
      break
    fi
    body=
    attempt=$((attempt + 1))
    sleep 0.25
  done
  [ -n "$body" ] || fail "GET /api/backlog never answered ready: $(tail -5 "$TMP_ROOT/endpoint/server.log" 2>/dev/null)"

  [ "$(printf '%s' "$body" | jq -r '.schema')" = "fm-dashboard-backlog.v1" ] \
    || fail "the backlog envelope schema is wrong: $(printf '%s' "$body" | jq -r '.schema')"
  [ "$(printf '%s' "$body" | jq -r '.backlog.present')" = true ] \
    || fail "a real backlog file was not reported present"
  count=$(printf '%s' "$body" | jq '[.backlog.records[] | select(.id != null)] | length')
  [ "$count" -eq 93 ] \
    || fail "the endpoint truncated the record set: served $count of the 93 written records"
  ids=$(printf '%s' "$body" | jq -r '[.backlog.records[].id | select(. != null)] | join(" ")')
  case "$ids" in
    *queued-090*) : ;;
    *) fail "the 90th queued record is missing, so the compact-listing truncation survived: $ids" ;;
  esac
  [ "$(printf '%s' "$body" | jq -r '[.backlog.records[] | select(.id == "held-1")] | .[0].hold_reason')" = "waiting on the captain" ] \
    || fail "the held record lost its hold reason through the endpoint"
  [ "$(printf '%s' "$body" | jq -r '[.backlog.records[] | select(.id == "done-1")] | .[0].state')" = "done" ] \
    || fail "the done record lost its section state through the endpoint"

  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=
  pass "GET /api/backlog serves the full parsed record set, beyond the compact listing's truncation"
}

test_backlog_endpoint_serves_the_full_record_set

printf '\nall fm-dashboard-backlog tests passed\n'
