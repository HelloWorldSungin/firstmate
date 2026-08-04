#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded external command execution.
#
# Firstmate calls forges from paths that must never hang: an optional status
# lookup that a dashboard waits on, and an optional tracker write-back that runs
# inside dispatch and merge. A hung CLI is indistinguishable from a slow one, so
# every such call is bounded here rather than each caller re-rolling a timeout.
#
# fm_run_timed <seconds> <command...> runs the command with a hard bound and
# returns the command's own exit code, except:
#   124 or 137  the bound elapsed (whichever the runner reports)
#   125         no bounded runner could start, so nothing was executed
# A caller distinguishes those from a real command failure and reports each
# differently; 125 in particular means "not attempted", never "failed".
#
# fm_call_bound <per-call-default> prints the seconds the NEXT bounded call may
# take. A script that makes several calls inside one operation the caller bounds
# as a whole - a milestone write-back across two surfaces, say - exports
# FM_WRITE_BACK_BUDGET as the seconds that whole script may spend, and each call
# then takes the smaller of its own default and the time left. 0 means the budget
# is spent, which a caller reports as "not attempted" rather than as a forge
# failure. Spending the budget this way is what lets a script exit cleanly with
# its own warning instead of being killed mid-call by an outer bound.
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
  left=$(( budget - SECONDS ))
  if [ "$left" -le 0 ]; then
    printf '0\n'
  elif [ "$left" -lt "$default" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$default"
  fi
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=1 "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=1 "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 125
  fi
}
