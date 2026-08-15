#!/usr/bin/env bash
# Behavior tests that a remote job worker leaves no orphaned processes after a
# run, including a deliberately failed shutdown.
#
# What would have to break in the real world for these assertions to go red:
# a TERM delivered to the serving worker (or its isolated process group) while
# ownership cannot be quarantined - the failed-run residue, when teardown has
# already removed the lock or state - would leave that process group alive.
# The serving loop would keep polling, and the Linux restart supervisor would
# stay waiting on it or spawn a replacement. That is the leak that accumulates
# CPU and starves a neighbouring shard.
#
# These cases exercise the production worker through its public start and TERM
# interface. They do not read the worker's source, and they do not rely on the
# test-side process-group KILL in tests/fm-remote-job.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-worker-leak)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

TRACKED_GROUPS=()

group_members() { # <pgid>
  local pgid=$1
  ps -eo pid=,pgid=,ppid=,args= | awk -v g="$pgid" '$2 == g { print }'
}

group_alive() { # <pgid>
  kill -0 -- "-$1" 2>/dev/null
}

wait_group_gone() { # <pgid> <seconds>
  local pgid=$1 deadline=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    group_alive "$pgid" || return 0
    sleep 0.1
  done
  ! group_alive "$pgid"
}

kill_tracked_groups() {
  local pgid pid
  for pgid in "${TRACKED_GROUPS[@]:-}"; do
    [ -n "$pgid" ] || continue
    while read -r pid rest; do
      [ -n "${pid:-}" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
    done < <(group_members "$pgid")
    kill -KILL -- "-$pgid" 2>/dev/null || true
  done
}

leak_cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  kill_tracked_groups
  fm_test_cleanup
  return "$status"
}
trap leak_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

track_group() { # <pgid>
  local pgid=$1 tracked
  case "$pgid" in ''|*[!0-9]*) return 1 ;; esac
  for tracked in "${TRACKED_GROUPS[@]:-}"; do
    [ "$tracked" != "$pgid" ] || return 0
  done
  TRACKED_GROUPS+=("$pgid")
}

assert_group_gone_after_term() { # <pgid> <label>
  local pgid=$1 label=$2 survivors
  wait_group_gone "$pgid" 5 || true
  if group_alive "$pgid"; then
    survivors=$(group_members "$pgid")
    fail "$label left orphaned processes in pgid $pgid:
$survivors"
  fi
}

build_remote_root() { # <dir>
  local root=$1
  mkdir -p "$root/bin"
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$root/bin/"
  chmod +x "$root/bin"/*.sh
  printf 'fixture\n' > "$root/AGENTS.md"
  git -C "$root" init -q -b main
  git -C "$root" config user.email test@example.com
  git -C "$root" config user.name Test
  git -C "$root" add AGENTS.md bin
  git -C "$root" commit -qm 'remote job worker leak fixture'
}

start_linux_worker() { # <dest>
  local dest=$1 pid
  set -m
  HOME="$dest/account" \
    FM_ROOT_OVERRIDE="$dest/remote-root" \
    FM_REMOTE_JOB_STATE_ROOT="$dest/remote-jobs" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_JOB_TIMEOUT=5 \
    "$dest/remote-root/bin/fm-remote-job-worker.sh" \
    > "$dest/worker.out" 2> "$dest/worker.err" &
  pid=$!
  set +m
  printf '%s\n' "$pid"
}

wait_ready() { # <dest>
  local dest=$1
  local i
  for i in $(seq 1 100); do
    [ -f "$dest/remote-jobs/worker.ready" ] && return 0
    sleep 0.05
  done
  return 1
}

prepare_case() { # <name>
  local dest="$TMP_ROOT/$1"
  mkdir -p "$dest/account" "$dest/remote-jobs"
  build_remote_root "$dest/remote-root"
  printf '%s\n' "$dest"
}

# --- idle worker, lock gone, TERM the serving child --------------------------
#
# Teardown of a failed run can unlink the lock while TERM is in flight. The
# serving process must still exit, and the Linux supervisor must not keep the
# tree alive.

CASE_IDLE=$(prepare_case idle-lock)
SUP_IDLE=$(start_linux_worker "$CASE_IDLE")
wait_ready "$CASE_IDLE" || fail "idle-lock: the worker did not become ready"
PGID_IDLE=$(fm_remote_job_process_pgid "$SUP_IDLE") ||
  fail "idle-lock: could not resolve the worker process group"
track_group "$PGID_IDLE"
SERVE_IDLE=$(cat "$CASE_IDLE/remote-jobs/worker.pid")
case "$SERVE_IDLE" in ''|*[!0-9]*) fail "idle-lock: no serving pid" ;; esac
rm -rf "$CASE_IDLE/remote-jobs/worker.lock"
kill -TERM "$SERVE_IDLE" 2>/dev/null || true
assert_group_gone_after_term "$PGID_IDLE" \
  "TERM of the serving worker after its lock directory disappeared"
pass "an idle worker leaves no orphans after a failed-quarantine TERM"

# --- idle worker, lock gone, TERM the isolated group -------------------------
#
# The same failed-run cleanup shape as signalling the whole tree, without a
# follow-up KILL. If shutdown returns instead of exiting, the group stays up.

CASE_GROUP=$(prepare_case group-lock)
SUP_GROUP=$(start_linux_worker "$CASE_GROUP")
wait_ready "$CASE_GROUP" || fail "group-lock: the worker did not become ready"
PGID_GROUP=$(fm_remote_job_process_pgid "$SUP_GROUP") ||
  fail "group-lock: could not resolve the worker process group"
track_group "$PGID_GROUP"
rm -rf "$CASE_GROUP/remote-jobs/worker.lock"
kill -TERM -- "-$PGID_GROUP" 2>/dev/null || true
assert_group_gone_after_term "$PGID_GROUP" \
  "TERM of the worker process group after its lock directory disappeared"
pass "a process-group TERM after a failed quarantine leaves no orphans"

# --- idle worker, entire state root gone, TERM the serving child -------------
#
# Heartbeat failure after a returned shutdown used to look like a crash, so the
# supervisor restarted a replacement. A failed run that already removed state
# must still end the tree.

CASE_STATE=$(prepare_case state-gone)
SUP_STATE=$(start_linux_worker "$CASE_STATE")
wait_ready "$CASE_STATE" || fail "state-gone: the worker did not become ready"
PGID_STATE=$(fm_remote_job_process_pgid "$SUP_STATE") ||
  fail "state-gone: could not resolve the worker process group"
track_group "$PGID_STATE"
SERVE_STATE=$(cat "$CASE_STATE/remote-jobs/worker.pid")
case "$SERVE_STATE" in ''|*[!0-9]*) fail "state-gone: no serving pid" ;; esac
rm -rf "$CASE_STATE/remote-jobs"
kill -TERM "$SERVE_STATE" 2>/dev/null || true
assert_group_gone_after_term "$PGID_STATE" \
  "TERM of the serving worker after its state root disappeared"
pass "removing the state root and TERMing the serving worker leaves no orphans"

# --- failed run with an active job: lock gone, then TERM ---------------------
#
# Five to six orphans survived a failed run on the original host; this case is
# that residue: a live command tree plus the supervisor and serving loop, TERM
# after the lock is already gone, no KILL.

CASE_FAIL=$(prepare_case failed-run)
cat > "$CASE_FAIL/remote-root/bin/fm-hang-job.sh" <<'SH'
#!/bin/bash
trap '' HUP INT TERM
printf 'started\n' > "$1"
sleep 30
printf 'done\n' > "$2"
SH
chmod +x "$CASE_FAIL/remote-root/bin/fm-hang-job.sh"
git -C "$CASE_FAIL/remote-root" add bin/fm-hang-job.sh
git -C "$CASE_FAIL/remote-root" commit -qm 'hang job'
SUP_FAIL=$(start_linux_worker "$CASE_FAIL")
wait_ready "$CASE_FAIL" || fail "failed-run: the worker did not become ready"
PGID_FAIL=$(fm_remote_job_process_pgid "$SUP_FAIL") ||
  fail "failed-run: could not resolve the worker process group"
track_group "$PGID_FAIL"
FM_REMOTE_JOB_STATE_ROOT="$CASE_FAIL/remote-jobs"
FM_REMOTE_JOB_TIMEOUT=30
export FM_REMOTE_JOB_STATE_ROOT FM_REMOTE_JOB_TIMEOUT
fm_remote_job_stage "$CASE_FAIL/account" "$CASE_FAIL/remote-root" "$CASE_FAIL/account" \
  fm-hang-job.sh "$CASE_FAIL/started" "$CASE_FAIL/done" </dev/null >/dev/null
for _ in $(seq 1 100); do
  [ -f "$CASE_FAIL/started" ] && break
  sleep 0.05
done
[ -f "$CASE_FAIL/started" ] || fail "failed-run: the hang job never started"
SERVE_FAIL=$(cat "$CASE_FAIL/remote-jobs/worker.pid")
case "$SERVE_FAIL" in ''|*[!0-9]*) fail "failed-run: no serving pid" ;; esac
rm -rf "$CASE_FAIL/remote-jobs/worker.lock"
kill -TERM "$SERVE_FAIL" 2>/dev/null || true
assert_group_gone_after_term "$PGID_FAIL" \
  "a deliberately failed run (active job, lock gone, TERM, no KILL)"
pass "a failed run with an active job leaves no orphaned processes"

printf '\nall fm-remote-job-worker-leak tests passed\n'
