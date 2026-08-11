#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity relationship used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either direction
# is unsafe: a false negative hides a genuinely parked run, and a false positive
# lets teardown act on a run it does not own. Teardown uses the strict
# equal-or-run-ahead predicate. Current-state reporting may additionally accept
# a run-behind head while that exact run is authoring fixes, or an unresolved
# head from a live branch-scoped answer, because the pipeline owns those changes.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Print how run head $2 relates to worktree $1's HEAD:
#   equal       the commits match, including short-SHA input
#   run-ahead   worktree HEAD is an ancestor of the run head
#   run-behind  run head is a strict ancestor of worktree HEAD
#   unresolved  run head is not an object in this worktree
#   missing     either input has no readable commit
#   diverged    both commits resolve but neither is ancestor of the other
fm_nm_head_relation() {  # <worktree> <run_head>
  local wt=$1 run_head=${2:-} local_full run_full
  [ -n "$run_head" ] || { printf 'missing'; return; }
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { printf 'missing'; return; }
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || { printf 'unresolved'; return; }
  if [ "$run_full" = "$local_full" ]; then printf 'equal'; return; fi
  if git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    printf 'run-ahead'; return
  fi
  if git -C "$wt" merge-base --is-ancestor "$run_full" "$local_full" 2>/dev/null; then
    printf 'run-behind'; return
  fi
  printf 'diverged'
}

# 0 when a run may be attributed to the worktree under the caller's evidence.
# Equal and run-ahead always match. Run-behind matches only while the run is
# actively authoring fixes. An unresolved head matches only for a live answer
# already scoped to this exact branch. Missing and diverged never match.
fm_nm_head_attributable() {  # <worktree> <run_head> <authoring:0|1> <branch-scoped-live:0|1>
  case "$(fm_nm_head_relation "$1" "$2")" in
    equal|run-ahead) return 0 ;;
    run-behind)      [ "${3:-0}" = 1 ] && return 0; return 1 ;;
    unresolved)      [ "${4:-0}" = 1 ] && return 0; return 1 ;;
    *)               return 1 ;;
  esac
}

# Strict teardown and historical-list predicate. A current-state caller with
# stronger live-run evidence uses fm_nm_head_attributable directly.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  fm_nm_head_attributable "$1" "$2" 0 0
}
