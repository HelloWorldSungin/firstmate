#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded external command execution.
#
# Sourced, never executed. Every bounded call in this repository shares the
# mechanism selection, process-group reap, budget calculation, and exit-status
# contract declared here.
#
# fm_timeout_mechanism prints timeout, gtimeout, perl, or bash.
# FM_TIMEOUT_MECHANISM_OVERRIDE=bash forces the dependency-free fallback.
# FM_TIMEOUT_FORCE_FALLBACK=1 forces a non-coreutils fallback, preferring perl
# for compatibility with the fork's existing fallback test surface.
#
# fm_run_timed <seconds> <command...> returns the command's own exit code,
# except 124 means the bound elapsed and 125 means nothing was attempted because
# the bound was invalid or no bounded runner could start.
# A command killed by a signal reports 128+signal.
#
# Every runner places the command in its own process group and reaps the whole
# group after the polite timeout signal, so a hung descendant cannot survive.
# FM_TIMEOUT_KILL_GRACE is the positive whole-number delay between TERM and KILL
# and defaults to 1 second.
#
# fm_call_bound <per-call-default> prints the next call's share of the optional
# FM_WRITE_BACK_BUDGET whole-operation budget.
#
# No side effects on source. set -u / set -e safe.

fm_call_bound() {  # <per-call-default>
  local default=$1 budget=${FM_WRITE_BACK_BUDGET:-} left
  case "$budget" in
    ''|*[!0-9]*)
      printf '%s\n' "$default"
      return 0
      ;;
  esac
  left=$((budget - SECONDS))
  if [ "$left" -le 0 ]; then
    printf '0\n'
  elif [ "$left" -lt "$default" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$default"
  fi
}

fm_timeout_mechanism() {
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif [ "${FM_TIMEOUT_FORCE_FALLBACK:-0}" = 1 ]; then
    if command -v perl >/dev/null 2>&1; then
      printf 'perl\n'
    else
      printf 'bash\n'
    fi
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

fm_run_bash_timeout() {  # <seconds> <grace> <command...>
  local seconds=$1 grace=$2 command_status deadline_status child_pid watchdog_pid
  local command_rc recorded_rc monitor_was_on=0
  shift 2
  command_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-command.XXXXXX" 2>/dev/null) || return 125
  deadline_status="${command_status}.deadline"
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    "$@"
    command_rc=$?
    printf '%s\n' "$command_rc" > "$command_status"
    exit "$command_rc"
  ) &
  child_pid=$!
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep "$grace"
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_run_external_timeout() {  # <runner> <seconds> <grace> <command...>
  local runner=$1 seconds=$2 grace=$3 runner_pid runner_rc started elapsed
  shift 3
  started=$SECONDS
  # Run the external runner asynchronously so its pid - which is also the
  # process-group id GNU/BSD timeout creates for itself without --foreground -
  # stays available for an explicit reap. A shell wrapper can exit promptly on
  # TERM while one of its descendants ignores TERM; timeout then considers the
  # command finished and never sends its configured KILL, so a real timeout
  # reaps that leftover group below instead of leaving it running.
  # `<&0` is load-bearing: without an explicit redirection a non-interactive
  # shell points an async command's stdin at /dev/null, which would silently
  # empty a piped payload (bin/fm-forge-lib.sh feeds curl its config on stdin).
  "$runner" -k "$grace" "$seconds" "$@" <&0 &
  runner_pid=$!
  # 2>/dev/null matches fm_run_bash_timeout: the shell otherwise prints its own
  # "Killed" job notice when a reaped async job died on a signal.
  if wait "$runner_pid" 2>/dev/null; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  elapsed=$((SECONDS - started))
  case "$runner_rc" in
    124)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    # GNU timeout reports 137 when its kill-after escalation fired, while a
    # command may also naturally exit 137. The deadline distinguishes them
    # without interposing a status-recording shell that would become the direct
    # child and let the real command escape timeout's process-group reap.
    137)
      if [ "$elapsed" -ge "$seconds" ]; then
        kill -KILL -- "-$runner_pid" 2>/dev/null || true
        return 124
      fi
      return 137
      ;;
    *) return "$runner_rc" ;;
  esac
}

fm_run_perl_timeout() {  # <seconds> <grace> <command...>
  local seconds=$1 grace=$2
  shift 2
  perl -e 'use POSIX qw(WNOHANG); my $t = shift; my $g = shift; my $pid = fork; exit 125 unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 125 } local $SIG{ALRM} = sub { kill "TERM", -$pid; for (my $i = 0; $i < $g * 20; $i++) { last if waitpid($pid, WNOHANG) != 0; select undef, undef, undef, 0.05 } kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; alarm $t; waitpid $pid, 0; my $st = $?; exit($st & 127 ? 128 + ($st & 127) : $st >> 8)' "$seconds" "$grace" "$@"
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1 grace=${FM_TIMEOUT_KILL_GRACE:-1}
  shift
  case "$seconds" in ''|*[!0-9]*) return 125 ;; esac
  [ "$seconds" -ge 1 ] || return 125
  case "$grace" in ''|*[!0-9]*|0) grace=1 ;; esac
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$grace" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$grace" "$@" ;;
    perl) fm_run_perl_timeout "$seconds" "$grace" "$@" ;;
    bash) fm_run_bash_timeout "$seconds" "$grace" "$@" ;;
    *) return 125 ;;
  esac
}
