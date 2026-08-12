#!/usr/bin/env bash
# Regression coverage for bin/fm-pr-status.sh's GitHub structured read.
#
# The single defect being guarded: a wrapper that returns non-JSON output
# while reporting success (exit 0) must not be folded into the same
# "unusable response" line a genuine forge error produces, and the structured
# read must never prefer a wrapper over plain gh for a --json-fields call.
# That second rule is what made the wrapper version of this bug invisible:
# the command-success check passed, so the parse guard downstream was the
# only place the wrong shape surfaced, and the message it emitted named a
# symptom, not a cause.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

PR_STATUS="$ROOT/bin/fm-pr-status.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-status)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A case fixture wires fake gh and gh-axi into a PATH-only fakebin, seeds a
# task metadata with a recorded PR URL, and exposes env knobs for the fake
# binaries. The fake gh prints the JSON body in $FM_TEST_GH_BODY and exits
# $FM_TEST_GH_RC; the fake gh-axi simulates the wrapper that ignores --json
# and prints a TOON body with exit 0, which is exactly what hid the defect.
make_case() {
  local name=$1 dir fakebin state
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  state="$dir/home/state"
  mkdir -p "$fakebin" "$state"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case " $* " in
  *" --json "*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit "${FM_TEST_GH_RC:-1}"
    printf '%s' "${FM_TEST_GH_BODY:-}"
    exit "${FM_TEST_GH_RC:-0}"
    ;;
esac
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case " $* " in
  *" --json "*)
    printf 'pull_request:\n  number: 1\n  state: OPEN\n'
    exit 0
    ;;
esac
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  : > "$dir/gh.log"
  : > "$dir/gh-axi.log"
  fm_write_meta "$state/task-a.meta" \
    'window=fm-task-a' \
    'endpoint_task_id=task-a' \
    'worktree=/tmp/unused' \
    'project=/tmp/unused' \
    'kind=ship' \
    'mode=no-mistakes' \
    'pr=https://github.com/o/r/pull/1'
  printf '%s\n' "$dir"
}

run_status() {  # <dir> <id> <extra-args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_STATUS" "$@"
}

# A base PATH stripped of any directory that resolves to a real gh, jq, or
# git, so a test that proves a missing CLI is rejected does not get a real
# tool from a Nix profile the host happens to expose. Built lazily so a host
# without nix-profile still has every test runnable.
STRICT_BASE_DIR="$TMP_ROOT/strict-bin"
mkdir -p "$STRICT_BASE_DIR"
STRICT_BASE_PATH="$STRICT_BASE_DIR"
for tool in bash sh cat printf sed awk grep head tail tr cut wc mktemp dirname basename cp mv rm chmod readlink uname env date ls find xargs perl python3 jq git timeout gtimeout; do
  src=$(command -v "$tool" 2>/dev/null) || continue
  case "$src" in
    "$STRICT_BASE_DIR"/*) continue ;;
  esac
  ln -sf "$src" "$STRICT_BASE_DIR/$tool" 2>/dev/null || true
done

run_status_strict_path() {  # <dir> <id>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
    PATH="$dir/fakebin:$STRICT_BASE_PATH" \
    "$PR_STATUS" "$@"
}

# Each test states in one line what would have to break for it to fail.

# Test 1: the structured read accepts real JSON and produces normalized
# fields. What would have to break: refresh_github stops calling `gh` with
# --json fields OR the jq reduction stops emitting the seven TSV columns.
test_github_refresh_accepts_real_json() {
  local dir
  dir=$(make_case real-json)
  export FM_TEST_GH_BODY='{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"","headRefOid":"0123456789abcdef0123456789abcdef01234567","statusCheckRollup":[]}'
  FM_TEST_GH_BODY="$FM_TEST_GH_BODY" run_status "$dir" refresh task-a > "$dir/out" 2> "$dir/err" \
    || fail "valid JSON refresh failed: $(cat "$dir/err")"
  local state rest
  IFS=$'\t' read -r state rest _ _ _ _ _ <<< "$(cat "$dir/out")"
  [ -n "$state" ] || fail "refresh did not emit a state field"
  grep -qxF 'pr view 1 --repo o/r --json state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefOid,statusCheckRollup' "$dir/gh.log" \
    || fail "refresh did not call gh with the full --json field list"
  grep -qxF '0' "$(wc -l < "$dir/gh-axi.log")" >/dev/null 2>&1 || [ ! -s "$dir/gh-axi.log" ] \
    || fail "refresh called gh-axi even though gh-axi does not honour --json"
  pass "real JSON refresh routes through gh and never touches gh-axi"
}

# Test 2: a CLI that exits 0 but returns non-JSON is caught as its own
# actionable condition, distinct from the "unusable response" line that hid
# the original defect. What would have to break: the parse guard is removed
# OR the exit-status check is folded back into the same message as the parse
# failure, so the next person reading the stderr again sees a symptom.
test_github_refresh_rejects_non_json_exit_zero_as_actionable_condition() {
  local dir
  dir=$(make_case toon-exit-zero)
  # Fake gh reproduces the wrapper's exact failure shape: exit 0, body that
  # is not JSON. If refresh_github ever switches back to a wrapper that does
  # this, the message must say so without being misread as a forge error.
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case " $* " in
  *" --json "*) printf 'pull_request:\n  number: 1\n  state: OPEN\n'; exit 0 ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  set +e
  run_status "$dir" refresh task-a > "$dir/out" 2> "$dir/err"
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "non-JSON success response was accepted as a successful refresh"
  assert_contains "$(cat "$dir/err")" "exited 0" \
    "the new actionable message must say the CLI exited 0"
  assert_contains "$(cat "$dir/err")" "non-JSON" \
    "the new actionable message must say the body was not JSON"
  assert_not_contains "$(cat "$dir/err")" "unusable response" \
    "the new actionable message must not collapse into the generic 'unusable response' line"
  pass "non-JSON success response is reported as the distinct, actionable condition it is"
}

# Test 3: refresh_github does not call gh-axi even when gh-axi is on PATH
# and gh is also available. What would have to break: refresh_github routes
# the structured read through a wrapper again, accepting whatever shape the
# wrapper returns.
test_github_refresh_does_not_call_gh_axi_when_gh_is_available() {
  local dir
  dir=$(make_case wrapper-bypass)
  FM_TEST_GH_BODY='{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"","headRefOid":"0123456789abcdef0123456789abcdef01234567","statusCheckRollup":[]}' \
    run_status "$dir" refresh task-a > "$dir/out" 2> "$dir/err" \
    || fail "structured read failed despite gh being on PATH"
  [ ! -s "$dir/gh-axi.log" ] || fail "structured read called gh-axi: $(cat "$dir/gh-axi.log")"
  pass "structured read bypasses gh-axi even when it is on PATH"
}

# Test 4: refresh_github fails closed when only gh-axi is on PATH, because
# gh-axi cannot honour --json. What would have to break: refresh_github
# routes through gh-axi when gh is absent and accepts the TOON body as JSON.
test_github_refresh_fails_closed_when_only_gh_axi_is_on_path() {
  local dir fakebin
  dir=$(make_case only-wrapper)
  fakebin="$dir/fakebin"
  rm -f "$fakebin/gh"
  set +e
  run_status_strict_path "$dir" refresh task-a > "$dir/out" 2> "$dir/err"
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "refresh succeeded with only gh-axi on PATH"
  assert_contains "$(cat "$dir/err")" "no gh on PATH" \
    "the missing-gh message must name the missing CLI"
  [ ! -s "$dir/gh-axi.log" ] || fail "refresh tried gh-axi when gh was missing: $(cat "$dir/gh-axi.log")"
  pass "structured read refuses to fall back to gh-axi when gh is missing"
}

# Test 5: a genuine forge failure (CLI exits nonzero) is reported as such,
# not folded into the non-JSON actionable message. What would have to break:
# the CLI-exit branch is folded into the parse-failure branch and the two
# failure shapes become indistinguishable again.
test_github_refresh_reports_cli_failure_separately_from_parse_failure() {
  local dir
  dir=$(make_case cli-failure)
  FM_TEST_GH_FAIL=1 FM_TEST_GH_RC=22 run_status "$dir" refresh task-a > "$dir/out" 2> "$dir/err" \
    || true
  assert_contains "$(cat "$dir/err")" "gh could not read" \
    "a CLI-exit failure must name the CLI, not the parser"
  assert_contains "$(cat "$dir/err")" "exit 22" \
    "a CLI-exit failure must surface the actual exit status"
  assert_not_contains "$(cat "$dir/err")" "exited 0" \
    "a CLI-exit failure must not claim the CLI exited 0"
  pass "CLI-exit failure is reported as such, not folded into the non-JSON actionable line"
}

main() {
  test_github_refresh_accepts_real_json
  test_github_refresh_rejects_non_json_exit_zero_as_actionable_condition
  test_github_refresh_does_not_call_gh_axi_when_gh_is_available
  test_github_refresh_fails_closed_when_only_gh_axi_is_on_path
  test_github_refresh_reports_cli_failure_separately_from_parse_failure
}

main "$@"
