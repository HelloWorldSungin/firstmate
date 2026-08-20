#!/usr/bin/env bash
# Routing contract for bin/fm-harness-adapter-doc.sh, which resolves a harness
# name to its harness-adapters variant file.
#
# Why this suite exists: the harness-adapters reference was split into a shared
# head plus one variant file per harness so a spawn loads the head and the one
# adapter it is about to act on. That trade is only safe while the routing is
# deterministic and its failures are loud. A resolver that quietly returned
# nothing would leave an agent answering a trust-dialog or exit-path question
# from the shared head alone - a confident wrong answer about a pane that is
# already waiting. So every verified harness is asserted to reach its OWN
# variant, and every failure mode is asserted to be a named non-zero refusal.
#
# Everything here runs against the real repository tree or a fixture tree built
# from it; no harness binary is involved, so this is a portable regression.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOC="$ROOT/bin/fm-harness-adapter-doc.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-adapter-doc)

# The nine verified harnesses from AGENTS.md section 4, plus the crew-only
# herdr-only agy adapter, each paired with a string that appears ONLY in its own
# variant file's heading. Resolving to the wrong file fails on this string.
VERIFIED_HARNESSES="claude:## claude (
codex:## codex (
opencode:## opencode (
pi:## pi and pi-signed (
pi-signed:## pi and pi-signed (
grok:## grok (
kimi:## kimi (
cursor:## cursor (
muse:## muse (
agy:## agy ("

# fixture_root: a throwaway copy of the routing script plus the variant
# directory, so a test can delete or chmod a variant without touching the repo.
fixture_root() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/.agents/skills/harness-adapters/harnesses"
  cp "$DOC" "$dir/bin/"
  cp "$ROOT"/.agents/skills/harness-adapters/harnesses/*.md \
    "$dir/.agents/skills/harness-adapters/harnesses/"
  printf '%s\n' "$dir"
}

# --- every verified harness reaches its own content --------------------------

test_every_verified_harness_resolves_to_its_own_variant() {
  local entry harness marker path out
  while IFS= read -r entry; do
    harness=${entry%%:*}
    marker=${entry#*:}

    path=$("$DOC" "$harness") \
      || fail "$harness: the resolver refused a verified harness"
    assert_present "$path" "$harness: resolved a path that does not exist: $path"

    out=$("$DOC" --print "$harness") \
      || fail "$harness: --print refused a verified harness"
    assert_contains "$out" "$marker" \
      "$harness: --print did not return that harness's own variant content"

    # The head is a separate file and must never be what a variant lookup
    # returns; serving it would be the silent-partial-answer failure.
    assert_not_contains "$out" "## Load the variant file for the harness you are acting on" \
      "$harness: the resolver returned shared-head content instead of a variant"
  done <<EOF
$VERIFIED_HARNESSES
EOF
  pass "every verified harness resolves to its own variant file"
}

test_pi_and_pi_signed_share_one_variant() {
  local a b
  a=$("$DOC" pi)
  b=$("$DOC" pi-signed)
  [ "$a" = "$b" ] \
    || fail "pi and pi-signed are one adapter and must share one variant file, got '$a' and '$b'"
  pass "pi and pi-signed resolve to the same variant file"
}

test_list_and_routing_table_agree_with_the_variant_directory() {
  local listed name routed file base path code orphan=

  listed=$("$DOC" --list) || fail "--list failed"
  [ -n "$listed" ] || fail "--list returned nothing, so this check would be vacuous"

  # Every name --list advertises must actually resolve; an advertised name that
  # refuses would be a routing table that lies about its own coverage. Take the
  # resolver's exit status OUTSIDE the command substitution: a `|| fail` inside
  # one exits only the subshell, which would make this assertion unable to fail.
  routed=
  for name in $listed; do
    path=$("$DOC" "$name" 2>/dev/null) && code=0 || code=$?
    [ "$code" = 0 ] \
      || fail "--list advertises '$name' but resolving it exits $code, so the routing table lies about its own coverage"
    [ -n "$path" ] \
      || fail "--list advertises '$name' but the resolver printed no path for it"
    assert_present "$path" "--list advertises '$name' but its variant file does not exist: $path"
    routed="$routed $(basename "$path")"
  done

  # And every variant file on disk must be reachable from some name, or it is a
  # file nothing would ever load - the silent half of a broken split.
  for file in "$ROOT"/.agents/skills/harness-adapters/harnesses/*.md; do
    base=$(basename "$file")
    case "$routed " in
      *" $base "*) : ;;
      *) orphan="$orphan $base" ;;
    esac
  done
  [ -z "$orphan" ] \
    || fail "variant files no harness name routes to, so nothing would ever load them:$orphan"
  pass "--list and the routing table reach every variant file in the directory"
}

# --- failures are loud -------------------------------------------------------

test_unknown_harness_name_refuses_by_name() {
  local out code
  out=$("$DOC" zellij 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "an unknown harness name"
  assert_contains "$out" "zellij" "the refusal must name the harness that failed"
  assert_contains "$out" "claude" "the refusal must list the names that do resolve"
  assert_contains "$out" "agy" "the refusal must list the names that do resolve"
  pass "an unknown harness name exits 2 naming it and the resolvable names"
}

test_resolution_results_are_refused_not_treated_as_harnesses() {
  local name out code
  for name in default unknown ""; do
    out=$("$DOC" "$name" 2>&1) && code=0 || code=$?
    case "$name" in
      "") expect_code 64 "$code" "an empty harness name" ;;
      *)
        expect_code 2 "$code" "the resolution result '$name'"
        assert_contains "$out" "bin/fm-harness.sh" \
          "'$name' must be routed back to harness detection, not silently accepted"
        ;;
    esac
  done
  pass "'default', 'unknown', and an empty name are refused rather than resolved"
}

test_missing_variant_file_refuses_naming_the_path() {
  local dir out code
  dir=$(fixture_root "$TMP_ROOT/missing")
  rm "$dir/.agents/skills/harness-adapters/harnesses/grok.md"
  out=$(FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-harness-adapter-doc.sh" grok 2>&1) && code=0 || code=$?
  expect_code 3 "$code" "a missing variant file"
  assert_contains "$out" "harnesses/grok.md" "the refusal must name the path it expected"
  assert_contains "$out" "shared head alone" \
    "the refusal must forbid falling back to the shared head"
  # A known name with a missing file must not be mistaken for an unknown name:
  # the two need different repairs.
  assert_not_contains "$out" "resolvable names:" \
    "a missing file is not an unknown-name refusal"
  pass "a missing variant file exits 3 naming the path, distinctly from an unknown name"
}

test_unreadable_variant_file_refuses() {
  local dir out code
  dir=$(fixture_root "$TMP_ROOT/unreadable")
  chmod 000 "$dir/.agents/skills/harness-adapters/harnesses/cursor.md"
  out=$(FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-harness-adapter-doc.sh" cursor 2>&1) && code=0 || code=$?
  chmod 644 "$dir/.agents/skills/harness-adapters/harnesses/cursor.md"
  if [ "$(id -u)" = 0 ]; then
    printf '# skipped: running as root, which can read a mode-000 file\n'
  else
    expect_code 3 "$code" "an unreadable variant file"
    assert_contains "$out" "harnesses/cursor.md" "the refusal must name the unreadable path"
  fi
  pass "an unreadable variant file exits 3 naming the path"
}

test_usage_errors_exit_64() {
  local out code
  out=$("$DOC" 2>&1) && code=0 || code=$?
  expect_code 64 "$code" "no harness name"
  out=$("$DOC" grok kimi 2>&1) && code=0 || code=$?
  expect_code 64 "$code" "two harness names"
  out=$("$DOC" --nonsense grok 2>&1) && code=0 || code=$?
  expect_code 64 "$code" "an unknown option"
  assert_contains "$out" "--nonsense" "an unknown option must be named"
  pass "usage errors exit 64 rather than resolving something"
}

test_every_verified_harness_resolves_to_its_own_variant
test_pi_and_pi_signed_share_one_variant
test_list_and_routing_table_agree_with_the_variant_directory
test_unknown_harness_name_refuses_by_name
test_resolution_results_are_refused_not_treated_as_harnesses
test_missing_variant_file_refuses_naming_the_path
test_unreadable_variant_file_refuses
test_usage_errors_exit_64

fm_test_every_defined_test_ran

printf '\nall fm-harness-adapter-doc tests passed\n'
