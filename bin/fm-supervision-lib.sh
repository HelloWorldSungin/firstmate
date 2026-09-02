# shellcheck shell=bash
# Shared "supervision missing" predicate, plus the watcher-beacon grace window
# and the tolerated-quiet window its consumers measure against.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists) or an X-mode relay poll
# (state/x-watch.check.sh), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# The shared watcher-beacon grace window, in seconds. This is the single owner
# of the window every consumer measures the beacon against: fm_supervision_status
# below, bin/fm-guard.sh through it, and bin/fm-fleet-snapshot.sh's supervision
# block. A beacon is fresh while its age is strictly under the window.
# FM_GUARD_GRACE overrides it; an unparseable override falls back to the default
# rather than silently disabling the check.
FM_SUP_GRACE_DEFAULT=300

fm_sup_grace_seconds() {  # [explicit-override]
  local grace=${1:-${FM_GUARD_GRACE:-$FM_SUP_GRACE_DEFAULT}}
  case "$grace" in ''|*[!0-9]*) grace=$FM_SUP_GRACE_DEFAULT ;; esac
  printf '%s' "$grace"
}

# How long a live worker may stay quiet before that quiet is worth inspecting,
# in seconds. This is the single owner of the window, and it is a window about
# ACTIVITY rather than about the beacon above: bin/fm-watch.sh ages a busy
# pane's latest state/<id>.turn-ended marker against it (busy_turn_over_age),
# and bin/fm-fleet-snapshot.sh publishes it as
# supervision.watcher.quiet_allowance_seconds so the dashboard's Task activity
# signal judges quiet on the window supervision already uses instead of
# carrying a second number of its own. docs/configuration.md documents the
# FM_BUSY_TURN_MAX_SECS override; an unparseable override falls back to the
# default rather than silently disabling the bound.
FM_SUP_BUSY_TURN_MAX_DEFAULT=3600

fm_sup_busy_turn_max_seconds() {  # [explicit-override]
  local secs=${1:-${FM_BUSY_TURN_MAX_SECS:-$FM_SUP_BUSY_TURN_MAX_DEFAULT}}
  case "$secs" in ''|*[!0-9]*) secs=$FM_SUP_BUSY_TURN_MAX_DEFAULT ;; esac
  printf '%s' "$secs"
}

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults through fm_sup_grace_seconds above.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace meta source beat m age
  grace=$(fm_sup_grace_seconds "${2:-}")
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true

  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_QUEUE_PENDING" = true ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
