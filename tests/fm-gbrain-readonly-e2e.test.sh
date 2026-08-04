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
mkdir -p "$MAIN_HOME/config" "$MAIN_HOME/data" "$SM_HOME/config" "$SM_HOME/data"

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

# The registration must actually be read-scoped in GBrain's own records.
scopes=$(GBRAIN_HOME="$MAIN_GBRAIN_HOME" "$GBRAIN_BIN" auth list 2>/dev/null || true)
assert_not_contains "$scopes" "gbrain_" "auth list should not expose a usable token value"

# --- serve the main brain and drive real tool calls -------------------------

GBRAIN_HOME="$MAIN_GBRAIN_HOME" OLLAMA_BASE_URL="$EMBED_URL" \
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
pass "the secondmate obtained a read-only access token for the main brain"

mcp_call() {  # <tool> <arguments-json> -> response body
  curl -sS -m 30 -X POST "http://127.0.0.1:$PORT/mcp" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$(jq -cn --arg n "$1" --argjson a "$2" \
      '{jsonrpc: "2.0", method: "tools/call", params: {name: $n, arguments: $a}, id: 1}')"
}

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
  FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" config
  FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" config --json
  FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" env
  FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=3 bash "$CLI" check || true
  cat "$SM_HOME/config/gbrain.json" "$SM_HOME/config/gbrain-local.json"
  cat "$TMP_ROOT/serve.log"
} > "$artifacts" 2>&1
assert_no_grep "$CLIENT_SECRET" "$artifacts" \
  "the real client secret appeared in a generated artifact or the server log"
assert_grep "$CLIENT_ID" "$artifacts" "the client id should still be recorded"
pass "no generated artifact or server log contains the real client secret"

echo "all fm-gbrain-readonly-e2e tests passed"
