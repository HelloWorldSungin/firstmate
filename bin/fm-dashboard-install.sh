#!/usr/bin/env bash
# fm-dashboard-install.sh - install the loopback fleet dashboard as a user service.
#
# Writes one private environment file and one user-level systemd unit, then
# enables the service unless --no-start is passed. No sudo is used.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SERVER="$SCRIPT_DIR/fm-dashboard-server.mjs"

usage() {
  cat <<'EOF'
usage: fm-dashboard-install.sh [options]

Install or update the read-only Firstmate fleet dashboard user service.

Options:
  --fm-home PATH       operational home (default: FM_HOME or repository root)
  --address ADDRESS    loopback bind address (default: 127.0.0.1)
  --port PORT          listen port (default: 8787)
  --poll SECONDS       snapshot poll interval (default: 5)
  --timeout SECONDS    hard snapshot deadline (default: 15)
  --stale SECONDS      last-good stale threshold (default: 30)
  --history-limit N    completion records read per history refresh (default: 500)
  --history-poll SEC   history refresh interval (default: 60)
  --report-bytes N     report bytes returned per request (default: 262144)
  --no-start           install files without enabling or starting the service
  -h, --help           show this help

The environment variables FM_DASHBOARD_ADDRESS, FM_DASHBOARD_PORT,
FM_DASHBOARD_POLL_SECONDS, FM_DASHBOARD_TIMEOUT_SECONDS,
FM_DASHBOARD_STALE_SECONDS, FM_DASHBOARD_HISTORY_LIMIT,
FM_DASHBOARD_HISTORY_POLL_SECONDS, and FM_DASHBOARD_REPORT_MAX_BYTES provide
the same defaults as their options. Raise --history-limit when retained history
has grown past the default read bound; the dashboard says so when it has.
EOF
}

FM_DASHBOARD_HOME=${FM_HOME:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)}
FM_DASHBOARD_ADDRESS=${FM_DASHBOARD_ADDRESS:-127.0.0.1}
FM_DASHBOARD_PORT=${FM_DASHBOARD_PORT:-8787}
FM_DASHBOARD_POLL_SECONDS=${FM_DASHBOARD_POLL_SECONDS:-5}
FM_DASHBOARD_TIMEOUT_SECONDS=${FM_DASHBOARD_TIMEOUT_SECONDS:-15}
FM_DASHBOARD_STALE_SECONDS=${FM_DASHBOARD_STALE_SECONDS:-30}
FM_DASHBOARD_HISTORY_LIMIT=${FM_DASHBOARD_HISTORY_LIMIT:-500}
FM_DASHBOARD_HISTORY_POLL_SECONDS=${FM_DASHBOARD_HISTORY_POLL_SECONDS:-60}
FM_DASHBOARD_REPORT_MAX_BYTES=${FM_DASHBOARD_REPORT_MAX_BYTES:-262144}
START_SERVICE=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fm-home|--address|--port|--poll|--timeout|--stale|\
    --history-limit|--history-poll|--report-bytes)
      [ "$#" -ge 2 ] || { printf 'fm-dashboard-install: %s requires a value\n' "$1" >&2; exit 2; }
      case "$1" in
        --fm-home) FM_DASHBOARD_HOME=$2 ;;
        --address) FM_DASHBOARD_ADDRESS=$2 ;;
        --port) FM_DASHBOARD_PORT=$2 ;;
        --poll) FM_DASHBOARD_POLL_SECONDS=$2 ;;
        --timeout) FM_DASHBOARD_TIMEOUT_SECONDS=$2 ;;
        --stale) FM_DASHBOARD_STALE_SECONDS=$2 ;;
        --history-limit) FM_DASHBOARD_HISTORY_LIMIT=$2 ;;
        --history-poll) FM_DASHBOARD_HISTORY_POLL_SECONDS=$2 ;;
        --report-bytes) FM_DASHBOARD_REPORT_MAX_BYTES=$2 ;;
      esac
      shift 2
      ;;
    --no-start) START_SERVICE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-dashboard-install: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$FM_DASHBOARD_ADDRESS" in
  127.0.0.1|::1) ;;
  *) echo "fm-dashboard-install: address must be loopback (127.0.0.1 or ::1)" >&2; exit 2 ;;
esac

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
[ -f "$SERVER" ] || { echo "fm-dashboard-install: dashboard server not found at $SERVER" >&2; exit 1; }

case "$FM_DASHBOARD_HOME$SERVER" in
  *$'\n'*|*%*) echo "fm-dashboard-install: paths containing newlines or % are unsupported" >&2; exit 2 ;;
esac

XDG_CONFIG_ROOT=${XDG_CONFIG_HOME:-"$HOME/.config"}
ENV_DIR="$XDG_CONFIG_ROOT/firstmate"
UNIT_DIR="$XDG_CONFIG_ROOT/systemd/user"
ENV_FILE="$ENV_DIR/dashboard.env"
UNIT_FILE="$UNIT_DIR/firstmate-dashboard.service"
NODE_BIN=$(command -v node)
case "$XDG_CONFIG_ROOT$NODE_BIN" in
  *$'\n'*|*%*) echo "fm-dashboard-install: tool and configuration paths containing newlines or % are unsupported" >&2; exit 2 ;;
esac

systemd_quote() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

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
  printf 'EnvironmentFile="%s"\n' "$(systemd_quote "$ENV_FILE")"
  printf 'ExecStart="%s" "%s"\n' "$(systemd_quote "$NODE_BIN")" "$(systemd_quote "$SERVER")"
  cat <<'EOF'
Restart=on-failure
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
  systemctl --user --no-pager --full status firstmate-dashboard.service
else
  echo "Service not started (--no-start)."
fi
