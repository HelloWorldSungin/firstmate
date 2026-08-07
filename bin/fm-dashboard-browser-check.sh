#!/usr/bin/env bash
# fm-dashboard-browser-check.sh - drive the real dashboard page in a real
# browser and record what it actually renders.
#
# Every other dashboard test in this repo imports a browser module into node and
# asserts on the data it returns. That proves the module, and it is worth
# keeping. It cannot prove the page: that the document loads at all, that the
# stylesheet and the module graph arrive, that the server-sent event stream
# connects from a browser, that the layout holds at 390 CSS px, that the console
# is clean. This command is the missing half, and it is deliberately a command
# rather than an unconditional test - see "Why this is a command" below.
#
# Usage:
#   fm-dashboard-browser-check.sh [--url <url> --user <name> --password-file <path>]
#                                 [--out <dir>] [--width <w>x<h>]... [--keep]
#                                 [--negative]
#
# Options:
#   --url            check an already-running dashboard instead of a fixture.
#                    With no --url this command starts its OWN dashboard server
#                    from this checkout, on an ephemeral loopback port, over a
#                    throwaway fixture home. It never starts, stops, installs,
#                    reconfigures, or repoints an operator's dashboard service,
#                    and there is no flag that makes it do so.
#   --user           username for --url, when that dashboard authenticates.
#   --password-file  file holding that password and nothing else, and not
#                    readable by other users - the same rule the dashboard
#                    applies to its own credentials file. The password is handed
#                    to bin/fm-dashboard-browser-front.mjs, which holds it in
#                    memory and adds the header the dashboard already requires;
#                    it never enters the URL the browser opens, so it cannot
#                    reach the browser's history or any evidence captured here.
#                    What that front costs is stated in its own header and is
#                    worth reading before using this on a shared host: while it
#                    runs it is an unauthenticated door to the authenticated
#                    dashboard, bound to loopback on an ephemeral port and alive
#                    only for the length of this one check.
#   --out            evidence directory (default: a temp directory, kept and
#                    named on exit). Holds a screenshot and the rendered text of
#                    every view at every width, the console transcript, and
#                    result.txt.
#   --width          a viewport to check, repeatable, as <css-px>x<css-px>.
#                    Default: 390x844 (phone) and 1440x900 (desktop). The phone
#                    width is not an afterthought - this dashboard is read on
#                    one. Naming the same viewport twice is a usage error:
#                    every observation is labelled with its width, so the run
#                    would owe two verdicts for each of them.
#   --keep           leave the fixture server running and print its URL.
#   --negative       prove the check can fail. Runs the identical assertions
#                    against a deliberately broken page and exits non-zero
#                    unless every assertion that reads what rendered is recorded
#                    as FAIL or ???? by name. A check that cannot tell "rendered
#                    correctly" from "rendered nothing" is worse than no check,
#                    so this is how that property stays true rather than being
#                    asserted once and assumed forever.
#
# Environment:
#   FM_DASHBOARD_BROWSER_FORCE
#                    fault injection, for the same purpose --negative serves:
#                    proving these checks can fail, by executing each failure
#                    path rather than reasoning about it. A space- or
#                    comma-separated list of <check>:<branch>, where <branch> is
#                    fail or unverified. Each entry corrupts the one value that
#                    check judges, so the check's OWN branch runs and prints its
#                    OWN detail - nothing here rewrites a verdict after the
#                    fact, and nothing here weakens an assertion when it is
#                    unset, which is the only state an ordinary run has.
#
#                    An injected run cannot be mistaken for a check of the
#                    dashboard: it stamps every forced branch into result.txt,
#                    refuses to run with --negative, and never exits 0 whatever
#                    the page did - 3 for any fault, or 4 when the fault it
#                    injected was one the reconciliation pass below catches.
#
#                    The checks, and the branches each one has:
#
#                      viewport-set:fail    the viewport could not be set
#                      open:fail            the browser refused to open the page
#                      probe:fail           the page could be read
#                      probe:unverified     the page could be measured
#                      document:fail        the dashboard document loaded
#                      viewport:fail        the browser really is at this viewport
#                      text:fail            the page rendered text
#                      stylesheet:fail      the stylesheet was applied
#                      swipe:fail           nothing behind a horizontal swipe
#                      swipe:unverified     ... never measured at this width
#                      view-present:fail    the view is on the page
#                      view-present:unverified
#                      view-height:fail     the view rendered with real height
#                      view-height:unverified
#                      view-legible:fail    the view is legible
#                      view-legible:unverified
#                      leak:fail            a credential- or path-shaped value
#                      leak:unverified      the scan cannot be shown to have run
#                      usage:fail           a completed record with no panel
#                      usage:unverified     no completion record to look at
#                      nav:fail             the link lands under the sticky bar
#                      nav:unverified       the landing could not be read
#                      live-event:fail      the event never reached the page
#                      live-event:unverified
#                      tail:fail            earlier events never left the stream
#                      tail:unverified
#                      backfill:fail        backfilled history was discarded
#                      backfill:unverified
#                      console:fail         the console printed something
#                      console:unverified   a console window could not be read
#                      reconcile:drop       an observation left unrecorded
#                      reconcile:duplicate  one recorded twice
#                      reconcile:undeclared one recorded that was never declared
#
#                    An entry naming a check or a branch that is not in that
#                    list is a usage error, so a typo cannot quietly inject
#                    nothing and leave the operator believing a path was
#                    exercised.
#
#                    Force one branch to a run when the point is to execute
#                    that branch. A list is accepted and every entry in it
#                    does what it says, but one fault can take away another
#                    check's precondition: co-forcing viewport:fail leaves the
#                    swipe check with no width it can trust, so it records
#                    could-not-verify rather than reaching its own failure
#                    branch. That is the swipe check behaving correctly, and it
#                    is also a branch that run did not exercise - so one
#                    batched run is not evidence that every branch named in it
#                    executed.
#
#                    The three reconcile entries are the exception to "corrupts
#                    the one value that check judges", because what the
#                    reconciliation pass judges IS the set of verdicts this run
#                    recorded: a fault in it is an observation dropped, recorded
#                    twice, or recorded without having been declared, so that is
#                    what those three do to the console observation.
#
# Why this is a command and not a test that CI runs
#
#   The two things this drives - a browser and a dashboard service - are shared
#   machine state. chrome-devtools-axi drives ONE Chrome session per host, so
#   two of these running at once fight over the same page, and the standard test
#   suite runs its files in parallel shards. CI has no Chrome at all. Making
#   this an unconditional test would therefore buy a check that is either
#   skipped everywhere it runs or flaky everywhere it does not.
#
#   So the harness is this command, and tests/fm-dashboard-browser.test.sh is a
#   thin opt-in wrapper that runs it end to end, including --negative, when the
#   operator asks for it. The tradeoff accepted: a rendering regression is not
#   caught by an ordinary CI run, and is caught by running this - after a
#   dashboard change, and before believing any claim about what the page shows.
#   The module-level dashboard tests are unaffected and still run everywhere.
#
# What it asserts, and why those things
#
#   The failure this exists to catch is a page that came up empty or broken
#   while something claimed it was fine, so no assertion here is satisfied by a
#   page that loaded. Each view must be present, must have real rendered
#   height, and must contain its own landmark text; the browser must be proven
#   to be at the width the section is named after; the document must carry no
#   sideways scroll at any width, because reaching a fleet signal by horizontal
#   swipe is a defect this dashboard specifically promises against; following a
#   nav link must actually navigate and land the section's heading clear of the
#   sticky bar; every completed record must carry its usage panel; no part of
#   the rendered page - not only the view sections, but the topbar, the notice
#   region that carries a failed command's raw stderr, the sidebar and the
#   report dialog - may contain a credential-shaped or absolute-path-shaped
#   value; and the console must be clean. The fixture run additionally proves the live
#   stream: an event posted while the page is open appears with no reload, and a
#   selected agent's backfilled history survives the next event rather than
#   being discarded with the stream that gets replaced.
#
#   The structural assertions are written against the page's own contract, not
#   against fixture data, so this same command is what you point at a live
#   dashboard. Extending it for a new view means adding a row to VIEWS below.
#
# The four verdicts, and why there are four
#
#   ok    the thing the observation names was seen to happen.
#   FAIL  it was seen not to happen.
#   ????  it could not be observed at all - the probe would not decode, a
#         browser command failed, or the scan cannot be shown to have run.
#   n/a   it does not apply to the thing being checked in this mode, and no
#         run against this target could ever observe it.
#
#   Two verdicts are not enough, because every "I could not read the evidence"
#   path then has to be folded into one of them, and folding it into ok is
#   exactly how a harness comes to rubber-stamp a page nobody looked at. A pass
#   here requires positive evidence that the named thing happened; the absence
#   of a failure signal is not evidence, so an unread source, a swallowed exit
#   status, an empty match on a scan that may never have run, and a discarded
#   eval result all record ???? instead.
#
#   n/a is the fourth because "I could not verify this" and "this does not
#   apply here" are different answers and collapsing them costs the run its
#   signal. ???? means something that should have been observable was not, and
#   it fails the run. n/a means the observation is out of this mode's reach by
#   design - the three live-stream observations under --url, which can only be
#   proved by posting events into a dashboard this command does not own - so it
#   is reported and counted but does not fail the run. Without the distinction
#   --url could never exit 0 however healthy the page was, which would leave
#   the only mode that can be pointed at the shipped dashboard impossible to
#   automate against.
#
# The declared observation set, and why it is reconciled
#
#   Every mode declares up front the observations it makes: the per-width ones
#   once per --width, the three per-view ones and the nav one once per VIEWS row
#   inside each of those, and the live-stream and console ones once for the run.
#   That list is derived from VIEWS and WIDTHS rather than written out, so a new
#   view row or a new width extends it without anyone remembering to.
#
#   Every declared observation must resolve to exactly one verdict, and at the
#   end of every run - fixture, --url, --negative, injected - the declared set is
#   reconciled against the set actually recorded. A declared observation with no
#   verdict, one carrying two, or a verdict for an observation that was never
#   declared is a hard error: it names the offending observation and exits 4. It
#   is deliberately not a warning, not a smaller count, and not a shorter
#   result.txt.
#
#   That pass exists because one defect shape kept recurring here: a verdict
#   emitted with no evidence behind it, evidence emitted with no verdict
#   reconciling it, a proof that passed with no assertion having run, and an
#   observation that produced no verdict at all in one mode while this header
#   claimed both modes observe identically. Nothing structurally guaranteed that
#   the set of observations a mode claims to make equals the set it emits.
#
#   It follows that no path may leave an observation unrecorded. Where this check
#   cannot get far enough at a width to judge - the viewport would not move, the
#   page would not open, the probe would not decode - it records ???? for every
#   remaining observation at that width, saying why, instead of returning with
#   them unrecorded.
#
# Exit status: 0 when nothing failed and nothing was left unverified, 1 when
# any observation is FAIL or ????, 2 on a usage or setup problem, 3 when
# FM_DASHBOARD_BROWSER_FORCE injected a fault, 4 when this run did not emit the
# observation set it declared. An n/a observation never fails the run, so a
# healthy dashboard checked with --url exits 0 with its three live-stream
# observations recorded as n/a; every other observation is made identically in
# both modes. The full per-observation result is printed and written to
# <out>/result.txt either way.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
FRONT="$ROOT/bin/fm-dashboard-browser-front.mjs"
BROWSER=${FM_DASHBOARD_BROWSER_CLI:-chrome-devtools-axi}

# Each row is: <section id>|<label>|<landmark>;<landmark>...
# The landmarks are the view's own furniture - its eyebrow, its heading, the
# controls it owns - so they hold against fixture data and against a live fleet
# alike. A new view is a new row here and nothing else.
VIEWS='inbox|Captain inbox|Captain inbox;Needs you
board|Board|Read-only fleet snapshot;Board;Secondmates;Filters
gbraintron|GBrain|GBrain health and search;Search captured knowledge
activity|Activity|Live agent events;Activity;Filters
history|History|Durable completion records;History;Filters and search'

DEFAULT_WIDTHS='390x844 1440x900'

# The verdict for an observation that could not be made. Counted and reported
# separately from a pass and from a failure, and it fails the run: a check that
# could not look is not a check that saw nothing wrong.
UNVERIFIED='????'

# The verdict for an observation this mode cannot reach by design. Counted and
# reported separately from all three of the others, and it does NOT fail the
# run - it is not a thing that went unobserved through some fault, it is a
# thing there was never anything here to observe.
INAPPLICABLE='n/a'

# styles.css asks for scroll-margin-top: var(--sticky-top) + 12px on every
# scroll target, so a section that was really navigated to lands its heading a
# few pixels below the sticky bar. This is how much further down than that the
# landing may sit and still count as an arrival; anything beyond it is a scroll
# that never finished or never happened.
NAV_LANDING_BAND=48

MODE=fixture
TARGET_URL=
AUTH_USER=
PASSWORD_FILE=
OUT_DIR=
WIDTHS=
KEEP=no
NEGATIVE=no

SERVER_PID=
FRONT_PID=
NEGATIVE_PID=
WORK_DIR=
DIAG_LOG=/dev/null
OK_LOG=
PASSES=0
FAILURES=0
UNVERIFIED_COUNT=0
INAPPLICABLE_COUNT=0
RESULT_FILE=

# The observations this run declares it will make, the ones it has recorded so
# far, and the widths where it could not get far enough to judge. The first two
# are reconciled against each other before the run exits; the third is what
# stops the negative proof reading a width that never rendered as a width whose
# assertions refused the page.
DECLARED_FILE=
EMITTED_LOG=
UNREACHED_WIDTHS=

# Every FM_* variable is cleared for the children this command spawns, and only
# the ones the fixture defines are set again. Populated by fixture_env().
FIXTURE_ENV=(env)

CONSOLE_BASELINE_MSGID=
CONSOLE_READS=0
CONSOLE_TOTAL=0
CONSOLE_UNNAMED=0
CONSOLE_UNREAD=
CONSOLE_PAGE_OPENED=no

# Leak matches seen across the views at the width being checked, reset per
# width by the caller.
ALL_LEAKS=

usage() {
  cat <<'TEXT'
usage: fm-dashboard-browser-check.sh [options]

Drives the real dashboard page in a real browser and records what it renders.

  --url <url>             check an already-running dashboard. With no --url this
                          starts its own server from this checkout on an
                          ephemeral loopback port over a throwaway fixture home,
                          and never touches an installed dashboard service.
  --user <name>           username for --url, when that dashboard authenticates
  --password-file <path>  file holding that password, and not readable by other
                          users; it is held by
                          bin/fm-dashboard-browser-front.mjs and never enters
                          the URL the browser opens
  --out <dir>             evidence directory (default: a temp directory, kept
                          and named on exit)
  --width <w>x<h>         a viewport to check, repeatable
                          (default: 390x844 and 1440x900)
  --keep                  leave the fixture server running
  --negative              prove the check can fail, by running the same
                          assertions against a page that renders nothing

Each observation is recorded as ok, FAIL, ???? or n/a. ???? means it could not
be observed at all, which is not a pass and fails the run. n/a means it does
not apply to the target being checked in this mode, which does not fail the
run; the three live-stream observations are n/a under --url, because proving
them means posting events into a dashboard this command does not own.

Every mode declares the observations it makes and reconciles that list against
what it recorded before it exits, so an observation left unrecorded, recorded
twice, or recorded without having been declared fails the run by name rather
than showing up as a quietly smaller result.

FM_DASHBOARD_BROWSER_FORCE=<check>:<branch>,... forces named checks down their
failure or could-not-verify branch, so each failure path can be executed and
read rather than reasoned about. It is inert unless set, refuses to run with
--negative, and never exits 0. This script's header lists every check and
branch it accepts.

Exit status: 0 when nothing failed and nothing was left unverified, 1 when any
observation is FAIL or ????, 2 on a usage or setup problem, 3 when a fault was
injected, 4 when the run did not emit the observation set it declared. The
per-observation result is written to <out>/result.txt.
TEXT
}

die() {
  printf 'fm-dashboard-browser-check: %s\n' "$1" >&2
  exit 2
}

# The evidence directory is deliberately NOT inside the work directory: the
# fixture server, the scratch probes, and the staged runtime are this command's
# internals and go away, but the screenshots, per-view text, console transcripts
# and result.txt are the point of running it and are still there afterwards at
# the path printed on exit.
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  for pid in "$FRONT_PID" "$NEGATIVE_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  if [ -n "$SERVER_PID" ] && [ "$KEEP" != yes ]; then
    kill "$SERVER_PID" 2>/dev/null
  fi
  [ -n "$WORK_DIR" ] && [ "$KEEP" != yes ] && rm -rf "$WORK_DIR"
  return 0
}
# A signal handler that only cleans up leaves bash resuming the script at the
# interruption point, with the fixture server killed and the work directory
# gone - so a Ctrl-C part way through drives a dead URL for the rest of the run
# and persists an evidence directory full of failures that reads as a broken
# dashboard. Clean up and leave, at the conventional 128+signal status.
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Every value-taking flag is guarded: bash leaves the positional parameters
# untouched and returns non-zero when `shift 2` has nothing to shift, and this
# script is not under `set -e`, so an unguarded shift on a value-less trailing
# flag spins this loop on the same argument forever instead of saying what was
# wrong with the command line.
while [ $# -gt 0 ]; do
  case "$1" in
    --url) [ $# -ge 2 ] || die "--url needs a value"; TARGET_URL=$2; MODE=url; shift 2 ;;
    --user) [ $# -ge 2 ] || die "--user needs a value"; AUTH_USER=$2; shift 2 ;;
    --password-file) [ $# -ge 2 ] || die "--password-file needs a value"; PASSWORD_FILE=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || die "--out needs a value"; OUT_DIR=$2; shift 2 ;;
    --width) [ $# -ge 2 ] || die "--width needs a value"; WIDTHS="${WIDTHS} $2"; shift 2 ;;
    --keep) KEEP=yes; shift ;;
    --negative) NEGATIVE=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

is_number() {  # <candidate>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_integer() {  # <candidate>, which may be negative
  case "${1:-}" in
    ''|-) return 1 ;;
    -*) is_number "${1#-}" ;;
    *) is_number "$1" ;;
  esac
}

[ -n "$WIDTHS" ] || WIDTHS=$DEFAULT_WIDTHS
# A viewport this check cannot parse is a usage error, not something to hand to
# the browser and then measure against: the width assertion below compares the
# page's own innerWidth with the number named here.
#
# A width named twice is a usage error too. Every observation is labelled with
# its width, so the same width twice means every observation at it resolves to
# two verdicts, which the reconciliation pass at the end refuses by design -
# saying so here names the real mistake instead.
SEEN_WIDTHS=
for spec in $WIDTHS; do
  case "$spec" in
    *x*) ;;
    *) die "--width takes <css-px>x<css-px>, not [$spec]" ;;
  esac
  if ! is_number "${spec%%x*}" || ! is_number "${spec#*x}"; then
    die "--width takes <css-px>x<css-px>, not [$spec]"
  fi
  case " $SEEN_WIDTHS " in
    *" $spec "*) die "--width $spec was given twice; each viewport is checked once" ;;
  esac
  SEEN_WIDTHS="${SEEN_WIDTHS} $spec"
done

for tool in node curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
command -v "$BROWSER" >/dev/null 2>&1 \
  || die "$BROWSER is required to drive a real browser (set FM_DASHBOARD_BROWSER_CLI to name another)"
[ -n "$PASSWORD_FILE" ] && [ -z "$AUTH_USER" ] && die "--password-file needs --user"
[ "$MODE" = fixture ] && [ -n "$PASSWORD_FILE" ] && die "--password-file only applies with --url"

# --- fault injection ---------------------------------------------------------
#
# Every branch below is written to be reachable, and reasoning about a failure
# path is not evidence that it works. This is how an operator executes one and
# reads what came out.
#
# Each entry names a check and one of its branches, and takes effect by
# corrupting the single value that check judges - the measured width, the
# scanned character count, the landing offset. The check's own branch then runs
# and prints its own detail, so what is recorded is what a real failure of that
# check would record, not a verdict substituted afterwards. Every pair this
# supports is listed here, and an entry that is not in the list is a usage
# error rather than a silent no-op.
FORCE_PAIRS='viewport-set:fail
open:fail
probe:fail
probe:unverified
document:fail
viewport:fail
text:fail
stylesheet:fail
swipe:fail
swipe:unverified
view-present:fail
view-present:unverified
view-height:fail
view-height:unverified
view-legible:fail
view-legible:unverified
leak:fail
leak:unverified
usage:fail
usage:unverified
usage:tokens
usage:operational
nav:fail
nav:unverified
live-event:fail
live-event:unverified
tail:fail
tail:unverified
backfill:fail
backfill:unverified
console:fail
console:unverified
reconcile:drop
reconcile:duplicate
reconcile:undeclared'

FORCE_SPEC=
for entry in $(printf '%s' "${FM_DASHBOARD_BROWSER_FORCE:-}" | tr ',' ' '); do
  printf '%s\n' "$FORCE_PAIRS" | grep -Fxq "$entry" \
    || die "FM_DASHBOARD_BROWSER_FORCE: [$entry] is not a check and branch this script can force; see its header for the list"
  FORCE_SPEC="${FORCE_SPEC} $entry"
done
[ -n "$FORCE_SPEC" ] && [ "$NEGATIVE" = yes ] \
  && die "--negative proves these assertions can fail; FM_DASHBOARD_BROWSER_FORCE makes them fail, so the two together prove nothing"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-browser.XXXXXX") || die "could not create a work directory"
DIAG_LOG="$WORK_DIR/diagnostics.log"
OK_LOG="$WORK_DIR/passed.txt"
: > "$DIAG_LOG"
: > "$OK_LOG"
if [ -z "$OUT_DIR" ]; then
  OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-browser-evidence.XXXXXX") \
    || die "could not create an evidence directory"
fi
mkdir -p "$OUT_DIR" || die "could not create the evidence directory $OUT_DIR"
RESULT_FILE="$OUT_DIR/result.txt"
: > "$RESULT_FILE"
DECLARED_FILE="$WORK_DIR/declared.txt"
EMITTED_LOG="$WORK_DIR/emitted.txt"
: > "$EMITTED_LOG"

# --- the declared observation set --------------------------------------------
#
# What this run says it will observe, in the order it observes it, derived from
# VIEWS and WIDTHS so that a new view row or a new width extends it on its own.
# reconcile_observations() below requires the recorded set to equal this one
# exactly, which is what stops any mode from quietly emitting a different set
# from the one this script and its documentation claim it makes.
#
# --negative genuinely observes a different set and says so here: it exits after
# the widths, before the live stream and the console, because the property it
# proves is about the assertions that read what rendered.
declared_observations() {
  local spec id name _landmarks
  for spec in $WIDTHS; do
    printf '%s: the dashboard document loaded\n' "$spec"
    printf '%s: the browser really is at this viewport\n' "$spec"
    printf '%s: the page rendered text rather than an empty document\n' "$spec"
    printf '%s: the stylesheet was applied\n' "$spec"
    printf '%s: nothing is placed behind a horizontal swipe\n' "$spec"
    while IFS='|' read -r id name _landmarks; do
      [ -n "$id" ] || continue
      printf '%s: the %s view is on the page\n' "$spec" "$name"
      printf '%s: the %s view rendered with real height\n' "$spec" "$name"
      printf '%s: the %s view is legible\n' "$spec" "$name"
    done <<VIEWROWS
$VIEWS
VIEWROWS
    printf '%s: no credential-shaped or path-shaped value on the page\n' "$spec"
    printf '%s: every completed record shows its usage panel\n' "$spec"
    printf '%s: collected usage shows token totals where attributed\n' "$spec"
    while IFS='|' read -r id name _landmarks; do
      [ -n "$id" ] || continue
      printf '%s: the %s link lands on that section'"'"'s heading\n' "$spec" "$name"
    done <<NAVROWS
$VIEWS
NAVROWS
  done
  [ "$NEGATIVE" = yes ] && return 0
  printf 'a live event appears without a reload\n'
  printf 'the agent'"'"'s earlier events really did leave the live stream\n'
  printf 'backfilled history survives a subsequent event\n'
  printf 'the browser console is clean\n'
  return 0
}

declared_observations > "$DECLARED_FILE" || die "could not declare the observation set"
[ -s "$DECLARED_FILE" ] || die "the declared observation set came out empty"

record() {  # <ok|FAIL|????|n/a> <observation> [detail]
  local verdict=$1 observation=$2 detail=${3:-}
  case "$verdict" in
    ok)
      PASSES=$((PASSES + 1))
      printf '%s\n' "$observation" >> "$OK_LOG"
      ;;
    FAIL) FAILURES=$((FAILURES + 1)) ;;
    "$INAPPLICABLE") INAPPLICABLE_COUNT=$((INAPPLICABLE_COUNT + 1)) ;;
    *) UNVERIFIED_COUNT=$((UNVERIFIED_COUNT + 1)) ;;
  esac
  printf '%s\n' "$observation" >> "$EMITTED_LOG"
  printf '%-4s %s%s\n' "$verdict" "$observation" "${detail:+ - $detail}" | tee -a "$RESULT_FILE"
}

# Every declared observation at this width that has not been recorded yet, as
# ???? with the reason the run could not reach it.
#
# This is what the early returns in check_width use instead of returning with
# the rest of the width unrecorded. A width that could not be rendered and read
# is not a width with fewer observations - it is a width whose observations
# could not be made, and each one has to say so under its own name.
record_unreached() {  # <label> <reason>
  local label=$1 reason=$2 observation
  UNREACHED_WIDTHS="${UNREACHED_WIDTHS}${UNREACHED_WIDTHS:+, }$label"
  while IFS= read -r observation; do
    case "$observation" in
      "$label: "*) ;;
      *) continue ;;
    esac
    grep -Fxq "$observation" "$EMITTED_LOG" && continue
    record "$UNVERIFIED" "$observation" "$reason"
  done < "$DECLARED_FILE"
}

note() {  # <line>
  printf '     %s\n' "$1" | tee -a "$RESULT_FILE"
}

# 0 when FM_DASHBOARD_BROWSER_FORCE asked for this check's branch, and it says
# so in the record on the way past, so no forced verdict can be quoted out of
# result.txt as an observation of the page. Inert - and cheap - when the
# variable is unset, which is the only state an ordinary run has.
forced() {  # <check> <branch>
  [ -n "$FORCE_SPEC" ] || return 1
  case " $FORCE_SPEC " in
    *" $1:$2 "*) note "forced: $1:$2 (FM_DASHBOARD_BROWSER_FORCE)"; return 0 ;;
  esac
  return 1
}

summarize() {
  local inapplicable=
  [ "$INAPPLICABLE_COUNT" -gt 0 ] && inapplicable=", $INAPPLICABLE_COUNT not applicable to this target"
  printf '\n%s passed, %s failed, %s could not be verified%s\n' \
    "$PASSES" "$FAILURES" "$UNVERIFIED_COUNT" "$inapplicable" | tee -a "$RESULT_FILE"
}

# The declared set against the recorded one, in every mode, before this command
# exits. Non-zero when they differ, and it names every difference.
#
# The counts alone would not do it, for the same reason an empty leak list means
# nothing without its coverage: a dropped observation and an undeclared one
# cancel out in a total. So each declared line is looked for by name and each
# recorded line is looked up in the declaration.
reconcile_observations() {
  local report declared recorded
  report=$(awk '
    NR == FNR { declared[$0] = 1; order[++count] = $0; next }
    { emitted[$0] += 1 }
    END {
      for (index_ = 1; index_ <= count; index_ += 1) {
        line = order[index_]
        if (!(line in emitted)) {
          printf "missing: no verdict was recorded for [%s]\n", line
        } else if (emitted[line] > 1) {
          printf "duplicate: %d verdicts were recorded for [%s]\n", emitted[line], line
        }
      }
      for (line in emitted) {
        if (!(line in declared)) {
          printf "undeclared: a verdict was recorded for [%s], which this run never declared\n", line
        }
      }
    }
  ' "$DECLARED_FILE" "$EMITTED_LOG")
  declared=$(grep -c . "$DECLARED_FILE")
  recorded=$(grep -c . "$EMITTED_LOG" || true)
  if [ -n "$report" ]; then
    {
      printf '\nOBSERVATION SET MISMATCH: this run did not make the observations it declares.\n'
      printf '%s\n' "$report"
      printf '%s observations declared, %s verdicts recorded - the result above is not a complete check and must not be read as one.\n' \
        "$declared" "$recorded"
    } | tee -a "$RESULT_FILE"
    return 1
  fi
  printf 'observation set reconciled: all %s declared observations recorded exactly once\n' \
    "$declared" | tee -a "$RESULT_FILE"
  return 0
}

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

# curl against a loopback port this command just opened, with the operator's
# proxy configuration out of the way. An exported http_proxy or ALL_PROXY sends
# these requests to a proxy that knows nothing about an ephemeral fixture port,
# and the run then records FAIL "the fixture dashboard refused the event" - a
# true verdict about the wrong thing. Every curl here talks to 127.0.0.1 and to
# nothing else, so there is no case in which a proxy is wanted.
fixture_curl() {  # <curl argument>...
  curl --noproxy '*' "$@"
}

# The environment the fixture server and its helpers run in.
#
# FM_HOME, the port, the address, auth, the poll intervals and the events config
# were always pinned, but every OTHER FM_* variable in the operator's shell
# reached the server - and reached every helper the server spawns, because it
# passes its own environment down to each of them. One exported
# FM_DASHBOARD_EVENTS=off is enough: the event bus disables itself, POST /events
# answers 401, and the run records FAIL for "a live event appears without a
# reload" against perfectly correct code. FM_DASHBOARD_USAGE=off reaches the
# usage panel the same way, FM_DASHBOARD_EVENT_MAX_ROWS_PER_TASK reaches the
# backfill assertion, and FM_DATA_OVERRIDE would put the fixture's completion
# records somewhere other than the throwaway home.
#
# So the whole FM_* namespace is cleared for the children this command spawns and
# only what the fixture itself defines is set again. Everything else then resolves
# to the server's own documented defaults, which is what a throwaway home is
# supposed to be checked against. Clearing by prefix rather than by a list means
# a variable added to the server later is covered without this needing to know
# its name.
fixture_env() {
  local name
  FIXTURE_ENV=(env)
  for name in $(env | sed -n 's/^\(FM_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u); do
    FIXTURE_ENV+=(-u "$name")
  done
}

# --- fixture dashboard ------------------------------------------------------
#
# A real server binary from this checkout, over a throwaway home, with a
# snapshot command that returns fixture data. The point is a page whose content
# is known in advance, so "the board rendered" can be checked against what the
# board was given rather than against whatever the fleet happens to be doing.

EVENT_TOKEN=0123456789abcdef0123456789abcdef

write_fixture_snapshot() {  # <path>
  cat > "$1" <<'JSON'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-08-07T00:00:00Z",
  "tasks": [
    {
      "id": "fixture-ship",
      "kind": "ship",
      "project": "firstmate",
      "harness": "claude",
      "model": "claude-opus-5",
      "effort": "high",
      "backlog": {"title": "Land the browser check"},
      "current_state": {"state": "working", "detail": "Implementing the harness"},
      "endpoint": {"exists": true, "status": "alive"},
      "paths": {"status_log": {"last_event_age_seconds": 12}},
      "pr": {"url": "https://github.com/HelloWorldSungin/firstmate/pull/64"},
      "work_items": [],
      "card": {"rank": 8, "column": "active", "action": "supervise", "reason": "contract-defined"}
    },
    {
      "id": "fixture-scout",
      "kind": "scout",
      "project": "firstmate",
      "harness": "claude",
      "model": "claude-opus-5",
      "effort": "xhigh",
      "backlog": {"title": "Investigate the empty board"},
      "current_state": {"state": "needs_decision", "detail": "Two viable layouts"},
      "endpoint": {"exists": true, "status": "alive"},
      "paths": {"status_log": {"last_event_age_seconds": 40}},
      "pr": {"url": null},
      "work_items": [],
      "card": {"rank": 10, "column": "needs_decision", "action": "decide", "reason": "contract-defined"}
    },
    {
      "id": "fixture-mate",
      "kind": "secondmate",
      "project": "",
      "harness": "codex",
      "model": "gpt-5.6-terra",
      "effort": "medium",
      "current_state": {"state": "idle", "detail": "Standing by"},
      "endpoint": {"exists": true, "status": "alive"},
      "paths": {"status_log": {"last_event_age_seconds": 30}},
      "work_items": [],
      "card": {"rank": 9, "column": "secondmate", "action": "route_work", "reason": "contract-defined"}
    }
  ],
  "card_precedence": ["needs_decision","blocked","parked","failed","review","done","waiting","active","secondmate","idle"],
  "supervision": {"watcher":{"present":true,"age_seconds":3,"stale":false},"afk":{"active":false}}
}
JSON
}

# A completed task recorded the way a real one is, published through the real
# manifest writer, so the History view is reading the format it reads in
# production rather than something shaped like it.
seed_completed_task() {  # <home> <id> <kind> <title> [pr-url]
  local home=$1 id=$2 kind=$3 title=$4 pr=${5:-}
  mkdir -p "$home/state" "$home/data/$id"
  {
    printf 'window=%s\n' "fm:$id"
    printf 'kind=%s\n' "$kind"
    printf 'project=firstmate\n'
    printf 'harness=claude\n'
    printf 'model=claude-opus-5\n'
    printf 'effort=high\n'
    printf 'mode=no-mistakes\n'
    printf 'yolo=off\n'
    printf 'backend=tmux\n'
    [ -n "$pr" ] && printf 'pr=%s\n' "$pr"
  } > "$home/state/$id.meta"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf 'working: started\ndone: finished\n' > "$home/state/$id.status"
  printf -- '- [x] %s - %s (since 2026-08-01)\n' "$id" "$title" >> "$home/data/backlog.md"
  "${FIXTURE_ENV[@]}" FM_HOME="$home" "$ROOT/bin/fm-outcome-manifest.sh" write "$id" >/dev/null 2>&1 \
    || die "could not publish the fixture completion record for $id"
}

build_fixture() {
  local runtime home
  fixture_env
  runtime="$WORK_DIR/runtime"
  home="$WORK_DIR/home"
  mkdir -p "$runtime" "$home/data" "$home/state" "$home/projects" "$WORK_DIR/control"
  # The server resolves every command it runs - the snapshot, the completion
  # manifests, usage, GBrain health - relative to its own directory, so the
  # whole tracked tree is staged and only the two commands this check wants to
  # hold still are replaced below. Staging less would mean discovering, one
  # missing helper at a time, which of them the server happens to need.
  cp -R "$ROOT/bin" "$ROOT/assets" "$runtime/" || die "could not stage the dashboard runtime"
  write_fixture_snapshot "$WORK_DIR/control/snapshot.json"

  cat > "$runtime/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat "${DASH_CHECK_CONTROL:?}/snapshot.json"
SH
  chmod +x "$runtime/bin/fm-fleet-snapshot.sh"

  # A brain that answers, so the GBrain panel renders its full strip rather
  # than the single "no brain configured" card. Both are legitimate states; the
  # populated one is the one worth looking at in a browser. The health fields
  # sit at the top level beside the schema, which is the shape
  # bin/fm-gbrain-health.sh emits and the shape the dashboard reads - nesting
  # them under a "health" key renders the unconfigured card instead.
  cat > "$runtime/bin/fm-gbrain-health.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat <<'JSON'
{
  "schema": "fm-gbrain-health.v1",
  "generated": "2026-08-07T00:00:00Z",
  "home": "fixture",
  "configured": true,
  "version": "0.9.3",
  "index": {"state": "ok", "detail": "index present"},
  "capture": {"enabled": true, "archived": 12, "pending": 1, "failed": 0, "unreadable": 0,
              "last_capture_at": "2026-08-06T22:00:00Z", "last_error": null, "detail": "capture on"},
  "retrieval": {"state": "ok",
    "embedding": {"state": "ok", "model": "snowflake-arctic-embed2", "endpoint": "local", "detail": "reachable"},
    "reranker": {"state": "ok", "model": "bge-reranker", "endpoint": "local", "detail": "reachable"},
    "main_brain": {"state": "same-as-local", "model": null, "endpoint": null, "detail": "this home is the main brain"}},
  "synthesis": {"state": "ok", "model": "hosted", "endpoint": "hosted", "detail": "reachable"},
  "maintenance": {"state": "ready", "detail": "no maintenance window"}
}
JSON
SH
  chmod +x "$runtime/bin/fm-gbrain-health.sh"

  seed_completed_task "$home" "fixture-done-ship" ship "Ship the foldable layout" \
    "https://github.com/HelloWorldSungin/firstmate/pull/58"
  seed_completed_task "$home" "fixture-done-scout" scout "Investigate the merge poll"

  printf '{"schema":"fm-dashboard-events-config.v1","url":"http://127.0.0.1:%s/events","token":"%s"}\n' \
    "$FIXTURE_PORT" "$EVENT_TOKEN" > "$WORK_DIR/dashboard-events.json"

  "${FIXTURE_ENV[@]}" \
    FM_HOME="$home" \
    FM_DASHBOARD_PORT="$FIXTURE_PORT" \
    FM_DASHBOARD_ADDRESS=127.0.0.1 \
    FM_DASHBOARD_AUTH=off \
    FM_DASHBOARD_POLL_SECONDS=1 \
    FM_DASHBOARD_TIMEOUT_SECONDS=10 \
    FM_DASHBOARD_HISTORY_POLL_SECONDS=3 \
    FM_DASHBOARD_EVENTS_CONFIG="$WORK_DIR/dashboard-events.json" \
    FM_DASHBOARD_EVENT_DB="$WORK_DIR/events.db" \
    DASH_CHECK_CONTROL="$WORK_DIR/control" \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$WORK_DIR/server.log" 2>&1 &
  SERVER_PID=$!

  local _
  for _ in $(seq 1 60); do
    if fixture_curl -fsS -o /dev/null "http://127.0.0.1:$FIXTURE_PORT/api/snapshot" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  die "the fixture dashboard did not start: $(cat "$WORK_DIR/server.log")"
}

post_event() {  # <task> <type> <tool>
  fixture_curl -fsS -o /dev/null -X POST "http://127.0.0.1:$FIXTURE_PORT/events" \
    -H "Authorization: Bearer $EVENT_TOKEN" \
    -H "X-Firstmate-Source: $1/claude" \
    -H "Content-Type: application/json" \
    -d "{\"schema\":\"fm-agent-event.v1\",\"events\":[{\"event_id\":\"$3\",\"task_id\":\"$1\",\"harness\":\"claude\",\"type\":\"$2\",\"tool\":\"$3\",\"occurred_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}"
}

# One request carrying <count> events, used only to push earlier events out of
# the dashboard's bounded fleet-wide tail. The server caps a batch, so the
# caller sends several of these rather than one large one.
post_event_batch() {  # <task> <prefix> <count>
  local task=$1 prefix=$2 count=$3 body
  # shellcheck disable=SC2016  # the node program interpolates its own argv, not the shell's
  body=$(node -e '
    const [task, prefix, count] = process.argv.slice(1);
    const at = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    const events = Array.from({ length: Number(count) }, (unused, index) => ({
      event_id: `${prefix}-${index}`,
      task_id: task,
      harness: "claude",
      type: "tool_started",
      tool: `${prefix}-${index}`,
      occurred_at: at,
    }));
    process.stdout.write(JSON.stringify({ schema: "fm-agent-event.v1", events }));
  ' "$task" "$prefix" "$count")
  fixture_curl -fsS -o /dev/null -X POST "http://127.0.0.1:$FIXTURE_PORT/events" \
    -H "Authorization: Bearer $EVENT_TOKEN" \
    -H "X-Firstmate-Source: $task/claude" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# --- browser -----------------------------------------------------------------

browser() {
  "$BROWSER" "$@" 2>&1
}

# chrome-devtools-axi prints `result: <json>` for an eval, and every probe below
# returns a JSON string, so what is printed is JSON wrapped around JSON. How
# many times it is wrapped is the browser tool's business and has changed
# between its versions, so this unwraps until it stops being a string rather
# than assuming a depth. A value that never stops being a string is a failure,
# not something to hand on as if it had decoded.
browser_eval() {  # <js-expression> <destination> <object|text>
  local expression=$1 destination=$2 want=$3 raw
  raw=$(browser eval "$expression") || return 1
  printf '%s\n' "$raw" | node -e '
    const want = process.argv[1];
    const chunks = [];
    process.stdin.on("data", (chunk) => chunks.push(chunk));
    process.stdin.on("end", () => {
      const text = chunks.join("");
      const line = text.split("\n").find((candidate) => candidate.startsWith("result: "));
      if (!line) { process.stderr.write(text); process.exit(1); }
      let value;
      try { value = JSON.parse(line.slice("result: ".length)); } catch { process.exit(1); }
      // Unwrap until the value stops being a string, keeping the last string
      // seen: a text probe wants that string, an object probe wants what it
      // decodes to.
      let previous = value;
      for (let depth = 0; depth < 4 && typeof value === "string"; depth += 1) {
        let next;
        try { next = JSON.parse(value); } catch { break; }
        previous = value;
        value = next;
      }
      if (want === "text") {
        process.stdout.write(typeof value === "string" ? value : previous);
        return;
      }
      if (value === null || typeof value !== "object") process.exit(1);
      process.stdout.write(JSON.stringify(value));
    });
  ' "$want" > "$destination" 2>>"$DIAG_LOG" || return 1
  [ -s "$destination" ]
}

browser_eval_json() {  # <js-expression> <destination>
  browser_eval "$1" "$2" object
}

browser_eval_text() {  # <js-expression> <destination>
  browser_eval "$1" "$2" text
}

# Reads named values out of a probe result as `<alias>=<value>` lines, and
# returns non-zero when any of them is absent or null.
#
# That distinction is the whole point, and it is the one the old permissive
# reader did not make: a read that failed and a field that is legitimately empty
# printed the same empty string, so every caller that treated "" as "nothing
# wrong" reported a pass on a probe it had never successfully read. Here a
# failed read is a non-zero status and the caller records ???? for it; only a
# value that was actually present comes back on stdout.
probe_fields() {  # <file> <alias>=<dotted.path>...
  local file=$1
  shift
  # shellcheck disable=SC2016  # the node program interpolates its own argv, not the shell's
  node -e '
    const file = process.argv[1];
    const data = JSON.parse(require("node:fs").readFileSync(file, "utf8"));
    const lines = [];
    for (const request of process.argv.slice(2)) {
      const split = request.indexOf("=");
      const alias = request.slice(0, split);
      const path = request.slice(split + 1);
      const value = path.split(".").reduce(
        (node, key) => (node === null || node === undefined ? undefined : node[key]), data);
      if (value === undefined || value === null) {
        process.stderr.write(`${file}: no value at ${path}\n`);
        process.exit(1);
      }
      const flat = Array.isArray(value) ? value.join(", ") : String(value);
      lines.push(`${alias}=${flat.replace(/[\r\n]+/g, " ")}`);
    }
    process.stdout.write(lines.join("\n"));
  ' "$file" "$@" 2>>"$DIAG_LOG"
}

# --- assertions --------------------------------------------------------------

# Values that must never be on the page. Absolute paths and credential shapes
# are the two the dashboard's own redaction is written against, so this is the
# rendered-page end of that guarantee. These are evaluated as JavaScript regular
# expressions inside the page.
LEAK_PATTERNS='/home/;/root/;/etc/;-----BEGIN;sk-[A-Za-z0-9];gh[pousr]_[A-Za-z0-9];github_pat_;glpat-;xox[abprs]-;AKIA[A-Z0-9];AIza[A-Za-z0-9]'
LEAK_PATTERN_COUNT=$(printf '%s' "$LEAK_PATTERNS" | tr ';' '\n' | grep -c .)

count_landmarks() {  # <semicolon-separated landmarks>
  printf '%s' "${1:-}" | tr ';' '\n' | grep -c . || true
}

# The one probe every observation at a width is read from.
#
# Every judgment about text - which landmarks are present, whether anything
# leak-shaped is on the page - is made INSIDE the page and comes back as a short
# list, rather than shipping the rendered text out to be searched here. That is
# not an optimization, and it is not a workaround for a limit either: the
# browser tool truncates an eval result at about 8000 characters and says so,
# offering --full to lift it, so a probe that shipped the text out could be made
# to work. It is that a verdict is a fixed small result whatever the fleet is
# doing, so it cannot be broken by page size at all, while a probe returning the
# rendered text sits a page growth away from coming back truncated on exactly
# the pages worth checking - and a check that breaks on real data and works on
# fixtures is the failure this whole command exists to end.
#
# The counts alongside each verdict are what make the verdict readable as
# evidence: how many landmarks this view was actually asked about, how many leak
# patterns compiled, how many characters they ran over, how many completion
# records were on the page. An empty "missing" list means nothing at all unless
# something was checked, so the caller requires those counts before it will
# read an empty list as a pass.
build_probe_js() {
  # shellcheck disable=SC2016  # the node program interpolates its own argv, not the shell's
  node -e '
    const views = process.argv[1].trim().split("\n").map((row) => {
      const [id, name, landmarks] = row.split("|");
      return { id, name, landmarks: (landmarks || "").split(";").filter(Boolean) };
    });
    const leaks = process.argv[2].split(";").filter(Boolean);
    process.stdout.write(`() => {
      const config = ${JSON.stringify({ views, leaks })};
      const doc = document.documentElement;
      const style = getComputedStyle(doc);
      const patterns = [];
      for (const source of config.leaks) {
        try { patterns.push({ source, expression: new RegExp(source) }); } catch { /* only a pattern that compiles is one this scan ran */ }
      }
      const historyCards = [...document.querySelectorAll("#history .history-card")];
      // The whole rendered page, because that is what the observation claims.
      // The five view sections are not all of it: the notice region, the
      // topbar, the sidebar and the report dialog all sit outside them, and
      // the notice region is where a failed snapshot command'"'"'s raw stderr is
      // rendered - the likeliest carrier of an absolute host path anywhere on
      // the page. The per-view lists below stay, for attribution.
      const bodyText = document.body.innerText;
      const out = {
        title: document.title,
        bodyTextLength: bodyText.length,
        clientWidth: doc.clientWidth,
        scrollWidth: doc.scrollWidth,
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        background: getComputedStyle(document.body).backgroundColor,
        // Defined by the dashboard'"'"'s own stylesheet and by nothing else on
        // the page, so a painted body that lacks it is some other stylesheet.
        gutter: style.getPropertyValue("--gutter").trim(),
        // Chrome renders its own error document, with a 200 from the tool'"'"'s
        // point of view, when the server is not there to answer.
        errorPage: document.getElementById("main-frame-error") !== null,
        historyCards: historyCards.length,
        usagePanels: historyCards.filter((card) => {
          const panel = card.querySelector(".usage-panel");
          return panel !== null && panel.innerText.includes("USAGE");
        }).length,
        usageTokenPanels: historyCards.filter((card) => {
          const total = card.querySelector(".usage-total");
          return total !== null && /\\btokens\\b/i.test(total.textContent);
        }).length,
        usageOperationalPanels: historyCards.filter((card) => card.querySelector(".usage-panel.operational") !== null).length,
        leakPatterns: patterns.length,
        leakChars: bodyText.length,
        pageLeaks: patterns.filter((pattern) => pattern.expression.test(bodyText)).map((pattern) => pattern.source),
        views: {},
      };
      for (const view of config.views) {
        const element = document.getElementById(view.id);
        if (!element) { out.views[view.id] = { present: false }; continue; }
        const box = element.getBoundingClientRect();
        const text = element.innerText;
        const lower = text.toLowerCase();
        out.views[view.id] = {
          present: true,
          height: Math.round(box.height),
          textLength: text.length,
          landmarksChecked: view.landmarks.length,
          missing: view.landmarks.filter((landmark) => !lower.includes(landmark.toLowerCase())),
          leaks: patterns.filter((pattern) => pattern.expression.test(text)).map((pattern) => pattern.source),
        };
      }
      return JSON.stringify(out);
    }`);
  ' "$VIEWS" "$LEAK_PATTERNS"
}

# A bounded slice of each view, saved so a human can read what the check saw.
# Evidence only - nothing is asserted from it, so the bound costs no coverage.
capture_view_text() {  # <label> <view id>
  browser_eval_text "() => document.getElementById('$2') ? document.getElementById('$2').innerText.slice(0, 2000) : ''" \
    "$OUT_DIR/text-$1-$2.txt" 2>/dev/null || true
}

check_width() {  # <width> <height>
  local width=$1 height=$2 label="${1}x${2}" probe scalars key value
  probe="$OUT_DIR/probe-${width}x${height}.json"

  # A viewport that would not move is a failure of the observation that the
  # browser really is at this width, and every other observation at this width
  # is one this run could not make - not one it may leave unrecorded.
  if forced viewport-set fail || ! browser resize "$width" "$height" > "$OUT_DIR/resize-$label.txt"; then
    record FAIL "$label: the browser really is at this viewport" \
      "the viewport could not be set to ${width}x${height}"
    record_unreached "$label" \
      "the browser was never placed at this viewport, so nothing here was measured at $width"
    return
  fi
  # Opening is a navigation too, so the bucket standing before it is read
  # first - but only once this run has opened a page of its own. Before that
  # the bucket belongs to whatever the shared browser was showing beforehand,
  # which the baseline read has already accounted for.
  [ "$CONSOLE_PAGE_OPENED" = yes ] && console_collect "$label-before-open"
  # The browser tool answers 0 and renders Chrome's own error document when the
  # server is not there, so this guard catches the tool failing and nothing
  # else. What actually catches an unreachable page is the error-page marker
  # read out of the probe below, and after that the title and the measurements.
  if forced open fail || ! browser open "$PAGE_URL" > "$OUT_DIR/open-$label.txt"; then
    record FAIL "$label: the dashboard document loaded" "the browser refused to open the page"
    record_unreached "$label" "the page never opened, so nothing here was read"
    return
  fi
  CONSOLE_PAGE_OPENED=yes
  # The page fills itself from its first snapshot poll and its history poll, so
  # give both a chance to land before reading it.
  sleep 4

  # Read the load and render window here rather than only in check_navigation,
  # because every path out of this function below can return early and the
  # first nav click would then be the thing that discards it unread.
  console_collect "$label-load"

  if forced probe fail || ! browser_eval_json "$(build_probe_js)" "$probe"; then
    record_unreached "$label" \
      "the probe returned nothing the browser could decode, so nothing at this width was judged"
    return
  fi

  local title body_length inner_width inner_height client_width scroll_width
  local background gutter error_page history_cards usage_panels usage_token_panels usage_operational_panels leak_patterns leak_chars page_leaks
  if forced probe unverified || ! scalars=$(probe_fields "$probe" \
    title=title bodyTextLength=bodyTextLength innerWidth=innerWidth innerHeight=innerHeight \
    clientWidth=clientWidth scrollWidth=scrollWidth background=background gutter=gutter \
    errorPage=errorPage historyCards=historyCards usagePanels=usagePanels \
    usageTokenPanels=usageTokenPanels usageOperationalPanels=usageOperationalPanels \
    leakPatterns=leakPatterns leakChars=leakChars pageLeaks=pageLeaks); then
    record_unreached "$label" \
      "the probe result carried none of the measurements this check reads, so nothing at this width was judged"
    return
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      title) title=$value ;;
      bodyTextLength) body_length=$value ;;
      innerWidth) inner_width=$value ;;
      innerHeight) inner_height=$value ;;
      clientWidth) client_width=$value ;;
      scrollWidth) scroll_width=$value ;;
      background) background=$value ;;
      gutter) gutter=$value ;;
      errorPage) error_page=$value ;;
      historyCards) history_cards=$value ;;
      usagePanels) usage_panels=$value ;;
      usageTokenPanels) usage_token_panels=$value ;;
      usageOperationalPanels) usage_operational_panels=$value ;;
      leakPatterns) leak_patterns=$value ;;
      leakChars) leak_chars=$value ;;
      pageLeaks) page_leaks=$value ;;
    esac
  done <<EOF
$scalars
EOF
  page_leaks=${page_leaks:-}

  if [ "$error_page" = true ]; then
    record FAIL "$label: the dashboard document loaded" \
      "the browser is showing its own network error document, not the dashboard"
    record_unreached "$label" \
      "the browser is showing its own network error document, so there was no dashboard here to read"
    return
  fi

  # Everything below reads numbers and text out of this probe. If the probe did
  # not yield them, the remaining assertions have nothing to judge, and an
  # assertion with nothing to judge must not report a pass - that is the exact
  # shape of a check that rubber-stamps a broken page.
  if ! is_number "$body_length" || ! is_number "$client_width" \
    || ! is_number "$scroll_width" || ! is_number "$inner_width"; then
    record_unreached "$label" \
      "the probe returned no usable geometry, so nothing further at this width was checked"
    return
  fi

  forced document fail && title="not the dashboard's title"
  if [ "$title" = "Firstmate Fleet" ]; then
    record ok "$label: the dashboard document loaded"
  else
    record FAIL "$label: the dashboard document loaded" "document title is [$title]"
  fi

  # Resizing reports success without proving anything about the page. Without
  # this, a run that silently stayed at the previous size reports a whole green
  # section named after a width it was never at - and every width-sensitive
  # measurement under it, the sideways-scroll one most of all, was taken at the
  # wrong viewport.
  local at_width=no
  forced viewport fail && inner_width=$((inner_width + 7))
  if [ "$inner_width" = "$width" ]; then
    at_width=yes
    record ok "$label: the browser really is at this viewport" \
      "the page reports ${inner_width}x${inner_height} CSS px"
  else
    record FAIL "$label: the browser really is at this viewport" \
      "the page reports ${inner_width} CSS px wide, not the ${width} this section is named after"
  fi

  forced text fail && body_length=0
  if [ "$body_length" -ge 200 ]; then
    record ok "$label: the page rendered text rather than an empty document" "$body_length characters"
  else
    record FAIL "$label: the page rendered text rather than an empty document" "only $body_length characters"
  fi

  # A stylesheet that 404s leaves the document readable and completely
  # unstyled, which is a real regression that every text assertion would
  # otherwise pass. Two things are required rather than one: the page sets its
  # own surface colour, so an unpainted body is the tell that nothing arrived,
  # and --gutter is declared by this dashboard's stylesheet and by nothing else,
  # so a painted body without it is some other stylesheet. Both hold in either
  # theme, which a fixed colour would not.
  local painted=yes
  forced stylesheet fail && background="rgba(0, 0, 0, 0)"
  case "$background" in
    ""|"rgba(0, 0, 0, 0)"|transparent) painted=no ;;
  esac
  if [ "$painted" = yes ] && [ -n "$gutter" ]; then
    record ok "$label: the stylesheet was applied" \
      "body surface $background, and this stylesheet's own --gutter resolves to $gutter"
  elif [ "$painted" != yes ]; then
    record FAIL "$label: the stylesheet was applied" \
      "the body is unpainted [$background], so the page is rendering unstyled"
  else
    record FAIL "$label: the stylesheet was applied" \
      "the body is painted $background but the dashboard's own --gutter is undefined, so this is not its stylesheet"
  fi

  # The injected width moves too, not just the flag: this branch only ever
  # happens because the page is at a width other than the one the section is
  # named after, so leaving the real width in place would print "the page was
  # 390 CSS px wide, so this was never measured at 390" - a sentence no real
  # run can produce, from an injection whose whole job is to reproduce one.
  forced swipe unverified && { at_width=no; inner_width=$((width + 7)); }
  forced swipe fail && scroll_width=$((client_width + 240))
  if [ "$at_width" != yes ]; then
    record "$UNVERIFIED" "$label: nothing is placed behind a horizontal swipe" \
      "the page was ${inner_width} CSS px wide, so this was never measured at ${width}"
  elif [ "$scroll_width" -le "$((client_width + 1))" ]; then
    record ok "$label: nothing is placed behind a horizontal swipe" "scrollWidth $scroll_width <= viewport $client_width"
  else
    record FAIL "$label: nothing is placed behind a horizontal swipe" \
      "the document scrolls sideways: scrollWidth $scroll_width > viewport $client_width"
  fi

  check_views "$label" "$probe"
  check_leak_scan "$label" "$leak_patterns" "$leak_chars" "$page_leaks"
  check_usage_panels "$label" "$history_cards" "$usage_panels"
  check_usage_token_totals "$label" "$history_cards" "$usage_token_panels" "$usage_operational_panels"

  browser screenshot "$OUT_DIR/screen-$label.png" > /dev/null 2>&1 \
    && note "screenshot: $OUT_DIR/screen-$label.png"

  check_navigation "$label"
}

check_views() {  # <label> <probe file>
  local label=$1 probe=$2 id name landmarks expected fields key value
  local present height checked missing leaks
  while IFS='|' read -r id name landmarks; do
    [ -n "$id" ] || continue
    expected=$(count_landmarks "$landmarks")

    # All three observations are recorded on every path out of this loop, not
    # only the one that decided it. A view that is absent was seen not to render
    # with real height and seen not to be legible, and a run that silently
    # stopped recording those two would be a quietly smaller run - which is the
    # shape of failure this whole command exists to end, and is exactly what the
    # negative proof below needs to be able to see.
    #
    # That includes the presence observation on the path where the view IS
    # present, which had no verdict at all until the reconciliation pass asked
    # for one: an absent view recorded FAIL and an unreadable probe recorded
    # ????, so on a healthy page the observation this run claims to make was the
    # only one of the three that produced nothing.
    if forced view-present unverified || ! present=$(probe_fields "$probe" "present=views.$id.present"); then
      record "$UNVERIFIED" "$label: the $name view is on the page" \
        "the probe said nothing about this view, so it was not looked at"
      record "$UNVERIFIED" "$label: the $name view rendered with real height" \
        "the probe said nothing about this view"
      record "$UNVERIFIED" "$label: the $name view is legible" \
        "the probe said nothing about this view"
      continue
    fi
    forced view-present fail && present="present=false"
    if [ "${present#*=}" != true ]; then
      record FAIL "$label: the $name view is on the page"
      record FAIL "$label: the $name view rendered with real height" \
        "the view is not on the page, so it rendered no height at all"
      record FAIL "$label: the $name view is legible" \
        "the view is not on the page, so none of its headings or controls are"
      continue
    fi
    record ok "$label: the $name view is on the page" "the page carries a #$id section"

    if ! fields=$(probe_fields "$probe" \
      "height=views.$id.height" "checked=views.$id.landmarksChecked" \
      "missing=views.$id.missing" "leaks=views.$id.leaks"); then
      record "$UNVERIFIED" "$label: the $name view rendered with real height" \
        "the probe carried no measurement for this view"
      record "$UNVERIFIED" "$label: the $name view is legible" \
        "the probe carried no landmark verdict for this view"
      continue
    fi
    height=; checked=; missing=; leaks=
    while IFS='=' read -r key value; do
      case "$key" in
        height) height=$value ;;
        checked) checked=$value ;;
        missing) missing=$value ;;
        leaks) leaks=$value ;;
      esac
    done <<INNER
$fields
INNER
    capture_view_text "$label" "$id"

    forced view-height unverified && height="not a measurement"
    forced view-height fail && height=10
    forced view-legible unverified && checked=0
    forced view-legible fail && missing="$name"

    # A section that exists but occupies almost nothing is exactly the "it
    # loaded" answer this check refuses to accept.
    if ! is_number "$height"; then
      record "$UNVERIFIED" "$label: the $name view rendered with real height" \
        "the probe reported its height as [$height]"
    elif [ "$height" -ge 60 ]; then
      record ok "$label: the $name view rendered with real height" "${height}px"
    else
      record FAIL "$label: the $name view rendered with real height" "only ${height}px tall"
    fi

    # An empty "missing" list is only evidence of legibility if landmarks were
    # actually looked for. A view row with no landmarks, or a verdict the probe
    # never filled in, produces the same empty list as a view that has every
    # heading it should - so the count of landmarks the page evaluated has to
    # match the count this check asked about before the empty list means
    # anything.
    if ! is_number "$checked" || [ "$checked" -eq 0 ]; then
      record "$UNVERIFIED" "$label: the $name view is legible" \
        "no landmark was evaluated for this view, so nothing about its legibility was judged"
    elif [ "$checked" != "$expected" ]; then
      record "$UNVERIFIED" "$label: the $name view is legible" \
        "the page evaluated $checked landmarks, but this check names $expected of them"
    elif [ -z "$missing" ]; then
      record ok "$label: the $name view is legible" "all $checked of its own headings and controls are on the page"
    else
      record FAIL "$label: the $name view is legible" "$checked landmarks checked, missing: $missing"
    fi

    [ -n "$leaks" ] && ALL_LEAKS="${ALL_LEAKS}${ALL_LEAKS:+; }$name: $leaks"
  done <<EOF
$VIEWS
EOF
}

# The higher-stakes empty list. "No leaks found" is worth nothing unless the
# scan can be shown to have run, so the page reports how many patterns compiled
# and how many characters they ran over, and both have to be real before an
# empty result is read as a clean page.
#
# The coverage is stated on every branch, the failing one included. A failure
# that cannot say what it covered is the same defect as a pass that verified
# nothing wearing the other mask: the reader cannot tell a scan that covered the
# whole page and found one thing from a scan that covered almost none of it and
# found one thing. The character count is the whole rendered page, so a scan
# that narrowed back to some convenient part of it shows up here as a smaller
# number rather than as an unchanged green line.
check_leak_scan() {  # <label> <patterns evaluated> <characters scanned> <page-wide matches>
  local label=$1 patterns=$2 chars=$3 matched=$4 coverage
  if ! is_number "$patterns" || ! is_number "$chars"; then
    record "$UNVERIFIED" "$label: no credential-shaped or path-shaped value on the page" \
      "the page did not report what the scan covered"
    return
  fi
  forced leak unverified && chars=0
  coverage="$patterns patterns over $chars rendered characters"
  if [ "$patterns" -eq 0 ] || [ "$chars" -eq 0 ]; then
    record "$UNVERIFIED" "$label: no credential-shaped or path-shaped value on the page" \
      "$patterns pattern(s) over $chars characters - the scan cannot be shown to have run"
    return
  fi
  if [ "$patterns" != "$LEAK_PATTERN_COUNT" ]; then
    record "$UNVERIFIED" "$label: no credential-shaped or path-shaped value on the page" \
      "the page ran $patterns of this check's $LEAK_PATTERN_COUNT patterns, so the scan was incomplete"
    return
  fi
  forced leak fail && matched="${matched:+$matched, }/home/"
  if [ -z "$matched" ]; then
    record ok "$label: no credential-shaped or path-shaped value on the page" "$coverage"
    return
  fi
  # The verdict is the page-wide scan; the per-view list only says where. A
  # match the views do not account for is a match somewhere the views are not -
  # the notice region, the topbar, the sidebar, the report dialog - and saying
  # so is more useful than an empty attribution.
  if [ -n "$ALL_LEAKS" ]; then
    record FAIL "$label: no credential-shaped or path-shaped value on the page" \
      "$coverage; matched $matched - in $ALL_LEAKS"
  else
    record FAIL "$label: no credential-shaped or path-shaped value on the page" \
      "$coverage; matched $matched - outside the named views, so in the topbar, the notice region, the sidebar or the report dialog"
  fi
}

# Token usage is not a view of its own: it renders as a USAGE panel inside every
# completed-work card in History. A home with no completed work therefore has no
# panel to look at, which is neither a pass nor a failure - it is an observation
# this run could not make, and saying so is the difference between covering
# usage and assuming it.
check_usage_panels() {  # <label> <history cards> <usage panels>
  local label=$1 cards=$2 panels=$3
  if ! is_number "$cards" || ! is_number "$panels"; then
    record "$UNVERIFIED" "$label: every completed record shows its usage panel" \
      "the page did not report how many completion records it rendered"
    return
  fi
  forced usage unverified && cards=0
  forced usage fail && panels=$((cards > 0 ? cards - 1 : 0))
  if [ "$cards" -eq 0 ]; then
    record "$UNVERIFIED" "$label: every completed record shows its usage panel" \
      "no completion record is on the page, so there is no usage panel to look at"
    return
  fi
  if [ "$panels" -eq "$cards" ]; then
    record ok "$label: every completed record shows its usage panel" \
      "$panels labelled panel(s) across $cards completed record(s)"
    return
  fi
  record FAIL "$label: every completed record shows its usage panel" \
    "only $panels of $cards completed records rendered one"
}

check_usage_token_totals() {  # <label> <history cards> <token panels> <operational panels>
  local label=$1 cards=$2 token_panels=$3 operational_panels=$4
  if ! is_number "$cards" || ! is_number "$token_panels" || ! is_number "$operational_panels"; then
    record "$UNVERIFIED" "$label: collected usage shows token totals where attributed" \
      "the page did not report usage totals"
    return
  fi
  forced usage unverified && cards=0
  forced usage tokens && token_panels=1
  forced usage operational && operational_panels=1
  if [ "$cards" -eq 0 ]; then
    record "$UNVERIFIED" "$label: collected usage shows token totals where attributed" \
      "no completion record is on the page, so there is no usage total to look at"
    return
  fi
  if [ "$token_panels" -gt 0 ]; then
    record ok "$label: collected usage shows token totals where attributed" \
      "$token_panels completion record(s) rendered token totals"
    return
  fi
  if [ "$operational_panels" -gt 0 ]; then
    record FAIL "$label: collected usage shows token totals where attributed" \
      "$operational_panels completion record(s) show an operational usage failure instead of totals"
    return
  fi
  record ok "$label: collected usage shows token totals where attributed" \
    "no record on the page shows attributed totals; the home may not collect usage yet"
}

# Following a nav link must put the reader at the top of the section they asked
# for. The bar is sticky, so a target scrolled to the top of the viewport is a
# target underneath it, and the reader lands part-way in with the heading hidden
# - which is what this dashboard did at every width until it was looked at.
#
# The click, the settle and the measurement are one evaluation in the page, so
# what is judged is the landing of the click that was just made rather than
# whatever the page happened to be showing. The page is first scrolled to the
# far end from the target: a section that is already where it should be proves
# nothing about following a link to it.
check_navigation() {  # <label>
  local label=$1 id name _landmarks followed landing key value
  local clicked reason hash bar_bottom head_top viewport_height at_limit moved
  local probe="$WORK_DIR/nav-landing.json"
  while IFS='|' read -r id name _landmarks; do
    [ -n "$id" ] || continue
    # Last thing before the click, because the click is a fragment navigation
    # and the browser tool discards the console bucket this reads. On the first
    # pass that bucket is everything the page printed while loading and first
    # rendering, which is the output most worth having.
    console_collect "$label-before-$id"
    if forced nav unverified || ! browser_eval_json "$(nav_js "$id")" "$probe"; then
      record "$UNVERIFIED" "$label: the $name link lands on that section's heading" \
        "the page returned nothing readable about where following the link landed"
      continue
    fi
    # The click verdict is read on its own first: a link that was never
    # followed carries no landing to measure, and reporting that as
    # "could not measure" would hide a broken nav behind an unread probe.
    if ! followed=$(probe_fields "$probe" clicked=clicked reason=reason); then
      record "$UNVERIFIED" "$label: the $name link lands on that section's heading" \
        "the page did not say whether the link was followed"
      continue
    fi
    clicked=; reason=
    while IFS='=' read -r key value; do
      case "$key" in
        clicked) clicked=$value ;;
        reason) reason=$value ;;
      esac
    done <<CLICK
$followed
CLICK
    # A link that was never followed is a failure of the thing this observation
    # names, not a reason to skip it.
    if [ "$clicked" != true ]; then
      record FAIL "$label: the $name link lands on that section's heading" "$reason"
      continue
    fi

    if ! landing=$(probe_fields "$probe" hash=hash \
      barBottom=barBottom headTop=headTop viewportHeight=viewportHeight \
      atLimit=atLimit moved=moved); then
      record "$UNVERIFIED" "$label: the $name link lands on that section's heading" \
        "the landing measurement could not be read"
      continue
    fi
    hash=; bar_bottom=; head_top=; viewport_height=; at_limit=; moved=
    while IFS='=' read -r key value; do
      case "$key" in
        hash) hash=$value ;;
        barBottom) bar_bottom=$value ;;
        headTop) head_top=$value ;;
        viewportHeight) viewport_height=$value ;;
        atLimit) at_limit=$value ;;
        moved) moved=$value ;;
      esac
    done <<INNER
$landing
INNER

    if ! is_integer "$bar_bottom" || ! is_integer "$head_top" || ! is_number "$viewport_height"; then
      record "$UNVERIFIED" "$label: the $name link lands on that section's heading" \
        "the landing position could not be measured"
      continue
    fi
    # The defect this observation exists to catch, reproduced on demand: the
    # section's heading 119px above the sticky bar's lower edge is what the
    # shipped dashboard did at desktop width before this was measured.
    forced nav fail && head_top=$((bar_bottom - 119))
    if [ "$hash" != "#$id" ]; then
      record FAIL "$label: the $name link lands on that section's heading" \
        "following the link did not select the section: the address bar reads [$hash]"
      continue
    fi
    if [ "$head_top" -lt "$bar_bottom" ]; then
      record FAIL "$label: the $name link lands on that section's heading" \
        "the sticky bar hides the top of the section by $((bar_bottom - head_top))px"
      continue
    fi
    if [ "$head_top" -ge "$viewport_height" ]; then
      record FAIL "$label: the $name link lands on that section's heading" \
        "the heading is ${head_top}px down a ${viewport_height}px viewport, so it is off screen"
      continue
    fi
    if [ "$((head_top - bar_bottom))" -le "$NAV_LANDING_BAND" ]; then
      record ok "$label: the $name link lands on that section's heading" \
        "the heading came to rest $((head_top - bar_bottom))px below the bar (scrolled ${moved}px)"
    elif [ "$at_limit" = true ]; then
      record ok "$label: the $name link lands on that section's heading" \
        "the page reached its scroll limit with the heading $((head_top - bar_bottom))px below the bar and on screen"
    else
      record FAIL "$label: the $name link lands on that section's heading" \
        "the heading came to rest $((head_top - bar_bottom))px below the bar, further than the ${NAV_LANDING_BAND}px an arrival leaves"
    fi
  done <<EOF
$VIEWS
EOF
  # The bucket the last click opened. Without this, whatever the page printed
  # while landing on the final section would be in no window anyone read.
  console_collect "$label-after-nav"
}

# Scroll away from the target, follow the link, wait for the scroll to stop
# moving, then measure - all inside the page, so nothing here is judging a
# scroll that has not finished or a section that was already in place.
nav_js() {  # <section id>
  cat <<JS
async () => {
  const id = "$1";
  const link = [...document.querySelectorAll(".nav-item")].find((a) => a.getAttribute("href") === "#" + id);
  if (!link) return JSON.stringify({ clicked: false, reason: "no .nav-item on the page links to #" + id });
  const section = document.getElementById(id);
  if (!section) return JSON.stringify({ clicked: false, reason: "there is no #" + id + " section to land on" });
  const doc = document.documentElement;
  const maximum = Math.max(0, doc.scrollHeight - window.innerHeight);
  const target = section.getBoundingClientRect().top + window.scrollY;
  const from = target > maximum / 2 ? 0 : maximum;
  window.scrollTo({ top: from, behavior: "instant" });
  await new Promise((resolve) => setTimeout(resolve, 100));
  const started = Math.round(window.scrollY);
  link.click();
  let previous = NaN;
  let stable = 0;
  for (let tick = 0; tick < 60; tick += 1) {
    const y = Math.round(window.scrollY);
    stable = y === previous ? stable + 1 : 0;
    previous = y;
    if (stable >= 3) break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const bar = document.querySelector(".topbar");
  if (!bar) return JSON.stringify({ clicked: false, reason: "the sticky .topbar is not on the page to measure against" });
  const heading = section.querySelector(".board-heading") || section;
  const ended = Math.round(window.scrollY);
  return JSON.stringify({
    clicked: true,
    reason: "",
    hash: location.hash,
    barBottom: Math.round(bar.getBoundingClientRect().bottom),
    headTop: Math.round(heading.getBoundingClientRect().top),
    viewportHeight: window.innerHeight,
    atLimit: ended <= 0 || Math.ceil(ended + window.innerHeight) >= doc.scrollHeight - 2,
    moved: Math.abs(ended - started),
  });
}
JS
}

# --- live stream -------------------------------------------------------------
#
# Fixture mode only. Injecting events into a live dashboard would mean writing
# into the operator's own event store, which this command has no business doing.

json_string() {  # <value>
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# Asked and answered inside the page, for the same reason the main probe is: the
# rendered text is far larger than an eval result may be, so shipping it out to
# search here would be answering the question from a truncated copy.
#
# Three answers, not two. An eval that failed and a page that genuinely does not
# carry the text are different findings, and collapsing them means a broken eval
# satisfies an assertion that the text is absent.
page_contains() {  # <needle>; prints present | absent | unreadable
  if ! browser_eval_text "() => String(document.body.innerText.includes($(json_string "$1")))" \
    "$WORK_DIR/contains.txt"; then
    printf 'unreadable'
    return
  fi
  case "$(cat "$WORK_DIR/contains.txt")" in
    true) printf 'present' ;;
    false) printf 'absent' ;;
    *) printf 'unreadable' ;;
  esac
}

wait_for_page_text() {  # <needle> <seconds>; 0 present, 1 confirmed absent, 2 never readable
  local needle=$1 deadline=$2 answer confirmed=no _
  for _ in $(seq 1 "$((deadline * 2))"); do
    answer=$(page_contains "$needle")
    [ "$answer" = present ] && return 0
    [ "$answer" = absent ] && confirmed=yes
    sleep 0.5
  done
  [ "$confirmed" = yes ] && return 1
  return 2
}

# The nearest enclosing element that names the agent, not the first one found
# walking up: every card shares a board container, so a generous walk matches
# whichever card happens to come first and silently selects the wrong agent.
timeline_click_js() {  # <task id>
  cat <<JS
() => {
  const wanted = "$1";
  let best = null;
  for (const button of document.querySelectorAll("button")) {
    if (button.textContent.trim() !== "Timeline") continue;
    let node = button.parentElement;
    let depth = 1;
    while (node && depth < 8) {
      if (node.textContent.includes(wanted)) break;
      node = node.parentElement;
      depth += 1;
    }
    if (node && depth < 8 && (!best || depth < best.depth)) best = { button, depth };
  }
  if (!best) return "not-found";
  best.button.click();
  return "clicked";
}
JS
}

check_live_stream() {
  browser resize 1440 900 > /dev/null || true
  # Before the open, because the open is a navigation and discards the bucket
  # the last width left behind.
  [ "$CONSOLE_PAGE_OPENED" = yes ] && console_collect "live-before-open"
  # All three live-stream observations are recorded on every path out of this
  # function, the ones that give up early included. Two of them are the reason
  # the third can be believed, and a path that recorded only some of them would
  # be the quietly smaller run this command exists to end.
  if forced open fail || ! browser open "$PAGE_URL#activity" > /dev/null; then
    record FAIL "a live event appears without a reload" "the browser refused to open the page"
    record "$UNVERIFIED" "the agent's earlier events really did leave the live stream" \
      "the page never opened, so this was never reached"
    record "$UNVERIFIED" "backfilled history survives a subsequent event" \
      "the page never opened, so this was never reached"
    return
  fi
  sleep 3

  # 1. The page is open and has not been reloaded since. An event posted now
  #    must arrive on it by itself.
  if ! post_event fixture-ship tool_started fmcheck-live-now; then
    record FAIL "a live event appears without a reload" "the fixture dashboard refused the event"
    record "$UNVERIFIED" "the agent's earlier events really did leave the live stream" \
      "the fixture dashboard refused an event, so this was never reached"
    record "$UNVERIFIED" "backfilled history survives a subsequent event" \
      "the fixture dashboard refused an event, so this was never reached"
    return
  fi
  local arrival
  if forced live-event fail; then
    arrival=1
  elif forced live-event unverified; then
    arrival=2
  else
    wait_for_page_text "fmcheck-live-now" 20
    arrival=$?
  fi
  case $arrival in
    0) record ok "a live event appears without a reload" \
         "posted after the page was open, and it arrived on that same page" ;;
    1) record FAIL "a live event appears without a reload" "the posted event never reached the open page" ;;
    *) record "$UNVERIFIED" "a live event appears without a reload" \
         "the page could not be read while waiting for the event" ;;
  esac

  # 2. Give one agent some earlier history, then push it out of the live tail
  #    with unrelated traffic. Without this the next assertion would be
  #    satisfied by the tail alone and would prove nothing about backfill.
  local index
  for index in 1 2 3; do
    post_event fixture-ship tool_started "fmcheck-backfill-$index" >/dev/null 2>&1
  done
  for index in $(seq 1 8); do
    post_event_batch fixture-filler "fmcheck-filler-$index" 30 >/dev/null 2>&1
    sleep 0.3
  done
  sleep 3

  local left_tail
  if forced tail fail; then
    left_tail=present
  elif forced tail unverified; then
    left_tail=unreadable
  else
    left_tail=$(page_contains "fmcheck-backfill-1")
  fi
  case "$left_tail" in
    present)
      record FAIL "the agent's earlier events really did leave the live stream" \
        "they are still in the fleet-wide tail, so the backfill assertion below would prove nothing"
      record "$UNVERIFIED" "backfilled history survives a subsequent event" \
        "the earlier events never left the tail, so there was nothing to fetch back"
      return ;;
    unreadable)
      record "$UNVERIFIED" "the agent's earlier events really did leave the live stream" \
        "the page could not be read, so their absence was never confirmed"
      record "$UNVERIFIED" "backfilled history survives a subsequent event" \
        "the page could not be read, so this was never reached"
      return ;;
  esac
  record ok "the agent's earlier events really did leave the live stream" \
    "confirmed absent from the page after later traffic, so selecting that agent has to fetch them back"

  # 3. Selecting that agent's own timeline is what fetches them back.
  #
  # Through the same reader every other interaction here uses, which parses the
  # tool's own result line and fails when the browser command did. Matching the
  # raw tool output instead would read a diagnostic that echoed the expression
  # back - the expression contains the word it looks for - as a successful
  # click, and would record a browser command that failed outright as a FAIL of
  # the observation rather than as the ???? this script's header requires.
  local clicked
  if ! browser_eval_text "$(timeline_click_js fixture-ship)" "$WORK_DIR/timeline-click.txt"; then
    record "$UNVERIFIED" "backfilled history survives a subsequent event" \
      "the browser could not be asked to select the agent's own timeline, so nothing about the backfill was observed"
    return
  fi
  clicked=$(cat "$WORK_DIR/timeline-click.txt")
  if [ "$clicked" != clicked ]; then
    record FAIL "backfilled history survives a subsequent event" \
      "the agent's own timeline control could not be found on the board [$clicked], so nothing was backfilled"
    return
  fi
  sleep 3

  case "$(page_contains "fmcheck-backfill-1")" in
    absent)
      record FAIL "backfilled history survives a subsequent event" \
        "selecting the agent did not bring its earlier events back, so there was nothing to survive"
      return ;;
    unreadable)
      record "$UNVERIFIED" "backfilled history survives a subsequent event" \
        "the page could not be read after selecting the agent"
      return ;;
  esac

  # 4. The next accepted event replaces the live stream wholesale. The
  #    backfilled rows must survive that - which is exactly the failure the
  #    timeline's own design note says it is built to avoid.
  post_event fixture-scout turn_ended fmcheck-after-event >/dev/null 2>&1
  sleep 4
  local survived
  if forced backfill fail; then
    survived=absent
  elif forced backfill unverified; then
    survived=unreadable
  else
    survived=$(page_contains "fmcheck-backfill-1")
  fi
  case "$survived" in
    present)
      record ok "backfilled history survives a subsequent event" \
        "the fetched earlier events are still on the page after a newer event replaced the stream" ;;
    absent)
      record FAIL "backfilled history survives a subsequent event" \
        "the fetched earlier events were discarded when the stream was replaced" ;;
    *)
      record "$UNVERIFIED" "backfilled history survives a subsequent event" \
        "the page could not be read after the next event arrived" ;;
  esac
}

# --- console -----------------------------------------------------------------
#
# The browser tool truncates a console listing at 2000 characters, head only,
# with no flag that lifts it, and the listing it returns covers ONLY the
# currently selected page since its last navigation. Worse than it sounds: the
# collector behind it splits its storage on Puppeteer's framenavigated, which
# fires for same-document navigations too, and it keeps three buckets. Each of
# the five nav-link clicks this check makes is a fragment navigation, so five
# clicks after the page loaded, the bucket holding everything the page printed
# while loading and first rendering has been discarded outright. Measured, not
# inferred: a message logged at load is gone from the listing after five
# fragment navigations.
#
# So a read taken once per width, at the end, sees the moment after the last
# nav click and nothing else, and would report a console it never looked at as
# clean. What follows from that is placement. Each bucket is read while it is
# still the current one - a read immediately before every navigation this check
# performs, which captures that bucket entire, plus one read after the last
# navigation of each window. Every bucket this run creates is therefore read
# once, and the reads are summed rather than replacing one another.
#
# The read itself is paged one message at a time, which puts the listing's own
# "Showing 1-1 of N" line - the count of everything there is, not of what fitted
# - in front of the verdict. A read that does not produce that line, or a
# browser command that exits non-zero, is a console window this run could not
# read, and it reports ???? rather than a clean console.

# Prints "<total> <highest msgid>" for one page of the listing. Returns non-zero
# when the browser command failed or the listing was not in a form this can read.
console_page() {  # <page index> <page size> <transcript>
  local index=$1 size=$2 transcript=$3 out status
  out=$(browser console --limit "$size" --page "$index")
  status=$?
  printf '%s\n' "$out" >> "$transcript"
  [ "$status" -eq 0 ] || return 1
  # shellcheck disable=SC2016  # the node program builds its own template string
  printf '%s\n' "$out" | node -e '
    const chunks = [];
    process.stdin.on("data", (chunk) => chunks.push(chunk));
    process.stdin.on("end", () => {
      const text = chunks.join("");
      const ids = [...text.matchAll(/^msgid=(\d+)/gm)].map((match) => Number(match[1]));
      const highest = ids.length ? Math.max(...ids) : 0;
      if (/<no console messages found>/.test(text)) { process.stdout.write("0 0"); return; }
      const showing = /^Showing \d+-\d+ of (\d+) \(Page \d+ of (\d+)\)\./m.exec(text);
      if (!showing) { process.stderr.write(text); process.exit(1); }
      process.stdout.write(`${showing[1]} ${highest}`);
    });
  ' 2>>"$DIAG_LOG"
}

# Prints "<total> <highest msgid>" for the whole listing, and appends every
# message it could name to <names>. Returns non-zero when the listing could not
# be read, because a console that could not be read is not a console that was
# clean.
console_snapshot() {  # <transcript> <names>
  local transcript=$1 names=$2 first last total pages highest index
  : > "$transcript"
  : > "$names"
  first=$(console_page 0 1 "$transcript") || return 1
  total=${first%% *}
  is_number "$total" || return 1
  if [ "$total" -eq 0 ]; then
    printf '0 0'
    return 0
  fi
  # Message ids rise with arrival order, so the last page carries the highest.
  last=$(console_page "$((total - 1))" 1 "$transcript") || return 1
  highest=${last#* }
  is_number "$highest" || return 1
  # Name what fits, for the human reading the evidence. Bounded on purpose: the
  # verdict is already settled by the count above, so paging further would buy
  # nothing but a slower run.
  index=0
  pages=5
  while [ "$index" -lt "$pages" ] && [ "$((index * 20))" -lt "$total" ]; do
    console_page "$index" 20 "$transcript" >/dev/null || break
    index=$((index + 1))
  done
  grep -h '^msgid=' "$transcript" | sort -u >> "$names"
  printf '%s %s' "$total" "$highest"
}

# Reads the console bucket that is current right now, and folds what it holds
# into this run's tally. The caller places these so that every bucket is read
# while it is still the current one; a bucket that was never read is a window
# this run cannot speak for, and CONSOLE_UNREAD names it.
#
# Message ids are accumulated rather than counted, so a bucket that two
# adjacent reads both happen to see is counted once. That matters because the
# reads are placed for coverage, not for tidiness: it is better to read the
# same bucket twice than to leave one unread, and the tally has to survive
# that.
console_collect() {  # <window label>
  local label=$1 snapshot total named
  if ! snapshot=$(console_snapshot "$OUT_DIR/console-$label.txt" "$WORK_DIR/console-names-$label.txt"); then
    CONSOLE_UNREAD="${CONSOLE_UNREAD}${CONSOLE_UNREAD:+, }$label"
    return
  fi
  CONSOLE_READS=$((CONSOLE_READS + 1))
  total=${snapshot%% *}
  is_number "$total" || total=0
  [ "$total" -gt 0 ] || return 0
  CONSOLE_TOTAL=$((CONSOLE_TOTAL + total))
  cat "$WORK_DIR/console-names-$label.txt" >> "$WORK_DIR/console-ids.txt"
  named=$(grep -c '^msgid=' "$WORK_DIR/console-names-$label.txt" 2>/dev/null || true)
  is_number "$named" || named=0
  # A listing whose messages the paging could not all name still happened, and
  # it is counted so the verdict cannot rest on the part that was readable.
  [ "$total" -gt "$named" ] && CONSOLE_UNNAMED=$((CONSOLE_UNNAMED + total - named))
  return 0
}

# The message ids this run is answerable for: unique, and newer than the id the
# console already stood at before the run began. A baseline that could not be
# read leaves every id in scope, which is the conservative direction.
console_fresh_ids() {
  [ -s "$WORK_DIR/console-ids.txt" ] || return 0
  awk -v since="${CONSOLE_BASELINE_MSGID:--1}" '
    match($0, /^msgid=[0-9]+/) {
      id = substr($0, 7, RLENGTH - 6) + 0
      if (id > since && !(id in seen)) { seen[id]; print }
    }
  ' "$WORK_DIR/console-ids.txt"
}

check_console() {
  local line fresh count
  # The reconciliation pass's own three failure paths, injected here because
  # this is the last observation any mode records and the only one every
  # non-negative mode records exactly once. What that pass judges is the set of
  # verdicts this run recorded, so a fault in it is an observation dropped, one
  # recorded twice, or one recorded that was never declared - and it is the pass
  # itself, not these lines, that has to notice.
  forced reconcile duplicate && record ok "the browser console is clean" \
    "recorded a second time on purpose, so the reconciliation pass has a duplicate verdict to find"
  forced reconcile undeclared && record ok "the injector's invented observation" \
    "recorded on purpose, so the reconciliation pass has an undeclared verdict to find"
  forced reconcile drop && return
  forced console unverified && CONSOLE_UNREAD="${CONSOLE_UNREAD}${CONSOLE_UNREAD:+, }forced"
  if [ -n "$CONSOLE_UNREAD" ]; then
    record "$UNVERIFIED" "the browser console is clean" \
      "these console windows could not be read: $CONSOLE_UNREAD - so nothing is known about what the page printed in them"
    return
  fi
  if [ "$CONSOLE_READS" -eq 0 ]; then
    record "$UNVERIFIED" "the browser console is clean" \
      "the console was never read, so this was never observed"
    return
  fi
  fresh=$(console_fresh_ids)
  forced console fail && fresh="msgid=forced type=error text=forced by FM_DASHBOARD_BROWSER_FORCE"
  count=0
  [ -n "$fresh" ] && count=$(printf '%s\n' "$fresh" | grep -c .)
  if [ "$count" -gt 0 ] || [ "$CONSOLE_UNNAMED" -gt 0 ]; then
    printf '%s\n' "$fresh" > "$OUT_DIR/console-new.txt"
    record FAIL "the browser console is clean" \
      "$count message(s) named and $CONSOLE_UNNAMED more listed but not named, across $CONSOLE_READS console window(s), see $OUT_DIR/console-new.txt"
    while IFS= read -r line; do
      [ -n "$line" ] && note "console: $line"
    done <<FRESH
$fresh
FRESH
    return
  fi
  # Every window read here is a bucket one of this run's own navigations
  # created, so a listed message older than the baseline should be impossible -
  # message ids only rise. Reaching this means the ids and the reads did not
  # line up the way this check assumes, and that is a thing it did not verify
  # rather than a clean console.
  if [ "$CONSOLE_TOTAL" -gt 0 ]; then
    record "$UNVERIFIED" "the browser console is clean" \
      "messages were listed but none could be shown to be newer than this run's baseline, so what the page printed is unclear"
    return
  fi
  record ok "the browser console is clean" \
    "$CONSOLE_READS console window(s) read, one immediately before every navigation this run made and one after the last of each, all empty"
}

# --- negative proof ----------------------------------------------------------
#
# The property being proved is that these assertions can fail. A page that
# serves the dashboard's own document shell with no stylesheet, no module, and
# no content is the exact shape of the failure worth catching: it is a 200, it
# has a title, and it renders nothing.
#
# Counting failures is not enough to prove it: a harness that had degraded to
# noticing nothing but a missing heading would still report a failure count.
# What has to hold is that the assertions which read what actually rendered ran
# and refused the page, so those are named here and each one is required to
# appear in result.txt as a FAIL or a ???? of its own.
#
# Requiring the record rather than its absence from the pass log is the whole
# point. "It is not among the passes" is satisfied by an assertion that never
# executed at all, which is how a --negative run on a host whose browser bridge
# was busy could report PASSED having rendered nothing: two early FAILs for a
# viewport that could not be set, an empty pass log, and a verdict inferred from
# two absences. This proof is subject to the same rule as every observation
# above it - a verdict comes from positive evidence that the thing it names
# happened, never from the absence of a contrary signal.
EVIDENCE_ASSERTIONS='the page rendered text rather than an empty document
the stylesheet was applied
view is on the page
view rendered with real height
view is legible
no credential-shaped or path-shaped value on the page
lands on that section'"'"'s heading
every completed record shows its usage panel'

start_negative_page() {
  NEGATIVE_PORT=$(free_port)
  cat > "$WORK_DIR/broken.mjs" <<'JS'
import http from "node:http";
const body = '<!doctype html><html><head><title>Firstmate Fleet</title></head><body></body></html>';
http.createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  response.end(body);
}).listen(Number(process.argv[2]), "127.0.0.1", () => process.stdout.write("ready\n"));
JS
  node "$WORK_DIR/broken.mjs" "$NEGATIVE_PORT" > "$WORK_DIR/broken.log" 2>&1 &
  NEGATIVE_PID=$!
  local _
  for _ in $(seq 1 40); do
    fixture_curl -fsS -o /dev/null "http://127.0.0.1:$NEGATIVE_PORT/" 2>/dev/null && return 0
    sleep 0.2
  done
  die "the deliberately broken page did not start"
}

# 0 when a FAIL or a ???? line in the recorded result names this observation.
# record() writes the verdict in a fixed four-character field, so the first four
# characters of a line are the verdict and nothing else, and the observation is
# matched as a literal substring rather than as a pattern - one of these carries
# an apostrophe and none of them are regular expressions.
recorded_refusal() {  # <observation fragment>
  awk -v needle="$1" '
    substr($0, 1, 4) == "FAIL" || substr($0, 1, 4) == "????" {
      if (index($0, needle) > 0) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$RESULT_FILE"
}

negative_verdict() {
  local pattern checked=0 still_passing='' never_ran=''
  # A width the run could not render and read records ???? for every observation
  # at it, which is the honest verdict for each of them but is NOT a refusal of
  # this page: the assertions never saw it. Reading those as refusals is exactly
  # how this proof once reported PASSED on a host whose browser bridge was busy,
  # so a width that was never reached fails the proof outright.
  if [ -n "$UNREACHED_WIDTHS" ]; then
    printf 'negative proof FAILED: the page was never rendered and read at these widths, so the assertions there recorded "could not be reached" rather than refusing anything: %s\n' \
      "$UNREACHED_WIDTHS" | tee -a "$RESULT_FILE"
    return 1
  fi
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    checked=$((checked + 1))
    if grep -Fq "$pattern" "$OK_LOG"; then
      still_passing="${still_passing}${still_passing:+; }$pattern"
      continue
    fi
    recorded_refusal "$pattern" || never_ran="${never_ran}${never_ran:+; }$pattern"
  done <<EOF
$EVIDENCE_ASSERTIONS
EOF
  if [ -n "$still_passing" ]; then
    printf 'negative proof FAILED: these still reported ok on a page that renders nothing: %s\n' \
      "$still_passing" | tee -a "$RESULT_FILE"
    return 1
  fi
  if [ -n "$never_ran" ]; then
    printf 'negative proof FAILED: these never reported anything at all on a page that renders nothing, so this run shows nothing about whether they can fail: %s\n' \
      "$never_ran" | tee -a "$RESULT_FILE"
    return 1
  fi
  if [ "$FAILURES" -eq 0 ]; then
    printf 'negative proof FAILED: nothing failed on a page that renders nothing, so the check proves nothing\n' \
      | tee -a "$RESULT_FILE"
    return 1
  fi
  printf 'negative proof PASSED: the check refuses a page that renders nothing (%s failed, %s could not be verified, and every one of the %s assertions that read what rendered recorded a FAIL or a ???? of its own)\n' \
    "$FAILURES" "$UNVERIFIED_COUNT" "$checked" | tee -a "$RESULT_FILE"
  return 0
}

# --- run ---------------------------------------------------------------------

if [ -n "$FORCE_SPEC" ]; then
  printf 'FAULT INJECTION ACTIVE:%s\n' "$FORCE_SPEC" | tee -a "$RESULT_FILE"
  printf 'This run forces the branches named above and is NOT a check of the dashboard.\n' \
    | tee -a "$RESULT_FILE"
fi

if CONSOLE_BASELINE=$(console_snapshot "$WORK_DIR/console-baseline.txt" "$WORK_DIR/console-baseline-names.txt"); then
  CONSOLE_BASELINE_MSGID=${CONSOLE_BASELINE#* }
fi

if [ "$NEGATIVE" = yes ]; then
  start_negative_page
  PAGE_URL="http://127.0.0.1:$NEGATIVE_PORT/"
  printf 'negative proof: the same assertions, against a page that renders nothing\n' | tee -a "$RESULT_FILE"
  for spec in $WIDTHS; do
    ALL_LEAKS=
    check_width "${spec%%x*}" "${spec#*x}"
  done
  summarize
  printf 'evidence: %s\n' "$OUT_DIR"
  # Before the proof's own verdict: a proof drawn from a set of observations
  # that is not the set this mode declares is not a proof of anything.
  reconcile_observations || exit 4
  negative_verdict || exit 1
  exit 0
fi

if [ "$MODE" = fixture ]; then
  FIXTURE_PORT=$(free_port)
  build_fixture
  PAGE_URL="http://127.0.0.1:$FIXTURE_PORT/"
  printf 'checking a fixture dashboard from this checkout at %s\n' "$PAGE_URL" | tee -a "$RESULT_FILE"
else
  if [ -n "$PASSWORD_FILE" ]; then
    [ -r "$PASSWORD_FILE" ] || die "cannot read the password file $PASSWORD_FILE"
    FRONT_PORT=$(free_port)
    node "$FRONT" --target "$TARGET_URL" --user "$AUTH_USER" \
      --password-file "$PASSWORD_FILE" --port "$FRONT_PORT" > "$WORK_DIR/front.log" 2>&1 &
    FRONT_PID=$!
    for _ in $(seq 1 40); do
      grep -q '^listening ' "$WORK_DIR/front.log" 2>/dev/null && break
      sleep 0.2
    done
    grep -q '^listening ' "$WORK_DIR/front.log" 2>/dev/null \
      || die "the authenticating front did not start: $(cat "$WORK_DIR/front.log")"
    PAGE_URL="http://127.0.0.1:$FRONT_PORT/"
    printf 'checking %s through a loopback authenticating front at %s\n' "$TARGET_URL" "$PAGE_URL" \
      | tee -a "$RESULT_FILE"
  else
    PAGE_URL="$TARGET_URL"
    printf 'checking %s\n' "$PAGE_URL" | tee -a "$RESULT_FILE"
  fi
fi

if [ -z "$CONSOLE_BASELINE_MSGID" ]; then
  note "the browser console could not be read before this run started, so there is no baseline to compare against;"
  note "every message any console window below lists is therefore counted against this run, which is the safe direction."
else
  note "browser console baseline before this run: highest message id $CONSOLE_BASELINE_MSGID"
fi

for spec in $WIDTHS; do
  printf '\n-- %s --\n' "$spec" | tee -a "$RESULT_FILE"
  ALL_LEAKS=
  check_width "${spec%%x*}" "${spec#*x}"
done

printf '\n-- live stream --\n' | tee -a "$RESULT_FILE"
if [ "$MODE" = fixture ]; then
  check_live_stream
  console_collect live
else
  # Not "could not verify": there is nothing here to verify. Proving any of
  # these means posting events into a dashboard this command does not own, so
  # no run against this target could ever observe them, and treating that as an
  # unverified observation would mean --url could never exit 0 however healthy
  # the page was.
  #
  # All three, not the two the fixture branch's headline guarantees are. The
  # middle one is what makes the third believable rather than a restatement of
  # the live tail, so it is as much an observation as they are, and leaving it
  # to be emitted nowhere in this mode was how a --url result came out one
  # observation shorter than a fixture one with nothing saying so.
  record "$INAPPLICABLE" "a live event appears without a reload" \
    "not applicable to a dashboard this command does not own: proving it means posting an event into that dashboard's own store. Run without --url."
  record "$INAPPLICABLE" "the agent's earlier events really did leave the live stream" \
    "same reason: pushing them out of the tail means posting unrelated events into that dashboard's own store. Run without --url."
  record "$INAPPLICABLE" "backfilled history survives a subsequent event" \
    "same reason: it needs events written into that dashboard's own store. Run without --url."
fi

printf '\n-- console --\n' | tee -a "$RESULT_FILE"
check_console

summarize
printf 'evidence: %s\n' "$OUT_DIR"
[ "$KEEP" = yes ] && [ -n "${FIXTURE_PORT:-}" ] && printf 'fixture dashboard left running at %s\n' "$PAGE_URL"
# First, and ahead of the injected-run status below: a run that did not make the
# observations it declares has not checked the dashboard whatever its verdicts
# say, so this outranks every other exit status this command has.
reconcile_observations || exit 4
# An injected run exits non-zero whatever the page did, so its result can never
# be quoted as a check of the dashboard - which is the whole reason a fault
# injection surface is safe to ship next to the check it injects into.
if [ -n "$FORCE_SPEC" ]; then
  printf 'fault injection was active:%s - these verdicts say what those branches print, not what the dashboard did\n' \
    "$FORCE_SPEC" | tee -a "$RESULT_FILE"
  exit 3
fi
[ "$FAILURES" -eq 0 ] && [ "$UNVERIFIED_COUNT" -eq 0 ] || exit 1
exit 0
