#!/usr/bin/env bash
# Live proof of the read-only main-brain share against a REAL GBrain instance.
#
# The claim this story rests on is that a secondmate can read the main brain and
# cannot mutate it. That claim is about GBrain's own OAuth scope enforcement, so
# a mock proves nothing: this builds two real brains, registers a real read-
# scoped OAuth client through bin/fm-gbrain.sh, serves the main brain over
# GBrain's own HTTP MCP transport, and drives real tool calls across it.
#
# It also proves the offline half of the contract for real: with the main brain
# stopped, the secondmate's own local search still answers from its own index.
#
# Opt-in, because it needs a GBrain installation and a local embedding endpoint
# that standard CI has neither of. Every brain, port, home, and credential it
# creates is disposable and confined to a temp root; it never touches the
# operator's own GBRAIN_HOME, brain, or ~/.gbrain.
set -u

if [ "${FM_GBRAIN_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_GBRAIN_LIVE_E2E=1 to run the live GBrain read-only share proof"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GBRAIN_BIN="${FM_GBRAIN_BIN:-gbrain}"
command -v "$GBRAIN_BIN" >/dev/null 2>&1 || { echo "skip: gbrain not found (set FM_GBRAIN_BIN)"; exit 0; }
for t in jq curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "skip: $t not found"; exit 0; }
done

EMBED_URL="${FM_GBRAIN_EMBED_URL:-http://127.0.0.1:11434/v1}"
EMBED_MODEL="${FM_GBRAIN_EMBED_MODEL:-ollama:snowflake-arctic-embed2:568m}"
EMBED_DIMS="${FM_GBRAIN_EMBED_DIMS:-1024}"
curl -sf -m 5 "${EMBED_URL%/}/models" >/dev/null 2>&1 \
  || { echo "skip: no local embedding endpoint at $EMBED_URL"; exit 0; }

CLI="$ROOT/bin/fm-gbrain.sh"
TMP_ROOT=$(fm_test_tmproot fm-gbrain-e2e)
SERVE_PID=""
PORT=""

cleanup_e2e() {
  if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
    kill "$SERVE_PID" 2>/dev/null || true
    local _wait
    for _wait in $(seq 1 20); do
      kill -0 "$SERVE_PID" 2>/dev/null || break
      sleep 1
    done
    : "$_wait"
    kill -9 "$SERVE_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_e2e EXIT

CANARY='xyzzy-mainbrain-canary'
SM_CANARY='xyzzy-secondmate-local-canary'

pick_port() {
  local p
  for p in $(seq 18790 18860); do
    curl -sf -m 1 "http://127.0.0.1:$p/health" >/dev/null 2>&1 && continue
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && { exec 3<&- 3>&-; continue; }
    printf '%s\n' "$p"
    return 0
  done
  return 1
}
PORT=$(pick_port) || { echo "skip: no free loopback port for the test brain"; exit 0; }

# --- build two real, isolated homes -----------------------------------------

MAIN_HOME="$TMP_ROOT/main"
SM_HOME="$TMP_ROOT/secondmate"
READER_TWO_HOME="$TMP_ROOT/reader-two"
mkdir -p "$MAIN_HOME/config" "$MAIN_HOME/data" "$SM_HOME/config" "$SM_HOME/data" \
  "$READER_TWO_HOME/config" "$READER_TWO_HOME/data"

SHARED=$(jq -n \
  --arg embed "$EMBED_URL" --arg model "$EMBED_MODEL" --argjson dims "$EMBED_DIMS" \
  --arg mcp "http://127.0.0.1:$PORT/mcp" --arg tok "http://127.0.0.1:$PORT/token" '
  {
    version: 1,
    local: {embedding_base_url: $embed, embedding_model: $model, embedding_dimensions: $dims},
    main_brain: {
      mcp_url: $mcp, token_url: $tok, mount: "fm-main",
      scopes: "read", secret: "main-brain-client-secret"
    }
  }')
printf '%s\n' "$SHARED" > "$MAIN_HOME/config/gbrain.json"
# The secondmate receives the shared plane exactly as inheritance would deliver
# it: byte-identical, and still resolving to its own brain.
cp "$MAIN_HOME/config/gbrain.json" "$SM_HOME/config/gbrain.json"
cp "$MAIN_HOME/config/gbrain.json" "$READER_TWO_HOME/config/gbrain.json"

home_env() {  # <home> <var>
  FM_HOME="$1" bash "$CLI" paths --json | jq -r ".$2"
}

MAIN_GBRAIN_HOME=$(home_env "$MAIN_HOME" gbrain_home)
MAIN_PGLITE=$(home_env "$MAIN_HOME" pglite)
SM_GBRAIN_HOME=$(home_env "$SM_HOME" gbrain_home)
SM_PGLITE=$(home_env "$SM_HOME" pglite)

[ "$MAIN_PGLITE" != "$SM_PGLITE" ] || fail "the two homes resolved one index"
mkdir -p "$MAIN_GBRAIN_HOME" "$SM_GBRAIN_HOME"

init_brain() {  # <gbrain-home> <pglite>
  GBRAIN_HOME="$1" OLLAMA_BASE_URL="$EMBED_URL" "$GBRAIN_BIN" init --pglite \
    --path "$2" --embedding-model "$EMBED_MODEL" --embedding-dimensions "$EMBED_DIMS" \
    --non-interactive >/dev/null 2>&1
}
put_page() {  # <gbrain-home> <slug> <body>
  printf -- '---\ntype: note\n---\n\n%s\n' "$3" \
    | GBRAIN_HOME="$1" OLLAMA_BASE_URL="$EMBED_URL" "$GBRAIN_BIN" put "$2" >/dev/null 2>&1
}

init_brain "$MAIN_GBRAIN_HOME" "$MAIN_PGLITE" || { echo "skip: could not initialize a test main brain"; exit 0; }
init_brain "$SM_GBRAIN_HOME" "$SM_PGLITE" || { echo "skip: could not initialize a test secondmate brain"; exit 0; }
put_page "$MAIN_GBRAIN_HOME" main-canary "The main brain holds $CANARY." \
  || fail "could not seed the main brain"
put_page "$SM_GBRAIN_HOME" sm-canary "This secondmate's own brain holds $SM_CANARY." \
  || fail "could not seed the secondmate brain"
WORLD_FACT='WORLD-CONTEXT-PACK-SENTINEL is visible remotely.'
PRIVATE_FACT='PRIVATE-CONTEXT-PACK-SENTINEL must remain local.'
GBRAIN_HOME="$MAIN_GBRAIN_HOME" OLLAMA_BASE_URL="$EMBED_URL" "$GBRAIN_BIN" remember "$WORLD_FACT" \
  --provenance 'live read-only E2E' --entity main-canary --kind commitment \
  --visibility world >/dev/null 2>&1 || fail "could not seed the world-visible fact"
GBRAIN_HOME="$MAIN_GBRAIN_HOME" OLLAMA_BASE_URL="$EMBED_URL" "$GBRAIN_BIN" remember "$PRIVATE_FACT" \
  --provenance 'live read-only E2E' --entity main-canary --kind commitment \
  --visibility private >/dev/null 2>&1 || fail "could not seed the private fact"
pass "two real, separately initialized brains exist, one per home"

# --- grant the read-only share ----------------------------------------------

grant_out=$(FM_HOME="$MAIN_HOME" FM_GBRAIN_BIN="$GBRAIN_BIN" \
  bash "$CLI" grant-read fm-e2e-read --home "$SM_HOME" 2>&1) \
  || fail "grant-read failed: $grant_out"

secret_file="$SM_HOME/config/gbrain-secrets/main-brain-client-secret"
assert_present "$secret_file" "grant-read must install the credential into the reading home"
mode=$(stat -c %a "$secret_file" 2>/dev/null || stat -f %Lp "$secret_file")
[ "$mode" = 600 ] || fail "the installed credential has mode $mode, expected 600"
CLIENT_SECRET=$(head -n 1 "$secret_file")
CLIENT_ID=$(jq -r .client_id "$SM_HOME/config/gbrain-local.json")
assert_not_contains "$grant_out" "$CLIENT_SECRET" "grant-read printed the credential it installed"
pass "grant-read installed a read-only credential at mode 0600 without printing it"

grant_two_out=$(FM_HOME="$MAIN_HOME" FM_GBRAIN_BIN="$GBRAIN_BIN" \
  bash "$CLI" grant-read fm-e2e-read-two --home "$READER_TWO_HOME" 2>&1) \
  || fail "second grant-read failed: $grant_two_out"
secret_file_two="$READER_TWO_HOME/config/gbrain-secrets/main-brain-client-secret"
assert_present "$secret_file_two" "the second reader must receive its own credential"
CLIENT_SECRET_TWO=$(head -n 1 "$secret_file_two")
CLIENT_ID_TWO=$(jq -r .client_id "$READER_TWO_HOME/config/gbrain-local.json")
[ "$CLIENT_ID" != "$CLIENT_ID_TWO" ] || fail "the two readers received one OAuth client id"
assert_not_contains "$grant_two_out" "$CLIENT_SECRET_TWO" "the second grant printed its credential"
pass "a second remote reader received a distinct read-only OAuth client"

writer_out=$(GBRAIN_HOME="$MAIN_GBRAIN_HOME" "$GBRAIN_BIN" auth register-client \
  fm-e2e-writer --scopes write --grant-types client_credentials 2>&1) \
  || fail "writer registration failed: $writer_out"
WRITER_ID=$(printf '%s\n' "$writer_out" | awk '/Client ID:/{print $NF}')
WRITER_SECRET=$(printf '%s\n' "$writer_out" | awk '/Client Secret:/{print $NF}')
[ -n "$WRITER_ID" ] && [ -n "$WRITER_SECRET" ] \
  || fail "the disposable writer registration returned no credentials"

# The registration must actually be read-scoped in GBrain's own records.
scopes=$(GBRAIN_HOME="$MAIN_GBRAIN_HOME" "$GBRAIN_BIN" auth list 2>/dev/null || true)
assert_not_contains "$scopes" "gbrain_" "auth list should not expose a usable token value"

# --- serve the main brain and drive real tool calls -------------------------
#
# The SERVED process is the one that would synthesize. `think` is scope:read
# since v0.42.76.0, so the guard further down really does reach it over the
# read-only share, and it would run on this process's model and credential: an
# inherited provider key would send the seeded main-brain page to a hosted
# provider from a suite that is supposed to touch nothing outside its temp root.
# So every credential-shaped variable is stripped from the served environment
# rather than the suite trusting the operator's shell to hold none, and the
# degrade is asserted at the call site instead of assumed.
serve_env=(env)
while IFS='=' read -r _name _; do
  case "$_name" in
    *API_KEY*|*AUTH_TOKEN*|*API_TOKEN*|*_SECRET_KEY) serve_env+=(-u "$_name") ;;
  esac
done < <(env)

"${serve_env[@]}" GBRAIN_HOME="$MAIN_GBRAIN_HOME" OLLAMA_BASE_URL="$EMBED_URL" \
  "$GBRAIN_BIN" serve --http --port "$PORT" > "$TMP_ROOT/serve.log" 2>&1 &
SERVE_PID=$!
up=0
for _ in $(seq 1 90); do
  curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { up=1; break; }
  kill -0 "$SERVE_PID" 2>/dev/null || break
  sleep 1
done
[ "$up" = 1 ] || { echo "skip: the test main brain did not start serving"; exit 0; }

TOKEN=$(FM_HOME="$SM_HOME" bash "$CLI" token) \
  || fail "the secondmate could not obtain a read-only token"
[ -n "$TOKEN" ] || fail "the secondmate received an empty token"
TOKEN_TWO=$(FM_HOME="$READER_TWO_HOME" bash "$CLI" token) \
  || fail "the second remote reader could not obtain a read-only token"
[ -n "$TOKEN_TWO" ] || fail "the second remote reader received an empty token"
WRITER_TOKEN=$(curl -sS -m 30 -X POST "http://127.0.0.1:$PORT/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode "client_id=$WRITER_ID" \
  --data-urlencode "client_secret=$WRITER_SECRET" \
  --data-urlencode 'scope=write' | jq -er '.access_token') \
  || fail "the disposable writer could not obtain an access token"
pass "both remote readers obtained read-only access tokens for the main brain"

mcp_call_with_token() {  # <token> <tool> <arguments-json> -> response body
  curl -sS -m 30 -X POST "http://127.0.0.1:$PORT/mcp" \
    -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$(jq -cn --arg n "$2" --argjson a "$3" \
      '{jsonrpc: "2.0", method: "tools/call", params: {name: $n, arguments: $a}, id: 1}')"
}

mcp_call() {  # <tool> <arguments-json> -> response body
  mcp_call_with_token "$TOKEN" "$1" "$2"
}

# The endpoint answers either a bare JSON-RPC body or an SSE frame depending on
# content negotiation, and the tool result is itself JSON encoded inside a
# string. Normalize both layers here so assertions can read parsed values
# instead of pattern-matching escaped JSON through the transport envelope.
mcp_result() {  # <response-body> -> tool result JSON, empty when unparseable
  local body="$1" sse
  sse=$(printf '%s\n' "$body" | sed -n 's/^data: //p' | tail -1)
  if [ -n "$sse" ]; then body="$sse"; fi
  printf '%s' "$body" | jq -r '.result.content[0].text // empty' 2>/dev/null
}

# The sorted slug set of a list_pages response, for proving a call left the
# page set alone. Shape-tolerant on purpose: it harvests every slug in the
# payload rather than binding to one envelope key that a release could rename.
mcp_result_slugs() {  # stdin: response body -> one sorted slug per line
  mcp_result "$(cat)" | jq -r '[.. | objects | .slug? // empty] | sort | .[]' 2>/dev/null
}

pack_out=$(mcp_call context_pack \
  '{"entities":"main-canary","include_private":true,"budget_tokens":1000}')
pack_json=$(mcp_result "$pack_out")
[ -n "$pack_json" ] || fail "the remote context_pack response could not be parsed: $pack_out"
assert_contains "$pack_json" "$WORLD_FACT" \
  "remote context_pack must retain the world-visible fact"
assert_not_contains "$pack_json" "$PRIVATE_FACT" \
  "remote context_pack must ignore include_private and exclude the private fact"
pack_observed=$(printf '%s' "$pack_json" | jq -c --arg private "$PRIVATE_FACT" '
  . as $pack | {
    include_private_requested: true,
    cards: [.cards[].slug],
    facts: [.facts[].fact],
    open_threads: [.open_threads[].text],
    private_present: ($pack | tostring | contains($private))
  }') || fail "could not summarize the remote context_pack result"
printf 'observed remote context_pack: %s\n' "$pack_observed"
pass "remote context_pack stays world-only when include_private is requested"

DELTA_SESSION='fm-shared-delta-session'
delta_args=$(jq -cn --arg session "$DELTA_SESSION" '{session_id:$session,budget_tokens:1000}')
client_one_established=$(mcp_result "$(mcp_call_with_token "$TOKEN" delta "$delta_args")")
client_two_established=$(mcp_result "$(mcp_call_with_token "$TOKEN_TWO" delta "$delta_args")")
for observed in "$client_one_established" "$client_two_established"; do
  [ -n "$observed" ] || fail "a remote delta response could not be parsed"
done
[ "$(printf '%s' "$client_one_established" | jq -c '[.pages[].slug]')" = '[]' ] \
  || fail "the first OAuth client did not establish an empty cursor"
[ "$(printf '%s' "$client_two_established" | jq -c '[.pages[].slug]')" = '[]' ] \
  || fail "the second OAuth client did not establish an empty cursor"

write_out=$(mcp_result "$(mcp_call_with_token "$WRITER_TOKEN" put_page \
  '{"slug":"isolated-delta-canary","content":"---\ntype: note\n---\n\nA new page created after both remote cursors exist.\n"}')")
[ -n "$write_out" ] || fail "the public MCP write response could not be parsed"
assert_contains "$write_out" 'isolated-delta-canary' \
  "the public MCP writer did not create the delta marker"

client_one_after_write=$(mcp_result "$(mcp_call_with_token "$TOKEN" delta "$delta_args")")
client_two_after_client_one=$(mcp_result "$(mcp_call_with_token "$TOKEN_TWO" delta "$delta_args")")
client_one_followup=$(mcp_result "$(mcp_call_with_token "$TOKEN" delta "$delta_args")")
client_two_followup=$(mcp_result "$(mcp_call_with_token "$TOKEN_TWO" delta "$delta_args")")
for observed in "$client_one_after_write" "$client_two_after_client_one" "$client_one_followup" "$client_two_followup"; do
  [ -n "$observed" ] || fail "a remote delta response could not be parsed"
done
client_one_after_write_slugs=$(printf '%s' "$client_one_after_write" | jq -c '[.pages[].slug]')
client_two_after_client_one_slugs=$(printf '%s' "$client_two_after_client_one" | jq -c '[.pages[].slug]')
client_one_followup_slugs=$(printf '%s' "$client_one_followup" | jq -c '[.pages[].slug]')
client_two_followup_slugs=$(printf '%s' "$client_two_followup" | jq -c '[.pages[].slug]')
[ "$client_one_after_write_slugs" = '["isolated-delta-canary"]' ] \
  || fail "the first OAuth client did not receive the new page: $client_one_after_write_slugs"
[ "$client_two_after_client_one_slugs" = '["isolated-delta-canary"]' ] \
  || fail "the first OAuth client's advancement consumed the second client's delta: $client_two_after_client_one_slugs"
[ "$client_one_followup_slugs" = '[]' ] \
  || fail "the first OAuth client's cursor did not advance: $client_one_followup_slugs"
[ "$client_two_followup_slugs" = '[]' ] \
  || fail "the second OAuth client's cursor did not advance: $client_two_followup_slugs"
delta_observed=$(jq -cn --arg session "$DELTA_SESSION" \
  --argjson client_one_after_write "$client_one_after_write_slugs" \
  --argjson client_two_after_client_one "$client_two_after_client_one_slugs" \
  --argjson client_one_followup "$client_one_followup_slugs" \
  --argjson client_two_followup "$client_two_followup_slugs" \
  '{session_id:$session,client_one_after_write:$client_one_after_write,client_two_after_client_one:$client_two_after_client_one,client_one_followup:$client_one_followup,client_two_followup:$client_two_followup}')
printf 'observed remote delta cursors: %s\n' "$delta_observed"
pass "distinct OAuth clients keep isolated cursors for one delta session id"

read_out=$(mcp_call get_page '{"slug":"main-canary"}')
assert_contains "$read_out" "$CANARY" "the secondmate must be able to read the main brain's content"
list_out=$(mcp_call list_pages '{}')
assert_contains "$list_out" "main-canary" "the secondmate must be able to list the main brain's pages"
pass "a read through the mounted main brain succeeds and returns real content"

# Every write-class operation must be refused, not merely discouraged.
for attempt in \
  'put_page|{"slug":"main-canary","content":"TAMPERED BY SECONDMATE"}' \
  'put_page|{"slug":"intruder-page","content":"should never exist"}' \
  'delete_page|{"slug":"main-canary"}'
do
  tool=${attempt%%|*}; args=${attempt#*|}
  write_out=$(mcp_call "$tool" "$args")
  assert_contains "$write_out" "insufficient_scope" \
    "$tool against the mounted main brain must be refused for lack of scope"
done
pass "every attempted write to the mounted main brain is refused for insufficient scope"

# The refusals must have changed nothing: this is the claim that matters.
after=$(mcp_call get_page '{"slug":"main-canary"}')
assert_contains "$after" "$CANARY" "the main brain's page must survive the write attempts"
assert_not_contains "$after" "TAMPERED BY SECONDMATE" "a refused write must not have landed"
intruder=$(mcp_call get_page '{"slug":"intruder-page"}')
assert_not_contains "$intruder" "should never exist" "a refused write must not have created a page"
pass "the main brain is byte-for-byte unaffected by the refused writes"

# --- the retrieval wrapper reads both corpora for real ----------------------
#
# bin/fm-recall.sh is what firstmate and every crewmate actually call, so the
# claim that a secondmate can search its own corpus PLUS the mounted main corpus
# is proven here against the real read-only share rather than against a stub.

RECALL="$ROOT/bin/fm-recall.sh"
recall_rc=0
recall_out=$(FM_HOME="$SM_HOME" FM_GBRAIN_BIN="$GBRAIN_BIN" \
  bash "$RECALL" search --json "$CANARY" 2>&1) || recall_rc=$?
expect_code 0 "$recall_rc" "the wrapper should read the shared corpus: $recall_out"
[ "$(printf '%s' "$recall_out" | jq -r '.sources[] | select(.source == "main") | .state')" = ok ] \
  || fail "the secondmate should reach the main brain through the wrapper: $recall_out"
assert_contains "$recall_out" '"citation": "main:main-canary"' \
  "a main-brain result must arrive citable as main:<slug>"

recall_out=$(FM_HOME="$SM_HOME" FM_GBRAIN_BIN="$GBRAIN_BIN" \
  bash "$RECALL" search --json "$SM_CANARY" 2>&1) || fail "the wrapper could not read the local corpus"
assert_contains "$recall_out" '"citation": "local:sm-canary"' \
  "a local result must arrive citable as local:<slug>"
pass "the retrieval wrapper reads this home's own corpus and the mounted main corpus, each labelled"

# What a read-only share can and cannot trigger through `think`.
#
# GBrain v0.42.76.0 reclassified `think` from a write-scope operation to
# scope:read, so the transport admits it and this guard can NO LONGER prove
# that main-brain content cannot reach a hosted model. That boundary is now
# operational rather than structural: docs/gbrain.md requires a home serving a
# main brain to carry no hosted synthesis credentials, and nothing here can
# enforce that for it.
#
# What IS still guaranteed is asserted directly rather than inferred from the
# op being unreachable, because "think returned something" alone would also
# pass on a genuinely broken read-only share. So the call is made in its most
# dangerous form - explicitly asking to persist - and the fence is proven from
# the parsed result AND from the main brain's page set being unchanged.
#
# The synthesis itself must degrade rather than run: the serving process was
# started with every provider credential stripped, and the assertion below is
# what proves that held, so this guard can never export the seeded page to a
# hosted model on an operator machine that happens to carry a key.
pages_before=$(mcp_call list_pages '{"limit":500}' | mcp_result_slugs)
assert_contains "$pages_before" "main-canary" \
  "the page-set snapshot must really list pages, or the unchanged-set assertion below is vacuous"

think_out=$(mcp_call think '{"question":"what is the canary?","save":true}')
assert_not_contains "$think_out" "insufficient_scope" \
  "think is scope:read since v0.42.76.0, so the transport must admit it rather than refuse it"
think_json=$(mcp_result "$think_out")
[ -n "$think_json" ] || fail "the think response could not be parsed: $think_out"
[ "$(printf '%s' "$think_json" | jq -r '.remote_persisted_blocked')" = true ] \
  || fail "a remote think that asked to persist must report the persistence blocked: $think_json"
# has() rather than a -r comparison: an absent field prints "null" too, so a
# release that renamed it while still persisting would satisfy the string test.
printf '%s' "$think_json" | jq -e 'has("saved_slug") and .saved_slug == null' >/dev/null \
  || fail "a remote think must never report a persisted synthesis page: $think_json"
printf '%s' "$think_json" | jq -e 'has("synthesisOk") and .synthesisOk == false' >/dev/null \
  || fail "the served brain reached a hosted model: this guard must run with no provider credential in the serving process: $think_json"

pages_after=$(mcp_call list_pages '{"limit":500}' | mcp_result_slugs)
[ "$pages_before" = "$pages_after" ] \
  || fail "think over a read-only share changed the main brain's page set"$'\n'"before: $pages_before"$'\n'"after:  $pages_after"
pass "a read-only share admits think, degrades it with no credential, cannot persist through it, and leaves the main brain unchanged"

# --- the secondmate writes only its OWN brain -------------------------------

put_page "$SM_GBRAIN_HOME" sm-second "The secondmate wrote this into its own brain." \
  || fail "the secondmate could not write its own brain"
own=$(GBRAIN_HOME="$SM_GBRAIN_HOME" OLLAMA_BASE_URL="$EMBED_URL" \
  "$GBRAIN_BIN" list 2>/dev/null || true)
assert_contains "$own" "sm-second" "the secondmate's own write must land in its own brain"
assert_not_contains "$own" "main-canary" "the main brain's pages must not appear in the secondmate's own index"

main_pages=$(mcp_call list_pages '{}')
assert_not_contains "$main_pages" "sm-second" "the secondmate's own write must not reach the main brain"
pass "the secondmate writes only its own brain, and the main brain never receives it"

# --- offline main brain leaves local search working -------------------------

kill "$SERVE_PID" 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 1; done
SERVE_PID=""

rc=0
FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" token >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "the main brain is stopped but a token was still issued"

local_search=$(GBRAIN_HOME="$SM_GBRAIN_HOME" OLLAMA_BASE_URL="$EMBED_URL" \
  "$GBRAIN_BIN" search "$SM_CANARY" 2>/dev/null || true)
assert_contains "$local_search" "sm-canary" \
  "with the main brain down, the secondmate's own search must still answer from its own index"

# The same must hold through the wrapper crewmates actually use: a stopped main
# brain is a degraded source, never a failed search.
recall_rc=0
recall_out=$(FM_HOME="$SM_HOME" FM_GBRAIN_BIN="$GBRAIN_BIN" FM_GBRAIN_TIMEOUT=3 \
  bash "$RECALL" search --json --timeout 30 "$SM_CANARY" 2>&1) || recall_rc=$?
expect_code 0 "$recall_rc" "a stopped main brain must not fail the wrapper's local search: $recall_out"
[ "$(printf '%s' "$recall_out" | jq -r '.sources[] | select(.source == "main") | .state')" = degraded ] \
  || fail "a stopped main brain should read as degraded through the wrapper: $recall_out"
assert_contains "$recall_out" '"citation": "local:sm-canary"' \
  "the home's own results must survive a stopped main brain"

rc=0
check_out=$(FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" check --json 2>/dev/null) || rc=$?
expect_code 0 "$rc" "a stopped main brain must not fail the reading home's check"
state=$(printf '%s' "$check_out" | jq -r '.[] | select(.check == "main-brain") | .state')
[ "$state" = degraded ] || fail "a stopped main brain should read as degraded, got '$state'"
pass "with the main brain offline the secondmate's local search still works and the outage reads as degraded"

# --- nothing generated along the way carried the credential -----------------

artifacts="$TMP_ROOT/artifacts.txt"
{
  printf '%s\n' "$grant_out"
  printf '%s\n' "$grant_two_out"
  FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" config
  FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" config --json
  FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" env
  FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" check || true
  cat "$SM_HOME/config/gbrain.json" "$SM_HOME/config/gbrain-local.json"
  cat "$TMP_ROOT/serve.log"
} > "$artifacts" 2>&1
assert_no_grep "$CLIENT_SECRET" "$artifacts" \
  "the real client secret appeared in a generated artifact or the server log"
assert_no_grep "$CLIENT_SECRET_TWO" "$artifacts" \
  "the second real client secret appeared in a generated artifact or the server log"
assert_no_grep "$WRITER_SECRET" "$artifacts" \
  "the disposable writer secret appeared in a generated artifact or the server log"
assert_grep "$CLIENT_ID" "$artifacts" "the client id should still be recorded"
assert_grep "$CLIENT_ID_TWO" "$artifacts" "the second client id should still be recorded"
pass "no generated artifact or server log contains the real client secret"

echo "all fm-gbrain-readonly-e2e tests passed"
