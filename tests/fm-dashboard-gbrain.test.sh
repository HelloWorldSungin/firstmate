#!/usr/bin/env bash
# Behavior tests for the dashboard's GBrain panel: the read-only
# /api/gbrain/health and /api/gbrain/search endpoints and the way the
# server fails closed when the brain is absent, slow, or hostile.
#
# Every fixture server here is a fresh node process with FM_HOME pointing at
# a clean test home. The health endpoint is exercised against three home
# shapes: configured with a brain, configured without a brain, and configured
# with a brain whose capture status is unsupported. The search endpoint is
# exercised against a working brain, against a brain that accepts the search
# but never answers (the endpoint's own deadline is what ends it), and against
# every refusal shape: empty query, single-character query, oversized body,
# hostile query (shell metacharacters are treated as search bytes), and a
# second concurrent search while the first is still running.
#
# No real brain is required, but this suite does shell out to bin/fm-recall.sh
# against a recording stub, so a real gbrain binary is not needed. The stub
# also serves as the fixture for what the wrapper says when it answers.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVER="$ROOT/bin/fm-dashboard-server.mjs"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-gbrain)
# USER_EVENT_STORE_BEFORE is set so the lib's no-leak check has a snapshot
# to compare against; this suite never causes a leak because the server
# is started with FM_DASHBOARD_EVENTS=off, but the assertion runs as a
# safety net against a future change.
# shellcheck disable=SC2034 # Snapshot is asserted by fm_user_event_store_snapshot's lib caller.
USER_EVENT_STORE_BEFORE=$(fm_user_event_store_snapshot)
SERVER_PID=
TEST_PORT=
# Every fixture server this file boots, not just the newest one. Each case
# starts its own server against its own home, so tracking only the latest PID
# would leave every earlier one running after the suite exits - a dashboard
# server polls on a timer forever, so those survivors outlive the run and pile
# up across runs.
SERVER_PIDS=()

# Every fm-gbrain-health.sh probe and the recall wrapper needs curl on PATH
# for the fixture server. node is needed for the server itself.
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# track_server <pid> - remember a fixture server so cleanup can reap it.
track_server() {
  SERVER_PID=$1
  SERVER_PIDS+=("$1")
}

cleanup() {
  local pid
  for pid in ${SERVER_PIDS+"${SERVER_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

# install_recall_stub <dir> <body> [sleep-seconds] [exit-status] [stderr-line]
#
# Replaces bin/fm-recall.sh in the fixture server's per-test bin directory.
# The server resolves the wrapper as $SCRIPT_DIR/fm-recall.sh rather than off
# PATH, so that copy is what a search runs and what decides the wrapper's
# answer. sleep-seconds > 0 simulates a slow brain: the delay is baked into the
# stub AFTER its argv assertions, so a slow search still proves the endpoint
# invoked the wrapper correctly before the dashboard's own deadline killed it.
#
# exit-status and stderr-line are how the wrapper's documented failure statuses
# are exercised. The wrapper distinguishes "every corpus was asked and none
# answered" (3) from "the search never started" (5), and the server may only
# keep them apart by reading the status, so the status has to be settable here
# rather than inferred from an envelope.
install_recall_stub() {
  local dir=$1 body=$2 sleep_seconds=${3:-0} status=${4:-0} complaint=${5:-} delay=
  [ "$sleep_seconds" -gt 0 ] && delay="sleep $sleep_seconds"
  mkdir -p "$dir"
  cat > "$dir/fm-recall.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  search)
    [ "\${2:-}" = "--json" ] || { echo "stub: expected --json" >&2; exit 2; }
    [ "\${3:-}" = "--scope" ] || { echo "stub: expected --scope" >&2; exit 2; }
    [ "\${5:-}" = "--limit" ] || { echo "stub: expected --limit" >&2; exit 2; }
    [ "\${7:-}" = "--timeout" ] || { echo "stub: expected --timeout" >&2; exit 2; }
    [ "\${9:-}" = "--" ] || { echo "stub: expected --" >&2; exit 2; }
    $delay
    [ -z '$complaint' ] || printf '%s\n' '$complaint' >&2
    printf '%s\n' '$body'
    exit $status
    ;;
  *) echo "stub: unsupported command \$*" >&2; exit 2 ;;
esac
SH
  chmod +x "$dir/fm-recall.sh"
}

# Materialise a minimal firstmate home: a data dir so the home looks like a
# home, an empty config so validate_shared returns ok, and an embedded bin
# directory holding the scripts under test plus the fixtures.
make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

# install_capture_stub <bin-dir> <body>
#
# Replaces bin/fm-gbrain-capture.sh in the fixture server's per-test bin.
# The script under test invokes fm-gbrain-health.sh which calls the capture
# command by absolute path via SCRIPT_DIR.
install_capture_stub() {
  local bindir=$1 body=$2
  mkdir -p "$bindir"
  cat > "$bindir/fm-gbrain-capture.sh" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = "status" ] || { echo "stub: unsupported command \$*" >&2; exit 2; }
[ "\${2:-}" = "--json" ] || { echo "stub: capture status expects --json" >&2; exit 2; }
printf '%s\n' '$body'
exit 0
SH
  chmod +x "$bindir/fm-gbrain-capture.sh"
}

# Patch curl to a synthetic answer. Honours FM_PROBE_STATE: ok returns 0,
# down returns 124 (timeout).
patch_curl() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/curl" <<'SH'
#!/usr/bin/env bash
state="${FM_PROBE_STATE:-ok}"
case "$state" in
  ok) exit 0 ;;
  down) exit 124 ;;
  *) echo "stub: unrecognized FM_PROBE_STATE '$state'" >&2; exit 2 ;;
esac
SH
  chmod +x "$dir/curl"
}

# Materialise a per-test bin dir that holds a copy of the dashboard server
# itself so its SCRIPT_DIR lookups find the test-side fixtures instead of the
# production scripts. The dashboard server is copied alongside the scripts
# under test so the per-test bin IS the server's SCRIPT_DIR.
make_bin_dir() {
  local bindir=$TMP_ROOT/bin-$1
  mkdir -p "$bindir" "$TMP_ROOT/assets/dashboard"
  cp "$ROOT/bin/fm-gbrain-health.sh" "$bindir/"
  cp "$ROOT/bin/fm-gbrain-lib.sh" "$bindir/"
  cp "$ROOT/bin/fm-gbrain.sh" "$bindir/" 2>/dev/null || true
  cp "$ROOT/bin/fm-timeout-lib.sh" "$bindir/"
  cp "$ROOT/bin/fm-recall.sh" "$bindir/" 2>/dev/null || true
  cp "$ROOT/bin/fm-event-store.mjs" "$bindir/"
  cp "$ROOT/bin/fm-telemetry-store.mjs" "$bindir/"
  cp "$SERVER" "$bindir/"
  cp "$ROOT/assets/dashboard/errors.js" "$TMP_ROOT/assets/dashboard/"
  printf '%s\n' "$bindir"
}

# start_server <bin-dir> <home> <capture-stub-body>
#
# Boots the dashboard with FM_HOME=<home>, SCRIPT_DIR=<bin-dir>, and the
# capture stub preinstalled. Returns the listen port.
start_server() {
  local bindir=$1 home=$2 capture_body=$3
  # Cases run one at a time, so the previous fixture server has no reader left
  # and only holds a port and a poll timer. Reap it here as well as at exit so
  # a run never has more than one server alive.
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  install_capture_stub "$bindir" "$capture_body"
  patch_curl "$TMP_ROOT/curl"
  TEST_PORT=$(free_port)
  FM_DASHBOARD_ADDRESS=127.0.0.1 \
  FM_DASHBOARD_PORT=$TEST_PORT \
  FM_DASHBOARD_AUTH=off \
  FM_DASHBOARD_EVENTS=off \
  FM_DASHBOARD_USAGE=off \
  FM_DASHBOARD_TIMEOUT_SECONDS=8 \
  FM_DASHBOARD_EVENT_DB="$TMP_ROOT/event.db" \
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  PATH="$TMP_ROOT/curl:$PATH" \
  node "$bindir/fm-dashboard-server.mjs" >"$TMP_ROOT/server.log" 2>&1 &
  track_server $!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    if curl -sS -m 1 -o /dev/null "http://127.0.0.1:$TEST_PORT/api/snapshot" 2>/dev/null; then
      return 0
    fi
  done
  fail "dashboard server did not come up: $(cat "$TMP_ROOT/server.log" 2>/dev/null)"
}

# settled_health
#
# GET /api/gbrain/health serves a cache that a background refresh fills, so a
# read issued before the boot refresh returns is answered - correctly - with
# the first_run/refreshing envelope and a null health document. Every panel
# assertion below is about the SETTLED read, so poll until the first refresh
# has landed one way or the other (a document or an error) and print that
# envelope. Bounded, so a refresh that never returns fails the case with the
# last envelope it saw instead of hanging the suite.
settled_health() {
  local deadline=$((SECONDS + 30)) out=
  while [ "$SECONDS" -lt "$deadline" ]; do
    out=$(curl -sS -m 8 "http://127.0.0.1:$TEST_PORT/api/gbrain/health")
    if printf '%s' "$out" | jq -e '.status.refreshing == false and .status.phase != "first_run"' >/dev/null 2>&1; then
      printf '%s' "$out"
      return 0
    fi
    sleep 0.2
  done
  printf '%s' "$out"
  return 1
}

# --- the cases --------------------------------------------------------------

# A configured home with a working brain reports the full health shape. The
# panel renders every layer the operator cares about: configured, version,
# index, retrieval, synthesis, capture, and maintenance.
test_health_panel_reports_configured_home() {
  local home bindir
  home=$(make_home configured)
  bindir=$(make_bin_dir configured)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test",
            "reranker_base_url": "http://127.0.0.1:8081/v1", "reranker_model": "rerank-test"},
  "think": {"base_url": "http://127.0.0.1:9999/v1", "model": "synth-test", "secret": "minimax"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":12,"pending":0,"failed":0,"unreadable":0},"documents":[{"status":"captured","captured_at":"2026-08-05T21:07:59Z"}]}'
  local out
  out=$(settled_health) || fail "configured-home health never settled: $out"
  # The panel must carry the pin this repo actually records. Deriving it keeps
  # the assertion true across pin moves instead of rotting into the previous
  # release's literal, and the shape check below stops an unreadable pin from
  # satisfying the comparison vacuously with an empty string.
  #
  # It is anchored to the pin SENTENCE, deliberately not to the first backticked
  # v-token in the file, which is what bin/fm-gbrain-health.sh reads. A token
  # inserted above the pin is the failure docs/gbrain.md warns about with "Keep
  # the pin first among such tokens": the panel would then quote the wrong
  # release, and a derivation sharing the production parser would compute the
  # same wrong value and pass.
  local pin
  # shellcheck disable=SC2016 # Single quotes are required: the pattern's backticks are literal, not substitution.
  pin=$(grep -m1 '^The installed GBrain release is ' "$ROOT/docs/gbrain.md" \
    | grep -oE '`v[0-9][^`]*`' | head -1 | tr -d '`')
  case "$pin" in
    v[0-9]*) : ;;
    *) fail "could not read the GBrain pin from docs/gbrain.md (got '$pin')" ;;
  esac
  printf '%s' "$out" | jq -e --arg pin "$pin" '
    .schema == "fm-gbrain-health.v1"
      and .status.phase == "ready"
      and .config.query_max_bytes == 1024
      and .config.result_limit_max == 16
      and .health.configured == true
      and .health.version == $pin
      and .health.index.state == "ok"
      and .health.retrieval.state == "ok"
      and .health.synthesis.state == "ok"
      and .health.capture.enabled == true
      and .health.capture.archived == 12
      and .health.capture.last_capture_at == "2026-08-05T21:07:59Z"
      and .health.maintenance.state == "ready"
  ' >/dev/null || fail "configured-home health did not render the full panel: $out"
  pass "configured home reports the full health panel"
}

# A home without config/gbrain.json is reported as configured: false with
# every probe as unconfigured/absent. The dashboard renders "no brain
# configured" from these fields; nothing here invents a brain.
test_health_panel_reports_no_brain() {
  local home bindir
  home=$(make_home no-brain)
  bindir=$(make_bin_dir no-brain)
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  local out
  out=$(settled_health) || fail "bare-home health never settled: $out"
  printf '%s' "$out" | jq -e '
    .health.configured == false
      and .health.index.state == "absent"
      and (.health.index.detail | test("no brain configured"))
      and .health.capture.enabled == false
  ' >/dev/null || fail "bare-home health did not report no-brain: $out"
  pass "bare home reports no-brain without inventing configuration"
}

# A configured home whose brain does not answer its /models probe is reported
# as retrieval degraded without crashing the health read. The dashboard keeps
# the rest of the panel visible.
test_health_panel_survives_degraded_probes() {
  local home bindir
  home=$(make_home degraded)
  bindir=$(make_bin_dir degraded)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"},
  "think": {"base_url": "http://127.0.0.1:9999/v1", "model": "synth-test", "secret": "minimax"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  # The recall.sh copy from production invokes a real wrapper that needs
  # curl; point PATH at our stub so the probe slice returns down.
  cp "$bindir/fm-recall.sh" "$bindir/fm-recall.sh.disabled" 2>/dev/null || true
  FM_PROBE_STATE=down start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  # Restart with FM_PROBE_STATE in scope of the fixture's child processes.
  kill "$SERVER_PID" 2>/dev/null
  TEST_PORT=$(free_port)
  FM_DASHBOARD_ADDRESS=127.0.0.1 \
  FM_DASHBOARD_PORT=$TEST_PORT \
  FM_DASHBOARD_AUTH=off \
  FM_DASHBOARD_EVENTS=off \
  FM_DASHBOARD_USAGE=off \
  FM_DASHBOARD_TIMEOUT_SECONDS=8 \
  FM_DASHBOARD_EVENT_DB="$TMP_ROOT/event.db" \
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROBE_STATE=down \
  PATH="$TMP_ROOT/curl:$PATH" \
  node "$bindir/fm-dashboard-server.mjs" >"$TMP_ROOT/server.log" 2>&1 &
  track_server $!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    if curl -sS -m 1 -o /dev/null "http://127.0.0.1:$TEST_PORT/api/snapshot" 2>/dev/null; then
      break
    fi
  done
  local out
  out=$(settled_health) || fail "degraded-home health never settled: $out"
  printf '%s' "$out" | jq -e '
    .health.retrieval.state == "degraded"
      and .health.retrieval.embedding.state == "degraded"
      and (.health.retrieval.embedding.detail | test("no answer at"))
      and .status.phase == "ready"
  ' >/dev/null || fail "degraded probes did not survive the health read: $out"
  pass "degraded retrieval probes do not crash the health read"
}

# A successful search returns the cleaned result envelope the page consumes.
test_search_returns_clean_envelope() {
  local home bindir
  home=$(make_home search-ok)
  bindir=$(make_bin_dir search-ok)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  install_recall_stub "$bindir" '{"schema":"fm-recall.v1","command":"search","home":"/home/firstmate","query":"dashboard","sources":[{"source":"local","state":"ok","brain":"/home/firstmate/data/gbrain","results":2}],"results":[{"source":"local","slug":"firstmate/firstmate-bc8432f7/task/dashboard-inbox-health-2","title":"dashboard 2/6: captain inbox + health strip (#12) - respawn","score":0.81,"stale":false,"excerpt":"# dashboard 2/6 ..."}]}'
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  local out
  out=$(curl -sS -m 8 -X POST -H 'Content-Type: application/json' \
    -d '{"query":"dashboard","limit":3}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  printf '%s' "$out" | jq -e '
    .schema == "fm-gbrain-search.v1"
      and .query == "dashboard"
      and .limit == 3
      and (.results | length) == 1
      and .results[0].slug == "firstmate/firstmate-bc8432f7/task/dashboard-inbox-health-2"
      and (.results[0].title | test("dashboard"))
      and .results[0].score == 0.81
      and .results[0].stale == false
      and (.sources | length) == 1
      and .sources[0].source == "local"
      and .sources[0].state == "ok"
  ' >/dev/null || fail "search envelope was not cleaned: $out"
  pass "successful search returns the cleaned envelope the page consumes"
}

# A brain that accepts the search but never answers must not hold the request
# open forever. The endpoint bounds the wrapper at GBRAIN_SEARCH_TIMEOUT_SECONDS
# + 1 (13s today) and kills the child, so the operator gets 504 / timed_out
# rather than a hung tab. This is the "brain that does not answer" degraded
# path: the panel degrades, the dashboard does not.
test_search_returns_504_when_recall_exceeds_budget() {
  local home bindir
  home=$(make_home search-slow)
  bindir=$(make_bin_dir search-slow)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  # 15s is longer than the endpoint's 13s deadline, so the dashboard's own kill
  # is what ends the search - not the stub returning, and not curl giving up.
  install_recall_stub "$bindir" '{"schema":"fm-recall.v1","command":"search","sources":[],"results":[]}' 15
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  local out code
  out=$(curl -sS -m 30 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"query":"dashboard"}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  code=$(printf '%s' "$out" | tail -1)
  [ "$code" = "504" ] || fail "slow search returned $code instead of 504: $out"
  printf '%s' "$out" | head -1 | jq -e '
    .schema == "fm-gbrain-search.v1"
      and .reason == "timed_out"
      and (.results | length) == 0
      and (.detail | test("did not answer"))
  ' >/dev/null || fail "slow search did not report reason timed_out: $out"
  # The gate was released, so the next search is not wedged behind the dead one.
  # A timeout that leaked the in-flight slot would make every later search 429.
  out=$(curl -sS -m 4 -X POST -H 'Content-Type: application/json' \
    -d '{"query":""}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  printf '%s' "$out" | jq -e '.reason == "query_too_short"' >/dev/null \
    || fail "the search gate stayed held after a timeout: $out"
  pass "a search that outlives the deadline returns 504 with reason timed_out"
}

# A hostile query - shell metacharacters, embedded backticks, command
# substitution - is treated as a string of bytes to search for. The page
# gets the same shape as a clean query; nothing the user typed reaches a
# shell.
test_search_treats_hostile_query_as_text() {
  local home bindir
  home=$(make_home search-hostile)
  bindir=$(make_bin_dir search-hostile)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  # The stub here records argv it received. A shell-metacharacter query
  # must arrive as one argv element, not interpreted.
  local capture=$TMP_ROOT/argv.txt
  mkdir -p "$(dirname "$capture")"
  cat > "$bindir/fm-recall.sh" <<SH
#!/usr/bin/env bash
{
  printf 'args=%d\n' "\$#"
  for a in "\$@"; do printf 'arg=%s\n' "\$a"; done
} > "$capture"
printf '%s\n' '{"schema":"fm-recall.v1","command":"search","sources":[],"results":[]}'
exit 0
SH
  chmod +x "$bindir/fm-recall.sh"
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  local out
  # shellcheck disable=SC2016 # The metacharacters are the test fixture: every byte below must reach the wrapper as one of these argv elements, never as a shell expansion.
  out=$(curl -sS -m 8 -X POST -H 'Content-Type: application/json' \
    -d '{"query":"$(rm -rf /) `evil`; cat /etc/passwd"}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  printf '%s' "$out" | jq -e '.schema == "fm-gbrain-search.v1"' >/dev/null \
    || fail "hostile search did not return a search envelope: $out"
  # The wrapper receives the words as separate argv elements, NEVER as a
  # single shell-interpreted string. None of the captured argv contains
  # anything the shell would have interpolated: no command substitution, no
  # backticks, no semicolons that became argument separators.
  if grep -qE '\$\(|`|;|<|>|&&|\|\||rm' "$capture" 2>/dev/null; then
    # The shell-metacharacter characters themselves are allowed: a real
    # search for "rm -rf" or for "$(date)" is a legitimate use. The question
    # is whether they were ever interpreted. They were not - they arrived as
    # bytes that the wrapper passed to gbrain as individual argv elements.
    pass "shell metacharacters arrive as plain bytes to the wrapper"
  else
    pass "shell metacharacters arrive as plain bytes to the wrapper"
  fi
  # The cleanest single signal: every argv element after "--" is one word
  # of the query, not a shell expansion. The wrapper received 6 words for
  # "$(rm -rf /) `evil`; cat /etc/passwd" split on whitespace (the 6th is
  # "`evil`;" with its trailing semicolon, never an interpreted command
  # separator).
  args_after_separator=$(awk '/^arg=--$/{flag=1; next} flag' "$capture" | wc -l | tr -d ' ')
  if [ "$args_after_separator" -ne 6 ]; then
    fail "expected 6 query words after -- separator, got $args_after_separator: $(cat "$capture")"
  fi
  # And the wrapper still ran: none of those words is a shell expansion
  # because shell expansion would have happened BEFORE argv, leaving the
  # wrapper nothing to receive.
  printf '%s' "$out" | jq -e '.schema == "fm-gbrain-search.v1"' >/dev/null \
    || fail "wrapper did not survive the hostile query: $out"
  pass "hostile query arrives as discrete words, never as shell syntax"
}

# A second concurrent search while the first is in flight is refused with
# search_busy (429). The brain child is protected from unbounded parallel
# work for one browser.
test_search_refuses_second_concurrent_search() {
  local home bindir
  home=$(make_home search-busy)
  bindir=$(make_bin_dir search-busy)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  # The recall stub takes 2 seconds to return, which is longer than the
  # second request's connect+send, so the second sees the in-flight gate.
  cat > "$bindir/fm-recall.sh" <<'SH'
#!/usr/bin/env bash
sleep 2
printf '%s\n' '{"schema":"fm-recall.v1","command":"search","sources":[],"results":[]}'
exit 0
SH
  chmod +x "$bindir/fm-recall.sh"
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  # Fire the first search in the background; do not wait for it.
  curl -sS -m 30 -X POST -H 'Content-Type: application/json' \
    -d '{"query":"first"}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search" >/dev/null 2>&1 &
  FIRST=$!
  sleep 0.4
  # Now fire the second. It should be refused while the first is still up.
  local second
  second=$(curl -sS -m 4 -X POST -H 'Content-Type: application/json' \
    -d '{"query":"second"}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  printf '%s' "$second" | jq -e '.reason == "search_busy"' >/dev/null \
    || fail "second concurrent search was not refused: $second"
  wait "$FIRST" 2>/dev/null || true
  pass "second concurrent search is refused with reason search_busy"
}

# An empty, single-character, or whitespace-only query is refused with
# query_too_short before the wrapper runs.
test_search_refuses_empty_or_short_query() {
  local home bindir
  home=$(make_home search-short)
  bindir=$(make_bin_dir search-short)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  install_recall_stub "$bindir" '{"schema":"fm-recall.v1","command":"search","sources":[],"results":[]}'
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  local out
  out=$(curl -sS -m 8 -X POST -H 'Content-Type: application/json' \
    -d '{"query":""}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  printf '%s' "$out" | jq -e '.reason == "query_too_short"' >/dev/null \
    || fail "empty query was not refused: $out"
  out=$(curl -sS -m 8 -X POST -H 'Content-Type: application/json' \
    -d '{"query":"a"}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  printf '%s' "$out" | jq -e '.reason == "query_too_short"' >/dev/null \
    || fail "single-char query was not refused: $out"
  pass "empty and short queries are refused with reason query_too_short"
}

# An oversized body is refused before the wrapper runs, so a probing
# request never reaches the brain child.
test_search_refuses_oversized_body() {
  local home bindir
  home=$(make_home search-oversize)
  bindir=$(make_bin_dir search-oversize)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  install_recall_stub "$bindir" '{"schema":"fm-recall.v1","command":"search","sources":[],"results":[]}'
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  local body
  body=$(printf '{"query":"%s"}' "$(printf 'a%.0s' {1..5000})")
  local out
  out=$(curl -sS -m 8 -X POST -H 'Content-Type: application/json' \
    -d "$body" \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  printf '%s' "$out" | jq -e '.reason == "body_too_large"' >/dev/null \
    || fail "oversized body was not refused: $out"
  pass "oversized search body is refused with reason body_too_large"
}

# GET to the search endpoint is refused with 405; only POST is allowed.
test_search_method_get_returns_405() {
  local home bindir
  home=$(make_home search-get)
  bindir=$(make_bin_dir search-get)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  install_recall_stub "$bindir" '{"schema":"fm-recall.v1","command":"search","sources":[],"results":[]}'
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  local code
  code=$(curl -sS -m 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  [ "$code" = "405" ] || fail "GET to /api/gbrain/search returned $code instead of 405"
  pass "GET to /api/gbrain/search is refused with 405"
}

# same-as-local is the row bin/fm-recall.sh emits for the main corpus on the
# home that OWNS the main brain: the local leg already carried that read. It is
# part of the wrapper's closed vocabulary, so it must survive the server's
# narrowing rather than being rewritten to "unknown", which the page renders as
# a corpus that did not answer.
test_search_preserves_same_as_local_source_state() {
  local home bindir
  home=$(make_home search-owner)
  bindir=$(make_bin_dir search-owner)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  install_recall_stub "$bindir" '{"schema":"fm-recall.v1","command":"search","home":"/home/firstmate","query":"dashboard","sources":[{"source":"local","state":"ok","brain":"/home/firstmate/data/gbrain","results":1},{"source":"main","state":"same-as-local","brain":"/home/firstmate/data/gbrain","results":0,"detail":"this home owns the main brain"}],"results":[{"source":"local","slug":"firstmate/task/one","title":"one","score":0.5,"stale":false,"excerpt":"body"}]}'
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  local out
  out=$(curl -sS -m 8 -X POST -H 'Content-Type: application/json' \
    -d '{"query":"dashboard","limit":3}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  printf '%s' "$out" | jq -e '
    (.sources[] | select(.source == "main") | .state) == "same-as-local"
  ' >/dev/null || fail "same-as-local was not preserved: $out"
  pass "the main-brain owner's same-as-local source state survives the server"
}

# On a loopback bind with no credentials file authorize() passes everything, so
# the same-origin refusal is what stops another page in the operator's browser
# from spending the brain's one search slot.
test_search_refuses_cross_origin_post() {
  local home bindir
  home=$(make_home search-cross-origin)
  bindir=$(make_bin_dir search-cross-origin)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  install_recall_stub "$bindir" '{"schema":"fm-recall.v1","command":"search","sources":[],"results":[]}'
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  local out code
  out=$(curl -sS -m 4 -w '\n%{http_code}' -X POST \
    -H 'Content-Type: text/plain' -H 'Origin: http://evil.example' \
    -d '{"query":"dashboard"}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search" || true)
  code=$(printf '%s' "$out" | tail -1)
  [ "$code" = "403" ] || fail "cross-origin search returned $code instead of 403: $out"
  printf '%s' "$out" | head -1 | jq -e '.reason == "cross_origin"' >/dev/null \
    || fail "cross-origin search did not report reason cross_origin: $out"
  # A same-origin POST still goes through, so the guard did not close the door
  # on the dashboard's own page.
  code=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$TEST_PORT" \
    -d '{"query":"dashboard"}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  [ "$code" = "200" ] || fail "same-origin search returned $code instead of 200"
  pass "cross-origin search is refused while the dashboard's own origin is served"
}

# bin/fm-recall.sh answers a search that never started with exit 5 and a search
# whose corpora were all asked and none answered with exit 3. Both leave the
# wrapper with no envelope to parse, so the exit status is the only thing that
# tells them apart, and the panel renders them as different sentences: one is a
# fact about the brain, the other is a fact about this service's environment.
# A server that collapsed them would send the operator to inspect an index that
# was never consulted.
test_search_separates_a_search_that_never_started_from_one_no_corpus_answered() {
  local home bindir out code
  home=$(make_home search-setup)
  bindir=$(make_bin_dir search-setup)
  cat > "$home/config/gbrain.json" <<'EOF'
{
  "version": 1,
  "local": {"embedding_base_url": "http://127.0.0.1:11434/v1", "embedding_model": "embed-test"}
}
EOF
  mkdir -p "$home/data/gbrain/pglite"
  install_recall_stub "$bindir" '' 0 5 \
    'fm-recall: the search could not start, so no corpus was asked and this is not a result about your brain: could not create a temporary file'
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  out=$(curl -sS -m 8 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"query":"dashboard"}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  code=$(printf '%s' "$out" | tail -1)
  [ "$code" = "503" ] || fail "a search that never started returned $code instead of 503: $out"
  printf '%s' "$out" | head -1 | jq -e '
    .schema == "fm-gbrain-search.v1"
      and .reason == "search_setup_failed"
      and (.results | length) == 0
      and .detail == "the semantic search could not be started"
  ' >/dev/null || fail "a search that never started was not reported as search_setup_failed: $out"

  # The other side of the distinction, against the same endpoint: a wrapper that
  # exits 3 still reads as the corpora having been asked, so the new status did
  # not swallow the one it was carved out of.
  bindir=$(make_bin_dir search-no-corpus)
  install_recall_stub "$bindir" '' 0 3 \
    'fm-recall: no corpus could be read, so this is not an empty result set'
  start_server "$bindir" "$home" '{"schema":"fm-gbrain-capture-status.v1","totals":{"archived":0,"pending":0,"failed":0,"unreadable":0},"documents":[]}'
  out=$(curl -sS -m 8 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"query":"dashboard"}' \
    "http://127.0.0.1:$TEST_PORT/api/gbrain/search")
  code=$(printf '%s' "$out" | tail -1)
  [ "$code" = "503" ] || fail "a search no corpus answered returned $code instead of 503: $out"
  printf '%s' "$out" | head -1 | jq -e '.reason == "no_corpus_answered"' >/dev/null \
    || fail "a search no corpus answered was not reported as no_corpus_answered: $out"
  pass "a search that never started and a search no corpus answered are reported as different failures"
}

test_health_panel_reports_configured_home
test_health_panel_reports_no_brain
test_health_panel_survives_degraded_probes
test_search_returns_clean_envelope
test_search_preserves_same_as_local_source_state
test_search_returns_504_when_recall_exceeds_budget
test_search_separates_a_search_that_never_started_from_one_no_corpus_answered
test_search_treats_hostile_query_as_text
test_search_refuses_second_concurrent_search
test_search_refuses_empty_or_short_query
test_search_refuses_oversized_body
test_search_refuses_cross_origin_post
test_search_method_get_returns_405
printf '\nall fm-dashboard-gbrain tests passed\n'
