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

out=$("$CHECK" --out "$TMP_ROOT/fixture" 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "the browser check failed against a correctly rendering dashboard"$'\n'"$out"

result="$TMP_ROOT/fixture/result.txt"
[ -f "$result" ] || fail "the browser check recorded no per-observation result"

# Both widths, named, because a check that quietly stopped visiting the phone
# width would still pass everything it did run.
assert_contains "$(cat "$result")" "390x844" "the check did not record the phone width"
assert_contains "$(cat "$result")" "1440x900" "the check did not record the desktop width"

# The observations the dashboard's own stories rest on. Each is asserted by
# name, so a harness that silently stopped making one of them fails here rather
# than reporting a smaller green run.
for observation in \
  "the dashboard document loaded" \
  "the stylesheet was applied" \
  "nothing is placed behind a horizontal swipe" \
  "the Captain inbox view is legible" \
  "the Board view is legible" \
  "the GBrain view is legible" \
  "the Activity view is legible" \
  "the History view is legible" \
  "no credential-shaped or path-shaped value on the page" \
  "lands on that section's heading" \
  "a live event appears without a reload" \
  "backfilled history survives a subsequent event" \
  "the browser console is clean"
do
  assert_contains "$(cat "$result")" "$observation" "the check stopped observing: $observation"
done

grep -q '^FAIL' "$result" && fail "the check reported a failure on a correctly rendering dashboard"$'\n'"$(cat "$result")"
pass "the browser check passes against a correctly rendering dashboard at phone and desktop widths"

# --- a page that renders nothing fails ---------------------------------------
#
# The deliberate negative. The page served here answers 200 and carries the
# dashboard's own title, so nothing short of looking at what rendered can tell
# it apart from the real thing - which is exactly the failure mode this guards.

negative=$("$CHECK" --negative --out "$TMP_ROOT/negative" 2>&1)
status=$?
[ "$status" -eq 0 ] \
  || fail "the check accepted a page that renders nothing, so it proves nothing"$'\n'"$negative"
assert_contains "$negative" "negative proof PASSED" "the negative proof did not report its verdict"

negative_result="$TMP_ROOT/negative/result.txt"
grep -q '^FAIL' "$negative_result" \
  || fail "the negative run recorded no failing observation"$'\n'"$(cat "$negative_result")"

# Named, because "some assertion failed" would still be satisfied by a check
# that had degraded to noticing nothing but a missing title.
for observation in \
  "the page rendered text rather than an empty document" \
  "the stylesheet was applied" \
  "the Board view is on the page"
do
  grep -q "^FAIL.*$observation" "$negative_result" \
    || fail "the check did not notice this on an empty page: $observation"$'\n'"$(cat "$negative_result")"
done
pass "the browser check refuses a page that answers 200 with the right title and renders nothing"
