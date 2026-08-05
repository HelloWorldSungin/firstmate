#!/usr/bin/env bash
# fm-dashboard-instrument.sh - turn the dashboard's agent-event timeline on or off.
#
#   fm-dashboard-instrument.sh enable [--url URL] [--port PORT]
#   fm-dashboard-instrument.sh disable
#   fm-dashboard-instrument.sh status
#
# Instrumentation is off until this command turns it on, and it is one file's
# presence the whole way down. `enable` writes a private configuration pair:
#
#   dashboard-events.json    the ingest URL and token, read by the dashboard
#   dashboard-events.curlrc  the same token as private curl options, read by
#                            bin/fm-event-emit.sh so the token never appears in
#                            this machine's process list
#
# With those present, bin/fm-spawn.sh wires each new task's own harness hooks to
# report lifecycle events, and the dashboard accepts them. With them absent -
# which is what `disable` leaves behind - fm-spawn writes the same hook files it
# wrote before this feature existed, the emitter returns without doing anything,
# and the dashboard answers every post with "not configured". Nothing else has
# to be undone, and no already-running agent is disturbed either way.
#
# Both files are mode 0600 under the user configuration root. Neither this
# command nor the dashboard writes anything into an operational home.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SERVER="$SCRIPT_DIR/fm-dashboard-server.mjs"

usage() {
  cat <<'EOF'
usage: fm-dashboard-instrument.sh enable [--url URL] [--port PORT] [--config PATH]
       fm-dashboard-instrument.sh disable [--config PATH]
       fm-dashboard-instrument.sh status [--config PATH]

Enable or disable the dashboard's per-agent live event timeline.

Options:
  --url URL       full ingest URL (default http://127.0.0.1:<port>/events)
  --port PORT     dashboard port when no URL is given (default 8787)
  --config PATH   configuration file path (default
                  $XDG_CONFIG_HOME/firstmate/dashboard-events.json)
  -h, --help      show this help

enable is idempotent for the URL and rotates the token every time, so a leaked
token is retired by running it again. status prints one JSON object.
EOF
}

COMMAND=${1:-}
case "$COMMAND" in
  enable|disable|status) shift ;;
  -h|--help|'') usage; exit 0 ;;
  *) printf 'fm-dashboard-instrument: unknown command: %s\n' "$COMMAND" >&2; usage >&2; exit 2 ;;
esac

XDG_CONFIG_ROOT=${XDG_CONFIG_HOME:-"$HOME/.config"}
CONFIG=${FM_DASHBOARD_EVENTS_CONFIG:-"$XDG_CONFIG_ROOT/firstmate/dashboard-events.json"}
PORT=8787
URL=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url|--port|--config)
      [ "$#" -ge 2 ] || { printf 'fm-dashboard-instrument: %s requires a value\n' "$1" >&2; exit 2; }
      case "$1" in
        --url) URL=$2 ;;
        --port) PORT=$2 ;;
        --config) CONFIG=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-dashboard-instrument: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

CURLRC=${CONFIG%.json}.curlrc
case "$CONFIG" in
  *.json) ;;
  *) echo "fm-dashboard-instrument: --config must name a .json file" >&2; exit 2 ;;
esac

json_string() {  # <value>
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037')"
}

if [ "$COMMAND" = disable ]; then
  rm -f "$CONFIG" "$CURLRC"
  printf 'Instrumentation disabled. Removed %s and %s.\n' "$CONFIG" "$CURLRC"
  printf 'New tasks are wired exactly as they were before instrumentation, and stored events are kept until they age out.\n'
  exit 0
fi

if [ "$COMMAND" = status ]; then
  enabled=false
  url=null
  [ -f "$CONFIG" ] && [ -f "$CURLRC" ] && enabled=true
  if [ "$enabled" = true ]; then
    url=$(sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -n 1)
    url=$(json_string "$url")
  fi
  store=null
  if [ -x "$SERVER" ] && command -v node >/dev/null 2>&1; then
    resolved=$(node "$SERVER" --event-store-path 2>/dev/null || true)
    [ -n "$resolved" ] && store=$(json_string "$resolved")
  fi
  printf '{"schema":"fm-dashboard-instrument-status.v1","enabled":%s,"config":%s,"url":%s,"store":%s}\n' \
    "$enabled" "$(json_string "$CONFIG")" "$url" "$store"
  exit 0
fi

# --- enable -----------------------------------------------------------------

case "$PORT" in
  ''|*[!0-9]*) echo "fm-dashboard-instrument: --port must be an integer" >&2; exit 2 ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] \
  || { echo "fm-dashboard-instrument: --port must be between 1 and 65535" >&2; exit 2; }

[ -n "$URL" ] || URL="http://127.0.0.1:$PORT/events"
# An instrumentation target that is not loopback would send fleet activity off
# this machine. Refuse it here rather than discover it in a packet capture. A
# dashboard exposed beyond loopback keeps a loopback listener for exactly this
# reason, so producers never need a target that leaves the host.
case "$URL" in
  http://127.0.0.1:*/*|http://127.0.0.1/*|http://\[::1\]:*/*|http://localhost:*/*|http://localhost/*) ;;
  *) echo "fm-dashboard-instrument: --url must address the loopback dashboard" >&2; exit 2 ;;
esac
# The URL is written verbatim into a JSON document and a curl configuration
# line, so a quote, a backslash, or a newline in it would corrupt both.
case "$URL" in
  *[\"\\]*|*$'\n'*) echo "fm-dashboard-instrument: --url contains an unsupported character" >&2; exit 2 ;;
esac

TOKEN=$(od -An -tx1 -N 32 /dev/urandom 2>/dev/null | tr -d ' \n')
[ "${#TOKEN}" -eq 64 ] || { echo "fm-dashboard-instrument: could not generate an ingest token" >&2; exit 1; }

CONFIG_DIR=$(dirname "$CONFIG")
install -d -m 700 "$CONFIG_DIR"
CONFIG_TMP=$(mktemp "$CONFIG_DIR/.dashboard-events.json.XXXXXX")
CURLRC_TMP=$(mktemp "$CONFIG_DIR/.dashboard-events.curlrc.XXXXXX")
trap 'rm -f "$CONFIG_TMP" "$CURLRC_TMP"' EXIT HUP INT TERM

printf '{"schema":"fm-dashboard-events-config.v1","url":"%s","token":"%s"}\n' "$URL" "$TOKEN" > "$CONFIG_TMP"
chmod 600 "$CONFIG_TMP"

{
  printf 'url = "%s"\n' "$URL"
  printf 'request = "POST"\n'
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
  printf 'header = "Content-Type: application/json"\n'
  printf 'silent\n'
  printf 'output = "/dev/null"\n'
} > "$CURLRC_TMP"
chmod 600 "$CURLRC_TMP"

mv -f "$CONFIG_TMP" "$CONFIG"
mv -f "$CURLRC_TMP" "$CURLRC"
trap - EXIT HUP INT TERM

printf 'Instrumentation enabled for %s\n' "$URL"
printf 'Configured %s and %s\n' "$CONFIG" "$CURLRC"
printf 'Tasks dispatched from now on report lifecycle events; tasks already running are untouched.\n'
printf 'A running dashboard picks the new token up on its own - no restart is needed.\n'
