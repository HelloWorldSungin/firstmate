#!/usr/bin/env bash
# Shared functions for independently owned real-Herdr presentation fixtures.
# Each entrypoint calls setup and seed functions in its own process, creating
# fresh source/home/lab/evidence state and installing cleanup before provision.
# No fixture state or pool slot is transferred between entrypoints.

fail() { FIXTURE_FAILED=1; printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

presentation_exit() {
  local fixture_exit=$?
  [ "$fixture_exit" -eq 0 ] || FIXTURE_FAILED=1
  cleanup_all
}

presentation_fixture_setup() {
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

  command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
  command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
  [ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

  REAL_HERDR=$(command -v herdr)
  REAL_TREEHOUSE=$(command -v treehouse)
  HERDR_ORIGINAL_PATH=$PATH
  TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-presentation.XXXXXX")
  EVIDENCE_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-presentation-evidence.XXXXXX")
  printf 'presentation evidence: %s; source root: %s\n' "$EVIDENCE_ROOT" "$TMP_ROOT"
  FAKEBIN="$TMP_ROOT/fakebin"
  HERDR_CALL_LOG="$EVIDENCE_ROOT/herdr-calls.log"
  TREEHOUSE_CALL_LOG="$EVIDENCE_ROOT/treehouse-calls.log"
  MOVE_CALL_LOG="$EVIDENCE_ROOT/workspace-move-calls.log"
  FOCUS_AUDIT_LOG="$EVIDENCE_ROOT/focus-audit.log"
  ACTIVE_SEEDED_CONTROL="$TMP_ROOT/active-seeded-control"
  POST_CREATE_ABORT_CONTROL="$TMP_ROOT/post-create-abort-control"
  mkdir -p "$FAKEBIN"
  : > "$HERDR_CALL_LOG"
  : > "$TREEHOUSE_CALL_LOG"
  : > "$MOVE_CALL_LOG"
  : > "$FOCUS_AUDIT_LOG"
  REAL_MOVER="$ROOT/bin/backends/herdr-workspace-move.py"
  export REAL_HERDR REAL_TREEHOUSE REAL_MOVER HERDR_CALL_LOG TREEHOUSE_CALL_LOG MOVE_CALL_LOG FOCUS_AUDIT_LOG HERDR_ORIGINAL_PATH HERDR_LAB_HELPER
  export ACTIVE_SEEDED_CONTROL POST_CREATE_ABORT_CONTROL TMP_ROOT

  # Log every production-adapter call, remove its already-validated trailing
  # session flag, and send the operation through the lab helper so that helper
  # remains the sole process which appends the real trailing session flag.
  # The adapter's deliberately session-independent version read cannot pass the
  # helper's leading-option guard, so the wrapper sends only that read straight
  # to the absolute real binary with the same explicit trailing lab session.
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$HERDR_CALL_LOG"
args=("$@")
last_index=$((${#args[@]} - 1))
flag_index=$((last_index - 1))
if [ "${#args[@]}" -ge 2 ] \
   && [ "${args[$flag_index]}" = --session ] \
   && [ "${args[$last_index]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last_index]" "args[$flag_index]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in
    --session|--session=*)
      echo "test wrapper: unexpected caller-supplied session flag" >&2
      exit 1
      ;;
  esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}

arg_value() {
  local want=$1 previous= arg
  shift
  for arg in "$@"; do
    if [ "$previous" = "$want" ]; then
      printf '%s' "$arg"
      return 0
    fi
    previous=$arg
  done
  return 1
}

label=$(arg_value --label "$@" || true)
if [ "${1:-} ${2:-}" = "workspace list" ] && [ -d "$ACTIVE_SEEDED_CONTROL" ]; then
  stage=$(cat "$ACTIVE_SEEDED_CONTROL/stage" 2>/dev/null || true)
  if [ "$stage" = task-created ]; then
    printf '%s\n' post-task-snapshot > "$ACTIVE_SEEDED_CONTROL/stage"
  elif [ "$stage" = post-task-snapshot ]; then
    seeded_tab=$(cat "$ACTIVE_SEEDED_CONTROL/seeded-tab")
    inject_before=$(focus_snapshot || printf ambiguous/ambiguous)
    env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab focus "$seeded_tab" >/dev/null
    inject_after=$(focus_snapshot || printf ambiguous/ambiguous)
    printf 'active-seeded-inject\t%s\t%s\t%s\n' "$inject_before" "$inject_after" "$seeded_tab" >> "$FOCUS_AUDIT_LOG"
    printf '%s\n' injected > "$ACTIVE_SEEDED_CONTROL/stage"
  fi
fi

mutation=
mutation_target=${3:-}
case "${1:-} ${2:-}" in
  "workspace create") mutation=workspace-create; mutation_target=$label ;;
  "tab create") mutation=tab-create; mutation_target=$label ;;
  "pane close") mutation=pane-close ;;
  "tab focus") mutation=tab-focus ;;
esac
refusal_probe=0
if [ "${1:-} ${2:-}" = "pane get" ] && [ -d "$ACTIVE_SEEDED_CONTROL" ] \
   && [ "$(cat "$ACTIVE_SEEDED_CONTROL/stage" 2>/dev/null || true)" = injected ] \
   && [ "${3:-}" = "$(cat "$ACTIVE_SEEDED_CONTROL/seeded-pane" 2>/dev/null || true)" ]; then
  refusal_probe=1
  refusal_before=$(focus_snapshot || printf ambiguous/ambiguous)
fi
before=
[ -z "$mutation" ] || before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"); then
  status=0
else
  status=$?
fi
if [ "$status" -eq 0 ] && [ "$mutation" = workspace-create ]; then
  case "$label" in
    $'└ active-seeded · p:'*)
      mkdir -p "$ACTIVE_SEEDED_CONTROL"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" > "$ACTIVE_SEEDED_CONTROL/workspace"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.tab.tab_id')" > "$ACTIVE_SEEDED_CONTROL/seeded-tab"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$ACTIVE_SEEDED_CONTROL/seeded-pane"
      ;;
    $'└ abort-a · p:'*|$'└ abort-b · p:'*)
      task=${label#$'└ '}; task=${task%% *}
      mkdir -p "$POST_CREATE_ABORT_CONTROL/$task"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" > "$POST_CREATE_ABORT_CONTROL/$task/workspace"
      ;;
  esac
fi
if [ "$status" -eq 0 ] && [ "$mutation" = tab-create ]; then
  case "$label" in
    fm-active-seeded)
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$ACTIVE_SEEDED_CONTROL/task-pane"
      printf '%s\n' task-created > "$ACTIVE_SEEDED_CONTROL/stage"
      ;;
    fm-abort-a|fm-abort-b)
      task=${label#fm-}
      mkdir -p "$POST_CREATE_ABORT_CONTROL/$task"
      printf '%s\n' "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" > "$POST_CREATE_ABORT_CONTROL/$task/task-pane"
      ;;
  esac
fi
if [ "$status" -eq 0 ] && [ "${1:-} ${2:-}" = "pane get" ] && [ -d "$POST_CREATE_ABORT_CONTROL" ]; then
  for task_dir in "$POST_CREATE_ABORT_CONTROL"/abort-*; do
    [ -d "$task_dir" ] || continue
    [ "${3:-}" = "$(cat "$task_dir/task-pane" 2>/dev/null || true)" ] || continue
    out=$(printf '%s' "$out" | jq --arg cwd "$POST_CREATE_ABORT_CONTROL/not-a-worktree" '.result.pane.foreground_cwd = $cwd')
    break
  done
fi
if [ -n "$mutation" ]; then
  after=$(focus_snapshot || printf ambiguous/ambiguous)
  printf '%s\t%s\t%s\t%s\n' "$mutation" "$before" "$after" "$mutation_target" >> "$FOCUS_AUDIT_LOG"
fi
if [ "$refusal_probe" -eq 1 ]; then
  refusal_after=$(focus_snapshot || printf ambiguous/ambiguous)
  printf 'seeded-prune-refusal\t%s\t%s\t%s\n' "$refusal_before" "$refusal_after" "${3:-}" >> "$FOCUS_AUDIT_LOG"
fi
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH

  cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$TREEHOUSE_CALL_LOG"
if [ -d "$POST_CREATE_ABORT_CONTROL" ] && [ "${1:-}" = get ]; then
  exit 0
fi
exec "$REAL_TREEHOUSE" "$@"
SH

  cat > "$FAKEBIN/herdr-workspace-mover" <<'SH'
#!/usr/bin/env bash
set -u
focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$MOVE_CALL_LOG"
before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$("$REAL_MOVER" "$@"); then
  status=0
else
  status=$?
fi
after=$(focus_snapshot || printf ambiguous/ambiguous)
printf 'workspace-move\t%s\t%s\t%s\n' "$before" "$after" "$2" >> "$FOCUS_AUDIT_LOG"
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH
  chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"
  chmod +x "$FAKEBIN/herdr-workspace-mover"
  export PATH="$FAKEBIN:$PATH"
  export FM_BACKEND_HERDR_WORKSPACE_MOVER="$FAKEBIN/herdr-workspace-mover"

  # shellcheck source=tests/herdr-test-safety.sh
  . "$ROOT/tests/herdr-test-safety.sh"
  # shellcheck source=tests/cleanup-test-safety.sh
  . "$ROOT/tests/cleanup-test-safety.sh"
  # This suite runs against its own isolated lab session, so a Herdr pane
  # inherited from the terminal it was launched in must not follow spawn into it
  # as a cross-session parent identity. Every projection below is anchored on the
  # parent this suite sets up, not on the developer's own workspace.
  herdr_forget_inherited_pane

  HERDR_LAB_SESSION=$(PATH="$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" name fm-herdr-presentation-projection)
  export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_SESSION
  LAB_READY=0
  RECORDED_WORKTREES="$EVIDENCE_ROOT/worktrees"
  : > "$RECORDED_WORKTREES"
  FIXTURE_FAILED=0
  PRESENTATION_CLEANUP_DONE=0
  PRESENTATION_CLEANUP_STATUS=1
  LOCK_CONTENTION_OWNER_PID=
  # shellcheck source=tests/herdr-presentation-cleanup.sh
  . "$ROOT/tests/herdr-presentation-cleanup.sh"
  trap presentation_exit EXIT

  PATH="$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
    || fail "could not provision the isolated Herdr lab"
  LAB_READY=1

}

lab() {
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

focus_snapshot() {
  local list row workspace tab tabs
  list=$(lab workspace list) || fail "could not read the active workspace for focus instrumentation"
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || fail "could not parse the active workspace and tab"
  [ -n "$row" ] || fail "focus instrumentation found an ambiguous active workspace"
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(lab tab list --workspace "$workspace") || fail "could not verify the active tab"
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || fail "workspace active_tab_id disagreed with the focused tab"
  printf '%s/%s' "$workspace" "$tab"
}

assert_focus_is() {  # <expected> <case-name>
  local expected=$1 case_name=$2 actual
  actual=$(focus_snapshot)
  [ "$actual" = "$expected" ] || fail "$case_name changed active workspace/tab from $expected to $actual"
}

focus_audit_line_count() { wc -l < "$FOCUS_AUDIT_LOG" | tr -d '[:space:]'; }

assert_raw_presentation_mutations_preserved_since() {  # <line-count> <case-name>
  local start=$1 case_name=$2 changed
  changed=$(sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' '
    ($1 == "workspace-create" || $1 == "tab-create" || $1 == "workspace-move" || $1 == "pane-close") && $2 != $3 {
      print $0
    }
  ')
  [ -z "$changed" ] || fail "$case_name changed active workspace/tab inside a create, move, or seeded cleanup: $changed"
}

remember_meta_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" | cut -d= -f2-)
  [ -n "$wt" ] || fail "metadata did not record a worktree"
  grep -Fxq -- "$wt" "$RECORDED_WORKTREES" || printf '%s\n' "$wt" >> "$RECORDED_WORKTREES"
  printf '%s' "$wt"
}

make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# Herdr projection E2E fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

write_ship_brief() {  # <home> <id> [description]
  local home=$1 id=$2 description=${3:-Herdr presentation fixture $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$description

## Firstmate spec
Verify projected workspace behavior for $id.
EOF
}

spawn_task() {  # <id> <home> <project>
  local id=$1 home=$2 project=$3
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}

finish_concurrent_spawn() {  # <id> <status> <stdout> <stderr> [home]
  local id=$1 status=$2 out=$3 err=$4 home=${5:-$HOME_DIR}
  [ "$status" -ne 0 ] || return 0
  if ! grep -F "task set is locked" "$err" >/dev/null 2>&1 \
     && ! grep -F "another Treehouse slot allocation or return is in progress" "$err" >/dev/null 2>&1; then
    fail "concurrent projected spawn $id failed unexpectedly: $(cat "$err")"
  fi
  cp "$err" "$err.contention"
  spawn_task "$id" "$home" "$PROJECT_DIR" > "$out" 2> "$err" \
    || fail "projected spawn $id retry failed after task-set publication completed: $(cat "$err")"
}

teardown_task() {  # <id> <home>
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force
}

log_line_count() { wc -l < "$HERDR_CALL_LOG" | tr -d '[:space:]'; }

projection_labels_from_log() {  # <start-line>
  local start=$1
  sed -n "$((start + 1)),\$p" "$HERDR_CALL_LOG" | awk -F '\t' '
    $1 == "workspace" && $2 == "create" {
      for (i = 1; i < NF; i += 1) {
        if ($i == "--label" && $(i + 1) ~ /^└ /) {
          print $(i + 1)
        }
      }
    }
  '
}

session_presentation_lock_path() {
  PATH="$FAKEBIN:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_presentation_session_lock_path "$1"
  ' "$ROOT" "$HERDR_LAB_SESSION"
}

presentation_fixture_seed_project() {  # <entrypoint-specific anchor id>
  ANCHOR_ID=$1
  HOME_DIR="$TMP_ROOT/home"
  PROJECT_DIR="$TMP_ROOT/project"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  write_ship_brief "$HOME_DIR" "$ANCHOR_ID" 'Projection anchor fixture.'
  make_project "$PROJECT_DIR"
  # Keep one ordinary primary task live so the durable firstmate workspace is
  # first and remains present while disposable workers are projected around it.
  spawn_task "$ANCHOR_ID" "$HOME_DIR" "$PROJECT_DIR" > "$EVIDENCE_ROOT/anchor.out" 2> "$EVIDENCE_ROOT/anchor.err" \
    || fail "opted-out anchor spawn failed: $(cat "$EVIDENCE_ROOT/anchor.err")"
  ANCHOR_META="$HOME_DIR/state/$ANCHOR_ID.meta"
  remember_meta_worktree "$ANCHOR_META" >/dev/null
  FIRSTMATE_WSID=$(grep '^herdr_workspace_id=' "$ANCHOR_META" | cut -d= -f2-)
  [ -n "$FIRSTMATE_WSID" ] || fail "anchor metadata did not record the firstmate workspace"

}

presentation_fixture_seed_parents() {
  SECOND_ONE_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label 2ndmate-alpha --no-focus) \
    || fail "could not create the first secondmate presentation fixture"
  SECOND_TWO_OUT=$(lab workspace create --cwd "$PROJECT_DIR" --label 2ndmate-bravo --focus) \
    || fail "could not create the focused secondmate presentation fixture"
  SECOND_ONE_WSID=$(printf '%s' "$SECOND_ONE_OUT" | jq -r '.result.workspace.workspace_id // empty')
  SECOND_TWO_WSID=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.workspace.workspace_id // empty')
  SECOND_TWO_TAB=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.tab.tab_id // empty')
  SECOND_TWO_PANE=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$SECOND_ONE_WSID" ] && [ -n "$SECOND_TWO_WSID" ] && [ -n "$SECOND_TWO_TAB" ] && [ -n "$SECOND_TWO_PANE" ] \
    || fail "secondmate presentation fixtures returned incomplete IDs"
  CAPTAIN_FOCUS="$SECOND_TWO_WSID/$SECOND_TWO_TAB"
  assert_focus_is "$CAPTAIN_FOCUS" "focused secondmate fixture"

}

presentation_fixture_finish() {  # <entrypoint name>
  STATUS_JSON=$(lab status --json)
  HERDR_VERSION=$(printf '%s' "$STATUS_JSON" | jq -r '.client.version // "unknown"')
  PATH="$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
    || fail "guarded Herdr lab teardown or default-session tripwire verification failed"
  LAB_READY=0
  pass "real Herdr lab validation completed on Herdr $HERDR_VERSION with the default-session tripwire intact"

  cleanup_all || { trap - EXIT; printf 'not ok - cleanup failed\n' >&2; exit 1; }
  trap - EXIT
  printf '\nall %s tests passed\n' "$1"
}
