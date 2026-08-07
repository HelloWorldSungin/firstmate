#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded external command execution.
#
# Firstmate calls forges and other external tools from paths that must never
# hang: an optional status lookup that a dashboard waits on, an optional tracker
# write-back that runs inside dispatch and merge, and a brain read a crewmate is
# waiting on. A hung CLI is indistinguishable from a slow one, so every such call
# is bounded here rather than each caller re-rolling a timeout. bin/fm-watch.sh
# deliberately keeps its own process-group-OWNING variant, which execs in place,
# honors an inherited group, and traps HUP/INT/TERM so a terminating watcher
# takes its check with it. That is a different guarantee, not a second copy.
#
# fm_run_timed <seconds> <command...> runs the command with a hard bound and
# returns the command's own exit code, except:
#   124 or 137  the bound elapsed (whichever the runner reports)
#   125         nothing was executed: no bounded runner could start, or the
#               requested bound was not a positive whole number of seconds
# A caller distinguishes those from a real command failure and reports each
# differently; 125 in particular means "not attempted", never "failed".
# A command killed by a signal reports 128+signal rather than the shell's own
# status, so a child the OOM killer or an outer bound took is never mistaken for
# one that exited 0.
#
# A bound of 0 is refused rather than honored, because 0 is not a bound: GNU
# timeout documents DURATION 0 as "no timeout", and the perl arm's `alarm 0`
# cancels the alarm outright, so either arm would run the command unbounded on
# the exact input a caller meant as "no time left".
#
# FM_TIMEOUT_KILL_GRACE is the seconds between the polite signal and the kill
# (1 by default). A caller raises it for a call whose child must leave something
# CONSISTENT behind rather than merely die - bin/fm-usage.mjs checkpoints its
# store back out of WAL on SIGTERM, and a kill that arrives mid-checkpoint would
# leave the shape the dashboard cannot read.
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
# macOS ships neither timeout nor gtimeout without coreutils, so the perl arm is
# the portability floor rather than a curiosity.
# FM_TIMEOUT_FORCE_FALLBACK=1 forces that arm so it stays exercised on hosts
# that do have timeout(1).
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
  local seconds=$1 force=${FM_TIMEOUT_FORCE_FALLBACK:-0} grace=${FM_TIMEOUT_KILL_GRACE:-1}
  shift
  case "$seconds" in ''|*[!0-9]*) return 125 ;; esac
  [ "$seconds" -ge 1 ] || return 125
  case "$grace" in ''|*[!0-9]*) grace=1 ;; esac
  if [ "$force" != 1 ] && command -v timeout >/dev/null 2>&1; then
    timeout --kill-after="$grace" "$seconds" "$@"
  elif [ "$force" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after="$grace" "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $g = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, $g; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; my $st = $?; exit($st & 127 ? 128 + ($st & 127) : $st >> 8)' "$seconds" "$grace" "$@"
  else
    return 125
  fi
}
