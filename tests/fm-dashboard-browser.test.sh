#!/usr/bin/env bash
# Opt-in end-to-end proof of the real-browser dashboard check.
#
# bin/fm-dashboard-browser-check.sh is the harness; this is the guard that keeps
# the harness honest. It runs the check twice for real, in a real browser:
# against a correctly rendering dashboard, where every assertion must pass, and
# against a page that renders nothing, where they must fail. The second run is
# the one that matters. A check that reports success is worth nothing on its own
# - the failure this whole area exists to end is a page that was declared fine
# without being looked at - so the property being pinned here is that these
# assertions can still fail, not that they currently pass.
#
# Opt-in for two reasons the harness header states in full: chrome-devtools-axi
# drives ONE Chrome session per host, which the parallel test shards would fight
# over, and standard CI has no Chrome at all. So this sits in the
# live-harness-optin family alongside the other guards that need real local
# software, and is run deliberately - after a dashboard change, and before
# believing any claim about what the page shows.
#
# It never touches an installed dashboard service. The check's fixture mode
# starts its own server from this checkout on an ephemeral loopback port over a
# throwaway home, and this test passes no --url.
set -u

if [ "${FM_DASHBOARD_BROWSER_E2E:-0}" != 1 ]; then
  echo "skip: set FM_DASHBOARD_BROWSER_E2E=1 to run the real-browser dashboard check"
  exit 0
fi

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-dashboard-browser-check.sh"
BROWSER=${FM_DASHBOARD_BROWSER_CLI:-chrome-devtools-axi}

for tool in node curl "$BROWSER"; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

TMP_ROOT=$(fm_test_tmproot fm-dashboard-browser)

# --- a correctly rendering dashboard passes ----------------------------------
#
# Against the real server binary and the real assets from this checkout, driven
# in a real browser at both a phone width and a desktop width.
#
# The two baseline runs below clear FM_DASHBOARD_BROWSER_FORCE rather than
# inheriting it. An operator who had exported it would otherwise get exit 3
# from an injected run reported here as "the browser check failed against a
# correctly rendering dashboard", and exit 2 from the negative run reported as
# "the check accepted a page that renders nothing" - two conclusions neither
# run reached. The injection cases further down set it explicitly, one per
# invocation.

out=$(FM_DASHBOARD_BROWSER_FORCE='' "$CHECK" --out "$TMP_ROOT/fixture" 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "the browser check failed against a correctly rendering dashboard"$'\n'"$out"

result="$TMP_ROOT/fixture/result.txt"
[ -f "$result" ] || fail "the browser check recorded no per-observation result"

# Every default width, named, because a check that quietly stopped visiting
# the phone width - or either side of the 899/900 navigation boundary, the
# defect that motivated the rebuild - would still pass everything it did run.
assert_contains "$(cat "$result")" "390x844" "the check did not record the phone width"
assert_contains "$(cat "$result")" "899x844" "the check did not record the tab-bar side of the navigation boundary"
assert_contains "$(cat "$result")" "900x844" "the check did not record the rail side of the navigation boundary"
assert_contains "$(cat "$result")" "1440x900" "the check did not record the desktop width"

# The observations the dashboard's own stories rest on. Each is asserted by
# name, so a harness that silently stopped making one of them fails here rather
# than reporting a smaller green run.
for observation in \
  "the dashboard document loaded" \
  "the browser really is at this viewport" \
  "the stylesheet was applied" \
  "the Needs you destination is reachable from the visible navigation" \
  "the Fleet destination is reachable from the visible navigation" \
  "the Backlog destination is reachable from the visible navigation" \
  "the History destination is reachable from the visible navigation" \
  "the Knowledge destination is reachable from the visible navigation" \
  "only the Needs you view is on the page" \
  "only the Fleet view is on the page" \
  "only the Backlog view is on the page" \
  "only the History view is on the page" \
  "only the Knowledge view is on the page" \
  "the Needs you view is legible" \
  "the Fleet view is legible" \
  "the Backlog view is legible" \
  "the History view is legible" \
  "the Knowledge view is legible" \
  "nothing is placed behind a horizontal swipe on Fleet" \
  "opening a task from the Fleet board lands on its detail page alone" \
  "the History view displays the completion records it read" \
  "every completed row shows its usage cell" \
  "no credential-shaped or path-shaped value on any destination" \
  "a live event appears on the open task page without a reload" \
  "the task's earlier events survive unrelated fleet traffic" \
  "unrelated traffic stays off the task's own timeline" \
  "the browser console is clean"
do
  assert_contains "$(cat "$result")" "$observation" "the check stopped observing: $observation"
done

grep -q '^FAIL' "$result" && fail "the check reported a failure on a correctly rendering dashboard"$'\n'"$(cat "$result")"
# The run has to have reconciled the observations it declared against the ones
# it recorded. Without this line the assertions above are satisfied by a run that
# emitted a subset of them under names they happen to match.
assert_contains "$(cat "$result")" "observation set reconciled" \
  "the run did not reconcile its declared observations against the verdicts it recorded"
# An observation the check could not make is not a pass. Against a fixture this
# command starts itself, every one of them is reachable, so a ???? here means
# the harness lost the ability to read some evidence it used to read - which
# would otherwise show up as a quietly smaller green run.
grep -q '^?' "$result" && fail "the check could not verify an observation against a fixture it controls"$'\n'"$(cat "$result")"
pass "the browser check passes against a correctly rendering dashboard at phone, boundary, and desktop widths"

# --- a page that renders nothing fails ---------------------------------------
#
# The deliberate negative. The page served here answers 200 and carries the
# dashboard's own title, so nothing short of looking at what rendered can tell
# it apart from the real thing - which is exactly the failure mode this guards.

negative=$(FM_DASHBOARD_BROWSER_FORCE='' "$CHECK" --negative --out "$TMP_ROOT/negative" 2>&1)
status=$?
[ "$status" -eq 0 ] \
  || fail "the check accepted a page that renders nothing, so it proves nothing"$'\n'"$negative"
assert_contains "$negative" "negative proof PASSED" "the negative proof did not report its verdict"

assert_contains "$negative" "observation set reconciled" \
  "the negative run did not reconcile its declared observations, so its proof rests on an unknown set"

negative_result="$TMP_ROOT/negative/result.txt"
grep -q '^FAIL' "$negative_result" \
  || fail "the negative run recorded no failing observation"$'\n'"$(cat "$negative_result")"

# Named, because "some assertion failed" would still be satisfied by a check
# that had degraded to noticing nothing but a missing title.
for observation in \
  "the page rendered text rather than an empty document" \
  "the stylesheet was applied" \
  "the Fleet destination is reachable from the visible navigation"
do
  grep -q "^FAIL.*$observation" "$negative_result" \
    || fail "the check did not notice this on an empty page: $observation"$'\n'"$(cat "$negative_result")"
done

# And the assertions whose honest answer on an empty page is "there was nothing
# to look at" have to say so, rather than reporting a clean scan of no text, a
# view judged behind an unreachable destination, or a usage cell on no rows.
for observation in \
  "only the Fleet view is on the page" \
  "no credential-shaped or path-shaped value on any destination" \
  "the History view displays the completion records it read" \
  "every completed row shows its usage cell"
do
  grep -q "^?.*$observation" "$negative_result" \
    || fail "the check claimed to have observed this on an empty page: $observation"$'\n'"$(cat "$negative_result")"
done

# The negative proof has to rest on what was recorded, not on what was absent.
# An assertion that never executed is absent from the pass log too, so requiring
# absence alone lets a run that rendered nothing report PASSED - which is how
# this proof once passed on a host whose browser bridge was busy.
for observation in \
  "the page rendered text rather than an empty document" \
  "the stylesheet was applied" \
  "destination is reachable from the visible navigation" \
  "view is on the page" \
  "view rendered with real height" \
  "view is legible" \
  "no credential-shaped or path-shaped value on any destination" \
  "the History view displays the completion records it read" \
  "every completed row shows its usage cell"
do
  grep -qE "^(FAIL|\?\?\?\?) .*$observation" "$negative_result" \
    || fail "the negative proof passed without this assertion recording a refusal of its own: $observation"$'\n'"$(cat "$negative_result")"
done
pass "the browser check refuses a page that answers 200 with the right title and renders nothing"

# --- the failure paths are reachable on demand -------------------------------
#
# --negative proves the assertions can fail as a set, against one broken page.
# It cannot reach a branch that page does not happen to trigger, and reading the
# code and concluding those branches work is not evidence that they do. The
# fault-injection surface is what makes each one executable, so what is pinned
# here is that surface's guardrails: it is inert unless set, a name it does not
# know is refused rather than silently ignored, it will not run alongside the
# negative proof whose meaning it would destroy, and an injected run can never
# be read as a clean check of the dashboard.

out=$(FM_DASHBOARD_BROWSER_FORCE=leek:fail "$CHECK" --out "$TMP_ROOT/typo" 2>&1)
status=$?
[ "$status" -eq 2 ] || fail "a fault-injection entry naming no known check was not refused"$'\n'"$out"
assert_contains "$out" "is not a check and branch this script can force" \
  "the refusal did not say what was wrong with the entry"

out=$(FM_DASHBOARD_BROWSER_FORCE=document:unverified "$CHECK" --out "$TMP_ROOT/branch" 2>&1)
status=$?
[ "$status" -eq 2 ] || fail "a fault-injection entry naming a branch that check does not have was not refused"$'\n'"$out"

out=$(FM_DASHBOARD_BROWSER_FORCE=leak:fail "$CHECK" --negative --out "$TMP_ROOT/both" 2>&1)
status=$?
[ "$status" -eq 2 ] || fail "fault injection was allowed to run alongside the negative proof"$'\n'"$out"

# And a few branches executed for real, at a single width, to prove the
# mechanism reaches each check's own failure branch rather than substituting a
# verdict for it: every detail asserted below is the assertion's own wording,
# not the injector's.
forced=$(FM_DASHBOARD_BROWSER_FORCE=nav:fail "$CHECK" --width 390x844 --out "$TMP_ROOT/forced" 2>&1 </dev/null)
status=$?
[ "$status" -eq 3 ] \
  || fail "an injected run did not exit 3, so its result could be read as a check of the dashboard"$'\n'"$forced"
assert_contains "$forced" "forced: nav:fail" "the injected run did not stamp the branch it forced"
grep -qE "^FAIL .*destination is reachable from the visible navigation - the route has 2 controls but none is visible at this width" \
  "$TMP_ROOT/forced/result.txt" \
  || fail "forcing nav:fail did not run the navigation assertion's own failure branch"$'\n'"$(cat "$TMP_ROOT/forced/result.txt")"

forced=$(FM_DASHBOARD_BROWSER_FORCE=view-present:fail "$CHECK" --width 390x844 --out "$TMP_ROOT/forced-exclusive" 2>&1 </dev/null)
status=$?
[ "$status" -eq 3 ] \
  || fail "forcing view-present:fail did not exit 3, so its result could be read as a check of the dashboard"$'\n'"$forced"
assert_contains "$forced" "forced: view-present:fail" "the injected run did not stamp the branch it forced"
grep -qF "another view is in the DOM beside it rather than absent" "$TMP_ROOT/forced-exclusive/result.txt" \
  || fail "forcing view-present:fail did not run the exclusivity assertion's own failure branch"$'\n'"$(cat "$TMP_ROOT/forced-exclusive/result.txt")"

forced=$(FM_DASHBOARD_BROWSER_FORCE=history:fail "$CHECK" --width 390x844 --out "$TMP_ROOT/forced-history" 2>&1 </dev/null)
status=$?
[ "$status" -eq 3 ] \
  || fail "forcing history:fail did not exit 3, so its result could be read as a check of the dashboard"$'\n'"$forced"
assert_contains "$forced" "forced: history:fail" "the injected run did not stamp the branch it forced"
grep -qF "completion records but the page displays none" "$TMP_ROOT/forced-history/result.txt" \
  || fail "forcing history:fail did not run the history display assertion's own failure branch"$'\n'"$(cat "$TMP_ROOT/forced-history/result.txt")"
pass "each named check's failure path is reachable from outside the script, and an injected run cannot pass for a check"

# --- the observation set is reconciled ----------------------------------------
#
# The two runs above assert that named observations appear, which no amount of
# naming can make exhaustive: the defect being closed here is a mode that emits a
# different set from the one the script and its docs claim it makes, and one such
# mode shipped - the tail observation was emitted nowhere under --url. So the
# check declares its observation set and reconciles it against the verdicts it
# recorded, and that pass is itself a check that could report success without
# checking. These three prove it does not: an observation dropped, one recorded
# twice, and one recorded that was never declared each have to fail the run
# loudly and name the observation at fault.

while IFS='|' read -r fault expected; do
  [ -n "$fault" ] || continue
  # stdin closed, because this loop's own stdin is the case list below and the
  # check drives a browser and a server that have no business reading it.
  out=$(FM_DASHBOARD_BROWSER_FORCE="reconcile:$fault" "$CHECK" \
    --width 390x844 --out "$TMP_ROOT/reconcile-$fault" 2>&1 </dev/null)
  status=$?
  [ "$status" -eq 4 ] \
    || fail "forcing reconcile:$fault did not fail the run as an observation set mismatch (exit $status)"$'\n'"$out"
  assert_contains "$out" "OBSERVATION SET MISMATCH" \
    "forcing reconcile:$fault did not report an observation set mismatch"
  assert_contains "$out" "$expected" \
    "the mismatch report did not name what was wrong with reconcile:$fault"
  grep -Fq "OBSERVATION SET MISMATCH" "$TMP_ROOT/reconcile-$fault/result.txt" \
    || fail "the mismatch was printed but never recorded in result.txt for reconcile:$fault"
done <<'CASES'
drop|missing: no verdict was recorded for [the browser console is clean]
duplicate|duplicate: 2 verdicts were recorded for [the browser console is clean]
undeclared|undeclared: a verdict was recorded for [the injector's invented observation]
CASES
pass "a dropped, duplicated or undeclared observation fails the run by name instead of shrinking the result"
printf '\nall fm-dashboard-browser tests passed\n'
