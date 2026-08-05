#!/usr/bin/env bash
# Behavior tests for bin/fm-recall.sh, the retrieval surface firstmate and
# crewmates use to read a brain.
#
# Portable: no GBrain installation, no brain, and no network. A recording stub
# stands in for the gbrain executable, which is what makes the argument-safety
# claim testable at all - the stub captures the exact argv and JSON it received,
# so "a hostile query cannot execute anything" is proven by what arrived rather
# than asserted about the source. The live proof that the same wrapper reads a
# REAL local brain and a REAL read-only main brain is
# tests/fm-gbrain-readonly-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for t in jq curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "skip: $t not found"; exit 0; }
done

CLI="$ROOT/bin/fm-recall.sh"
TMP_ROOT=$(fm_test_tmproot fm-recall)
STUB_DIR="$TMP_ROOT/stub"
mkdir -p "$STUB_DIR"

# --- the recording gbrain stub ----------------------------------------------
#
# It writes every argument it was given, one per line, plus the environment
# values that decide WHICH brain a call reaches, then replies with whatever the
# current test asked for. It never interprets the query.

STUB="$STUB_DIR/gbrain"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
set -u
: > "$FM_STUB_ARGV"
for a in "$@"; do printf '%s\n' "$a" >> "$FM_STUB_ARGV"; done
{
  printf 'GBRAIN_HOME=%s\n' "${GBRAIN_HOME:-}"
  printf 'OLLAMA_BASE_URL=%s\n' "${OLLAMA_BASE_URL:-}"
  printf 'MINIMAX_API_KEY_SET=%s\n' "$(if [ -n "${MINIMAX_API_KEY:-}" ]; then echo yes; else echo no; fi)"
  printf 'MINIMAX_API_KEY=%s\n' "${MINIMAX_API_KEY:-}"
} > "$FM_STUB_ENV"
[ "${FM_STUB_SLEEP:-0}" = 0 ] || sleep "$FM_STUB_SLEEP"
[ -z "${FM_STUB_STDERR:-}" ] || printf '%s\n' "$FM_STUB_STDERR" >&2
[ -z "${FM_STUB_OUT:-}" ] || cat "$FM_STUB_OUT"
exit "${FM_STUB_RC:-0}"
STUBEOF
chmod 0755 "$STUB"

export FM_STUB_ARGV="$TMP_ROOT/argv.txt"
export FM_STUB_ENV="$TMP_ROOT/env.txt"
export FM_GBRAIN_BIN="$STUB"

stub_reply() {  # <json-file-content>
  printf '%s\n' "$1" > "$TMP_ROOT/stub-out.json"
  export FM_STUB_OUT="$TMP_ROOT/stub-out.json"
  export FM_STUB_RC=0
  unset FM_STUB_STDERR FM_STUB_SLEEP 2>/dev/null || true
}

stub_fail() {  # <rc> <stderr>
  export FM_STUB_RC=$1 FM_STUB_STDERR=$2
  unset FM_STUB_OUT 2>/dev/null || true
}

SEARCH_HIT='[{"slug":"teardown-notes","title":"Teardown Notes","chunk_text":"Teardown refuses unlanded work.","score":0.91,"stale":false}]'

# --- home fixtures ----------------------------------------------------------

make_home() {  # <path> -> an operating firstmate home with a shared plane
  local home=$1
  mkdir -p "$home/config" "$home/data"
  jq -n '{version: 1, local: {embedding_base_url: "http://127.0.0.1:11434/v1"}}' \
    > "$home/config/gbrain.json"
  printf '%s\n' "$home"
}

MAIN_HOME=$(make_home "$TMP_ROOT/main")
SM_HOME=$(make_home "$TMP_ROOT/secondmate")
printf 'sm-01\n' > "$SM_HOME/.fm-secondmate-home"

# A worktree of the firstmate repository: the tracked tree with none of the
# gitignored operating directories, which is exactly what a crewmate on a
# firstmate task stands in.
CHECKOUT="$TMP_ROOT/checkout"
mkdir -p "$CHECKOUT/bin" "$CHECKOUT/state"

# An ordinary project worktree, which has no firstmate layout at all.
PROJECT_WT="$TMP_ROOT/project-worktree"
mkdir -p "$PROJECT_WT"

# The document's own consistency rule: every source row counts exactly the
# entries in the result list that carry its source, so summing the rows and
# counting the list can never disagree about what was returned.
assert_rows_match_results() {  # <document> <what>
  local doc=$1 what=$2 mismatch
  mismatch=$(printf '%s' "$doc" | jq -r '
    . as $d
    | [ $d.sources[]
        | . as $row
        | select($row.results != ([$d.results[] | select(.source == $row.source)] | length))
        | $row.source ]
    | join(",")' 2>/dev/null) || mismatch="unreadable"
  [ -z "$mismatch" ] \
    || fail "$what: source rows disagree with the result list for [$mismatch]: $doc"
}

run_recall() {  # <home-env-or-empty> <args...> -> RECALL_OUT / RECALL_RC
  local home=$1
  shift
  RECALL_OUT=""
  RECALL_RC=0
  if [ -n "$home" ]; then
    RECALL_OUT=$(FM_HOME="$home" bash "$CLI" "$@" 2>&1) || RECALL_RC=$?
  else
    RECALL_OUT=$(env -u FM_HOME bash "$CLI" "$@" 2>&1) || RECALL_RC=$?
  fi
}

# --- 1. the same command resolves the right brain from every task location ---

stub_reply "$SEARCH_HIT"

run_recall "$MAIN_HOME" search --json teardown
expect_code 0 "$RECALL_RC" "a search from the main home should succeed"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .home)" = "$MAIN_HOME" ] \
  || fail "FM_HOME did not select the main home's brain"
assert_grep "GBRAIN_HOME=$MAIN_HOME/data/gbrain/runtime" "$FM_STUB_ENV" \
  "the call must reach the main home's own brain runtime"

run_recall "$SM_HOME" search --json teardown
[ "$(printf '%s' "$RECALL_OUT" | jq -r .home)" = "$SM_HOME" ] \
  || fail "a secondmate home did not select its own brain"
assert_grep "GBRAIN_HOME=$SM_HOME/data/gbrain/runtime" "$FM_STUB_ENV" \
  "a secondmate must read its own brain, not the main home's"

# A crewmate in a project worktree reaches the wrapper by the absolute path its
# brief gives it, with no firstmate environment at all.
RECALL_RC=0
RECALL_OUT=$(cd "$PROJECT_WT" && env -u FM_HOME bash "$CLI" search --json --home "$MAIN_HOME" teardown 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "a crewmate in a project worktree should reach its home's brain"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .home)" = "$MAIN_HOME" ] \
  || fail "--home did not select the named home from a project worktree"

# --home outranks an inherited FM_HOME, so a caller that names a home is never
# quietly answered from a different one.
run_recall "$SM_HOME" search --json --home "$MAIN_HOME" teardown
[ "$(printf '%s' "$RECALL_OUT" | jq -r .home)" = "$MAIN_HOME" ] \
  || fail "--home must outrank FM_HOME"
pass "one wrapper resolves the correct brain from the main home, a secondmate home, and a project worktree"

# --- 2. a source checkout is refused rather than turned into a brain ---------
#
# Deriving the home from the invocation root alone would let a crewmate on a
# firstmate task create an empty brain inside a worktree teardown then deletes,
# and report success while doing it.

RECALL_RC=0
RECALL_OUT=$(cd "$CHECKOUT" && env -u FM_HOME bash "$ROOT/bin/fm-recall.sh" search --json teardown 2>&1) || RECALL_RC=$?
expect_code 2 "$RECALL_RC" "an unresolvable home must refuse rather than guess"
RECALL_RC=0
RECALL_OUT=$(cd "$CHECKOUT" && env -u FM_HOME FM_ROOT_OVERRIDE="$CHECKOUT" bash "$CLI" search --json teardown 2>&1) || RECALL_RC=$?
expect_code 2 "$RECALL_RC" "a source checkout is not an operating home"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .error.code)" = no_home ] \
  || fail "the refusal should be reported as no_home, got: $RECALL_OUT"
assert_contains "$RECALL_OUT" "source checkout" "the refusal must say why the location cannot be used"
assert_absent "$CHECKOUT/data/gbrain" "a refused resolution must not have created a brain in the checkout"

run_recall "$TMP_ROOT/nowhere" search --json teardown
expect_code 2 "$RECALL_RC" "a home that does not exist must be refused"
pass "a firstmate source checkout is refused by name instead of resolving a throwaway brain"

# --- 3. a hostile query is data, never a command ----------------------------

# Every quoting style a naive implementation reaches for is attacked at once:
# the single quote breaks a '<json>' wrapper, the double quote breaks a "<json>"
# one, and the substitutions fire the moment either lets the shell see them.
# shellcheck disable=SC2016  # the substitutions must stay unexpanded: they are the payload.
HOSTILE=$(printf '%s' 'teardown'"'"'; touch '"$TMP_ROOT"'/PWNED; "; touch '"$TMP_ROOT"'/PWNED2; $(touch '"$TMP_ROOT"'/PWNED3) `touch '"$TMP_ROOT"'/PWNED4` && rm -rf / #')
stub_reply "$SEARCH_HIT"
run_recall "$MAIN_HOME" search --json -- "$HOSTILE"
expect_code 0 "$RECALL_RC" "a query full of shell metacharacters is still an ordinary query"
assert_absent "$TMP_ROOT/PWNED" "a single quote in a query must not escape a quoted argument"
assert_absent "$TMP_ROOT/PWNED2" "a double quote in a query must not escape a quoted argument"
assert_absent "$TMP_ROOT/PWNED3" "a query must not be able to run a command substitution"
assert_absent "$TMP_ROOT/PWNED4" "a query must not be able to run a backquoted command"

# The query must arrive at GBrain byte-identical: neither mangled by quoting nor
# split across arguments.
[ "$(printf '%s' "$RECALL_OUT" | jq -r .query)" = "$HOSTILE" ] \
  || fail "the reported query was not the query that was asked"
[ "$(sed -n 1p "$FM_STUB_ARGV")" = call ] || fail "the wrapper should use gbrain's trusted local dispatch"
[ "$(sed -n 2p "$FM_STUB_ARGV")" = search ] || fail "a search must dispatch the search operation"
STUB_QUERY=$(sed -n 3p "$FM_STUB_ARGV" | jq -r .query)
[ "$STUB_QUERY" = "$HOSTILE" ] || fail "the query reached gbrain altered: $STUB_QUERY"
[ "$(wc -l < "$FM_STUB_ARGV")" -eq 3 ] \
  || fail "the query must arrive as ONE argument, not split into several"

# A newline inside a query is the case a line-oriented pipeline gets wrong.
# shellcheck disable=SC2016  # the substitution must stay unexpanded: it is the payload.
NEWLINE_QUERY='first line
second "line" $(touch '"$TMP_ROOT"'/PWNED5)'
run_recall "$MAIN_HOME" search --json -- "$NEWLINE_QUERY"
expect_code 0 "$RECALL_RC" "a multi-line query should be accepted"
assert_absent "$TMP_ROOT/PWNED5" "a multi-line query must not be able to run a command"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .query)" = "$NEWLINE_QUERY" ] \
  || fail "a multi-line query was not preserved"
pass "shell metacharacters and newlines in a query reach GBrain as one intact JSON value and execute nothing"

# --- 4. local retrieval failures are named as local --------------------------

stub_fail 1 "No brain configured. Run: gbrain init"
run_recall "$MAIN_HOME" search --json teardown
expect_code 3 "$RECALL_RC" "a local retrieval failure has its own exit status"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "local") | .state')" = failed ] \
  || fail "the local source should read as failed: $RECALL_OUT"
assert_contains "$RECALL_OUT" "No brain configured" "the refusal must carry GBrain's own reason"

# A missing GBrain is this home's own index failing, and it is reported through
# the same document as every other source verdict rather than as its own shape.
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$MAIN_HOME" FM_GBRAIN_BIN="$TMP_ROOT/not-installed" bash "$CLI" search --json teardown 2>&1) || RECALL_RC=$?
expect_code 3 "$RECALL_RC" "a missing GBrain with no other corpus to read is a retrieval failure"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .schema)" = fm-recall.v1 ] \
  || fail "a missing GBrain must still leave the documented document behind: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "local") | .state')" = failed ] \
  || fail "a missing GBrain should read as a failed local source: $RECALL_OUT"
assert_contains "$RECALL_OUT" "gbrain is not installed" "the local verdict must say GBrain is missing"

# A result of an unexpected shape must fail as a local retrieval failure with
# the usual document, not die mid-render with a raw parser error.
stub_reply '{"not":"a list of results"}'
run_recall "$MAIN_HOME" search --json teardown
expect_code 3 "$RECALL_RC" "a malformed local result is a local retrieval failure"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "local") | .state')" = failed ] \
  || fail "a malformed local result should read as failed: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .schema)" = fm-recall.v1 ] \
  || fail "a malformed local result must still produce the documented shape"

# The container being the right type is not enough: a row is indexed by name, so
# a reply whose ROWS are not objects reaches the renderer and dies there, with a
# raw parser error and an exit status outside this command's contract.
for MALFORMED in '[1,2]' '["teardown-notes"]' '[null]' '[[]]'; do
  stub_reply "$MALFORMED"
  run_recall "$MAIN_HOME" search --json teardown
  expect_code 3 "$RECALL_RC" "a malformed result ROW is a local retrieval failure, not a crash: $MALFORMED"
  [ "$(printf '%s' "$RECALL_OUT" | jq -r .schema)" = fm-recall.v1 ] \
    || fail "a malformed result row must still produce the documented shape ($MALFORMED): $RECALL_OUT"
  [ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "local") | .state')" = failed ] \
    || fail "a malformed result row should read as a failed local source ($MALFORMED): $RECALL_OUT"
  assert_not_contains "$RECALL_OUT" "jq:" "a malformed row must not surface a raw parser error ($MALFORMED)"
done

# A row that IS an object but carries a field of the wrong type is a poorer row,
# not an unreadable corpus: it stays citable and the read still answers.
stub_reply '[{"slug":7,"title":null,"chunk_text":42,"score":"high"}]'
run_recall "$MAIN_HOME" search --json teardown
expect_code 0 "$RECALL_RC" "a row with unexpected field types should still be rendered: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].citation')" = local:7 ] \
  || fail "a non-string slug should still produce a citation: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].score')" = null ] \
  || fail "a non-numeric score must not be ranked on: $RECALL_OUT"

# A single corpus is returned in exactly the order that brain returned it. Its
# order is its own verdict - reranking runs inside the brain and its score
# column does not expose that contribution - so these rows arrive in ascending
# score deliberately: a wrapper that re-sorted on score would reverse them.
stub_reply '[{"slug":"reranked-first","title":"First","chunk_text":"a","score":0.11,"stale":false},
             {"slug":"reranked-second","title":"Second","chunk_text":"b","score":0.42,"stale":false},
             {"slug":"reranked-third","title":"Third","chunk_text":"c","score":0.87,"stale":false}]'
run_recall "$MAIN_HOME" search --json teardown
expect_code 0 "$RECALL_RC" "a single-corpus read should answer: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[].slug] | join(",")')" \
  = "reranked-first,reranked-second,reranked-third" ] \
  || fail "a single corpus must keep the order the brain returned: $RECALL_OUT"

stub_reply "$SEARCH_HIT"
export FM_STUB_SLEEP=5
run_recall "$MAIN_HOME" search --json --timeout 1 teardown
unset FM_STUB_SLEEP
expect_code 3 "$RECALL_RC" "a call that overruns its bound is a local retrieval failure"
assert_contains "$RECALL_OUT" "did not answer within" "an overrun must say the brain did not answer in time"

# The same bound taken through the perl arm, which is the one macOS actually
# uses and which a host with timeout(1) would otherwise never reach.
if command -v perl >/dev/null 2>&1; then
  stub_reply "$SEARCH_HIT"
  export FM_STUB_SLEEP=5
  RECALL_RC=0
  RECALL_OUT=$(FM_HOME="$MAIN_HOME" FM_TIMEOUT_FORCE_FALLBACK=1 bash "$CLI" search --json --timeout 1 teardown 2>&1) || RECALL_RC=$?
  unset FM_STUB_SLEEP
  expect_code 3 "$RECALL_RC" "the fallback bound must expire an overrunning call the same way timeout(1) does"
  assert_contains "$RECALL_OUT" "did not answer within" "the fallback bound must report an overrun as an overrun"
  stub_reply "$SEARCH_HIT"
  RECALL_RC=0
  RECALL_OUT=$(FM_HOME="$MAIN_HOME" FM_TIMEOUT_FORCE_FALLBACK=1 bash "$CLI" search --json teardown 2>&1) || RECALL_RC=$?
  expect_code 0 "$RECALL_RC" "the fallback bound must return an ordinary answer unchanged: $RECALL_OUT"
  [ "$(printf '%s' "$RECALL_OUT" | jq -r '.results | length')" -eq 1 ] \
    || fail "the fallback bound should deliver the brain's own results: $RECALL_OUT"
fi
pass "a missing brain, a refusing brain, a malformed row, and an overrunning brain each fail as LOCAL retrieval"

# --- 5. hosted synthesis fails on its own, and never takes search with it ----

stub_reply "$SEARCH_HIT"
run_recall "$MAIN_HOME" think --json "what does teardown refuse"
expect_code 4 "$RECALL_RC" "an unconfigured hosted provider is a hosted failure"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .error.code)" = hosted_unconfigured \
  ] || fail "expected hosted_unconfigured, got: $RECALL_OUT"

jq '.think = {base_url: "https://api.example.invalid/v1", model: "minimax:MiniMax-M3", secret: "minimax-key"}' \
  "$MAIN_HOME/config/gbrain.json" > "$TMP_ROOT/g.json" && mv "$TMP_ROOT/g.json" "$MAIN_HOME/config/gbrain.json"

run_recall "$MAIN_HOME" think --json "what does teardown refuse"
expect_code 4 "$RECALL_RC" "a named but uninstalled hosted credential is a hosted failure"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .error.code)" = hosted_key_missing \
  ] || fail "expected hosted_key_missing, got: $RECALL_OUT"
assert_contains "$RECALL_OUT" "fm-recall.sh search" \
  "a hosted failure must name the retrieval path that still works"

# THE claim: with the hosted provider unusable, local search still answers.
run_recall "$MAIN_HOME" search --json teardown
expect_code 0 "$RECALL_RC" "local search must not depend on the hosted provider"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results | length')" -eq 1 ] \
  || fail "local search should still return results with no hosted credential"

# GBrain answers with a placeholder and exit 0 when it has no usable model, so a
# wrapper that trusted the exit status would report a non-answer as an answer.
mkdir -p "$MAIN_HOME/config/gbrain-secrets"
printf 'test-hosted-credential-value\n' > "$MAIN_HOME/config/gbrain-secrets/minimax-key"
chmod 0600 "$MAIN_HOME/config/gbrain-secrets/minimax-key"
stub_reply '{"question":"q","answer":"(no LLM available)","citations":[],"pagesGathered":3,"modelUsed":"minimax:MiniMax-M3","warnings":["LLM_OUTPUT_NOT_JSON"],"synthesisOk":false}'
run_recall "$MAIN_HOME" think --json "what does teardown refuse"
expect_code 4 "$RECALL_RC" "a placeholder answer must not be reported as success"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .synthesis.state)" = failed ] \
  || fail "synthesis should read as failed: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[0].state')" = ok ] \
  || fail "the local half of a failed synthesis still worked and must say so"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[0].results')" = 3 ] \
  || fail "the pages the local half gathered should still be reported"

# think renders values the provider chose, so it must survive an unexpected
# shape exactly as search does: a nested value indexed by name is refused as a
# local retrieval failure, and a value that is only printed is coerced. Either
# way the wrapper leaves a document behind rather than a raw parser error.
for THINK_UNREADABLE in \
  '{"answer":"ok","citations":[1],"synthesisOk":true}' \
  '{"answer":"ok","citations":["teardown-notes"],"synthesisOk":true}' \
  '{"answer":"ok","warnings":"LLM_OUTPUT_NOT_JSON","synthesisOk":true}' \
  '["not","an","object"]'; do
  stub_reply "$THINK_UNREADABLE"
  run_recall "$MAIN_HOME" think --json "what does teardown refuse"
  expect_code 3 "$RECALL_RC" "an unreadable think reply is a local retrieval failure: $THINK_UNREADABLE"
  [ "$(printf '%s' "$RECALL_OUT" | jq -r .error.code)" = local_retrieval_failed ] \
    || fail "an unreadable think reply must be named as one ($THINK_UNREADABLE): $RECALL_OUT"
  [ "$(printf '%s' "$RECALL_OUT" | jq -r .schema)" = fm-recall.v1 ] \
    || fail "an unreadable think reply must still leave the document behind ($THINK_UNREADABLE): $RECALL_OUT"
  assert_not_contains "$RECALL_OUT" "jq:" "an unreadable think reply must not surface a raw parser error"
done

# A field of the wrong TYPE is a value worth less, not an unreadable reply: the
# answer, the warnings, the model and the page count all still render.
stub_reply '{"answer":5000,"citations":[{"page_slug":7}],"pagesGathered":"three","modelUsed":{"name":"m"},"warnings":[{"code":"X"},9],"synthesisOk":true}'
run_recall "$MAIN_HOME" think --json --max-answer 2 "what does teardown refuse"
expect_code 0 "$RECALL_RC" "a think reply with odd field types should still render: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .synthesis.answer)" = "50..." ] \
  || fail "a non-string answer should be coerced and capped: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .synthesis.truncated)" = true ] \
  || fail "a coerced answer over the cap must report itself truncated: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.synthesis.warnings | join("|")')" = '{"code":"X"}|9' ] \
  || fail "non-string warnings should be coerced rather than break the render: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.citations[0]')" = local:7 ] \
  || fail "a non-string page slug should still be citable: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[0].results')" = 0 ] \
  || fail "a non-numeric page count must not be reported as a number it is not: $RECALL_OUT"

# The same reply through the human renderer, which joins the warnings it was
# handed and would die on a value the document promised was a string.
stub_reply '{"answer":5000,"citations":[{"page_slug":7}],"pagesGathered":"three","modelUsed":{"name":"m"},"warnings":[{"code":"X"},9],"synthesisOk":true}'
run_recall "$MAIN_HOME" think "what does teardown refuse"
expect_code 0 "$RECALL_RC" "the human renderer must survive the same reply: $RECALL_OUT"
assert_not_contains "$RECALL_OUT" "jq:" "the human renderer must not surface a raw parser error"
pass "hosted synthesis failure is reported as hosted, keeps local retrieval's own verdict, never fails search, and an unreadable or oddly typed reply degrades instead of crashing"

# --- 6. the hosted credential reaches one process and nothing else -----------

stub_reply '{"question":"q","answer":"An answer [teardown-notes].","citations":[{"page_slug":"teardown-notes"}],"pagesGathered":1,"modelUsed":"minimax:MiniMax-M3","warnings":[],"synthesisOk":true}'
run_recall "$MAIN_HOME" think --json "what does teardown refuse"
expect_code 0 "$RECALL_RC" "a real synthesis should succeed"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.citations[0]')" = local:teardown-notes \
  ] || fail "a synthesis citation should be citable as <source>:<slug>"
assert_grep "MINIMAX_API_KEY_SET=yes" "$FM_STUB_ENV" \
  "the hosted credential must reach the synthesizing process"
assert_not_contains "$RECALL_OUT" "test-hosted-credential-value" \
  "the hosted credential must never appear in this command's output"

# A search never carries the hosted credential: retrieval stays on this host.
stub_reply "$SEARCH_HIT"
run_recall "$MAIN_HOME" search --json teardown
assert_grep "MINIMAX_API_KEY_SET=no" "$FM_STUB_ENV" \
  "a local search must not hand the hosted credential to anything"

# A credential stored too loosely is a finding, not an outage.
chmod 0644 "$MAIN_HOME/config/gbrain-secrets/minimax-key"
run_recall "$MAIN_HOME" think --json "what does teardown refuse"
expect_code 2 "$RECALL_RC" "a world-readable credential must be refused, not used"
chmod 0600 "$MAIN_HOME/config/gbrain-secrets/minimax-key"
pass "the hosted credential reaches only the synthesizing process, never search, never the output"

# --- 7. the main brain is a separate, softer fact ---------------------------

jq '.main_brain = {mcp_url: "http://127.0.0.1:9/mcp", token_url: "http://127.0.0.1:9/token", mount: "fm-main", scopes: "read", secret: "main-brain-client-secret"}' \
  "$SM_HOME/config/gbrain.json" > "$TMP_ROOT/g.json" && mv "$TMP_ROOT/g.json" "$SM_HOME/config/gbrain.json"

stub_reply "$SEARCH_HIT"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=2 bash "$CLI" search --json teardown 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "an unreachable main brain must not fail a home's own search"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = degraded ] \
  || fail "an unshared main brain should read as degraded: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "local") | .state')" = ok ] \
  || fail "the home's own brain answered and must say so"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results | length')" -eq 1 ] \
  || fail "local results must survive an unreachable main brain"

# The home that owns the main brain reads it directly and never mints a token
# to itself, so it must not report itself as having lost access.
jq -n '{version: 1, main_brain_owner: true}' > "$MAIN_HOME/config/gbrain-local.json"
jq '.main_brain = {mcp_url: "http://127.0.0.1:9/mcp", token_url: "http://127.0.0.1:9/token", scopes: "read", secret: "main-brain-client-secret"}' \
  "$MAIN_HOME/config/gbrain.json" > "$TMP_ROOT/g.json" && mv "$TMP_ROOT/g.json" "$MAIN_HOME/config/gbrain.json"
run_recall "$MAIN_HOME" search --json teardown
expect_code 0 "$RECALL_RC" "the owning home's search should succeed"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = same-as-local ] \
  || fail "the owning home should report the main brain as its own: $RECALL_OUT"

# Every row counts the entries that actually carry its source, so the alias row
# cannot claim a hit that only exists once and consumers summing rows cannot
# double count the same result against the list it came from.
assert_rows_match_results "$RECALL_OUT" "the owning home's default search"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .results')" = 0 ] \
  || fail "the alias row contributes no main-sourced result and must count none: $RECALL_OUT"

# On that home the local index IS the main corpus, so a main-only search asks a
# question with a real answer and must be answered rather than returned empty.
run_recall "$MAIN_HOME" search --json --scope main teardown
expect_code 0 "$RECALL_RC" "the owning home must answer a main-only search: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results | length')" -eq 1 ] \
  || fail "a main-only search on the owning home must read the corpus it owns: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = same-as-local ] \
  || fail "the owning home should still report the main corpus as its own: $RECALL_OUT"
assert_rows_match_results "$RECALL_OUT" "the owning home's main-only search"

# The alias row must never read as though the corpus was consulted when the leg
# that stands in for it did not answer, or a consumer filtering on state alone
# sees the main corpus succeed while nothing was ever read.
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$MAIN_HOME" FM_GBRAIN_BIN="$TMP_ROOT/not-installed" bash "$CLI" search --json --scope main teardown 2>&1) || RECALL_RC=$?
expect_code 3 "$RECALL_RC" "the owning home cannot answer a main-only search with no readable index"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = failed ] \
  || fail "the alias row must carry the failure of the leg that stands in for it: $RECALL_OUT"
assert_contains "$RECALL_OUT" "gbrain is not installed" \
  "the alias row must say why the corpus could not be read"
assert_rows_match_results "$RECALL_OUT" "the owning home with no readable index"

# An unreachable main brain is a soft fact only while another corpus answered.
# Asked for that corpus alone, the run fails rather than reporting no matches.
stub_reply "$SEARCH_HIT"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" FM_GBRAIN_TIMEOUT=2 bash "$CLI" search --json --scope main policy 2>&1) || RECALL_RC=$?
expect_code 3 "$RECALL_RC" "an unreachable main brain must fail a main-only search instead of reporting no matches"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = degraded ] \
  || fail "a main-only search should still carry the main source's own verdict: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results | length')" -eq 0 ] \
  || fail "an unreachable main brain returns no results: $RECALL_OUT"
pass "an unreachable main brain degrades without touching local results, fails a main-only search, and its owner answers from the corpus it owns"

# The main brain answers over SSE, and a refused read arrives as an in-band
# error rather than an HTTP failure. Both are parsed here rather than at the
# renderer, so a fake transport is the honest way to cover them without a server.
FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'CURLEOF'
#!/usr/bin/env bash
# Answers the token mint with whatever token the current case asked for, then
# replies to the MCP call with whatever body it asked for. It reads nothing out
# of the request, so it cannot leak a credential, and the token is encoded with
# jq so a case can hand back one containing bytes a config file treats as
# syntax - the shape the wrapper has to refuse.
#
# It does reproduce the one config-file behavior that makes that refusal matter:
# a curl config file is line-oriented, so an `output = <path>` line WRITES that
# path. Honoring it here is what makes "a token can never become a directive" a
# property this suite proves rather than one it asserts about the source.
CONFIG=$(cat)
while IFS= read -r line; do
  case $line in
    'output = '*) printf 'injected\n' > "${line#output = }" ;;
  esac
done <<CFGEOF
$CONFIG
CFGEOF
for a in "$@"; do
  case $a in
    */token) jq -cn --arg t "${FM_FAKE_TOKEN:-fake-token}" '{access_token: $t, token_type: "Bearer"}'; exit 0 ;;
  esac
done
cat "$FM_FAKE_MCP_REPLY"
exit 0
CURLEOF
chmod 0755 "$FAKE_BIN/curl"

mkdir -p "$SM_HOME/config/gbrain-secrets"
printf 'gbrain_cs_fake\n' > "$SM_HOME/config/gbrain-secrets/main-brain-client-secret"
chmod 0600 "$SM_HOME/config/gbrain-secrets/main-brain-client-secret"
jq -n '{version: 1, client_id: "fake-client"}' > "$SM_HOME/config/gbrain-local.json"
jq -n '{version: 1,
        local: {embedding_base_url: "http://127.0.0.1:11434/v1"},
        main_brain: {mcp_url: "http://127.0.0.1:9/mcp", token_url: "http://127.0.0.1:9/token",
                     mount: "fm-main", scopes: "read", secret: "main-brain-client-secret"}}' \
  > "$SM_HOME/config/gbrain.json"
export FM_FAKE_MCP_REPLY="$TMP_ROOT/mcp-reply.txt"

MAIN_HIT='[{"slug":"fleet-policy","title":"Fleet Policy","chunk_text":"The main brain holds the fleet policy.","score":0.77,"stale":false}]'
{
  printf 'event: message\n'
  printf 'data: %s\n' "$(jq -cn --arg t "$MAIN_HIT" '{result: {content: [{type: "text", text: $t}]}, jsonrpc: "2.0", id: 1}')"
} > "$FM_FAKE_MCP_REPLY"

stub_reply "$SEARCH_HIT"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" PATH="$FAKE_BIN:$PATH" bash "$CLI" search --json policy 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "an SSE answer from the main brain should be read: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = ok ] \
  || fail "an SSE main-brain answer should read as ok: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[] | select(.source == "main")] | length')" -eq 1 ] \
  || fail "a main-brain result should be merged into the result list: $RECALL_OUT"
assert_contains "$RECALL_OUT" '"citation": "main:fleet-policy"' \
  "a main-brain result must be citable as main:<slug>"
# Both corpora land in one list rather than one appended after the other, so a
# crewmate reads each brain's best evidence early whichever brain holds it.
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[].source] | sort | unique | join(",")')" = local,main ] \
  || fail "both corpora should appear in one result list: $RECALL_OUT"

# The merge interleaves by RANK and never re-sorts on the score column, because
# two brains' scores are different quantities. This corpus pair is built so the
# two rules disagree: every main row outscores every local row, so a score sort
# would put both main rows first, while the rank merge alternates and leads with
# this home's own index.
LOCAL_PAIR='[{"slug":"local-first","title":"Local First","chunk_text":"first","score":0.30,"stale":false},
             {"slug":"local-second","title":"Local Second","chunk_text":"second","score":0.20,"stale":false}]'
MAIN_PAIR='[{"slug":"main-first","title":"Main First","chunk_text":"first","score":0.99,"stale":false},
            {"slug":"main-second","title":"Main Second","chunk_text":"second","score":0.98,"stale":false}]'
{
  printf 'event: message\n'
  printf 'data: %s\n' "$(jq -cn --arg t "$MAIN_PAIR" '{result: {content: [{type: "text", text: $t}]}, jsonrpc: "2.0", id: 1}')"
} > "$FM_FAKE_MCP_REPLY"
stub_reply "$LOCAL_PAIR"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" PATH="$FAKE_BIN:$PATH" bash "$CLI" search --json policy 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "a two-corpus read should answer: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[].citation] | join(",")')" \
  = "local:local-first,main:main-first,local:local-second,main:main-second" ] \
  || fail "two corpora should be merged by rank, own index first on an equal rank: $RECALL_OUT"
# Guard the divergence itself, so this case cannot go quietly vacuous if the
# fixture scores are ever edited into agreement with the rank order.
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[].score] == ([.results[].score] | sort | reverse)')" = false ] \
  || fail "the fixture must make score order and rank order disagree: $RECALL_OUT"
# The merge is a permutation of what the two corpora returned, so every row each
# source counts is still in the list and none was dropped or duplicated.
assert_rows_match_results "$RECALL_OUT" "the two-corpus rank merge"

# A corpus that runs out drops out of the cycle and the other keeps its order.
stub_reply "$SEARCH_HIT"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" PATH="$FAKE_BIN:$PATH" bash "$CLI" search --json policy 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "an uneven two-corpus read should answer: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[].citation] | join(",")')" \
  = "local:teardown-notes,main:main-first,main:main-second" ] \
  || fail "a corpus with fewer results should drop out of the cycle: $RECALL_OUT"
assert_rows_match_results "$RECALL_OUT" "the uneven two-corpus merge"

# GBrain refuses an out-of-scope operation in band, with isError and HTTP 200.
{
  printf 'event: message\n'
  printf 'data: %s\n' '{"result":{"content":[{"type":"text","text":"{\"error\":\"insufficient_scope\",\"message\":\"Operation search requires write scope\",\"your_scopes\":[\"read\"]}"}],"isError":true},"jsonrpc":"2.0","id":1}'
} > "$FM_FAKE_MCP_REPLY"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" PATH="$FAKE_BIN:$PATH" bash "$CLI" search --json policy 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "a refused main-brain read must not fail this home's own search"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = degraded ] \
  || fail "a refused main-brain read should read as degraded: $RECALL_OUT"
assert_contains "$RECALL_OUT" "insufficient_scope" \
  "a refused main-brain read must carry GBrain's own reason"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[] | select(.source == "local")] | length')" -eq 1 ] \
  || fail "local results must survive a refused main-brain read"

# A main-brain result row of the wrong shape must degrade that source, not kill
# the render: the shape is checked at this leg's boundary too, not once.
for MAIN_MALFORMED in '[1,2]' '{"not":"a list"}' '["fleet-policy"]'; do
  {
    printf 'event: message\n'
    printf 'data: %s\n' "$(jq -cn --arg t "$MAIN_MALFORMED" '{result: {content: [{type: "text", text: $t}]}, jsonrpc: "2.0", id: 1}')"
  } > "$FM_FAKE_MCP_REPLY"
  stub_reply "$SEARCH_HIT"
  RECALL_RC=0
  RECALL_OUT=$(FM_HOME="$SM_HOME" PATH="$FAKE_BIN:$PATH" bash "$CLI" search --json policy 2>&1) || RECALL_RC=$?
  expect_code 0 "$RECALL_RC" "a malformed main-brain row must not fail this home's own search: $MAIN_MALFORMED"
  [ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = degraded ] \
    || fail "a malformed main-brain row should degrade that source ($MAIN_MALFORMED): $RECALL_OUT"
  assert_not_contains "$RECALL_OUT" "jq:" "a malformed main-brain row must not surface a raw parser error"
done

# The two legs are independent in both directions: a home with no GBrain
# installed has no local index to read and still reaches the shared corpus,
# which needs only curl and a token.
{
  printf 'event: message\n'
  printf 'data: %s\n' "$(jq -cn --arg t "$MAIN_HIT" '{result: {content: [{type: "text", text: $t}]}, jsonrpc: "2.0", id: 1}')"
} > "$FM_FAKE_MCP_REPLY"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" FM_GBRAIN_BIN="$TMP_ROOT/not-installed" PATH="$FAKE_BIN:$PATH" \
  bash "$CLI" search --json policy 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "a missing local GBrain must not cut this home off from the shared corpus: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .schema)" = fm-recall.v1 ] \
  || fail "a missing GBrain must leave the same document behind as every other verdict: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "local") | .state')" = failed ] \
  || fail "the local source must report its own failure: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = ok ] \
  || fail "the main brain must still be read when the local leg cannot run: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[] | select(.source == "main")] | length')" -eq 1 ] \
  || fail "main-brain results must survive a missing local GBrain: $RECALL_OUT"

# A curl config file is line-oriented, so a token carrying a newline stops being
# header text and becomes a DIRECTIVE - an attacker-chosen output path, from a
# token endpoint that is only semi-trusted. Such a token is refused outright.
HOSTILE_TOKEN=$(printf 'abc\noutput = %s/INJECTED\nurl = http://127.0.0.1:9/pwned' "$TMP_ROOT")
stub_reply "$SEARCH_HIT"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" FM_FAKE_TOKEN="$HOSTILE_TOKEN" PATH="$FAKE_BIN:$PATH" \
  bash "$CLI" search --json policy 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "a refused token must not fail this home's own search: $RECALL_OUT"
assert_absent "$TMP_ROOT/INJECTED" "a token must never be able to add a curl directive"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = degraded ] \
  || fail "a refused token should degrade the main source: $RECALL_OUT"
assert_contains "$RECALL_OUT" "refusing to use it" \
  "a token that cannot be passed verbatim must be refused rather than repaired"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[] | select(.source == "local")] | length')" -eq 1 ] \
  || fail "local results must survive a refused token: $RECALL_OUT"
assert_not_contains "$RECALL_OUT" "$TMP_ROOT/INJECTED" \
  "a refused token must not be echoed back into the output"

# The same refusal for the quote that would end the config file's quoted value.
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" FM_FAKE_TOKEN='abc"def' PATH="$FAKE_BIN:$PATH" \
  bash "$CLI" search --json policy 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "a quoted-value break must degrade the main source, not corrupt a header"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "main") | .state')" = degraded ] \
  || fail "a token containing a double quote should be refused: $RECALL_OUT"

# Asked for the main corpus alone, that refusal is the whole run failing.
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" FM_FAKE_TOKEN="$HOSTILE_TOKEN" PATH="$FAKE_BIN:$PATH" \
  bash "$CLI" search --json --scope main policy 2>&1) || RECALL_RC=$?
expect_code 3 "$RECALL_RC" "a refused token on a main-only search must fail the run: $RECALL_OUT"
pass "the main-brain leg reads an SSE answer, an in-band refusal or malformed row degrades that source alone, a missing local GBrain still reaches it, and a token that curl would read as configuration is refused"

# --- 8. caps, flags, and a stable document ----------------------------------

LONG=$(printf 'x%.0s' $(seq 1 900))
stub_reply "$(jq -cn --arg t "$LONG" '[{slug:"long",title:"Long",chunk_text:$t,score:0.5}]')"
run_recall "$MAIN_HOME" search --json --excerpt 100 teardown
EXCERPT_LEN=$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].excerpt | length')
[ "$EXCERPT_LEN" -eq 103 ] \
  || fail "an excerpt should be capped at 100 characters plus an ellipsis, got $EXCERPT_LEN"

stub_reply "$SEARCH_HIT"
run_recall "$MAIN_HOME" search --json --limit 3 teardown
[ "$(sed -n 3p "$FM_STUB_ARGV" | jq -r .limit)" = 3 ] || fail "--limit must reach GBrain"

run_recall "$MAIN_HOME" search --json --limit 500 teardown
expect_code 2 "$RECALL_RC" "a limit past the cap must be refused rather than silently clamped"
run_recall "$MAIN_HOME" search --json --limit 0 teardown
expect_code 2 "$RECALL_RC" "a zero limit must be refused"

# A flag that would do nothing is refused, so nobody believes a cap was applied.
run_recall "$MAIN_HOME" think --json --limit 3 "what does teardown refuse"
expect_code 2 "$RECALL_RC" "--limit is a search flag and must be refused on think"
run_recall "$MAIN_HOME" search --json --max-answer 10 teardown
expect_code 2 "$RECALL_RC" "--max-answer is a think flag and must be refused on search"
run_recall "$MAIN_HOME" search --json --scope sideways teardown
expect_code 2 "$RECALL_RC" "an unknown scope must be refused"

# Every refusal is the same document shape as every success.
[ "$(printf '%s' "$RECALL_OUT" | jq -r .schema)" = fm-recall.v1 ] \
  || fail "a refusal must carry the same schema as a result"
stub_reply "$SEARCH_HIT"
run_recall "$MAIN_HOME" search --json teardown
[ "$(printf '%s' "$RECALL_OUT" | jq -r .schema)" = fm-recall.v1 ] || fail "a result must carry the schema"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].citation')" = local:teardown-notes ] \
  || fail "a result must be citable as <source>:<slug>"
pass "caps are enforced, a flag that would do nothing is refused, and success and refusal share one document shape"

# --- 9. a broken configuration is refused before any brain is touched -------

printf '{"local": {"embedding_base_url": "http://example.com/v1"}}\n' > "$SM_HOME/config/gbrain.json"
run_recall "$SM_HOME" search --json teardown
expect_code 0 "$RECALL_RC" "a plaintext non-loopback local endpoint stays allowed"
printf '{"main_brain": {"mcp_url": "http://example.com/mcp", "scopes": "read"}}\n' > "$SM_HOME/config/gbrain.json"
run_recall "$SM_HOME" search --json teardown
expect_code 2 "$RECALL_RC" "a credential-bearing plaintext endpoint must be refused"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .error.code)" = bad_config ] \
  || fail "a bad shared plane should be reported as bad_config: $RECALL_OUT"
printf '{"main_brain": {"scopes": "write"}}\n' > "$SM_HOME/config/gbrain.json"
run_recall "$SM_HOME" search --json teardown
expect_code 2 "$RECALL_RC" "a home configured to ask for write on another brain must be refused"
# A home reached through a symlink must still match its own FM_CONFIG_OVERRIDE.
# Resolving the symlink here would change the home's spelling, silently stop the
# override applying, and read a different configuration than the operator set -
# which matters on any host whose temp directory is itself a symlink.
LINK_REAL="$TMP_ROOT/linked-home"
LINK_CONF="$TMP_ROOT/linked-config"
mkdir -p "$LINK_REAL/data" "$LINK_CONF"
ln -sfn "$LINK_REAL" "$TMP_ROOT/home-link"
printf '{"main_brain": {"scopes": "write"}}\n' > "$LINK_CONF/gbrain.json"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$TMP_ROOT/home-link" FM_CONFIG_OVERRIDE="$LINK_CONF" \
  bash "$CLI" search --json teardown 2>&1) || RECALL_RC=$?
expect_code 2 "$RECALL_RC" "the override's configuration must be the one that is read"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .error.code)" = bad_config ] \
  || fail "a symlinked home must still consult its own config override: $RECALL_OUT"
pass "a refused configuration stops the read instead of being worked around"

echo "all fm-recall tests passed"
