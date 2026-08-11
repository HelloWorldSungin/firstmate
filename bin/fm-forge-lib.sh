# shellcheck shell=bash
# FM_FORGE_HTTP_CODE, FM_FORGE_OUTCOME, and FM_FORGE_REASON are this library's
# published outputs: assigned throughout, and read only by the sourcing scripts
# that this file cannot see from here.
# shellcheck disable=SC2034
#
# fm-forge-lib.sh - the single owner of per-host forge credential resolution,
# the bounded argv-free authenticated transport, and the complete allowlist of
# tracker WRITE operations firstmate may perform on a non-GitHub forge.
#
# The read side (bin/fm-issue-status.sh) and the write side
# (bin/fm-issue-comment.sh, bin/fm-pr-merge.sh) resolve the same
# config/forge-tokens/<host> credential through the same function here, so the
# refusal rules cannot drift between them. The security properties this library
# holds for every caller:
#
#   - A token file must be a regular non-symlink file with mode 0600. Anything
#     looser is refused (return 2) rather than used: a credential stored
#     carelessly is a finding, not something to quietly use. An absent file is
#     return 1, which read paths may treat as "unauthenticated" and write paths
#     must treat as "no credential". A file that is present and correctly moded
#     but holds no token on its first line is return 3, a third fact that is
#     neither "absent" nor "usable" and must be reported as itself.
#   - The token reaches curl only through a stdin config file (`-K -`), so it
#     never appears in any process's arguments, and it is never printed,
#     logged, or cached by anything here.
#   - config/ is gitignored in full, and forge-tokens is deliberately absent
#     from the inheritable-config allowlist in bin/fm-config-inherit-lib.sh,
#     so a secondmate home never receives another home's forge credentials.
#
# WRITE ALLOWLIST, AND WHY IT IS STRUCTURAL RATHER THAN ADVISORY. The fm_gitea_*
# functions below are the only entry points that reach a forge, and they cover
# exactly what firstmate's tracker lifecycle needs: reading an issue and its
# comments, creating or editing firstmate's own status comment, posting the
# merge-link comment, and closing the issue. Two properties, not one convention,
# are what hold that:
#
#   - The authenticated transport is _fm_forge_curl and the request builder is
#     _fm_forge_gitea_call. Both are private, so no caller - present or future -
#     is offered any way to name a method, a URL, or a body of its own. Sourcing
#     this library therefore grants the named operations and nothing wider; a
#     script that wants another endpoint must add it HERE, in the reviewed
#     allowlist, which is the whole point.
#   - The public surface is pinned by a test that sources this library and
#     compares the set of exported function names against the allowlist, so a
#     re-exported general transport fails the suite rather than passing review
#     unnoticed (tests/fm-issue-writeback.test.sh).
#
# So nothing here can touch a branch, release, repository setting, permission,
# or any other forge object: a wider credential on disk gains no extra reach
# through this library, which is what lets the captain issue a narrow token and
# revoke a wide one.
#
# Minimum viable credential per forge - issue a token no wider than this:
#   github.com  the ambient gh/gh-axi authentication; a fine-grained token
#               needs only "Issues: Read and write" on the target repository
#               (classic tokens: the repo scope). No config/forge-tokens entry
#               is read for github.com.
#   gitea       config/forge-tokens/<host> holding a scoped access token with
#               read:issue and write:issue for an account that can see the
#               target repository. Repository admin or write:repository is NOT
#               required and should not be granted.
#   gitlab      no write adapter yet; fm_forge_write_supported says so
#               honestly rather than faking one.
#
# EXTENSION PATH. The next forge is an adapter, not a redesign: add its
# operation functions here (the same five operations, nothing more), teach
# fm_forge_write_supported to accept it, state its minimum token scope above,
# and give bin/fm-issue-comment.sh and bin/fm-pr-merge.sh their per-forge
# dispatch branch. Until that lands, fm_forge_write_supported reports the gap
# as a missing adapter, which is a different fact from a missing credential.
#
# Failure reporting: each operation returns 0 only on an HTTP 2xx answer.
# On any other outcome it returns 1 with FM_FORGE_REASON holding a one-line
# reason that distinguishes an unreachable host, a timeout, a refused
# credential (HTTP 401/403), a missing target (404), and any other answer,
# and FM_FORGE_HTTP_CODE holding the code when one was received.
# FM_FORGE_OUTCOME carries the same distinction as a fixed token - ok, timeout,
# no-runner, unreachable, http, or local - for a caller that words its own
# report rather than repeating this library's phrasing. Callers stay fail-open:
# they warn with the reason and exit 0, never fail the operation that already
# succeeded around them.
#
# Request payloads are staged in the caller's own scratch directory, named once
# through fm_forge_scratch_set, because every caller already bounds itself and
# already removes that directory on any exit. Nothing here creates a file the
# caller's cleanup does not already cover.
#
# Requires bash. Sources bin/fm-timeout-lib.sh for the bounded-call contract.
# No other side effects on source. set -u / set -e safe.

_FM_FORGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_FORGE_LIB_DIR/fm-timeout-lib.sh"

# Published outputs, read by sourcing scripts after each call.
FM_FORGE_HTTP_CODE=
FM_FORGE_OUTCOME=
FM_FORGE_REASON=

# The caller's own scratch directory, where request payloads are staged.
_FM_FORGE_SCRATCH=
_FM_FORGE_PAYLOAD=

# Read a per-host token from its restrictive local path.
# Prints the token and returns 0; returns 1 when absent; returns 2 when the
# file exists but is a symlink, not a regular file, or readable beyond its
# owner, which callers must report rather than work around; returns 3 when the
# file is there and correctly moded but its first line holds no token, which is
# a different fact from an absent file and must not be reported as one.
fm_forge_token_read() {  # <config-dir> <host>
  local config=$1 host=$2 path mode token
  path="$config/forge-tokens/$host"
  [ -e "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 2
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$path" 2>/dev/null)
  else
    mode=$(stat -c %a "$path" 2>/dev/null)
  fi
  [ "$mode" = 600 ] || return 2
  token=$(head -n 1 "$path" 2>/dev/null)
  [ -n "${token//[[:space:]]/}" ] || return 3
  printf '%s\n' "$token"
}

# Name the caller's trap-covered working directory as the place request
# payloads are staged, so no file this library writes can outlive the caller.
fm_forge_scratch_set() {  # <dir>
  _FM_FORGE_SCRATCH=$1
}

# Stage one payload file inside that directory, into _FM_FORGE_PAYLOAD.
_fm_forge_payload_file() {
  _FM_FORGE_PAYLOAD=
  FM_FORGE_HTTP_CODE=
  FM_FORGE_OUTCOME=local
  if [ -z "$_FM_FORGE_SCRATCH" ] || [ ! -d "$_FM_FORGE_SCRATCH" ]; then
    FM_FORGE_REASON="no caller-owned working directory was named for the request payload, so nothing was sent"
    return 1
  fi
  _FM_FORGE_PAYLOAD=$(mktemp "$_FM_FORGE_SCRATCH/payload.XXXXXX") || {
    FM_FORGE_REASON="could not create a temporary file"
    return 1
  }
}

# Bounded curl with the credential passed through a stdin config file, so it
# never appears in process arguments. An empty token runs unauthenticated.
# Returns curl's own exit code, or 124/137/125 from the outer bound.
# PRIVATE, and deliberately so: see the write-allowlist note in the header.
_fm_forge_curl() {  # <bound> <token> <curl-args...>
  local bound=$1 token=$2
  shift 2
  if [ -n "$token" ]; then
    printf 'header = "Authorization: token %s"\n' "$token" \
      | fm_run_timed "$bound" curl -sS -K - -m "$bound" "$@"
  else
    fm_run_timed "$bound" curl -sS -m "$bound" "$@"
  fi
}

# Which forge/host pairs have a WRITE adapter. Distinct from holding a
# credential: this is "does firstmate know how to write there at all".
# Returns 0 when supported; 1 with FM_FORGE_REASON naming the honest gap.
fm_forge_write_supported() {  # <forge> <host>
  FM_FORGE_REASON=
  case "$1" in
    github)
      [ "$2" = github.com ] && return 0
      FM_FORGE_REASON="firstmate has no write-back adapter for self-hosted GitHub host $2 yet"
      return 1
      ;;
    gitea)
      return 0
      ;;
    gitlab)
      FM_FORGE_REASON="firstmate has no GitLab write-back adapter yet"
      return 1
      ;;
    *)
      FM_FORGE_REASON="firstmate has no write-back adapter for forge $1"
      return 1
      ;;
  esac
}

# One bounded Gitea API call. Internal to this library: the operation
# functions below are the public surface, so the set of reachable endpoints
# stays the allowlist the header declares.
_fm_forge_gitea_call() {  # <bound> <token> <host> <method> <api-path> <out-file> [json-body-file]
  local bound=$1 token=$2 host=$3 method=$4 api=$5 out=$6 body=${7-} rc=0 code
  FM_FORGE_HTTP_CODE=
  FM_FORGE_OUTCOME=
  FM_FORGE_REASON=
  local -a args
  args=(-o "$out" -w '%{http_code}' -H 'Accept: application/json')
  case "$method" in
    GET) ;;
    *) args+=(-X "$method") ;;
  esac
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  fi
  code=$(_fm_forge_curl "$bound" "$token" "${args[@]}" "https://$host$api" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    28|124|137)
      FM_FORGE_OUTCOME=timeout
      FM_FORGE_REASON="$host did not answer within ${bound}s"
      return 1
      ;;
    125)
      FM_FORGE_OUTCOME=no-runner
      FM_FORGE_REASON="no bounded timeout runner could start, so nothing was sent"
      return 1
      ;;
    *)
      FM_FORGE_OUTCOME=unreachable
      FM_FORGE_REASON="$host is unreachable"
      return 1
      ;;
  esac
  if [ -z "$code" ]; then
    FM_FORGE_OUTCOME=unreachable
    FM_FORGE_REASON="$host is unreachable"
    return 1
  fi
  FM_FORGE_HTTP_CODE=$code
  FM_FORGE_OUTCOME=http
  case "$code" in
    2[0-9][0-9]) FM_FORGE_OUTCOME=ok; return 0 ;;
    401|403)
      FM_FORGE_REASON="$host refused the credential (HTTP $code); it may lack issue write scope or access to this repository"
      return 1
      ;;
    404)
      FM_FORGE_REASON="not found on $host (the issue may be deleted, or the repository is not visible to this credential)"
      return 1
      ;;
    *)
      FM_FORGE_REASON="$host answered HTTP $code"
      return 1
      ;;
  esac
}

# Wrap raw text from <text-file> as the {"body": ...} JSON payload the comment
# endpoints take, into <payload-file>. Needs jq, which callers verify first.
_fm_forge_gitea_body_payload() {  # <text-file> <payload-file>
  if ! jq -Rs '{body: .}' < "$1" > "$2" 2>/dev/null; then
    FM_FORGE_HTTP_CODE=
    FM_FORGE_OUTCOME=local
    FM_FORGE_REASON="could not encode the comment body"
    return 1
  fi
}

# --- the write-operation allowlist -------------------------------------------

fm_gitea_comments_page() {  # <bound> <token> <host> <path> <number> <page> <out-file>
  _fm_forge_gitea_call "$1" "$2" "$3" GET \
    "/api/v1/repos/$4/issues/$5/comments?page=$6&limit=50" "$7"
}

fm_gitea_comment_update() {  # <bound> <token> <host> <path> <comment-id> <body-file>
  local payload rc=0
  _fm_forge_payload_file || return 1
  payload=$_FM_FORGE_PAYLOAD
  if _fm_forge_gitea_body_payload "$6" "$payload"; then
    _fm_forge_gitea_call "$1" "$2" "$3" PATCH \
      "/api/v1/repos/$4/issues/comments/$5" /dev/null "$payload" || rc=1
  else
    rc=1
  fi
  rm -f -- "$payload"
  return "$rc"
}

fm_gitea_comment_create() {  # <bound> <token> <host> <path> <number> <body-file>
  local payload rc=0
  _fm_forge_payload_file || return 1
  payload=$_FM_FORGE_PAYLOAD
  if _fm_forge_gitea_body_payload "$6" "$payload"; then
    _fm_forge_gitea_call "$1" "$2" "$3" POST \
      "/api/v1/repos/$4/issues/$5/comments" /dev/null "$payload" || rc=1
  else
    rc=1
  fi
  rm -f -- "$payload"
  return "$rc"
}

fm_gitea_issue_read() {  # <bound> <token> <host> <path> <number> <out-file>
  _fm_forge_gitea_call "$1" "$2" "$3" GET "/api/v1/repos/$4/issues/$5" "$6"
}

fm_gitea_issue_close() {  # <bound> <token> <host> <path> <number>
  local payload rc=0
  _fm_forge_payload_file || return 1
  payload=$_FM_FORGE_PAYLOAD
  printf '{"state":"closed"}\n' > "$payload"
  _fm_forge_gitea_call "$1" "$2" "$3" PATCH \
    "/api/v1/repos/$4/issues/$5" /dev/null "$payload" || rc=1
  rm -f -- "$payload"
  return "$rc"
}
