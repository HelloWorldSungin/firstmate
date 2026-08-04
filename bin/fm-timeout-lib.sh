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
# No side effects on source. set -u / set -e safe.

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
