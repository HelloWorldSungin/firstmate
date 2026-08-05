#!/usr/bin/env bash
# Behavior tests for the dashboard's live per-agent event timeline: the
# authenticated ingest boundary, the store's redaction and retention, the
# producer's fail-open guarantees, the per-task harness wiring bin/fm-spawn.sh
# installs, and the browser's timeline policy.
#
# The cases that matter most here are not the happy path. They are the ones that
# would let this feature hurt something else: a hook that could change what a
# guard decides, a producer that could stall an agent because a dashboard is
# down, a payload that could carry a credential into a store or onto a page, and
# an instrumentation switch that does not fully switch off.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ROOT is the repo root exported by tests/lib.sh; the per-case `root` locals
# below are a different thing entirely.
# shellcheck disable=SC2153
SERVER="$ROOT/bin/fm-dashboard-server.mjs"
EMIT="$ROOT/bin/fm-event-emit.sh"
INSTRUMENT="$ROOT/bin/fm-dashboard-instrument.sh"
STORE="$ROOT/bin/fm-event-store.mjs"
SPAWN="$ROOT/bin/fm-spawn.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null \
  || { echo "skip: node:sqlite not available (Node 22+ required)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-dashboard-events)
# What the operator's own state root held before this suite ran. The store lives
# outside every FM_HOME by design, so this is what proves none of the servers
# below put one there.
USER_EVENT_STORE_BEFORE=$(fm_user_event_store_snapshot)
SERVER_PID=
SSE_PID=
TEST_PORT=
TOKEN=
# The dashboard stand-ins publish their port in HELPER_PORT rather than on
# standard output: a helper started inside a command substitution would leave
# its pid in a subshell, and an unkillable listener outlives the whole suite.
HELPER_PORT=
HELPER_PIDS=()

stop_helpers() {
  local pid
  for pid in "${HELPER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  HELPER_PIDS=()
  return 0
}

cleanup() {
  local pid
  for pid in "$SSE_PID" "$SERVER_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  stop_helpers
  fm_test_cleanup || true
  return 0
}
trap cleanup EXIT HUP INT TERM

# The seeded hostile values. Each is shaped like something that must never
# survive either redaction boundary: a private path, a vendor key, and an
# opaque high-entropy token.
SEED_PATH='/home/sungin/.ssh/id_rsa'
SEED_KEY='sk-ant-api03-NOTREAL9'
SEED_TOKEN='ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345'

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

# --- fixtures ---------------------------------------------------------------

make_case() {  # <name> - a home, a fixed snapshot command, and an instrumentation config
  local name=$1 root
  root="$TMP_ROOT/$name"
  mkdir -p "$root/home/data" "$root/home/state" "$root/home/projects" "$root/bin" "$root/config"
  cat > "$root/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '{"schema":"fm-fleet-snapshot.v1","generated":"2026-08-04T00:00:00Z","tasks":[],"card_precedence":[],"supervision":{}}\n'
SH
  chmod +x "$root/bin/fm-fleet-snapshot.sh"
  cp "$SERVER" "$ROOT/bin/fm-event-store.mjs" "$ROOT/bin/fm-telemetry-store.mjs" "$root/bin/"
  mkdir -p "$root/assets/dashboard"
  cp "$ROOT/assets/dashboard/"* "$root/assets/dashboard/"
  printf '%s\n' "$root"
}

configure_instrumentation() {  # <case-root> <port>
  local root=$1 port=$2
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port "$port" >/dev/null
  TOKEN=$(jq -r '.token' "$root/config/dashboard-events.json")
}

start_server() {  # <case-root> [extra env assignments...]
  local root=$1
  shift
  TEST_PORT=$(free_port)
  configure_instrumentation "$root" "$TEST_PORT"
  env "$@" \
    FM_HOME="$root/home" \
    FM_DASHBOARD_PORT="$TEST_PORT" \
    FM_DASHBOARD_POLL_SECONDS=30 \
    FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    FM_DASHBOARD_EVENT_DB="$root/events.db" \
    node "$root/bin/fm-dashboard-server.mjs" > "$root/server.log" 2>&1 &
  SERVER_PID=$!
  local attempt
  # Readiness is probed on the snapshot rather than the timeline deliberately:
  # reading the timeline opens the event store, which would mask whether the
  # stream's own first frame is authoritative about a store nothing has touched.
  for attempt in $(seq 1 40); do
    curl -fsS -o /dev/null "http://127.0.0.1:$TEST_PORT/api/snapshot" 2>/dev/null && return 0
    sleep 0.1
  done
  fail "event dashboard did not listen: $(cat "$root/server.log")"
}

stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# post <status-var-name> <source-header> <body> [curl args...]
post_status() {  # <source> <body> [extra curl args...]
  local source=$1 body=$2
  shift 2
  curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$TEST_PORT/events" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Firstmate-Source: $source" \
    -H "Content-Type: application/json" \
    --data-binary "$body" "$@"
}

one_event() {  # <task> <harness> <type> <id> [extra json fields]
  printf '{"schema":"fm-agent-event.v1","events":[{"event_id":"%s","task_id":"%s","harness":"%s","type":"%s","occurred_at":"%s"%s}]}' \
    "$4" "$1" "$2" "$3" "$(now_iso)" "${5:-}"
}

# A dashboard that accepts the connection and then never answers, which is the
# failure mode a naive producer turns into a stalled agent.
start_black_hole() {  # <case-root> - sets HELPER_PORT
  local root=$1
  HELPER_PORT=$(free_port)
  node -e '
    const net = require("node:net");
    const held = [];
    net.createServer((socket) => { held.push(socket); socket.resume(); })
      .listen(Number(process.argv[1]), "127.0.0.1");
  ' "$HELPER_PORT" > "$root/blackhole.log" 2>&1 &
  HELPER_PIDS+=("$!")
  sleep 0.3
}

# A dashboard stand-in that records exactly what a producer put on the wire.
start_capture() {  # <case-root> - sets HELPER_PORT
  local root=$1
  HELPER_PORT=$(free_port)
  node -e '
    const http = require("node:http");
    const fs = require("node:fs");
    const out = process.argv[2];
    http.createServer((request, response) => {
      const chunks = [];
      request.on("data", (chunk) => chunks.push(chunk));
      request.on("end", () => {
        fs.appendFileSync(out, JSON.stringify({
          headers: request.headers,
          body: Buffer.concat(chunks).toString("utf8"),
        }) + "\n");
        response.writeHead(202, { "Content-Type": "application/json" });
        response.end("{}");
      });
    }).listen(Number(process.argv[1]), "127.0.0.1");
  ' "$HELPER_PORT" "$root/captured.jsonl" > "$root/capture.log" 2>&1 &
  HELPER_PIDS+=("$!")
  sleep 0.3
}

wait_for_capture() {  # <file> <count>
  local file=$1 want=$2 attempt
  for attempt in $(seq 1 40); do
    [ -f "$file" ] && [ "$(wc -l < "$file")" -ge "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

# Elapsed milliseconds of one command, measured the way an agent experiences it.
elapsed_ms() {  # <command...>
  local start end
  start=$(date +%s%N)
  "$@" </dev/null >/dev/null 2>&1
  end=$(date +%s%N)
  printf '%s\n' "$(( (end - start) / 1000000 ))"
}

# --- the ingest boundary ----------------------------------------------------

test_ingest_refuses_cheaply_before_reading_a_body() {
  local root code
  root=$(make_case refusals)
  start_server "$root"

  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$TEST_PORT/events" \
    -H "X-Firstmate-Source: t/claude" -d '{}')
  expect_code 401 "$code" "an unauthenticated post must be refused"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$TEST_PORT/events" \
    -H "Authorization: Bearer not-the-token" -H "X-Firstmate-Source: t/claude" -d '{}')
  expect_code 401 "$code" "a wrong token must be refused"

  code=$(post_status '' '{}')
  expect_code 400 "$code" "a missing source header must be refused"
  code=$(post_status 'not a source' '{}')
  expect_code 400 "$code" "a malformed source header must be refused"

  # Well past the 16 KiB body cap, so the refusal has to happen while the body
  # is still arriving rather than after it is buffered.
  head -c 200000 /dev/zero | tr '\0' 'a' > "$root/oversized"
  code=$(post_status 'task-a/claude' "@$root/oversized")
  expect_code 413 "$code" "an oversized body must be refused"

  code=$(post_status 'task-a/claude' '{not json')
  expect_code 400 "$code" "malformed JSON must be refused"
  code=$(post_status 'task-a/claude' '{"schema":"fm-agent-event.v99","events":[]}')
  expect_code 400 "$code" "an unsupported wire schema must be refused"
  code=$(post_status 'task-a/claude' '{"schema":"fm-agent-event.v1","events":[]}')
  expect_code 400 "$code" "an empty batch must be refused"

  # A well-formed event that claims a different source than the one that was
  # rate-limited would spend another agent's budget.
  code=$(post_status 'task-a/claude' "$(one_event other-task claude turn_ended mism1)")
  expect_code 422 "$code" "an event whose task disagrees with its declared source must be refused"

  # The burst is driven from one process over keep-alive connections rather than
  # from a loop of curl invocations. A bucket that refills at 20/s only drains
  # if the drain sustains more than 20 requests a second, which a loop paying a
  # process spawn per request does on an idle host and does not on a loaded CI
  # box - so a serial loop tests the host's fork latency, not the limiter.
  local flood
  flood=$(TOKEN="$TOKEN" PORT="$TEST_PORT" node - <<'NODE'
const http = require("node:http");
const agent = new http.Agent({ keepAlive: true, maxSockets: 8 });
const port = Number(process.env.PORT);
const token = process.env.TOKEN;
const stamp = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
let sent = 0;
let throttled = false;
const post = (index) => new Promise((resolve) => {
  const body = JSON.stringify({
    schema: "fm-agent-event.v1",
    events: [{
      event_id: `flood${index}`, task_id: "flood", harness: "claude",
      type: "notification", occurred_at: stamp,
    }],
  });
  const request = http.request({
    host: "127.0.0.1", port, path: "/events", method: "POST", agent,
    headers: {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body),
      Authorization: `Bearer ${token}`,
      "X-Firstmate-Source": "flood/claude",
    },
  }, (response) => {
    response.resume();
    response.on("end", () => resolve(response.statusCode));
  });
  request.on("error", () => resolve(0));
  request.end(body);
});
(async () => {
  const worker = async () => {
    while (!throttled && sent < 400) {
      const status = await post(sent++);
      if (status === 429) throttled = true;
    }
  };
  await Promise.all(Array.from({ length: 8 }, worker));
  process.stdout.write(throttled ? "throttled" : `never-throttled-over-${sent}-posts`);
})();
NODE
  )
  [ "$flood" = throttled ] || fail "per-source rate limiting never engaged: $flood"

  stop_server
  pass "unauthenticated, malformed, oversized, mismatched, and flooding posts are all refused"
}

test_replayed_and_duplicated_events_are_stored_once() {
  local root code stored
  root=$(make_case replay)
  start_server "$root"

  code=$(post_status 'task-r/claude' "$(one_event task-r claude turn_ended dup1)")
  expect_code 202 "$code" "the first event must be accepted"
  stored=$(curl -fsS "http://127.0.0.1:$TEST_PORT/events" -X POST \
    -H "Authorization: Bearer $TOKEN" -H "X-Firstmate-Source: task-r/claude" \
    -H "Content-Type: application/json" \
    --data-binary "$(one_event task-r claude turn_ended dup1)" | jq -r '.duplicate')
  [ "$stored" = 1 ] || fail "replaying the same event id must be recognized as a duplicate, got $stored"

  # A captured batch resent later carries its own original instant, and that is
  # what refuses it - identity alone would not, because a replayer can mint
  # fresh ids.
  code=$(post_status 'task-r/claude' \
    '{"schema":"fm-agent-event.v1","events":[{"event_id":"ancient","task_id":"task-r","harness":"claude","type":"turn_ended","occurred_at":"2020-01-01T00:00:00Z"}]}')
  expect_code 422 "$code" "an event replayed from outside the accepted window must be refused"

  stored=$(curl -fsS "http://127.0.0.1:$TEST_PORT/api/timeline?task=task-r" | jq '.events | length')
  [ "$stored" = 1 ] || fail "the store should hold exactly one event after a duplicate and a replay, got $stored"
  stop_server
  pass "a duplicate is stored once and a replay from outside the window is refused by its own timestamp"
}

# A task id may legally begin with - or _ (bin/fm-pr-lib.sh's
# fm_task_id_creation_valid), while an event id may not. Composing the one from
# the other therefore used to fail the producer's own check for exactly those
# tasks, and the emitter's fail-open exit meant every event they ever reported
# was discarded silently and permanently while the timeline showed them quiet.
test_every_legal_task_id_can_report() {
  local root task attempt ids
  root=$(make_case taskids)
  start_server "$root"

  for task in -fix-thing _scratch ordinary-task; do
    FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
      "$EMIT" --task "$task" --harness claude --type turn_ended </dev/null
  done
  for attempt in $(seq 1 40); do
    ids=$(curl -fsS "http://127.0.0.1:$TEST_PORT/api/timeline" | jq -r '[.events[].task_id] | sort | join(",")')
    [ "$ids" = "-fix-thing,_scratch,ordinary-task" ] && break
    sleep 0.1
  done
  [ "$ids" = "-fix-thing,_scratch,ordinary-task" ] \
    || fail "a legal task id was silently discarded at the producer: got [$ids]"

  stop_server
  pass "a task id that starts with a dash or an underscore reports like any other"
}

# --- redaction at both boundaries -------------------------------------------

test_redaction_holds_at_producer_server_and_page() {
  local root captured timeline rendered
  root=$(make_case redaction)

  # Producer boundary: the emitter is pointed at a recorder, and hostile values
  # are handed to it the way a careless adapter would.
  start_capture "$root"
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port "$HELPER_PORT" >/dev/null
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$EMIT" --task task-x --harness claude --type tool_finished \
    --tool "$SEED_TOKEN" --summary "read $SEED_PATH" </dev/null
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$EMIT" --task task-x --harness claude --type notification \
    --summary "key $SEED_KEY" </dev/null
  # A hook payload full of exactly what must never travel.
  printf '{"session_id":"sess-1","tool_name":"Bash","tool_input":{"command":"export API_KEY=%s"},"prompt":"%s","cwd":"%s"}' \
    "$SEED_KEY" "SEEDED_PROMPT_BODY" "$SEED_PATH" \
    | FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
      "$EMIT" --task task-x --harness claude --type tool_started --from-stdin
  wait_for_capture "$root/captured.jsonl" 3 || fail "the producer never reached the recorder"
  # The whole record, headers included, is searched for the seeds; the decoded
  # bodies are what the positive assertions read.
  captured=$(cat "$root/captured.jsonl")
  for seed in "$SEED_PATH" "$SEED_KEY" "$SEED_TOKEN" SEEDED_PROMPT_BODY API_KEY; do
    case "$captured" in
      *"$seed"*) fail "the producer put a seeded secret on the wire: $seed" ;;
    esac
  done
  local bodies
  bodies=$(jq -r '.body' "$root/captured.jsonl")
  [ "$(printf '%s\n' "$bodies" | jq -sr '[.[].events[0].tool] | map(select(. != null)) | join(",")')" = Bash ] \
    || fail "the producer did not report exactly the tool name it is allowed to: $bodies"
  [ "$(printf '%s\n' "$bodies" | jq -sr '[.[].events[0].session_id] | map(select(. != null)) | join(",")')" = sess-1 ] \
    || fail "the producer dropped the session id it is supposed to report: $bodies"
  [ "$(printf '%s\n' "$bodies" | jq -sr '[.[].events[0].summary] | map(select(. != null)) | length')" = 0 ] \
    || fail "a seeded summary survived the producer: $bodies"
  stop_helpers

  # Server boundary: the same hostile values posted directly, as a compromised
  # or simply wrong producer would send them.
  start_server "$root"
  post_status 'task-x/claude' "$(printf '{"schema":"fm-agent-event.v1","events":[{"event_id":"hostile1","task_id":"task-x","harness":"claude","type":"tool_finished","occurred_at":"%s","tool":"%s","summary":"read %s","prompt":"SEEDED_PROMPT_BODY","env":{"AWS":"AKIAIOSFODNN7EXAMPLE"}}]}' \
    "$(now_iso)" "$SEED_TOKEN" "$SEED_PATH")" >/dev/null
  post_status 'task-x/claude' "$(printf '{"schema":"fm-agent-event.v1","events":[{"event_id":"hostile2","task_id":"task-x","harness":"claude","type":"notification","occurred_at":"%s","summary":"key %s"}]}' \
    "$(now_iso)" "$SEED_KEY")" >/dev/null
  timeline=$(curl -fsS "http://127.0.0.1:$TEST_PORT/api/timeline?task=task-x")
  [ "$(printf '%s' "$timeline" | jq '.events | length')" = 2 ] \
    || fail "the hostile events were not stored at all, so redaction was not exercised"
  for seed in "$SEED_PATH" "$SEED_KEY" "$SEED_TOKEN" SEEDED_PROMPT_BODY AKIAIOSFODNN7EXAMPLE; do
    case "$timeline" in
      *"$seed"*) fail "a seeded secret survived the server boundary: $seed" ;;
    esac
  done
  grep -q -e "$SEED_KEY" -e "$SEED_TOKEN" -e id_rsa -e SEEDED_PROMPT_BODY "$root/events.db" \
    && fail "a seeded secret reached the store file on disk"

  # Page boundary: the stored rows through the module the browser renders from.
  rendered=$(TIMELINE="$timeline" node - "$ROOT/assets/dashboard/events.js" <<'NODE'
const { pathToFileURL } = require("node:url");
(async () => {
  const events = await import(pathToFileURL(process.argv[2]).href);
  const envelope = JSON.parse(process.env.TIMELINE);
  const view = events.buildTimeline({ events: envelope.events });
  // Everything a row can put on the page, concatenated. Nothing else in the
  // stored record ever reaches a node.
  const text = view.rows.flatMap((row) => [
    events.typeLabel(row.type), row.tool, row.outcome, row.summary,
    row.task, row.harness, events.clockLabel(row.at),
  ]).filter(Boolean).join(" | ");
  process.stdout.write(text);
})();
NODE
  ) || fail "the timeline module could not render the stored rows"
  for seed in "$SEED_PATH" "$SEED_KEY" "$SEED_TOKEN" SEEDED_PROMPT_BODY; do
    case "$rendered" in
      *"$seed"*) fail "a seeded secret reached the rendered page: $seed" ;;
    esac
  done
  case "$rendered" in
    *"Tool finished"*) ;;
    *) fail "the rendered timeline lost the lifecycle fact it exists to show: $rendered" ;;
  esac

  stop_server
  pass "seeded credentials and private paths reach neither the wire, the store, nor the page"
}

# A tool name is an identifier, not free-form content. The entropy rule that
# `summary` needs would classify any MCP tool name of 24 or more characters
# containing a digit as a credential and silently blank the one field a
# tool_started row exists to show, so `tool` carries the named-prefix check
# alone. All three halves of that split are pinned here: what must survive, what
# must still be refused wherever it appears, and the entropy rule itself.
test_a_tool_name_is_an_identifier_not_a_secret() {
  local root bodies timeline rendered tools
  local mcp_tool='mcp__github_v2__create_issue'
  local camel_tool='SlackSendMessageToChannel'
  root=$(make_case toolnames)

  node - "$ROOT/bin/fm-event-store.mjs" <<'NODE' \
    || fail "the two credential predicates are not split the way their fields need"
const { pathToFileURL } = require("node:url");
(async () => {
  const store = await import(pathToFileURL(process.argv[2]).href);
  // 24 characters mixing letters and digits, with no vendor prefix: exactly
  // what only the entropy branch can catch.
  const entropy = "Ab3xQ9zL2mNp7RtVu4Wy8Kd6";
  const vendor = "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345";
  const checks = [
    [store.hasCredentialPrefix(vendor) === true, "a named credential prefix must be recognized"],
    [store.hasCredentialPrefix(entropy) === false, "the prefix predicate must not guess at unprefixed values"],
    [store.looksLikeCredential(entropy) === true, "the entropy branch must still refuse an unprefixed token"],
    [store.looksLikeCredential(vendor) === true, "the free-form predicate must still include the prefixes"],
    [store.safeTool("mcp__github_v2__create_issue") === "mcp__github_v2__create_issue", "a long MCP tool name must survive"],
    [store.safeTool("SlackSendMessageToChannel") === "SlackSendMessageToChannel", "a long camelCase tool name must survive"],
    [store.safeTool(vendor) === null, "a credential-shaped tool value must be dropped"],
    [store.safeSummary(`key ${vendor}`) === null, "a credential-shaped summary must be dropped"],
    [store.safeSummary("listed the branch") === "listed the branch", "an ordinary summary must survive"],
  ];
  const failed = checks.filter(([ok]) => !ok).map(([, why]) => why);
  if (failed.length) {
    process.stderr.write(`${failed.join("; ")}\n`);
    process.exit(1);
  }
})();
NODE

  # Producer boundary.
  start_capture "$root"
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port "$HELPER_PORT" >/dev/null
  local tool
  for tool in "$mcp_tool" "$camel_tool" "$SEED_TOKEN"; do
    FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
      "$EMIT" --task task-t --harness claude --type tool_started --tool "$tool" </dev/null
  done
  wait_for_capture "$root/captured.jsonl" 3 || fail "the producer never reached the recorder"
  bodies=$(jq -r '.body' "$root/captured.jsonl")
  tools=$(printf '%s\n' "$bodies" | jq -sr '[.[].events[0].tool] | map(select(. != null)) | sort | join(",")')
  [ "$tools" = "$camel_tool,$mcp_tool" ] \
    || fail "the producer did not report exactly the tool names it is allowed to: $tools"
  stop_helpers

  # Server boundary.
  start_server "$root"
  post_status 'task-t/claude' "$(one_event task-t claude tool_started mcp1 ",\"tool\":\"$mcp_tool\"")" >/dev/null
  post_status 'task-t/claude' "$(one_event task-t claude tool_started camel1 ",\"tool\":\"$camel_tool\"")" >/dev/null
  post_status 'task-t/claude' "$(one_event task-t claude tool_started vendor1 ",\"tool\":\"$SEED_TOKEN\"")" >/dev/null
  post_status 'task-t/claude' "$(one_event task-t claude notification vendorsum1 ",\"summary\":\"key $SEED_KEY\"")" >/dev/null
  timeline=$(curl -fsS "http://127.0.0.1:$TEST_PORT/api/timeline?task=task-t")
  [ "$(printf '%s' "$timeline" | jq '.events | length')" = 4 ] \
    || fail "the tool-name events were not stored, so the boundary was not exercised: $timeline"
  tools=$(printf '%s' "$timeline" | jq -r '[.events[].tool] | map(select(. != null)) | sort | join(",")')
  [ "$tools" = "$camel_tool,$mcp_tool" ] \
    || fail "the server did not keep exactly the tool names it is allowed to: $tools"
  for seed in "$SEED_KEY" "$SEED_TOKEN"; do
    case "$timeline" in
      *"$seed"*) fail "a credential-shaped value survived the server boundary: $seed" ;;
    esac
  done

  # Page boundary: the tool identity an acceptance criterion names has to reach
  # the rendered row, not just the stored one.
  rendered=$(TIMELINE="$timeline" node - "$ROOT/assets/dashboard/events.js" <<'NODE'
const { pathToFileURL } = require("node:url");
(async () => {
  const events = await import(pathToFileURL(process.argv[2]).href);
  const view = events.buildTimeline({ events: JSON.parse(process.env.TIMELINE).events });
  process.stdout.write(view.rows.map((row) => row.tool).filter(Boolean).join(" | "));
})();
NODE
  ) || fail "the timeline module could not render the stored rows"
  case "$rendered" in
    *"$mcp_tool"*) ;;
    *) fail "the MCP tool name never reached the rendered row: $rendered" ;;
  esac

  stop_server
  pass "a long MCP tool name survives both boundaries while credential shapes are still refused"
}

# --- the producer's fail-open guarantees ------------------------------------

test_a_down_or_slow_dashboard_never_delays_or_fails_an_agent() {
  local root port down_ms slow_ms missing_ms hostile_ms code
  root=$(make_case failopen)

  # No dashboard at all: the configuration points at a port nobody is listening
  # on, which is what an unstarted or crashed service looks like.
  port=$(free_port)
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port "$port" >/dev/null
  down_ms=$(elapsed_ms env FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$EMIT" --task task-f --harness claude --type turn_ended)
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$EMIT" --task task-f --harness claude --type turn_ended </dev/null
  expect_code 0 $? "the emitter must succeed with no dashboard listening"
  [ "$down_ms" -lt 500 ] || fail "a down dashboard cost the agent ${down_ms}ms"

  # A dashboard that accepts the connection and never answers is the worse case:
  # a naive producer waits for its own timeout here.
  start_black_hole "$root"
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port "$HELPER_PORT" >/dev/null
  slow_ms=$(elapsed_ms env FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    FM_EVENT_MAX_TIME=30 "$EMIT" --task task-f --harness claude --type turn_ended)
  [ "$slow_ms" -lt 500 ] || fail "a hung dashboard cost the agent ${slow_ms}ms even though the request budget was 30s"
  stop_helpers

  # Removed configuration, and arguments that are simply wrong. Neither may fail
  # and neither may print, because a hook that prints can change what a harness
  # does with it.
  rm -f "$root/config/dashboard-events.json" "$root/config/dashboard-events.curlrc"
  missing_ms=$(elapsed_ms env FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$EMIT" --task task-f --harness claude --type turn_ended)
  [ "$missing_ms" -lt 500 ] || fail "an unconfigured emitter cost the agent ${missing_ms}ms"

  hostile_ms=$(elapsed_ms env FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$EMIT" --task '../../etc/passwd' --harness 'NOT A HARNESS' --type nonsense --unknown-flag)
  [ "$hostile_ms" -lt 500 ] || fail "malformed arguments cost the agent ${hostile_ms}ms"

  local out
  out=$(printf 'not json at all' | FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$EMIT" --task task-f --harness claude --type turn_ended --from-stdin 2>&1)
  code=$?
  expect_code 0 "$code" "the emitter must exit 0 on a malformed payload"
  [ -z "$out" ] || fail "the emitter wrote to a stream a harness reads: $out"

  pass "a down, hung, unconfigured, or misused emitter costs an agent nothing and never fails one"
}

# --- the guards this must not touch -----------------------------------------

install_guard_scripts() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/docs"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$ROOT/bin/fm-turnend-guard-grok.sh" \
    "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-supervision-instructions.sh" \
    "$ROOT/bin/fm-harness.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-supervision-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-grok.sh" \
    "$dir/bin/fm-operational-input.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
}

make_primary() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

run_guard() {  # <dir>
  local dir=$1
  printf '{"stop_hook_active":false}' \
    | CLAUDECODE=1 FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" --claude 2>&1
}

state_fingerprint() {  # <dir>
  node - "$1" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
const rows = [];
(function walk(current) {
  for (const name of fs.readdirSync(current).sort()) {
    const full = path.join(current, name);
    const info = fs.lstatSync(full);
    rows.push([path.relative(root, full), info.mode, info.size, info.mtimeMs].join("\t"));
    if (info.isDirectory()) walk(full);
  }
})(root);
process.stdout.write(rows.join("\n"));
NODE
}

test_instrumentation_cannot_change_what_a_guard_decides() {
  local root bare with emit_code bare_out bare_code with_out with_code before after
  root=$(make_case guards)

  # The hung dashboard is deliberate: if the emitter could ever hold up or
  # colour a Stop hook, this is the configuration that would show it.
  start_black_hole "$root"
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port "$HELPER_PORT" >/dev/null

  local case_name
  for case_name in idle blocking; do
    # Two identical primaries rather than two runs in one, because the guard
    # keeps its own re-block budget in the state directory: a second run in the
    # same home is not the same experiment as the first.
    bare=$(make_primary "$root/$case_name-bare")
    with=$(make_primary "$root/$case_name-with")
    # The blocking case is a real block: in-flight work with no live watcher is
    # exactly what the guard exists to refuse.
    if [ "$case_name" = blocking ]; then
      : > "$bare/state/task1.meta"
      : > "$with/state/task1.meta"
    fi

    before=$(state_fingerprint "$with/state")
    printf '{"session_id":"s1","hook_event_name":"Stop"}' \
      | FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
        "$EMIT" --task guarded-task --harness claude --type turn_ended --from-stdin
    emit_code=$?
    # Long enough for the detached request to be well into its hung connection
    # while the guard runs, which is the interference this rules out.
    sleep 0.3
    after=$(state_fingerprint "$with/state")

    bare_out=$(run_guard "$bare"); bare_code=$?
    with_out=$(run_guard "$with"); with_code=$?
    bare_out=${bare_out//$bare/PRIMARY}
    with_out=${with_out//$with/PRIMARY}

    expect_code 0 "$emit_code" "the $case_name-case emitter must exit 0 beside a guard"
    [ "$bare_code" = "$with_code" ] \
      || fail "the $case_name guard exited $bare_code alone and $with_code beside the emitter"
    [ "$bare_out" = "$with_out" ] \
      || fail "the $case_name guard's output changed when the emitter ran beside it"
    [ "$before" = "$after" ] \
      || fail "the emitter wrote into the state directory the $case_name guard reads"
  done

  # Claude aggregates its Stop hooks, so an entry that always exits 0 and prints
  # nothing cannot change the aggregate. Both halves of that are asserted here
  # rather than assumed.
  local emit_out
  emit_out=$(FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$EMIT" --task guarded-task --harness claude --type turn_ended </dev/null 2>&1)
  emit_code=$?
  expect_code 0 "$emit_code" "the emitter must never exit non-zero"
  [ -z "$emit_out" ] || fail "the emitter produced output beside a Stop guard: $emit_out"

  stop_helpers
  pass "the turn-end guard's exit status, output, and inputs are identical with and without instrumentation"
}

# The other guard the constraint names by file. It fires on the same Stop event
# as the event hook - on a crew worktree of firstmate's own repo the tracked
# .claude/settings.json auto-arm entry and the generated settings.local.json
# event entry are merged into one Stop array - so "an entry that always exits 0
# cannot change the aggregate" is proven here rather than argued, the same way
# the turn-end guard's half is.
FAKE_CLAUDE=

# A primary the auto-arm will actually act in: plain checkout, AGENTS.md, bin/,
# state/, in-flight work, not AFK, and its session lock claimed by the fake
# harness that runs the hook. The arm wrapper is a fixture, so no real watcher
# is ever launched.
make_autoarm_primary() {  # <dir> <close-kind>
  local dir=$1 kind=$2
  mkdir -p "$dir/state" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-supervision-lib.sh" "$ROOT/bin/fm-wake-lib.sh" \
    "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-lock.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  : > "$dir/state/task1.meta"
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    clean)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
rm -f "$FM_HOME"/state/*.meta
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: fixture\n'
exit 0
SH
      ;;
    *) fail "unknown auto-arm close fixture: $kind" ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
  printf '%s\n' "$dir"
}

run_autoarm() {  # <dir> <stderr-file>
  local dir=$1 err=$2
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>"$err"
}

# The ledger the synchronous guard reads, plus the two markers that bound a
# failure episode. The owner pid and the stamp are the only fields two separate
# runs cannot share, so those two are normalized and everything else - the epoch
# sequence, the recorded outcome, and the presence of each marker - has to match.
autoarm_ledger() {  # <dir>
  local marker
  sed -e 's/owner_pid=[0-9]*/owner_pid=PID/' -e 's/updated_at=[0-9]*/updated_at=AT/' \
    "$1/state/.claude-autoarm-epoch" 2>/dev/null || printf 'epoch absent\n'
  for marker in .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed; do
    if [ -e "$1/state/$marker" ]; then printf '%s present\n' "$marker"
    else printf '%s absent\n' "$marker"; fi
  done
}

test_instrumentation_cannot_change_what_the_stop_autoarm_decides() {
  local root fakebin bare with bare_err with_err bare_code with_code emit_code kind
  root=$(make_case autoarm)
  fakebin=$(fm_fakebin "$root/fake")
  ln -sf /bin/bash "$fakebin/claude"
  FAKE_CLAUDE="$fakebin/claude"

  # The same deliberately hung dashboard the turn-end case stands up: if the
  # emitter could ever hold up or colour a Stop hook, this is what would show it.
  start_black_hole "$root"
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port "$HELPER_PORT" >/dev/null

  # Both closes, so the comparison is not made on a single trivially-equal
  # outcome: an actionable close exits 2 with a rewake banner, and a close whose
  # need vanished mid-cycle exits 0 in silence.
  for kind in actionable clean; do
    bare=$(make_autoarm_primary "$root/autoarm-$kind-bare" "$kind")
    with=$(make_autoarm_primary "$root/autoarm-$kind-with" "$kind")
    bare_err="$root/autoarm-$kind-bare.err"
    with_err="$root/autoarm-$kind-with.err"

    run_autoarm "$bare" "$bare_err" >/dev/null; bare_code=$?

    printf '{"session_id":"s1","hook_event_name":"Stop"}' \
      | FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
        "$EMIT" --task autoarm-task --harness claude --type turn_ended --from-stdin
    emit_code=$?
    run_autoarm "$with" "$with_err" >/dev/null; with_code=$?

    expect_code 0 "$emit_code" "the $kind-close emitter must exit 0 beside the auto-arm"
    [ "$bare_code" = "$with_code" ] \
      || fail "the $kind-close auto-arm exited $bare_code alone and $with_code beside the emitter"
    diff <(sed "s|$bare|PRIMARY|g" "$bare_err") <(sed "s|$with|PRIMARY|g" "$with_err") >/dev/null \
      || fail "the $kind-close auto-arm's stderr changed when the emitter ran beside it"
    [ "$(autoarm_ledger "$bare")" = "$(autoarm_ledger "$with")" ] \
      || fail "the $kind-close auto-arm's ledger changed when the emitter ran beside it"
  done

  # Both closes have to be the ones this test believes it exercised, or the
  # comparison above is two identical no-ops.
  grep -q 'outcome=rewake' "$root/autoarm-actionable-bare/state/.claude-autoarm-epoch" \
    || fail "the actionable case did not reach the rewake close it exists to compare"
  grep -q 'outcome=clean' "$root/autoarm-clean-bare/state/.claude-autoarm-epoch" \
    || fail "the clean case did not reach the clean close it exists to compare"

  stop_helpers
  pass "the Claude Stop auto-arm's exit status, stderr, and epoch ledger are identical with and without instrumentation"
}

# --- the per-task wiring fm-spawn installs ----------------------------------

make_spawn_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi opencode claude codex
  printf '%s\n' "$fakebin"
}

run_real_spawn() {  # <case-root> <harness> <id> <events-config-or-empty>
  local root=$1 harness=$2 id=$3 config=$4 home proj wt fakebin
  home="$root/spawn-$id/home"
  proj="$root/spawn-$id/project"
  wt="$root/spawn-$id/wt"
  fakebin=$(make_spawn_fakebin "$root/spawn-$id/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DASHBOARD_EVENTS_CONFIG="${config:-$root/absent/dashboard-events.json}" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off >/dev/null 2>&1 \
    || fail "spawning $harness task $id failed"
  printf '%s\n' "$wt|$home"
}

test_harness_wiring_is_additive_and_reversible() {
  local root config off_claude on_claude off_oc on_oc record wt
  root=$(make_case wiring)
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port 8787 >/dev/null
  config="$root/config/dashboard-events.json"

  record=$(run_real_spawn "$root" claude claude-off ""); wt=${record%%|*}
  off_claude="$wt/.claude/settings.local.json"
  record=$(run_real_spawn "$root" claude claude-on "$config"); wt=${record%%|*}
  on_claude="$wt/.claude/settings.local.json"

  grep -q 'fm-event-emit.sh' "$off_claude" \
    && fail "an unconfigured home wired event reporting into a Claude task anyway"
  jq -e . "$on_claude" >/dev/null || fail "the instrumented Claude settings are not valid JSON"
  jq -e . "$off_claude" >/dev/null || fail "the uninstrumented Claude settings are not valid JSON"

  # Additive in the strict sense: every command the busy-state contract owns is
  # still there unchanged, alongside the new ones. Two spawns cannot share a
  # task id, a home, or a busy-state generation, so those three are normalized
  # away and everything else has to match exactly.
  normalize_wiring() {  # <file> <task-id> <home>
    sed -e "s|$2|TASK|g" -e "s|$3|HOME|g" -e "s|--gen '[^']*'|--gen GEN|g" "$1"
  }
  normalize_wiring "$on_claude" claude-on "$root/spawn-claude-on/home" > "$root/on.normal"
  local existing
  while read -r existing; do
    grep -qF -- "$existing" "$root/on.normal" \
      || fail "instrumentation changed an existing Claude hook command: $existing"
  done < <(normalize_wiring "$off_claude" claude-off "$root/spawn-claude-off/home" \
    | jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command')

  for event in UserPromptSubmit Stop SessionEnd SessionStart PreToolUse PostToolUse; do
    jq -e --arg e "$event" \
      'any(.hooks[$e][]?.hooks[]?.command; contains("fm-event-emit.sh"))' "$on_claude" >/dev/null \
      || fail "the instrumented Claude wiring reports no $event event"
  done
  # The turn-end marker and busy-state writer must still be the Stop hook that
  # runs first, ahead of anything this feature added.
  jq -e '.hooks.Stop[0].hooks[0].command | contains("fm-busy-event.sh")' "$on_claude" >/dev/null \
    || fail "instrumentation displaced the existing Stop hook from its position"

  record=$(run_real_spawn "$root" opencode oc-off ""); wt=${record%%|*}
  off_oc="$wt/.opencode/plugins/fm-busy-state.js"
  record=$(run_real_spawn "$root" opencode oc-on "$config"); wt=${record%%|*}
  on_oc="$wt/.opencode/plugins/fm-busy-state.js"
  grep -q 'fm-event-emit.sh' "$off_oc" \
    && fail "an unconfigured home wired event reporting into an OpenCode task anyway"
  grep -q 'fm-event-emit.sh' "$on_oc" || fail "the instrumented OpenCode plugin reports no events"
  grep -q 'tool.execute.before' "$on_oc" || fail "the OpenCode adapter reports no tool events"
  node --input-type=module -e "await import('file://$on_oc')" \
    || fail "the instrumented OpenCode plugin is not loadable"
  node --input-type=module -e "await import('file://$off_oc')" \
    || fail "the uninstrumented OpenCode plugin is not loadable"
  # Removing the emitted lines from the instrumented plugin must give back the
  # uninstrumented one, which is what "additive" has to mean for generated code.
  grep -v -e 'fm-event-emit.sh' -e 'agentEvent' -e 'chat.message' -e 'tool.execute' -e '"--task", "oc-on"' "$on_oc" \
    | grep -c . > "$root/on-lines"
  [ "$(grep -c . "$off_oc")" -le "$(cat "$root/on-lines")" ] \
    || fail "instrumentation removed lines from the OpenCode plugin instead of only adding them"
  # The busy-state branch must be untouched: OpenCode flips its session status
  # busy and idle at every step inside one turn, which is right for an
  # idempotent state writer and would draw the same turn repeatedly on a
  # timeline. The adapter therefore takes OpenCode's own semantic hooks and
  # leaves that branch alone.
  diff <(sed -n '/event: async/,$p' "$off_oc" | sed 's/oc-off/TASK/g; s|spawn-oc-off|spawn-TASK|g') \
       <(sed -n '/event: async/,$p' "$on_oc" | sed 's/oc-on/TASK/g; s|spawn-oc-on|spawn-TASK|g' \
         | grep -v 'agentEvent("turn_ended"') >/dev/null \
    || fail "instrumentation changed the OpenCode busy-state branch instead of only adding hooks beside it"

  pass "event wiring is added to the existing per-task hooks and is absent without configuration"
}

# The generated OpenCode plugin, loaded and driven in a plain Node host exactly
# as OpenCode drives it, with the emitter pointed at a recorder. This is what
# proves the adapter translates OpenCode's vocabulary into the shared one; the
# live-session verification behind it is recorded in the pull request.
test_the_opencode_adapter_translates_its_own_events() {
  local root record wt plugin bodies
  root=$(make_case ocdrive)
  start_capture "$root"
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port "$HELPER_PORT" >/dev/null

  record=$(run_real_spawn "$root" opencode oc-drive "$root/config/dashboard-events.json")
  wt=${record%%|*}
  plugin="$wt/.opencode/plugins/fm-busy-state.js"

  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    node --input-type=module -e "
      const plugin = await import('file://$plugin');
      const hooks = await plugin.FmBusyState({});
      await hooks['chat.message']({ sessionID: 'ses_abc' }, { message: {}, parts: [] });
      await hooks['tool.execute.before']({ tool: 'bash', sessionID: 'ses_abc', callID: 'c1' }, { args: {} });
      await hooks['tool.execute.after']({ tool: 'bash', sessionID: 'ses_abc', callID: 'c1', args: {} },
        { title: 't', output: 'o', metadata: {} });
      await hooks.event({ event: { type: 'session.idle', properties: { sessionID: 'ses_abc' } } });
    " || fail "the generated OpenCode plugin could not be driven"

  wait_for_capture "$root/captured.jsonl" 4 \
    || fail "the OpenCode adapter reported fewer than its four events: $(cat "$root/captured.jsonl" 2>/dev/null)"
  bodies=$(jq -r '.body' "$root/captured.jsonl")
  [ "$(printf '%s\n' "$bodies" | jq -sr '[.[].events[0].type] | sort | join(",")')" \
    = "prompt_submitted,tool_finished,tool_started,turn_ended" ] \
    || fail "the OpenCode adapter reported the wrong lifecycle events: $bodies"
  [ "$(printf '%s\n' "$bodies" | jq -sr '[.[].events[0] | select(.tool != null) | .tool] | unique | join(",")')" = bash ] \
    || fail "the OpenCode adapter lost or mangled the tool name: $bodies"
  [ "$(printf '%s\n' "$bodies" | jq -sr '[.[].events[0].harness] | unique | join(",")')" = opencode ] \
    || fail "the OpenCode adapter reported the wrong harness: $bodies"
  stop_helpers
  pass "the OpenCode adapter turns its own hooks into the shared lifecycle vocabulary"
}

test_an_uninstrumented_harness_degrades_to_no_event_source() {
  local root record wt home notice adapters
  root=$(make_case nosource)
  FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    "$INSTRUMENT" enable --port 8787 >/dev/null

  record=$(run_real_spawn "$root" pi pi-task "$root/config/dashboard-events.json")
  home=${record##*|}
  grep -q 'fm-event-emit.sh' "$home/state/pi-task.pi-ext.ts" \
    && fail "a harness without a verified event adapter was wired anyway"

  # The adapter list is the server's, so the view is checked against the real
  # coverage rather than against a list this test made up.
  adapters=$(node -e 'import("./bin/fm-event-store.mjs").then(m=>console.log(JSON.stringify(m.INSTRUMENTED_HARNESSES)))')
  notice=$(ADAPTERS="$adapters" node - "$ROOT/assets/dashboard/events.js" <<'NODE'
const { pathToFileURL } = require("node:url");
(async () => {
  const events = await import(pathToFileURL(process.argv[2]).href);
  const envelope = { instrumented_harnesses: JSON.parse(process.env.ADAPTERS), events: [] };
  const quiet = events.sourceNotice({ id: "pi-task", harness: "pi" }, envelope);
  const loud = events.sourceNotice({ id: "c", harness: "claude" }, envelope);
  process.stdout.write(JSON.stringify({ quiet, loud }));
})();
NODE
  ) || fail "the timeline module could not report source coverage"
  case "$notice" in
    *"no event source"*) ;;
    *) fail "an uninstrumented harness is not explained to the reader: $notice" ;;
  esac
  [ "$(printf '%s' "$notice" | jq -r '.loud')" = null ] \
    || fail "an instrumented harness was wrongly labelled as having no event source"
  pass "a harness with no adapter is explained as having no event source rather than looking broken"
}

# --- store retention and the live stream ------------------------------------

test_retention_caps_bound_the_store() {
  local root rows index
  root=$(make_case retention)
  start_server "$root" FM_DASHBOARD_EVENT_MAX_ROWS_PER_TASK=5 FM_DASHBOARD_EVENT_MAX_ROWS=8

  for index in $(seq 1 12); do
    post_status 'task-cap/claude' "$(one_event task-cap claude notification "cap$index")" >/dev/null
  done
  rows=$(curl -fsS "http://127.0.0.1:$TEST_PORT/api/timeline?task=task-cap" | jq '.events | length')
  [ "$rows" -le 5 ] || fail "the per-task retention cap did not bound the store: $rows rows"
  [ "$rows" -gt 0 ] || fail "retention pruned the store empty"

  rows=$(FM_DASHBOARD_EVENT_DB="$root/events.db" node "$STORE" stats | jq '.rows')
  [ "$rows" -le 8 ] || fail "the total row cap did not bound the store: $rows rows"
  stop_server
  pass "age and row caps bound the event store without emptying it"
}

test_live_events_reach_the_browser_over_sse() {
  local root log attempt
  root=$(make_case sse)
  start_server "$root"
  log="$root/sse.log"
  curl --max-time 6 -Ns "http://127.0.0.1:$TEST_PORT/api/events" > "$log" 2>/dev/null &
  SSE_PID=$!
  sleep 0.4
  post_status 'task-live/claude' \
    "$(one_event task-live claude tool_started live1 ',"tool":"Bash","summary":"listed the branch"')" >/dev/null
  for attempt in $(seq 1 40); do
    grep -q 'listed the branch' "$log" && break
    sleep 0.1
  done
  grep -q '^event: agent_events' "$log" || fail "no agent event frame was pushed: $(cat "$log")"
  grep -q 'listed the branch' "$log" || fail "the accepted event never reached the stream: $(cat "$log")"
  kill "$SSE_PID" 2>/dev/null; SSE_PID=
  stop_server
  pass "an accepted event is pushed to connected browsers on the existing stream"
}

# The browser connects to the stream and fetches the timeline together, and the
# frame the stream pushes on connect is what wins. On a server that has just
# started over a store full of history, that frame has to carry the history -
# otherwise the reader is told no events have ever arrived until the next one
# does.
test_the_first_stream_frame_reports_a_store_that_was_already_full() {
  local root log attempt
  root=$(make_case firstframe)
  start_server "$root"
  post_status 'task-boot/claude' \
    "$(one_event task-boot claude turn_ended boot1 ',"summary":"before the restart"')" >/dev/null
  stop_server

  # A fresh process over the same store. Nothing posts and nothing reads the
  # timeline, so the connect frame is the only thing the reader has.
  start_server "$root"
  log="$root/firstframe.log"
  curl --max-time 4 -Ns "http://127.0.0.1:$TEST_PORT/api/events" > "$log" 2>/dev/null &
  SSE_PID=$!
  for attempt in $(seq 1 40); do
    grep -q '^event: agent_events' "$log" 2>/dev/null && break
    sleep 0.1
  done
  kill "$SSE_PID" 2>/dev/null; SSE_PID=
  grep -q '^event: agent_events' "$log" || fail "no agent event frame was pushed on connect: $(cat "$log")"
  grep -q 'before the restart' "$log" \
    || fail "the first stream frame reported an empty store that is not empty: $(cat "$log")"

  stop_server
  pass "the first stream frame a browser receives is authoritative about a store that already has history"
}

# What `disable` promises, in both directions at once: stored events stay
# browsable until they age out, and nothing new is collected. Both halves live
# in one case on purpose - serving history without a token is one narrowing
# away from also accepting writes without one, so the two assertions must not be
# able to drift apart into separate tests.
test_disabled_instrumentation_serves_history_and_still_refuses_writes() {
  local root port log before after code timeline kept_token attempt
  root=$(make_case disabled)
  start_server "$root"
  kept_token=$TOKEN
  post_status 'task-kept/claude' \
    "$(one_event task-kept claude turn_ended kept1 ',"summary":"stored before disable"')" >/dev/null
  post_status 'task-kept/claude' \
    "$(one_event task-kept claude session_end kept2 ',"summary":"also stored"')" >/dev/null
  stop_server

  # Exactly what bin/fm-dashboard-instrument.sh disable leaves behind.
  rm -f "$root/config/dashboard-events.json" "$root/config/dashboard-events.curlrc"
  before=$(FM_DASHBOARD_EVENT_DB="$root/events.db" node "$STORE" stats | jq '.rows')
  [ "$before" = 2 ] || fail "the store does not hold the history this case is about: $before rows"

  port=$(free_port)
  FM_HOME="$root/home" FM_DASHBOARD_PORT="$port" FM_DASHBOARD_POLL_SECONDS=30 \
    FM_DASHBOARD_EVENTS_CONFIG="$root/config/dashboard-events.json" \
    FM_DASHBOARD_EVENT_DB="$root/events.db" \
    node "$root/bin/fm-dashboard-server.mjs" > "$root/disabled.log" 2>&1 &
  SERVER_PID=$!
  TEST_PORT=$port
  for attempt in $(seq 1 40); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/api/snapshot" 2>/dev/null && break
    sleep 0.1
  done

  # (a) the history is still served, over BOTH surfaces the browser reads:
  # the timeline it fetches and the frame the stream pushes on connect.
  timeline=$(curl -fsS "http://127.0.0.1:$port/api/timeline?task=task-kept")
  [ "$(printf '%s' "$timeline" | jq '.events | length')" = 2 ] \
    || fail "disabling instrumentation hid the stored history from the timeline: $timeline"
  [ "$(printf '%s' "$timeline" | jq -r '.status.ingestion')" = disabled \
    ] || fail "a home with no configuration did not report collection as off: $timeline"
  log="$root/disabled-sse.log"
  curl --max-time 3 -Ns "http://127.0.0.1:$port/api/events" > "$log" 2>/dev/null
  grep -q 'stored before disable' "$log" \
    || fail "the stream's connect frame dropped the stored history: $(cat "$log")"

  # (b) and nothing new can be collected, even by a producer still holding the
  # token the home was configured with before it was disabled.
  TOKEN=$kept_token
  code=$(post_status 'task-kept/claude' "$(one_event task-kept claude notification afterdisable1)")
  expect_code 503 "$code" "a disabled dashboard must refuse a post"
  stop_server
  after=$(FM_DASHBOARD_EVENT_DB="$root/events.db" node "$STORE" stats | jq '.rows')
  [ "$after" = "$before" ] || fail "a disabled dashboard stored an event anyway: $before -> $after rows"

  pass "disabling instrumentation keeps stored history browsable and still refuses every new event"
}

# The store is the dashboard's own file outside every operational home, so
# opening it on a dashboard that can never write to it leaves a directory behind
# in the operator's state root for nothing. Presence-gating is the whole design
# of this feature, and the store has to obey it too.
test_an_unconfigured_dashboard_creates_no_store() {
  local root state port log
  root=$(make_case nostore)
  state="$root/state-root"
  port=$(free_port)

  # No instrumentation config, and no explicit store path: exactly the shape a
  # dashboard has before anyone runs bin/fm-dashboard-instrument.sh enable.
  env -u FM_DASHBOARD_EVENT_DB \
    FM_HOME="$root/home" \
    FM_DASHBOARD_PORT="$port" \
    FM_DASHBOARD_POLL_SECONDS=30 \
    FM_DASHBOARD_EVENTS_CONFIG="$root/absent/dashboard-events.json" \
    XDG_STATE_HOME="$state" \
    node "$root/bin/fm-dashboard-server.mjs" > "$root/nostore.log" 2>&1 &
  SERVER_PID=$!
  local attempt
  for attempt in $(seq 1 40); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/api/snapshot" 2>/dev/null && break
    sleep 0.1
  done

  # Everything a browser does on load, in the order it does it.
  log="$root/nostore-sse.log"
  curl --max-time 2 -Ns "http://127.0.0.1:$port/api/events" > "$log" 2>/dev/null
  curl -fsS -o "$root/nostore-timeline.json" "http://127.0.0.1:$port/api/timeline" \
    || fail "the timeline endpoint failed on an unconfigured dashboard"
  stop_server

  if [ -d "$state" ]; then
    fail "an unconfigured dashboard created a store it can never write to: $(find "$state" | tr '\n' ' ')"
  fi
  [ "$(jq -r '.status.ingestion' "$root/nostore-timeline.json")" = disabled ] \
    || fail "an unconfigured dashboard did not report itself as uninstrumented: $(cat "$root/nostore-timeline.json")"
  grep -q '^event: agent_events' "$log" \
    || fail "an unconfigured dashboard pushed no activity frame at all: $(cat "$log")"
  pass "a dashboard with no configured ingest token opens no event store anywhere"
}

# The live stream is a bounded fleet-wide tail that every broadcast replaces
# whole. A task whose events have already scrolled out of it is backfilled from
# the store, and those rows have to survive the next broadcast - otherwise the
# per-task timeline appears and vanishes the moment any agent in the fleet
# reports anything.
test_a_selected_task_survives_a_broadcast_that_replaces_the_tail() {
  local root batch index events counted rows
  root=$(make_case backfill)
  start_server "$root"

  post_status 'task-old/claude' \
    "$(one_event task-old claude turn_ended old1 ',"summary":"the first turn"')" >/dev/null

  # Past the server's 200-row tail, in batches, so task-old is genuinely no
  # longer in what a broadcast carries.
  for batch in $(seq 1 7); do
    events=''
    for index in $(seq 1 32); do
      [ -n "$events" ] && events="$events,"
      events="$events{\"event_id\":\"noise$batch-$index\",\"task_id\":\"task-noise\",\"harness\":\"claude\",\"type\":\"notification\",\"occurred_at\":\"$(now_iso)\"}"
    done
    post_status 'task-noise/claude' "{\"schema\":\"fm-agent-event.v1\",\"events\":[$events]}" >/dev/null
  done

  counted=$(curl -fsS "http://127.0.0.1:$TEST_PORT/api/timeline" | jq -r '[.events[].task_id] | unique | join(",")')
  [ "$counted" = task-noise ] \
    || fail "the fleet-wide tail did not scroll task-old out, so the case under test never happened: $counted"

  rows=$(TAIL="$(curl -fsS "http://127.0.0.1:$TEST_PORT/api/timeline")" \
    BACKFILL="$(curl -fsS "http://127.0.0.1:$TEST_PORT/api/timeline?task=task-old")" \
    node - "$ROOT/assets/dashboard/events.js" <<'NODE'
const { pathToFileURL } = require("node:url");
(async () => {
  const events = await import(pathToFileURL(process.argv[2]).href);
  const filters = { task: "task-old", harness: "", type: "" };
  const tail = JSON.parse(process.env.TAIL).events;
  const backfill = { task: "task-old", events: JSON.parse(process.env.BACKFILL).events };
  const render = (stream, slot) =>
    events.buildTimeline({ events: events.mergeTaskBackfill(stream, slot, filters.task) }, filters).rows.length;
  // What the stream alone can show, what selecting the task shows, and what is
  // still shown after a broadcast hands over a whole new fleet-wide tail.
  const streamOnly = render(tail, null);
  const selected = render(tail, backfill);
  const broadcast = [
    { event_id: "broadcast1", task_id: "task-noise", harness: "claude", type: "notification", occurred_at: tail[0].occurred_at, occurred_epoch: tail[0].occurred_epoch },
    ...tail.slice(0, 199),
  ];
  const afterBroadcast = render(broadcast, backfill);
  process.stdout.write(`${streamOnly},${selected},${afterBroadcast}`);
})();
NODE
  ) || fail "the timeline module could not merge a task backfill"
  [ "$rows" = "0,1,1" ] \
    || fail "the selected task's backfilled rows did not survive a broadcast (stream,selected,after): $rows"

  stop_server
  pass "a task backfilled from the store keeps its rows when a broadcast replaces the fleet-wide tail"
}

test_instrument_refuses_a_target_off_this_machine() {
  local out code
  out=$(FM_DASHBOARD_EVENTS_CONFIG="$TMP_ROOT/refuse/dashboard-events.json" \
    "$INSTRUMENT" enable --url "http://dashboard.example.invalid:8787/events" 2>&1)
  code=$?
  [ "$code" -ne 0 ] || fail "instrumentation accepted a target off this machine"
  assert_contains "$out" "must address the loopback dashboard" "the refusal was not explicit"
  [ -f "$TMP_ROOT/refuse/dashboard-events.json" ] \
    && fail "a refused target still wrote a configuration"
  pass "instrumentation refuses any target that is not the loopback dashboard"
}

test_ingest_refuses_cheaply_before_reading_a_body
test_replayed_and_duplicated_events_are_stored_once
test_every_legal_task_id_can_report
test_redaction_holds_at_producer_server_and_page
test_a_tool_name_is_an_identifier_not_a_secret
test_a_down_or_slow_dashboard_never_delays_or_fails_an_agent
test_instrumentation_cannot_change_what_a_guard_decides
test_instrumentation_cannot_change_what_the_stop_autoarm_decides
test_harness_wiring_is_additive_and_reversible
test_the_opencode_adapter_translates_its_own_events
test_an_uninstrumented_harness_degrades_to_no_event_source
test_retention_caps_bound_the_store
test_live_events_reach_the_browser_over_sse
test_the_first_stream_frame_reports_a_store_that_was_already_full
test_disabled_instrumentation_serves_history_and_still_refuses_writes
test_an_unconfigured_dashboard_creates_no_store
test_a_selected_task_survives_a_broadcast_that_replaces_the_tail
test_instrument_refuses_a_target_off_this_machine
fm_assert_no_user_event_store_leak "$USER_EVENT_STORE_BEFORE"
pass "no agent-event store was created outside this suite's own temp space"
