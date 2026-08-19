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
# docs/gbrain.md is there to keep the repo's own record parseable: the pin has
# to stay the first backticked v-prefixed token in that file or the dashboard
# panel quotes the wrong thing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
JQ_BIN_DIR=$(dirname "$(command -v jq)")

# shellcheck source=bin/fm-gbrain-lib.sh disable=SC1091
. "$ROOT/bin/fm-gbrain-lib.sh"

CHECK="$ROOT/bin/fm-gbrain-pin-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-gbrain-pin-check)

# --- fixtures ---------------------------------------------------------------

# A code root holding only the one file the check reads.
make_root() {  # <name> <record-line>
  local root="$TMP_ROOT/$1"
  mkdir -p "$root/docs"
  printf '# Local GBrain archive\n\n%s\n' "$2" > "$root/docs/gbrain.md"
  printf '%s\n' "$root"
}

# The record sentence in the shape docs/gbrain.md writes it, so the parse under
# test is the real one. Its backticks are markdown rather than command
# substitution, which is why the one place that writes them carries the
# directive instead of every case below.
# shellcheck disable=SC2016
PIN_RECORD='The installed GBrain release is `%s` at commit `%s`.'

make_pinned_root() {  # <name> <version> <commit>
  # shellcheck disable=SC2059 # PIN_RECORD is this suite's own format string
  make_root "$1" "$(printf "$PIN_RECORD" "$2" "$3")"
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

# Run the check with no gbrain reachable unless one is passed. FM_GBRAIN_BIN is
# cleared because the check resolves it ahead of PATH, and a caller who exports
# it - the form the gbrain verification docs prescribe - would otherwise hand
# these cases a real brain. jq's own directory is kept on the pinned PATH
# because the check needs it for --json and it is not under /usr/bin everywhere
# (Homebrew installs it elsewhere).
run_check() {  # <code-root> [args...]
  local root=$1
  shift
  FM_ROOT_OVERRIDE="$root" FM_GBRAIN_BIN='' \
    PATH="$TMP_ROOT/empty-path:$JQ_BIN_DIR:/usr/bin:/bin" \
    bash "$CHECK" "$@" 2>&1
}

mkdir -p "$TMP_ROOT/empty-path"

# --- cases ------------------------------------------------------------------

test_matching_pin_and_install_is_ok() {
  local root out rc
  root=$(make_pinned_root match v0.46.21.0 649ffe5f)
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
  root=$(make_pinned_root vform v0.46.21.0 649ffe5f)
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
  root=$(make_pinned_root drift v0.45.9.0 1ec6a6e)
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
  root=$(make_pinned_root absent v0.46.21.0 649ffe5f)
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
  # The reason has to survive the read. It lives in FM_GBRAIN_ERROR, which a
  # command substitution around the reader would leave in a subshell, and the
  # header promises unknown distinguishes an absent record from an unparseable
  # one - which an empty detail cannot do.
  case $out in
    *unknown*"no docs/gbrain.md under $root"*) ;;
    *) fail "a missing record must be reported unknown, naming the root it looked under: $out" ;;
  esac
  pass "a missing docs/gbrain.md is unknown, never agreement"
}

test_unparseable_record_is_unknown() {
  local root out rc
  root=$(make_root nopin 'The installed GBrain release is recorded nowhere machine-readable.')
  out=$(run_check "$root" --gbrain "$(make_gbrain nopin 'gbrain 0.46.21.0')") && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a record with no pin token must exit 2, got $rc: $out"
  case $out in
    *unknown*"records no pinned release token"*) ;;
    *) fail "an unparseable record must be reported unknown, and say the token is what is missing: $out" ;;
  esac
  pass "a record carrying no pin token is unknown, and says so"
}

test_broken_executable_is_unknown_not_drift() {
  local root out rc
  root=$(make_pinned_root broken v0.46.21.0 649ffe5f)
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
  root=$(make_pinned_root json v0.45.9.0 1ec6a6e)
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
  root=$(make_pinned_root flag v0.46.21.0 649ffe5f)
  out=$(run_check "$root" --no-such-flag) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown flag must be refused, got $rc: $out"
  pass "an unknown flag is refused rather than ignored"
}

test_repo_record_keeps_its_pin_first() {
  local sentence_pin
  # docs/gbrain.md is the owned record of the installed release, and one
  # sentence in it carries that meaning while fm_gbrain_documented_pin - the
  # single reader the dashboard panel and this check share - takes the FIRST
  # backticked v-prefixed token in the whole file. Those two agree only while
  # the pin stays first, so the expectation is derived from the sentence alone:
  # deriving it with the reader's own rule would agree with the reader for any
  # content at all, including the stray-earlier-token regression this pins.
  # shellcheck disable=SC2016 # regex pattern, not a shell expansion
  sentence_pin=$(grep -m1 '^The installed GBrain release is ' "$ROOT/docs/gbrain.md" \
    | grep -oE '`v[0-9][^`]*`' | head -1 | tr -d '`')
  [ -n "$sentence_pin" ] \
    || fail "docs/gbrain.md has no 'The installed GBrain release is <pin>' sentence to read the pin from"
  fm_gbrain_documented_pin "$ROOT" \
    || fail "the shared reader cannot read the repo's own record: $FM_GBRAIN_ERROR"
  [ "$FM_GBRAIN_PIN" = "$sentence_pin" ] \
    || fail "the shared reader returns $FM_GBRAIN_PIN but the record's pin sentence says $sentence_pin, so an earlier token has taken its place"
  pass "the repo's docs/gbrain.md keeps its pin as the first release token"
}

test_an_explicitly_named_gbrain_that_is_unusable_is_unknown() {
  local root out rc missing notexec
  # Auto-discovery finding nothing is an absent brain. A caller that NAMES a
  # path has asserted it should be there, so an unusable one is a side that
  # could not be read - reporting it as skipped would hand any caller whose
  # wired path later moves a permanently green exit 0.
  root=$(make_pinned_root explicit v0.46.21.0 649ffe5f)
  missing="$TMP_ROOT/absent-gbrain"
  out=$(run_check "$root" --gbrain "$missing") && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "an explicitly named missing gbrain must exit 2, got $rc: $out"
  case $out in
    *unknown*"$missing"*) ;;
    *) fail "an explicitly named missing gbrain must be unknown and name the path: $out" ;;
  esac

  notexec="$TMP_ROOT/not-executable-gbrain"
  printf '#!/usr/bin/env bash\nprintf "gbrain 0.46.21.0\\n"\n' > "$notexec"
  chmod 0644 "$notexec"
  out=$(run_check "$root" --gbrain="$notexec") && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "an explicitly named non-executable gbrain must exit 2, got $rc: $out"
  case $out in
    *skipped*) fail "an explicitly named path must never read as an absent brain: $out" ;;
  esac
  pass "an explicitly named gbrain that is missing or not executable is unknown, not skipped"
}

test_fm_gbrain_bin_names_the_executable_to_compare() {
  local root out rc envbin flagbin
  # docs/configuration.md owns FM_GBRAIN_BIN as the gbrain executable the
  # recall, capture, health, and eval surfaces all resolve, and a home may name
  # it there without putting that directory on PATH. A comparer that only
  # looked at PATH would read such a home as having no brain at all and let its
  # pin drift behind a permanent exit 0, which is the silent pass `skipped`
  # exists to avoid claiming.
  root=$(make_pinned_root envbin v0.45.9.0 1ec6a6e)
  envbin=$(make_gbrain envbin 'gbrain 0.46.21.0')
  out=$(FM_ROOT_OVERRIDE="$root" FM_GBRAIN_BIN="$envbin" \
    PATH="$TMP_ROOT/empty-path:$JQ_BIN_DIR:/usr/bin:/bin" bash "$CHECK" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "a gbrain reachable only through FM_GBRAIN_BIN must be compared, got $rc: $out"
  case $out in
    *drift*v0.45.9.0*0.46.21.0*) ;;
    *) fail "FM_GBRAIN_BIN's executable must be the side compared: $out" ;;
  esac
  case $out in
    *skipped*) fail "a home that names its gbrain in FM_GBRAIN_BIN has a brain to compare: $out" ;;
  esac

  # The flag is the caller's own override, so it outranks the environment.
  flagbin=$(make_gbrain envbin-flag 'gbrain 0.45.9.0')
  out=$(FM_ROOT_OVERRIDE="$root" FM_GBRAIN_BIN="$envbin" \
    PATH="$TMP_ROOT/empty-path:$JQ_BIN_DIR:/usr/bin:/bin" bash "$CHECK" --gbrain "$flagbin" 2>&1) \
    && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "--gbrain must outrank FM_GBRAIN_BIN, got $rc: $out"
  case $out in
    *"ok - "*"$flagbin"*) ;;
    *) fail "--gbrain must name the executable actually asked: $out" ;;
  esac
  pass "FM_GBRAIN_BIN names the executable to compare, and --gbrain outranks it"
}

test_an_unresolvable_fm_gbrain_bin_is_unknown_not_skipped() {
  local root out rc
  # Setting FM_GBRAIN_BIN names an executable, which is the same assertion
  # --gbrain makes, so a target that has been renamed or moved is a side that
  # could not be read. Reporting it as skipped would hand that home a green
  # exit 0 and a permanently silent session start while its pin drifts.
  root=$(make_pinned_root envmissing v0.45.9.0 1ec6a6e)
  out=$(FM_ROOT_OVERRIDE="$root" FM_GBRAIN_BIN="$TMP_ROOT/renamed-away-gbrain" \
    PATH="$TMP_ROOT/empty-path:$JQ_BIN_DIR:/usr/bin:/bin" bash "$CHECK" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unresolvable FM_GBRAIN_BIN must exit 2, got $rc: $out"
  case $out in
    *unknown*"$TMP_ROOT/renamed-away-gbrain"*) ;;
    *) fail "an unresolvable FM_GBRAIN_BIN must be unknown and name the path: $out" ;;
  esac
  case $out in
    *skipped*) fail "a named executable that does not resolve is not an absent brain: $out" ;;
  esac

  # An unset one is the genuine absent brain, and stays the one exit 0 that did
  # not compare two releases.
  out=$(run_check "$root") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "an unset FM_GBRAIN_BIN with no gbrain on PATH must stay skipped, got $rc: $out"
  case $out in
    *skipped*) ;;
    *) fail "nothing naming a gbrain and none on PATH must report skipped: $out" ;;
  esac
  pass "an FM_GBRAIN_BIN that does not resolve is unknown, while naming none stays skipped"
}

test_installed_release_is_read_from_stdout_alone() {
  local root out rc bin
  # gbrain writes upgrade-availability banners carrying a second version to
  # stderr on the non-TTY path every caller here takes. A merged stream lets
  # that banner's version be read as the installed release, which would report
  # false drift on every host at once.
  root=$(make_pinned_root banner v0.46.21.0 649ffe5f)
  bin="$TMP_ROOT/bin-banner/gbrain"
  mkdir -p "$TMP_ROOT/bin-banner"
  printf '#!/usr/bin/env bash\nprintf "UPGRADE_AVAILABLE 0.46.21.0 0.47.0.0\\n" >&2\nprintf "gbrain 0.46.21.0\\n"\n' > "$bin"
  chmod 0755 "$bin"
  out=$(run_check "$root" --gbrain "$bin") && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a banner on stderr must not become the installed release, got $rc: $out"
  case $out in
    *"ok - "*0.46.21.0*) ;;
    *) fail "the release must be read from stdout alone: $out" ;;
  esac
  case $out in
    *0.47.0.0*) fail "the stderr banner's version must never be reported as installed: $out" ;;
  esac
  pass "the installed release is read from stdout alone, never from a stderr banner"
}

test_a_record_with_no_dotted_release_is_unknown() {
  local root out rc
  # The pin token parses but carries nothing comparable, so the record side was
  # not read as a release. Calling that drift would name a difference the check
  # never established.
  root=$(make_pinned_root nodots v1 1ec6a6e)
  out=$(run_check "$root" --gbrain "$(make_gbrain nodots 'gbrain 0.46.21.0')") && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a record with no dotted release must exit 2, got $rc: $out"
  case $out in
    *unknown*"no dotted release number"*) ;;
    *) fail "a record with no comparable release must be unknown, not drift: $out" ;;
  esac
  pass "a recorded pin carrying no dotted release number is unknown, not drift"
}

test_help_prints_the_flags_and_verdicts_it_owns() {
  local out rc needle
  # docs/one-owner.md makes each script's --help the owner of its exact flags
  # and mechanics, and this one's verdict/exit-code table is the contract every
  # caller branches on.
  out=$(bash "$CHECK" --help) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "--help must exit 0, got $rc: $out"
  for needle in 'Usage:' '--json' '--gbrain' 'ok        0' 'drift     1' 'skipped   0' 'unknown   2'; do
    case $out in
      *"$needle"*) ;;
      *) fail "--help must document \"$needle\": $out" ;;
    esac
  done
  pass "--help prints the flags and the verdict table the script owns"
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
test_an_explicitly_named_gbrain_that_is_unusable_is_unknown
test_fm_gbrain_bin_names_the_executable_to_compare
test_an_unresolvable_fm_gbrain_bin_is_unknown_not_skipped
test_installed_release_is_read_from_stdout_alone
test_a_record_with_no_dotted_release_is_unknown
test_help_prints_the_flags_and_verdicts_it_owns

fm_test_every_defined_test_ran

printf '\nall fm-gbrain-pin-check tests passed\n'
