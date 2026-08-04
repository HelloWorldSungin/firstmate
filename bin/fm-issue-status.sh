#!/usr/bin/env bash
# Optional status enrichment for resolved work-item references.
#
# Usage: fm-issue-status.sh [--format tsv|json] [--refresh] <record>...
#        fm-issue-status.sh [--format tsv|json] [--refresh] --task <task-id>
#
#   <record> is a "<origin>|<forge>|<url>" work-item record as recorded in task
#   metadata; --task reads every work_item= line from state/<task-id>.meta.
#
# Enrichment is strictly optional decoration on top of a link that already
# resolves. Every failure mode - an unreachable host, an expired or missing
# credential, a forge with no adapter, a deleted issue, a private repository, a
# missing tool - degrades to the canonical URL plus a one-line reason and still
# exits 0. Nothing here can stall supervision or blank a board: a caller that
# ignores the status columns still has a working link.
#
# Output is one record per line, four tab-separated columns:
#   <url>  ok|unavailable  open|closed|-  <title>|<reason>
# --format json emits the same fields as an array, with null title/state when
# the lookup did not succeed. A task with no work items is a first-class case
# and still answers with the empty array, so a dashboard is never handed empty
# input where it asked for a document.
#
# Rate limiting and caching (a dashboard refresh must never hammer a forge):
#   Results are cached under state/issue-status/ keyed by URL digest and reused
#   for FM_ISSUE_STATUS_TTL seconds (default 900). Live lookups to one host are
#   additionally spaced by at least FM_ISSUE_STATUS_MIN_INTERVAL seconds
#   (default 2); when that spacing would be violated, a stale cache entry is
#   served if one exists and the reference reports "throttled" if not. --refresh
#   ignores a fresh cache entry but still respects the per-host spacing.
#   The per-host spacing is BEST-EFFORT across processes, deliberately: there is
#   no lock, so two concurrent processes may each read "no recent call" and each
#   perform one lookup. The cache is what actually keeps a dashboard off a
#   forge; the spacing only thins the lookups that miss it. Cache entries and
#   the per-host timestamp are replaced atomically, so a concurrent reader sees
#   a whole record or the previous one, never a torn one.
#
# Credentials, per host, never in tracked files and never inherited:
#   github  uses the ambient gh-axi authentication, like every other GitHub
#           path in this repo. No separate secret is read.
#   gitea   reads config/forge-tokens/<host>, which must be a regular file with
#           mode 0600. A token file with looser permissions is refused rather
#           than used, and an absent one falls back to an unauthenticated read
#           that works for public repositories. config/ is gitignored in full,
#           and forge-tokens is deliberately absent from the inheritable-config
#           allowlist in bin/fm-config-inherit-lib.sh, so a secondmate home
#           never receives another home's forge credentials.
#   gitlab  has no enrichment adapter yet and reports that as its reason.
# The token is passed to curl through a stdin config file so it never appears in
# the process arguments, and it is never printed, cached, or logged.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CACHE="$STATE/issue-status"
TTL=${FM_ISSUE_STATUS_TTL:-900}
MIN_INTERVAL=${FM_ISSUE_STATUS_MIN_INTERVAL:-2}
LOOKUP_TIMEOUT=${FM_ISSUE_STATUS_TIMEOUT:-10}
case "$LOOKUP_TIMEOUT" in
  ''|*[!0-9]*|0) LOOKUP_TIMEOUT=10 ;;
esac

# shellcheck source=bin/fm-issue-lib.sh
. "$SCRIPT_DIR/fm-issue-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

FORMAT=tsv
REFRESH=0
TASK=
RECORDS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      format) FORMAT=$a ;;
      task) TASK=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --format) want_value=format ;;
    --format=*) FORMAT=${a#--format=} ;;
    --task) want_value=task ;;
    --task=*) TASK=${a#--task=} ;;
    --refresh) REFRESH=1 ;;
    --*) echo "error: unknown option $a" >&2; exit 1 ;;
    *) RECORDS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
case "$FORMAT" in
  tsv|json) ;;
  *) echo "error: --format must be tsv or json (got '$FORMAT')" >&2; exit 1 ;;
esac

if [ -n "$TASK" ]; then
  [ "${#RECORDS[@]}" -eq 0 ] || { echo "error: --task and explicit records are mutually exclusive" >&2; exit 1; }
  fm_task_id_safe() {
    local id=${1-}
    local LC_ALL=C
    case "$id" in
      ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
  }
  fm_task_id_safe "$TASK" || { echo "error: invalid task id" >&2; exit 1; }
  META="$STATE/$TASK.meta"
  if [ -f "$META" ] && [ ! -L "$META" ]; then
    while IFS= read -r line; do
      RECORDS+=("${line#work_item=}")
    done < <(grep '^work_item=' "$META" 2>/dev/null || true)
  fi
fi

if [ "${#RECORDS[@]}" -eq 0 ]; then
  # A task with no work items is a first-class case, the same way it is in
  # bin/fm-issue-ref.sh. The line-oriented format says that with no lines; json
  # must still emit a document a consumer can parse, so it emits the empty array
  # rather than handing a dashboard empty input.
  [ "$FORMAT" != json ] || printf '[]\n'
  exit 0
fi

now() { date +%s; }

file_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

digest() {  # <string>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

utf8_prefix_shell() {  # <text> <code-points>
  local text=$1 limit=$2 output='' count=0 width b1 b2 b3 b4
  local LC_ALL=C
  while [ -n "$text" ] && [ "$count" -lt "$limit" ]; do
    printf -v b1 '%d' "'${text:0:1}"
    width=0
    if [ "$b1" -le 127 ]; then
      width=1
    elif [ "$b1" -ge 194 ] && [ "$b1" -le 223 ] && [ "${#text}" -ge 2 ]; then
      printf -v b2 '%d' "'${text:1:1}"
      [ "$b2" -ge 128 ] && [ "$b2" -le 191 ] && width=2
    elif [ "$b1" -ge 224 ] && [ "$b1" -le 239 ] && [ "${#text}" -ge 3 ]; then
      printf -v b2 '%d' "'${text:1:1}"
      printf -v b3 '%d' "'${text:2:1}"
      if [ "$b3" -ge 128 ] && [ "$b3" -le 191 ]; then
        case "$b1" in
          224) [ "$b2" -ge 160 ] && [ "$b2" -le 191 ] && width=3 ;;
          237) [ "$b2" -ge 128 ] && [ "$b2" -le 159 ] && width=3 ;;
          *) [ "$b2" -ge 128 ] && [ "$b2" -le 191 ] && width=3 ;;
        esac
      fi
    elif [ "$b1" -ge 240 ] && [ "$b1" -le 244 ] && [ "${#text}" -ge 4 ]; then
      printf -v b2 '%d' "'${text:1:1}"
      printf -v b3 '%d' "'${text:2:1}"
      printf -v b4 '%d' "'${text:3:1}"
      if [ "$b3" -ge 128 ] && [ "$b3" -le 191 ] \
        && [ "$b4" -ge 128 ] && [ "$b4" -le 191 ]; then
        case "$b1" in
          240) [ "$b2" -ge 144 ] && [ "$b2" -le 191 ] && width=4 ;;
          244) [ "$b2" -ge 128 ] && [ "$b2" -le 143 ] && width=4 ;;
          *) [ "$b2" -ge 128 ] && [ "$b2" -le 191 ] && width=4 ;;
        esac
      fi
    fi
    if [ "$width" -eq 0 ]; then
      text=${text:1}
      continue
    fi
    output="${output}${text:0:$width}"
    text=${text:$width}
    count=$((count + 1))
  done
  printf '%s' "$output"
}

utf8_prefix() {  # <text> <code-points>
  local text=$1 limit=$2
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$text" | perl -MEncode=decode,encode,FB_DEFAULT -e '
      local $/;
      my $bytes = <STDIN>;
      $bytes = "" unless defined $bytes;
      print encode("UTF-8", substr(decode("UTF-8", $bytes, FB_DEFAULT), 0, shift));
    ' "$limit"
  else
    utf8_prefix_shell "$text" "$limit"
  fi
}

# A forge title is untrusted remote text that lands in status output, task
# metadata consumers, and eventually a dashboard cell. Strip control characters
# (which would forge extra TSV columns or lines), collapse whitespace, and cap
# the length so one pathological title cannot distort a whole view.
#
# The cap decodes UTF-8 explicitly before taking a prefix, so the ambient locale
# cannot turn code-point truncation into byte truncation and split a CJK or emoji
# character inside the JSON a dashboard has to parse.
sanitize() {  # <text>
  local text
  text=$(printf '%s' "$1" \
    | tr -d '\000-\037\177' \
    | tr -s ' \t' ' ' \
    | sed 's/^ //; s/ $//')
  utf8_prefix "$text" 200
}

cache_dir_ready() {
  [ ! -L "$CACHE" ] || return 1
  mkdir -p "$CACHE" 2>/dev/null || return 1
  [ -d "$CACHE" ] && [ ! -L "$CACHE" ] || return 1
  chmod 0700 "$CACHE" 2>/dev/null || return 1
}

CACHE_OK=1
cache_dir_ready || CACHE_OK=0

# One field per line rather than delimited columns. An unavailable entry has an
# empty state, and every candidate single-character delimiter is either IFS
# whitespace (where `read` silently collapses the empty field and swallows the
# reason) or a character a title could contain. Detail is sanitized to be
# control-character free, so it can never span lines.
cache_read() {  # <url> -> sets CACHED_STATUS/CACHED_STATE/CACHED_DETAIL/CACHED_AGE
  local url=$1 path age stamp
  CACHED_STATUS=; CACHED_STATE=; CACHED_DETAIL=; CACHED_AGE=
  [ "$CACHE_OK" -eq 1 ] || return 1
  path="$CACHE/$(digest "$url")"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  stamp=$(file_mtime "$path") || return 1
  [ -n "$stamp" ] || return 1
  age=$(( $(now) - stamp ))
  exec 6< "$path" || return 1
  IFS= read -r CACHED_STATUS <&6 || { exec 6<&-; return 1; }
  IFS= read -r CACHED_STATE <&6 || { exec 6<&-; return 1; }
  IFS= read -r CACHED_DETAIL <&6 || { exec 6<&-; return 1; }
  exec 6<&-
  case "$CACHED_STATUS" in
    ok|unavailable) ;;
    *) return 1 ;;
  esac
  CACHED_AGE=$age
}

cache_write() {  # <url> <status> <state> <detail>
  local url=$1 path tmp
  [ "$CACHE_OK" -eq 1 ] || return 0
  path="$CACHE/$(digest "$url")"
  [ ! -L "$path" ] || return 0
  tmp=$(mktemp "$CACHE/.status.XXXXXX") || return 0
  if printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$tmp" && chmod 0600 "$tmp"; then
    mv -f -- "$tmp" "$path" || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
  return 0
}

# Coarse per-host spacing for the lookups that miss the cache: at most one live
# call per MIN_INTERVAL seconds, decided by a plain read-then-write with no
# mutual exclusion of any kind.
#
# This is BEST-EFFORT across processes by deliberate choice. An earlier version
# serialized this decision with a cross-process claim protocol, and that one
# mechanism produced a run of correctness defects - a limiter that failed open
# when the cache was unusable, a non-atomic check-and-touch, a stale-reclamation
# race, and a check-then-delete release that could remove another holder's claim
# - which is far out of proportion to what it protects. The accepted criterion
# is that a dashboard cannot hammer a forge on every refresh, and the TTL cache
# above is what delivers that; the claim only ever added cross-process
# exactness. The entire cost of dropping it is an occasional duplicate GET for
# an optional issue title, so two concurrent processes may each read "no recent
# call" and each perform one lookup. That is accepted, not overlooked.
#
# The timestamp is written to a temp file and renamed into place, the same
# discipline cache_write uses. Concurrent access must never yield a torn record;
# atomic replacement is the whole requirement, and nothing is layered on it.
host_may_call() {  # <host>
  local host=$1 marker stamp tmp
  HOST_CALL_REASON=
  if [ "$CACHE_OK" -ne 1 ]; then
    HOST_CALL_REASON="status cache/rate limiter is unavailable"
    return 2
  fi
  marker="$CACHE/.host-$(digest "$host")"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    if [ ! -f "$marker" ] || [ -L "$marker" ]; then
      HOST_CALL_REASON="status cache/rate limiter marker is unusable for $host"
      return 2
    fi
    stamp=$(file_mtime "$marker") || stamp=
    if [ -n "$stamp" ] && [ $(( $(now) - stamp )) -lt "$MIN_INTERVAL" ]; then
      return 1
    fi
  fi
  # Recorded before the request, so a slow or hanging forge cannot let this
  # process issue a burst of its own while one call is still outstanding.
  if ! tmp=$(mktemp "$CACHE/.host.XXXXXX" 2>/dev/null); then
    HOST_CALL_REASON="status cache/rate limiter cannot record a lookup for $host"
    return 2
  fi
  if ! chmod 0600 "$tmp" 2>/dev/null || ! mv -f -- "$tmp" "$marker" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null || true
    HOST_CALL_REASON="status cache/rate limiter cannot record a lookup for $host"
    return 2
  fi
  return 0
}

# Read a per-host token from its restrictive local path. A token file that is a
# symlink, not a regular file, or readable beyond its owner is refused outright:
# a credential stored carelessly is a finding, not something to quietly use.
read_forge_token() {  # <host> -> prints token, or returns 1
  local host=$1 path mode
  path="$CONFIG/forge-tokens/$host"
  [ -e "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 2
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$path" 2>/dev/null)
  else
    mode=$(stat -c %a "$path" 2>/dev/null)
  fi
  [ "$mode" = 600 ] || return 2
  head -n 1 "$path"
}

# --- per-forge adapters -----------------------------------------------------
#
# Each adapter sets LOOKUP_STATUS (ok|unavailable), LOOKUP_STATE (open|closed)
# and LOOKUP_DETAIL (title, or the reason when unavailable), and always returns
# 0. A forge without an adapter reports that as its reason.

adapter_github() {  # <host> <path> <number>
  local host=$1 path=$2 number=$3 output state title rc=0
  if [ "$host" != github.com ]; then
    LOOKUP_STATUS=unavailable; LOOKUP_STATE=
    LOOKUP_DETAIL="GitHub status enrichment is not implemented for host $host; the link still resolves"
    return 0
  fi
  if ! command -v gh-axi >/dev/null 2>&1; then
    LOOKUP_STATUS=unavailable; LOOKUP_STATE=; LOOKUP_DETAIL="gh-axi is not installed"
    return 0
  fi
  output=$(fm_run_timed "$LOOKUP_TIMEOUT" gh-axi issue view "$number" --repo "$path" --full 2>&1) || rc=$?
  case "$rc" in
    0) ;;
    124|137)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="GitHub lookup timed out after ${LOOKUP_TIMEOUT}s"
      return 0
      ;;
    125)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="GitHub lookup unavailable because no bounded timeout runner could start"
      return 0
      ;;
    *)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="GitHub lookup failed (issue missing, repository private, or credential expired)"
      return 0
      ;;
  esac
  state=$(printf '%s\n' "$output" | awk '$1 == "state:" { print $2; exit }')
  title=$(printf '%s\n' "$output" | awk '
    $1 == "title:" { sub(/^[[:space:]]*title:[[:space:]]*/, ""); print; exit }')
  title=${title%\"}
  title=${title#\"}
  case "$state" in
    open|closed) ;;
    *)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="GitHub returned no readable issue state"
      return 0
      ;;
  esac
  LOOKUP_STATUS=ok; LOOKUP_STATE=$state; LOOKUP_DETAIL=$(sanitize "$title")
}

# Gitea's REST API returns {"title": ..., "state": "open"|"closed"}. Its issue
# and pull-request numbering share one sequence, so a number that names a pull
# request answers here too; that is Gitea's own identity model, not a mismatch.
adapter_gitea() {  # <host> <path> <number>
  local host=$1 path=$2 number=$3 token token_rc=0 body code response response_rc=0
  if ! command -v curl >/dev/null 2>&1; then
    LOOKUP_STATUS=unavailable; LOOKUP_STATE=; LOOKUP_DETAIL="curl is not installed"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    LOOKUP_STATUS=unavailable; LOOKUP_STATE=; LOOKUP_DETAIL="jq is not installed"
    return 0
  fi
  token=$(read_forge_token "$host") || token_rc=$?
  if [ "$token_rc" -eq 2 ]; then
    LOOKUP_STATUS=unavailable; LOOKUP_STATE=
    LOOKUP_DETAIL="refusing the token at config/forge-tokens/$host: it must be a regular file with mode 0600"
    return 0
  fi
  # The credential travels through a stdin config file, so it never appears in
  # this process's arguments and never reaches a log or the cache.
  if [ "$token_rc" -eq 0 ] && [ -n "$token" ]; then
    response=$(printf 'header = "Authorization: token %s"\n' "$token" \
      | fm_run_timed "$LOOKUP_TIMEOUT" curl -sS -K - -m "$LOOKUP_TIMEOUT" -w '\n%{http_code}' \
        -H 'Accept: application/json' \
        "https://$host/api/v1/repos/$path/issues/$number" 2>/dev/null) || response_rc=$?
  else
    response=$(fm_run_timed "$LOOKUP_TIMEOUT" curl -sS -m "$LOOKUP_TIMEOUT" -w '\n%{http_code}' \
      -H 'Accept: application/json' \
      "https://$host/api/v1/repos/$path/issues/$number" 2>/dev/null) || response_rc=$?
  fi
  case "$response_rc" in
    0) ;;
    28|124|137)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="Gitea lookup timed out after ${LOOKUP_TIMEOUT}s"
      return 0
      ;;
    125)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="Gitea lookup unavailable because no bounded timeout runner could start"
      return 0
      ;;
  esac
  if [ -z "$response" ]; then
    LOOKUP_STATUS=unavailable; LOOKUP_STATE=
    LOOKUP_DETAIL="Gitea host $host is unreachable"
    return 0
  fi
  code=${response##*$'\n'}
  body=${response%$'\n'*}
  case "$code" in
    200) ;;
    401|403)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="Gitea rejected the credential for $host (HTTP $code)"
      return 0
      ;;
    404)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="Gitea issue not found (deleted, or the repository is private to this credential)"
      return 0
      ;;
    *)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="Gitea host $host answered HTTP $code"
      return 0
      ;;
  esac
  local state title
  state=$(printf '%s' "$body" | jq -r '.state // empty' 2>/dev/null) || state=
  title=$(printf '%s' "$body" | jq -r '.title // empty' 2>/dev/null) || title=
  case "$state" in
    open|closed) ;;
    *)
      LOOKUP_STATUS=unavailable; LOOKUP_STATE=
      LOOKUP_DETAIL="Gitea returned no readable issue state"
      return 0
      ;;
  esac
  LOOKUP_STATUS=ok; LOOKUP_STATE=$state; LOOKUP_DETAIL=$(sanitize "$title")
}

lookup() {  # <forge> <host> <path> <number>
  LOOKUP_STATUS=unavailable; LOOKUP_STATE=; LOOKUP_DETAIL=
  case "$1" in
    github) adapter_github "$2" "$3" "$4" ;;
    gitea) adapter_gitea "$2" "$3" "$4" ;;
    gitlab)
      LOOKUP_DETAIL="GitLab issue status enrichment is not implemented; the link still resolves"
      ;;
    *)
      LOOKUP_DETAIL="no status adapter for forge $1"
      ;;
  esac
}

emit_tsv() {  # <url> <status> <state> <detail>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "$4"
}

json_escape() {  # <text>
  local text=$1 output='' char code escaped
  local LC_ALL=C
  while [ -n "$text" ]; do
    char=${text:0:1}
    text=${text:1}
    printf -v code '%d' "'$char"
    case "$code" in
      8) output="${output}\\b" ;;
      9) output="${output}\\t" ;;
      10) output="${output}\\n" ;;
      12) output="${output}\\f" ;;
      13) output="${output}\\r" ;;
      34) output="${output}\\\"" ;;
      92) output="${output}\\\\" ;;
      0|[1-9]|1[0-9]|2[0-9]|3[01])
        printf -v escaped '\\u%04x' "$code"
        output="${output}${escaped}"
        ;;
      *) output="${output}${char}" ;;
    esac
  done
  printf '%s' "$output"
}

RESULT_URLS=()
RESULT_STATUS=()
RESULT_STATE=()
RESULT_DETAIL=()

for record in "${RECORDS[@]}"; do
  if ! fm_issue_work_item_parse "$record"; then
    RESULT_URLS+=("$(sanitize "$record")")
    RESULT_STATUS+=(unavailable)
    RESULT_STATE+=("")
    RESULT_DETAIL+=("malformed work-item record")
    continue
  fi
  url=$FM_ISSUE_URL
  status=; state=; detail=
  host_call_rc=0
  if [ "$REFRESH" -eq 0 ] && cache_read "$url" && [ "$CACHED_AGE" -lt "$TTL" ]; then
    status=$CACHED_STATUS; state=$CACHED_STATE; detail=$CACHED_DETAIL
  else
    host_may_call "$FM_ISSUE_HOST" || host_call_rc=$?
    if [ "$host_call_rc" -eq 0 ]; then
      lookup "$FM_ISSUE_FORGE" "$FM_ISSUE_HOST" "$FM_ISSUE_PATH" "$FM_ISSUE_NUMBER"
      status=$LOOKUP_STATUS; state=$LOOKUP_STATE; detail=$LOOKUP_DETAIL
      cache_write "$url" "$status" "$state" "$detail"
    elif [ "$host_call_rc" -eq 2 ]; then
      status=unavailable; state=; detail=$HOST_CALL_REASON
    elif cache_read "$url"; then
      status=$CACHED_STATUS; state=$CACHED_STATE
      detail="$CACHED_DETAIL (cached ${CACHED_AGE}s ago)"
    else
      status=unavailable; state=
      detail="throttled: $FM_ISSUE_HOST was queried within the last ${MIN_INTERVAL}s"
    fi
  fi
  RESULT_URLS+=("$url")
  RESULT_STATUS+=("$status")
  RESULT_STATE+=("$state")
  RESULT_DETAIL+=("$detail")
done

if [ "$FORMAT" = tsv ]; then
  i=0
  while [ "$i" -lt "${#RESULT_URLS[@]}" ]; do
    emit_tsv "${RESULT_URLS[$i]}" "${RESULT_STATUS[$i]}" "${RESULT_STATE[$i]}" "${RESULT_DETAIL[$i]}"
    i=$((i + 1))
  done
  exit 0
fi

printf '[\n'
i=0
sep=
while [ "$i" -lt "${#RESULT_URLS[@]}" ]; do
  printf '%s' "$sep"
  printf '  {"url": "%s", "status": "%s", ' \
    "$(json_escape "${RESULT_URLS[$i]}")" "${RESULT_STATUS[$i]}"
  if [ "${RESULT_STATUS[$i]}" = ok ]; then
    printf '"state": "%s", "title": "%s", "reason": null}' \
      "${RESULT_STATE[$i]}" "$(json_escape "${RESULT_DETAIL[$i]}")"
  else
    printf '"state": null, "title": null, "reason": "%s"}' \
      "$(json_escape "${RESULT_DETAIL[$i]}")"
  fi
  sep=',
'
  i=$((i + 1))
done
printf '\n]\n'
