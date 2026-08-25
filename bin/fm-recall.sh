#!/usr/bin/env bash
# fm-recall.sh - the retrieval surface firstmate and crewmates use to read a
# brain. Firstmate owns this wrapper so no worker ever calls a raw GBrain
# command: a raw call would resolve whatever brain the caller's directory
# happens to imply, and would report a hosted synthesis failure as a successful
# answer, because GBrain returns a placeholder answer and exit 0 when it has no
# usable model.
#
# bin/fm-gbrain.sh is the OPERATOR surface over the same home (scoping,
# credentials, retirement); docs/gbrain-scoping.md owns the contract both
# implement, and bin/fm-gbrain-lib.sh owns home resolution, the configuration
# planes, and the main-brain token.
#
# Usage:
#   fm-recall.sh search <query...> [--scope local|main|all] [--limit N]
#                                  [--excerpt N] [--json] [--home <dir>]
#                                  [--timeout <seconds>]
#   fm-recall.sh think  <question...> [--max-answer N] [--json] [--home <dir>]
#                                     [--timeout <seconds>]
#
# Commands:
#   search  Retrieval only, and the default way to consult a brain. It stays on
#           this host: the query reaches this home's own index and, when the
#           fleet's main brain is configured and this home holds a read-only
#           client, the main brain's index too. Cite a result as <source>:<slug>.
#   think   Hosted synthesis over THIS home's own brain. It is a separate
#           command rather than a flag on search because it sends the question
#           and the excerpts it selects to the configured hosted provider, so
#           choosing it is a deliberate act. It never reaches the main brain:
#           this wrapper calls think against this home's own brain alone and
#           never over the main brain's read-only client. That is the wrapper's
#           own construction, not a server refusal - GBrain has classified
#           think as a read-scope operation since v0.42.76.0.
#
# Failure separation. The corpora a search reads, and hosted synthesis, fail for
# unrelated reasons and are never reported as one outcome. Each source succeeds,
# degrades, or fails on its own, every one of those verdicts is a row in the
# document, and the exit status reports whether the search as a whole answered:
#   exit 0  a requested corpus answered, whether or not it had a match. Another
#           requested corpus that is stopped, unreachable, or not shared with
#           this home is reported per source as degraded or failed and does not
#           fail the run, because one corpus answering is a real answer.
#   exit 2  usage, or a configuration this command refuses to guess at.
#   exit 3  retrieval failed - NO requested corpus answered. "No match" and
#           "could not be read" are never rendered as the same outcome, so an
#           empty result list with exit 0 means at least one requested corpus
#           was read and had no match; the per-source rows say which were read
#           and which were not.
#   exit 4  HOSTED synthesis is unavailable or produced no answer while local
#           retrieval worked. Every such refusal names `search` as the path that
#           still works.
#   exit 5  SETUP failed - this command could not create the working files it
#           needs, so no corpus was ever reached. That is a third state, not a
#           quiet kind of exit 3: exit 3 means every requested corpus was asked
#           and none answered, while this means none was ever asked. A caller
#           that renders the two alike tells the operator their brain is empty
#           or broken when the truth is that the search never started.
#
# Every query is passed as an argument array and, at the GBrain boundary, as a
# jq-built JSON value. No query text is ever interpolated into a shell command,
# a format string, or a filename, so shell metacharacters in a query are just
# characters to search for.
#
# --json prints one "fm-recall.v1" document: the resolved home, a per-source
# state, an answer framing, and capped results. Human output renders the same
# content as lines.
# Each corpus's results keep the order that corpus returned them in, which is
# its own ranking rather than its raw score column, and two corpora are merged
# by rank: first result of each, then second of each, cycling in the order the
# corpora were read. Scores from different brains are not comparable, so a
# printed score explains one corpus's row and never orders across corpora.
# The printed score is also not that ranking within one corpus: rerank reorders
# rows while leaving the pre-rerank blend in .score, so rank 1 may show a lower
# number than rank 2. Order is the verdict; .score is a blend for that row.
# Each row also carries rerank_score, cosine, evidence, and create_safety when
# GBrain supplied them. rerank_score is the confidence signal; .score is not.
# create_safety is surfaced and is never the miss bit.
#
# Answer protocol. A corpus that was read always answers, and the engine
# essentially always returns rows, including for queries whose topic is absent.
# A non-empty list is therefore not a find. Confidence is judged PER CORPUS:
# each corpus's own pool of returned rows is judged against that corpus's own
# search.autocut_min_top, the weak-top floor GBrain already defines and applies
# to one corpus's top rerank_score. This command does not invent a different
# threshold, and it never judges on the head of the merged list: two brains'
# scores are not the same quantity, so the corpus that happened to lead the
# merge must not decide the other corpus's verdict.
#
# The floor GBrain actually applies comes from the brain's DATABASE plane, so
# that is the only plane a value is accepted from here. A file-plane value is
# one this host can see and the running search does not use, and judging a row
# against it would be a statement about a measurement that never happened. The
# read is lazy, taken only for a corpus whose rows carry a rerank_score and can
# therefore be judged, bounded by a short slice of what is LEFT of the budget
# --timeout granted with the runner's kill grace reserved out of it, and run with
# GBrain's connect retry ladder disabled so a served brain fails fast instead of
# spending clock no caller sanctioned. Anything short of a database answer
# inside that slice is the pinned module default (0.35). The answer object
# discloses, per judged corpus, the floor used and where it came from, so the
# fallback is stated rather than passed off as a setting this command read.
# That fallback is disclosed two ways, because they are two different facts:
# `pinned-default` when the brain was asked and holds no usable value of its
# own, and `unconfirmed-default` when it could not be asked at all and this
# command therefore does not know what the brain applies.
# Only corpora that were actually judged carry a floor.
#
# When a corpus answered, the document carries an `answer` object:
#   nearest  rows are the nearest indexed pages, not answers. A listed page may
#            be unrelated to the query. Absence of a match is not absence of
#            the queried thing. A corpus clears when its own top rerank_score
#            is a number that is not below its own floor, and the corpora that
#            cleared are named in confident_corpora. no_confident_match is true
#            only when NO corpus cleared. A corpus whose rows carry no
#            rerank_score at all is left unjudged rather than counted a miss,
#            it is named as unjudged rather than tied to a floor it was never
#            measured against, and when nothing could be judged the answer
#            carries no verdict. `corpora` carries each corpus's own top
#            rerank_score, whether it was judged, and whether it cleared, while
#            `floors` alone owns the floor and the plane it came from. When one
#            corpus clears and another was judged and fell short, the notice
#            names the one that fell short, so a caller reading only the notice
#            still learns which brain does not hold this.
#   none     the corpus was read and returned no rows. That is absence of an
#            indexed match, never evidence that the queried thing is absent.
# `answer` is omitted when no corpus was read, so a retrieval failure cannot be
# rendered as "not found".
#
# A search in a home whose local index directory exists appends one JSON line
# to state/recall.jsonl recording the query, what the read returned, each
# corpus's own top rerank_score, the rank-1 rerank_score with the corpus it came
# from, and whether the caller was told there was no confident match. The
# disposition names which of four things happened - unread, unjudged, miss, or
# hit - so a corpus that was never read can never serialize as a read that
# returned an unjudgeable row. That is a local record of the read, never of what
# the caller then decided, and nothing is sent anywhere. The query is recorded
# as the text that was asked, so nothing leaves the host but the file does hold
# this home's own private content until it is deleted. think never writes it.
# The file is home-wide and size-capped rather than unbounded: the append and
# the trim that follows it run under one advisory lock, bounded by the run's own
# remaining budget, so concurrent searches cannot overwrite each other's newest
# lines and a record nobody promised is never why a caller's deadline fires.
# The lock directory and the scratch names the trim and the stale sweep leave
# behind when a run is killed mid-section are swept by age on a later search, so
# none of them is a durable artifact and all of them are safe to delete.
# Past the cap the oldest lines are
# dropped and the newest tail is kept, and it is always safe to delete or trim
# because the next search recreates it. A home with no local index writes
# nothing, so a fleet that has not adopted a brain keeps today's path.
# Each local result also carries provenance from this home's capture outbox and
# the live source that outbox was composed from, when those records exist:
#   captured_at        when the outbox revision was marked captured, or null
#   source_state       current | drifted | uncompared | missing | snapshot |
#                      unknown
#   source_kind/id     task or note identity from the slug, or null
#   source_updated_at  newest mtime of the live source files, or null
# source_state for a task is decided from EVIDENCE, and every check answers
# agree, disagree, or "could not run". Two checks can run: the live report still
# ends the way the captured body does, and the report's mtime is no later than
# the capture. Any check that disagrees makes the page drifted, because a live
# source that disagrees wins. Otherwise the page is current only if at least one
# check ran and agreed, and uncompared when none of them could run at all.
# A check that could not run - an unreadable or contentless report tail, a body
# capture truncated or redacted, a capture time that is absent or unparseable,
# an outcome-only task whose only live file is the manifest capture itself
# rewrites - contributes nothing rather than a quiet pass, so current is always
# earned rather than assumed. Uncompared is not a clean bill of health: nothing
# was checked, so it reads with unknown rather than with current.
# It is missing when the outbox names a task whose durable files are gone,
# snapshot for a note (no live file to compare), and unknown when this home
# cannot judge - no outbox, not a Firstmate capture slug, a main-brain row, or
# a provenance pass that ran out of the run's time budget before reaching the
# row. Drifted and missing set stale=true, combined with GBrain's own stale
# flag rather than replacing it. Where a live
# source disagrees with the page, the live source wins and the disagreement is
# surfaced; this command never silently prefers either copy, never drops the
# page, and never rewrites the excerpt from the live file. A home with no
# outbox, and a home with no brain, keep their existing paths: provenance that
# cannot be judged is unknown, and a missing index still fails as retrieval.
# A source's state is one of:
#   ok             it was read, and its results are the rows labelled with it.
#   degraded       the main brain is configured but this read did not reach it,
#                  was refused by it, or had no curl to reach it with.
#   failed         it could not be read at all.
#   absent         no such corpus is configured for this fleet.
#   same-as-local  this home OWNS the main brain, so the main corpus is its own
#                  index: the local row carries the read, and those results are
#                  cited local:<slug>.
#
# Options:
#   --scope     search only. Which corpora to read (default: all).
#   --limit     search only. Results per corpus (default 8, max 50).
#   --excerpt   search only. Characters of matched text per result
#               (default 400, max 4000). The cap is applied here so a wide
#               result set cannot flood a worker's context with one page's body.
#   --max-answer  think only. Characters of synthesis kept (default 8000).
#   --home      the firstmate home whose brain to read.
#   --timeout   seconds allowed for each retrieval call
#               (default: search 60, think 300). It also sizes search's
#               provenance pass, at this budget once per corpus that search
#               will read, so a value tuned down for a fast retrieval also
#               bounds how many rows can be annotated before the rest keep
#               their fail-safe unknown state.
#   --          end of flags, so a query may begin with a dash.
#
# Environment:
#   FM_HOME            active firstmate home; --home overrides it, and with
#                      neither this command uses the home it was invoked from,
#                      refusing when that is a source checkout rather than a home
#   FM_GBRAIN_BIN      gbrain executable (default: gbrain on PATH)
#   FM_RECALL_TIMEOUT  default seconds per retrieval call, overriding the
#                      per-command defaults above
#   FM_GBRAIN_TIMEOUT  seconds allowed for the main brain's token mint, which a
#                      main-scoped or all-scoped search makes before the MCP
#                      read (default 10). The floor read does not use it and is
#                      bounded by the run's own remaining budget instead.
#   FM_RECALL_JSONL_MAX_BYTES  size cap for state/recall.jsonl
#                      (default 262144)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gbrain-lib.sh
. "$SCRIPT_DIR/fm-gbrain-lib.sh"
# shellcheck source=bin/fm-gbrain-capture-lib.sh
. "$SCRIPT_DIR/fm-gbrain-capture-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

GBRAIN_BIN="${FM_GBRAIN_BIN:-gbrain}"
SCHEMA=fm-recall.v1

LIMIT_MAX=50
EXCERPT_MAX=4000
ANSWER_MAX_CEILING=100000
TIMEOUT_MAX=3600
# GBrain owns the weak-top floor and resolves search.autocut_min_top per-call,
# then from the brain's database plane, then from its bundle, so the effective
# value is a property of the brain being read rather than of this wrapper. This
# is DEFAULT_AUTOCUT.minTopScore at the pinned release, used whenever the
# database plane does not answer inside the run's budget, and every use of it is
# disclosed on the answer as a fallback rather than as a setting. Do not replace
# it with a Firstmate-invented value.
AUTOCUT_MIN_TOP_DEFAULT=0.35

# state/recall.jsonl is home-wide and append-only, so it needs a bound rather
# than an owner that removes it. Past the cap the oldest lines go and the newest
# tail stays, which keeps the newest read and makes the file safe to delete.
RECALL_JSONL_MAX_BYTES=${FM_RECALL_JSONL_MAX_BYTES:-262144}
case $RECALL_JSONL_MAX_BYTES in '' | *[!0-9]* | 0) RECALL_JSONL_MAX_BYTES=262144 ;; esac

usage() { awk 'NR == 1 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }

# Every refusal leaves the same shape behind, so a caller parsing --json never
# has to tell a structured result from an unstructured death.
JSON_MODE=0
COMMAND=unknown

die() {  # <exit-code> <error-code> <message>
  local code=$1 err=$2 msg=$3
  if [ "$JSON_MODE" -eq 1 ] && command -v jq >/dev/null 2>&1; then
    jq -n --arg s "$SCHEMA" --arg c "$COMMAND" --arg e "$err" --arg m "$msg" \
      '{schema: $s, command: $c, error: {code: $e, message: $m}}'
  else
    printf 'fm-recall: %s\n' "$msg" >&2
  fi
  exit "$code"
}

require_tool() {  # <tool>
  command -v "$1" >/dev/null 2>&1 || die 2 missing_tool "$1 is not installed"
}

# --- argument parsing -------------------------------------------------------
#
# Positional words are joined into one query with single spaces, so a crewmate
# can write the question the way it reads. "--" ends flag parsing, which is what
# makes a query that legitimately starts with a dash expressible.

HOME_ARG=""
SCOPE=all
LIMIT=8
EXCERPT=400
ANSWER_MAX=8000
TIMEOUT=""
QUERY_WORDS=()
SET_SCOPE=0
SET_LIMIT=0
SET_EXCERPT=0
SET_ANSWER=0

bounded_int() {  # <value> <flag> <max>
  case $1 in
    '' | *[!0-9]* ) die 2 bad_argument "$2 requires a positive integer" ;;
  esac
  [ "$1" -gt 0 ] || die 2 bad_argument "$2 requires a positive integer"
  [ "$1" -le "$3" ] || die 2 bad_argument "$2 must not exceed $3"
}

# --json decides how a refusal is rendered, so it is honored before any other
# argument can be refused.
prescan_json() {
  local a
  for a in "$@"; do
    [ "$a" = -- ] && return 0
    [ "$a" = --json ] && JSON_MODE=1
  done
  return 0
}

parse_args() {
  local end_of_flags=0 want=""
  while [ $# -gt 0 ]; do
    if [ -n "$want" ]; then
      case $want in
        home) HOME_ARG=$1 ;;
        scope) SCOPE=$1; SET_SCOPE=1 ;;
        limit) bounded_int "$1" --limit "$LIMIT_MAX"; LIMIT=$1; SET_LIMIT=1 ;;
        excerpt) bounded_int "$1" --excerpt "$EXCERPT_MAX"; EXCERPT=$1; SET_EXCERPT=1 ;;
        max-answer) bounded_int "$1" --max-answer "$ANSWER_MAX_CEILING"; ANSWER_MAX=$1; SET_ANSWER=1 ;;
        timeout) bounded_int "$1" --timeout "$TIMEOUT_MAX"; TIMEOUT=$1 ;;
      esac
      want=""
      shift
      continue
    fi
    if [ "$end_of_flags" -eq 1 ]; then
      QUERY_WORDS+=("$1"); shift; continue
    fi
    case $1 in
      --) end_of_flags=1 ;;
      --json) : ;;
      --home | --scope | --limit | --excerpt | --max-answer | --timeout) want=${1#--} ;;
      --home=* | --scope=* | --limit=* | --excerpt=* | --max-answer=* | --timeout=*)
        set -- "${1%%=*}" "${1#*=}" "${@:2}"
        continue
        ;;
      -h | --help) usage; exit 0 ;;
      -*) die 2 bad_argument "unknown flag: $1" ;;
      *) QUERY_WORDS+=("$1") ;;
    esac
    shift
  done
  [ -z "$want" ] || die 2 bad_argument "--$want requires a value"
}

# A flag that does nothing for the command it was passed to is refused rather
# than dropped, so nobody believes a cap was applied that never was.
refuse_flag() {  # <was-set> <flag> <command>
  [ "$1" -eq 0 ] || die 2 bad_argument "$2 applies to $3, not to $COMMAND"
}

joined_query() {
  local out="" word
  for word in ${QUERY_WORDS[@]+"${QUERY_WORDS[@]}"}; do
    if [ -z "$out" ]; then out=$word; else out="$out $word"; fi
  done
  printf '%s' "$out"
}

# --- resolved home and configuration ----------------------------------------

HOME_PATH=""
EMBED_URL=""
MAIN_MCP_URL=""

resolve_context() {
  local shared
  fm_gbrain_resolve_home "$HOME_ARG" "$FM_ROOT" || die 2 no_home "$FM_GBRAIN_ERROR"
  HOME_PATH=$FM_GBRAIN_HOME_PATH
  shared=$(fm_gbrain_shared_path "$HOME_PATH")
  fm_gbrain_validate_shared "$shared" || die 2 bad_config "$HOME_PATH: $FM_GBRAIN_ERROR"
  fm_gbrain_resolve_paths "$HOME_PATH" || die 2 bad_config "$HOME_PATH: $FM_GBRAIN_ERROR"
  EMBED_URL=$(fm_gbrain_json_str "$shared" '.local.embedding_base_url')
  MAIN_MCP_URL=$(fm_gbrain_json_str "$shared" '.main_brain.mcp_url')
}

# --- the shape a retrieval reply must have ----------------------------------
#
# A reply is unreadable in two different ways, and each has one owner here
# rather than a copy per leg, because a rule written once per leg is a rule the
# next leg is added without.
#
# Structure is REFUSED. A renderer that indexes an unexpected shape by name dies
# mid-document with a raw jq error, which is neither a structured refusal nor an
# honest per-source verdict, so every value a renderer indexes is constrained
# below. The reply is validated by the SAME name that selects the operation, so
# no call site picks its own contract or forgets one, and an operation with no
# contract here is refused rather than waved through.
reply_shape_ok() {  # <operation> <json>
  local predicate
  case $1 in
    search) predicate='type == "array" and all(.[]; type == "object")' ;;
    think) predicate='type == "object"
                      and ((.citations // []) | type == "array" and all(.[]; type == "object"))
                      and ((.warnings // []) | type == "array")' ;;
    *) return 1 ;;
  esac
  printf '%s' "$2" | jq -e "$predicate" >/dev/null 2>&1
}

# A field's TYPE is coerced. Every renderer prefixes this, so neither command
# can be total in a way the other is not: a field of an unexpected type is a
# value worth less, never a document that cannot be produced.
JQ_RENDER_PRELUDE='
  def text(v): if v == null then "" elif (v | type) == "string" then v else (v | tostring) end;
  def capped(v; cap): text(v) | if length > cap then .[0:cap] + "..." else . end;
'

# --- the local leg ----------------------------------------------------------
#
# `gbrain call <tool> <json>` is GBrain's trusted local dispatch surface and
# returns the operation's own JSON, so the query crosses this boundary as a JSON
# string inside one argv element. GBrain does not persist the command-scoped
# embedding endpoint (docs/gbrain.md), so it is supplied per call.

LOCAL_OUT=""
LOCAL_ERR=""
# Set by any leg that could not create its own working files. It is tracked
# apart from the per-source detail because it changes the exit status of the
# whole run: a corpus that was never asked is not a corpus that did not answer.
SETUP_FAILED=0
SETUP_DETAIL=""

setup_failure() {  # <detail>
  SETUP_FAILED=1
  [ -n "$SETUP_DETAIL" ] || SETUP_DETAIL=$1
}

# The only place this command asks for scratch space, so the exit-5 contract
# cannot drift as legs are added: a leg either gets a path back or the setup
# failure is already recorded by the time this returns non-zero, and the
# sentence the operator reads is written once.
RECALL_SCRATCH=""
RECALL_SCRATCH_ERR=""
recall_scratch_file() {  # <what-was-never-asked> -> 0 with RECALL_SCRATCH set
  local never_asked=$1
  RECALL_SCRATCH=""; RECALL_SCRATCH_ERR=""
  if RECALL_SCRATCH=$(mktemp "${TMPDIR:-/tmp}/fm-recall.XXXXXX"); then
    return 0
  fi
  RECALL_SCRATCH=""
  RECALL_SCRATCH_ERR="could not create a temporary file in ${TMPDIR:-/tmp}, so $never_asked was never asked"
  setup_failure "$RECALL_SCRATCH_ERR"
  return 1
}
# Set by a caller that must hand a hosted credential to exactly one process.
# gbrain_local_call exports it for that call only; the caller clears it after.
GBRAIN_CALL_HOSTED_KEY=""

gbrain_local_call() {  # <tool> <params-json> <seconds> -> 0
  local tool=$1 params=$2 secs=$3 out_file err_file rc=0
  LOCAL_OUT=""; LOCAL_ERR=""
  recall_scratch_file "this home's index" || { LOCAL_ERR=$RECALL_SCRATCH_ERR; return 1; }
  out_file=$RECALL_SCRATCH
  recall_scratch_file "this home's index" || {
    rm -f "$out_file"; LOCAL_ERR=$RECALL_SCRATCH_ERR; return 1
  }
  err_file=$RECALL_SCRATCH
  (
    export GBRAIN_HOME="$FM_GBRAIN_HOME_DIR"
    [ -z "$EMBED_URL" ] || export OLLAMA_BASE_URL="$EMBED_URL"
    [ -z "$GBRAIN_CALL_HOSTED_KEY" ] || export MINIMAX_API_KEY="$GBRAIN_CALL_HOSTED_KEY"
    fm_run_timed "$secs" "$GBRAIN_BIN" call "$tool" "$params"
  ) >"$out_file" 2>"$err_file" || rc=$?
  LOCAL_OUT=$(cat "$out_file")
  LOCAL_ERR=$(tr -s '[:space:]' ' ' < "$err_file")
  LOCAL_ERR=${LOCAL_ERR# }; LOCAL_ERR=${LOCAL_ERR% }
  rm -f "$out_file" "$err_file"
  case $rc in
    0) ;;
    124|137) LOCAL_ERR="the local brain did not answer within ${secs}s"; return 1 ;;
    125) LOCAL_ERR="no timeout implementation on PATH, so this call cannot be bounded"; return 1 ;;
    *) [ -n "$LOCAL_ERR" ] || LOCAL_ERR="gbrain exited $rc"; return 1 ;;
  esac
  if ! reply_shape_ok "$tool" "$LOCAL_OUT"; then
    LOCAL_ERR="gbrain returned a $tool result this command cannot read"
    return 1
  fi
  return 0
}

# --- the main-brain leg -----------------------------------------------------
#
# The main brain is read over GBrain's own HTTP MCP transport with this home's
# read-scoped token, which is what makes the share read-only
# (docs/gbrain-scoping.md). A response may arrive as JSON or as an SSE stream,
# so both shapes are unpacked.

MAIN_OUT=""
MAIN_ERR=""

# Sets MAIN_OUT rather than printing it: a command substitution would lose
# MAIN_ERR to the subshell, which is exactly the failure detail the caller needs.
mcp_unpack() {  # <raw-body> -> 0 with MAIN_OUT set
  local raw=$1 envelope text
  MAIN_OUT=""
  if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    envelope=$raw
  else
    envelope=$(printf '%s\n' "$raw" \
      | sed -n 's/^data: //p' \
      | jq -c -s 'map(select(type == "object" and (has("result") or has("error")))) | last // empty' 2>/dev/null) \
      || envelope=""
  fi
  if [ -z "$envelope" ]; then
    MAIN_ERR="the main brain returned a response this command cannot read"
    return 1
  fi
  if printf '%s' "$envelope" | jq -e 'has("error")' >/dev/null 2>&1; then
    MAIN_ERR=$(printf '%s' "$envelope" | jq -r '.error.message // (.error | tostring)')
    return 1
  fi
  text=$(printf '%s' "$envelope" | jq -r '.result.content[0].text // empty')
  if [ -z "$text" ]; then
    MAIN_ERR="the main brain returned an empty result"
    return 1
  fi
  if printf '%s' "$envelope" | jq -e '.result.isError == true' >/dev/null 2>&1; then
    MAIN_ERR=$(printf '%s' "$text" | jq -r '"\(.error // "refused") \(.message // "")"' 2>/dev/null) \
      || MAIN_ERR="the main brain refused the read"
    return 1
  fi
  if ! reply_shape_ok search "$text"; then
    MAIN_ERR="the main brain returned a result this command cannot read"
    return 1
  fi
  MAIN_OUT=$text
  return 0
}

main_brain_search() {  # <query> <limit> <seconds> -> 0 with MAIN_OUT set
  local query=$1 limit=$2 secs=$3 body_file raw rc=0
  MAIN_OUT=""; MAIN_ERR=""
  if ! fm_gbrain_mint_token "$HOME_PATH"; then
    MAIN_ERR=$FM_GBRAIN_ERROR
    return 1
  fi
  recall_scratch_file "the main brain" || {
    FM_GBRAIN_TOKEN=""; MAIN_ERR=$RECALL_SCRATCH_ERR; return 1
  }
  body_file=$RECALL_SCRATCH
  jq -cn --arg q "$query" --argjson n "$limit" \
    '{jsonrpc: "2.0", id: 1, method: "tools/call",
      params: {name: "search", arguments: {query: $q, limit: $n}}}' > "$body_file"
  # The bearer token travels through a stdin config file, so it never appears in
  # this process's arguments and cannot be read from the process table.
  raw=$(printf 'header = "Authorization: Bearer %s"\n' "$FM_GBRAIN_TOKEN" \
    | curl -sS -m "$secs" -K - -X POST "$MAIN_MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      --data-binary "@$body_file" 2>/dev/null) || rc=$?
  FM_GBRAIN_TOKEN=""
  rm -f "$body_file"
  if [ "$rc" -ne 0 ]; then
    MAIN_ERR="the main brain did not answer at $MAIN_MCP_URL"
    return 1
  fi
  mcp_unpack "$raw" || return 1
  return 0
}

# --- shaping results --------------------------------------------------------

# One GBrain result row becomes one citable line, through the shared coercion so
# a row whose slug is a number or whose score arrived as a string is still
# rendered and still citable rather than aborting the whole read.
shape_results() {  # <source> <results-json> <excerpt-chars>
  jq -c --arg src "$1" --argjson cap "$3" "$JQ_RENDER_PRELUDE"'
    [ .[]? | {
        source: $src,
        citation: ($src + ":" + (if .slug == null or .slug == "" then "?" else text(.slug) end)),
        slug: text(.slug),
        title: text(.title),
        score: (if (.score | type) == "number" then .score else null end),
        rerank_score: (if (.rerank_score | type) == "number" then .rerank_score else null end),
        cosine: (if (.cosine | type) == "number" then .cosine else null end),
        evidence: (if .evidence == null then null else text(.evidence) end),
        create_safety: (if .create_safety == null then null else text(.create_safety) end),
        stale: (.stale == true),
        excerpt: capped(.chunk_text; $cap)
      } ]
  ' <<EOF
$2
EOF
}

# Provenance is judged from this home's capture outbox and the live source that
# outbox was composed from. It is presentation: it never changes result order,
# never drops a row, and never rewrites an excerpt from the live file.
ANSWER_NEAREST_NOTICE='These are the nearest indexed pages, not answers. A listed page may be unrelated to the query. No indexed match is not evidence that the queried thing is absent. Order is the brain ranking; score is a pre-rerank blend; rerank_score is the confidence signal. Where a live source disagrees with a page, the live source wins.'
# The weak and confident notices are assembled around the floors this run
# actually judged against, so a retuned knob can never leave a notice quoting a
# floor the code no longer uses.
ANSWER_WEAK_HEAD='No confident match. Top rerank_score stayed below search.autocut_min_top in '
ANSWER_WEAK_MID=' ('
ANSWER_WEAK_AFTER=').'
ANSWER_WEAK_TAIL=' These are still the nearest indexed pages, not answers. A listed page may be unrelated to the query. No confident match is not evidence that the queried thing is absent. Where a live source disagrees with a page, the live source wins.'
ANSWER_CONFIDENT_HEAD='Confident match in '
ANSWER_CONFIDENT_MID=', judged against search.autocut_min_top ('
ANSWER_CONFIDENT_TAIL='). '
# When one corpus clears and another was judged and fell short, the caller is
# told which one fell short: that a sibling brain holds this and the corpus that
# missed does not is the actionable half of a mixed read, and the notice is the
# only surface a whitelisting consumer renders. A corpus that was never judged
# is not named here, because it was never measured against a floor at all.
ANSWER_SHORTFALL_HEAD='Judged and short of its own floor: '
ANSWER_SHORTFALL_TAIL='. '
# A corpus that stamped no rerank_score was never measured against a floor, so
# it is named as unjudged rather than folded into a sentence about floors.
ANSWER_UNJUDGED_HEAD=' Not judged at all, because no returned row carried a rerank_score: '
ANSWER_UNJUDGED_TAIL='.'
ANSWER_NONE_NOTICE='No indexed match. That is absence of a match in this brain, not evidence that the queried thing is absent.'

recall_stat_mtime() {  # <path> -> epoch seconds, or empty
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null || true
  else
    stat -c %Y "$1" 2>/dev/null || true
  fi
}

# The two date dialects collide in both directions, so neither form is ever
# tried as a fallthrough from the other. On BSD `-d` is the daylight-saving
# flag, not a date to parse, and a build that does not validate its argument
# answers with the CURRENT time instead of failing - which would silently make
# every capture look newer than every report and retire the drift rule.
recall_iso_epoch() {  # <YYYY-MM-DDTHH:MM:SSZ> -> epoch seconds, or empty
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || true
  else
    date -u -d "$1" +%s 2>/dev/null || true
  fi
}

# The mirror image: BSD date reads an epoch with -r, while GNU date reads a
# FILE's mtime with -r and an epoch with -d @. This command runs from an
# arbitrary working directory, and a file there named for the epoch integer
# would answer with its own mtime.
recall_epoch_iso() {  # <epoch> -> ISO-8601 UTC, or empty
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true
  else
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true
  fi
}

recall_regular_file() {  # <path> -> 0 when it is a regular non-symlink file
  [ -f "$1" ] && [ ! -L "$1" ]
}

# One provenance object for a slug this home cannot judge. Kind and id are null
# rather than echoed back, because a slug that failed the address checks has not
# earned the claim that it names a task or a note this home owns.
provenance_unknown() {  # <slug> [<kind> <id>]
  jq -cn --arg slug "$1" --arg kind "${2:-}" --arg id "${3:-}" \
    '{slug:$slug, captured_at:null, source_state:"unknown",
      source_kind:(if $kind == "" then null else $kind end),
      source_id:(if $id == "" then null else $id end),
      source_updated_at:null, stale_from_source:false}'
}

# --- currency: what evidence is there that a page still matches its source ---
#
# Every check below answers with EVIDENCE, not with a verdict, and the vocabulary
# has three words:
#
#   agree     the check ran and the page still matches the live source
#   disagree  the check ran and the page does not match the live source
#   none      the check could not run, and therefore says nothing either way
#
# `none` is the default of every check, and it is not a quiet `agree`. A check
# that could not read its input, could not parse its input, or was handed inputs
# that are not comparable produces `none`, so the only way to reach `agree` is
# for a comparison to have actually happened and actually matched. That is the
# whole shape: `current` is earned by evidence rather than assumed in its
# absence, so a path nobody thought of degrades to "nothing was checked" rather
# than to "this page is fine".
#
# recall_currency_verdict is the single owner that turns the collected evidence
# into a state, and it is the only producer of `current` in this file.

# Does the live report still end the way the captured body does?
#
# The stored body is not a verbatim copy of the report: capture composes
# frontmatter in front of it, truncates the composed document at
# FM_GBRAIN_CAPTURE_MAX_BYTES, and rewrites credential-shaped values before any
# byte reaches disk. A tail that is absent for one of those reasons is not
# evidence that the report changed - and a tail that could not be read at all is
# not evidence that it did not, so both answer `none`.
#
# The comparison is taken in CHARACTERS, not bytes. A byte-sized cut lands inside
# a multi-byte character often enough to matter, and the orphaned continuation
# bytes decode to U+FFFD, which matches nothing in a body that was stored intact.
recall_content_evidence() {  # <item-json> <report-path> -> agree | disagree | none
  local item=$1 report=$2 max=${FM_GBRAIN_CAPTURE_MAX_BYTES:-65536} size verdict
  size=$(wc -c < "$report" 2>/dev/null | tr -cd '0-9') || size=""
  [ -n "$size" ] || size=0
  verdict=$(printf '%s' "$item" | jq -r \
    --rawfile tail <(tail -c 4000 "$report" 2>/dev/null || true) \
    --argjson max "$max" --argjson size "$size" '
      ($tail[-200:] | sub("\\s+$"; "")) as $fp
      | if ($fp | length) == 0 then "none"
        elif (.body | index($fp)) != null then "agree"
        elif ((.redactions | length) > 0)
          or ((.body | utf8bytelength) >= $max)
          or ($size >= $max) then "none"
        else "disagree"
        end' 2>/dev/null) || verdict=""
  case $verdict in
    agree | disagree) printf '%s\n' "$verdict" ;;
    *) printf 'none\n' ;;
  esac
}

# Was the live source last written no later than the capture that copied it?
#
# Both sides have to be readable integers for this to say anything: an epoch this
# command could not stat and a capture time it could not parse are each a reason
# the check did not run, never a reason to call the page current.
recall_mtime_evidence() {  # <live-epoch> <captured-at> -> agree | disagree | none
  local live=${1:-} captured=${2:-} cap_epoch
  case $live in '' | *[!0-9]*) printf 'none\n'; return 0 ;; esac
  [ "$live" -gt 0 ] || { printf 'none\n'; return 0; }
  [ -n "$captured" ] || { printf 'none\n'; return 0; }
  cap_epoch=$(recall_iso_epoch "$captured")
  case $cap_epoch in '' | *[!0-9]*) printf 'none\n'; return 0 ;; esac
  if [ "$live" -gt "$cap_epoch" ]; then printf 'disagree\n'; else printf 'agree\n'; fi
}

# The single owner of the currency question, and the only producer of `current`.
#
# One check disagreeing is enough to mark the page drifted, because the live
# source wins on disagreement. `current` needs a check that ran and agreed; with
# no agreeing check the answer is `uncompared`, which is what "no evidence"
# means and is never read as a clean bill of health.
recall_currency_verdict() {  # <evidence...> -> current | drifted | uncompared
  local piece agreed=0
  for piece in "$@"; do
    case $piece in
      disagree) printf 'drifted\n'; return 0 ;;
      agree) agreed=1 ;;
    esac
  done
  if [ "$agreed" -eq 1 ]; then printf 'current\n'; else printf 'uncompared\n'; fi
}

# Emit one provenance object for a local slug. Always succeeds with JSON so a
# missing outbox cannot abort a search that already answered.
provenance_for_slug() {  # <data-dir> <slug>
  local data=$1 slug=$2
  local prefix tag kind id extra
  local doc_id item captured_at source_kind source_id
  local report outcome live_epoch=0 file_epoch evidence=()
  local source_state=unknown source_updated_at="" stale_from_source=false
  IFS=/ read -r prefix tag kind id extra <<EOF
$slug
EOF
  if [ "$prefix" != firstmate ] || [ -z "$tag" ] || [ -z "$id" ] || [ -n "${extra:-}" ] \
      || { [ "$kind" != task ] && [ "$kind" != note ]; } \
      || ! fm_gbrain_capture_source_id_valid "$id"; then
    provenance_unknown "$slug"
    return 0
  fi
  # The home tag arrives inside a slug the brain returned, and it becomes a path
  # component of the outbox record this reads. The parse above rejects a slug
  # carrying an extra "/", but that is incidental to splitting the slug rather
  # than a guarantee about the tag, so the document id is shape-checked with the
  # library's own guard before it addresses a file.
  doc_id=$(fm_gbrain_capture_document_id "$tag" "$kind" "$id")
  if ! fm_gbrain_capture_document_id_valid "$doc_id"; then
    provenance_unknown "$slug"
    return 0
  fi
  source_kind=$kind
  source_id=$id
  item=$(fm_gbrain_capture_item_read "$data" "$doc_id" 2>/dev/null) || item=""
  if [ -z "$item" ]; then
    provenance_unknown "$slug" "$source_kind" "$source_id"
    return 0
  fi
  captured_at=$(printf '%s' "$item" | jq -r '.captured_at // empty')
  if [ "$kind" = note ]; then
    jq -cn --arg slug "$slug" --arg kind "$source_kind" --arg id "$source_id" \
      --arg captured "${captured_at:-}" \
      '{slug:$slug, captured_at:(if $captured == "" then null else $captured end),
        source_state:"snapshot", source_kind:$kind, source_id:$id,
        source_updated_at:null, stale_from_source:false}'
    return 0
  fi

  report="$data/$id/report.md"
  outcome="$data/$id/outcome.json"
  # Capture republishes the outcome manifest in the same second as captured_at,
  # so that file's mtime is not a freshness signal. The report is. Outcome-only
  # tasks have no later editable source on disk once teardown finished.
  if recall_regular_file "$report"; then
    file_epoch=$(recall_stat_mtime "$report")
    if [ -n "$file_epoch" ] && [ "$file_epoch" -gt "$live_epoch" ]; then
      live_epoch=$file_epoch
    fi
    evidence+=("$(recall_content_evidence "$item" "$report")")
    evidence+=("$(recall_mtime_evidence "$live_epoch" "$captured_at")")
  else
    # An outcome-only task contributes NO evidence. Its only live file is the
    # manifest capture republishes around captured_at, so comparing against it
    # would answer with capture's own timestamp rather than with the source.
    # Having nothing to compare is not a comparison that passed.
    if recall_regular_file "$outcome"; then
      file_epoch=$(recall_stat_mtime "$outcome")
      if [ -n "$file_epoch" ]; then
        live_epoch=$file_epoch
      fi
    fi
  fi

  if [ "$live_epoch" -eq 0 ]; then
    source_state=missing
    stale_from_source=true
  else
    source_updated_at=$(recall_epoch_iso "$live_epoch")
    source_state=$(recall_currency_verdict ${evidence[@]+"${evidence[@]}"})
    [ "$source_state" != drifted ] || stale_from_source=true
  fi
  jq -cn --arg slug "$slug" --arg kind "$source_kind" --arg id "$source_id" \
    --arg captured "${captured_at:-}" --arg state "$source_state" \
    --arg updated "${source_updated_at:-}" --argjson stale "$stale_from_source" \
    '{slug:$slug,
      captured_at:(if $captured == "" then null else $captured end),
      source_state:$state, source_kind:$kind, source_id:$id,
      source_updated_at:(if $updated == "" then null else $updated end),
      stale_from_source:$stale}'
}

# The run's wall-clock ceiling, as bash's own second counter: the per-call
# retrieval budget once per leg the run will read. Empty means no ceiling, which
# is what a caller that never set one, or set one this command cannot compute
# with, gets.
RECALL_DEADLINE=""

annotate_search_results() {  # <results-json> <home> -> annotated results json
  local results=$1 home=$2
  local data="$home/data"
  local meta slug
  # Each slug's provenance is one JSON line and the whole stream is folded once.
  # Re-reading and re-serialising the accumulated array per slug is quadratic on
  # a path the dashboard runs under a time budget, at the CLI's cap of 50 rows.
  #
  # Provenance is read from the filesystem AFTER both corpora have answered, so
  # without a ceiling it is unbounded time added to a run a caller already
  # budgeted - and a caller that kills the run gets no answer at all, throwing
  # away results that were successfully retrieved. The run's own budget bounds
  # it: past the deadline the remaining rows keep the fail-safe state this
  # design already defines, so a slow filesystem costs provenance, never the
  # answer.
  meta=$(
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      if [ -n "$RECALL_DEADLINE" ] && [ "$SECONDS" -ge "$RECALL_DEADLINE" ]; then break; fi
      provenance_for_slug "$data" "$slug"
    done < <(printf '%s' "$results" | jq -r '[.[] | select(.source == "local") | .slug] | unique[]') \
      | jq -c -s '.'
  )
  jq -c --argjson meta "$meta" '
    ($meta | map({key: .slug, value: .}) | from_entries) as $by
    | map(
        . as $row
        | (if $row.source == "local" then ($by[$row.slug] // null) else null end) as $p
        | .captured_at = (if $p == null then null else $p.captured_at end)
        | .source_state = (if $p == null then "unknown" else $p.source_state end)
        | .source_kind = (if $p == null then null else $p.source_kind end)
        | .source_id = (if $p == null then null else $p.source_id end)
        | .source_updated_at = (if $p == null then null else $p.source_updated_at end)
        | .stale = ((.stale == true) or ($p != null and $p.stale_from_source == true))
      )
  ' <<EOF
$results
EOF
}

# Two corpora are merged by RANK, never by score, and each corpus's own order is
# left exactly as it arrived. A brain's returned order is its verdict, not its
# raw score: reranking runs inside the brain, so its ordering carries a
# contribution no score column exposes, and re-sorting on that column throws it
# away. Two brains' scores are not the same quantity either - different
# embedding models, different rerankers, different corpora - so comparing them
# ranks on a number that only looks shared.
#
# What IS comparable is each brain's own opinion of its own results, so the
# merge takes the first result of every corpus, then the second of every corpus,
# and so on. A corpus that runs out drops out and the rest keep their order.
# Corpora are cycled in the order they were read, which puts this home's own
# index first on an equal rank, because a home is accountable for what it wrote.
#
# The single-corpus case needs no special rule: interleaving one list returns it
# unchanged, so a lone corpus is never reordered at all.
# shellcheck disable=SC2016  # jq program text; $rows/$order/$r/$s are jq variables
JQ_MERGE_BY_RANK='
  def merge_by_rank:
    . as $rows
    | (reduce $rows[] as $r ([]; if (index($r.source) == null) then . + [$r.source] else . end)) as $order
    | [ ($order | to_entries[]) as $s
        | ($rows | map(select(.source == $s.value)) | to_entries[])
        | {rank: .key, corpus: $s.key, row: .value} ]
    | sort_by(.rank, .corpus)
    | map(.row);
'

# A row's count is the number of entries in `.results` that carry its source, so
# summing the rows can never disagree with the list they describe.
source_row() {  # <source> <state> <brain> <count> [detail]
  jq -cn --arg s "$1" --arg st "$2" --arg b "$3" --argjson n "$4" --arg d "${5:-}" '
    {source: $s, state: $st, brain: $b, results: $n}
    + (if $d == "" then {} else {detail: $d} end)
  '
}

# Each corpus is judged against its OWN returned pool and its OWN effective
# floor, which is the quantity GBrain applies search.autocut_min_top to. The
# head of the merged list is not that quantity: the merge interleaves by rank
# and puts this home's own index first on an equal rank, so a verdict taken
# from merged rank 1 would let the local corpus decide the main brain's
# verdict, and a confident fleet answer sitting at position 2 would be
# announced as no confident match. Taking the maximum across the merged list
# would be just as wrong in the other direction, because two brains' rerank
# scores are different quantities and are not comparable to each other.
#
# A corpus clears when its own top rerank_score is a number that is not below
# its floor, so a score equal to the floor is not a miss. The read is a miss
# only when NO corpus cleared. A corpus whose pool carries no rerank_score at
# all is left UNJUDGED rather than counted a miss: this command does not invent
# a signal GBrain did not stamp, and it does not name a floor that corpus was
# never measured against. `corpora` carries what each corpus was judged on and
# `floors` carries the floor each JUDGED corpus was judged against, so a caller
# can tell a miss that covered every brain from one where a brain with its
# reranker off was never judged. create_safety is never consulted.
search_answer_json() {  # <results-json> <floors-json> -> answer object
  jq -c --argjson floor_input "$2" \
    --argjson default_floor "$AUTOCUT_MIN_TOP_DEFAULT" \
    --arg nearest "$ANSWER_NEAREST_NOTICE" \
    --arg weak_head "$ANSWER_WEAK_HEAD" \
    --arg weak_mid "$ANSWER_WEAK_MID" \
    --arg weak_after "$ANSWER_WEAK_AFTER" \
    --arg weak_tail "$ANSWER_WEAK_TAIL" \
    --arg conf_head "$ANSWER_CONFIDENT_HEAD" \
    --arg conf_mid "$ANSWER_CONFIDENT_MID" \
    --arg conf_tail "$ANSWER_CONFIDENT_TAIL" \
    --arg shortfall_head "$ANSWER_SHORTFALL_HEAD" \
    --arg shortfall_tail "$ANSWER_SHORTFALL_TAIL" \
    --arg unjudged_head "$ANSWER_UNJUDGED_HEAD" \
    --arg unjudged_tail "$ANSWER_UNJUDGED_TAIL" \
    --arg none "$ANSWER_NONE_NOTICE" '
    def where($source):
      if $source == "db-config" then "the brain database plane"
      elif $source == "pinned-default" then "the pinned GBrain default this brain has not overridden"
      else "the pinned GBrain default, standing in for a floor this command could not read from that brain" end;
    def floor_for($corpus):
      ([$floor_input[] | select(.corpus == $corpus)] | .[0] | .autocut_min_top)
      // $default_floor;
    def render($floors):
      $floors
      | map(.corpus + " " + (.autocut_min_top | tostring) + " from " + where(.source))
      | join(", ");
    . as $rows
    | if ($rows | length) == 0 then
        {kind: "none", notice: $none, no_confident_match: true,
         confident_corpora: [], corpora: [], floors: []}
      else
        [ ([$rows[].source] | unique)[] as $corpus
          | ([$rows[] | select(.source == $corpus) | .rerank_score
              | select(type == "number")]
             | if length == 0 then null else max end) as $top
          | {corpus: $corpus,
             top_rerank_score: $top,
             judged: ($top != null),
             cleared: ($top != null and $top >= floor_for($corpus))} ] as $corpora
        | [$corpora[] | select(.judged) | .corpus] as $judged_names
        | [$corpora[] | select(.judged | not) | .corpus] as $unjudged_names
        | [$corpora[] | select(.cleared) | .corpus] as $cleared
        | [$floor_input[] | select(.corpus as $c | $judged_names | index($c))] as $floors
        | [$corpora[] | select(.judged and (.cleared | not)) | .corpus] as $short
        | (if ($unjudged_names | length) == 0 then ""
           else $unjudged_head + ($unjudged_names | join(" and ")) + $unjudged_tail
           end) as $unjudged_text
        | (if ($cleared | length) == 0 or ($short | length) == 0 then ""
           else $shortfall_head + ($short | join(" and ")) + $shortfall_tail
           end) as $shortfall_text
        | if ($cleared | length) > 0 then
            {kind: "nearest",
             notice: ($conf_head + ($cleared | join(" and ")) + $conf_mid
                      + render($floors) + $conf_tail + $shortfall_text
                      + $nearest + $unjudged_text),
             no_confident_match: false,
             confident_corpora: $cleared,
             corpora: $corpora,
             floors: $floors}
          elif ($judged_names | length) > 0 then
            {kind: "nearest",
             notice: ($weak_head + ($judged_names | join(" and ")) + $weak_mid
                      + render($floors) + $weak_after + $unjudged_text + $weak_tail),
             no_confident_match: true,
             confident_corpora: [],
             corpora: $corpora,
             floors: $floors}
          else
            {kind: "nearest", notice: $nearest, corpora: $corpora, floors: []}
          end
      end
  ' <<EOF
$1
EOF
}

# The floor GBrain actually applies lives in the brain's DATABASE plane. At the
# pinned release `applyAutocut` is handed `resolvedMode.autocut_min_top`, which
# `loadSearchModeConfig` resolves through `engine.getConfig` alone, and that is
# the DB `config` table; the nested file-plane shape has one reader in the pin
# and nothing calls it. `gbrain config get` reports the file/env plane ahead of
# the database, so its answer is NOT the floor unless it says the database
# answered. This command therefore accepts a value only from the db plane: a
# file-plane number is a value this host can see, never a value the search used,
# and judging a row against it would be the false statement this surface exists
# to avoid.
#
# The read is an engine connect, so it is fenced three ways. It is lazy, taken
# only when the local corpus returned rows that CAN be judged, meaning rows that
# carry a rerank_score. It is bounded by a short slice of what is LEFT of the
# budget the caller granted, with the runner's kill grace reserved out of that
# remainder, so the run's real ceiling stays at the deadline rather than one
# grace past it. And it disables GBrain's connect retry ladder, because on a
# home whose brain is being served the daemon holds the index's exclusive lock
# and walking that ladder spends seconds only to arrive at the pinned default
# anyway. Anything short of a db-plane answer inside that slice is the pinned
# default, disclosed either as the value the brain applies or as one this
# command could not confirm.
# Sized from a measurement, not a guess. Measured 2026-08-25 against this
# fleet's brain with the connect retry ladder disabled, `gbrain config get
# search.autocut_min_top` took 0.299s, 0.311s, and 0.300s over three runs with
# the index lock free. One second is more than three times that, and it still
# fits the one-second remainder a dashboard-shaped run tends to leave. Re-take
# the measurement before moving this number; the record is in
# docs/verification/gbrain-retrieval.md.
RECALL_FLOOR_READ_MAX_SECONDS=1

# The bound a caller sanctioned is the whole run, not the retrieval calls alone,
# and the runner that enforces this read's own bound spends its kill grace ON
# TOP of the seconds it was given: it arms `timeout -k <grace> <slice>`, so a
# slice of N can occupy N + grace before this command gets control back. The
# grace is therefore reserved out of what is left rather than borrowed from the
# margin a consumer held back for its own kill. A remainder too small to hold
# both is no budget at all, and the read is skipped for the pinned default.
recall_floor_read_slice() {  # -> seconds this run may spend, or non-zero
  local grace=${FM_TIMEOUT_KILL_GRACE:-1} left=$RECALL_FLOOR_READ_MAX_SECONDS
  case $grace in '' | *[!0-9]* | 0) grace=1 ;; esac
  if [ -n "$RECALL_DEADLINE" ]; then
    left=$((RECALL_DEADLINE - SECONDS - grace))
    [ "$left" -le "$RECALL_FLOOR_READ_MAX_SECONDS" ] || left=$RECALL_FLOOR_READ_MAX_SECONDS
  fi
  [ "$left" -ge 1 ] || return 1
  printf '%s\n' "$left"
}

# Two different things end at the pinned default, and saying them with one word
# would be a false statement about what was searched. A brain that was ASKED and
# holds no usable value really does apply the pinned default, and saying so is
# accurate. A brain that could not be asked - the budget did not fit, the read
# was killed, the index lock was held, the binary is missing - applies whatever
# it applies, and this command does not know. The first is `pinned-default`; the
# second is `unconfirmed-default`, and the notice attributes that gap to the
# read this command could not complete rather than to the brain it searched.
RECALL_LOCAL_FLOOR=""
RECALL_LOCAL_FLOOR_SOURCE=unconfirmed-default
RECALL_LOCAL_FLOOR_READ=0
resolve_local_autocut_floor() {
  [ "$RECALL_LOCAL_FLOOR_READ" -eq 0 ] || return 0
  RECALL_LOCAL_FLOOR_READ=1
  RECALL_LOCAL_FLOOR=""
  RECALL_LOCAL_FLOOR_SOURCE=unconfirmed-default
  [ -n "${FM_GBRAIN_HOME_DIR:-}" ] || return 0
  command -v "$GBRAIN_BIN" >/dev/null 2>&1 || return 0
  local slice out_file err_file rc=0 value
  slice=$(recall_floor_read_slice) || return 0
  out_file=$(mktemp "${TMPDIR:-/tmp}/fm-recall-floor.XXXXXX" 2>/dev/null) || return 0
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-recall-floor.XXXXXX" 2>/dev/null) || {
    rm -f "$out_file"
    return 0
  }
  # Scratch that could not be created is not a setup failure: it costs the
  # knob, never the run, so the exit contract stays exactly where it was.
  (
    GBRAIN_HOME="$FM_GBRAIN_HOME_DIR" GBRAIN_NO_RETRY_CONNECT=1 \
      fm_run_timed "$slice" "$GBRAIN_BIN" config get search.autocut_min_top
  ) >"$out_file" 2>"$err_file" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^\[config\] source: db plane' "$err_file"; then
    # The database plane answered. A value GBrain would itself refuse falls
    # through to the bundle default there too, so an unusable answer is a
    # confirmed pinned default rather than an unknown one.
    value=$(head -n 1 "$out_file" | tr -d '[:space:]')
    RECALL_LOCAL_FLOOR=$(jq -rn --arg v "$value" \
      'try (($v | tonumber) as $n | select($n >= 0 and $n <= 1) | $n) catch empty' \
      2>/dev/null) || RECALL_LOCAL_FLOOR=""
    if [ -n "$RECALL_LOCAL_FLOOR" ]; then
      RECALL_LOCAL_FLOOR_SOURCE=db-config
    else
      RECALL_LOCAL_FLOOR_SOURCE=pinned-default
    fi
  elif [ "$rc" -eq 1 ] && grep -q '^Config key not found' "$err_file"; then
    # The connect completed and the key is in no plane at all, so the bundle
    # default is what this brain applies.
    RECALL_LOCAL_FLOOR_SOURCE=pinned-default
  elif [ "$rc" -eq 0 ] && grep -q '^\[config\] source: file/env plane' "$err_file" \
       && ! grep -q 'shadowed at runtime' "$err_file"; then
    # The file plane answered and GBrain reported no database value behind it.
    # Search reads only the database plane, so an empty one means the bundle
    # default is the applied floor even though the number printed is not.
    RECALL_LOCAL_FLOOR_SOURCE=pinned-default
  fi
  rm -f "$out_file" "$err_file"
  return 0
}

# The main brain is read over MCP and has no database plane this host can query,
# so its floor is the pinned default and is disclosed as unconfirmed: nothing
# here knows whether the fleet brain overrode it. Borrowing this home's value
# for it would claim a setting the fleet brain never reported.
autocut_floor_row() {  # <corpus> -> floor row
  local corpus=$1 value source
  if [ "$corpus" != local ]; then
    value=$AUTOCUT_MIN_TOP_DEFAULT; source=unconfirmed-default
  elif [ -n "$RECALL_LOCAL_FLOOR" ]; then
    value=$RECALL_LOCAL_FLOOR; source=$RECALL_LOCAL_FLOOR_SOURCE
  else
    value=$AUTOCUT_MIN_TOP_DEFAULT; source=$RECALL_LOCAL_FLOOR_SOURCE
  fi
  jq -cn --arg c "$corpus" --argjson v "$value" --arg s "$source" \
    '{corpus: $c, autocut_min_top: $v, source: $s}'
}

# The log is home-wide and append-only, so the bound is the retention story: no
# task owns it and no teardown removes it. Past the cap the oldest lines are
# dropped and the newest tail is kept, so the read that just happened always
# survives and a delete or a trim can never fail the search that follows.
trim_recall_read_log() {  # <file>
  local file=$1 size tmp
  size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  case $size in '' | *[!0-9]*) return 0 ;; esac
  [ "$size" -gt "$RECALL_JSONL_MAX_BYTES" ] || return 0
  tmp="$file.trim.$$"
  # Whole lines are taken from the newest end until the cap is reached, so a
  # partial record cannot survive by construction. A byte-sized tail cannot
  # promise that: its cut lands inside a record whenever the offset falls there,
  # and a record of this shape carries interior braces of its own, so no
  # leading-character test can tell a fragment from a whole line - it would keep
  # the fragment and leave the file unreadable to any reader that parses the
  # whole log. The newest record is kept even when it alone exceeds the cap,
  # because dropping it would discard the very read this trim was called to
  # preserve.
  if LC_ALL=C awk -v max="$RECALL_JSONL_MAX_BYTES" '
       { line[NR] = $0; len[NR] = length($0) + 1 }
       END {
         if (NR == 0) exit
         total = 0
         start = NR + 1
         for (i = NR; i >= 1; i--) {
           if (total + len[i] > max) break
           total += len[i]
           start = i
         }
         if (start > NR) start = NR
         for (i = start; i <= NR; i++) print line[i]
       }
     ' "$file" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$file" 2>/dev/null || true
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# The append and the trim that follows it are ONE critical section, because the
# file is home-wide: crewmates and the dashboard search the same home at once,
# and a trim built from a tail snapshot taken before another search appended
# would overwrite exactly the newest lines the cap exists to keep. mkdir is the
# atomic primitive every host has, so it is the whole mechanism rather than one
# arm of two. A holder that died mid-section is swept by age instead of waited
# on forever, and a section this run cannot enter costs the record, never the
# search.
RECALL_LOG_LOCK_STALE_SECONDS=30
# The ceiling is counted in polls rather than in SECONDS, because SECONDS is
# whole-second granular: a bound of "SECONDS + 1" is really anywhere from zero
# to one second depending on where in the current second the run started, so a
# run that arrived late in a second would give up after a single pause and drop
# a record it could have written. Twenty polls at the pause below is a bound
# that means the same thing on every run.
RECALL_LOG_LOCK_MAX_POLLS=20

# A holder that died mid-section leaves its directory behind, so a stale hold is
# swept by age. The sweep has to be single-winner or it recreates the very
# interleaving the lock prevents: two waiters that sampled the same stale mtime
# would each remove the directory, and the second would remove the lock the
# first had already re-created. Renaming the directory IS the claim, because a
# rename is atomic and only one sweeper can win it.
# The trim's scratch file and a claimed stale-lock directory are each removed by
# the invocation that made them, so a run killed in between leaves one behind
# under a name nothing else would ever look at. They are swept by the same age
# rule the lock itself uses, and from the append path rather than the contention
# path, because a home nobody is competing for never reaches the lock sweep at
# all. The age is what keeps a live run's scratch safe: a trim finishes in
# milliseconds, so anything this old belongs to a run that is gone.
recall_log_sweep_leftovers() {  # <log-file>
  local file=$1 leftover held now=""
  for leftover in "$file".trim.* "$file".lock.stale.*; do
    [ -e "$leftover" ] || continue
    if [ -z "$now" ]; then
      now=$(date +%s 2>/dev/null || printf '')
      case $now in '' | *[!0-9]*) return 0 ;; esac
    fi
    held=$(recall_stat_mtime "$leftover")
    [ -n "$held" ] || continue
    [ "$((now - held))" -ge "$RECALL_LOG_LOCK_STALE_SECONDS" ] || continue
    rm -rf "$leftover" 2>/dev/null || true
  done
  return 0
}

recall_log_lock_sweep_stale() {  # <lock-dir>
  local lock=$1 held now claimed
  held=$(recall_stat_mtime "$lock")
  [ -n "$held" ] || return 0
  now=$(date +%s 2>/dev/null || printf '')
  case $now in '' | *[!0-9]*) return 0 ;; esac
  [ "$((now - held))" -ge "$RECALL_LOG_LOCK_STALE_SECONDS" ] || return 0
  claimed="$lock.stale.$$"
  mv "$lock" "$claimed" 2>/dev/null || return 0
  rmdir "$claimed" 2>/dev/null || rm -rf "$claimed" 2>/dev/null || true
  return 0
}

# A host whose sleep refuses a fractional argument must not turn each pause into
# a whole second, so the shape of the pause is probed once and a host without
# one spins on mkdir alone rather than sleeping.
RECALL_LOG_LOCK_PAUSE=unknown
recall_log_lock_pause() {
  case $RECALL_LOG_LOCK_PAUSE in
    yes) sleep 0.05 2>/dev/null || true ;;
    no) : ;;
    *) if sleep 0.05 2>/dev/null; then RECALL_LOG_LOCK_PAUSE=yes; else RECALL_LOG_LOCK_PAUSE=no; fi ;;
  esac
  return 0
}

# The wait is bounded by whichever comes first: a short ceiling of its own, or
# what is LEFT of the budget the caller granted. This runs after the document
# has already been printed, and a consumer that kills the run on its own
# deadline discards that document, so a record nobody promised must never be
# the reason an operator is told the brain was unreachable. Past the budget the
# lock is tried exactly once and the record is dropped.
recall_read_log_lock() {  # <lock-dir> -> 0 when held
  local lock=$1 polls=0
  while :; do
    mkdir "$lock" 2>/dev/null && return 0
    recall_log_lock_sweep_stale "$lock"
    polls=$((polls + 1))
    [ "$polls" -lt "$RECALL_LOG_LOCK_MAX_POLLS" ] || return 1
    [ -z "$RECALL_DEADLINE" ] || [ "$SECONDS" -lt "$RECALL_DEADLINE" ] || return 1
    recall_log_lock_pause
  done
}

recall_read_log_append() {  # <file> <line>
  local file=$1 line=$2 lock="$1.lock"
  recall_log_sweep_leftovers "$file"
  recall_read_log_lock "$lock" || return 0
  { printf '%s\n' "$line" >> "$file" 2>/dev/null \
      && trim_recall_read_log "$file"; } || true
  rmdir "$lock" 2>/dev/null || true
  return 0
}

# Presence-gated on the local index directory, the same predicate the brief
# scaffold uses. A write failure never fails the search it records.
#
# The record answers three things about the read: what was asked, whether a
# corpus was read at all, and what the read returned. The disposition is what
# keeps those separable - a run that never reached a corpus would otherwise
# serialize as a successful read whose top row carried no rerank_score, which
# is the one question an audit trail of reads exists to answer.
#
# The score the verdict was actually taken from is per corpus, so the record
# carries corpus_tops. rank1_rerank_score is the head of the MERGED list and is
# named with the corpus it came from, because on a two-corpus read that row can
# belong to a corpus the verdict is not about.
append_recall_read_record() {  # <doc-json>
  [ -n "${HOME_PATH:-}" ] || return 0
  [ -n "${FM_GBRAIN_PGLITE:-}" ] && [ -d "$FM_GBRAIN_PGLITE" ] || return 0
  local dir="$HOME_PATH/state" file line
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/recall.jsonl"
  line=$(printf '%s' "$1" | jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    (if (.answer | type) == "object" then .answer else null end) as $a
    | ($a != null and ($a | has("no_confident_match"))) as $judged
    | {
      schema: "fm-recall-read.v1",
      at: $at,
      query: .query,
      disposition: (
        if $a == null then "unread"
        elif ($judged | not) then "unjudged"
        elif $a.no_confident_match then "miss"
        else "hit" end
      ),
      answer_kind: (if $a == null then null else $a.kind end),
      rank1_corpus: (.results[0].source // null),
      rank1_rerank_score: (
        if ((.results[0].rerank_score // null) | type) == "number"
        then .results[0].rerank_score
        else null end
      ),
      corpus_tops: (
        if $a == null then null
        else [ ($a.corpora // [])[]
               | {corpus, top_rerank_score, judged, cleared} ]
        end
      ),
      no_confident_match: (if $judged then $a.no_confident_match else null end),
      confident_corpora: (if $a == null then null else ($a.confident_corpora // null) end)
    }
  ' 2>/dev/null) || return 0
  [ -n "$line" ] || return 0
  recall_read_log_append "$file" "$line"
  return 0
}

# --- search -----------------------------------------------------------------

cmd_search() {
  COMMAND=search
  prescan_json "$@"
  parse_args "$@"
  refuse_flag "$SET_ANSWER" --max-answer think
  case $SCOPE in
    local | main | all) ;;
    *) die 2 bad_argument "--scope must be local, main, or all" ;;
  esac
  local query
  query=$(joined_query)
  [ -n "$query" ] || die 2 bad_argument "search needs a query"
  require_tool jq
  resolve_context
  local secs=${TIMEOUT:-${FM_RECALL_TIMEOUT:-60}}

  # Each requested corpus is read on its own terms and reports its own verdict,
  # so neither leg decides the other's outcome. A home with no GBrain installed
  # still reaches the fleet's shared corpus, which needs only curl and a token,
  # and a home whose main brain is stopped still reads its own index.
  local rows=() results='[]' answered=0 owner=0 params shaped count
  local local_state="" local_detail="" local_count=0
  if fm_gbrain_is_main_brain_owner "$HOME_PATH"; then owner=1; fi

  local read_local=0 read_main=0 main_is_local=0
  case $SCOPE in
    local) read_local=1 ;;
    main) read_main=1 ;;
    all) read_local=1; read_main=1 ;;
  esac
  # On the home that owns the main brain, the main corpus IS this home's own
  # index, so a main-scoped read there is a legitimate question with a real
  # answer and is served by the local leg rather than answered with nothing.
  if [ "$read_main" -eq 1 ] && [ "$owner" -eq 1 ]; then
    main_is_local=1
    read_local=1
  fi

  # --timeout bounds EACH retrieval call, so the run's own ceiling is that
  # budget once per leg this scope will actually read. Sizing the provenance
  # pass against one leg instead would expire it while retrieval was still
  # inside the budget it was granted, and every row would lose its capture date
  # and its drift marker because the index was merely cold.
  #
  # A budget that is not a positive integer is left to the retrieval bound to
  # refuse the way it always has; computing a deadline from it would abort the
  # run with a raw arithmetic error, which is none of this command's statuses.
  local legs=$((read_local + (read_main == 1 && main_is_local == 0 ? 1 : 0)))
  case $secs in
    '' | *[!0-9]*) RECALL_DEADLINE="" ;;
    *) RECALL_DEADLINE=$((SECONDS + secs * (legs > 0 ? legs : 1))) ;;
  esac

  if [ "$read_local" -eq 1 ]; then
    if ! command -v "$GBRAIN_BIN" >/dev/null 2>&1; then
      local_state=failed
      local_detail="gbrain is not installed (set FM_GBRAIN_BIN), so this home's own index cannot be read"
    else
      params=$(jq -cn --arg q "$query" --argjson n "$LIMIT" '{query: $q, limit: $n}')
      if gbrain_local_call search "$params" "$secs"; then
        shaped=$(shape_results local "$LOCAL_OUT" "$EXCERPT")
        local_count=$(printf '%s' "$shaped" | jq 'length')
        results=$(jq -c -n --argjson a "$results" --argjson b "$shaped" '$a + $b')
        local_state=ok
        answered=1
      else
        local_state=failed
        local_detail=$LOCAL_ERR
      fi
    fi
    rows+=("$(source_row local "$local_state" "$FM_GBRAIN_BRAIN_ROOT" "$local_count" "$local_detail")")
  fi

  if [ "$read_main" -eq 1 ]; then
    if [ "$main_is_local" -eq 1 ]; then
      # The alias row counts nothing, because no entry in the result list carries
      # this source, and it never claims a read the local leg did not perform.
      if [ "$local_state" = ok ]; then
        rows+=("$(source_row main same-as-local "$FM_GBRAIN_BRAIN_ROOT" 0 "this home owns the main brain, so the main corpus is its own index and its results are the local rows, cited local:<slug>")")
      else
        rows+=("$(source_row main failed "$FM_GBRAIN_BRAIN_ROOT" 0 "this home owns the main brain, so the main corpus is its own index, which could not be read: $local_detail")")
      fi
    elif [ -z "$MAIN_MCP_URL" ]; then
      if [ "$SCOPE" = main ]; then
        die 2 no_main_brain "no main brain is configured for $HOME_PATH"
      fi
      rows+=("$(source_row main absent "" 0 "no main brain is configured for this fleet")")
    elif ! command -v curl >/dev/null 2>&1; then
      rows+=("$(source_row main degraded "$MAIN_MCP_URL" 0 "curl is not installed, so the main brain cannot be reached")")
    elif main_brain_search "$query" "$LIMIT" "$secs"; then
      shaped=$(shape_results main "$MAIN_OUT" "$EXCERPT")
      count=$(printf '%s' "$shaped" | jq 'length')
      results=$(jq -c -n --argjson a "$results" --argjson b "$shaped" '$a + $b')
      rows+=("$(source_row main ok "$MAIN_MCP_URL" "$count")")
      answered=1
    else
      rows+=("$(source_row main degraded "$MAIN_MCP_URL" 0 "$MAIN_ERR")")
    fi
  fi

  local sources doc corpus floor_rows=() floors='[]' answer_json="null"
  results=$(annotate_search_results "$results" "$HOME_PATH")
  results=$(printf '%s' "$results" | jq -c "$JQ_MERGE_BY_RANK"'. | merge_by_rank')

  # The floor is read only for a corpus that actually returned rows to judge,
  # and only after the run's deadline has been set and every retrieval leg has
  # spent what it was granted. A search that found nothing needs no floor and
  # reads no plane, and a run whose budget is already gone reads none either.
  # A corpus is judgeable only when its own rows carry a rerank_score, which is
  # the same predicate the answer uses to decide `judged`. A corpus without one
  # is never measured against a floor, so reading a plane for it would spend an
  # engine connect on a number that is then thrown away - the whole cost this
  # read is fenced against, and the ordinary case on a brain whose reranker is
  # off.
  local judged_corpora
  judged_corpora=$(printf '%s' "$results" | jq -r '
    [ ([.[].source] | unique)[] as $c
      | select([.[] | select(.source == $c) | .rerank_score
                | select(type == "number")] | length > 0)
      | $c ][]' 2>/dev/null || true)
  if [ "$answered" -eq 1 ] && [ -n "$judged_corpora" ]; then
    for corpus in $judged_corpora; do
      [ "$corpus" != local ] || resolve_local_autocut_floor
      floor_rows+=("$(autocut_floor_row "$corpus")")
    done
    floors=$(printf '%s\n' ${floor_rows[@]+"${floor_rows[@]}"} | jq -c -s 'map(select(. != null))')
  fi
  if [ "$answered" -eq 1 ]; then
    answer_json=$(search_answer_json "$results" "$floors")
  fi
  sources=$(printf '%s\n' ${rows[@]+"${rows[@]}"} | jq -c -s 'map(select(. != null))')
  doc=$(jq -c -n --arg s "$SCHEMA" --arg h "$HOME_PATH" --arg q "$query" \
    --argjson src "$sources" --argjson res "$results" --argjson ans "$answer_json" '
    {schema: $s, command: "search", home: $h, query: $q, sources: $src,
     results: $res}
    + (if $ans == null then {} else {answer: $ans} end)')

  if [ "$JSON_MODE" -eq 1 ]; then
    printf '%s\n' "$doc" | jq '.'
  else
    printf '%s' "$doc" | jq -r '
      (.sources[] | "\(.source)\t\(.state)\(if .brain == "" then "" else "\t" + .brain end)\(if .detail then "\t" + .detail else "" end)"),
      (if .answer then "answer\t\(.answer.kind)\t\(.answer.notice)" else empty end),
      "",
      (if (.answer | not) then "not searched: no corpus could be read - this says nothing about whether it exists"
       elif (.results | length) == 0 then "no match in this brain - the brain may simply not hold it"
       else (.results[]
             | "\(.citation)  score=\((.score // 0) | tostring | .[0:6])\(if .rerank_score != null then "  rerank=" + (.rerank_score | tostring) else "" end)\(if .cosine != null then "  cosine=" + (.cosine | tostring) else "" end)\(if .evidence then "  evidence=" + .evidence else "" end)\(if .create_safety then "  create_safety=" + .create_safety else "" end)\(if .stale then " (stale)" else "" end)\(if .captured_at then "  captured=" + .captured_at else "" end)\(if .source_state then "  source=" + .source_state else "" end)\(if .source_state == "drifted" then " (live source wins)" else "" end)\(if .source_updated_at then "  live=" + .source_updated_at else "" end)\n  \(.excerpt)")
       end)'
  fi

  append_recall_read_record "$doc"

  # No corpus answered, so an empty result list here would be the one lie this
  # command must never tell: "nothing was found" reads the same as "nothing
  # could be read" only to a caller that was never told the difference.
  #
  # There is a third thing it must not say either. When this command could not
  # create its own working files, no corpus was ever asked, and reporting that
  # as "none answered" points the operator at their brain instead of at the
  # environment the command was run in - which is where the fault actually is.
  if [ "$answered" -eq 0 ]; then
    if [ "$SETUP_FAILED" -eq 1 ]; then
      [ "$JSON_MODE" -eq 1 ] \
        || printf 'fm-recall: the search could not start, so no corpus was asked and this is not a result about your brain: %s\n' \
             "$SETUP_DETAIL" >&2
      exit 5
    fi
    [ "$JSON_MODE" -eq 1 ] \
      || printf 'fm-recall: not searched: no corpus could be read, so this is not an empty result set and says nothing about whether the queried thing exists - see the source states above\n' >&2
    exit 3
  fi
}

# --- think ------------------------------------------------------------------

cmd_think() {
  COMMAND=think
  prescan_json "$@"
  parse_args "$@"
  refuse_flag "$SET_SCOPE" --scope search
  refuse_flag "$SET_LIMIT" --limit search
  refuse_flag "$SET_EXCERPT" --excerpt search
  local question
  question=$(joined_query)
  [ -n "$question" ] || die 2 bad_argument "think needs a question"
  require_tool jq
  resolve_context
  command -v "$GBRAIN_BIN" >/dev/null 2>&1 \
    || die 3 gbrain_missing "gbrain is not installed (set FM_GBRAIN_BIN); this home's brain cannot be read"
  local secs=${TIMEOUT:-${FM_RECALL_TIMEOUT:-300}}

  # The hosted credential is named by the shared plane and stored only in the
  # home's own credential plane, so it reaches exactly one process and never a
  # log, an argument list, or an inherited configuration file.
  local secret_name rc=0
  secret_name=$(fm_gbrain_json_str "$(fm_gbrain_shared_path "$HOME_PATH")" '.think.secret')
  [ -n "$secret_name" ] \
    || die 4 hosted_unconfigured "$HOME_PATH names no hosted synthesis credential, so think cannot run; local retrieval is unaffected - use: fm-recall.sh search"
  fm_gbrain_read_secret "$HOME_PATH" "$secret_name" || rc=$?
  case $rc in
    0) ;;
    1) FM_GBRAIN_SECRET=""
       die 4 hosted_key_missing "the hosted synthesis credential \"$secret_name\" is not installed in $HOME_PATH, so think cannot run; local retrieval is unaffected - use: fm-recall.sh search" ;;
    *) FM_GBRAIN_SECRET=""
       die 2 bad_config "$FM_GBRAIN_ERROR" ;;
  esac

  local params ok=0
  params=$(jq -cn --arg q "$question" '{question: $q, rounds: 1}')
  GBRAIN_CALL_HOSTED_KEY=$FM_GBRAIN_SECRET
  FM_GBRAIN_SECRET=""
  if gbrain_local_call think "$params" "$secs"; then ok=1; fi
  GBRAIN_CALL_HOSTED_KEY=""
  if [ "$ok" -ne 1 ]; then
    [ "$SETUP_FAILED" -eq 0 ] \
      || die 5 setup_failed "the search could not start, so no corpus was asked: $SETUP_DETAIL"
    die 3 local_retrieval_failed "$HOME_PATH: $LOCAL_ERR"
  fi

  # GBrain answers with a placeholder and exits 0 when it has no usable model,
  # so its synthesis flag is the only honest signal that an answer was produced.
  local synth_ok doc
  synth_ok=$(printf '%s' "$LOCAL_OUT" | jq -r '.synthesisOk == true')
  doc=$(printf '%s' "$LOCAL_OUT" | jq -c --arg s "$SCHEMA" --arg h "$HOME_PATH" --arg q "$question" \
    --argjson cap "$ANSWER_MAX" --arg brain "$FM_GBRAIN_BRAIN_ROOT" "$JQ_RENDER_PRELUDE"'
    {
      schema: $s, command: "think", home: $h, question: $q,
      sources: [{source: "local", state: "ok", brain: $brain,
                 results: (if (.pagesGathered | type) == "number" then .pagesGathered else 0 end)}],
      synthesis: {
        state: (if .synthesisOk == true then "ok" else "failed" end),
        model: (if .modelUsed == null then null else text(.modelUsed) end),
        warnings: [ (.warnings // [])[] | text(.) ],
        truncated: ((text(.answer) | length) > $cap),
        answer: capped(.answer; $cap)
      },
      citations: [ (.citations // [])[]
                   | "local:" + (if .page_slug == null or .page_slug == "" then "?" else text(.page_slug) end) ]
    }')

  if [ "$JSON_MODE" -eq 1 ]; then
    printf '%s\n' "$doc" | jq '.'
  else
    printf '%s' "$doc" | jq -r '
      "local\t\(.sources[0].state)\t\(.sources[0].brain)\tpages=\(.sources[0].results)",
      "synthesis\t\(.synthesis.state)\t\(.synthesis.model // "none")\(if (.synthesis.warnings | length) > 0 then "\t" + (.synthesis.warnings | join(",")) else "" end)",
      "",
      .synthesis.answer,
      (if (.citations | length) > 0 then "\ncited: " + (.citations | join(" ")) else empty end)'
  fi

  if [ "$synth_ok" != true ]; then
    [ "$JSON_MODE" -eq 1 ] \
      || printf 'fm-recall: the hosted provider produced no answer; this home retrieved its own pages fine - use: fm-recall.sh search\n' >&2
    exit 4
  fi
}

# --- dispatch ---------------------------------------------------------------

main() {
  local cmd=${1:-}
  [ $# -gt 0 ] && shift
  case $cmd in
    search) cmd_search "$@" ;;
    think) cmd_think "$@" ;;
    -h | --help | help | '') usage ;;
    *) die 2 bad_argument "unknown command: $cmd" ;;
  esac
}

main "$@"
