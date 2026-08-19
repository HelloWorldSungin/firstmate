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
# A main brain that answers slowly, on the call that reads it rather than on the
# token mint. This is the only way to spend real wall clock inside a run without
# a network or a server, and the run's time budget is a behavior that needs it.
[ "${FM_FAKE_CURL_SLEEP:-0}" = 0 ] || sleep "$FM_FAKE_CURL_SLEEP"
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

# --- 10. a search that never started is not a search that found nothing -----
#
# The dashboard runs this command under a hardened service unit whose whole
# filesystem is read-only, and mktemp is the first thing to fail there. Exit 3
# already means "every requested corpus was asked and none answered", which a
# panel is entitled to render as a statement about the brain. A setup failure
# is a different fact - no corpus was ever asked - and rendering it as exit 3
# sends the operator to inspect a brain that was never consulted.
#
# TMPDIR is the lever here because the script passes it to mktemp explicitly
# rather than leaning on a fallback: bash silently falls back to /tmp when
# TMPDIR is unusable, so a test that only set TMPDIR for bash's own here-strings
# would pass no matter which way the code went.
stub_reply "$SEARCH_HIT"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$MAIN_HOME" TMPDIR="$TMP_ROOT/no-such-scratch-dir" \
  bash "$CLI" search --json --scope local teardown 2>&1) || RECALL_RC=$?
expect_code 5 "$RECALL_RC" "a search that could not create its working files needs its own exit status"
[ "$RECALL_RC" -ne 3 ] \
  || fail "a setup failure must not share the exit status that means the corpora were read"
assert_contains "$RECALL_OUT" "never asked" \
  "the setup failure must say the corpus was never consulted: $RECALL_OUT"

# The distinction only exists if the other side still holds: with scratch space
# available, a corpus that was genuinely asked and could not answer stays exit 3
# rather than being swept into the new status.
stub_fail 1 "No brain configured. Run: gbrain init"
run_recall "$MAIN_HOME" search --json --scope local teardown
expect_code 3 "$RECALL_RC" "a corpus that was asked and failed must still be a retrieval failure"

# And an empty result set from a corpus that WAS read is still exit 0, which is
# the distinction the whole exit contract exists to protect.
stub_reply '[]'
run_recall "$MAIN_HOME" search --json --scope local teardown
expect_code 0 "$RECALL_RC" "a corpus that was read and had no match is not a failure"
pass "a search that never started, one that was refused, and one that found nothing each have their own exit status"

# --- 11. the answer protocol: nearest pages, provenance, live source wins ----
#
# The engine returns rows for queries whose topic is absent, and the score
# cannot separate a hit from nonsense, so a threshold would lie. Rows are
# presented as nearest pages, never as answers, and a miss is absence of a
# match rather than absence of the thing. A served page carries its capture
# date and the live source's state, so a voided or superseded finding cannot
# be read as current. Where the live source disagrees, that disagreement is
# named and the live source wins; the page is not dropped or rewritten.

# shellcheck source=bin/fm-gbrain-capture-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-gbrain-capture-lib.sh"

write_outbox() {  # <home> <kind> <id> <captured_at-or-empty> <body> [<redactions-json>]
  local home=$1 kind=$2 id=$3 captured=$4 body=$5 redactions=${6:-[]}
  local tag doc_id slug
  tag=$(fm_gbrain_capture_home_tag "$home")
  doc_id=$(fm_gbrain_capture_document_id "$tag" "$kind" "$id")
  slug=$(fm_gbrain_capture_slug "$tag" "$kind" "$id")
  mkdir -p "$home/data/gbrain-outbox"
  jq -n \
    --arg schema "$FM_GBRAIN_CAPTURE_SCHEMA" \
    --arg document_id "$doc_id" \
    --arg slug "$slug" \
    --arg home "$home" \
    --arg kind "$kind" \
    --arg id "$id" \
    --arg captured "$captured" \
    --arg body "$body" \
    --argjson redactions "$redactions" \
    '{
      schema: $schema,
      document_id: $document_id,
      revision_id: "rev-aaaaaaaaaaaaaaaa",
      slug: $slug,
      home: $home,
      source: {kind: $kind, id: $id, title: $id},
      content_version: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      status: "captured",
      attempts: 1,
      last_error: null,
      gbrain_document: $slug,
      redactions: $redactions,
      created_at: "2026-08-11T20:00:00Z",
      updated_at: "2026-08-11T20:00:00Z",
      captured_at: (if $captured == "" then null else $captured end),
      body: $body
    }' > "$home/data/gbrain-outbox/${doc_id}.json"
  printf '%s\n' "$slug"
}

stub_reply '[]'
run_recall "$MAIN_HOME" search --json --scope local "a topic this brain has never captured"
expect_code 0 "$RECALL_RC" "a read corpus with no rows is still a successful read"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .answer.kind)" = none ] \
  || fail "zero rows from a read corpus must be framed as none, not as an answer: $RECALL_OUT"
assert_contains "$RECALL_OUT" "absence of a match" \
  "a miss must be named as absence of a match"
assert_not_contains "$RECALL_OUT" "does not exist" \
  "a miss must not be readable as absence of the queried thing"
assert_not_contains "$RECALL_OUT" "no such thing" \
  "a miss must not be readable as a negative about the world"

stub_fail 1 "No brain configured. Run: gbrain init"
run_recall "$MAIN_HOME" search --json --scope local teardown
expect_code 3 "$RECALL_RC" "a home with no readable brain is still a retrieval failure"
[ "$(printf '%s' "$RECALL_OUT" | jq -r 'has("answer")')" = false ] \
  || fail "a corpus that was never read must not carry an answer framing: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "local") | .state')" = failed ] \
  || fail "a missing brain must still fail as local retrieval: $RECALL_OUT"

DRIFT_ID=ratchet-side-effects
DRIFT_SLUG=$(write_outbox "$MAIN_HOME" task "$DRIFT_ID" "2026-08-11T20:39:46Z" \
  "AGS has a code-proven zero-Value problem that becomes long intervals.")
mkdir -p "$MAIN_HOME/data/$DRIFT_ID"
printf '%s\n' \
  "AGS has a code-proven zero-Value problem that becomes long intervals." \
  "" \
  "Finding 5 is void. Ratcheting does not apply to AGS." \
  > "$MAIN_HOME/data/$DRIFT_ID/report.md"
touch -d '2026-08-11T21:25:41Z' "$MAIN_HOME/data/$DRIFT_ID/report.md"
stub_reply "$(jq -cn --arg s "$DRIFT_SLUG" \
  '[{slug:$s, title:"BZ-SIM ratchet side effects", chunk_text:"AGS has a code-proven zero-Value problem", score:0.49, stale:false}]')"
run_recall "$MAIN_HOME" search --json --scope local "Does the BZ-SIM ratchet feature apply to AGS?"
expect_code 0 "$RECALL_RC" "a drifted page should still be returned: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r .answer.kind)" = nearest ] \
  || fail "returned rows must be framed as nearest pages: $RECALL_OUT"
assert_contains "$RECALL_OUT" "not answers" \
  "nearest pages must not be readable as answers"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = drifted ] \
  || fail "a live report that moved on after capture must be drifted: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].captured_at')" = "2026-08-11T20:39:46Z" ] \
  || fail "a served page must carry its capture date: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].stale')" = true ] \
  || fail "a drifted page must not be presentable as current: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_updated_at')" = "2026-08-11T21:25:41Z" ] \
  || fail "a drifted page must name the live source's time: $RECALL_OUT"
run_recall "$MAIN_HOME" search --scope local "Does the BZ-SIM ratchet feature apply to AGS?"
assert_contains "$RECALL_OUT" "live source wins" \
  "human output must say the live source wins when it disagrees"
assert_contains "$RECALL_OUT" "(stale)" \
  "human output must mark the voided finding stale"

CURRENT_ID=ohlcv-reenable
CURRENT_SLUG=$(write_outbox "$MAIN_HOME" task "$CURRENT_ID" "2026-08-11T19:42:31Z" \
  "OHLCV service active+enabled on CT100, listening 8812, healthy.")
mkdir -p "$MAIN_HOME/data/$CURRENT_ID"
printf '%s\n' "OHLCV service active+enabled on CT100, listening 8812, healthy." \
  > "$MAIN_HOME/data/$CURRENT_ID/report.md"
touch -d '2026-08-11T19:40:41Z' "$MAIN_HOME/data/$CURRENT_ID/report.md"
STALE_ID=ohlcv-deploy-fix
STALE_SLUG=$(write_outbox "$MAIN_HOME" task "$STALE_ID" "2026-08-11T17:45:52Z" \
  "The OHLCV service remains inactive and disabled.")
mkdir -p "$MAIN_HOME/data/$STALE_ID"
printf '%s\n' \
  "The OHLCV service remains inactive and disabled." \
  "" \
  "Re-enable completed; service is active and enabled." \
  > "$MAIN_HOME/data/$STALE_ID/report.md"
touch -d '2026-08-11T19:40:13Z' "$MAIN_HOME/data/$STALE_ID/report.md"
stub_reply "$(jq -cn --arg a "$CURRENT_SLUG" --arg b "$STALE_SLUG" \
  '[{slug:$a, title:"Re-enable OHLCV", chunk_text:"OHLCV service active+enabled", score:0.64, stale:false},
    {slug:$b, title:"Deploy OHLCV fix", chunk_text:"The OHLCV service remains inactive", score:0.65, stale:false}]')"
run_recall "$MAIN_HOME" search --json --scope local "What is the current state of the OHLCV service on CT100?"
expect_code 0 "$RECALL_RC" "active and stale pages should both be returned: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[].slug] | join(",")')" = "$CURRENT_SLUG,$STALE_SLUG" ] \
  || fail "provenance must not reorder rows: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = current ] \
  || fail "the matching live source must read as current: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[1].source_state')" = drifted ] \
  || fail "the superseded live source must read as drifted: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].stale')" = false ] \
  || fail "a current page must not inherit the sibling's stale mark: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[1].stale')" = true ] \
  || fail "the reader must be able to tell the stale OHLCV page from the current one: $RECALL_OUT"

MISSING_ID=torn-down-task
MISSING_SLUG=$(write_outbox "$MAIN_HOME" task "$MISSING_ID" "2026-08-11T12:00:00Z" "a captured body")
stub_reply "$(jq -cn --arg s "$MISSING_SLUG" \
  '[{slug:$s, title:"gone", chunk_text:"a captured body", score:0.4, stale:false}]')"
run_recall "$MAIN_HOME" search --json --scope local missing-source
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = missing ] \
  || fail "an outbox whose live files are gone must read as missing: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].stale')" = true ] \
  || fail "a missing source must not be presentable as current: $RECALL_OUT"

NOTE_ID=pruned-learning
NOTE_SLUG=$(write_outbox "$MAIN_HOME" note "$NOTE_ID" "2026-08-11T18:00:00Z" "a pruned learning")
stub_reply "$(jq -cn --arg s "$NOTE_SLUG" \
  '[{slug:$s, title:"note", chunk_text:"a pruned learning", score:0.5, stale:false}]')"
run_recall "$MAIN_HOME" search --json --scope local pruned-learning
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = snapshot ] \
  || fail "a note has no live file and must read as a snapshot: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].stale')" = false ] \
  || fail "a snapshot note is not itself a drifted source: $RECALL_OUT"

stub_reply "$SEARCH_HIT"
run_recall "$MAIN_HOME" search --json --scope local teardown
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = unknown ] \
  || fail "a slug with no outbox must be unknown rather than guessed current: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.answer.kind')" = nearest ] \
  || fail "unjudged rows are still nearest pages: $RECALL_OUT"
pass "answer protocol: a miss is not a negative, a served page carries provenance, and a live-source disagreement is surfaced without reordering"

# --- 12. drift is only claimed when the two sides are actually comparable ----
#
# The stored body is not a verbatim copy of the report. Capture composes
# frontmatter in front of it, truncates the composed document at
# FM_GBRAIN_CAPTURE_MAX_BYTES, and rewrites credential-shaped values before any
# byte reaches disk. A page whose live report never changed must not be marked
# drifted - and so read as stale, with the live source winning - because the
# tail it is compared against was cut or rewritten by capture itself.

# A report whose tail carries a multi-byte character positioned so that a
# 200-BYTE cut lands inside it. The orphaned continuation bytes decode to
# U+FFFD, which matches nothing in a body that was stored intact, so a
# byte-sized fingerprint reports an untouched page as drifted. The capture date
# is after the report's mtime here, so the mtime rule cannot mask the result:
# whatever this row says about drift is the content check's own verdict.
UTF8_ID=utf8-tail-report
UTF8_BODY="$(printf 'x%.0s' $(seq 1 300))→$(printf 'y%.0s' $(seq 1 197))"
UTF8_SLUG=$(write_outbox "$MAIN_HOME" task "$UTF8_ID" "2026-08-11T20:00:00Z" "$UTF8_BODY")
mkdir -p "$MAIN_HOME/data/$UTF8_ID"
printf '%s\n' "$UTF8_BODY" > "$MAIN_HOME/data/$UTF8_ID/report.md"
touch -d '2026-08-11T19:00:00Z' "$MAIN_HOME/data/$UTF8_ID/report.md"
stub_reply "$(jq -cn --arg s "$UTF8_SLUG" \
  '[{slug:$s, title:"utf8 tail", chunk_text:"x", score:0.5, stale:false}]')"
run_recall "$MAIN_HOME" search --json --scope local utf8-tail
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = current ] \
  || fail "an unchanged report whose tail splits a multi-byte character must not read as drifted: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].stale')" = false ] \
  || fail "a false drift must not be escalated to stale: $RECALL_OUT"

# A body that capture truncated cannot hold the report's tail at all. The tail
# is genuinely absent, and that absence is capture's doing, not the report's, so
# the mtime rule decides alone. FM_GBRAIN_CAPTURE_MAX_BYTES is the same knob
# capture reads, which is what makes the ceiling testable without a 64 KiB file.
TRUNC_ID=truncated-capture
TRUNC_REPORT="$(printf 'a%.0s' $(seq 1 900))ENDOFREPORT"
TRUNC_SLUG=$(write_outbox "$MAIN_HOME" task "$TRUNC_ID" "2026-08-11T20:00:00Z" \
  "$(printf 'a%.0s' $(seq 1 512))")
mkdir -p "$MAIN_HOME/data/$TRUNC_ID"
printf '%s\n' "$TRUNC_REPORT" > "$MAIN_HOME/data/$TRUNC_ID/report.md"
touch -d '2026-08-11T19:00:00Z' "$MAIN_HOME/data/$TRUNC_ID/report.md"
stub_reply "$(jq -cn --arg s "$TRUNC_SLUG" \
  '[{slug:$s, title:"truncated", chunk_text:"a", score:0.5, stale:false}]')"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$MAIN_HOME" FM_GBRAIN_CAPTURE_MAX_BYTES=512 \
  bash "$CLI" search --json --scope local truncated 2>&1) || RECALL_RC=$?
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = current ] \
  || fail "a body capture truncated cannot disprove the report it was cut from: $RECALL_OUT"

# The same body, now judged against the default ceiling it is nowhere near, has
# no truncation to excuse the missing tail. The content check must still vote,
# or this whole mechanism would have been disabled rather than made honest.
run_recall "$MAIN_HOME" search --json --scope local truncated
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = drifted ] \
  || fail "a body that is comparable and does not match must still read as drifted: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].stale')" = true ] \
  || fail "a real drift must still be stale: $RECALL_OUT"

# Redaction rewrites the body before it is stored, so a tail that no longer
# matches may be the redactor's edit rather than the report's. A record that
# names redactions cannot be used to claim drift.
REDACT_ID="redacted-capture"
REDACT_SLUG=$(write_outbox "$MAIN_HOME" task "$REDACT_ID" "2026-08-11T20:00:00Z" \
  "The deploy key is [redacted:openai-key] and the service came up clean." \
  '[{"class":"openai-key","count":1}]')
mkdir -p "$MAIN_HOME/data/$REDACT_ID"
printf '%s\n' "The deploy key is sk-liveliveliveliveliveliveliveliveli and the service came up clean." \
  > "$MAIN_HOME/data/$REDACT_ID/report.md"
touch -d '2026-08-11T19:00:00Z' "$MAIN_HOME/data/$REDACT_ID/report.md"
stub_reply "$(jq -cn --arg s "$REDACT_SLUG" \
  '[{slug:$s, title:"redacted", chunk_text:"deploy key", score:0.5, stale:false}]')"
run_recall "$MAIN_HOME" search --json --scope local redacted
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = current ] \
  || fail "a redacted body cannot be read as evidence that the report drifted: $RECALL_OUT"

# The mtime rule on its own. The report's tail is byte-identical to the stored
# body, so the content check votes "match" and cannot be what decides this row -
# only the capture time compared against the live mtime can. That comparison
# runs through recall_iso_epoch, whose two date dialects disagree about what -d
# means, and a build that answers it with the current time instead of failing
# would make every capture look newer than every report and retire drift
# detection entirely on that platform.
MTIME_ID="edited-mid-report"
MTIME_BODY="The deploy is green and the runbook stands."
MTIME_SLUG=$(write_outbox "$MAIN_HOME" task "$MTIME_ID" "2026-08-11T20:00:00Z" "$MTIME_BODY")
mkdir -p "$MAIN_HOME/data/$MTIME_ID"
printf '%s\n' "$MTIME_BODY" > "$MAIN_HOME/data/$MTIME_ID/report.md"
touch -d '2026-08-11T21:30:00Z' "$MAIN_HOME/data/$MTIME_ID/report.md"
stub_reply "$(jq -cn --arg s "$MTIME_SLUG" \
  '[{slug:$s, title:"edited", chunk_text:"deploy is green", score:0.5, stale:false}]')"
run_recall "$MAIN_HOME" search --json --scope local edited-mid-report
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = drifted ] \
  || fail "a report edited after capture must be drifted on the mtime rule alone: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].stale')" = true ] \
  || fail "a page whose live source moved on after capture must not read as current: $RECALL_OUT"

# A task with no report on disk has nothing to compare against: its only live
# file is the manifest capture itself rewrites, which is deliberately not read
# as a freshness signal. Reporting that as current would be a confident
# positive with nothing behind it, so it is uncompared - which reads with
# unknown, never with a clean bill of health.
OUTCOME_ID="outcome-only-task"
OUTCOME_SLUG=$(write_outbox "$MAIN_HOME" task "$OUTCOME_ID" "2026-08-11T20:00:00Z" "an outcome with no report")
mkdir -p "$MAIN_HOME/data/$OUTCOME_ID"
jq -n '{schema: "fm-outcome-manifest.v1", outcome: {state: "done"}}' \
  > "$MAIN_HOME/data/$OUTCOME_ID/outcome.json"
stub_reply "$(jq -cn --arg s "$OUTCOME_SLUG" \
  '[{slug:$s, title:"outcome only", chunk_text:"an outcome", score:0.5, stale:false}]')"
run_recall "$MAIN_HOME" search --json --scope local outcome-only
expect_code 0 "$RECALL_RC" "a page nothing could be compared against is still returned: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = uncompared ] \
  || fail "an outcome-only task compares nothing and must say so: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" != current ] \
  || fail "a page that compared nothing must never be reported as current: $RECALL_OUT"
run_recall "$MAIN_HOME" search --scope local outcome-only
assert_contains "$RECALL_OUT" "source=uncompared" \
  "a reader must see that nothing was compared rather than a silent clean state"
assert_not_contains "$RECALL_OUT" "source=current" \
  "the human line must not absorb an uncompared page into current"

# The second way a comparison cannot happen: capture truncated the body, so the
# report's tail is legitimately absent, and the record carries no capture time
# for the mtime rule to fall back on. Neither check ran, so neither may be
# reported as having agreed.
UNCOMP_ID="truncated-and-uncaptured"
UNCOMP_SLUG=$(write_outbox "$MAIN_HOME" task "$UNCOMP_ID" "" "$(printf 'b%.0s' $(seq 1 512))")
mkdir -p "$MAIN_HOME/data/$UNCOMP_ID"
printf '%s\n' "$(printf 'b%.0s' $(seq 1 900))TAILNOTINBODY" \
  > "$MAIN_HOME/data/$UNCOMP_ID/report.md"
touch -d '2026-08-11T19:00:00Z' "$MAIN_HOME/data/$UNCOMP_ID/report.md"
stub_reply "$(jq -cn --arg s "$UNCOMP_SLUG" \
  '[{slug:$s, title:"pending capture", chunk_text:"b", score:0.5, stale:false}]')"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$MAIN_HOME" FM_GBRAIN_CAPTURE_MAX_BYTES=512 \
  bash "$CLI" search --json --scope local truncated-and-uncaptured 2>&1) || RECALL_RC=$?
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = uncompared ] \
  || fail "a truncated body with no capture time compared nothing and must say so: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" != current ] \
  || fail "a row where neither check ran must never be reported as current: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].captured_at')" = null ] \
  || fail "the uncompared fixture must be the null-capture case it claims to be: $RECALL_OUT"

# A slug whose home tag cannot form a valid document id addresses no record in
# this outbox, so it is unjudgeable rather than a task this home owns: reporting
# a source kind and id for it would claim an identity nothing validated.
stub_reply "$(jq -cn '[{slug:"firstmate/a b/task/some-task", title:"bad tag", chunk_text:"x", score:0.4, stale:false}]')"
run_recall "$MAIN_HOME" search --json --scope local bad-tag
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = unknown ] \
  || fail "a slug with an unaddressable home tag must be unknown: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_kind')" = null ] \
  || fail "a slug that failed the address checks must not be credited with a source kind: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_id')" = null ] \
  || fail "a slug that failed the address checks must not be credited with a source id: $RECALL_OUT"
pass "drift is claimed only from a comparable body: truncation, redaction, and a split character are not evidence"

# --- 13. the human surface tells a miss apart from an unread corpus ----------
#
# stdout is what a reader actually sees, and neither of these two states may
# read as "the thing does not exist" and neither may be silence. They are
# checked on stdout ALONE, separated from stderr, because the defect this pins
# was exactly stdout contradicting stderr: a reader piping stdout was told a
# negative while stderr said the opposite.

run_recall_split() {  # <home> <args...> -> RECALL_STDOUT / RECALL_STDERR / RECALL_RC
  local home=$1
  shift
  local errfile
  errfile=$(mktemp "$TMP_ROOT/stderr.XXXXXX")
  RECALL_RC=0
  RECALL_STDOUT=$(FM_HOME="$home" bash "$CLI" "$@" 2>"$errfile") || RECALL_RC=$?
  RECALL_STDERR=$(cat "$errfile")
  rm -f "$errfile"
}

# A home with no brain installed: the corpus was never read, so nothing here is
# a statement about what the brain holds.
FM_GBRAIN_BIN="$TMP_ROOT/no-such-gbrain-anywhere" \
  run_recall_split "$MAIN_HOME" search --scope local "does the OHLCV service run on CT100"
expect_code 3 "$RECALL_RC" "a corpus that could not be read is still a retrieval failure"
assert_contains "$RECALL_STDOUT" "not searched" \
  "stdout must say the corpus was never searched: $RECALL_STDOUT"
assert_contains "$RECALL_STDOUT" "says nothing about whether it exists" \
  "stdout must refuse to turn an unread corpus into a statement about the world"
assert_not_contains "$RECALL_STDOUT" "no results" \
  "an unread corpus must not be rendered as an empty result set"
assert_not_contains "$RECALL_STDOUT" "no match in this brain" \
  "an unread corpus must not be rendered as a miss"
assert_contains "$RECALL_STDERR" "not an empty result set" \
  "stderr must name the same fact stdout does: $RECALL_STDERR"
assert_not_contains "$RECALL_STDERR" "no results" \
  "stderr must not contradict stdout by calling this an empty result set"

# A brain that WAS read and holds no match: a real, successful, empty answer -
# which must be said out loud, and said as a fact about this brain.
stub_reply '[]'
run_recall_split "$MAIN_HOME" search --scope local "a topic this brain has never captured"
expect_code 0 "$RECALL_RC" "a corpus that was read and had no match is not a failure"
assert_contains "$RECALL_STDOUT" "no match in this brain" \
  "a successful miss must be stated, not left as silence: [$RECALL_STDOUT]"
assert_contains "$RECALL_STDOUT" "may simply not hold it" \
  "a miss must be framed as this brain's gap, not the world's"
assert_not_contains "$RECALL_STDOUT" "not searched" \
  "a corpus that was read must not be reported as unsearched"
assert_not_contains "$RECALL_STDOUT" "no results" \
  "a miss must not fall back to the bare empty-result wording"
assert_not_contains "$RECALL_STDERR" "no corpus could be read" \
  "a corpus that answered must not have stderr claim it was never read: $RECALL_STDERR"
pass "human output separates a searched brain with no match from a corpus that was never read, on stdout alone"

# --- 14. provenance spends the run's budget, never the answer ----------------
#
# Provenance is read from the filesystem AFTER both corpora have answered, so it
# is wall clock a caller already budgeted for retrieval. The dashboard sizes its
# kill deadline around the wrapper's own timeout with about a second to spare,
# and a caller that kills the run gets nothing - including the rows that were
# successfully retrieved before the annotation started. Past the deadline the
# rows keep the fail-safe unknown state instead, so a slow read costs
# provenance and never the answer.
#
# The clock is spent by the main brain rather than by a real slow filesystem,
# because that is the only way to spend a deterministic amount of it offline.

jq -n '{version: 1,
        local: {embedding_base_url: "http://127.0.0.1:11434/v1"},
        main_brain: {mcp_url: "http://127.0.0.1:9/mcp", token_url: "http://127.0.0.1:9/token",
                     mount: "fm-main", scopes: "read", secret: "main-brain-client-secret"}}' \
  > "$SM_HOME/config/gbrain.json"
{
  printf 'event: message\n'
  printf 'data: %s\n' "$(jq -cn --arg t '[]' '{result: {content: [{type: "text", text: $t}]}, jsonrpc: "2.0", id: 1}')"
} > "$FM_FAKE_MCP_REPLY"

BUDGET_ID="budgeted-page"
BUDGET_BODY="The provenance pass must not cost the answer."
BUDGET_SLUG=$(write_outbox "$SM_HOME" task "$BUDGET_ID" "2026-08-11T20:00:00Z" "$BUDGET_BODY")
mkdir -p "$SM_HOME/data/$BUDGET_ID"
printf '%s\n' "$BUDGET_BODY" > "$SM_HOME/data/$BUDGET_ID/report.md"
touch -d '2026-08-11T19:00:00Z' "$SM_HOME/data/$BUDGET_ID/report.md"
stub_reply "$(jq -cn --arg s "$BUDGET_SLUG" \
  '[{slug:$s, title:"budgeted", chunk_text:"provenance", score:0.5, stale:false}]')"

# The control: with budget to spare the same row IS judged, so the degradation
# below is the deadline's doing and not a broken annotator.
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" PATH="$FAKE_BIN:$PATH" \
  bash "$CLI" search --json --scope all --timeout 30 budgeted 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "the control search should answer: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = current ] \
  || fail "with budget to spare the row must carry its judged provenance: $RECALL_OUT"

# The same search whose corpora spend the whole RUN budget - `--timeout` once
# per leg this scope reads, which is what the caller actually sanctioned - and
# only then does the provenance degrade, with the answer surviving intact.
# Two legs at 1s each is a 2s ceiling; the main brain spends 3s.
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" PATH="$FAKE_BIN:$PATH" FM_FAKE_CURL_SLEEP=3 \
  bash "$CLI" search --json --scope all --timeout 1 budgeted 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "a run whose corpora spent the budget must still answer: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[] | select(.source == "local")] | length')" -eq 1 ] \
  || fail "a retrieved row must survive a provenance pass that ran out of budget: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = unknown ] \
  || fail "past the deadline a row keeps the fail-safe unknown state: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].captured_at')" = null ] \
  || fail "a row the provenance pass never reached must claim nothing about its capture: $RECALL_OUT"
pass "a provenance pass that runs out of the run's budget degrades to unknown instead of costing the answer"

# --- 15. the named regression survives a cold index --------------------------
#
# The captain-voided BZ-SIM finding is the page this whole task exists to stop
# presenting as current. A brain that takes a few seconds on a cold index is the
# condition the Knowledge view's own hint tells the reader to expect, and it is
# well inside the budget the caller granted retrieval - so the page must still
# arrive carrying its capture date and its drift marker. Sizing the provenance
# pass against ONE leg instead of the run wipes exactly this row to
# unknown/null, which is the failure this pins.
#
# Two legs at 3s each is a 6s ceiling; the main brain spends 4s of it.

BZSIM_ID="bzsim-ratchet-fix-side-effects"
BZSIM_CAPTURED="AGS has a code-proven zero-Value problem that becomes long intervals."
BZSIM_SLUG=$(write_outbox "$SM_HOME" task "$BZSIM_ID" "2026-08-11T20:39:46Z" "$BZSIM_CAPTURED")
mkdir -p "$SM_HOME/data/$BZSIM_ID"
printf '%s\n' "$BZSIM_CAPTURED" "" "Finding 5 is void. Ratcheting does not apply to AGS." \
  > "$SM_HOME/data/$BZSIM_ID/report.md"
touch -d '2026-08-11T21:25:41Z' "$SM_HOME/data/$BZSIM_ID/report.md"
stub_reply "$(jq -cn --arg s "$BZSIM_SLUG" \
  '[{slug:$s, title:"BZ-SIM ratchet side effects", chunk_text:"AGS has a code-proven zero-Value problem", score:0.49, stale:false}]')"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$SM_HOME" PATH="$FAKE_BIN:$PATH" FM_FAKE_CURL_SLEEP=4 \
  bash "$CLI" search --json --scope all --timeout 3 "Does the BZ-SIM ratchet feature apply to AGS?" 2>&1) || RECALL_RC=$?
expect_code 0 "$RECALL_RC" "a slow but budgeted run must still answer: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].source_state')" = drifted ] \
  || fail "a cold index must not cost the voided finding its drift marker: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].stale')" = true ] \
  || fail "the captain-voided finding must still read as not current when the brain was slow: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results[0].captured_at')" = "2026-08-11T20:39:46Z" ] \
  || fail "a slow run must not wipe the served page's capture date: $RECALL_OUT"
pass "the captain-voided BZ-SIM page keeps its capture date and drift marker when retrieval spends most of the run budget"

# --- 16. current is earned: every path that can produce one -------------------
#
# Currency is decided from evidence, and every check answers agree, disagree, or
# "could not run". The property under test is not that particular cases behave -
# it is that `current` has exactly one way in. A check that cannot run must
# contribute nothing, so a path nobody anticipated degrades to "nothing was
# checked" rather than to "this page is fine".
#
# The enumeration below is the whole input space of a provenance verdict, one
# fixture per class, read through a single search. Only the two rows built with
# a comparison that ran AND agreed may come back current.

VERDICT_HOME=$(make_home "$TMP_ROOT/verdict")
VERDICT_TAG=$(fm_gbrain_capture_home_tag "$VERDICT_HOME")
VERDICT_SLUGS=()

# Sets <var> to the fixture's slug and adds it to the row set the search will
# return. It assigns rather than printing because a command substitution would
# run the array append in a subshell and drop it.
verdict_fixture() {  # <var> <id> <captured_at-or-empty> <body> <report|OUTCOME-ONLY|NO-LIVE-FILES> [<mtime>] [<redactions>]
  local into=$1 id=$2 captured=$3 body=$4 report=$5
  local mtime=${6:-2026-08-11T19:00:00Z} redactions=${7:-[]}
  local slug
  slug=$(write_outbox "$VERDICT_HOME" task "$id" "$captured" "$body" "$redactions")
  if [ "$report" != NO-LIVE-FILES ]; then
    mkdir -p "$VERDICT_HOME/data/$id"
    if [ "$report" = OUTCOME-ONLY ]; then
      jq -n '{schema: "fm-outcome-manifest.v1", outcome: {state: "done"}}' \
        > "$VERDICT_HOME/data/$id/outcome.json"
    else
      printf '%s' "$report" > "$VERDICT_HOME/data/$id/report.md"
      touch -d "$mtime" "$VERDICT_HOME/data/$id/report.md"
    fi
  fi
  VERDICT_SLUGS+=("$slug")
  printf -v "$into" '%s' "$slug"
}

verdict_search() {  # <extra-env-assignments...> -> RECALL_OUT with every fixture row
  stub_reply "$(printf '%s\n' ${VERDICT_SLUGS[@]+"${VERDICT_SLUGS[@]}"} \
    | jq -R -s -c 'split("\n") | map(select(length > 0))
        | map({slug: ., title: "row", chunk_text: "x", score: 0.5, stale: false})')"
  RECALL_RC=0
  RECALL_OUT=$(env FM_HOME="$VERDICT_HOME" "$@" bash "$CLI" search --json --scope local everything 2>&1) || RECALL_RC=$?
}

verdict_state() {  # <slug> -> the source_state that slug came back with
  printf '%s' "$RECALL_OUT" | jq -r --arg s "$1" '.results[] | select(.slug == $s) | .source_state'
}

expect_state() {  # <slug> <expected> <why>
  local got
  got=$(verdict_state "$1")
  [ "$got" = "$2" ] || fail "$3: expected $2, got ${got:-<no row>}"
}

# Both checks can run and both agree - the only shape that earns current.
AGREE_BODY="The runbook stands and the deploy is green."
BLANK_REPORT=$(printf '   \n\n   \n')
verdict_fixture EV_BOTH_AGREE ev-both-agree "2026-08-11T20:00:00Z" "$AGREE_BODY" "$AGREE_BODY"
# Only the content check can run, and it agrees: no capture time to compare.
verdict_fixture EV_CONTENT_AGREE ev-content-agree "" "$AGREE_BODY" "$AGREE_BODY"
# Only the mtime check can run, and it agrees: the body was redacted, so the
# missing tail says nothing, but the report predates the capture.
verdict_fixture EV_MTIME_AGREE ev-mtime-agree "2026-08-11T20:00:00Z" \
  "The key is [redacted:openai-key] and nothing else survived." \
  "The key is sk-liveliveliveliveliveliveliveliveli and nothing else survived." \
  "2026-08-11T19:00:00Z" '[{"class":"openai-key","count":1}]'
# The content check ran and disagreed.
verdict_fixture EV_CONTENT_DISAGREE ev-content-disagree "" "A body that is not the report." "$AGREE_BODY"
# The content check agreed and the mtime check disagreed: one disagreement is
# enough, because a live source that disagrees wins.
verdict_fixture EV_MTIME_DISAGREE ev-mtime-disagree "2026-08-11T20:00:00Z" "$AGREE_BODY" "$AGREE_BODY" \
  "2026-08-11T21:30:00Z"
# Neither check can run: a report with no content to fingerprint and no capture
# time to fall back on.
verdict_fixture EV_NO_EVIDENCE ev-no-evidence "" "$AGREE_BODY" "$BLANK_REPORT"
# Neither check can run: the capture time is present but unparseable.
verdict_fixture EV_BAD_CAPTURE ev-bad-capture "not-a-date" "$AGREE_BODY" "$BLANK_REPORT"
# No report to compare, and the only live file is the manifest capture rewrites.
verdict_fixture EV_OUTCOME_ONLY ev-outcome-only "2026-08-11T20:00:00Z" "$AGREE_BODY" OUTCOME-ONLY
# The live files are gone entirely.
verdict_fixture EV_LIVE_GONE ev-live-gone "2026-08-11T20:00:00Z" "$AGREE_BODY" NO-LIVE-FILES
# A note has no live file by construction.
EV_NOTE=$(write_outbox "$VERDICT_HOME" note ev-note "2026-08-11T20:00:00Z" "a pruned learning")
VERDICT_SLUGS+=("$EV_NOTE")
# A slug this home never captured, and a slug whose home tag cannot address a
# record at all.
EV_NO_OUTBOX="firstmate/$VERDICT_TAG/task/ev-never-captured"
VERDICT_SLUGS+=("$EV_NO_OUTBOX")
EV_BAD_TAG="firstmate/a b/task/ev-bad-tag"
VERDICT_SLUGS+=("$EV_BAD_TAG")

verdict_search
expect_code 0 "$RECALL_RC" "the enumeration search should answer: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.results | length')" -eq "${#VERDICT_SLUGS[@]}" ] \
  || fail "the enumeration must read every fixture row: $RECALL_OUT"

expect_state "$EV_BOTH_AGREE" current "two agreeing checks earn current"
expect_state "$EV_CONTENT_AGREE" current "a content check that ran and agreed earns current"
expect_state "$EV_MTIME_AGREE" current "an mtime check that ran and agreed earns current"
expect_state "$EV_CONTENT_DISAGREE" drifted "a content check that ran and disagreed marks drift"
expect_state "$EV_MTIME_DISAGREE" drifted "one disagreeing check outweighs one that agreed"
expect_state "$EV_NO_EVIDENCE" uncompared "no check could run, so nothing was compared"
expect_state "$EV_BAD_CAPTURE" uncompared "an unparseable capture time is not a comparison"
expect_state "$EV_OUTCOME_ONLY" uncompared "an outcome-only task compares nothing"
expect_state "$EV_LIVE_GONE" missing "an outbox whose live files are gone is missing"
expect_state "$EV_NOTE" snapshot "a note has no live file to compare"
expect_state "$EV_NO_OUTBOX" unknown "a slug with no outbox cannot be judged"
expect_state "$EV_BAD_TAG" unknown "a slug that cannot address a record cannot be judged"

# The closure itself: across the whole input space, the rows that came back
# current are EXACTLY the three built with a comparison that ran and agreed. A
# new path that reaches current without evidence fails here even if nobody
# thought to name it.
CURRENT_ROWS=$(printf '%s' "$RECALL_OUT" | jq -r '[.results[] | select(.source_state == "current") | .slug] | sort | join(",")')
EXPECTED_CURRENT=$(printf '%s\n%s\n%s\n' "$EV_BOTH_AGREE" "$EV_CONTENT_AGREE" "$EV_MTIME_AGREE" \
  | sort | tr '\n' ',' | sed 's/,$//')
[ "$CURRENT_ROWS" = "$EXPECTED_CURRENT" ] \
  || fail "current was reached without an agreeing comparison: got [$CURRENT_ROWS], earned [$EXPECTED_CURRENT]"

# The mechanism, stated as a property rather than as a case list: for EVERY way
# a check can fail to run, pairing it with the other check also unable to run
# yields uncompared. None of them contributes a quiet pass.
VERDICT_SLUGS=()
CANNOT_RUN=()
cannot_run_slug=""
for content_way in whitespace-tail empty-file truncated-body redacted-body; do
  for capture_way in absent unparseable; do
    id="cannot-run-$content_way-$capture_way"
    case $capture_way in
      absent) captured="" ;;
      *) captured="not-a-date" ;;
    esac
    case $content_way in
      whitespace-tail) body="$AGREE_BODY"; report="$BLANK_REPORT"; redactions='[]' ;;
      empty-file) body="$AGREE_BODY"; report=""; redactions='[]' ;;
      truncated-body) body=$(printf 'b%.0s' $(seq 1 512)); report="$(printf 'b%.0s' $(seq 1 900))TAILNOTINBODY"; redactions='[]' ;;
      *) body="key [redacted:openai-key] done"; report="key sk-liveliveliveliveliveliveliveliveli done"; redactions='[{"class":"openai-key","count":1}]' ;;
    esac
    verdict_fixture cannot_run_slug "$id" "$captured" "$body" "$report" "2026-08-11T19:00:00Z" "$redactions"
    CANNOT_RUN+=("$cannot_run_slug")
  done
done
verdict_search FM_GBRAIN_CAPTURE_MAX_BYTES=512
expect_code 0 "$RECALL_RC" "the cannot-run search should answer: $RECALL_OUT"
for slug in "${CANNOT_RUN[@]}"; do
  expect_state "$slug" uncompared "a check that could not run must contribute nothing ($slug)"
done
[ "$(printf '%s' "$RECALL_OUT" | jq -r '[.results[] | select(.source_state == "current")] | length')" -eq 0 ] \
  || fail "a check that could not run was counted as a pass: $RECALL_OUT"
pass "current is reachable only through a comparison that ran and agreed; a check that cannot run contributes nothing"

# A budget this command cannot compute with is refused by the retrieval bound
# the way it always was, rather than aborting the run with a raw shell error on
# a status no caller knows how to read.
stub_reply "$SEARCH_HIT"
RECALL_RC=0
RECALL_OUT=$(FM_HOME="$MAIN_HOME" FM_RECALL_TIMEOUT=30s \
  bash "$CLI" search --json --scope local teardown 2>&1) || RECALL_RC=$?
expect_code 3 "$RECALL_RC" "a non-integer retrieval budget must stay a named retrieval failure: $RECALL_OUT"
[ "$(printf '%s' "$RECALL_OUT" | jq -r '.sources[] | select(.source == "local") | .state')" = failed ] \
  || fail "a non-integer budget must be reported as the local leg failing: $RECALL_OUT"
assert_not_contains "$RECALL_OUT" "value too great for base" \
  "a bad budget must not surface as a raw shell arithmetic error"
pass "a retrieval budget that is not a positive integer keeps the documented exit contract"

echo "all fm-recall tests passed"
