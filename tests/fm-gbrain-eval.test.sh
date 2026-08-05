#!/usr/bin/env bash
# Behavior tests for bin/fm-gbrain-eval.sh, the retrieval-quality evaluation
# harness.
#
# Portable: no GBrain installation, no brain, and no network. Two stubs stand in
# for the only external surfaces the harness has - the retrieval wrapper and the
# gbrain executable - so the scoring rules, the provenance the run document
# carries, and the exit statuses are all proven from what the harness produced
# for a known input rather than asserted about its source.
#
# The live proof that the same harness measures a REAL brain is the dated record
# in docs/verification/gbrain-eval.md, which names the commands that refresh it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || { echo "skip: sha256sum not found"; exit 0; }

CLI="$ROOT/bin/fm-gbrain-eval.sh"
TMP_ROOT=$(fm_test_tmproot fm-gbrain-eval)
REPLY_DIR="$TMP_ROOT/replies"
mkdir -p "$REPLY_DIR" "$TMP_ROOT/stub"

# --- stubs ------------------------------------------------------------------
#
# The recall stub answers from a canned document chosen by the first word of the
# query, so one run can exercise a hit, a near miss, and a total miss together.

RECALL_STUB="$TMP_ROOT/stub/fm-recall.sh"
cat > "$RECALL_STUB" <<'RECALLEOF'
#!/usr/bin/env bash
set -u
cmd=$1
shift
query=""
while [ $# -gt 0 ]; do
  case $1 in
    --) shift; query=${1:-}; break ;;
    --home|--scope|--limit|--excerpt|--max-answer|--timeout) shift 2 ;;
    --json) shift ;;
    *) query=$1; shift ;;
  esac
done
key=${query%% *}
printf '%s %s\n' "$cmd" "$key" >> "$FM_STUB_CALLS"
reply="$FM_STUB_REPLIES/$key.$cmd.json"
# A key may declare a per-attempt script: the Nth call answers from .N.
attempt=$(grep -c "^$cmd $key\$" "$FM_STUB_CALLS")
[ -f "$FM_STUB_REPLIES/$key.$cmd.$attempt.json" ] && reply="$FM_STUB_REPLIES/$key.$cmd.$attempt.json"
if [ ! -f "$reply" ]; then
  echo "no canned reply for $cmd $key" >&2
  exit 3
fi
rc=0
[ -f "$reply.rc" ] && rc=$(cat "$reply.rc")
cat "$reply"
exit "$rc"
RECALLEOF
chmod 0755 "$RECALL_STUB"

GBRAIN_STUB="$TMP_ROOT/stub/gbrain"
cat > "$GBRAIN_STUB" <<'GBRAINEOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  version) echo "gbrain 9.9.9-test" ;;
  stats)
    printf 'Pages:     %s\nChunks:    %s\nEmbedded:  %s\n' \
      "${FM_STUB_PAGES:-3}" "${FM_STUB_CHUNKS:-9}" "${FM_STUB_EMBEDDED:-9}" ;;
  config)
    case "${3:-}" in
      search.reranker.enabled)
        # An unreadable key is how the real brain answers once reinit-pglite has
        # wiped its database plane: the complaint goes to stderr and the read
        # fails, so the harness gets nothing rather than a value.
        [ "${FM_STUB_RERANK:-true}" = "unreadable" ] && {
          echo "Config key not found: ${3:-}" >&2; exit 1; }
        echo "${FM_STUB_RERANK:-true}" ;;
      search.reranker.model) echo "test-reranker:v1" ;;
      models.think) echo "test-think:v1" ;;
      *) echo "Config key not found: ${3:-}" ;;
    esac
    echo "[config] source: db plane" ;;
  *) exit 1 ;;
esac
GBRAINEOF
chmod 0755 "$GBRAIN_STUB"

export FM_STUB_CALLS="$TMP_ROOT/calls.txt"
export FM_STUB_REPLIES="$REPLY_DIR"
export FM_RECALL_BIN="$RECALL_STUB"
export FM_GBRAIN_BIN="$GBRAIN_STUB"
: > "$FM_STUB_CALLS"

# --- fixtures ---------------------------------------------------------------

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data/gbrain/runtime/.gbrain" \
  "$HOME_DIR/data/gbrain/pglite" "$HOME_DIR/data/gbrain-outbox"
jq -n '{version: 1,
        local: {embedding_base_url: "http://127.0.0.1:11434/v1",
                reranker_base_url: "http://127.0.0.1:8081/v1"},
        think: {base_url: "https://example.invalid/v1", model: "test-think:v1", secret: "test"}}' \
  > "$HOME_DIR/config/gbrain.json"
jq -n '{engine: "pglite", embedding_model: "test-embed:v1", embedding_dimensions: 512,
        schema_pack: "test-pack"}' \
  > "$HOME_DIR/data/gbrain/runtime/.gbrain/config.json"

write_outbox() {  # <content-version>
  jq -n --arg v "$1" '{document_id: "v1.test.task.alpha", content_version: $v}' \
    > "$HOME_DIR/data/gbrain-outbox/alpha.json"
}
write_outbox sha256:aaa

search_doc() {  # <slug...> -> an fm-recall.v1 search document in that order
  local slugs=()
  local s
  for s in "$@"; do slugs+=("$s"); done
  printf '%s\n' "${slugs[@]}" | jq -R . | jq -s '
    {schema: "fm-recall.v1", command: "search", home: "x", query: "q",
     sources: [{source: "local", state: "ok", brain: "b", results: length}],
     results: [to_entries[] | {source: "local",
                               citation: ("local:" + .value),
                               slug: .value,
                               title: .value,
                               score: (1 - (.key / 100))}]}'
}

think_doc() {  # <state> <answer> <citation-slug...>
  local state=$1 answer=$2
  shift 2
  printf '%s\n' ${1+"$@"} | jq -R . | jq -s --arg st "$state" --arg a "$answer" '
    {schema: "fm-recall.v1", command: "think", home: "x", question: "q",
     sources: [{source: "local", state: "ok", brain: "b", results: 1}],
     synthesis: {state: $st, model: "test-think:v1", warnings: [], truncated: false, answer: $a},
     citations: [.[] | select(. != "") | "local:" + .]}'
}

local_read_failure() {  # -> the document fm-recall.sh emits when the brain fails
  jq -n '{schema: "fm-recall.v1", command: "think",
          error: {code: "local_retrieval_failed", message: "the brain could not be read"}}'
}

EVAL_SET="$TMP_ROOT/set.json"
write_set() {  # <jq-filter-applied-to-the-base-set>
  jq "${1:-.}" > "$EVAL_SET" <<'SETEOF'
{
  "schema": "fm-gbrain-eval-set.v1",
  "id": "unit",
  "version": 1,
  "query": {"scope": "local", "limit": 4, "top_k": 3, "excerpt": 100, "think_max_answer": 500},
  "thresholds": {"search_top1": 0.5, "search_topk": 0.7, "think_answered": 0.5,
                 "think_grounded": 0.5, "think_key_facts": 0.5},
  "questions": [
    {"id": "qa", "question": "qa first result is right",
     "expect": ["task/alpha"], "key_facts": [["alpha", "ALPHA"], ["wedge"]]},
    {"id": "qb", "question": "qb right answer is third",
     "expect": ["task/beta"], "key_facts": [["beta"]]},
    {"id": "qc", "question": "qc not retrieved at all",
     "expect": ["task/gamma"], "key_facts": [["gamma"]]},
    {"id": "qd", "question": "qd either of two sources is correct",
     "expect": ["task/delta", "task/epsilon"], "key_facts": [["delta"]]}
  ]
}
SETEOF
}
write_set

# qa: expected slug first, and the expectation is a SUFFIX of the real slug.
search_doc "home/tag/task/alpha" "home/tag/task/zulu" > "$REPLY_DIR/qa.search.json"
# qb: expected slug third - inside top_k=3 but not top-1, so rr = 1/3.
search_doc "home/tag/task/zulu" "home/tag/task/yankee" "home/tag/task/beta" \
  > "$REPLY_DIR/qb.search.json"
# qc: nothing expected came back at all.
search_doc "home/tag/task/zulu" "home/tag/task/yankee" > "$REPLY_DIR/qc.search.json"
# qd: the second of two accepted sources is first, which still counts.
search_doc "home/tag/task/epsilon" "home/tag/task/zulu" > "$REPLY_DIR/qd.search.json"

run_eval() {  # <args...> -> EVAL_OUT / EVAL_RC
  EVAL_OUT=""
  EVAL_RC=0
  EVAL_OUT=$(bash "$CLI" "$@" 2>"$TMP_ROOT/err.txt") || EVAL_RC=$?
}

# --- 1. validate ------------------------------------------------------------

run_eval validate --set "$ROOT/docs/gbrain-eval-set.v1.json"
expect_code 0 "$EVAL_RC" "the shipped evaluation set must validate"
assert_contains "$EVAL_OUT" "fleet-history" "validate should name the set it read"

reject() {  # <jq-filter> <what>
  write_set "$1"
  run_eval validate --set "$EVAL_SET"
  expect_code 2 "$EVAL_RC" "$2"
  write_set
}
reject '.schema = "something-else"' "a foreign schema must be refused"
reject '.questions[1].id = "qa"' "duplicate question ids must be refused"
reject '.questions[0].expect = []' "a question with no expectation must be refused"
reject '.query.top_k = 99' "a top_k larger than the retrieved limit must be refused"
reject '.questions[0].key_facts = [[]]' "an empty key-fact alternative list must be refused"
reject 'del(.thresholds)' "a set with no thresholds must be refused"

# --- 2. search scoring ------------------------------------------------------

run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json
expect_code 0 "$EVAL_RC" "a search run whose thresholds are met should exit 0"
S=$(printf '%s' "$EVAL_OUT" | jq -c '.search')
[ "$(printf '%s' "$S" | jq -r '.top1')" = "0.5" ] \
  || fail "top-1 should be 2 of 4 (qa and qd), got $S"
[ "$(printf '%s' "$S" | jq -r '.topk')" = "0.75" ] \
  || fail "top-k should be 3 of 4 - qb is inside k=3, qc missed entirely - got $S"
MRR=$(printf '%s' "$S" | jq -r '(.mrr * 1000 | round)')
[ "$MRR" = "583" ] || fail "MRR should be (1 + 1/3 + 0 + 1)/4 = 0.583, got $MRR"
[ "$(printf '%s' "$S" | jq -c '.missed')" = '["qc"]' ] \
  || fail "only qc retrieved nothing expected, got $S"
[ "$(printf '%s' "$S" | jq -c '.below_top1')" = '[{"id":"qb","rank":3}]' ] \
  || fail "qb should be reported at rank 3, got $S"

# A recall failure is a corpus that was not read, never a scored miss: it must
# not be silently averaged in as a zero.
cp "$REPLY_DIR/qc.search.json" "$TMP_ROOT/qc.keep"
printf '3\n' > "$REPLY_DIR/qc.search.json.rc"
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.search.read')" = "3" ] \
  || fail "a failed retrieval must be counted as not read"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.search.questions')" = "4" ] \
  || fail "a failed retrieval must still be counted as a question"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '(.search.top1 * 100 | round)')" = "67" ] \
  || fail "rates must be over the questions actually read, got $EVAL_OUT"

# A run where NO question could be read measured nothing, and must not report a
# pass just because every averaged metric came out null.
for k in qa qb qc qd; do printf '3\n' > "$REPLY_DIR/$k.search.json.rc"; done
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json
expect_code 3 "$EVAL_RC" "a run that read no corpus at all must not exit 0"
for k in qa qb qc qd; do rm -f "$REPLY_DIR/$k.search.json.rc"; done
rm -f "$REPLY_DIR/qc.search.json.rc"

# --- 3. provenance travels with the numbers ---------------------------------

run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json --label "run one"
C=$(printf '%s' "$EVAL_OUT" | jq -c '.configuration')
[ "$(printf '%s' "$C" | jq -r '.gbrain_version')" = "9.9.9-test" ] \
  || fail "the GBrain version must be recorded, got $C"
[ "$(printf '%s' "$C" | jq -r '.embedding.model')" = "test-embed:v1" ] \
  || fail "the embedding model must be recorded, got $C"
[ "$(printf '%s' "$C" | jq -r '.embedding.dimensions')" = "512" ] \
  || fail "the embedding dimension must be recorded, got $C"
[ "$(printf '%s' "$C" | jq -r '.reranker.enabled')" = "true" ] \
  || fail "the reranker state must be recorded from the brain, got $C"
[ "$(printf '%s' "$C" | jq -r '.reranker.model')" = "test-reranker:v1" ] \
  || fail "the reranker model must be recorded, got $C"
[ "$(printf '%s' "$C" | jq -r '.query.top_k')" = "3" ] \
  || fail "the query settings must be recorded, got $C"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.corpus.revision_source')" = "capture-outbox" ] \
  || fail "the corpus revision source must be recorded"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.run.label')" = "run one" ] \
  || fail "--label must be recorded so two runs can be told apart"
REV_ONE=$(printf '%s' "$EVAL_OUT" | jq -r '.corpus.revision')
SUM=$(printf '%s' "$EVAL_OUT" | jq -r '.eval_set.checksum')
case $REV_ONE in sha256:*) ;; *) fail "the corpus revision should be a digest, got $REV_ONE" ;; esac
printf '%s' "$EVAL_OUT" > "$TMP_ROOT/run-one.json"

# One unreadable outbox record leaves the revision underivable, which is a
# provenance field this run does not have - never a reason to abandon the
# questions, and never a digest over whatever happened to parse.
printf 'not json\n' > "$HOME_DIR/data/gbrain-outbox/broken.json"
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json
expect_code 0 "$EVAL_RC" "an unreadable outbox record must not abort the run"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.corpus.revision_source')" = "capture-outbox-unreadable" ] \
  || fail "an underivable revision must say so, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.corpus.revision')" = "null" ] \
  || fail "a partial corpus must not be reported as a reproducible revision, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.search.read')" = "4" ] \
  || fail "the questions must still be measured, got $EVAL_OUT"
rm -f "$HOME_DIR/data/gbrain-outbox/broken.json"

# The reranker is read from the brain rather than from firstmate's intent for
# it, so a brain that has it off is recorded as off.
FM_STUB_RERANK=false run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.configuration.reranker.enabled')" = "false" ] \
  || fail "a disabled reranker must be recorded as disabled"

# The summary a reader actually sees has to keep the same distinction: a brain
# with reranking OFF is a measured fact, and only a state the harness could not
# read is unknown.
FM_STUB_RERANK=false run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search
assert_contains "$EVAL_OUT" "(enabled: false)" \
  "a disabled reranker must render as disabled rather than as unknown"
FM_STUB_RERANK=unreadable run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search
assert_contains "$EVAL_OUT" "(enabled: unknown)" \
  "a reranker state that could not be read must render as unknown"
FM_STUB_RERANK=unreadable run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.configuration.reranker.enabled')" = "null" ] \
  || fail "an unreadable reranker state must be recorded as unknown, not as disabled"

# A changed corpus produces a changed revision, which is what stops a later run
# from being compared to this one as if nothing moved.
write_outbox sha256:bbb
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json --label "run two"
REV_TWO=$(printf '%s' "$EVAL_OUT" | jq -r '.corpus.revision')
[ "$REV_ONE" != "$REV_TWO" ] || fail "a changed corpus must change the recorded revision"
printf '%s' "$EVAL_OUT" > "$TMP_ROOT/run-two.json"
write_outbox sha256:aaa

# --- 4. thresholds decide the exit status -----------------------------------

write_set '.thresholds.search_top1 = 0.9'
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json
expect_code 1 "$EVAL_RC" "a missed threshold must exit 1 rather than pass quietly"
[ "$(printf '%s' "$EVAL_OUT" | jq -c '[.verdict[] | select(.met | not) | .metric]')" = '["search_top1"]' ] \
  || fail "the missed metric must be named in the verdict"
write_set

run_eval run --set "$EVAL_SET" --home "$TMP_ROOT/no-such-home" --phase search
expect_code 2 "$EVAL_RC" "an unusable home must be refused"
NO_BRAIN="$TMP_ROOT/brainless"
mkdir -p "$NO_BRAIN/config" "$NO_BRAIN/data"
run_eval run --set "$EVAL_SET" --home "$NO_BRAIN" --phase search
expect_code 3 "$EVAL_RC" "a home with no brain cannot be measured"
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase nonsense
expect_code 2 "$EVAL_RC" "an unknown phase must be refused"
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --think-attempts 0
expect_code 2 "$EVAL_RC" "a zero attempt budget must be refused"

# --- 5. think scoring, separately from search -------------------------------

think_doc ok "The alpha wedge report explains it." "home/tag/task/alpha" > "$REPLY_DIR/qa.think.json"
think_doc ok "Beta is mentioned but nothing is cited." > "$REPLY_DIR/qb.think.json"
think_doc failed "" > "$REPLY_DIR/qc.think.json"
think_doc ok "Delta, plus an unrelated citation." "home/tag/task/delta" "home/tag/task/zulu" \
  > "$REPLY_DIR/qd.think.json"

run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase think --json
T=$(printf '%s' "$EVAL_OUT" | jq -c '.think')
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.search')" = "null" ] \
  || fail "a think-only run must not report a search score"
[ "$(printf '%s' "$T" | jq -r '.answered')" = "0.75" ] \
  || fail "three of four questions were answered, got $T"
[ "$(printf '%s' "$T" | jq -c '.unanswered')" = '["qc"]' ] \
  || fail "the unanswered question must be named, got $T"
[ "$(printf '%s' "$T" | jq -r '(.grounded * 1000 | round)')" = "667" ] \
  || fail "grounding is over ANSWERED questions: qa and qd of three, got $T"
[ "$(printf '%s' "$T" | jq -c '.ungrounded')" = '["qb"]' ] \
  || fail "the ungrounded answer must be named, got $T"
[ "$(printf '%s' "$T" | jq -r '(.citation_precision * 1000 | round)')" = "750" ] \
  || fail "citation precision is (1/1 + 1/2)/2 over the answers that cited, got $T"
# qa requires two facts and the answer carries both, one of them only in the
# accepted alternative spelling; qb and qd carry their single fact.
[ "$(printf '%s' "$T" | jq -r '.key_facts')" = "1" ] \
  || fail "every answered question matched its facts, got $T"

# A fact the answer does not carry is scored down rather than ignored.
think_doc ok "Nothing relevant here." "home/tag/task/alpha" > "$REPLY_DIR/qa.think.json"
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase think --json
[ "$(printf '%s' "$EVAL_OUT" | jq -r '(.think.key_facts * 1000 | round)')" = "667" ] \
  || fail "a missing fact must lower the key-fact rate, got $EVAL_OUT"

# --- 6. retries separate a flaky provider from an unusable one --------------

: > "$FM_STUB_CALLS"
think_doc failed "" > "$REPLY_DIR/qa.think.1.json"
think_doc ok "The alpha wedge report explains it." "home/tag/task/alpha" > "$REPLY_DIR/qa.think.2.json"
rm -f "$REPLY_DIR/qa.think.json"
think_doc ok "Beta." "home/tag/task/beta" > "$REPLY_DIR/qb.think.json"
think_doc ok "Gamma." "home/tag/task/gamma" > "$REPLY_DIR/qc.think.json"
think_doc ok "Delta." "home/tag/task/delta" > "$REPLY_DIR/qd.think.json"

run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase think --json --think-attempts 2
T=$(printf '%s' "$EVAL_OUT" | jq -c '.think')
[ "$(printf '%s' "$T" | jq -r '.attempts_allowed')" = "2" ] \
  || fail "the attempt budget must be recorded with the numbers, got $T"
[ "$(printf '%s' "$T" | jq -r '.answered')" = "1" ] \
  || fail "a retry that succeeds must count as answered, got $T"
[ "$(printf '%s' "$T" | jq -r '.first_attempt_answered')" = "0.75" ] \
  || fail "the first-call rate must stay visible next to it, got $T"

# --- 7. a failed LOCAL read is not a failed synthesis -----------------------
#
# think measures the HOSTED provider. When the local read fails, fm-recall.sh
# exits 3 with a document that carries an error and no synthesis at all, so the
# hosted side was never reached: counting that question as an unanswered
# synthesis would fold a corpus failure into the number that exists to measure
# the provider.

: > "$FM_STUB_CALLS"
rm -f "$REPLY_DIR/qa.think.1.json" "$REPLY_DIR/qa.think.2.json"
think_doc ok "The alpha wedge report explains it." "home/tag/task/alpha" > "$REPLY_DIR/qa.think.json"
think_doc failed "" > "$REPLY_DIR/qb.think.json"
think_doc ok "Delta." "home/tag/task/delta" > "$REPLY_DIR/qd.think.json"
local_read_failure > "$REPLY_DIR/qc.think.json"
printf '3\n' > "$REPLY_DIR/qc.think.json.rc"

run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase think --json
T=$(printf '%s' "$EVAL_OUT" | jq -c '.think')
[ "$(printf '%s' "$T" | jq -r '.questions')" = "4" ] \
  || fail "an unread question must still be counted as a question, got $T"
[ "$(printf '%s' "$T" | jq -r '.read')" = "3" ] \
  || fail "the questions actually read must be reported next to the rates, got $T"
[ "$(printf '%s' "$T" | jq -c '.unread')" = '[{"id":"qc","reason":"local_retrieval_failed"}]' ] \
  || fail "the excluded question must be named as unread, with why it was excluded, got $T"
[ "$(printf '%s' "$T" | jq -c '.unanswered')" = '["qb"]' ] \
  || fail "an unread question must not be reported as an unanswered synthesis, got $T"
[ "$(printf '%s' "$T" | jq -r '(.answered * 1000 | round)')" = "667" ] \
  || fail "answered must denominate over the questions read, not all of them, got $T"
[ "$(printf '%s' "$T" | jq -r '(.first_attempt_answered * 1000 | round)')" = "667" ] \
  || fail "the first-call rate must denominate the same way, got $T"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '[.questions[] | select(.id == "qc") | .think.state] | first')" = "unread" ] \
  || fail "the per-question record must say the local read failed, got $EVAL_OUT"

# A think run where the brain answered nothing measured nothing, and must not
# report a missed hosted threshold for a failure that was never the provider's.
: > "$FM_STUB_CALLS"
for k in qa qb qc qd; do
  local_read_failure > "$REPLY_DIR/$k.think.json"
  printf '3\n' > "$REPLY_DIR/$k.think.json.rc"
done
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase think --json
expect_code 3 "$EVAL_RC" "a think run that could read nothing must not exit 1 as a missed threshold"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.think.read')" = "0" ] \
  || fail "no question was read, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.think.answered')" = "null" ] \
  || fail "a rate over no questions is not zero, it is absent, got $EVAL_OUT"

# --- 7b. a phase that ran and measured nothing fails the gate ---------------
#
# The worst thing this harness can do is report success for a run that produced
# no evidence. A hosted credential that was rotated away makes fm-recall.sh
# refuse every think call before the provider is reached, and search still reads
# the index perfectly - so the run must not pass on the strength of the half
# that worked, and it must say the hosted half measured nothing rather than
# leaving its thresholds silently absent.
: > "$FM_STUB_CALLS"
for k in qa qb qc qd; do
  jq -n '{schema: "fm-recall.v1", command: "think",
          error: {code: "hosted_key_missing", message: "the credential is not installed"}}' \
    > "$REPLY_DIR/$k.think.json"
  printf '4\n' > "$REPLY_DIR/$k.think.json.rc"
done
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase both --json
expect_code 1 "$EVAL_RC" "a phase that ran and measured nothing must not let the run pass"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.search.measured')" = "true" ] \
  || fail "the search phase did measure, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.think.measured')" = "false" ] \
  || fail "a phase that read nothing must record that it measured nothing, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -c '[.verdict[] | select(.state == "unmeasured") | .metric]')" \
    = '["think_answered","think_grounded","think_key_facts"]' ] \
  || fail "a declared threshold for an unmeasured phase must stay in the verdict, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -c '[.verdict[] | select(.state == "met") | .metric]')" \
    = '["search_top1","search_topk"]' ] \
  || fail "the phase that did measure must still report its own verdict, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -c '[.think.unread[].reason] | unique')" = '["hosted_key_missing"]' ] \
  || fail "an operator must be pointed at the credential, not the index, got $EVAL_OUT"
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase both
assert_contains "$EVAL_OUT" "MEASURED NOTHING" "the render must show the phase that measured nothing"
assert_contains "$EVAL_OUT" "UNMEASURED  think_answered" \
  "an unmeasured threshold must read differently from a missed one"
assert_contains "$EVAL_OUT" "hosted_key_missing" "the render must name why each question was unread"

# Whether a phase produced evidence cannot depend on what the set happens to
# declare. With no think threshold at all there is no threshold to miss, and the
# run must still fail because the phase measured nothing.
write_set 'del(.thresholds.think_answered, .thresholds.think_grounded, .thresholds.think_key_facts)'
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase both --json
expect_code 1 "$EVAL_RC" "a phase that measured nothing must fail with no threshold declared for it"
[ "$(printf '%s' "$EVAL_OUT" | jq -c '[.verdict[] | select(.phase == "think")]')" = "[]" ] \
  || fail "a threshold the set never declared must not appear in the verdict, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -c '[.verdict[] | select(.met | not)]')" = "[]" ] \
  || fail "no threshold was missed, so the failure must come from the missing evidence, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.think.measured')" = "false" ] \
  || fail "the think phase measured nothing, got $EVAL_OUT"
assert_contains "$(cat "$TMP_ROOT/err.txt")" "measured nothing" \
  "a run that produced no evidence for a phase must say so even with --json"
write_set
for k in qa qb qc qd; do rm -f "$REPLY_DIR/$k.think.json.rc"; done

# --- 7c. an unmeasured metric names the cause it actually reached -----------
#
# A metric averaged over the ANSWERED questions goes unmeasured when the
# provider answers nothing, which is not the same state as a phase that read
# nothing - and after reinit-pglite wipes the hosted model, that is exactly what
# a real brain does. Reporting "read nothing" here would send an operator to the
# index while every question was read.
: > "$FM_STUB_CALLS"
for k in qa qb qc qd; do think_doc failed "" > "$REPLY_DIR/$k.think.json"; done
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase think --json
expect_code 1 "$EVAL_RC" "a provider that answered nothing misses its answered threshold"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.think.measured')" = "true" ] \
  || fail "every question was read, so the phase did measure, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -c '[.verdict[] | select(.state == "unmeasured") | {metric, scored, reason}]')" \
    = '[{"metric":"think_grounded","scored":0,"reason":"the think phase produced no value for this metric"},{"metric":"think_key_facts","scored":0,"reason":"the think phase produced no value for this metric"}]' ] \
  || fail "an unmeasured metric must name the cause it actually reached, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -c '[.verdict[] | select(.metric == "think_answered") | {state, scored}]')" \
    = '[{"state":"missed","scored":4}]' ] \
  || fail "answered was measured over the four read questions and missed, got $EVAL_OUT"
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase think
assert_not_contains "$EVAL_OUT" "read nothing" \
  "a phase that read every question must never be reported as having read nothing"
assert_not_contains "$EVAL_OUT" "MEASURED NOTHING" \
  "a phase that read every question did measure"

# --- 8. compare reports what is not like-for-like ---------------------------

run_eval compare "$TMP_ROOT/run-one.json" "$TMP_ROOT/run-two.json" --json
expect_code 0 "$EVAL_RC" "compare should read two run documents"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.comparable.corpus')" = "changed" ] \
  || fail "a changed corpus revision must be reported as not like-for-like"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.comparable.eval_set')" = "same" ] \
  || fail "the same evaluation set must be reported as comparable"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.comparable.embedding')" = "same" ] \
  || fail "an unchanged embedding must be reported as comparable"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '[.metrics[] | select(.metric == "search_top1")][0].delta')" = "0" ] \
  || fail "an unchanged metric must compare as no delta"

# A field neither run could record is not evidence of sameness: two nulls
# compare equal, and reporting that as "same" is the silent like-for-like claim
# this command exists to prevent.
jq '.corpus.revision = null | .configuration.gbrain_version = null' \
  "$TMP_ROOT/run-one.json" > "$TMP_ROOT/run-blind.json"
run_eval compare "$TMP_ROOT/run-blind.json" "$TMP_ROOT/run-blind.json" --json
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.comparable.corpus')" = "unknown" ] \
  || fail "an underivable corpus revision must not compare as same, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.comparable.gbrain')" = "unknown" ] \
  || fail "an unrecorded GBrain version must not compare as same, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.comparable.embedding')" = "same" ] \
  || fail "a field both runs did record must still compare, got $EVAL_OUT"
run_eval compare "$TMP_ROOT/run-blind.json" "$TMP_ROOT/run-blind.json"
assert_contains "$EVAL_OUT" "UNKNOWN  corpus" "the rendered comparison must show what could not be compared"

# An absent optional value must not swallow a definite difference. A migration
# is exactly this shape: the endpoint moves to the command line, so no run
# records it, while the dimension change is the whole point of the comparison.
jq '.configuration.embedding = {model: "nomic-embed-text:v1.5", dimensions: 768, base_url: null}
    | .configuration.reranker.base_url = null' \
  "$TMP_ROOT/run-one.json" > "$TMP_ROOT/run-migrated.json"
jq '.configuration.embedding.base_url = null | .configuration.reranker.base_url = null' \
  "$TMP_ROOT/run-one.json" > "$TMP_ROOT/run-premigration.json"
run_eval compare "$TMP_ROOT/run-premigration.json" "$TMP_ROOT/run-migrated.json" --json
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.comparable.embedding')" = "changed" ] \
  || fail "a 1024-to-768 style migration must read as changed with no endpoint recorded, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.comparable.reranker')" = "unknown" ] \
  || fail "a value neither run recorded must still read as unknown, got $EVAL_OUT"
[ "$(printf '%s' "$EVAL_OUT" | jq -c '.unrecorded.reranker')" = '["base_url"]' ] \
  || fail "the value that could not be compared must be named, got $EVAL_OUT"
run_eval compare "$TMP_ROOT/run-premigration.json" "$TMP_ROOT/run-migrated.json"
assert_contains "$EVAL_OUT" "CHANGED  embedding" "a real difference must not be rendered as unknown"
assert_contains "$EVAL_OUT" "not recorded: base_url" \
  "the render must name which value was missing rather than an opaque unknown"

run_eval compare "$TMP_ROOT/run-one.json" "$EVAL_SET"
expect_code 2 "$EVAL_RC" "compare must refuse a document that is not a run"

# The set checksum is what makes a later run comparable at all, so it has to
# move when the set does.
write_set '.questions[0].question = "qa reworded"'
run_eval run --set "$EVAL_SET" --home "$HOME_DIR" --phase search --json
[ "$(printf '%s' "$EVAL_OUT" | jq -r '.eval_set.checksum')" != "$SUM" ] \
  || fail "an edited evaluation set must change the recorded checksum"
write_set

rm -f "$TMP_ROOT/qc.keep"
pass "fm-gbrain-eval.sh scores retrieval and synthesis separately, records its provenance, and reports a missed threshold"
