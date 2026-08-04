# shellcheck shell=bash
# Bounded command execution.
# Usage: . bin/fm-bounded-lib.sh   (no FM_* setup required)
#
# fm_run_bounded runs a command with a wall-clock bound on whichever of
# timeout(1), gtimeout(1), or perl the host actually has, and refuses rather
# than running unbounded when it has none. macOS ships neither timeout nor
# gtimeout without coreutils, so the perl arm is the portability floor rather
# than a curiosity.
#
# This is the single owner of the SIMPLE bound: run one command, kill its
# process group on expiry, report 124. bin/fm-watch.sh deliberately keeps its
# own process-group-OWNING variant, which execs in place, honors an inherited
# group, and traps HUP/INT/TERM so a terminating watcher takes its check with
# it. That is a different guarantee, not a second copy of this one.
#
# FM_BOUNDED_FORCE_FALLBACK=1 forces the perl arm so the fallback is exercised
# on hosts that do have timeout(1).

# Run <cmd...> under a <seconds> wall-clock bound. Returns the command's own
# exit status, 124 when the bound expired, or 125 when the host offers no way
# to bound it at all.
fm_run_bounded() {  # <seconds> <cmd...>
  local secs=$1
  shift
  if [ "${FM_BOUNDED_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif [ "${FM_BOUNDED_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
      "$secs" "$@"
  else
    return 125
  fi
}
