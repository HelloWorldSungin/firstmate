#!/usr/bin/env bash
# fm-event-emit.sh - the one producer-side boundary for dashboard agent events.
#
#   fm-event-emit.sh --task <id> --harness <name> --type <type> [options]
#
# Every harness adapter calls this and nothing else, which is why the wire stays
# harness-agnostic: an adapter translates its own native event into this
# vocabulary and adds no field of its own.
#
# THREE PROPERTIES THIS SCRIPT EXISTS TO GUARANTEE
#
#   1. It cannot fail a harness action. It exits 0 on every path - missing
#      configuration, missing curl, malformed input, an unreachable dashboard,
#      an argument it does not recognize. Standard output and standard error are
#      closed to /dev/null before any work, so it can never colour a hook
#      decision that reads them (Claude Code, for one, only honours a PreToolUse
#      deny when the hook wrote nothing to stdout).
#
#   2. It cannot delay a harness action. The foreground does argument
#      validation and one drain of the hook payload, then forks. All parsing,
#      configuration reading, and network work happen in that detached child, so
#      a dashboard that is down, hung, or answering slowly costs the harness one
#      fork rather than a timeout. Nothing is retried and nothing is spooled: a
#      lost live event is a gap in a view, and a view is not worth a stalled
#      agent.
#
#   3. It cannot leak. The producer never forwards free text. Every field is
#      rebuilt from a validated token, and a value that does not match its
#      pattern is dropped rather than sent. The payload has no field a prompt,
#      a response, a tool argument, a file body, an environment value, or an
#      absolute path could travel in, and --from-stdin reads exactly two
#      pattern-matched values out of a hook payload and ignores the rest.
#
# The server applies its own independent allowlist to everything that arrives
# here; docs/dashboard-events.md owns both boundaries and
# tests/fm-dashboard-events.test.sh seeds hostile values at each of them.
#
# Instrumentation is presence-gated: with no configuration file this script
# reads its input and returns, so removing the configuration restores stock
# harness behaviour with no other change.
set -u

usage() {
  cat <<'EOF'
usage: fm-event-emit.sh --task <id> --harness <name> --type <type>
                        [--session <id>] [--tool <name>] [--outcome <o>]
                        [--summary <text>] [--from-stdin]

Report one agent lifecycle event to the fleet dashboard. Always exits 0 and
always prints nothing. Absent configuration means no event source.

  --type      session_start | prompt_submitted | tool_started | tool_finished |
              turn_ended | session_end | notification
  --outcome   ok | error | blocked | unknown
  --from-stdin  read the harness hook payload on stdin and take only the tool
                name and session id out of it

Environment:
  FM_DASHBOARD_EVENTS_CONFIG   configuration directory override (default
                               $XDG_CONFIG_HOME/firstmate/dashboard-events.json)
  FM_EVENT_CONNECT_TIMEOUT     connect deadline in seconds (default 0.3)
  FM_EVENT_MAX_TIME            total request deadline in seconds (default 1.5)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# Structural silence. Nothing below this line can reach a harness, whatever it
# does. This is the guarantee, not a convention: no later edit can accidentally
# print into a hook decision.
exec >/dev/null 2>&1

TASK=
HARNESS=
TYPE=
SESSION=
TOOL=
OUTCOME=
SUMMARY=
FROM_STDIN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:-}; shift 2 || exit 0 ;;
    --harness) HARNESS=${2:-}; shift 2 || exit 0 ;;
    --type) TYPE=${2:-}; shift 2 || exit 0 ;;
    --session) SESSION=${2:-}; shift 2 || exit 0 ;;
    --tool) TOOL=${2:-}; shift 2 || exit 0 ;;
    --outcome) OUTCOME=${2:-}; shift 2 || exit 0 ;;
    --summary) SUMMARY=${2:-}; shift 2 || exit 0 ;;
    --from-stdin) FROM_STDIN=1; shift ;;
    *) shift ;;
  esac
done

CONFIG=${FM_DASHBOARD_EVENTS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/dashboard-events.json}
CURLRC=${CONFIG%.json}.curlrc

# --- the allowlist ----------------------------------------------------------
#
# Each field is admitted only by its own pattern. There is deliberately no
# escaping step anywhere below: a value that reached the payload passed a
# pattern that cannot contain a quote, a backslash, or a control character, so
# the JSON is built by concatenation and is well formed by construction.

matches() {  # <value> <extended-regex>
  printf '%s' "$1" | grep -Eq "$2"
}

# The same two predicates the server keeps, split the same way and applied to
# the same fields, so producer and server never disagree about what a value is.
#
#   has_credential_prefix  the named vendor shapes only. No false positives, so
#                          it is safe on any field, and it is what guards `tool`.
#   looks_like_credential  those prefixes plus a long mixed letter-and-digit
#                          run. A content-scanning rule for a free-form value,
#                          and `summary` is the only one this schema has.
#
# bin/fm-event-store.mjs's header owns why an identifier field must not carry
# the entropy rule: a tool name is one unbroken run by construction, so it would
# blank every MCP tool name of 24 or more characters containing a digit.
has_credential_prefix() {  # <value>
  printf '%s' "$1" | grep -Eq 'sk-[A-Za-z0-9]|gh[pousr]_[A-Za-z0-9]|github_pat_|glpat-|xox[abprs]-|A[KS]IA[A-Z0-9]|AIza[A-Za-z0-9]|-----BEGIN'
}

looks_like_credential() {  # <value>
  has_credential_prefix "$1" && return 0
  printf '%s' "$1" | grep -Eq '[A-Za-z0-9+/=_-]{24,}' || return 1
  printf '%s' "$1" | grep -oE '[A-Za-z0-9+/=_-]{24,}' | grep -q '[A-Za-z]' || return 1
  printf '%s' "$1" | grep -oE '[A-Za-z0-9+/=_-]{24,}' | grep -q '[0-9]'
}

# A summary may use only these characters - no slash, so an absolute path
# cannot survive; no equals or at-sign, so an assignment or an address cannot
# either - and no unbroken run long enough to be a token. Human summaries have
# spaces; secrets do not.
safe_summary() {  # <value>
  local value=$1 word
  value=$(printf '%s' "$value" | tr -d '\000-\037\177' | tr -s '[:space:]' ' ')
  value=${value# }
  value=${value% }
  [ -n "$value" ] || return 1
  [ "${#value}" -le 80 ] || return 1
  matches "$value" '^[A-Za-z0-9 .,_:#()-]+$' || return 1
  for word in $value; do
    [ "${#word}" -le 15 ] || return 1
  done
  looks_like_credential "$value" && return 1
  printf '%s' "$value"
}

# Everything past this point runs off the harness's critical path - the
# configuration check, the validation, the read of the hook payload, and the
# request. Draining the payload matters (a harness writing into a pipe nobody
# reads can block), but it must never be the foreground's problem: an unclosed
# standard input would otherwise hold the hook open for as long as the writer
# felt like it. The detached child inherits the pipe and drains it, so this
# script's own cost to a harness is one fork whatever the answer turns out to be.
#
# The payload has to travel on a descriptor of its own: a shell reassigns an
# asynchronous list's standard input to /dev/null before any explicit
# redirection, so a child that simply read stdin would find an empty payload
# every time and silently report no tool and no session.
exec 3<&0 || true
{
  PAYLOAD=
  if [ "$FROM_STDIN" -eq 1 ]; then
    PAYLOAD=$(cat <&3 2>/dev/null || true)
    PAYLOAD=${PAYLOAD:0:65536}
  else
    cat <&3 >/dev/null 2>&1 || true
  fi

  # No configuration means no event source, which is also what removing the
  # instrumentation leaves behind.
  [ -f "$CONFIG" ] && [ -f "$CURLRC" ] || exit 0
  command -v curl >/dev/null 2>&1 || exit 0

  matches "$TASK" '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$' || exit 0
  matches "$HARNESS" '^[a-z][a-z0-9-]{0,31}$' || exit 0
  case "$TYPE" in
    session_start|prompt_submitted|tool_started|tool_finished|turn_ended|session_end|notification) ;;
    *) exit 0 ;;
  esac
  case "$OUTCOME" in
    ok|error|blocked|unknown) ;;
    *) OUTCOME= ;;
  esac

  # Two pattern-matched values out of a hook payload, and nothing else. The
  # payload is never stored, never logged, and never forwarded.
  if [ "$FROM_STDIN" -eq 1 ] && [ -n "$PAYLOAD" ]; then
    if [ -z "$TOOL" ]; then
      TOOL=$(printf '%s' "$PAYLOAD" \
        | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_.:-]\{1,64\}\)".*/\1/p' \
        | head -n 1)
    fi
    if [ -z "$SESSION" ]; then
      SESSION=$(printf '%s' "$PAYLOAD" \
        | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._:-]\{1,128\}\)".*/\1/p' \
        | head -n 1)
    fi
  fi

  matches "$TOOL" '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$' || TOOL=
  { [ -n "$TOOL" ] && has_credential_prefix "$TOOL"; } && TOOL=
  matches "$SESSION" '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' || SESSION=
  if [ -n "$SUMMARY" ]; then
    SUMMARY=$(safe_summary "$SUMMARY") || SUMMARY=
  fi

  OCCURRED=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || exit 0
  # Identity is the producer's, so a resend of the same event collapses in the
  # store instead of drawing a second entry on the timeline.
  #
  # The constant prefix and the bounded task slice are what make this id valid
  # for EVERY task id firstmate accepts. A task id may legally begin with - or _
  # and may run to 128 characters (bin/fm-pr-lib.sh's fm_task_id_creation_valid),
  # neither of which an event id may do - so composing one straight from the task
  # id used to fail the check below and discard every event that task ever
  # reported, silently and permanently. Identity is still per-event: the instant,
  # the pid, and two random values follow the task slice.
  EVENT_ID="e.${TASK:0:80}.$(date -u +%s 2>/dev/null).$$.${RANDOM:-0}${RANDOM:-0}"
  matches "$EVENT_ID" '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' || exit 0

  BODY="{\"schema\":\"fm-agent-event.v1\",\"events\":[{"
  BODY="$BODY\"event_id\":\"$EVENT_ID\""
  BODY="$BODY,\"task_id\":\"$TASK\""
  BODY="$BODY,\"harness\":\"$HARNESS\""
  BODY="$BODY,\"type\":\"$TYPE\""
  BODY="$BODY,\"occurred_at\":\"$OCCURRED\""
  [ -n "$SESSION" ] && BODY="$BODY,\"session_id\":\"$SESSION\""
  [ -n "$TOOL" ] && BODY="$BODY,\"tool\":\"$TOOL\""
  [ -n "$OUTCOME" ] && BODY="$BODY,\"outcome\":\"$OUTCOME\""
  [ -n "$SUMMARY" ] && BODY="$BODY,\"summary\":\"$SUMMARY\""
  BODY="$BODY}]}"

  # The bearer token lives in the private curl configuration rather than in an
  # argument, so it never appears in this machine's process list. Both deadlines
  # are short and there is no retry.
  curl --config "$CURLRC" \
    --connect-timeout "${FM_EVENT_CONNECT_TIMEOUT:-0.3}" \
    --max-time "${FM_EVENT_MAX_TIME:-1.5}" \
    --header "X-Firstmate-Source: $TASK/$HARNESS" \
    --data-binary "$BODY" || true
} >/dev/null 2>&1 &
exec 3<&- 2>/dev/null || true

exit 0
