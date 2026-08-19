#!/usr/bin/env bash
# Behavior tests for bin/fm-gbrain-pin-check.sh, the drift check between the
# GBrain release docs/gbrain.md records and the one actually installed.
#
# The check exists because those two are required to move in one change and
# nothing verified it; the pin went stale silently once already. So the cases
# below pin the distinction that makes it useful: a disagreement is a failure,
# an absent executable is a reported skip rather than a pass, and a side that
# cannot be read is reported as unknown rather than as agreement.
#
# No real GBrain runs here. Every case drives the check against a fixture doc
# and a stub executable, so the suite is offline, deterministic, and safe to
# run on a host that has no brain at all. The one case that reads the real
# docs/gbrain.md still stubs the executable, and it is there to keep the repo's
# own record parseable: the pin has to stay the first backticked v-prefixed
# token in that file or the dashboard panel quotes the wrong thing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CHECK="$ROOT/bin/fm-gbrain-pin-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-gbrain-pin-check)

# --- fixtures ---------------------------------------------------------------

# A code root holding only the one file the check reads. <pin> is written in
# the same shape docs/gbrain.md uses so the parse under test is the real one.
make_root() {  # <name> <pin-line>
  local root="$TMP_ROOT/$1"
  mkdir -p "$root/docs"
  printf '# Local GBrain archive\n\n%s\n' "$2" > "$root/docs/gbrain.md"
  printf '%s\n' "$root"
}

# A stub gbrain. <mode> is a version string to print, or "fail" to exit
# non-zero the way a broken install does.
make_gbrain() {  # <name> <mode>
  local bin="$TMP_ROOT/bin-$1"
  mkdir -p "$bin"
  if [ "$2" = fail ]; then
    printf '#!/usr/bin/env bash\nprintf "gbrain: cannot open database\\n" >&2\nexit 1\n' > "$bin/gbrain"
  else
    printf '#!/usr/bin/env bash\nprintf "%s\\n"\n' "$2" > "$bin/gbrain"
  fi
  chmod 0755 "$bin/gbrain"
  printf '%s\n' "$bin/gbrain"
}

# Run the check with no gbrain reachable on PATH unless one is passed.
run_check() {  # <code-root> [args...]
  local root=$1
  shift
  FM_ROOT_OVERRIDE="$root" PATH="$TMP_ROOT/empty-path:/usr/bin:/bin" \
    bash "$CHECK" "$@" 2>&1
}

mkdir -p "$TMP_ROOT/empty-path"

# --- cases ------------------------------------------------------------------

test_matching_pin_and_install_is_ok() {
  local root out rc
  root=$(make_root match 'The installed GBrain release is `v0.46.21.0` at commit `649ffe5f`.')
  out=$(run_check "$root" --gbrain "$(make_gbrain match 'gbrain 0.46.21.0')") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a matching pin must exit 0, got $rc: $out"
  case $out in
    *"ok - "*) ;;
    *) fail "a matching pin must report ok: $out" ;;
  esac
  pass "a recorded pin matching the installed release is ok"
}

test_leading_v_is_a_tag_convention_not_a_difference() {
  local root out rc
  # The record writes the tag and the executable prints a bare version. If the
  # check compared those literally, every correct pin would read as drift.
  root=$(make_root vform 'The installed GBrain release is `v0.46.21.0` at commit `649ffe5f`.')
  out=$(run_check "$root" --gbrain "$(make_gbrain vform 'gbrain 0.46.21.0')") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "v-prefixed record vs bare version must not read as drift: $out"
  case $out in
    *v0.46.21.0*0.46.21.0*) ;;
    *) fail "the ok line must name both sides: $out" ;;
  esac
  pass "the record's leading v is a tag convention, not a difference"
}

test_stale_pin_fails_naming_both_sides() {
  local root out rc
  root=$(make_root drift 'The installed GBrain release is `v0.45.9.0` at commit `1ec6a6e`.')
  out=$(run_check "$root" --gbrain "$(make_gbrain drift 'gbrain 0.46.21.0')") && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "drift must exit 1, got $rc: $out"
  case $out in
    *drift*v0.45.9.0*0.46.21.0*) ;;
    *) fail "drift must name the recorded pin and the installed release: $out" ;;
  esac
  pass "a recorded pin the host has moved past fails, naming both sides"
}

test_absent_gbrain_is_a_reported_skip_not_a_pass() {
  local root out rc
  root=$(make_root absent 'The installed GBrain release is `v0.46.21.0` at commit `649ffe5f`.')
  out=$(run_check "$root") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "an absent gbrain must not fail the check, got $rc: $out"
  case $out in
    *skipped*) ;;
    *) fail "an absent gbrain must be reported as skipped, never as ok: $out" ;;
  esac
  case $out in
    *"ok - "*) fail "an absent gbrain must not report ok: $out" ;;
  esac
  pass "no installed gbrain is a reported skip, not a silent pass"
}

test_missing_record_is_unknown_not_agreement() {
  local root out rc
  root="$TMP_ROOT/no-doc"
  mkdir -p "$root"
  out=$(run_check "$root" --gbrain "$(make_gbrain nodoc 'gbrain 0.46.21.0')") && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a missing docs/gbrain.md must exit 2, got $rc: $out"
  case $out in
    *unknown*) ;;
    *) fail "a missing record must be reported unknown: $out" ;;
  esac
  pass "a missing docs/gbrain.md is unknown, never agreement"
}

test_unparseable_record_is_unknown() {
  local root out rc
  root=$(make_root nopin 'The installed GBrain release is recorded nowhere machine-readable.')
  out=$(run_check "$root" --gbrain "$(make_gbrain nopin 'gbrain 0.46.21.0')") && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a record with no pin token must exit 2, got $rc: $out"
  case $out in
    *unknown*) ;;
    *) fail "a record with no pin token must be reported unknown: $out" ;;
  esac
  pass "a record carrying no pin token is unknown"
}

test_broken_executable_is_unknown_not_drift() {
  local root out rc
  root=$(make_root broken 'The installed GBrain release is `v0.46.21.0` at commit `649ffe5f`.')
  out=$(run_check "$root" --gbrain "$(make_gbrain broken fail)") && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "an executable that cannot report its version must exit 2, got $rc: $out"
  case $out in
    *unknown*) ;;
    *) fail "a failed --version must be unknown, not drift: $out" ;;
  esac
  pass "an executable that cannot report its version is unknown, not drift"
}

test_json_carries_both_sides_and_the_verdict() {
  local root out
  root=$(make_root json 'The installed GBrain release is `v0.45.9.0` at commit `1ec6a6e`.')
  out=$(run_check "$root" --json --gbrain "$(make_gbrain json 'gbrain 0.46.21.0')") || true
  [ "$(printf '%s' "$out" | jq -r '.schema')" = fm-gbrain-pin-check.v1 ] \
    || fail "json must carry its schema: $out"
  [ "$(printf '%s' "$out" | jq -r '.verdict')" = drift ] || fail "json verdict wrong: $out"
  [ "$(printf '%s' "$out" | jq -r '.documented')" = v0.45.9.0 ] || fail "json documented wrong: $out"
  [ "$(printf '%s' "$out" | jq -r '.installed')" = 0.46.21.0 ] || fail "json installed wrong: $out"
  pass "json output carries the verdict and both sides"
}

test_unknown_flag_is_refused() {
  local root out rc
  root=$(make_root flag 'The installed GBrain release is `v0.46.21.0` at commit `649ffe5f`.')
  out=$(run_check "$root" --no-such-flag) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown flag must be refused, got $rc: $out"
  pass "an unknown flag is refused rather than ignored"
}

test_repo_record_keeps_its_pin_first() {
  local pin out rc
  # The dashboard panel quotes the FIRST backticked v-prefixed token in the
  # real docs/gbrain.md. If an edit ever puts another one above the pin, this
  # check would compare the wrong token and the panel would quote it too.
  # shellcheck disable=SC2016 # regex pattern, not a shell expansion
  pin=$(grep -oE '`v[0-9][^`]*`' "$ROOT/docs/gbrain.md" | head -1 | tr -d '`')
  [ -n "$pin" ] || fail "the repo's docs/gbrain.md carries no pin token at all"
  out=$(FM_ROOT_OVERRIDE="$ROOT" PATH="$TMP_ROOT/empty-path:/usr/bin:/bin" \
    bash "$CHECK" --gbrain "$(make_gbrain repo "gbrain ${pin#v}")" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the repo's own pin token is not the first one in docs/gbrain.md: $out"
  pass "the repo's docs/gbrain.md keeps its pin as the first release token"
}

test_matching_pin_and_install_is_ok
test_leading_v_is_a_tag_convention_not_a_difference
test_stale_pin_fails_naming_both_sides
test_absent_gbrain_is_a_reported_skip_not_a_pass
test_missing_record_is_unknown_not_agreement
test_unparseable_record_is_unknown
test_broken_executable_is_unknown_not_drift
test_json_carries_both_sides_and_the_verdict
test_unknown_flag_is_refused
test_repo_record_keeps_its_pin_first

fm_test_every_defined_test_ran

printf '\nall fm-gbrain-pin-check tests passed\n'
