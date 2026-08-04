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
#           GBrain classifies think as a write-scope operation, which a
#           read-only client is refused.
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
#
# Every query is passed as an argument array and, at the GBrain boundary, as a
# jq-built JSON value. No query text is ever interpolated into a shell command,
# a format string, or a filename, so shell metacharacters in a query are just
# characters to search for.
#
# --json prints one "fm-recall.v1" document: the resolved home, a per-source
# state, and capped results. Human output renders the same content as lines.
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
#               (default: search 60, think 300).
#   --          end of flags, so a query may begin with a dash.
#
# Environment:
#   FM_HOME            active firstmate home; --home overrides it, and with
#                      neither this command uses the home it was invoked from,
#                      refusing when that is a source checkout rather than a home
#   FM_GBRAIN_BIN      gbrain executable (default: gbrain on PATH)
#   FM_RECALL_TIMEOUT  default seconds per retrieval call, overriding the
#                      per-command defaults above
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gbrain-lib.sh
. "$SCRIPT_DIR/fm-gbrain-lib.sh"
# shellcheck source=bin/fm-bounded-lib.sh
. "$SCRIPT_DIR/fm-bounded-lib.sh"

GBRAIN_BIN="${FM_GBRAIN_BIN:-gbrain}"
SCHEMA=fm-recall.v1

LIMIT_MAX=50
EXCERPT_MAX=4000
ANSWER_MAX_CEILING=100000
TIMEOUT_MAX=3600

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
# Set by a caller that must hand a hosted credential to exactly one process.
# gbrain_local_call exports it for that call only; the caller clears it after.
GBRAIN_CALL_HOSTED_KEY=""

gbrain_local_call() {  # <tool> <params-json> <seconds> -> 0
  local tool=$1 params=$2 secs=$3 out_file err_file rc=0
  LOCAL_OUT=""; LOCAL_ERR=""
  out_file=$(mktemp "${TMPDIR:-/tmp}/fm-recall.XXXXXX") || {
    LOCAL_ERR="could not create a temporary file"; return 1
  }
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-recall.XXXXXX") || {
    rm -f "$out_file"; LOCAL_ERR="could not create a temporary file"; return 1
  }
  (
    export GBRAIN_HOME="$FM_GBRAIN_HOME_DIR"
    [ -z "$EMBED_URL" ] || export OLLAMA_BASE_URL="$EMBED_URL"
    [ -z "$GBRAIN_CALL_HOSTED_KEY" ] || export MINIMAX_API_KEY="$GBRAIN_CALL_HOSTED_KEY"
    fm_run_bounded "$secs" "$GBRAIN_BIN" call "$tool" "$params"
  ) >"$out_file" 2>"$err_file" || rc=$?
  LOCAL_OUT=$(cat "$out_file")
  LOCAL_ERR=$(tr -s '[:space:]' ' ' < "$err_file")
  LOCAL_ERR=${LOCAL_ERR# }; LOCAL_ERR=${LOCAL_ERR% }
  rm -f "$out_file" "$err_file"
  case $rc in
    0) ;;
    124) LOCAL_ERR="the local brain did not answer within ${secs}s"; return 1 ;;
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
  body_file=$(mktemp "${TMPDIR:-/tmp}/fm-recall.XXXXXX") || {
    FM_GBRAIN_TOKEN=""; MAIN_ERR="could not create a temporary file"; return 1
  }
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
        stale: (.stale == true),
        excerpt: capped(.chunk_text; $cap)
      } ]
  ' <<EOF
$2
EOF
}

# A row's count is the number of entries in `.results` that carry its source, so
# summing the rows can never disagree with the list they describe.
source_row() {  # <source> <state> <brain> <count> [detail]
  jq -cn --arg s "$1" --arg st "$2" --arg b "$3" --argjson n "$4" --arg d "${5:-}" '
    {source: $s, state: $st, brain: $b, results: $n}
    + (if $d == "" then {} else {detail: $d} end)
  '
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

  local sources doc
  sources=$(printf '%s\n' ${rows[@]+"${rows[@]}"} | jq -c -s 'map(select(. != null))')
  doc=$(jq -c -n --arg s "$SCHEMA" --arg h "$HOME_PATH" --arg q "$query" \
    --argjson src "$sources" --argjson res "$results" '
    {schema: $s, command: "search", home: $h, query: $q, sources: $src,
     results: ($res | sort_by(-(.score // 0)))}')

  if [ "$JSON_MODE" -eq 1 ]; then
    printf '%s\n' "$doc" | jq '.'
  else
    printf '%s' "$doc" | jq -r '
      (.sources[] | "\(.source)\t\(.state)\(if .brain == "" then "" else "\t" + .brain end)\(if .detail then "\t" + .detail else "" end)"),
      "",
      (if (.results | length) == 0 then "no results"
       else (.results[] | "\(.citation)  score=\((.score // 0) | tostring | .[0:6])\(if .stale then " (stale)" else "" end)\n  \(.excerpt)")
       end)'
  fi

  # No corpus answered, so an empty result list here would be the one lie this
  # command must never tell: "nothing was found" reads the same as "nothing
  # could be read" only to a caller that was never told the difference.
  if [ "$answered" -eq 0 ]; then
    [ "$JSON_MODE" -eq 1 ] \
      || printf 'fm-recall: no corpus could be read, so this is not an empty result set - see the source states above\n' >&2
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
  [ "$ok" -eq 1 ] || die 3 local_retrieval_failed "$HOME_PATH: $LOCAL_ERR"

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
