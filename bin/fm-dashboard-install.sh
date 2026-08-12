#!/usr/bin/env bash
# fm-dashboard-install.sh - install the fleet dashboard as a user service.
#
# Writes one private environment file and one user-level systemd unit, then
# enables the service unless --no-start is passed. No sudo is used.
#
# The unit is emitted with unquoted absolute paths. systemd reads the argument
# of EnvironmentFile= and the members of ReadWritePaths= as paths, and a quoted
# path there is not accepted - it is logged once and the whole directive is
# ignored, which silently drops the environment file and the one write grant the
# service has. Anything that would need quoting is refused at generation time
# instead, so a unit this script writes is either literal and correct or not
# written at all.
#
# The unit also pins a PATH. systemd's user manager hands a service a minimal
# one, and the fleet snapshot this service runs shells out to tools that live in
# the operator's own bin directories; without a PATH every snapshot runs to its
# deadline and the dashboard serves a permanently empty view.
#
# The unit grants scratch space exactly once, through RuntimeDirectory= and the
# TMPDIR= pointing at it, so a panel that needs a temp file uses that grant
# rather than being rewritten to do without one.
# ProtectSystem=strict and ProtectHome=read-only leave every directory the
# service can reach read-only, so anything calling mktemp fails against healthy
# data - and so does bash itself, which needs a temp file for any here-document
# or here-string larger than a pipe buffer.
# Three panels discovered that separately before the grant existed: token usage,
# semantic search, and durable completed-work history.
#
# Do NOT reach for PrivateTmp=yes to grant it instead.
# It substitutes a private tmpfs for the shared /tmp, which hides the fleet's
# tmux server socket at /tmp/tmux-$UID from the snapshot this service runs and
# reports every live task's endpoint as absent - trading the false absences this
# grant fixes for a worse one in the primary view.
# RuntimeDirectory= adds a writable directory without replacing /tmp, so the
# socket stays reachable.
#
# bin/fm-telemetry-store.mjs still sets PRAGMA temp_store = MEMORY on its
# readOnly open, and still should: a reader that never asks the filesystem for
# scratch space cannot be denied it, including outside this unit.
# The unit separately grants the operational home's brain directory, because a
# GBrain search writes to its own index while reading it.
# docs/verification/dashboard-service-unit.md pins all of it.
#
# Loopback is the first-install default and remote exposure is opt-in:
# --address only accepts a non-loopback bind once credentials exist, and the
# server independently refuses to start beyond loopback without them.
# A later run preserves the installed operator-facing settings unless the
# environment or an option overrides them, so repairing the unit cannot silently
# retract an existing bind or trusted-proxy configuration.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Two dashboard servers, and one rule about which is asked what.
#
# INSTALLER_SERVER is the one beside this script. SERVER is the one the service
# will run, which --checkout deliberately points at a possibly older tree.
#
# THE RULE: every non-serving probe goes to INSTALLER_SERVER, never to SERVER.
# A server that does not recognise a probe flag does not fail - older ones fall
# through to serving, so the probe binds a port and the command substitution
# waiting for its output never returns. SERVER is named in the unit and nowhere
# else, so no future probe has to rediscover this.
INSTALLER_SERVER="$SCRIPT_DIR/fm-dashboard-server.mjs"
SERVER="$INSTALLER_SERVER"

usage() {
  cat <<'EOF'
usage: fm-dashboard-install.sh [options]

Install or update the read-only Firstmate fleet dashboard user service.

Options:
  --fm-home PATH       operational home (default: FM_HOME, else an explicit
                       --checkout, else the installed value, else this checkout)
  --checkout PATH      tracked Firstmate checkout whose dashboard server the
                       service runs (default: the checkout this script is in).
                       Use it to install the persistent service for a permanent
                       checkout while running a newer installer from elsewhere.
                       With neither FM_HOME nor --fm-home set, the operational
                       home follows an explicit --checkout rather than staying
                       where this installer happens to be.
  --allow-worktree     install a persistent service that runs from a linked git
                       worktree anyway. Refused by default: a worktree is
                       disposable, and the service breaks when it is reclaimed.
  --address ADDRESS    numeric bind address (first-install default: 127.0.0.1).
                       A reinstall preserves the configured address. Any address
                       other than 127.0.0.1 or ::1 exposes the dashboard beyond
                       this host and is accepted only once --set-password has
                       stored credentials.
  --trusted-proxy ADDR numeric address or CIDR range of a reverse proxy whose
                       X-Forwarded-For this dashboard may believe when deciding
                       which client an authentication attempt is throttled as.
                       Repeatable. A reinstall preserves the configured list;
                       the first flag replaces that installed list. Nothing is
                       trusted on first install.
  --set-password       read a dashboard password from the terminal, or from
                       standard input when there is no terminal, and store only
                       its salted digest in the private credentials file
  --username NAME      username stored with --set-password (default: captain)
  --auth-file PATH     credentials file
                       (first-install default:
                       $XDG_CONFIG_HOME/firstmate/dashboard-auth.json).
                       A reinstall preserves the configured file.
  --port PORT          listen port (first-install default: 8787).
                       A reinstall preserves the configured port.
  --poll SECONDS       snapshot poll interval (first-install default: 5).
                       A reinstall preserves the configured interval.
  --timeout SECONDS    hard snapshot deadline (first-install default: 15).
                       A reinstall preserves the configured deadline.
  --stale SECONDS      last-good stale threshold (first-install default: 30).
                       A reinstall preserves the configured threshold.
  --history-limit N    completion records read per history refresh
                       (first-install default: 500).
                       A reinstall preserves the configured limit.
  --history-poll SEC   history refresh interval (first-install default: 60).
                       A reinstall preserves the configured interval.
  --report-bytes N     report bytes returned per request
                       (first-install default: 262144).
                       A reinstall preserves the configured limit.
  --no-start           install files without enabling or starting the service
  -h, --help           show this help

The environment variables FM_DASHBOARD_ADDRESS, FM_DASHBOARD_PORT,
FM_DASHBOARD_POLL_SECONDS, FM_DASHBOARD_TIMEOUT_SECONDS,
FM_DASHBOARD_STALE_SECONDS, FM_DASHBOARD_HISTORY_LIMIT,
FM_DASHBOARD_HISTORY_POLL_SECONDS, FM_DASHBOARD_REPORT_MAX_BYTES,
FM_DASHBOARD_AUTH_FILE, and FM_DASHBOARD_TRUSTED_PROXIES provide the same
defaults as their options. Raise --history-limit when retained history has
grown past the default read bound; the dashboard says so when it has.

docs/dashboard-remote-access.md owns the remote-access posture: what
authentication does and does not protect, and the Twingate, firewall, and
transport steps that belong to the operator rather than to this script.
EOF
}

# Read only values this installer itself emitted, and never source the file.
# EnvironmentFile syntax can execute nothing, but sourcing an operator-editable
# configuration would turn a repair into arbitrary shell execution. Every
# preserved setting below is validated again before either output file changes.
XDG_CONFIG_ROOT=${XDG_CONFIG_HOME:-"$HOME/.config"}
ENV_DIR="$XDG_CONFIG_ROOT/firstmate"
UNIT_DIR="$XDG_CONFIG_ROOT/systemd/user"
ENV_FILE="$ENV_DIR/dashboard.env"
UNIT_FILE="$UNIT_DIR/firstmate-dashboard.service"
installed_setting() {  # <key>
  [ -f "$ENV_FILE" ] || return 0
  awk -v key="$1" 'index($0, key "=\"") == 1 && substr($0, length($0)) == "\"" {
    print substr($0, length(key) + 3, length($0) - length(key) - 3)
    exit
  }' "$ENV_FILE"
}

INSTALLED_HOME=$(installed_setting FM_HOME)
INSTALLED_ADDRESS=$(installed_setting FM_DASHBOARD_ADDRESS)
INSTALLED_PORT=$(installed_setting FM_DASHBOARD_PORT)
INSTALLED_POLL=$(installed_setting FM_DASHBOARD_POLL_SECONDS)
INSTALLED_TIMEOUT=$(installed_setting FM_DASHBOARD_TIMEOUT_SECONDS)
INSTALLED_STALE=$(installed_setting FM_DASHBOARD_STALE_SECONDS)
INSTALLED_HISTORY_LIMIT=$(installed_setting FM_DASHBOARD_HISTORY_LIMIT)
INSTALLED_HISTORY_POLL=$(installed_setting FM_DASHBOARD_HISTORY_POLL_SECONDS)
INSTALLED_REPORT_BYTES=$(installed_setting FM_DASHBOARD_REPORT_MAX_BYTES)
INSTALLED_AUTH_FILE=$(installed_setting FM_DASHBOARD_AUTH_FILE)
INSTALLED_TRUSTED_PROXIES=$(installed_setting FM_DASHBOARD_TRUSTED_PROXIES)

FM_DASHBOARD_HOME=${FM_HOME:-$INSTALLED_HOME}
FM_DASHBOARD_HOME_EXPLICIT=0
[ -z "${FM_HOME:-}" ] || FM_DASHBOARD_HOME_EXPLICIT=1
FM_DASHBOARD_ADDRESS=${FM_DASHBOARD_ADDRESS:-${INSTALLED_ADDRESS:-127.0.0.1}}
FM_DASHBOARD_PORT=${FM_DASHBOARD_PORT:-${INSTALLED_PORT:-8787}}
FM_DASHBOARD_POLL_SECONDS=${FM_DASHBOARD_POLL_SECONDS:-${INSTALLED_POLL:-5}}
FM_DASHBOARD_TIMEOUT_SECONDS=${FM_DASHBOARD_TIMEOUT_SECONDS:-${INSTALLED_TIMEOUT:-15}}
FM_DASHBOARD_STALE_SECONDS=${FM_DASHBOARD_STALE_SECONDS:-${INSTALLED_STALE:-30}}
FM_DASHBOARD_HISTORY_LIMIT=${FM_DASHBOARD_HISTORY_LIMIT:-${INSTALLED_HISTORY_LIMIT:-500}}
FM_DASHBOARD_HISTORY_POLL_SECONDS=${FM_DASHBOARD_HISTORY_POLL_SECONDS:-${INSTALLED_HISTORY_POLL:-60}}
FM_DASHBOARD_REPORT_MAX_BYTES=${FM_DASHBOARD_REPORT_MAX_BYTES:-${INSTALLED_REPORT_BYTES:-262144}}
AUTH_FILE=${FM_DASHBOARD_AUTH_FILE:-$INSTALLED_AUTH_FILE}
TRUSTED_PROXIES_FROM_INSTALL=0
if [ "${FM_DASHBOARD_TRUSTED_PROXIES+x}" = x ]; then
  FM_DASHBOARD_TRUSTED_PROXIES=${FM_DASHBOARD_TRUSTED_PROXIES:-}
else
  FM_DASHBOARD_TRUSTED_PROXIES=$INSTALLED_TRUSTED_PROXIES
  [ -z "$INSTALLED_TRUSTED_PROXIES" ] || TRUSTED_PROXIES_FROM_INSTALL=1
fi
START_SERVICE=1
SET_PASSWORD=0
AUTH_USERNAME=captain
CHECKOUT=
ALLOW_WORKTREE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fm-home|--address|--port|--poll|--timeout|--stale|\
    --history-limit|--history-poll|--report-bytes|--username|--auth-file|--checkout|--trusted-proxy)
      [ "$#" -ge 2 ] || { printf 'fm-dashboard-install: %s requires a value\n' "$1" >&2; exit 2; }
      case "$1" in
        --fm-home) FM_DASHBOARD_HOME=$2; FM_DASHBOARD_HOME_EXPLICIT=1 ;;
        --trusted-proxy)
          if [ "$TRUSTED_PROXIES_FROM_INSTALL" -eq 1 ]; then
            FM_DASHBOARD_TRUSTED_PROXIES=
            TRUSTED_PROXIES_FROM_INSTALL=0
          fi
          FM_DASHBOARD_TRUSTED_PROXIES=${FM_DASHBOARD_TRUSTED_PROXIES:+$FM_DASHBOARD_TRUSTED_PROXIES,}$2
          ;;
        --address) FM_DASHBOARD_ADDRESS=$2 ;;
        --port) FM_DASHBOARD_PORT=$2 ;;
        --poll) FM_DASHBOARD_POLL_SECONDS=$2 ;;
        --timeout) FM_DASHBOARD_TIMEOUT_SECONDS=$2 ;;
        --stale) FM_DASHBOARD_STALE_SECONDS=$2 ;;
        --history-limit) FM_DASHBOARD_HISTORY_LIMIT=$2 ;;
        --history-poll) FM_DASHBOARD_HISTORY_POLL_SECONDS=$2 ;;
        --report-bytes) FM_DASHBOARD_REPORT_MAX_BYTES=$2 ;;
        --username) AUTH_USERNAME=$2 ;;
        --auth-file) AUTH_FILE=$2 ;;
        --checkout) CHECKOUT=$2 ;;
      esac
      shift 2
      ;;
    --allow-worktree) ALLOW_WORKTREE=1; shift ;;
    --set-password) SET_PASSWORD=1; shift ;;
    --no-start) START_SERVICE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-dashboard-install: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

validate_positive_number() {
  case "$2" in
    ''|*[!0-9.]*|.*|*.*.*) printf 'fm-dashboard-install: %s must be a positive number\n' "$1" >&2; exit 2 ;;
  esac
  awk -v value="$2" 'BEGIN { exit !(value > 0) }' \
    || { printf 'fm-dashboard-install: %s must be a positive number\n' "$1" >&2; exit 2; }
}

validate_positive_number port "$FM_DASHBOARD_PORT"
case "$FM_DASHBOARD_PORT" in *.*) echo "fm-dashboard-install: port must be an integer" >&2; exit 2 ;; esac
[ "$FM_DASHBOARD_PORT" -le 65535 ] || { echo "fm-dashboard-install: port must be at most 65535" >&2; exit 2; }
validate_positive_number poll "$FM_DASHBOARD_POLL_SECONDS"
validate_positive_number timeout "$FM_DASHBOARD_TIMEOUT_SECONDS"
validate_positive_number stale "$FM_DASHBOARD_STALE_SECONDS"
validate_positive_number history-poll "$FM_DASHBOARD_HISTORY_POLL_SECONDS"
validate_positive_number history-limit "$FM_DASHBOARD_HISTORY_LIMIT"
validate_positive_number report-bytes "$FM_DASHBOARD_REPORT_MAX_BYTES"
case "$FM_DASHBOARD_HISTORY_LIMIT" in *.*) echo "fm-dashboard-install: history-limit must be an integer" >&2; exit 2 ;; esac
case "$FM_DASHBOARD_REPORT_MAX_BYTES" in *.*) echo "fm-dashboard-install: report-bytes must be an integer" >&2; exit 2 ;; esac

command -v node >/dev/null 2>&1 || { echo "fm-dashboard-install: node not found" >&2; exit 1; }

# The unit names one dashboard server by absolute path and keeps naming it
# across reboots, so which checkout that is decides whether the service still
# exists next week.
if [ -n "$CHECKOUT" ]; then
  CHECKOUT=$(CDPATH='' cd -- "$CHECKOUT" 2>/dev/null && pwd) \
    || { echo "fm-dashboard-install: --checkout is not a directory" >&2; exit 2; }
  [ "$FM_DASHBOARD_HOME_EXPLICIT" -eq 1 ] || FM_DASHBOARD_HOME=$CHECKOUT
  SERVER="$CHECKOUT/bin/fm-dashboard-server.mjs"
else
  CHECKOUT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
fi
[ -f "$SERVER" ] || { echo "fm-dashboard-install: dashboard server not found at $SERVER" >&2; exit 1; }
[ -f "$INSTALLER_SERVER" ] \
  || { echo "fm-dashboard-install: dashboard server not found beside this script at $INSTALLER_SERVER" >&2; exit 1; }

# The operational home follows the checkout the service is being installed for
# unless one was named, because the unit pins FM_HOME and derives the event
# store from it: a home left pointing at wherever this installer happens to sit
# would hand the persistent service a fleet home that is not the one it runs.
[ -n "$FM_DASHBOARD_HOME" ] || FM_DASHBOARD_HOME=$CHECKOUT

# A linked git worktree is disposable by construction: whoever created it will
# reclaim it, and a boot-persistent unit pointing into one is a service that
# works until the day it silently does not. Both pinned paths are checked, since
# a service whose fleet home evaporates is as broken as one whose server does.
# Installing from a worktree to try a change is legitimate, so this refuses with
# the way to say that is what you meant rather than deciding for you.
refuse_linked_worktree() {  # <label> <path> <way-out>
  local git_dir common_dir
  [ -d "$2" ] || return 0
  git_dir=$(git -C "$2" rev-parse --absolute-git-dir 2>/dev/null || true)
  common_dir=$(git -C "$2" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ] || return 0
  printf 'fm-dashboard-install: the %s %s is a linked git worktree, which will be reclaimed.\n' "$1" "$2" >&2
  printf 'fm-dashboard-install: %s\n' "$3" >&2
  printf 'fm-dashboard-install: or pass --allow-worktree if a disposable service is what you meant.\n' >&2
  exit 2
}

if command -v git >/dev/null 2>&1 && [ "$ALLOW_WORKTREE" -eq 0 ]; then
  refuse_linked_worktree "checkout" "$CHECKOUT" \
    "install the persistent service for a permanent checkout with --checkout PATH,"
  refuse_linked_worktree "operational home" "$FM_DASHBOARD_HOME" \
    "name a permanent operational home with --fm-home PATH,"
fi

NODE_BIN=$(command -v node)
[ -n "$AUTH_FILE" ] || AUTH_FILE="$ENV_DIR/dashboard-auth.json"

# Every path this script writes into the unit is emitted literally, so a path
# that would need quoting to survive is refused here rather than encoded in a
# form systemd would drop. % is refused because systemd expands specifiers.
assert_unit_path_safe() {  # <label> <path>
  case "$2" in
    /*) ;;
    *) printf 'fm-dashboard-install: %s must be an absolute path: %s\n' "$1" "$2" >&2; exit 2 ;;
  esac
  case "$2" in
    *[[:space:]]*|*'"'*|*"'"*|*\\*|*%*)
      printf 'fm-dashboard-install: %s contains whitespace, a quote, a backslash, or %% and cannot be written into a systemd unit: %s\n' \
        "$1" "$2" >&2
      exit 2
      ;;
  esac
}

assert_unit_path_safe "the operational home" "$FM_DASHBOARD_HOME"
assert_unit_path_safe "the dashboard server" "$SERVER"
assert_unit_path_safe "the node binary" "$NODE_BIN"
assert_unit_path_safe "the configuration root" "$XDG_CONFIG_ROOT"
assert_unit_path_safe "the credentials file" "$AUTH_FILE"

# The address is the exposure decision, so it is checked before anything is
# written. Only a numeric address is accepted: a name would make what this
# service is reachable on depend on resolution rather than on configuration.
"$NODE_BIN" -e 'process.exit(require("net").isIP(process.argv[1]) ? 0 : 1)' "$FM_DASHBOARD_ADDRESS" \
  || { printf 'fm-dashboard-install: address must be a numeric IPv4 or IPv6 address: %s\n' "$FM_DASHBOARD_ADDRESS" >&2; exit 2; }

# Which proxy the dashboard may believe about who a client is. The server owns
# what a usable allowlist is and answers with the entries it would honour, so a
# value this installer pins is one that server already accepted.
#
# Only stdout becomes that value. This capture is written into the unit's
# configuration, so anything else the process printed - a warning from the
# operator's NODE_OPTIONS, a deprecation notice from a module the server imports
# - would become an entry in the allowlist that decides whose forwarded headers
# are believed. The credentials check below folds stderr into its capture
# because that value is only ever printed back to the operator, and that is the
# whole difference between the two call sites.
if [ -n "$FM_DASHBOARD_TRUSTED_PROXIES" ]; then
  TRUSTED_PROXY_REFUSAL=$(mktemp)
  trap 'rm -f "$TRUSTED_PROXY_REFUSAL"' EXIT HUP INT TERM
  FM_DASHBOARD_TRUSTED_PROXIES=$(FM_DASHBOARD_TRUSTED_PROXIES="$FM_DASHBOARD_TRUSTED_PROXIES" \
    "$NODE_BIN" "$INSTALLER_SERVER" --check-trusted-proxies 2>"$TRUSTED_PROXY_REFUSAL") || {
    cat "$TRUSTED_PROXY_REFUSAL" >&2
    printf 'fm-dashboard-install: --trusted-proxy takes a numeric address or CIDR range, and nothing is trusted by default.\n' >&2
    exit 2
  }
  rm -f "$TRUSTED_PROXY_REFUSAL"
  trap - EXIT HUP INT TERM
fi

# Setting the password comes first, so a single command can both establish
# credentials and open the bind that requires them. The password is read from
# the terminal when there is one and from standard input otherwise, and it
# reaches the digest helper only through a pipe: it is never an argument, so it
# is never in the process table, the shell history, or a service log.
install -d -m 700 "$ENV_DIR"
if [ "$SET_PASSWORD" -eq 1 ]; then
  DASHBOARD_PASSWORD=
  DASHBOARD_PASSWORD_CONFIRM=
  if [ -t 0 ]; then
    printf 'Dashboard password: ' >&2
    stty -echo 2>/dev/null || true
    IFS= read -r DASHBOARD_PASSWORD || true
    stty echo 2>/dev/null || true
    printf '\nConfirm dashboard password: ' >&2
    stty -echo 2>/dev/null || true
    IFS= read -r DASHBOARD_PASSWORD_CONFIRM || true
    stty echo 2>/dev/null || true
    printf '\n' >&2
    [ "$DASHBOARD_PASSWORD" = "$DASHBOARD_PASSWORD_CONFIRM" ] \
      || { echo "fm-dashboard-install: the two passwords did not match" >&2; exit 2; }
  else
    IFS= read -r DASHBOARD_PASSWORD || true
  fi
  AUTH_TMP=$(mktemp "$ENV_DIR/.dashboard-auth.json.XXXXXX")
  chmod 600 "$AUTH_TMP"
  trap 'rm -f "$AUTH_TMP"' EXIT HUP INT TERM
  printf '%s' "$DASHBOARD_PASSWORD" \
    | "$NODE_BIN" "$INSTALLER_SERVER" --hash-password --username "$AUTH_USERNAME" > "$AUTH_TMP" \
    || { echo "fm-dashboard-install: the dashboard password was not stored" >&2; exit 2; }
  DASHBOARD_PASSWORD=
  DASHBOARD_PASSWORD_CONFIRM=
  # Only a directory this script has to create is given a mode. install -d -m
  # also re-modes one that was already there, and a credentials file the
  # operator put somewhere of their own must not silently take the rest of that
  # directory private with it.
  AUTH_DIR=$(dirname -- "$AUTH_FILE")
  [ -d "$AUTH_DIR" ] || install -d -m 700 "$AUTH_DIR"
  mv -f "$AUTH_TMP" "$AUTH_FILE"
  trap - EXIT HUP INT TERM
  printf 'Stored dashboard credentials for %s in %s\n' "$AUTH_USERNAME" "$AUTH_FILE"
fi

# Exposure is opt-in and it is never a bind-address change alone. The server
# enforces the same rule at startup; refusing here means the operator finds out
# before a unit is written rather than from a service that will not come up.
#
# What is required is a credential the server could actually serve behind, not a
# file at that path: a credentials document that is group-readable, truncated,
# or written with work factors the server will not accept fails the server's own
# gate at startup, so accepting it here would write a unit for a service that
# can never come up. The server owns that judgement and is asked for it.
case "$FM_DASHBOARD_ADDRESS" in
  127.0.0.1|::1) ;;
  *)
    AUTH_CREDENTIAL_USER=$("$NODE_BIN" "$INSTALLER_SERVER" --check-credentials --auth-file "$AUTH_FILE" 2>&1) || {
      printf 'fm-dashboard-install: binding %s reaches beyond this host and needs credentials first.\n' "$FM_DASHBOARD_ADDRESS" >&2
      printf 'fm-dashboard-install: %s\n' "$AUTH_CREDENTIAL_USER" >&2
      printf 'fm-dashboard-install: run %s --set-password (optionally with --username NAME) and try again.\n' "$0" >&2
      exit 2
    }
    printf 'Exposing %s behind the stored credentials for %s in %s\n' \
      "$FM_DASHBOARD_ADDRESS" "$AUTH_CREDENTIAL_USER" "$AUTH_FILE"
    case "$FM_DASHBOARD_ADDRESS" in
      0.0.0.0|::)
        printf 'warning: %s binds every interface on this host, not only the one you reach it on.\n' "$FM_DASHBOARD_ADDRESS" >&2
        printf 'warning: prefer the specific interface address the Twingate connector reaches.\n' >&2
        ;;
    esac
    ;;
esac

# The service is otherwise read-only towards the whole filesystem, and that is
# the point of it. The agent-event store is the one directory it may write, so
# the unit names exactly that directory and nothing else. The server itself owns
# the rule that derives the path, so this asks it rather than re-deriving it.
#
# The answer is then PINNED into the environment file below, because the grant
# and the resolution must not be able to disagree. This shell's environment is
# not the systemd user manager's: it does not import FM_DASHBOARD_EVENT_DB or
# XDG_STATE_HOME, so a service left to re-derive the path at runtime would
# resolve a different directory than the one the unit granted, fail to open its
# store under ProtectHome=read-only, and answer 503 for the life of the process.
# The same reasoning pins the shared configuration file that carries the ingest
# token, which is resolved from XDG_CONFIG_HOME here and would not be there.
EVENT_DB=$(FM_HOME="$FM_DASHBOARD_HOME" "$NODE_BIN" "$INSTALLER_SERVER" --event-store-path 2>/dev/null || true)
[ -n "$EVENT_DB" ] || { echo "fm-dashboard-install: could not resolve the agent-event store path" >&2; exit 1; }
EVENT_DIR=${EVENT_DB%/*}
EVENTS_CONFIG=${FM_DASHBOARD_EVENTS_CONFIG:-"$XDG_CONFIG_ROOT/firstmate/dashboard-events.json"}
[ -n "$EVENT_DIR" ] || { echo "fm-dashboard-install: the agent-event store path has no directory" >&2; exit 1; }
assert_unit_path_safe "the agent-event store" "$EVENT_DB"
assert_unit_path_safe "the shared instrumentation configuration" "$EVENTS_CONFIG"
install -d -m 700 "$EVENT_DIR"

# A GBrain search writes to its own index while reading it, so the semantic
# search panel needs this grant on top of the scratch directory. Do not narrow
# it below data/gbrain: GBrain takes a lock file at pglite/.gbrain-lock before it
# can open the database at all, so a denied write here is a lock timeout rather
# than a partial read. The grant is tolerant because a home with no brain is
# normal and must not keep the unit from loading; the panel is presence-gated
# and simply stays off there.
GBRAIN_DIR="$FM_DASHBOARD_HOME/data/gbrain"
assert_unit_path_safe "the brain directory" "$GBRAIN_DIR"

# The one scratch directory every panel's temp file goes to. The name is
# relative by contract: RuntimeDirectory= is always resolved under the manager's
# runtime root and systemd refuses an absolute one.
RUNTIME_DIR_NAME=firstmate-dashboard

# EnvironmentFile values are parsed with shell-like quoting, so a value there is
# quoted and escaped. Unit directives are not: those are emitted literally, and
# assert_unit_path_safe has already refused anything that would not survive it.
systemd_quote() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# The PATH the fleet tools were found on at install time is the PATH the service
# gets, minus any entry a unit file cannot carry literally. The directory the
# resolved node came from leads, because the service must be able to run the
# interpreter it was installed against.
SERVICE_PATH_ENTRIES=
SERVICE_PATH_DROPPED=0
add_service_path_entry() {  # <directory>
  case "$1" in /*) ;; *) return 0 ;; esac
  case "$1" in
    *[[:space:]]*|*'"'*|*"'"*|*\\*|*%*) SERVICE_PATH_DROPPED=$((SERVICE_PATH_DROPPED + 1)); return 0 ;;
  esac
  printf '%s\n' "$SERVICE_PATH_ENTRIES" | grep -Fxq -- "$1" && return 0
  SERVICE_PATH_ENTRIES=${SERVICE_PATH_ENTRIES:+$SERVICE_PATH_ENTRIES$'\n'}$1
}

add_service_path_entry "${NODE_BIN%/*}"
while IFS= read -r service_path_entry; do
  [ -n "$service_path_entry" ] || continue
  add_service_path_entry "$service_path_entry"
done <<EOF
$(printf '%s' "$PATH" | tr ':' '\n')
EOF
SERVICE_PATH=$(printf '%s' "$SERVICE_PATH_ENTRIES" | tr '\n' ':')
[ -n "$SERVICE_PATH" ] || { echo "fm-dashboard-install: no usable PATH entry could be pinned into the unit" >&2; exit 1; }
[ "$SERVICE_PATH_DROPPED" -eq 0 ] \
  || printf 'warning: %s PATH entries were left out of the unit because a systemd unit cannot carry them literally.\n' \
    "$SERVICE_PATH_DROPPED" >&2

install -d -m 700 "$ENV_DIR" "$UNIT_DIR"
ENV_TMP=$(mktemp "$ENV_DIR/.dashboard.env.XXXXXX")
UNIT_TMP=$(mktemp "$UNIT_DIR/.firstmate-dashboard.service.XXXXXX")
trap 'rm -f "$ENV_TMP" "$UNIT_TMP"' EXIT HUP INT TERM

{
  printf 'FM_HOME="%s"\n' "$(systemd_quote "$FM_DASHBOARD_HOME")"
  printf 'FM_DASHBOARD_ADDRESS="%s"\n' "$(systemd_quote "$FM_DASHBOARD_ADDRESS")"
  printf 'FM_DASHBOARD_PORT="%s"\n' "$(systemd_quote "$FM_DASHBOARD_PORT")"
  printf 'FM_DASHBOARD_POLL_SECONDS="%s"\n' "$(systemd_quote "$FM_DASHBOARD_POLL_SECONDS")"
  printf 'FM_DASHBOARD_TIMEOUT_SECONDS="%s"\n' "$(systemd_quote "$FM_DASHBOARD_TIMEOUT_SECONDS")"
  printf 'FM_DASHBOARD_STALE_SECONDS="%s"\n' "$(systemd_quote "$FM_DASHBOARD_STALE_SECONDS")"
  printf 'FM_DASHBOARD_HISTORY_LIMIT="%s"\n' "$(systemd_quote "$FM_DASHBOARD_HISTORY_LIMIT")"
  printf 'FM_DASHBOARD_HISTORY_POLL_SECONDS="%s"\n' "$(systemd_quote "$FM_DASHBOARD_HISTORY_POLL_SECONDS")"
  printf 'FM_DASHBOARD_REPORT_MAX_BYTES="%s"\n' "$(systemd_quote "$FM_DASHBOARD_REPORT_MAX_BYTES")"
  printf 'FM_DASHBOARD_EVENT_DB="%s"\n' "$(systemd_quote "$EVENT_DB")"
  printf 'FM_DASHBOARD_EVENTS_CONFIG="%s"\n' "$(systemd_quote "$EVENTS_CONFIG")"
  printf 'FM_DASHBOARD_AUTH_FILE="%s"\n' "$(systemd_quote "$AUTH_FILE")"
  printf 'FM_DASHBOARD_TRUSTED_PROXIES="%s"\n' "$(systemd_quote "$FM_DASHBOARD_TRUSTED_PROXIES")"
} > "$ENV_TMP"
chmod 600 "$ENV_TMP"

{
  cat <<'EOF'
[Unit]
Description=Firstmate read-only fleet dashboard
After=default.target

[Service]
Type=simple
EOF
  printf 'Environment=PATH=%s\n' "$SERVICE_PATH"
  # %t is the user manager's runtime root, so the name is written once and
  # systemd resolves both the directory it creates and the TMPDIR pointing at
  # it. The mode is stated rather than left to systemd's 0755 default, so the
  # scratch space matches the UMask=0077 posture below without depending on the
  # runtime root's own permissions to stand in for it. The directory is removed
  # on stop, so nothing survives a restart.
  printf 'RuntimeDirectory=%s\n' "$RUNTIME_DIR_NAME"
  printf 'RuntimeDirectoryMode=0700\n'
  printf 'Environment=TMPDIR=%%t/%s\n' "$RUNTIME_DIR_NAME"
  printf 'Environment=FM_DASHBOARD_UNIT_CONTRACT=runtime-scratch-v1\n'
  printf 'EnvironmentFile=%s\n' "$ENV_FILE"
  printf 'ExecStart=%s %s\n' "$NODE_BIN" "$SERVER"
  printf 'ReadWritePaths=-%s\n' "$EVENT_DIR"
  printf 'ReadWritePaths=-%s\n' "$GBRAIN_DIR"
  cat <<'EOF'
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
UMask=0077

[Install]
WantedBy=default.target
EOF
} > "$UNIT_TMP"
chmod 600 "$UNIT_TMP"

mv -f "$ENV_TMP" "$ENV_FILE"
mv -f "$UNIT_TMP" "$UNIT_FILE"
trap - EXIT HUP INT TERM

printf 'Installed %s\n' "$UNIT_FILE"
printf 'Configured %s\n' "$ENV_FILE"
if [ "$START_SERVICE" -eq 1 ]; then
  command -v systemctl >/dev/null 2>&1 || { echo "fm-dashboard-install: systemctl not found" >&2; exit 1; }
  systemctl --user daemon-reload
  systemctl --user enable firstmate-dashboard.service
  systemctl --user restart firstmate-dashboard.service

  # A directive systemd read past is the exact failure this installer exists to
  # prevent, and it is invisible in `status`: the service comes up green while
  # running on defaults it was never configured with. Reinstalling over such a
  # unit is only a repair if the repair is confirmed, so the install is not
  # reported as finished until systemd reads its own configuration back.
  loaded_env=$(systemctl --user show -p EnvironmentFiles --value firstmate-dashboard.service 2>/dev/null || true)
  case "$loaded_env" in
    *"$ENV_FILE"*) ;;
    *)
      printf 'fm-dashboard-install: systemd did not accept the environment file %s (read back: %s)\n' \
        "$ENV_FILE" "${loaded_env:-none}" >&2
      exit 1
      ;;
  esac
  loaded_environment=$(systemctl --user show -p Environment --value firstmate-dashboard.service 2>/dev/null || true)
  case "$loaded_environment" in
    *PATH=*) ;;
    *) echo "fm-dashboard-install: systemd did not accept the pinned PATH for the service" >&2; exit 1 ;;
  esac
  loaded_writable=$(systemctl --user show -p ReadWritePaths --value firstmate-dashboard.service 2>/dev/null || true)
  case "$loaded_writable" in
    *"$EVENT_DIR"*) ;;
    *)
      printf 'fm-dashboard-install: systemd did not accept the agent-event write grant for %s (read back: %s)\n' \
        "$EVENT_DIR" "${loaded_writable:-none}" >&2
      exit 1
      ;;
  esac

  # The scratch grant is read back for the same reason as the rest: a service
  # that comes up without it stays green and reports panels empty rather than
  # broken, which is the failure this whole installer exists to refuse.
  loaded_runtime=$(systemctl --user show -p RuntimeDirectory --value firstmate-dashboard.service 2>/dev/null || true)
  case "$loaded_runtime" in
    *"$RUNTIME_DIR_NAME"*) ;;
    *)
      printf 'fm-dashboard-install: systemd did not accept the scratch directory %s (read back: %s)\n' \
        "$RUNTIME_DIR_NAME" "${loaded_runtime:-none}" >&2
      exit 1
      ;;
  esac
  case "$loaded_environment" in
    *TMPDIR=*"$RUNTIME_DIR_NAME"*) ;;
    *)
      printf 'fm-dashboard-install: systemd did not accept the TMPDIR pointing at %s (read back: %s)\n' \
        "$RUNTIME_DIR_NAME" "${loaded_environment:-none}" >&2
      exit 1
      ;;
  esac
  case "$loaded_environment" in
    *FM_DASHBOARD_UNIT_CONTRACT=runtime-scratch-v1*) ;;
    *)
      printf 'fm-dashboard-install: systemd did not accept the dashboard runtime contract (read back: %s)\n' \
        "${loaded_environment:-none}" >&2
      exit 1
      ;;
  esac

  # A drop-in left behind by a hand repair keeps overriding this unit after it
  # has been corrected, so the operator is told about one rather than left to
  # wonder why their reinstall did not take.
  drop_ins=$(systemctl --user show -p DropInPaths --value firstmate-dashboard.service 2>/dev/null || true)
  [ -z "$drop_ins" ] \
    || printf 'warning: this service still has drop-in overrides that outrank the unit: %s\n' "$drop_ins" >&2

  # Every read-back above answers from the unit file whether or not a process is
  # alive, and Type=simple calls a restart successful the moment the process
  # forks. So the service is given time to fail and then asked whether it is
  # still there: a refused credential, a port already taken, or a checkout that
  # has gone away all leave a unit that reads as installed and a service that
  # crash-loops, and reporting that as a finished install is how an operator
  # ends up trusting a dashboard that is not running.
  #
  # Asked twice, because a service that dies at once and waits RestartSec to be
  # started again spends nearly all of each cycle waiting rather than running,
  # and one sample can land in the moment it is up.
  service_state=
  for _ in 1 2; do
    sleep 1.5
    service_state=$(systemctl --user show -p ActiveState --value firstmate-dashboard.service 2>/dev/null || true)
    [ "$service_state" = "active" ] || break
  done
  if [ "$service_state" != "active" ]; then
    printf 'fm-dashboard-install: the dashboard service did not stay up (state: %s).\n' \
      "${service_state:-unknown}" >&2
    printf 'fm-dashboard-install: read why with: journalctl --user -u firstmate-dashboard.service -n 50 --no-pager\n' >&2
    systemctl --user --no-pager --full status firstmate-dashboard.service >&2 || true
    exit 1
  fi

  systemctl --user --no-pager --full status firstmate-dashboard.service || true
  printf 'systemd accepted the environment file, the pinned PATH, the agent-event write grant, the scratch directory %s, the TMPDIR pointing at it, and the dashboard runtime contract, and the service is running.\n' \
    "$RUNTIME_DIR_NAME"
else
  echo "Service not started (--no-start)."
fi
