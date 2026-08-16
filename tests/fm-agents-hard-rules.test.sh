#!/usr/bin/env bash
# Structural contract for AGENTS.md section 1's hard-rule list - the write
# boundaries every fleet session loads before it does anything else.
#
# Two silent failure modes have no other guard here. Prose across this repo
# cites those boundaries BY NUMBER, so inserting or retiring a rule renumbers
# the list and leaves a citation pointing at a different boundary. And a size
# trim of the always-loaded surface can drop a boundary outright, which reads
# as ordinary prose churn in a diff.
#
# This suite pins that seam rather than the wording: the numbering shape, the
# numeric citations resolving, and the presence and required clauses of the
# upstream write boundary - whose whole job is to be in force at the moment a
# recorded publish target would otherwise route a write to a third-party
# upstream repository, where an agent instruction alone and a push-URL guard
# alone both miss.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
TMP_ROOT=$(fm_test_tmproot fm-agents-hard-rules)

# "<number>\t<title>" for every rule in section 1's hard-rule list.
hard_rules() {  # <agents-md>
  awk '
    /^Hard rules, in priority order:$/ { inlist = 1; next }
    !inlist { next }
    /^[0-9]+\. \*\*/ {
      number = $0
      sub(/\..*$/, "", number)
      title = $0
      sub(/^[0-9]+\. \*\*/, "", title)
      sub(/\*\*.*$/, "", title)
      printf "%s\t%s\n", number, title
      next
    }
    /^[^ 0-9]/ { exit }
  ' "$1"
}

# One rule's numbered line plus its indented continuation lines.
hard_rule_body() {  # <agents-md> <number>
  awk -v want="$2" '
    /^Hard rules, in priority order:$/ { inlist = 1; next }
    !inlist { next }
    /^[0-9]+\. / {
      number = $0
      sub(/\..*$/, "", number)
      capture = (number == want)
      if (capture) print
      next
    }
    capture && /^ / { print; next }
    /^[^ 0-9]/ { exit }
  ' "$1"
}

# The checks below report their reason on stdout and return 1 rather than
# calling fail, so the same check runs against a mutated copy to prove it bites.

check_numbering() {  # <agents-md>
  local rules number title expected=1
  rules=$(hard_rules "$1")
  if [ -z "$rules" ]; then
    echo "no hard-rule list found under 'Hard rules, in priority order:'"
    return 1
  fi
  while IFS=$'\t' read -r number title; do
    [ -n "$number" ] || continue
    if [ "$number" != "$expected" ]; then
      echo "hard rules are not sequential: expected $expected, found $number"
      return 1
    fi
    if [ -z "$title" ]; then
      echo "hard rule $number has no bolded title"
      return 1
    fi
    expected=$((expected + 1))
  done <<EOF
$rules
EOF
  return 0
}

# Every current citation names hard rule 1, and names it for the project-write
# boundary whose exception it relies on. A future rule taking number 1 has to
# re-check all of them, and this is the assertion that forces that.
check_cited_identity() {  # <agents-md>
  local title
  title=$(hard_rules "$1" | awk -F'\t' '$1 == "1" { print $2 }')
  if [ "$title" != "Never write to a project." ]; then
    echo "hard rule 1 is now '$title'; every 'hard rule 1' citation needs re-checking"
    return 1
  fi
  return 0
}

check_citations() {  # <repo-root> <rule-count>
  local root=$1 count=$2 reference number
  while IFS= read -r reference; do
    [ -n "$reference" ] || continue
    number=${reference##* }
    if [ "$number" -lt 1 ] || [ "$number" -gt "$count" ]; then
      echo "tracked prose cites '$reference', outside the 1..$count hard rules"
      return 1
    fi
  done < <(git -C "$root" grep -hIoiE 'hard rule [0-9]+' | LC_ALL=C sort -u)
  return 0
}

check_upstream_boundary() {  # <agents-md>
  local number body clause
  number=$(hard_rules "$1" | grep -i 'third-party upstream repository' | cut -f1)
  if [ -z "$number" ]; then
    echo "no hard rule names the third-party upstream write boundary"
    return 1
  fi
  body=$(hard_rule_body "$1" "$number")
  # Read stays allowed and keeps its owner; every write class is named; the
  # destination is the captain's own repository; a recorded target is verified
  # rather than assumed; and the only exception is a concrete current approval.
  for clause in \
    '/sync-upstream' \
    'pushing branches' \
    'opening PRs' \
    "captain's own repository" \
    'recorded publish target' \
    'concrete, current approval'; do
    case "$body" in
      *"$clause"*) ;;
      *)
        echo "hard rule $number lost its '$clause' clause"
        return 1
        ;;
    esac
  done
  return 0
}

test_repository_hard_rules_are_well_formed() {
  local out count
  out=$(check_numbering "$AGENTS") || fail "AGENTS.md hard rules: $out"
  out=$(check_cited_identity "$AGENTS") || fail "AGENTS.md hard rules: $out"
  count=$(hard_rules "$AGENTS" | wc -l | tr -d '[:space:]')
  out=$(check_citations "$ROOT" "$count") || fail "AGENTS.md hard rules: $out"
  pass "hard rules number 1..$count and every numeric citation resolves"
}

test_upstream_write_boundary_is_always_loaded() {
  local out
  out=$(check_upstream_boundary "$AGENTS") || fail "AGENTS.md hard rules: $out"
  pass "the third-party upstream write boundary is a hard rule with every clause"
}

test_renumbering_and_dropped_clauses_are_caught() {
  local renumbered dropped weakened out rc
  renumbered="$TMP_ROOT/renumbered.md"
  dropped="$TMP_ROOT/dropped.md"
  weakened="$TMP_ROOT/weakened.md"

  # A rule inserted or retired without renumbering its successors.
  sed 's/^3\. /4. /' "$AGENTS" > "$renumbered"
  set +e
  out=$(check_numbering "$renumbered")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a renumbered hard-rule list passed the numbering check"
  assert_contains "$out" "not sequential" "numbering failure did not explain itself"

  # The boundary retitled away while the list still numbers cleanly.
  sed 's/^\([0-9][0-9]*\)\. \*\*Never write to a third-party upstream repository\.\*\*$/\1. **Never write to an unfamiliar remote.**/' \
    "$AGENTS" > "$dropped"
  set +e
  out=$(check_upstream_boundary "$dropped")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a dropped upstream boundary passed the boundary check"
  assert_contains "$out" "no hard rule names" "dropped-boundary failure did not explain itself"

  # The boundary kept, but its configuration half quietly removed.
  grep -v 'recorded publish target' "$AGENTS" > "$weakened"
  set +e
  out=$(check_upstream_boundary "$weakened")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a boundary without its recorded-target clause passed"
  assert_contains "$out" "recorded publish target" "weakened-boundary failure did not explain itself"

  pass "renumbering, a dropped boundary, and a dropped clause each fail loudly"
}

test_repository_hard_rules_are_well_formed
test_upstream_write_boundary_is_always_loaded
test_renumbering_and_dropped_clauses_are_caught
printf '\nall fm-agents-hard-rules tests passed\n'
