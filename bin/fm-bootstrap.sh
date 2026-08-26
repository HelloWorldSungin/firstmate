#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "CREW_DISPATCH: backend mismatch - <reason>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "BOARD_SWEEP: <project>: <board drift the sweep corrected, or a status option the captain must add by hand>",
#                 "PR_CHECK_MIGRATION: <private remediation>",
#                 "ENDPOINT_BINDING_MIGRATION: task <id> (<backend>): <reason>",
#                 "RUN_ATTRIBUTION: task <id>: legacy no-mistakes metadata has no proven branch=; any run is unattributable until task cleanup",
#                 "TANGLE: <remediation>",
#                 "VAULT_DRIFT: <project>: <vault problem and remedy>",
#                 "UPSTREAM: <fork drift or measurement failure>",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged fm-<id> with '<message>'",
#                 "SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>",
#                 "SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)",
#                 "USAGE_STORE: skipped|failed: <detail>",
#                 "GBRAIN_SERVING_CREDENTIAL: <why hosted synthesis is reachable on a serving home, or why the verdict could not be reached>",
#                 "GBRAIN_PIN: <drift between the recorded GBrain pin and the installed release, or why a side could not be read>",
#                 "GBRAIN_CAPTURE: <captured task knowledge the brain no longer serves, or why the capture sweep could not finish>",
#                 "FMX: X mode on ..." or "FMX: X mode off ...".
#          When a RUNNING local secondmate worktree is fast-forwarded to
#          firstmate's own current default-branch commit, that update is a
#          purely local fast-forward and never an origin fetch. Remote routes
#          instead converge the persistent home to their configured remote code
#          root. If either placement changes its loaded instruction surface
#          (AGENTS.md, bin/, or .agents/skills/), bootstrap immediately nudges it
#          via FM_HOME=<active-home> bin/fm-send.sh fm-<id> so meta resolves the
#          current route and the standard from-firstmate marker is applied. A
#          successful send prints one BOOTSTRAP_INFO line with the exact target
#          and message sent; a failed send leaves an idempotent retry marker
#          under state/.secondmate-nudge-pending/ and prints an actionable
#          NUDGE_SECONDMATES line.
#          Already-current or no-instruction-change homes are silently left alone.
#          The secondmate sweep also propagates declared inherited local material
#          into each validated live secondmate home.
#          SECONDMATE_SYNC lines report actionable skipped placement-specific
#          syncs or inheritance failures for live secondmate homes, plus
#          quarantine diagnostics for divergent shared captain-preference
#          copies; no-op/current and successful updates stay quiet.
#          SECONDMATE_LIVENESS lines report only actionable failures from the
#          recovery-grade state owned by bin/fm-backend.sh's
#          fm_backend_agent_state: skipped distinguishes an existing ambiguous
#          process, an unreadable target, and an unverified backend; respawn
#          failed names whether the endpoint was missing or agent-less.
#          Already-live and successfully relaunched secondmates are silent
#          unless FM_BOOTSTRAP_VERBOSE_FACTS=1 requests BOOTSTRAP_INFO facts.
#          A TANGLE line means the firstmate primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          A VAULT_DRIFT line means a project's documentation vault is stale, or
#          its external vault link is absent or broken so drift cannot be
#          measured at all; the check is read-only and runs in detect-only
#          sessions too. bin/fm-vault-drift.sh owns the vault shapes, thresholds,
#          and exact wording.
#          An UPSTREAM line is the optional fork-drift detector's read-only
#          report. bin/fm-upstream-status.sh owns its trigger and wording, stays
#          inert without an upstream remote, and never fetches into this repo.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.31.2.
#          The AXI-family floor policy is owned beside GH_AXI_MIN,
#          LAVISH_AXI_MIN, and CHROME_DEVTOOLS_AXI_MIN below; the per-tool
#          owners point there. An installed
#          build below its floor reports MISSING like no-mistakes, so the operator
#          is asked to upgrade rather than silently running an older tool.
#          tasks-axi feature probes remain a separate defense-in-depth check.
#          tasks-axi and quota-axi are required bootstrap tools (same class as
#          lavish-axi). A compatible tasks-axi default backend is silent.
#          quota-axi is required for the agent-owned dispatch-profile array
#          procedure in AGENTS.md section 4 and
#          .agents/skills/quota-array-dispatch/SKILL.md.
#          On a primary home, the locked mutable path materializes the visible
#          default config/startup-memory-budget=7500 when absent. It never
#          guesses at malformed or unsafe existing files, and secondmate homes
#          await the primary-authoritative inherited value instead of creating
#          their own.
#          X mode is OPTIONAL and inert unless FM_HOME/.env has a non-empty
#          FMX_PAIRING_TOKEN. When opted in, bootstrap requires curl+jq, writes
#          the relay poll shim and 30s cadence config, and prints an FMX line.
#          Fleet sync fetches with stale remote-pointer pruning, fast-forwards
#          safe default-branch states, and reports recovered and STUCK clone
#          drift; it is bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed fm-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          An ENDPOINT_BINDING_MIGRATION line reports one non-tmux task record
#          that lacks `endpoint_task_id=` and whose recorded endpoint could not
#          be verified to belong to that task, so cleanup still refuses it;
#          bin/fm-endpoint-binding-migrate.sh owns that contract.
#          A RUN_ATTRIBUTION line names one live legacy no-mistakes task whose
#          run remains unreadable because its metadata has no proven branch.
#          bin/fm-run-attribution-legacy-transition.sh owns the one safe PR-head
#          migration proof, the refusal of every inferential source, and the
#          detect-only diagnostic.
#          The usage refresh runs a best-effort bin/fm-usage.mjs ingest only
#          when data/usage.db already exists, matching teardown's opt-in
#          contract in docs/usage-accounting.md; it is bounded by
#          FM_BOOTSTRAP_USAGE_TIMEOUT (blank, non-numeric or zero falls back to
#          120s) and every bound escalates to SIGKILL. A successful refresh is silent;
#          one that timed out, could not be bounded on this host, or ran and
#          exited non-zero reports itself on a single USAGE_STORE line rather
#          than degrading silently.
#          The recorded-GBrain-pin comparison runs bin/fm-gbrain-pin-check.sh
#          wherever this code root carries a docs/gbrain.md, and that script
#          alone decides whether this host has a gbrain to compare against; it
#          is bounded by FM_BOOTSTRAP_PIN_TIMEOUT (blank, non-numeric or zero
#          falls back to 10s) and every bound escalates to SIGKILL. Agreement
#          and a home with no GBrain installed are both silent; drift, a side
#          that could not be read, and a read that could not be bounded each
#          report themselves on a single GBRAIN_PIN line.
#          The captured-knowledge sweep runs bin/fm-gbrain-capture.sh in a home
#          that has an initialized brain, at most every
#          FM_GBRAIN_CAPTURE_SWEEP_INTERVAL seconds (default 6h) and bounded by
#          FM_BOOTSTRAP_CAPTURE_TIMEOUT (blank, non-numeric or zero falls back to
#          120s). It is the structural re-capture trigger: a durable report or
#          manifest edited after its page was written is recomposed and
#          re-delivered to the same page here, so a page can go stale only for
#          one interval rather than until somebody remembers. It then audits what
#          the outbox says was captured against what the index actually serves.
#          A sweep that corrected nothing and found no gap is silent; refreshed
#          pages, a parity gap, and a sweep that could not finish each report
#          themselves on GBRAIN_CAPTURE lines.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the eleven MUTATING sweeps
#          (PR-check migration, endpoint-binding migration, run-attribution
#          transition, secondmate_sync, secondmate_liveness_sweep,
#          secondmate_handoff_resume, x_mode_setup, fleet_sync, board_sweep,
#          gbrain_capture_sweep, usage_store_refresh)
#          while still printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          fm-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          PR-check artifacts, secondmate homes, pending handoff outboxes,
#          X-mode artifacts, project clones, the usage store and its per-task
#          session maps, or repair instructions.
#          Unset/0 (the default) runs every sweep exactly as before - this flag
#          is purely additive.
#          Set FM_BOOTSTRAP_NETWORK to split this run by whether a step talks to
#          the network, so a session start can print its digest from local reads
#          alone and run the network half concurrently:
#            all  (default, and any unrecognized value) - everything, exactly as
#                 before. Unrecognized values fall back here on purpose: a typo
#                 must never silently skip a safety sweep.
#            skip - every LOCAL step, and none of the network ones. Skips
#                 `gh auth status`, secondmate_liveness_sweep, secondmate_sync,
#                 secondmate_handoff_resume, fleet_sync, and board_sweep.
#            only - ONLY those network steps and nothing else. No tool detection,
#                 no version floors, no tangle check, no PR-check migration, no
#                 x_mode_setup: those already ran on the local pass.
#          FM_BOOTSTRAP_DETECT_ONLY composes with it unchanged, so `only` plus
#          detect-only is the read-only `gh auth status` probe on its own.
#          bin/fm-startup-network.sh owns the deferral: it runs the `only` phase
#          in a detached bounded worker and publishes the result. This file stays
#          the single owner of every sweep, and the split changes only WHEN each
#          runs, never WHETHER.
#          A relaunch that the liveness sweep performs during an `only` run is
#          always reported, because a digest composed before that run already
#          printed the superseded endpoint record.
#          Set FM_BOOTSTRAP_LOCKED=1 alongside it when the sweeps are skipped
#          because THIS session already ran them while holding the fleet lock,
#          rather than because it has no lock at all. The two cases differ in
#          exactly one place: repair ownership. A locked session is told to
#          restore a tangled primary checkout itself, while an unlocked one is
#          told to leave that work to the lock holder. Unset/0 (the default)
#          keeps detect-only meaning unlocked, exactly as before.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# fm-timing-lib.sh is inert unless FM_TIMING_LOG names a file, which only the
# deferred network stage sets, so an ordinary bootstrap run records nothing.
# shellcheck source=bin/fm-timing-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timing-lib.sh"

# Network-phase selection (see the header). An unrecognized value resolves to
# `all` so a malformed override runs every step rather than silently dropping a
# safety sweep.
case "${FM_BOOTSTRAP_NETWORK:-all}" in
  skip|only) FM_BOOTSTRAP_NETWORK_PHASE=${FM_BOOTSTRAP_NETWORK:-all} ;;
  *) FM_BOOTSTRAP_NETWORK_PHASE=all ;;
esac
local_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != only ]; }
network_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != skip ]; }

network_mutation_authorized() {
  local expected=${FM_BOOTSTRAP_NETWORK_LOCK_PID:-} current
  [ -n "$expected" ] || return 0
  case "$expected" in *[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

network_sweep_authorized() {
  local label=$1
  if network_mutation_authorized; then
    return 0
  fi
  echo "NETWORK_CHECKS: fleet lock ownership changed before $label, so this stale worker skipped that sweep"
  return 1
}

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

# Best-effort usage refresh at a locked session boundary. Ingestion is
# idempotent and only runs once a home already has data/usage.db, matching
# teardown's opt-in contract in docs/usage-accounting.md. The call is bounded,
# because a first collection scans every Claude transcript and Codex rollout on
# the machine: a slow or hung collector degrades to a staler store rather than
# stalling session start. A refresh that does not finish says so on one
# USAGE_STORE line, the way fleet_sync reports its own timeout, so a session
# that just spent the whole budget is never left guessing why.
#
# The bound comes from bin/fm-timeout-lib.sh, the declared single owner: every
# arm there escalates to SIGKILL because SIGTERM alone is not a bound, and a
# runner that cannot start reports 125 without starting a scan of every
# transcript on the machine unbounded at session start.
usage_store_refresh() {
  [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && return 0
  [ -f "$DATA/usage.db" ] || return 0
  [ -x "$SCRIPT_DIR/fm-usage.mjs" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  local timeout=${FM_BOOTSTRAP_USAGE_TIMEOUT:-120} start elapsed status=0
  # Zero falls back with the blank and the non-numeric, because zero is not a
  # bound: GNU timeout reads DURATION 0 as "no timeout". The owner refuses it
  # too, so the fallback is what keeps that input a 120-second refresh rather
  # than a skipped one.
  case "$timeout" in ''|*[!0-9]*) timeout=120 ;; esac
  [ "$timeout" -ge 1 ] || timeout=120
  start=$SECONDS
  # The kill grace is raised from the owner's one-second default because the
  # polite signal has real work to do here: fm-usage.mjs answers SIGTERM by
  # checkpointing the store back out of WAL, and a kill that lands mid-close
  # leaves behind exactly the WAL-at-rest shape the read-only dashboard cannot
  # open (issue #65).
  (
    export FM_TIMEOUT_KILL_GRACE=5
    fm_run_timed "$timeout" node "$SCRIPT_DIR/fm-usage.mjs" ingest --home "$FM_HOME"
  ) >/dev/null 2>&1 || status=$?
  elapsed=$((SECONDS - start))
  case "$status" in
    0) ;;
    125)
      echo "USAGE_STORE: skipped: the bounded runner could not start"
      ;;
    124|137)
      echo "USAGE_STORE: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      ;;
    *)
      # Not "skipped": fm-usage.mjs exits non-zero for a derivation stage that
      # failed after the collection it already committed, so the likeliest
      # reading of this line is a refresh that ran and landed part of its work.
      echo "USAGE_STORE: failed: bootstrap refresh ran but exited $status (elapsed=${elapsed}s)"
      ;;
  esac
  return 0
}

# The fleet-wide board drift sweep, run where it is cheap: once per locked
# session start, at most every FM_BOARD_SWEEP_INTERVAL seconds (default 6h), and
# only for projects whose data/projects.md entry DECLARES a board. A home that
# declares none - which is every home until the captain adds the token - does
# nothing here and contacts no host.
#
# bin/fm-project-board.sh owns what the sweep may write, and its own bounds hold
# for a direct run. Inside the deferred network stage it gets a TIGHTER one, for
# the reason board_sweep_budget states.
#
# Only its actionable lines are relayed: a board this run could not reach is not
# a fleet diagnostic, because the next sweep re-derives exactly the same drift,
# and a session start that reported every transient network hiccup would train
# the reader to skip the section that also carries the destructive one - a board
# missing the status option a closed issue needs, which is the captain's to add
# by hand.
board_sweep_due() {
  local marker="$STATE/.board-sweep" interval=${FM_BOARD_SWEEP_INTERVAL:-21600} mtime now
  case "$interval" in
    ''|*[!0-9]*) interval=21600 ;;
  esac
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || return 0
  now=$(date +%s)
  [ $((now - mtime)) -ge "$interval" ]
}

# The sweep's share of the stage that contains it, or 0 when there is too little
# of that stage left to be worth starting one.
#
# fm-startup-network.sh bounds the whole deferred network stage and kills it by
# process group, so a sweep carrying only its own larger default would take the
# checks that run after it down with it - a board problem becoming a fleet
# problem, which is the one thing this sweep may never do. The bound is handed
# down rather than repeated here, so the two cannot drift apart when either
# default changes; an unset value means this is a direct run outside the stage,
# where the script's own FM_BOARD_SWEEP_TIMEOUT is the right bound.
#
# Half of what is left, because upstream_status_check and vault_drift_check
# still have to run after this and are owed the other half.
BOARD_SWEEP_GRACE=2
BOARD_SWEEP_MIN_BUDGET=5
board_sweep_budget() {
  local stage=${FM_STARTUP_NETWORK_TIMEOUT:-} left
  case "$stage" in ''|*[!0-9]*|0) echo ''; return 0 ;; esac
  left=$((stage - SECONDS))
  [ "$left" -gt 0 ] || { echo 0; return 0; }
  echo $((left / 2))
}

board_sweep() {
  local tmp budget
  [ -x "$FM_ROOT/bin/fm-project-board.sh" ] || return 0
  [ -f "$DATA/projects.md" ] || return 0
  grep -q '\[[^]]*board=' "$DATA/projects.md" 2>/dev/null || return 0
  board_sweep_due || return 0
  budget=$(board_sweep_budget)
  # Checked before the marker is stamped, so a session start that had no room
  # for the sweep leaves the next one free to run it rather than burning the
  # interval on a sweep that never happened.
  [ -z "$budget" ] || [ "$budget" -ge "$BOARD_SWEEP_MIN_BUDGET" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-board-sweep.XXXXXX" 2>/dev/null) || return 0
  # The marker is stamped BEFORE the run, so a sweep that dies part-way through
  # waits out its interval like any other rather than retrying on every session
  # start against a board that is already refusing it.
  : > "$STATE/.board-sweep" 2>/dev/null || true
  if [ -n "$budget" ]; then
    # The budget is what the sweep spends across its own calls and reports on;
    # the bound around it is a backstop with a little grace, for the case a
    # budget cannot cover. Both are scoped to this one call so no other sweep
    # inherits either.
    (
      export FM_WRITE_BACK_BUDGET=$budget
      fm_run_timed "$((budget + BOARD_SWEEP_GRACE))" \
        "$FM_ROOT/bin/fm-project-board.sh" reconcile --quiet
    ) >"$tmp" 2>/dev/null || true
  else
    "$FM_ROOT/bin/fm-project-board.sh" reconcile --quiet >"$tmp" 2>/dev/null || true
  fi
  grep '^BOARD_SWEEP:' "$tmp" || true
  awk '/^board: /{ sub(/^board: /, ""); print "BOARD_SWEEP: " $0 }' "$tmp" || true
  rm -f "$tmp"
  return 0
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

vault_drift_check() {
  FM_HOME="$FM_HOME" FM_PROJECTS_OVERRIDE="$PROJECTS" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-vault-drift.sh" || true
}

upstream_status_check() {
  [ -x "$SCRIPT_DIR/fm-upstream-status.sh" ] || return 0
  FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-upstream-status.sh" || true
}

# docs/gbrain.md owns the rule. This read-only check has no fleet-sync
# dependency and stays silent when the home is clear.
gbrain_serving_credential_check() {
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-gbrain.sh" serving-check || true
}

# docs/gbrain.md's upgrade policy requires the recorded GBrain pin and the
# installed release to move in one change, and bin/fm-gbrain-pin-check.sh is the
# single comparer of the two. Session start is where that comparison has to
# happen: the drift it exists to catch came from an upgrade performed outside
# that procedure, so a check reachable only from inside the procedure is one an
# operator skips exactly when it matters. CI cannot close it either, because CI
# has no brain and the check is inherently skipped there.
#
# Whether this host has a gbrain to compare against is the comparer's own
# question, so it is asked there rather than gated on a second copy of the
# resolution rule here: an absent brain comes back as its silent `skipped`,
# while an FM_GBRAIN_BIN naming an executable that moved comes back as a line
# instead of disappearing. The one gate left is the record's presence, which is
# bin/fm-doc-audience-check.sh's invariant rather than a session's to report.
# Everything past it is either agreement, which is silent, or a line. The read
# is bounded like every other startup probe because it execs `gbrain --version`,
# and a hung executable must degrade to one reported line rather than parking
# session start.
gbrain_pin_drift_check() {
  local timeout=${FM_BOOTSTRAP_PIN_TIMEOUT:-10} out status=0
  [ -x "$SCRIPT_DIR/fm-gbrain-pin-check.sh" ] || return 0
  [ -f "$FM_ROOT/docs/gbrain.md" ] || return 0
  # Zero falls back with the blank and the non-numeric for the reason
  # usage_store_refresh records: zero is not a bound to any runner underneath.
  case "$timeout" in ''|*[!0-9]*) timeout=10 ;; esac
  [ "$timeout" -ge 1 ] || timeout=10
  out=$(fm_run_timed "$timeout" \
    env FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-gbrain-pin-check.sh" 2>&1) || status=$?
  # The check owns the verdict wording and prefixes it with its own name; strip
  # that prefix so the emitted line reads as one of this family rather than two
  # names stacked, and keep the verdict word it chose.
  out=$(printf '%s\n' "$out" | head -1)
  out=${out#fm-gbrain-pin-check: }
  case "$status" in
    0) ;;
    1 | 2) echo "GBRAIN_PIN: ${out:-bin/fm-gbrain-pin-check.sh exited $status without saying why}" ;;
    124 | 137)
      echo "GBRAIN_PIN: unknown - the bounded pin check did not finish within ${timeout}s, so the recorded pin was compared against nothing"
      ;;
    125)
      echo "GBRAIN_PIN: unknown - the bounded runner could not start, so the recorded pin was compared against nothing"
      ;;
    *)
      echo "GBRAIN_PIN: unknown - bin/fm-gbrain-pin-check.sh exited $status: ${out:-no output}"
      ;;
  esac
  return 0
}

# The structural re-capture trigger, and the parity audit that proves it worked,
# armed where it is cheap: once per locked session start, on the sweep's own
# interval, in a home that has a brain.
#
# bin/fm-gbrain-capture.sh sweep owns all of that - the interval, the inertness
# of a home with no brain, what gets refreshed, and what the audit compares - so
# this is a bounded call and a prefix, not a second copy of the policy. Its
# output is already only the actionable lines; everything else is silence.
#
# The sweep is home-local: the index and the embedding endpoint are on this
# machine, so it belongs to the local phase and contacts no host.
gbrain_capture_sweep() {
  [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && return 0
  [ -x "$SCRIPT_DIR/fm-gbrain-capture.sh" ] || return 0
  local timeout=${FM_BOOTSTRAP_CAPTURE_TIMEOUT:-120} tmp status=0 line
  # Zero falls back with the blank and the non-numeric for the reason
  # usage_store_refresh records: zero is not a bound to any runner underneath.
  case "$timeout" in ''|*[!0-9]*) timeout=120 ;; esac
  [ "$timeout" -ge 1 ] || timeout=120
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-gbrain-capture-sweep.XXXXXX" 2>/dev/null) || return 0
  fm_run_timed "$timeout" "$SCRIPT_DIR/fm-gbrain-capture.sh" sweep >"$tmp" 2>/dev/null || status=$?
  case "$status" in
    0 | 1)
      # The sweep exits 1 when it has something to say, so an exit 1 with an
      # empty file means it stopped before saying it. Reporting that as silence
      # would hide exactly the sweep failure this line exists to surface.
      if [ "$status" -eq 1 ] && [ ! -s "$tmp" ]; then
        echo "GBRAIN_CAPTURE: the captured-knowledge sweep stopped without reporting why; run bin/fm-gbrain-capture.sh sweep --force by hand to see it"
      fi
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "GBRAIN_CAPTURE: $line"
      done < "$tmp"
      ;;
    124 | 137)
      echo "GBRAIN_CAPTURE: unknown - the captured-knowledge sweep did not finish within ${timeout}s, so an edited report may still be serving its old page and the served pages were compared against nothing"
      ;;
    125)
      echo "GBRAIN_CAPTURE: unknown - the bounded runner could not start, so the captured-knowledge sweep did not run"
      ;;
    *)
      echo "GBRAIN_CAPTURE: the captured-knowledge sweep exited $status; run bin/fm-gbrain-capture.sh sweep --force by hand to see why"
      ;;
  esac
  rm -f "$tmp"
  return 0
}

secondmate_sync() {
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # Placement-specific secondmate sync: local homes fast-forward to the primary
  # checkout's current default-branch commit. That path is purely LOCAL - no
  # fetch, no origin dependency: a linked-worktree home already holds the primary's
  # commit (fm-ff-lib.sh), while a standalone clone without it is skipped until
  # /updatefirstmate refreshes it from origin. Startup sends reread nudges only
  # for RUNNING secondmates whose instruction surface (AGENTS.md, bin/, or
  # .agents/skills/) actually changed, so a secondmate already on the primary's
  # version is never disturbed (AGENTS.md bootstrap + supervision). Unlike
  # /updatefirstmate, startup owns the live-convergence send itself because it is
  # a deterministic locked sweep and can report success as BOOTSTRAP_INFO while
  # preserving failed sends as NUDGE_SECONDMATES retry markers.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$FM_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
      id=$(basename "$meta" .meta)
      echo "SECONDMATE_SYNC: secondmate $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  SECOND_MATE_NUDGE_MESSAGE=$FM_SECOND_MATE_NUDGE_MESSAGE
  REMOTE_SECOND_MATE_NUDGE_MESSAGE=$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE
  SECOND_MATE_NUDGE_PENDING_DIR="$STATE/.secondmate-nudge-pending"

  secondmate_nudge_marker_path() {
    fm_secondmate_nudge_marker_path "$STATE" "$1"
  }

  secondmate_write_nudge_marker() {
    local id=$1 home=$2 commit=$3 instr=$4 message=${5:-$SECOND_MATE_NUDGE_MESSAGE} remote=${6:-0}
    fm_secondmate_nudge_write "$STATE" "$id" "$home" "$commit" "$instr" "$message" "$remote"
  }

  secondmate_send_nudge() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker out
    selector="fm-$id"
    marker=$(secondmate_nudge_marker_path "$id") || {
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: unsafe id"
      return 0
    }
    if ! secondmate_write_nudge_marker "$id" "$home" "$commit" "$instr"; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot record retry marker"
      return 0
    fi
    if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
      rm -f "$marker"
      echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
    else
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
    fi
  }

  fm_ff_after_instruction_update() {
    local id=$1 home=$2 _window=$3 instr=$4
    secondmate_send_nudge "$id" "$home" "$primary_head" "$instr"
  }

  secondmate_retry_pending_nudges() {
    local marker id selector home commit message remote expected_marker meta meta_home home_real head out
    [ -d "$SECOND_MATE_NUDGE_PENDING_DIR" ] || return 0
    for marker in "$SECOND_MATE_NUDGE_PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      id=$(fm_meta_get "$marker" id)
      if ! expected_marker=$(secondmate_nudge_marker_path "$id"); then
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker has unsafe id"
        continue
      fi
      [ "$expected_marker" = "$marker" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry marker filename mismatch"
        continue
      }
      selector=$(fm_meta_get "$marker" selector)
      home=$(fm_meta_get "$marker" home)
      commit=$(fm_meta_get "$marker" commit)
      message=$(fm_meta_get "$marker" message)
      remote=$(fm_meta_get "$marker" remote)
      [ -n "$remote" ] || remote=0
      [ "$selector" = "fm-$id" ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker selector mismatch"
        continue
      }
      case "$remote" in
        0) [ "$message" = "$SECOND_MATE_NUDGE_MESSAGE" ] || {
          echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker message mismatch"
          continue
        } ;;
        1) [ "$message" = "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" ] || {
          echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: remote retry marker message mismatch"
          continue
        } ;;
        *)
          echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker placement is invalid"
          continue
          ;;
      esac
      [ "$remote" -ne 1 ] || continue
      meta="$STATE/$id.meta"
      [ -f "$meta" ] && [ "$(fm_meta_get "$meta" kind)" = secondmate ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry target has no live secondmate metadata"
        continue
      }
      meta_home=$(fm_meta_get "$meta" home)
      [ -n "$meta_home" ] || meta_home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home || true)
      if ! validate_secondmate_home "$id" "$meta_home"; then
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target home unsafe: $VALIDATION_ERROR"
        continue
      fi
      home_real="$VALIDATED_HOME"
      [ "$home_real" = "$home" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target home changed"
        continue
      }
      head=$(git -C "$home_real" rev-parse HEAD 2>/dev/null || true)
      [ -n "$head" ] && [ "$head" = "$commit" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target is not at recorded instruction commit"
        continue
      }
      if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$marker"
        echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
      else
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
      fi
    done
  }

  local tmp line
  secondmate_retry_pending_nudges
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_secondmate_metas "$STATE" "$primary_head" yes "$DATA/secondmates.md" >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      secondmate\ *': skipped:'*) echo "SECONDMATE_SYNC: $line" ;;
      BOOTSTRAP_INFO:\ *) echo "$line" ;;
      NUDGE_SECONDMATES:\ *) echo "$line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  unset -f fm_ff_after_instruction_update
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into every VALIDATED live secondmate home swept above.
  # FF_SEEN_HOMES is exactly that set, and fm-config-inherit-lib.sh owns the
  # declared config items plus data/captain-shared.md.
  # After a successful push that changes allowlisted config/* for an already-
  # running home, send its literal-content reread instruction pointer so the
  # live agent does not keep applying stale defaults. Spawn/respawn already
  # re-reads at launch and needs no redundant nudge unless files changed after launch.
  local id home home_real home_lock propagated_homes report reread_out reread_skip_pending
  propagated_homes=""
  SECONDMATE_RESPAWNED_IDS=${SECONDMATE_RESPAWNED_IDS:-}
  while IFS='|' read -r id home _window _meta; do
    validate_secondmate_home "$id" "$home" || continue
    home_real="$VALIDATED_HOME"
    case " $FF_SEEN_HOMES " in
      *" $home_real "*) ;;
      *) continue ;;
    esac
    case " $propagated_homes " in
      *" $home_real "*) continue ;;
    esac
    propagated_homes="$propagated_homes $home_real"
    mkdir -p "$home_real/state" || {
      echo "CONFIG_REREAD: secondmate $id: send failed: could not create state directory"
      continue
    }
    home_lock=$(fm_config_inherit_lock_path "$home_real") || {
      echo "CONFIG_REREAD: secondmate $id: send failed: could not resolve per-home lock"
      continue
    }
    fm_lock_acquire_wait "$home_lock" || {
      echo "CONFIG_REREAD: secondmate $id: send failed: could not acquire per-home lock"
      continue
    }
    reread_skip_pending=0
    case " $SECONDMATE_RESPAWNED_IDS " in
      *" $id "*) reread_skip_pending=1 ;;
    esac
    if [ "$reread_skip_pending" -eq 0 ] \
      && fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
      fm_config_reread_retry_pending "$id" "$home_real" || true
      if fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
        echo "CONFIG_REREAD: secondmate $id: send failed: retry instruction queue is full"
        fm_lock_release "$home_lock" || true
        continue
      fi
    fi
    report=$(mktemp "${TMPDIR:-/tmp}/fm-bootstrap-inherit.XXXXXX" 2>/dev/null) || {
      echo "SECONDMATE_SYNC: secondmate $id: skipped: inheritance failed"
      fm_lock_release "$home_lock" || true
      continue
    }
    if FM_CONFIG_INHERIT_REPORT="$report" FM_CONFIG_INHERIT_LIVE=1 \
      propagate_secondmate_inheritance "$FM_HOME" "$home_real" "$CONFIG" "$DATA"; then
      :
    else
      echo "SECONDMATE_SYNC: secondmate $id: skipped: inheritance failed"
    fi
    if ! reread_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_CONFIG_REREAD_SKIP_PENDING="$reread_skip_pending" \
      fm_config_send_reread_nudge "$id" "$home_real" "$report" 2>&1); then
      if [ -n "$reread_out" ]; then
        printf '%s\n' "$reread_out"
      else
        echo "CONFIG_REREAD: secondmate $id: send failed: unknown error"
      fi
    elif [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    fi
    rm -f "$report"
    fm_lock_release "$home_lock" || true
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")

  # One remote secondmate's convergence, split out of the loop so each host is
  # individually timed; every `return` here was a `continue` and still means
  # "move on to the next secondmate".
  secondmate_sync_remote_one() {  # <id> <home> <remote-host>
    local id=$1 _home=$2 remote_host=$3
    local sync_out inherit_out nudge_needed remote_marker remote_pending converged out remote_lock remote_generation
    remote_lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_lock" ] || ! fm_lock_acquire_wait "$remote_lock"; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot lock remote inheritance transaction"
      return 0
    fi
    if ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm "$id" >/dev/null 2>&1; then
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote reply source could not be registered"
    fi
    remote_generation=$(fm_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_generation" ]; then
      echo "SECONDMATE_SYNC: secondmate $id: skipped: remote inheritance generation could not be published"
      fm_lock_release "$remote_lock" || true
      return 0
    fi
    remote_marker=$(secondmate_nudge_marker_path "$id" 2>/dev/null || true)
    remote_pending=0
    if [ -f "$remote_marker" ] && [ "$(fm_meta_get "$remote_marker" remote)" = 1 ]; then remote_pending=1; fi
    if ! secondmate_write_nudge_marker "$id" "$_home" "" remote \
      "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" 1; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot record remote retry marker"
      fm_lock_release "$remote_lock" || true
      return 0
    fi
    nudge_needed=0
    converged=1
    if sync_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh sync "$id" < /dev/null 2>&1); then
      case "$sync_out" in synced:*) nudge_needed=1 ;; esac
    else
      echo "SECONDMATE_SYNC: secondmate $id: skipped: remote tracked-file sync failed on $remote_host: $(first_line "$sync_out")"
      converged=0
    fi
    if inherit_out=$(FM_CONFIG_INHERIT_LIVE=1 \
      "$SCRIPT_DIR/fm-remote-inherit-push.sh" "$id" "$remote_generation" 2>&1); then
      if printf '%s\n' "$inherit_out" | grep -Eq '^(pushed|removed):'; then nudge_needed=1; fi
    else
      echo "SECONDMATE_SYNC: secondmate $id: skipped: remote inheritance failed on $remote_host: $(first_line "$inherit_out")"
      converged=0
    fi
    [ "$remote_pending" -eq 0 ] || nudge_needed=1
    if [ "$converged" -eq 1 ] && [ "$nudge_needed" -eq 1 ]; then
      if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-send.sh" "fm-$id" "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$remote_marker"
        [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] || echo "BOOTSTRAP_INFO: nudged remote fm-$id after convergence"
      else
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: $(first_line "$out")"
      fi
    elif [ "$converged" -eq 1 ]; then
      rm -f "$remote_marker"
    fi
    fm_lock_release "$remote_lock" || true
    return 0
  }

  # Remote routes converge through the generic transport. Their code root and
  # inherited files are authoritative on that host; no local path probe or
  # local fast-forward is attempted for them.
  local remote_host __fm_timing_stamp
  while IFS='|' read -r id _home _window meta; do
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ -n "$remote_host" ] || continue
    __fm_timing_stamp=$(fm_timing_now_ms)
    secondmate_sync_remote_one "$id" "$_home" "$remote_host"
    fm_timing_record secondmate convergence "$__fm_timing_stamp" "$id@$remote_host"
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
  return 0
}

# A relaunch replaces the endpoint record a digest may already have printed. On
# the local pass that digest has not been composed yet, so the fact stays behind
# FM_BOOTSTRAP_VERBOSE_FACTS as before; on the deferred network pass the digest
# is already out, so reporting it is what keeps the superseded record from being
# acted on.
report_relaunch() {  # <id> <cause> <where>
  [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] || ! local_phase || return 0
  echo "BOOTSTRAP_INFO: secondmate $1 relaunched after $2 ($3)"
}

secondmate_liveness_sweep() {
  # Idempotent secondmate liveness guarantee - SESSION START ONLY. The detailed
  # state machine and its only recovery-authorizing states are owned by
  # fm_backend_agent_state. A missing tmux pane is not enough: tmux must prove
  # the window or session absent. This preserves duplicate prevention for
  # existing ambiguous processes and every transiently unreadable target while
  # adding the missing-session path the original bare-shell and Herdr-husk sweep
  # lacked.
  # A meta with no window remains owned by secondmate-provisioning recovery.
  # Secondmate homes never contain kind=secondmate meta, so this is naturally a
  # primary-only no-op there. Mid-session liveness remains explicitly out of
  # scope and requires a separate periodic signal.
  [ -d "$STATE" ] || return 0
  local meta id remote_host label __fm_timing_stamp
  SECONDMATE_RESPAWNED_IDS=""
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    # Identity for the timing record is read here, in the loop, so the per-meta
    # body below keeps its single-exit-per-outcome shape.
    id=$(basename "$meta" .meta)
    remote_host=$(fm_meta_get "$meta" remote_host)
    label=$id
    [ -z "$remote_host" ] || label="$id@$remote_host"
    __fm_timing_stamp=$(fm_timing_now_ms)
    secondmate_liveness_one "$meta" "$id"
    fm_timing_record secondmate liveness "$__fm_timing_stamp" "$label"
  done
  return 0
}

# One secondmate's liveness check. Split out of the sweep so each is individually
# timed; every `return` here was a `continue` in the loop and means exactly the
# same thing - move on to the next secondmate. SECONDMATE_RESPAWNED_IDS stays a
# global that this appends to, so the sweep's hand-off to secondmate_sync is
# unchanged.
secondmate_liveness_one() {  # <meta> <id>
  local meta=$1 id=$2
  local window harness backend target agent_state out cause remote_host remote_rc readiness_reason route_out remote_backend
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || return 0
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    remote_rc=0
    fm_remote_readiness_ensure "$SCRIPT_DIR" "$id" || remote_rc=$?
    if [ "$remote_rc" -eq 255 ]; then
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
      return 0
    fi
    if [ "$remote_rc" -ne 0 ]; then
      readiness_reason=$(printf '%s\n' "$FM_REMOTE_READINESS_OUT" \
        | awk '/^check [^=]+=(fixable|human):|^action:|^error:/ { print; exit }')
      [ -n "$readiness_reason" ] || readiness_reason=$(first_line "$FM_REMOTE_READINESS_OUT")
      [ -n "$readiness_reason" ] || readiness_reason="unknown readiness failure"
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote readiness failed on $remote_host: $readiness_reason"
      return 0
    fi
    if out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
      remote_rc=0
    else
      remote_rc=$?
    fi
    if [ "$remote_rc" -eq 255 ]; then
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
      return 0
    fi
    if [ "$remote_rc" -ne 0 ]; then
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote endpoint probe unreadable on $remote_host"
      return 0
    fi
    agent_state=$(printf '%s\n' "$out" | tail -1)
    case "$agent_state" in
      alive)
        if route_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh route "$id" < /dev/null 2>/dev/null); then
          remote_rc=0
        else
          remote_rc=$?
        fi
        if [ "$remote_rc" -eq 255 ]; then
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote host unavailable or endpoint route unknown; route preserved on $remote_host"
          return 0
        fi
        if [ "$remote_rc" -ne 0 ]; then
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: alive remote endpoint route is unreadable on $remote_host; inspect and migrate or retire it explicitly"
          return 0
        fi
        remote_backend=$(printf '%s\n' "$route_out" | sed -n 's/^backend=//p' | tail -1)
        if [ "$remote_backend" != herdr ]; then
          echo "SECONDMATE_LIVENESS: secondmate $id: skipped: alive remote endpoint is recorded on backend '${remote_backend:-missing}'; migrate or retire it explicitly"
          return 0
        fi
        [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] || echo "BOOTSTRAP_INFO: remote secondmate $id already live (host=$remote_host)"
        ;;
      dead|missing)
        cause="remote endpoint $agent_state on its configured host"
        if out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1); then
          SECONDMATE_RESPAWNED_IDS="$SECONDMATE_RESPAWNED_IDS $id"
          report_relaunch "$id" "$cause" "host=$remote_host"
        else
          echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed after $cause: $(first_line "$out")"
        fi
        ;;
      ambiguous|unreadable|unverified)
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote endpoint state is $agent_state on $remote_host"
        ;;
      *) echo "SECONDMATE_LIVENESS: secondmate $id: skipped: remote endpoint returned an invalid state" ;;
    esac
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target="$window"
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi) ;;
    *)
      case "$agent_state" in dead|missing) agent_state=unverified-harness ;; esac
      ;;
  esac
  case "$agent_state" in
    alive)
      if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
        echo "BOOTSTRAP_INFO: secondmate $id already live (backend=$backend)"
      fi
      ;;
    dead|missing)
      if [ "$agent_state" = dead ]; then
        cause="confirmed agent absence on existing endpoint"
        fm_backend_kill "$backend" "$target" 2>/dev/null || true
      else
        cause="recorded endpoint confidently missing"
      fi
      if out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1); then
        SECONDMATE_RESPAWNED_IDS="$SECONDMATE_RESPAWNED_IDS $id"
        report_relaunch "$id" "$cause" "backend=$backend"
      else
        echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed after $cause: $(first_line "$out")"
      fi
      ;;
    ambiguous)
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: existing endpoint has ambiguous agent process (backend=$backend)"
      ;;
    unreadable)
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: endpoint probe unreadable (backend=$backend)"
      ;;
    unverified-harness)
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: recorded harness '$harness' is unverified for recovery (backend=$backend)"
      ;;
    *)
      echo "SECONDMATE_LIVENESS: secondmate $id: skipped: agent recovery classifier unverified (backend=$backend)"
      ;;
  esac
  return 0
}

secondmate_handoff_resume() {
  [ -d "$DATA/handoff" ] || return 0
  "$SCRIPT_DIR/fm-backlog-handoff.sh" --resume-pending >/dev/null 2>&1 || true
}

secondmate_handoff_detect() {
  local outbox id count
  [ -d "$DATA/handoff" ] || return 0
  for outbox in "$DATA/handoff"/*.outbox.md; do
    [ -e "$outbox" ] || continue
    id=$(basename "$outbox" .outbox.md)
    case "$id" in ''|*[!A-Za-z0-9._-]*) id=unknown ;; esac
    if [ ! -f "$outbox" ] || [ -L "$outbox" ]; then
      echo "SECONDMATE_HANDOFF: secondmate $id: pending delivery: unsafe outbox"
      continue
    fi
    count=$(awk '/^- \[[ x]\] / { count++ } END { print count + 0 }' "$outbox" 2>/dev/null || printf unknown)
    echo "SECONDMATE_HANDOFF: secondmate $id: pending delivery: $count item(s)"
  done
}

install_cmd() {
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    cursor-agent) echo "https://cursor.com/cli" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# fm_backend_required_tools (bin/fm-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops treehouse. A backend value with
# no verified dependency set is reported before the universal checks continue.
# jq is universal because the read-only fleet snapshot, the crew-dispatch
# profile reader, and the durable outcome manifest teardown publishes all parse
# and emit JSON through it; without jq a home cannot archive a finished task.
COMMON_TOOLS="node git gh jq no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
BACKEND=$(fm_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
NO_MISTAKES_MIN=1.31.2
# AXI-FAMILY FLOOR POLICY. Every axi-family floor is the CURRENT LATEST published
# version of that tool, captain-bumped periodically to keep the whole fleet on the
# newest axi tools. It is NOT the minimum feature-introduced version. These floors
# are expected to drift upward as new versions ship. Never lower a floor to the
# earliest release that happens to satisfy some depended-on behavior. The
# tasks-axi feature probes are an independent defense-in-depth concern, not part
# of its floor.
GH_AXI_MIN=0.1.34
LAVISH_AXI_MIN=0.1.62
CHROME_DEVTOOLS_AXI_MIN=0.1.30

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

# Shared semantic-version floor for the tool gates below. A version string that
# cannot be parsed into exactly one major.minor.patch triple is incompatible,
# never assumed current, so a development or vendored build cannot pass a floor
# it was never checked against.
tool_version_at_least() {  # <tool> <min-version>
  local tool=$1 min=$2 output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v "$tool" >/dev/null 2>&1 || return 1
  output=$("$tool" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

x_mode_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp parent_device current_mode
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$parent_device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current_mode=$(stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current_mode=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current_mode" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-x-mode.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" "$mode" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fmx_single_link_file_valid "$dest" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fmx_single_link_file_mode_valid "$dest" "$mode" "$parent_device" \
    || ! cmp -s "$dest" <(printf '%s\n' "$content"); then
    rm -f -- "$dest"
    return 1
  fi
}

x_mode_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

x_mode_remove_artifact() {
  local artifact=$1 parent=${1%/*}
  x_mode_artifact_present "$artifact" || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$artifact" 2>/dev/null || return 1
  ! x_mode_artifact_present "$artifact"
}

# X mode (opt-in): when this home's .env carries a non-empty FMX_PAIRING_TOKEN,
# wire the relay poll into the existing authenticated watcher dispatch.
# Drops two idempotent, gitignored artifacts:
#   state/x-watch.check.sh - byte-static identity shim; the watcher validates
#                            its bytes and invokes bin/fm-x-poll.sh directly
#   config/x-mode.env      - exports FM_CHECK_INTERVAL=30, sourced by the watcher
#                            arm so only an X instance polls at the 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the instance
# reverts to the default 300s no-poll behavior. Absent a token AND with no leftover
# artifacts it is a complete no-op (nothing written, nothing printed), so a non-X
# user sees zero change. Prints one confirmation line on opt-in, and one on opt-out
# only when it actually removed artifacts. It never touches the watcher itself;
# applying a cadence transition to a running watcher is the caller's job via
# the emitted harness-aware supervision repair instruction.
x_mode_setup() {
  local env_file token shim cadence shim_body cadence_body tool missing shim_home
  env_file="$FM_HOME/.env"
  shim="$STATE/x-watch.check.sh"
  cadence="$CONFIG/x-mode.env"

  token=
  [ -f "$env_file" ] && token=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")

  x_mode_remove_artifacts() {
    local failed=0
    x_mode_remove_artifact "$shim" || failed=1
    x_mode_remove_artifact "$cadence" || failed=1
    [ "$failed" -eq 0 ]
  }

  x_mode_supervision_repair() {
    local out
    out=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --repair-line 2>/dev/null) \
      || out='repair missing watcher supervision according to the session-start operating block.'
    printf '%s\n' "$out"
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - removed relay poll shim and 30s cadence; default cadence applies on the next supervision cycle; $(x_mode_supervision_repair)"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence"
      fi
    fi
    return 0
  fi

  missing=0
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (install: $(install_cmd "$tool"))"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - missing relay poll dependencies; install them and rerun bootstrap"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies"
      fi
    fi
    return 0
  fi

  fmx_arm_failed() {
    if x_mode_remove_artifacts; then
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence"
    else
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain"
    fi
  }

  mkdir -p "$STATE" "$CONFIG" 2>/dev/null || { fmx_arm_failed; return 0; }

  case "$FM_HOME" in
    /*) shim_home=$FM_HOME ;;
    *)
      shim_home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) \
        || { fmx_arm_failed; return 0; }
      ;;
  esac
  shim_body=$(fmx_poll_shim_content "$shim_home" "$FM_ROOT")
  x_mode_write_if_changed "$shim" "$shim_body" 700 || { fmx_arm_failed; return 0; }
  fmx_poll_shim_valid "$shim" "$shim_home" "$FM_ROOT" \
    || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by fm-bootstrap.sh - X mode watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh polls the X check every 30s. Non-X instances have no such file and
# keep the default 300s cadence.
export FM_CHECK_INTERVAL=30
EOF
)
  x_mode_write_if_changed "$cadence" "$cadence_body" 600 || { fmx_arm_failed; return 0; }

  echo "FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env"
}

crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","pi-signed","grok","kimi","cursor","muse","agy"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "agy" then (["low","medium","high"] | index($e))
      elif $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  # Backend-context check (S2): agy is crew-only, HERDR-only. A dispatch profile
  # that selects it is valid JSON, but every matching task will be refused at
  # spawn when the resolved backend is not herdr. Diagnose it here rather than
  # deferring the surprise to task intake. $BACKEND is the already-resolved
  # runtime backend (fm_backend_name, above). cursor is deliberately excluded:
  # it is an ordinary verified harness on every spawn backend.
  if [ "$BACKEND" != herdr ]; then
    local restricted
    restricted=$(jq -r '
      def profiles($value):
        if ($value | type) == "array" then $value
        elif ($value | type) == "object" then [$value]
        else [] end;
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end))
      | map(.harness?) | map(select(. == "agy")) | unique | join(", ")
    ' "$file" 2>/dev/null || true)
    if [ -n "$restricted" ]; then
      echo "CREW_DISPATCH: backend mismatch - config/crew-dispatch.json selects crew-only herdr-only harness(es) ($restricted) but the resolved backend is '$BACKEND'; those tasks will be refused at spawn. Select the herdr backend (config/backend) or drop agy from the dispatch rules."
      return 0
    fi
  fi
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

startup_memory_budget_setup() {
  # Primary bootstrap owns default publication. A secondmate is deliberately
  # passive here because its setting must converge from the primary through the
  # inherited-local-material contract rather than becoming a local authority.
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    return 0
  fi
  if ! fm_startup_memory_budget_materialize "$CONFIG"; then
    echo "STARTUP_MEMORY_BUDGET: invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
  fi
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. It pauses an
# identity-matched watcher, holds its lock, and neutralizes legacy PR checks
# before any tool detection or later bootstrap mutation can leave old artifacts
# runnable. Detect-only sessions never touch state, and the deferred network pass
# never repeats it: the local pass that ran first already closed that window.
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ] && local_phase; then
  "$SCRIPT_DIR/fm-pr-check-migrate.sh" || true
  # Endpoint-binding migration: converge legacy non-tmux task records that
  # predate `endpoint_task_id=` so they stay cleanable. It only ever adds a
  # binding it verified live, so it is safe to re-run every locked session and
  # is silent once no record needs one.
  "$SCRIPT_DIR/fm-endpoint-binding-migrate.sh" || true
  "$SCRIPT_DIR/fm-run-attribution-legacy-transition.sh" || true
  startup_memory_budget_setup
else
  "$SCRIPT_DIR/fm-run-attribution-legacy-transition.sh" --detect-only || true
fi

# Local detection: presence, version floors, and configuration. Nothing here
# leaves this machine, so it stays on the session-start critical path.
detect_local_tools() {
  if [ "$BACKEND_VALID" -eq 0 ]; then
    echo "BACKEND_INVALID: $BACKEND (known: $FM_BACKEND_KNOWN)"
  fi
  for t in $BACKEND_TOOLS; do
    fm_backend_required_tool_available "$BACKEND" "$t" \
      || missing_tool_diagnostic "$t"
  done
  for t in $COMMON_TOOLS; do
    command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
  done
  # The treehouse lease-support upgrade check is only relevant when the resolved
  # backend actually requires treehouse (every backend except orca, which owns its
  # own worktrees); an orca home must not be told to upgrade a provider it never uses.
  if fm_backend_list_contains "$TOOLS" treehouse \
    && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
    echo "MISSING: treehouse (install: $(install_cmd treehouse))"
  fi
  if command -v no-mistakes >/dev/null 2>&1 && ! tool_version_at_least no-mistakes "$NO_MISTAKES_MIN"; then
    echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
  fi
  if command -v gh-axi >/dev/null 2>&1 && ! tool_version_at_least gh-axi "$GH_AXI_MIN"; then
    echo "MISSING: gh-axi (install: $(install_cmd gh-axi))"
  fi
  if command -v chrome-devtools-axi >/dev/null 2>&1 && ! tool_version_at_least chrome-devtools-axi "$CHROME_DEVTOOLS_AXI_MIN"; then
    echo "MISSING: chrome-devtools-axi (install: $(install_cmd chrome-devtools-axi))"
  fi
  if command -v lavish-axi >/dev/null 2>&1 && ! tool_version_at_least lavish-axi "$LAVISH_AXI_MIN"; then
    echo "MISSING: lavish-axi (install: $(install_cmd lavish-axi))"
  fi
  if command -v quota-axi >/dev/null 2>&1 && ! fm_quota_axi_compatible; then
    echo "MISSING: quota-axi (install: $(install_cmd quota-axi))"
  fi
  if command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
    echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
  fi
}

detect_local_config() {
  # Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
  # default branch, not a feature branch (see fm-tangle-lib.sh). Scoped to the
  # primary only; detached-HEAD worktrees and secondmate homes never trip it.
  tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
  if [ -n "$tangle_branch" ]; then
    tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
    if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && [ "${FM_BOOTSTRAP_LOCKED:-0}" != 1 ]; then
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
    else
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
    fi
  fi
  crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
    echo "BOOTSTRAP_INFO: crew harness override active: $crew"
  fi
  # A configured cursor crew harness needs a cursor executable present, and
  # cursor ships under EITHER installed name. Resolution runs through the
  # verified owner rather than a bare `command -v`, so a home that merely has
  # some unrelated executable named `agent` on PATH is still reported missing
  # instead of failing at the first spawn.
  if [ "$crew" = cursor ] && ! fm_cursor_resolve_binary >/dev/null 2>&1; then
    echo "MISSING_MANUAL: cursor-agent (instructions: $(manual_install_url cursor-agent))"
  fi
  crew_dispatch_validate
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
    && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
    echo "BOOTSTRAP_INFO: tasks-axi available"
  fi
}

# The order below is the order the diagnostics have always printed in, so a
# `skip` run is the same output with the network lines removed rather than a
# reshuffle. `gh auth status` sits between the two local blocks because that is
# where it has always been.
# Each network owner below is bracketed by an elapsed-time record, so a deferred
# stage that ran long can be attributed to the phase that spent the time.
# fm-timing-lib.sh discards the record unless the caller asked for timings, and
# every sweep is still called directly and in the same order, so nothing about
# what runs, in what sequence, or what it returns changes.
# The stamp variable is named for the library rather than `start` on purpose:
# fleet_sync and others assign plain names like `start` without `local`, and
# bash's dynamic scoping would let them overwrite a stamp held by a caller.
local_phase && detect_local_tools
if network_phase; then
  __fm_timing_stamp=$(fm_timing_now_ms)
  gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
  fm_timing_record phase gh-auth "$__fm_timing_stamp"
fi
local_phase && detect_local_config

if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  # secondmate_sync consumes SECONDMATE_RESPAWNED_IDS from the liveness sweep, so
  # those two always run together in the same phase.
  if network_phase; then
    if network_sweep_authorized 'dead-secondmate relaunch'; then
      __fm_timing_stamp=$(fm_timing_now_ms)
      secondmate_liveness_sweep
      fm_timing_record phase secondmate-liveness "$__fm_timing_stamp"
    fi
    if network_sweep_authorized 'secondmate convergence'; then
      __fm_timing_stamp=$(fm_timing_now_ms)
      secondmate_sync
      fm_timing_record phase secondmate-sync "$__fm_timing_stamp"
    fi
    if network_sweep_authorized 'pending handoff delivery'; then
      __fm_timing_stamp=$(fm_timing_now_ms)
      secondmate_handoff_resume
      fm_timing_record phase handoff-delivery "$__fm_timing_stamp"
    fi
  fi
  # x_mode_setup writes local Relay artifacts only and never leaves the machine.
  local_phase && x_mode_setup
  if network_phase && network_sweep_authorized 'project clone refresh'; then
    __fm_timing_stamp=$(fm_timing_now_ms)
    fleet_sync
    fm_timing_record phase fleet-sync "$__fm_timing_stamp"
  fi
  if network_phase && network_sweep_authorized 'project board reconciliation'; then
    __fm_timing_stamp=$(fm_timing_now_ms)
    board_sweep
    fm_timing_record phase board-sweep "$__fm_timing_stamp"
  fi
fi
# Fork-upstream drift can fetch into a disposable repository, so the deferred
# network phase owns it and the local session-start digest remains network-free.
network_phase && upstream_status_check
# Documentation-vault drift is local-only. Detect-only runs inspect the current
# clones immediately; normal runs inspect them after the deferred fleet refresh.
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
  local_phase && vault_drift_check
elif network_phase; then
  vault_drift_check
fi
# The GBrain serving boundary, the recorded-pin drift check, and the usage-store
# refresh are home-local checks.
local_phase && gbrain_serving_credential_check
local_phase && gbrain_pin_drift_check
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  local_phase && gbrain_capture_sweep
  local_phase && usage_store_refresh
fi
local_phase && secondmate_handoff_detect
exit 0
