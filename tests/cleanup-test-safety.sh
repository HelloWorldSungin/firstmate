#!/usr/bin/env bash
set -u

fm_test_tmux_server_state() {
  local tmux_bin=$1 socket=$2 output rc
  [ -n "$tmux_bin" ] || { echo "tmux safety guard: empty tmux binary" >&2; return 1; }
  [ -n "$socket" ] || { echo "tmux safety guard: empty socket name" >&2; return 1; }
  if output=$("$tmux_bin" -L "$socket" list-sessions 2>&1); then
    printf 'present\n'
    return 0
  else
    rc=$?
  fi
  case "$output" in
    "no server running on "*|"error connecting to "*" (No such file or directory)"|"error connecting to "*" (Connection refused)")
      printf 'absent\n'
      return 0
      ;;
  esac
  echo "tmux safety guard: session inventory failed (exit $rc): ${output:-<no output>}" >&2
  return 1
}

fm_test_tmux_safe_kill_server() {
  local tmux_bin=$1 socket=$2 state attempts=0
  state=$(fm_test_tmux_server_state "$tmux_bin" "$socket") || return 1
  [ "$state" = present ] || return 0
  "$tmux_bin" -L "$socket" kill-server >/dev/null 2>&1 || return 1
  while [ "$attempts" -lt 50 ]; do
    if state=$(fm_test_tmux_server_state "$tmux_bin" "$socket" 2>/dev/null) && [ "$state" = absent ]; then
      return 0
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  state=$(fm_test_tmux_server_state "$tmux_bin" "$socket") || return 1
  if [ "$state" != absent ]; then
    echo "tmux safety guard: server on socket $socket still exists after kill-server" >&2
    return 1
  fi
  return 0
}

fm_test_safe_stop_process() {
  local pid=$1 label=$2
  [ -n "$pid" ] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    return 0
  fi
  if ! kill "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
    echo "cleanup: could not signal $label process $pid" >&2
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  if kill -0 "$pid" 2>/dev/null; then
    echo "cleanup: $label process $pid is still running after termination" >&2
    return 1
  fi
  return 0
}
