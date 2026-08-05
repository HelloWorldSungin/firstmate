#!/usr/bin/env bash
# fm-gbrain-eval.sh - measure a home brain's retrieval and synthesis quality
# against a versioned evaluation set, and record the configuration the numbers
# came from.
#
# A retrieval score with no provenance cannot be compared to the next one, so
# every run records the GBrain version, the embedding model and its dimension,
# the reranker, the hosted synthesis model, the corpus revision, and the query
# settings alongside the numbers. Re-running after a corpus, GBrain, model, or
# reranker change is then a like-for-like comparison rather than a new opinion.
#
# Local retrieval and hosted synthesis are scored and reported SEPARATELY. They
# fail for unrelated reasons - a weak embedding model and an unreachable hosted
# provider are not the same problem - and one combined score would hide which
# half is weak.
#
# Retrieval goes through bin/fm-recall.sh, the same surface firstmate and every
# crewmate read a brain with, so the measurement is of the path that is actually
# used rather than of a private one. This script never writes to a brain.
#
# docs/gbrain.md owns the evaluation and migration procedure this implements,
# and docs/gbrain-eval-set.v1.json is the default evaluation set.
#
# Usage:
#   fm-gbrain-eval.sh run [--set <file>] [--home <dir>] [--phase search|think|both]
#                         [--question <id>]... [--out <file>] [--json]
#                         [--search-timeout <s>] [--think-timeout <s>]
#                         [--think-attempts <n>] [--label <text>]
#   fm-gbrain-eval.sh validate [--set <file>]
#   fm-gbrain-eval.sh compare <baseline.json> <candidate.json> [--json]
#
# Commands:
#   run       Run every question in the set and print one "fm-gbrain-eval.v1"
#             run document. --json prints the document instead of the human
#             summary; --out writes it to a file as well, which is what a later
#             compare reads.
#   validate  Check an evaluation set's shape without touching a brain: schema,
#             version, query settings, thresholds, unique question ids, and a
#             non-empty expectation per question.
#   compare   Print the metric-by-metric delta between two run documents, and
#             the configuration fields that differ. A comparison across
#             different corpus revisions or eval sets is reported as such rather
#             than silently treated as like-for-like, and a value neither run
#             could record is reported as unknown rather than as unchanged: two
#             absent values are not evidence of sameness. A field whose recorded
#             values differ is still reported as changed even when an optional
#             sibling value is missing.
#
# Scoring:
#   An expected source is a slug SUFFIX, so the set is portable across homes:
#   "task/<id>" matches "<anything>/task/<id>". A question may list several
#   expectations and any of them counts as correct, which is how a genuine
#   near-duplicate family is scored honestly.
#
#   search  top1     the first result is an expected source.
#           topk     an expected source is within the first k results (k comes
#                    from the set's query.top_k, and is 5 in the shipped set).
#           mrr      mean reciprocal rank of the first expected source within
#                    the retrieved limit, 0 when none was retrieved.
#   think   answered synthesis returned an answer within --think-attempts calls
#                    (default 1, so the default number is per call). A run also
#                    records first_attempt_answered, which is what distinguishes
#                    a flaky provider from an unusable one.
#                    Every think rate is over the questions that reached hosted
#                    synthesis, which the run records as think.read. A question
#                    that never reached it - the local read failed, gbrain is
#                    absent, no hosted credential is installed, or the call was
#                    killed - is reported as unread WITH ITS REASON rather than
#                    as an unanswered synthesis, because none of those says
#                    anything about the hosted provider, and folding them in
#                    would be exactly the combined score this separation exists
#                    to prevent.
#           grounded the answer cites at least one expected source.
#           key_facts the fraction of the question's required facts that appear
#                    in the answer. Each fact is a list of accepted spellings
#                    and any one of them satisfies it. This is a deterministic
#                    keyword proxy for answer quality, not a judge: it is
#                    repeatable and sends nothing extra off the host, and it
#                    cannot recognise a correct answer that uses none of the
#                    accepted spellings.
#           citation_precision the fraction of cited sources that were expected,
#                    over the answered questions that cited anything.
#
# Exit status:
#   0  the run completed and every threshold the set declares was met.
#   1  the run completed and at least one threshold was missed. That is a
#      reportable outcome, not an error: record it rather than moving the
#      threshold. A threshold the set declares for a phase that RAN and read
#      nothing counts here too, reported as unmeasured rather than as a miss: a
#      phase that produced no evidence cannot have met the threshold it was
#      asked to clear.
#   2  usage, or a configuration this command refuses to guess at.
#   3  the run could not be measured at all, because the brain could not be
#      read: no question was read by any phase that ran.
#
# Environment:
#   FM_HOME            active firstmate home; --home overrides it
#   FM_GBRAIN_BIN      gbrain executable (default: gbrain on PATH), read only
#                      for the version, configuration, and corpus counts
#   FM_RECALL_BIN      retrieval surface (default: bin/fm-recall.sh beside this)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gbrain-lib.sh
. "$SCRIPT_DIR/fm-gbrain-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

SCHEMA=fm-gbrain-eval.v1
SET_SCHEMA=fm-gbrain-eval-set.v1
DEFAULT_SET="$FM_ROOT/docs/gbrain-eval-set.v1.json"
GBRAIN_BIN="${FM_GBRAIN_BIN:-gbrain}"
RECALL_BIN="${FM_RECALL_BIN:-$SCRIPT_DIR/fm-recall.sh}"

SEARCH_TIMEOUT_DEFAULT=120
THINK_TIMEOUT_DEFAULT=300

usage() { awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }

die() {  # <exit> <message>
  local code=$1
  shift
  printf 'fm-gbrain-eval.sh: %s\n' "$*" >&2
  exit "$code"
}

need() {  # <command>
  command -v "$1" >/dev/null 2>&1 || die 2 "$1 is required"
}

# --- evaluation set ---------------------------------------------------------

# Validation is deliberately strict and separate from the run, because a set
# that is silently half-read produces numbers that look like measurements.
validate_set() {  # <file> -> 0 valid, 2 invalid (reason on stderr)
  local file=$1 problem
  [ -f "$file" ] || die 2 "no evaluation set at $file"
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || die 2 "$file is not a JSON object"
  problem=$(jq -r --arg schema "$SET_SCHEMA" '
    def bad($m): $m;
    if (.schema // "") != $schema then bad("schema must be \($schema)")
    elif (.id // "") == "" then bad("id is required")
    elif (.version | type) != "number" then bad("version must be a number")
    elif (.query | type) != "object" then bad("query is required")
    elif ((.query.limit | type) != "number") or (.query.limit < 1) then bad("query.limit must be a positive number")
    elif ((.query.top_k | type) != "number") or (.query.top_k < 1) then bad("query.top_k must be a positive number")
    elif .query.top_k > .query.limit then bad("query.top_k cannot exceed query.limit")
    elif (.thresholds | type) != "object" then bad("thresholds is required")
    elif ((.questions | type) != "array") or ((.questions | length) == 0) then bad("questions must be a non-empty array")
    elif ([.questions[].id] | length) != ([.questions[].id] | unique | length) then bad("question ids must be unique")
    elif any(.questions[]; (.id // "") == "") then bad("every question needs an id")
    elif any(.questions[]; (.question // "") == "") then bad("every question needs question text")
    elif any(.questions[]; ((.expect | type) != "array") or ((.expect | length) == 0)) then bad("every question needs a non-empty expect list")
    elif any(.questions[]; (.key_facts // []) | type != "array") then bad("key_facts must be an array of alternative lists")
    elif any(.questions[]; (.key_facts // [])[] | (type != "array") or (length == 0)) then bad("each key fact must be a non-empty list of accepted spellings")
    else "" end' "$file")
  if [ -n "$problem" ]; then
    printf 'fm-gbrain-eval.sh: %s: %s\n' "$file" "$problem" >&2
    return 2
  fi
  return 0
}

# --- configuration provenance -----------------------------------------------

# GBrain prints an upgrade banner on the same stream as its answers, so every
# read strips it rather than letting it become the value.
strip_banner() {
  grep -v -e '^UPGRADE_AVAILABLE' -e 'Run: gbrain self-upgrade' -e '^\[config\] source:' || true
}

gbrain_config_get() {  # <key> -> value, or empty when unavailable
  local key=$1 out
  command -v "$GBRAIN_BIN" >/dev/null 2>&1 || return 0
  out=$(GBRAIN_HOME="$FM_GBRAIN_HOME_DIR" fm_run_timed 30 "$GBRAIN_BIN" config get "$key" 2>/dev/null | strip_banner | head -1) || return 0
  printf '%s\n' "${out# }"
}

# The corpus revision has to be derivable from what a home actually holds. A
# capture-fed home's durable source is its outbox, whose per-document content
# version already names one exact revision of one document; a home fed from a
# markdown archive has that archive's git revision instead. Neither is guessed
# at: when neither exists the revision is reported as unknown rather than as a
# number that cannot be reproduced.
#
# A record that cannot be read is an anticipated state rather than a reason to
# abandon the run: the questions are still measurable, and only the revision is
# not. It is reported as its own source instead of being hashed over whatever
# happened to parse, because a digest that covers less than the corpus does
# would look exactly as reproducible as one that covers all of it.
corpus_revision() {  # <home> -> "<source>\t<revision>"
  local home=$1 outbox=$2 rev listing rc=0
  if [ -d "$outbox" ] && [ -n "$(find "$outbox" -maxdepth 1 -name '*.json' -print -quit 2>/dev/null)" ]; then
    listing=$(find "$outbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null \
      | xargs -0 -r jq -r '"\(.document_id)\t\(.content_version)"' 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$listing" ]; then
      rev=$(printf '%s\n' "$listing" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
      printf 'capture-outbox\tsha256:%s\n' "$rev"
      return 0
    fi
    printf 'capture-outbox-unreadable\t\n'
    return 0
  fi
  if [ -d "$FM_GBRAIN_ARCHIVE/.git" ] && command -v git >/dev/null 2>&1; then
    rev=$(git -C "$FM_GBRAIN_ARCHIVE" rev-parse HEAD 2>/dev/null) || rev=""
    [ -n "$rev" ] && { printf 'archive-git\t%s\n' "$rev"; return 0; }
  fi
  printf 'unknown\t\n'
  return 0
}

collect_configuration() {  # sets CONFIG_JSON and CORPUS_JSON
  local shared version="" engine="" embed_model="" embed_dims="" schema_pack=""
  local rerank_model="" rerank_enabled="" think_model="" gcfg
  local embed_url="" rerank_url="" think_url="" think_secret=""
  local pages="" chunks="" embedded="" stats revision_line revision_source revision

  shared=$(fm_gbrain_shared_path "$HOME_PATH")
  if [ -f "$shared" ]; then
    embed_url=$(fm_gbrain_json_str "$shared" '.local.embedding_base_url')
    rerank_url=$(fm_gbrain_json_str "$shared" '.local.reranker_base_url')
    think_url=$(fm_gbrain_json_str "$shared" '.think.base_url')
    think_secret=$(fm_gbrain_json_str "$shared" '.think.secret')
  fi

  if command -v "$GBRAIN_BIN" >/dev/null 2>&1; then
    version=$(fm_run_timed 30 "$GBRAIN_BIN" version 2>/dev/null | strip_banner | head -1 | awk '{print $2}') || version=""
  fi

  gcfg="$FM_GBRAIN_HOME_DIR/.gbrain/config.json"
  if [ -f "$gcfg" ]; then
    engine=$(jq -r '.engine // empty' "$gcfg" 2>/dev/null) || engine=""
    embed_model=$(jq -r '.embedding_model // empty' "$gcfg" 2>/dev/null) || embed_model=""
    embed_dims=$(jq -r '.embedding_dimensions // empty' "$gcfg" 2>/dev/null) || embed_dims=""
    schema_pack=$(jq -r '.schema_pack // empty' "$gcfg" 2>/dev/null) || schema_pack=""
  fi

  # The reranker and the hosted model live in the brain's own database plane, so
  # they are read from the brain rather than from firstmate's intent for it: a
  # run recorded as reranked while the brain has reranking off is exactly the
  # provenance failure this document exists to prevent.
  rerank_enabled=$(gbrain_config_get search.reranker.enabled)
  rerank_model=$(gbrain_config_get search.reranker.model)
  think_model=$(gbrain_config_get models.think)

  if command -v "$GBRAIN_BIN" >/dev/null 2>&1; then
    stats=$(GBRAIN_HOME="$FM_GBRAIN_HOME_DIR" fm_run_timed 120 "$GBRAIN_BIN" stats 2>/dev/null | strip_banner) || stats=""
    pages=$(printf '%s\n' "$stats" | awk '/^Pages:/{print $2; exit}')
    chunks=$(printf '%s\n' "$stats" | awk '/^Chunks:/{print $2; exit}')
    embedded=$(printf '%s\n' "$stats" | awk '/^Embedded:/{print $2; exit}')
  fi

  revision_line=$(corpus_revision "$HOME_PATH" "$HOME_PATH/data/gbrain-outbox")
  revision_source=${revision_line%%	*}
  revision=${revision_line#*	}

  CONFIG_JSON=$(jq -n \
    --arg home "$HOME_PATH" \
    --arg brain_root "$FM_GBRAIN_BRAIN_ROOT" \
    --arg version "$version" \
    --arg engine "$engine" \
    --arg embed_model "$embed_model" \
    --arg embed_dims "$embed_dims" \
    --arg embed_url "$embed_url" \
    --arg schema_pack "$schema_pack" \
    --arg rerank_model "$rerank_model" \
    --arg rerank_enabled "$rerank_enabled" \
    --arg rerank_url "$rerank_url" \
    --arg think_model "$think_model" \
    --arg think_url "$think_url" \
    --arg think_secret "$think_secret" \
    --argjson query "$QUERY_JSON" '
    def s($v): if $v == "" then null else $v end;
    {
      home: $home,
      brain_root: s($brain_root),
      gbrain_version: s($version),
      engine: s($engine),
      schema_pack: s($schema_pack),
      embedding: {
        model: s($embed_model),
        dimensions: (if $embed_dims == "" then null else ($embed_dims | tonumber) end),
        base_url: s($embed_url)
      },
      reranker: {
        model: s($rerank_model),
        enabled: (if $rerank_enabled == "" then null else ($rerank_enabled == "true") end),
        base_url: s($rerank_url)
      },
      think: {
        model: s($think_model),
        base_url: s($think_url),
        credential_name: s($think_secret)
      },
      query: $query
    }')

  CORPUS_JSON=$(jq -n \
    --arg pages "$pages" --arg chunks "$chunks" --arg embedded "$embedded" \
    --arg source "$revision_source" --arg revision "$revision" '
    def n($v): if ($v | test("^[0-9]+$")) then ($v | tonumber) else null end;
    {
      documents: n($pages),
      chunks: n($chunks),
      embedded: n($embedded),
      revision_source: $source,
      revision: (if $revision == "" then null else $revision end)
    }')
}

# --- one question -----------------------------------------------------------

run_search() {  # <question-json> -> per-question search JSON on stdout
  local q=$1 text expect doc rc=0
  text=$(printf '%s' "$q" | jq -r '.question')
  expect=$(printf '%s' "$q" | jq -c '.expect')
  doc=$(fm_run_timed "$SEARCH_TIMEOUT" "$RECALL_BIN" search --home "$HOME_PATH" \
    --scope "$SCOPE" --limit "$LIMIT" --excerpt "$EXCERPT" --json -- "$text" 2>/dev/null) || rc=$?
  # A refusal document and a document a kill truncated are both "not read", and
  # neither may abort the run: one unreadable answer is a question that was not
  # measured, not a reason to abandon the nineteen that were.
  if [ "$rc" -ne 0 ] || [ -z "$doc" ] \
    || ! printf '%s' "$doc" | jq -e 'has("results")' >/dev/null 2>&1; then
    jq -n --arg rc "$rc" '{state: "failed", exit: ($rc | tonumber), hit_rank: null,
      top1: false, topk: false, rr: 0, retrieved: 0, results: []}'
    return 0
  fi
  printf '%s' "$doc" | jq -c --argjson expect "$expect" --argjson k "$TOP_K" '
    def hit($slug): any($expect[]; . as $e | ($slug == $e) or ($slug | endswith("/" + $e)));
    [.results[] | .slug] as $slugs
    | ([range(0; ($slugs | length)) | select(hit($slugs[.])) ] | first) as $idx
    | ($idx // -1) as $i
    | {
        state: "ok",
        exit: 0,
        retrieved: ($slugs | length),
        hit_rank: (if $i < 0 then null else $i + 1 end),
        top1: ($i == 0),
        topk: ($i >= 0 and $i < $k),
        rr: (if $i < 0 then 0 else (1 / ($i + 1)) end),
        results: [.results[] | {slug: .slug, source: .source, score: .score}],
        sources: [.sources[] | {source: .source, state: .state}]
      }'
}

# The hosted provider can return an unusable answer for one call and a good one
# for the next, so attempts are explicit and both numbers are kept: an operator
# needs to know whether a retry clears the failure or the provider is simply
# unusable. attempts stays 1 by default, which keeps a set's declared
# think_answered threshold a per-call number rather than a per-question one.
#
# A think call reaches a verdict on the hosted provider only when it produced a
# synthesis block at all. Without one - the local read failed, gbrain is absent,
# no hosted credential is installed, or the call was killed - the hosted side
# was never measured, so the question is recorded as unread rather than as an
# answer the provider failed to give.
run_think() {  # <question-json> -> per-question think JSON on stdout
  local q=$1 text expect facts doc rc=0 attempt=0 first_ok=false
  text=$(printf '%s' "$q" | jq -r '.question')
  expect=$(printf '%s' "$q" | jq -c '.expect')
  facts=$(printf '%s' "$q" | jq -c '.key_facts // []')
  while [ "$attempt" -lt "$THINK_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    rc=0
    doc=$(fm_run_timed "$THINK_TIMEOUT" "$RECALL_BIN" think --home "$HOME_PATH" \
      --max-answer "$ANSWER_MAX" --json -- "$text" 2>/dev/null) || rc=$?
    if [ -n "$doc" ] && printf '%s' "$doc" \
      | jq -e '(.synthesis.state // "") == "ok" and ((.synthesis.answer // "") | length) > 0' >/dev/null 2>&1; then
      if [ "$attempt" -eq 1 ]; then first_ok=true; fi
      break
    fi
  done
  # The LAST attempt's document is the one scored, so a question that never
  # succeeded is reported with its final failure rather than an earlier one.
  if [ -z "$doc" ] || ! printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1; then
    jq -n --arg rc "$rc" --arg a "$attempt" '{state: "unread", exit: ($rc | tonumber),
      read: false, error: "no_document",
      answered: false, first_attempt_answered: false, attempts: ($a | tonumber),
      grounded: false, key_fact_rate: null, key_facts_matched: 0, key_facts_total: 0,
      citations: [], citations_expected: 0, truncated: null}'
    return 0
  fi
  printf '%s' "$doc" | jq -c --argjson expect "$expect" --argjson facts "$facts" --arg rc "$rc" \
    --arg attempts "$attempt" --argjson first "$first_ok" '
    def hit($slug): any($expect[]; . as $e | ($slug == $e) or ($slug | endswith("/" + $e)));
    (.synthesis.answer // "") as $answer
    | ($answer | ascii_downcase) as $lower
    | [.citations[]? | sub("^[a-z]+:"; "")] as $cited
    | ((.synthesis.state // "") == "ok" and ($answer | length) > 0) as $answered
    | [$facts[] | any(.[]; . as $alt | ($lower | contains($alt | ascii_downcase)))] as $matched
    | (.synthesis != null) as $read
    | {
        state: (if $read then (.synthesis.state // "failed") else "unread" end),
        exit: ($rc | tonumber),
        read: $read,
        error: (if $read then null else (.error.code // "no_synthesis") end),
        answered: $answered,
        attempts: ($attempts | tonumber),
        first_attempt_answered: ($first and $answered),
        model: .synthesis.model,
        truncated: .synthesis.truncated,
        warnings: (.synthesis.warnings // []),
        citations: $cited,
        citations_expected: ([$cited[] | select(hit(.))] | length),
        grounded: ($answered and (any($cited[]; hit(.)))),
        key_facts_total: ($matched | length),
        key_facts_matched: ([$matched[] | select(.)] | length),
        key_fact_rate: (if ($matched | length) == 0 then null
                        else (([$matched[] | select(.)] | length) / ($matched | length)) end),
        answer_chars: ($answer | length)
      }'
}

# --- run --------------------------------------------------------------------

cmd_run() {
  local set_file=$DEFAULT_SET home_arg="" phase=both out="" json=0 label=""
  local -a only=()
  SEARCH_TIMEOUT=$SEARCH_TIMEOUT_DEFAULT
  THINK_TIMEOUT=$THINK_TIMEOUT_DEFAULT
  THINK_ATTEMPTS=1
  while [ $# -gt 0 ]; do
    case $1 in
      --set) set_file=${2:-}; shift 2 ;;
      --home) home_arg=${2:-}; shift 2 ;;
      --phase) phase=${2:-}; shift 2 ;;
      --question) only+=("${2:-}"); shift 2 ;;
      --out) out=${2:-}; shift 2 ;;
      --label) label=${2:-}; shift 2 ;;
      --search-timeout) SEARCH_TIMEOUT=${2:-}; shift 2 ;;
      --think-timeout) THINK_TIMEOUT=${2:-}; shift 2 ;;
      --think-attempts) THINK_ATTEMPTS=${2:-}; shift 2 ;;
      --json) json=1; shift ;;
      -h | --help) usage; return 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  case $phase in search | think | both) ;; *) die 2 "--phase takes search, think, or both" ;; esac
  case $SEARCH_TIMEOUT in ''|*[!0-9]*|0) die 2 "--search-timeout takes a positive number of seconds" ;; esac
  case $THINK_TIMEOUT in ''|*[!0-9]*|0) die 2 "--think-timeout takes a positive number of seconds" ;; esac
  case $THINK_ATTEMPTS in ''|*[!0-9]*|0) die 2 "--think-attempts takes a positive number of calls" ;; esac
  validate_set "$set_file" || exit 2
  [ -x "$RECALL_BIN" ] || die 2 "no retrieval surface at $RECALL_BIN (set FM_RECALL_BIN)"

  fm_gbrain_resolve_home "$home_arg" "$FM_ROOT" || die 2 "$FM_GBRAIN_ERROR"
  HOME_PATH=$FM_GBRAIN_HOME_PATH
  fm_gbrain_resolve_paths "$HOME_PATH" || die 2 "$HOME_PATH: $FM_GBRAIN_ERROR"
  [ -d "$FM_GBRAIN_PGLITE" ] || die 3 "$HOME_PATH has no initialized brain at $FM_GBRAIN_PGLITE"

  SCOPE=$(jq -r '.query.scope // "all"' "$set_file")
  LIMIT=$(jq -r '.query.limit' "$set_file")
  TOP_K=$(jq -r '.query.top_k' "$set_file")
  EXCERPT=$(jq -r '.query.excerpt // 400' "$set_file")
  ANSWER_MAX=$(jq -r '.query.think_max_answer // 8000' "$set_file")
  QUERY_JSON=$(jq -c '.query' "$set_file")

  local selected
  if [ "${#only[@]}" -gt 0 ]; then
    selected=$(jq -c --argjson ids "$(printf '%s\n' "${only[@]}" | jq -R . | jq -s .)" \
      '[.questions[] | select(.id as $i | $ids | index($i))]' "$set_file")
    [ "$(printf '%s' "$selected" | jq 'length')" -gt 0 ] || die 2 "no question in $set_file matched --question"
  else
    selected=$(jq -c '.questions' "$set_file")
  fi

  collect_configuration

  local started finished per_question total i q qid
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  per_question=$(mktemp) || die 2 "could not create a working file"
  # shellcheck disable=SC2064  # the path is fixed at trap-installation time
  trap "rm -f '$per_question'" EXIT
  total=$(printf '%s' "$selected" | jq 'length')
  i=0
  while [ "$i" -lt "$total" ]; do
    q=$(printf '%s' "$selected" | jq -c ".[$i]")
    qid=$(printf '%s' "$q" | jq -r '.id')
    i=$((i + 1))
    [ "$json" -eq 1 ] || printf '[%d/%d] %s\n' "$i" "$total" "$qid" >&2
    local s='null' t='null'
    case $phase in
      search | both) s=$(run_search "$q") ;;
    esac
    case $phase in
      think | both) t=$(run_think "$q") ;;
    esac
    jq -nc --argjson q "$q" --argjson s "$s" --argjson t "$t" \
      '{id: $q.id, question: $q.question, expect: $q.expect, note: $q.note, search: $s, think: $t}' \
      >> "$per_question"
  done
  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local document
  document=$(jq -s \
    --arg schema "$SCHEMA" \
    --arg started "$started" --arg finished "$finished" \
    --arg phase "$phase" --arg label "$label" \
    --argjson attempts "$THINK_ATTEMPTS" \
    --arg set_path "$set_file" \
    --arg set_sum "sha256:$(sha256sum "$set_file" | cut -d' ' -f1)" \
    --argjson set_meta "$(jq -c '{id, version, schema, questions: (.questions | length)}' "$set_file")" \
    --argjson thresholds "$(jq -c '.thresholds' "$set_file")" \
    --argjson configuration "$CONFIG_JSON" \
    --argjson corpus "$CORPUS_JSON" '
    . as $qs
    | [$qs[] | select(.search != null)] as $sq
    | [$qs[] | select(.think != null)] as $tq
    | [$sq[] | select(.search.state == "ok")] as $sok
    | [$tq[] | select(.think.read)] as $tread
    | [$tread[] | select(.think.answered)] as $tok
    | [$tok[] | select((.think.citations | length) > 0)] as $tcited
    | def avg($xs): if ($xs | length) == 0 then null else (($xs | add) / ($xs | length)) end;
    {
      schema: $schema,
      run: {started: $started, finished: $finished, phase: $phase,
            label: (if $label == "" then null else $label end),
            questions: ($qs | length)},
      eval_set: ($set_meta + {path: $set_path, checksum: $set_sum}),
      configuration: $configuration,
      corpus: $corpus,
      thresholds: $thresholds,
      search: (if ($sq | length) == 0 then null else {
        questions: ($sq | length),
        read: ($sok | length),
        measured: (($sok | length) > 0),
        top_k: $configuration.query.top_k,
        top1: avg([$sok[] | (if .search.top1 then 1 else 0 end)]),
        topk: avg([$sok[] | (if .search.topk then 1 else 0 end)]),
        mrr: avg([$sok[] | .search.rr]),
        missed: [$sq[] | select(.search.state != "ok" or .search.hit_rank == null) | .id],
        below_top1: [$sok[] | select(.search.hit_rank != null and .search.hit_rank > 1)
                     | {id: .id, rank: .search.hit_rank}]
      } end),
      think: (if ($tq | length) == 0 then null else {
        questions: ($tq | length),
        read: ($tread | length),
        measured: (($tread | length) > 0),
        attempts_allowed: $attempts,
        answered: avg([$tread[] | (if .think.answered then 1 else 0 end)]),
        first_attempt_answered: avg([$tread[] | (if .think.first_attempt_answered then 1 else 0 end)]),
        grounded: avg([$tok[] | (if .think.grounded then 1 else 0 end)]),
        key_facts: avg([$tok[] | .think.key_fact_rate | select(. != null)]),
        citation_precision: avg([$tcited[] | (.think.citations_expected / (.think.citations | length))]),
        truncated: [$tok[] | select(.think.truncated == true) | .id],
        unread: [$tq[] | select(.think.read | not) | {id: .id, reason: .think.error}],
        unanswered: [$tread[] | select(.think.answered | not) | .id],
        ungrounded: [$tok[] | select(.think.grounded | not) | .id]
      } end)
    }
    # A threshold the set declares for a phase that RAN is part of the verdict
    # even when the phase measured nothing, because dropping it would report a
    # run that produced no evidence as one that met every threshold. It carries
    # its own state rather than counting as a miss: no measurement fell short,
    # the measurement never happened at all.
    | . as $run
    | . + {verdict: ([
        {metric: "search_top1", phase: "search", value: $run.search.top1, threshold: $run.thresholds.search_top1},
        {metric: "search_topk", phase: "search", value: $run.search.topk, threshold: $run.thresholds.search_topk},
        {metric: "think_answered", phase: "think", value: $run.think.answered, threshold: $run.thresholds.think_answered},
        {metric: "think_grounded", phase: "think", value: $run.think.grounded, threshold: $run.thresholds.think_grounded},
        {metric: "think_key_facts", phase: "think", value: $run.think.key_facts, threshold: $run.thresholds.think_key_facts}
      ] | map(select(.threshold != null
                     and (if .phase == "search" then $run.search else $run.think end) != null))
        | map(. + (if .value == null then {met: false, state: "unmeasured"}
                   else {met: (.value >= .threshold),
                         state: (if .value >= .threshold then "met" else "missed" end)} end)))}
    | . + {questions: $qs}' "$per_question")

  [ -z "$out" ] || printf '%s\n' "$document" > "$out"
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$document"
  else
    render_run "$document"
  fi
  # A phase that read no corpus at all measured nothing, so a run in which no
  # phase read anything must not report a passing verdict just because every
  # averaged metric came out null and dropped out of the verdict.
  if [ "$(printf '%s' "$document" | jq -r '
        [(.search, .think) | select(. != null) | .read] as $read
        | if ($read | length) > 0 and ($read | all(. == 0)) then "none" else "some" end')" = "none" ]; then
    printf 'fm-gbrain-eval.sh: no corpus answered; the run measured nothing\n' >&2
    return 3
  fi
  local missed
  missed=$(printf '%s' "$document" | jq '[.verdict[] | select(.met | not)] | length')
  [ "$missed" -eq 0 ]
}

render_run() {  # <document>
  printf '%s' "$1" | jq -r '
    def pct($v): if $v == null then "n/a" else ((($v * 1000 | round) / 10) | tostring) + "%" end;
    "eval-set   \(.eval_set.id) v\(.eval_set.version)  (\(.run.questions) of \(.eval_set.questions) questions, \(.eval_set.checksum[0:14])...)",
    "gbrain     \(.configuration.gbrain_version // "unknown")   home \(.configuration.home)",
    "embedding  \(.configuration.embedding.model // "unknown") @ \(.configuration.embedding.dimensions // "?") dims",
    "reranker   \(.configuration.reranker.model // "unknown") (enabled: \(.configuration.reranker.enabled // "unknown"))",
    "think      \(.configuration.think.model // "unknown")",
    "corpus     \(.corpus.documents // "?") documents, \(.corpus.chunks // "?") chunks, \(.corpus.embedded // "?") embedded",
    "           revision \(.corpus.revision // "unknown") (\(.corpus.revision_source))",
    "query      scope=\(.configuration.query.scope) limit=\(.configuration.query.limit) top_k=\(.configuration.query.top_k)",
    "run        \(.run.started) -> \(.run.finished)  phase=\(.run.phase)",
    "",
    (if .search then
      "SEARCH (local retrieval, \(.search.read)/\(.search.questions) questions read)",
      (if .search.measured then empty
       else "  MEASURED NOTHING     no question was read, so every rate below is absent rather than zero" end),
      "  top-1                \(pct(.search.top1))",
      "  top-\(.search.top_k)                \(pct(.search.topk))",
      "  MRR                  \(if .search.mrr == null then "n/a" else ((.search.mrr * 1000 | round) / 1000 | tostring) end)",
      "  not retrieved        \(if (.search.missed | length) == 0 then "none" else (.search.missed | join(", ")) end)"
     else "SEARCH  not run" end),
    "",
    (if .think then
      "THINK (hosted synthesis, \(.think.read)/\(.think.questions) questions read, \(.think.attempts_allowed) attempt(s) allowed)",
      (if .think.measured then empty
       else "  MEASURED NOTHING     no question reached hosted synthesis, so every rate below is absent rather than zero" end),
      "  answered             \(pct(.think.answered))",
      "  answered 1st call    \(pct(.think.first_attempt_answered))",
      "  grounded             \(pct(.think.grounded))",
      "  key facts            \(pct(.think.key_facts))",
      "  citation precision   \(pct(.think.citation_precision))",
      "  not read             \(if (.think.unread | length) == 0 then "none"
                                 else (.think.unread | map("\(.id) (\(.reason // "unknown"))") | join(", "))
                                      + " - never reached hosted synthesis, so excluded from every rate above" end)",
      "  not answered         \(if (.think.unanswered | length) == 0 then "none" else (.think.unanswered | join(", ")) end)",
      "  not grounded         \(if (.think.ungrounded | length) == 0 then "none" else (.think.ungrounded | join(", ")) end)"
     else "THINK   not run" end),
    "",
    "THRESHOLDS",
    (.verdict[]
      | "  \(if .state == "met" then "met       " elif .state == "missed" then "MISSED    " else "UNMEASURED" end)  \(.metric)  \(pct(.value)) vs \(pct(.threshold))"),
    (if any(.verdict[]; .state == "unmeasured") then
      "  UNMEASURED means that phase ran and read nothing, so its thresholds could not be evaluated and the run does not pass"
     else empty end),
    (if ((.verdict | length) == 0) then "  none applicable to this run" else empty end)'
}

# --- compare ----------------------------------------------------------------

cmd_compare() {
  local a="" b="" json=0
  while [ $# -gt 0 ]; do
    case $1 in
      --json) json=1; shift ;;
      -h | --help) usage; return 0 ;;
      -*) die 2 "unknown argument: $1" ;;
      *) if [ -z "$a" ]; then a=$1; elif [ -z "$b" ]; then b=$1; else die 2 "compare takes exactly two run documents"; fi; shift ;;
    esac
  done
  [ -n "$a" ] && [ -n "$b" ] || die 2 "compare takes a baseline and a candidate run document"
  local f
  for f in "$a" "$b"; do
    [ -f "$f" ] || die 2 "no run document at $f"
    jq -e --arg s "$SCHEMA" '.schema == $s' "$f" >/dev/null 2>&1 || die 2 "$f is not a $SCHEMA document"
  done
  local doc
  doc=$(jq -n --slurpfile base "$a" --slurpfile cand "$b" '
    ($base[0]) as $a | ($cand[0]) as $b
    | def d($x; $y): if ($x == null or $y == null) then null else ($y - $x) end;
    # A field neither run could record is not evidence that it did not move:
    # two nulls compare equal, and reporting that as "same" would be the exact
    # silent like-for-like claim this command exists to prevent.
    #
    # The decision is per LEAF rather than per field, because a composite field
    # mixes values that were recorded with values that were not. A leaf both
    # runs recorded and that differs makes the whole field changed, even when an
    # optional sibling like a base URL is absent: an embedding that moved from
    # 1024 to 768 dimensions is the change a migration comparison exists to
    # detect, and it must not disappear behind an unrecorded endpoint. Only a
    # leaf that one of the runs could not record leaves the field unknown, and
    # the leaves responsible are named so the operator can tell which value is
    # missing rather than being handed an opaque verdict.
    def leafcmp($x; $y):
      if $x == null or $y == null then "unknown"
      elif $x == $y then "same"
      else "changed" end;
    def leafpaths($v):
      [$v | paths] | map(. as $p | select(($v | getpath($p) | type) | . != "object" and . != "array"));
    def leaves($x; $y):
      ((leafpaths($x) + leafpaths($y)) | unique) as $ps
      | if ($ps | length) == 0 then [{path: [], state: leafcmp($x; $y)}]
        else [$ps[] | . as $p
              | {path: $p, state: (try leafcmp($x | getpath($p); $y | getpath($p)) catch "unknown")}]
        end;
    def state($ls):
      if any($ls[]; .state == "changed") then "changed"
      elif any($ls[]; .state == "unknown") then "unknown"
      else "same" end;
    def unrecorded($ls):
      [$ls[] | select(.state == "unknown") | (.path | join(".")) | select(. != "")];
    [
      {key: "eval_set", x: {id: $a.eval_set.id, checksum: $a.eval_set.checksum},
                        y: {id: $b.eval_set.id, checksum: $b.eval_set.checksum}},
      {key: "corpus", x: $a.corpus.revision, y: $b.corpus.revision},
      {key: "gbrain", x: $a.configuration.gbrain_version, y: $b.configuration.gbrain_version},
      {key: "embedding", x: $a.configuration.embedding, y: $b.configuration.embedding},
      {key: "reranker", x: $a.configuration.reranker, y: $b.configuration.reranker},
      {key: "think_model", x: $a.configuration.think.model, y: $b.configuration.think.model},
      {key: "query", x: $a.configuration.query, y: $b.configuration.query}
    ]
    | map(leaves(.x; .y) as $ls | {key: .key, state: state($ls), unrecorded: unrecorded($ls)})
    | . as $fields
    | {
      baseline: {path: $a.eval_set.path, label: $a.run.label, started: $a.run.started},
      candidate: {path: $b.eval_set.path, label: $b.run.label, started: $b.run.started},
      comparable: ($fields | map({key: .key, value: .state}) | from_entries),
      unrecorded: ($fields | map(select((.unrecorded | length) > 0)
                                 | {key: .key, value: .unrecorded}) | from_entries),
      metrics: [
        {metric: "search_top1", baseline: $a.search.top1, candidate: $b.search.top1, delta: d($a.search.top1; $b.search.top1)},
        {metric: "search_topk", baseline: $a.search.topk, candidate: $b.search.topk, delta: d($a.search.topk; $b.search.topk)},
        {metric: "search_mrr", baseline: $a.search.mrr, candidate: $b.search.mrr, delta: d($a.search.mrr; $b.search.mrr)},
        {metric: "think_answered", baseline: $a.think.answered, candidate: $b.think.answered, delta: d($a.think.answered; $b.think.answered)},
        {metric: "think_grounded", baseline: $a.think.grounded, candidate: $b.think.grounded, delta: d($a.think.grounded; $b.think.grounded)},
        {metric: "think_key_facts", baseline: $a.think.key_facts, candidate: $b.think.key_facts, delta: d($a.think.key_facts; $b.think.key_facts)}
      ]
    }')
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$doc"
    return 0
  fi
  printf '%s' "$doc" | jq -r '
    def pct($v): if $v == null then "n/a" else ((($v * 1000 | round) / 10) | tostring) + "%" end;
    def sign($v): if $v == null then "" elif $v > 0 then "+" else "" end;
    "baseline   \(.baseline.label // .baseline.started)",
    "candidate  \(.candidate.label // .candidate.started)",
    "",
    "LIKE-FOR-LIKE",
    (. as $doc | .comparable | to_entries[]
      | "  \(if .value == "same" then "same     " elif .value == "changed" then "CHANGED  " else "UNKNOWN  " end)\(.key)\(if .value == "unknown" and ($doc.unrecorded[.key] // []) != [] then "  (not recorded: " + ($doc.unrecorded[.key] | join(", ")) + ")" else "" end)"),
    (if ([.comparable[] | select(. == "unknown")] | length) > 0 then
      "  UNKNOWN means one of the two runs did not record the value, so this comparison could not be made"
     else empty end),
    "",
    "METRICS",
    (.metrics[] | select(.baseline != null or .candidate != null)
      | "  \(.metric)  \(pct(.baseline)) -> \(pct(.candidate))  (\(sign(.delta))\(pct(.delta)))")'
}

# --- entry ------------------------------------------------------------------

main() {
  need jq
  need sha256sum
  local cmd=${1:-}
  [ $# -gt 0 ] && shift
  case $cmd in
    run) cmd_run "$@" ;;
    validate)
      local set_file=$DEFAULT_SET
      while [ $# -gt 0 ]; do
        case $1 in
          --set) set_file=${2:-}; shift 2 ;;
          -h | --help) usage; return 0 ;;
          *) die 2 "unknown argument: $1" ;;
        esac
      done
      validate_set "$set_file" || exit 2
      printf 'ok %s (%s v%s, %s questions)\n' "$set_file" \
        "$(jq -r '.id' "$set_file")" "$(jq -r '.version' "$set_file")" \
        "$(jq -r '.questions | length' "$set_file")"
      ;;
    compare) cmd_compare "$@" ;;
    -h | --help | help | '') usage ;;
    *) die 2 "unknown command: $cmd" ;;
  esac
}

main "$@"
