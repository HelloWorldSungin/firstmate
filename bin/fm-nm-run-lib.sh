#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity relationship used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either direction
# is unsafe: a false negative hides a genuinely parked run, and a false positive
# lets teardown act on a run it does not own. Teardown uses the strict
# equal-or-run-ahead predicate. Current-state reporting may additionally accept
# a run-behind head while that exact run is authoring fixes, and may accept any
# head at all - unresolved and diverged included - under the active
# pipeline-owned exemption that fm_nm_run_is_pipeline_owned_active defines at
# this file, because there the pipeline owns those changes.
# The runs-ledger reader below additionally recognizes only the terminal exact-HEAD
# anchor recorded in docs/fork-divergence.md; it does not change teardown.
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
# actively authoring fixes. Missing, unresolved, and diverged never match here:
# an unresolved head is the pipeline-owned lane head, and the branch-custody
# evidence for it is fm_nm_run_is_pipeline_owned_active below rather than any
# head relation. This predicate once accepted an unresolved head from any live
# branch-scoped answer, which was a proxy for that custody before branch_sync
# was readable; a live run on a `synced` branch whose head simply never reached
# this worktree is not attributable by this predicate, so the proxy is not restored.
# The separate ledger-anchored route is owned by fm_nm_runs_row_for_worktree.
fm_nm_head_attributable() {  # <worktree> <run_head> <authoring:0|1>
  case "$(fm_nm_head_relation "$1" "$2")" in
    equal|run-ahead) return 0 ;;
    run-behind)      [ "${3:-0}" = 1 ] && return 0; return 1 ;;
    *)               return 1 ;;
  esac
}

# Strict teardown and historical-list predicate. A current-state caller with
# stronger live-run evidence uses fm_nm_head_attributable directly.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  fm_nm_head_attributable "$1" "$2" 0
}

# The PROVEN-mismatch versus UNKNOWN-attribution distinction upstream carried in
# a separate fm_nm_head_resolvable predicate is expressed here by
# fm_nm_head_relation's `unresolved` verdict, which is the same test with the
# caller's live-run evidence attached. A caller scanning run rows newest-first
# must stop on `unresolved` rather than surface an older, superseded run.

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The custody exemption to the head rule above: while the pipeline OWNS the
# branch (branch_sync.state=pipeline_owned), the daemon's own branch
# attribution IS the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
#
# This exemption is OR'd with fm_nm_head_attributable rather than consulted
# inside it, so it reads NO head relation at all: under pipeline custody an
# active run binds even on a `diverged` head, which fm_nm_head_attributable
# rejects everywhere else. That is deliberate and is the whole difference the
# two rules have. A diverged head under pipeline custody is the pipeline's own
# rebase - the one actor entitled to rewrite that tip while it holds the branch
# - whereas a diverged head with no live custody is the rewritten-tip evidence
# the relation table exists to refuse. `branch_sync.state=pipeline_owned` plus
# a non-terminal run is therefore the whole bound on the exemption, and a
# caller with no branch_sync evidence at all (the coarse runs-listing fallback)
# never reaches it and stays on the relation table alone.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}

# Validate the captured ledger fields without granting attribution. The caller
# reports malformed input as inconclusive, so it cannot erase a degraded read.
fm_nm_runs_row_fields_valid() {  # <status> <branch> <head> <date> <time> <pr> <extra>
  local st=$1 br=$2 sha=$3 day=$4 clock=$5 pr=$6 extra=$7
  local year_num month_num day_num max_day
  [ -n "$st" ] && [ -n "$br" ] && [ -n "$sha" ] && [ -n "$day" ] && [ -n "$clock" ] || return 1
  [ -z "$extra" ] || return 1
  case "$st" in *[!a-z_-]*|'') return 1 ;; esac
  case "$br" in *[!A-Za-z0-9._/-]*|'') return 1 ;; esac
  case "$sha" in *[!A-Fa-f0-9]*|'') return 1 ;; esac
  case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  case "$clock" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) return 1 ;; esac
  case "$pr" in ''|https://*) ;; *) return 1 ;; esac
  [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 40 ] || return 1
  year_num=$((10#${day%%-*}))
  month_num=${day#*-}; month_num=${month_num%%-*}; month_num=$((10#$month_num))
  day_num=$((10#${day##*-}))
  [ "$year_num" -gt 0 ] && [ "$month_num" -ge 1 ] && [ "$month_num" -le 12 ] || return 1
  case "$month_num" in
    1|3|5|7|8|10|12) max_day=31 ;;
    4|6|9|11) max_day=30 ;;
    2)
      if (( year_num % 400 == 0 || (year_num % 4 == 0 && year_num % 100 != 0) )); then
        max_day=29
      else
        max_day=28
      fi
      ;;
  esac
  [ "$day_num" -ge 1 ] && [ "$day_num" -le "$max_day" ] || return 1
  return 0
}

# One owner for runs-ledger attribution, returning the newest matching branch
# row as <evidence>\t<status>\t<head>. Evidence is attributable, inconclusive,
# or rejected; an absent branch prints nothing. Older rows never answer as the
# current run. The only use of an older row is the approved narrow anchor:
# a newest running unresolved head is attributable when the immediately older
# same-branch row is completed, failed, or cancelled at exactly local HEAD.
# Missing, nonterminal, and mismatched anchors remain inconclusive. This is a
# current-state reader, never a relaxation of the strict teardown predicate.
# The listing is the caller's captured `no-mistakes runs --limit N` output:
# newest first, status, branch, short head, then date and optional PR columns.
# Malformed input is inconclusive, never proof that this branch has no run.
fm_nm_runs_row_for_worktree() {  # <worktree> <branch> <runs-list-output>
  local wt=$1 branch=$2 list=$3 row st br sha relation pending_head=''
  local day clock pr extra
  [ -n "$list" ] || return 0
  while IFS= read -r row; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    IFS=$' \t' read -r st br sha day clock pr extra <<< "$row"
    if ! fm_nm_runs_row_fields_valid "$st" "$br" "$sha" "$day" "$clock" "$pr" "$extra"; then
      printf 'inconclusive\tmalformed\t-'
      return 0
    fi
    [ "$br" = "$branch" ] || continue
    relation=$(fm_nm_head_relation "$wt" "$sha")
    if [ -n "$pending_head" ]; then
      case "$st:$relation" in
        completed:equal|failed:equal|cancelled:equal)
          printf 'attributable\trunning\t%s' "$pending_head" ;;
        *) printf 'inconclusive\trunning\t%s' "$pending_head" ;;
      esac
      return 0
    fi
    case "$relation" in
      equal|run-ahead) printf 'attributable\t%s\t%s' "$st" "$sha"; return 0 ;;
      unresolved)
        case "$st" in
          running) pending_head=$sha ;;
          *) printf 'rejected\t%s\t%s' "$st" "$sha"; return 0 ;;
        esac
        ;;
      *) printf 'rejected\t%s\t%s' "$st" "$sha"; return 0 ;;
    esac
  done <<< "$list"
  [ -z "$pending_head" ] || printf 'inconclusive\trunning\t%s' "$pending_head"
  return 0
}
