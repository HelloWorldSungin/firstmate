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
#                    Default: 390x844 (phone), 899x844 and 900x844 (the two
#                    sides of the navigation boundary - the rail appears at 900
#                    and the bottom tab bar below it, and navigation vanishing
#                    below 900 is the defect that motivated the rebuild), and
#                    1440x900 (desktop). Naming the same viewport twice is a
#                    usage error: every observation is labelled with its width,
#                    so the run would owe two verdicts for each of them.
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
#                      view-present:fail    only the active view is on the page
#                      view-present:unverified
#                      view-height:fail     the view rendered with real height
#                      view-height:unverified
#                      view-legible:fail    the view is legible
#                      view-legible:unverified
#                      leak:fail            a credential- or path-shaped value
#                      leak:unverified      the scan cannot be shown to have run
#                      usage:fail           a completed row with no usage cell
#                      usage:unverified     no completion row to look at
#                      history:fail         records read but not displayed
#                      history:unverified   the history view could not be read
#                      nav:fail             the destination's control went unfound
#                      nav:unverified       the navigation could not be read
#                      task-open:fail       a board row did not open its task
#                      task-open:unverified
#                      live-event:fail      the event never reached the page
#                      live-event:unverified
#                      isolation:fail       unrelated traffic reached the timeline
#                      isolation:unverified
#                      persist:fail         earlier events vanished from the timeline
#                      persist:unverified
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
#   page that loaded. The page is a hash router with mutually exclusive views,
#   and the assertions are shaped for that: every destination must be reachable
#   through the navigation control that is actually visible at the width being
#   checked (the rail at >=900 CSS px, the bottom tab bar below it - navigation
#   existing at every width is the defect that motivated the rebuild); the
#   active view must be on the page with real rendered height and its own
#   landmark text while EVERY OTHER view is absent from the DOM, not hidden;
#   the browser must be proven to be at the width the section is named after;
#   no destination may scroll sideways; the History view must display the
#   completion records it read, each displayed row carrying its usage cell;
#   opening a task from the Fleet board must land on that task's detail page
#   alone; no destination's rendered page may contain a credential-shaped or
#   absolute-path-shaped value; and the console must be clean. The fixture run
#   additionally proves the task timeline: an event posted while a task's page
#   is open appears with no reload, the task's earlier events survive unrelated
#   fleet traffic, and that unrelated traffic stays off the task's own
#   timeline.
#
#   The structural assertions are written against the page's own contract, not
#   against fixture data, so this same command is what you point at a live
#   dashboard. Extending it for a new destination means adding a row to VIEWS
#   below.
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
#   design - the three task-timeline observations under --url, which can only be
#   proved by posting events into a dashboard this command does not own - so it
#   is reported and counted but does not fail the run. Without the distinction
#   --url could never exit 0 however healthy the page was, which would leave
#   the only mode that can be pointed at the shipped dashboard impossible to
#   automate against.
#
# The declared observation set, and why it is reconciled
#
#   Every mode declares up front the observations it makes: the per-width ones
#   once per --width, the five per-destination ones once per VIEWS row inside
#   each of those, the task-detail, leak, usage and history-display ones once
#   per width, and the timeline and console ones once for the run. That list is
#   derived from VIEWS and WIDTHS rather than written out, so a new view row or
#   a new width extends it without anyone remembering to.
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
# healthy dashboard checked with --url exits 0 with its three task-timeline
# observations recorded as n/a; every other observation is made identically in
# both modes. The full per-observation result is printed and written to
# <out>/result.txt either way.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
FRONT="$ROOT/bin/fm-dashboard-browser-front.mjs"
BROWSER=${FM_DASHBOARD_BROWSER_CLI:-chrome-devtools-axi}

# Each row is: <route>|<view root id>|<label>|<landmark>;<landmark>...
# The route is the [data-route] value on the navigation controls and the hash
# path (#/<route>); the id is the root the router mounts for it, and the id
# every OTHER route must NOT have on its page. The landmarks are the view's own
# furniture - its eyebrow and its heading - chosen to hold against fixture
# data, a live fleet, and the designed empty states alike. A new destination is
# a new row here and nothing else.
VIEWS='needs|view-needs|Needs you|Needs you
fleet|view-fleet|Fleet|Live board;Fleet
backlog|view-backlog|Backlog|Queue · read-only;Backlog
history|view-history|History|Delivered · newest first;History
knowledge|view-knowledge|Knowledge|Knowledge'

DEFAULT_WIDTHS='390x844 899x844 900x844 1440x900'

# Every view root id the router can mount, the task detail included: the
# absence half of the exclusivity assertion looks for all of them by name.
ALL_VIEW_IDS="$(printf '%s\n' "$VIEWS" | cut -d'|' -f2 | paste -sd, -),view-task"

# How many completion records the fixture publishes, so the History display
# assertion can hold the page to the exact record set this run controls.
FIXTURE_HISTORY_COUNT=2

# The verdict for an observation that could not be made. Counted and reported
# separately from a pass and from a failure, and it fails the run: a check that
# could not look is not a check that saw nothing wrong.
UNVERIFIED='????'

# The verdict for an observation this mode cannot reach by design. Counted and
# reported separately from all three of the others, and it does NOT fail the
# run - it is not a thing that went unobserved through some fault, it is a
# thing there was never anything here to observe.
INAPPLICABLE='n/a'

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
run; the three task-timeline observations are n/a under --url, because proving
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
history:fail
history:unverified
nav:fail
nav:unverified
task-open:fail
task-open:unverified
live-event:fail
live-event:unverified
isolation:fail
isolation:unverified
persist:fail
persist:unverified
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
  local spec _route _id name _landmarks
  for spec in $WIDTHS; do
    printf '%s: the dashboard document loaded\n' "$spec"
    printf '%s: the browser really is at this viewport\n' "$spec"
    printf '%s: the page rendered text rather than an empty document\n' "$spec"
    printf '%s: the stylesheet was applied\n' "$spec"
    while IFS='|' read -r _route _id name _landmarks; do
      [ -n "$_route" ] || continue
      printf '%s: the %s destination is reachable from the visible navigation\n' "$spec" "$name"
      printf '%s: only the %s view is on the page\n' "$spec" "$name"
      printf '%s: the %s view rendered with real height\n' "$spec" "$name"
      printf '%s: the %s view is legible\n' "$spec" "$name"
      printf '%s: nothing is placed behind a horizontal swipe on %s\n' "$spec" "$name"
    done <<VIEWROWS
$VIEWS
VIEWROWS
    printf '%s: opening a task from the Fleet board lands on its detail page alone\n' "$spec"
    printf '%s: the History view displays the completion records it read\n' "$spec"
    printf '%s: every completed row shows its usage cell\n' "$spec"
    printf '%s: no credential-shaped or path-shaped value on any destination\n' "$spec"
  done
  [ "$NEGATIVE" = yes ] && return 0
  printf 'a live event appears on the open task page without a reload\n'
  printf 'the task'"'"'s earlier events survive unrelated fleet traffic\n'
  printf 'unrelated traffic stays off the task'"'"'s own timeline\n'
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
  "supervision": {"watcher":{"present":true,"age_seconds":3,"grace_seconds":300,"quiet_allowance_seconds":3600,"stale":false},"afk":{"active":false}},
  "backlog": {
    "path": "data/backlog.md",
    "present": true,
    "records": [
      {"order":1,"state":"queued","structured":true,"id":"fixture-queued-fix","title":"Fix the stale badge count","repo":"firstmate","kind":"fix","priority":"1","since":"2026-08-01","since_age_seconds":86400},
      {"order":2,"state":"queued","structured":true,"id":"fixture-queued-held","title":"Design token sync from the studio site","repo":"arknodestudio-website","kind":"chore","priority":"2","hold_reason":"waiting on vault token rotation","since":"2026-08-02","since_age_seconds":43200}
    ]
  }
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

  # A real sectioned backlog, so the Backlog destination renders queue rows
  # rather than only its first-run empty state. Done stays the last section:
  # seed_completed_task appends its "- [x]" rows to the end of this file, and
  # they have to land under Done for the snapshot parse to read them as such.
  cat > "$home/data/backlog.md" <<'MD'
## In flight

## Queued
- [ ] fixture-queued-fix - Fix the stale badge count (repo: firstmate, kind: fix, priority: 1, since 2026-08-01)
- [ ] fixture-queued-held - Design token sync from the studio site (repo: arknodestudio-website, kind: chore, hold: waiting on vault token rotation, since 2026-08-02)

## Done
MD

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

# The document-level probe each width starts from: identity, geometry, and the
# stylesheet, before any route is visited.
build_page_probe_js() {
  cat <<'JS'
() => {
  const doc = document.documentElement;
  const bodyText = document.body.innerText;
  return JSON.stringify({
    title: document.title,
    bodyTextLength: bodyText.length,
    clientWidth: doc.clientWidth,
    scrollWidth: doc.scrollWidth,
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    background: getComputedStyle(document.body).backgroundColor,
    // Defined by the dashboard's own stylesheet and by nothing else on the
    // page, so a painted body that lacks it is some other stylesheet.
    accent: getComputedStyle(doc).getPropertyValue("--amber-soft").trim(),
    // Chrome renders its own error document, with a 200 from the tool's
    // point of view, when the server is not there to answer.
    errorPage: document.getElementById("main-frame-error") !== null,
  });
}
JS
}

# The one probe every observation about a destination is read from: it clicks
# the route's visible navigation control, waits for the router to mount the
# view, and measures - the click, the settle, and every judgment in one
# evaluation inside the page.
#
# Every judgment about text - which landmarks are present, whether anything
# leak-shaped is on the page - is made INSIDE the page and comes back as a
# short list, rather than shipping the rendered text out to be searched here:
# a verdict is a fixed small result whatever the fleet is doing, while a probe
# returning the rendered text sits a page growth away from coming back
# truncated on exactly the pages worth checking.
#
# The counts alongside each verdict are what make the verdict readable as
# evidence: how many landmarks were asked about, how many other view ids were
# looked for, how many leak patterns compiled and how many characters they ran
# over, how many history rows were on the page. An empty "missing" or "others"
# list means nothing at all unless something was checked, so the caller
# requires those counts before it will read an empty list as a pass.
route_probe_js() {  # <route> <view id> <semicolon landmarks>
  # shellcheck disable=SC2016  # the node program interpolates its own argv, not the shell's
  node -e '
    const [route, viewId, landmarksRaw, allIdsRaw, leaksRaw] = process.argv.slice(1);
    const config = {
      route,
      viewId,
      landmarks: landmarksRaw.split(";").filter(Boolean),
      allIds: allIdsRaw.split(",").filter(Boolean),
      leaks: leaksRaw.split(";").filter(Boolean),
    };
    process.stdout.write(`async () => {
      const config = ${JSON.stringify(config)};
      const out = { clicked: false, control: "", reason: "" };
      // A control is only worth finding on a page that has finished becoming
      // the dashboard: the router must have mounted a view (which proves the
      // module ran and the click listeners exist) and the dashboard stylesheet
      // must be applied (which is what makes the visibility test below mean
      // anything - before it, the rail is "visible" at every width). Probing
      // earlier clicks a listener-less button and reads a layout the container
      // queries have not shaped yet.
      for (let tick = 0; tick < 60; tick += 1) {
        const mounted = document.querySelector("#view > [id^=" + JSON.stringify("view-") + "]");
        const styled = getComputedStyle(document.documentElement).getPropertyValue("--amber-soft").trim() !== "";
        if (mounted && styled) break;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      const controls = [...document.querySelectorAll("[data-route=" + JSON.stringify(config.route) + "]")];
      if (!controls.length) {
        out.reason = "no navigation control on the page carries this route";
        return JSON.stringify(out);
      }
      const visible = controls.find((control) => {
        const box = control.getBoundingClientRect();
        return box.width > 0 && box.height > 0 && getComputedStyle(control).display !== "none";
      });
      if (!visible) {
        out.reason = "the route has " + controls.length + " controls but none is visible at this width";
        return JSON.stringify(out);
      }
      out.control = visible.classList.contains("tabitem") ? "the bottom tab bar" : "the rail";
      visible.click();
      for (let tick = 0; tick < 40; tick += 1) {
        if (document.getElementById(config.viewId)) break;
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      out.clicked = true;
      out.hash = location.hash;
      const doc = document.documentElement;
      out.clientWidth = doc.clientWidth;
      out.scrollWidth = doc.scrollWidth;
      const element = document.getElementById(config.viewId);
      out.present = element !== null;
      // The exclusivity evidence: every other view id, looked for by name, and
      // the count of how many were looked for so an empty list is checkable.
      out.others = config.allIds.filter((id) => id !== config.viewId && document.getElementById(id) !== null);
      out.othersChecked = config.allIds.length - 1;
      const patterns = [];
      for (const source of config.leaks) {
        try { patterns.push({ source, expression: new RegExp(source) }); } catch { /* only a pattern that compiles is one this scan ran */ }
      }
      // The whole rendered page at this destination, because that is what the
      // leak observation claims: the verdict strip, the navigation, and any
      // notice carrying a failed command'"'"'s stderr sit outside the view root.
      const bodyText = document.body.innerText;
      out.leakPatterns = patterns.length;
      out.leakChars = bodyText.length;
      out.pageLeaks = patterns.filter((pattern) => pattern.expression.test(bodyText)).map((pattern) => pattern.source);
      if (element) {
        const text = element.innerText;
        const lower = text.toLowerCase();
        out.height = Math.round(element.getBoundingClientRect().height);
        out.landmarksChecked = config.landmarks.length;
        out.missing = config.landmarks.filter((landmark) => !lower.includes(landmark.toLowerCase()));
        if (config.route === "history") {
          const rows = [...element.querySelectorAll(".rrow")];
          out.historyRows = rows.length;
          out.usageCells = rows.filter((row) => {
            const cell = row.querySelector(".hcost");
            return cell !== null && cell.textContent.trim() !== "";
          }).length;
          const pginfo = element.querySelector(".pginfo");
          out.pageInfo = pginfo ? pginfo.textContent : "";
          const emptyBig = element.querySelector(".empty-big");
          out.emptyBig = emptyBig ? emptyBig.textContent : "";
        }
      }
      return JSON.stringify(out);
    }`);
  ' "$1" "$2" "$3" "$ALL_VIEW_IDS" "$LEAK_PATTERNS"
}

# Clicks the first task row on the Fleet board and reads where it landed, so
# the detail route is proven through the interaction that reaches it rather
# than by writing a hash by hand.
task_open_probe_js() {
  # shellcheck disable=SC2016  # the node program interpolates its own argv, not the shell's
  node -e '
    const allIds = process.argv[1].split(",").filter(Boolean);
    process.stdout.write(`async () => {
      const allIds = ${JSON.stringify(allIds)};
      const row = document.querySelector("#view-fleet .trow");
      if (!row) return JSON.stringify({ clicked: false, reason: "no task row is on the Fleet board" });
      row.click();
      for (let tick = 0; tick < 40; tick += 1) {
        if (document.getElementById("view-task")) break;
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      return JSON.stringify({
        clicked: true,
        reason: "",
        hash: location.hash,
        present: document.getElementById("view-task") !== null,
        others: allIds.filter((id) => document.getElementById(id) !== null),
        othersChecked: allIds.length,
      });
    }`);
  ' "$ALL_VIEW_IDS"
}

# A bounded slice of each view, saved so a human can read what the check saw.
# Evidence only - nothing is asserted from it, so the bound costs no coverage.
capture_view_text() {  # <label> <view id>
  browser_eval_text "() => document.getElementById('$2') ? document.getElementById('$2').innerText.slice(0, 2000) : ''" \
    "$OUT_DIR/text-$1-$2.txt" 2>/dev/null || true
}

# Aggregates the per-destination probes feed. Reset at the top of every width.
WIDTH_TRUSTED=no
LEAK_SCANS=0
LEAK_CHARS_TOTAL=0
LEAK_PATTERNS_SHORT=no
LEAK_MATCHES=

# ???? for any observation declared at this width that no path above recorded.
# The width still counts as reached - unlike record_unreached, which marks the
# whole width unrendered and thereby fails the negative proof - so this is the
# backstop for observations whose carrier (a route, a board row) was itself
# unreachable while the page as a whole was rendered and read.
record_missing() {  # <label>
  local label=$1 observation
  while IFS= read -r observation; do
    case "$observation" in
      "$label: "*) ;;
      *) continue ;;
    esac
    grep -Fxq "$observation" "$EMITTED_LOG" && continue
    record "$UNVERIFIED" "$observation" \
      "this observation was never reached at this width; the verdicts above say why"
  done < "$DECLARED_FILE"
}

check_width() {  # <width> <height>
  local width=$1 height=$2 label="${1}x${2}" probe scalars key value
  local route id name landmarks
  probe="$OUT_DIR/probe-${width}x${height}.json"

  WIDTH_TRUSTED=no
  LEAK_SCANS=0
  LEAK_CHARS_TOTAL=0
  LEAK_PATTERNS_SHORT=no
  LEAK_MATCHES=

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
  # The page fills itself from its first snapshot, history, and backlog polls,
  # so give them a chance to land before reading it.
  sleep 4

  # Read the load and render window here rather than only before the first
  # route click, because every path out of this function below can return early
  # and the first click would then be the thing that discards it unread.
  console_collect "$label-load"

  if forced probe fail || ! browser_eval_json "$(build_page_probe_js)" "$probe"; then
    record_unreached "$label" \
      "the probe returned nothing the browser could decode, so nothing at this width was judged"
    return
  fi

  local title body_length inner_width inner_height client_width scroll_width
  local background accent error_page
  if forced probe unverified || ! scalars=$(probe_fields "$probe" \
    title=title bodyTextLength=bodyTextLength innerWidth=innerWidth innerHeight=innerHeight \
    clientWidth=clientWidth scrollWidth=scrollWidth background=background accent=accent \
    errorPage=errorPage); then
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
      accent) accent=$value ;;
      errorPage) error_page=$value ;;
    esac
  done <<EOF
$scalars
EOF

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
  # measurement under it, the per-destination sideways-swipe ones most of all,
  # was taken at the wrong viewport.
  forced viewport fail && inner_width=$((inner_width + 7))
  if [ "$inner_width" = "$width" ]; then
    WIDTH_TRUSTED=yes
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
  # and --amber-soft is declared by this dashboard's stylesheet and by nothing
  # else, so a painted body without it is some other stylesheet. Both hold in
  # either theme, which a fixed colour would not.
  local painted=yes
  forced stylesheet fail && { background="rgba(0, 0, 0, 0)"; accent=; }
  case "$background" in
    ""|"rgba(0, 0, 0, 0)"|transparent) painted=no ;;
  esac
  if [ "$painted" = yes ] && [ -n "$accent" ]; then
    record ok "$label: the stylesheet was applied" \
      "body surface $background, and this stylesheet's own --amber-soft resolves to $accent"
  elif [ "$painted" != yes ]; then
    record FAIL "$label: the stylesheet was applied" \
      "the body is unpainted [$background], so the page is rendering unstyled"
  else
    record FAIL "$label: the stylesheet was applied" \
      "the body is painted $background but the dashboard's own --amber-soft is undefined, so this is not its stylesheet"
  fi

  # Every destination in turn, through the navigation control that is actually
  # visible at this width, with the task detail proven from the Fleet board's
  # own rows while that board is the active view.
  while IFS='|' read -r route id name landmarks; do
    [ -n "$route" ] || continue
    check_route "$label" "$route" "$id" "$name" "$landmarks"
    [ "$route" = fleet ] && check_task_open "$label"
  done <<EOF
$VIEWS
EOF
  # The bucket the last click opened. Without this, whatever the page printed
  # while rendering the final destination would be in no window anyone read.
  console_collect "$label-after-nav"

  check_leak_aggregate "$label"

  browser screenshot "$OUT_DIR/screen-$label.png" > /dev/null 2>&1 \
    && note "screenshot: $OUT_DIR/screen-$label.png"

  record_missing "$label"
}

# ???? for the four view observations of a destination that was never reached.
route_unobserved() {  # <label> <name> <reason>
  local label=$1 name=$2 reason=$3
  record "$UNVERIFIED" "$label: only the $name view is on the page" "$reason"
  record "$UNVERIFIED" "$label: the $name view rendered with real height" "$reason"
  record "$UNVERIFIED" "$label: the $name view is legible" "$reason"
  record "$UNVERIFIED" "$label: nothing is placed behind a horizontal swipe on $name" "$reason"
}

check_route() {  # <width label> <route> <view id> <name> <landmarks>
  local label=$1 route=$2 id=$3 name=$4 landmarks=$5 expected probe fields key value
  local clicked control reason hash present others others_checked
  local client_width scroll_width leak_patterns leak_chars page_leaks
  expected=$(count_landmarks "$landmarks")
  probe="$OUT_DIR/route-$label-$route.json"

  # Last thing before the click, because the click is a fragment navigation
  # and the browser tool discards the console bucket this reads.
  console_collect "$label-before-$route"

  if forced nav unverified || ! browser_eval_json "$(route_probe_js "$route" "$id" "$landmarks")" "$probe"; then
    record "$UNVERIFIED" "$label: the $name destination is reachable from the visible navigation" \
      "the page returned nothing readable about the navigation"
    route_unobserved "$label" "$name" "the destination was never reached, so nothing about its view was observed"
    return 1
  fi
  # The click verdict is read on its own first: a control that was never found
  # carries no view to measure, and reporting that as "could not measure" would
  # hide a missing navigation behind an unread probe.
  if ! fields=$(probe_fields "$probe" clicked=clicked reason=reason); then
    record "$UNVERIFIED" "$label: the $name destination is reachable from the visible navigation" \
      "the page did not say whether the navigation control was found"
    route_unobserved "$label" "$name" "the destination was never reached, so nothing about its view was observed"
    return 1
  fi
  clicked=; reason=
  while IFS='=' read -r key value; do
    case "$key" in
      clicked) clicked=$value ;;
      reason) reason=$value ;;
    esac
  done <<CLICK
$fields
CLICK
  # The founding defect, reproduced on demand: a width at which no visible
  # control leads to this destination.
  forced nav fail && { clicked=false; reason="the route has 2 controls but none is visible at this width"; }
  if [ "$clicked" != true ]; then
    record FAIL "$label: the $name destination is reachable from the visible navigation" "$reason"
    route_unobserved "$label" "$name" "the destination could not be reached, so nothing about its view was observed"
    return 1
  fi

  if ! fields=$(probe_fields "$probe" hash=hash control=control present=present \
    others=others othersChecked=othersChecked clientWidth=clientWidth scrollWidth=scrollWidth \
    leakPatterns=leakPatterns leakChars=leakChars pageLeaks=pageLeaks); then
    record "$UNVERIFIED" "$label: the $name destination is reachable from the visible navigation" \
      "the landing could not be read out of the probe"
    route_unobserved "$label" "$name" "the landing could not be read, so nothing about the view was observed"
    return 1
  fi
  hash=; control=; present=; others=; others_checked=; client_width=; scroll_width=
  leak_patterns=; leak_chars=; page_leaks=
  while IFS='=' read -r key value; do
    case "$key" in
      hash) hash=$value ;;
      control) control=$value ;;
      present) present=$value ;;
      others) others=$value ;;
      othersChecked) others_checked=$value ;;
      clientWidth) client_width=$value ;;
      scrollWidth) scroll_width=$value ;;
      leakPatterns) leak_patterns=$value ;;
      leakChars) leak_chars=$value ;;
      pageLeaks) page_leaks=$value ;;
    esac
  done <<INNER
$fields
INNER

  if [ "$hash" != "#/$route" ]; then
    record FAIL "$label: the $name destination is reachable from the visible navigation" \
      "following the control did not select the destination: the address reads [$hash]"
    route_unobserved "$label" "$name" "the destination was never selected, so nothing about its view was observed"
    return 1
  fi
  record ok "$label: the $name destination is reachable from the visible navigation" \
    "reached through $control, and the address reads $hash"

  # Fold this destination's page-wide leak scan into the width's aggregate.
  # A scan over zero characters is a scan that cannot be shown to have run.
  if is_number "$leak_patterns" && is_number "$leak_chars" && [ "$leak_chars" -gt 0 ]; then
    LEAK_SCANS=$((LEAK_SCANS + 1))
    LEAK_CHARS_TOTAL=$((LEAK_CHARS_TOTAL + leak_chars))
    [ "$leak_patterns" != "$LEAK_PATTERN_COUNT" ] && LEAK_PATTERNS_SHORT=yes
    [ -n "$page_leaks" ] && LEAK_MATCHES="${LEAK_MATCHES}${LEAK_MATCHES:+; }$name: $page_leaks"
  fi

  # The exclusivity assertion this rebuild exists for: the active view mounted,
  # and every other view root absent from the DOM - not hidden, absent. Both
  # halves are required, because "the others are absent" is vacuously true of a
  # page that rendered nothing at all.
  if forced view-present unverified; then
    record "$UNVERIFIED" "$label: only the $name view is on the page" \
      "the probe said nothing about this view, so it was not looked at"
    record "$UNVERIFIED" "$label: the $name view rendered with real height" \
      "the probe said nothing about this view"
    record "$UNVERIFIED" "$label: the $name view is legible" \
      "the probe said nothing about this view"
  else
    forced view-present fail && { present=true; others="view-fleet"; }
    if [ "$present" != true ]; then
      record FAIL "$label: only the $name view is on the page" \
        "the active view is missing entirely, so there is no view exclusivity could be claimed about"
      record FAIL "$label: the $name view rendered with real height" \
        "the view is not on the page, so it rendered no height at all"
      record FAIL "$label: the $name view is legible" \
        "the view is not on the page, so none of its headings or controls are"
    else
      if [ -n "$others" ]; then
        record FAIL "$label: only the $name view is on the page" \
          "another view is in the DOM beside it rather than absent: $others"
      elif ! is_number "$others_checked" || [ "$others_checked" -eq 0 ]; then
        record "$UNVERIFIED" "$label: only the $name view is on the page" \
          "no other view id was looked for, so the empty list proves nothing"
      else
        record ok "$label: only the $name view is on the page" \
          "#$id is mounted and all $others_checked other view roots are absent from the DOM"
      fi
      check_route_body "$label" "$name" "$id" "$probe" "$expected"
    fi
  fi

  # The swipe verdict is a page property at this destination, judged only at a
  # width the run proved, because a sideways scroll measured at the wrong
  # viewport says nothing about this one.
  local trusted=$WIDTH_TRUSTED
  forced swipe unverified && trusted=no
  forced swipe fail && scroll_width=$((client_width + 240))
  if [ "$trusted" != yes ]; then
    record "$UNVERIFIED" "$label: nothing is placed behind a horizontal swipe on $name" \
      "the page is not proven to be at ${label%%x*} CSS px, so this was never measured at it"
  elif ! is_number "$scroll_width" || ! is_number "$client_width"; then
    record "$UNVERIFIED" "$label: nothing is placed behind a horizontal swipe on $name" \
      "the probe returned no usable geometry for this destination"
  elif [ "$scroll_width" -le "$((client_width + 1))" ]; then
    record ok "$label: nothing is placed behind a horizontal swipe on $name" \
      "scrollWidth $scroll_width <= viewport $client_width"
  else
    record FAIL "$label: nothing is placed behind a horizontal swipe on $name" \
      "the document scrolls sideways at this destination: scrollWidth $scroll_width > viewport $client_width"
  fi
  return 0
}

# The height and legibility of a view the probe confirmed present, plus the
# History display and usage observations while that view is the one on stage.
check_route_body() {  # <label> <name> <view id> <probe> <expected landmark count>
  local label=$1 name=$2 id=$3 probe=$4 expected=$5 fields key value
  local height checked missing history_rows usage_cells page_info empty_big
  capture_view_text "$label" "$id"
  if ! fields=$(probe_fields "$probe" height=height checked=landmarksChecked missing=missing); then
    record "$UNVERIFIED" "$label: the $name view rendered with real height" \
      "the probe carried no measurement for this view"
    record "$UNVERIFIED" "$label: the $name view is legible" \
      "the probe carried no landmark verdict for this view"
    return
  fi
  height=; checked=; missing=
  while IFS='=' read -r key value; do
    case "$key" in
      height) height=$value ;;
      checked) checked=$value ;;
      missing) missing=$value ;;
    esac
  done <<INNER
$fields
INNER

  forced view-height unverified && height="not a measurement"
  forced view-height fail && height=10

  # A view that exists but occupies almost nothing is exactly the "it loaded"
  # answer this check refuses to accept.
  if ! is_number "$height"; then
    record "$UNVERIFIED" "$label: the $name view rendered with real height" \
      "the probe reported its height as [$height]"
  elif [ "$height" -ge 60 ]; then
    record ok "$label: the $name view rendered with real height" "${height}px"
  else
    record FAIL "$label: the $name view rendered with real height" "only ${height}px tall"
  fi

  forced view-legible unverified && checked=0
  forced view-legible fail && missing="$name"

  # An empty "missing" list is only evidence of legibility if landmarks were
  # actually looked for, and as many of them as this check names.
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

  [ "$id" = view-history ] || return 0
  if ! fields=$(probe_fields "$probe" historyRows=historyRows usageCells=usageCells \
    pageInfo=pageInfo emptyBig=emptyBig); then
    record "$UNVERIFIED" "$label: the History view displays the completion records it read" \
      "the probe carried no row measurement for the History view"
    record "$UNVERIFIED" "$label: every completed row shows its usage cell" \
      "the probe carried no row measurement for the History view"
    return
  fi
  history_rows=; usage_cells=; page_info=; empty_big=
  while IFS='=' read -r key value; do
    case "$key" in
      historyRows) history_rows=$value ;;
      usageCells) usage_cells=$value ;;
      pageInfo) page_info=$value ;;
      emptyBig) empty_big=$value ;;
    esac
  done <<INNER
$fields
INNER
  check_history_display "$label" "$history_rows" "$page_info" "$empty_big"
  check_usage_cells "$label" "$history_rows" "$usage_cells"
}

# The assertion the old dashboard failed for months: it found completion
# records and displayed none of them. The displayed rows must agree with the
# pager's own account of the list, the fixture's known record count where this
# run controls the records, and zero rows may stand only behind one of the
# page's designed, disclosed empty states - never silently.
check_history_display() {  # <label> <rows> <pager text> <empty-state text>
  local label=$1 rows=$2 info=$3 empty=$4 bounds first last matched
  if forced history unverified; then
    record "$UNVERIFIED" "$label: the History view displays the completion records it read" \
      "the History view could not be read"
    return
  fi
  forced history fail && { rows=0; info=; empty=; }
  if ! is_number "$rows"; then
    record "$UNVERIFIED" "$label: the History view displays the completion records it read" \
      "the probe reported the row count as [$rows]"
    return
  fi
  if [ "$rows" -gt 0 ]; then
    bounds=$(printf '%s' "$info" | sed -n 's/^\([0-9][0-9]*\)[^0-9][^0-9]*\([0-9][0-9]*\) of \([0-9][0-9]*\)$/\1 \2 \3/p')
    if [ -z "$bounds" ]; then
      record "$UNVERIFIED" "$label: the History view displays the completion records it read" \
        "$rows rows are on the page but the pager did not state what the list holds: [$info]"
      return
    fi
    # shellcheck disable=SC2086  # bounds is three numbers this function just built
    set -- $bounds
    first=$1; last=$2; matched=$3
    if [ "$rows" -ne $((last - first + 1)) ]; then
      record FAIL "$label: the History view displays the completion records it read" \
        "the pager says rows $first-$last of $matched are shown, but $rows are on the page"
      return
    fi
    if [ "$MODE" = fixture ] && [ "$rows" -ne "$FIXTURE_HISTORY_COUNT" ]; then
      record FAIL "$label: the History view displays the completion records it read" \
        "the fixture published $FIXTURE_HISTORY_COUNT completion records but $rows are displayed"
      return
    fi
    record ok "$label: the History view displays the completion records it read" \
      "$rows rows displayed, agreeing with the pager's $first-$last of $matched"
    return
  fi
  if [ "$MODE" = fixture ]; then
    record FAIL "$label: the History view displays the completion records it read" \
      "the fixture published $FIXTURE_HISTORY_COUNT completion records but the page displays none${empty:+ - the page says [$empty]}"
    return
  fi
  if [ -n "$empty" ]; then
    record ok "$label: the History view displays the completion records it read" \
      "no row is displayed, and the page discloses why in its designed empty state: [$empty]"
  else
    record FAIL "$label: the History view displays the completion records it read" \
      "no row, no pager, and no empty state - the records vanished silently"
  fi
}

# Usage is a cell on every completed row: a token total, or an explicit
# "unavailable" - never a blank. A page with no completed row has no cell to
# look at, which is neither a pass nor a failure.
check_usage_cells() {  # <label> <rows> <cells>
  local label=$1 rows=$2 cells=$3
  forced usage unverified && rows=0
  if ! is_number "$rows" || ! is_number "$cells"; then
    record "$UNVERIFIED" "$label: every completed row shows its usage cell" \
      "the page did not report how many completion rows it rendered"
    return
  fi
  forced usage fail && cells=$((rows > 0 ? rows - 1 : 0))
  if [ "$rows" -eq 0 ]; then
    record "$UNVERIFIED" "$label: every completed row shows its usage cell" \
      "no completion row is on the page, so there is no usage cell to look at"
    return
  fi
  if [ "$cells" -eq "$rows" ]; then
    record ok "$label: every completed row shows its usage cell" \
      "$cells non-empty cell(s) across $rows displayed row(s)"
  else
    record FAIL "$label: every completed row shows its usage cell" \
      "only $cells of $rows displayed rows rendered one"
  fi
}

# The task detail route, proven through the interaction that reaches it: a row
# on the Fleet board, clicked while that board is the active view.
check_task_open() {  # <label>
  local label=$1 probe fields key value clicked reason hash present others others_checked
  probe="$OUT_DIR/task-open-$label.json"
  console_collect "$label-before-task"
  if forced task-open unverified || ! browser_eval_json "$(task_open_probe_js)" "$probe"; then
    record "$UNVERIFIED" "$label: opening a task from the Fleet board lands on its detail page alone" \
      "the page returned nothing readable about the board"
    return
  fi
  if ! fields=$(probe_fields "$probe" clicked=clicked reason=reason); then
    record "$UNVERIFIED" "$label: opening a task from the Fleet board lands on its detail page alone" \
      "the page did not say whether a board row was found"
    return
  fi
  clicked=; reason=
  while IFS='=' read -r key value; do
    case "$key" in
      clicked) clicked=$value ;;
      reason) reason=$value ;;
    esac
  done <<CLICK
$fields
CLICK
  if [ "$clicked" != true ]; then
    if [ "$MODE" = fixture ]; then
      record FAIL "$label: opening a task from the Fleet board lands on its detail page alone" "$reason"
    else
      # A healthy fleet can be idle. A board with no row is not a defect of the
      # detail route, and no run against it could observe this.
      record "$INAPPLICABLE" "$label: opening a task from the Fleet board lands on its detail page alone" \
        "$reason - a fleet with no live task has no row to open"
    fi
    return
  fi
  if ! fields=$(probe_fields "$probe" hash=hash present=present others=others othersChecked=othersChecked); then
    record "$UNVERIFIED" "$label: opening a task from the Fleet board lands on its detail page alone" \
      "the landing could not be read out of the probe"
    return
  fi
  hash=; present=; others=; others_checked=
  while IFS='=' read -r key value; do
    case "$key" in
      hash) hash=$value ;;
      present) present=$value ;;
      others) others=$value ;;
      othersChecked) others_checked=$value ;;
    esac
  done <<INNER
$fields
INNER
  forced task-open fail && present=false
  case "$hash" in
    "#/task/"*) ;;
    *)
      record FAIL "$label: opening a task from the Fleet board lands on its detail page alone" \
        "clicking a board row did not navigate: the address reads [$hash]"
      return ;;
  esac
  if [ "$present" != true ]; then
    record FAIL "$label: opening a task from the Fleet board lands on its detail page alone" \
      "the task view is not on the page after opening a task"
    return
  fi
  if ! is_number "$others_checked" || [ "$others_checked" -eq 0 ]; then
    record "$UNVERIFIED" "$label: opening a task from the Fleet board lands on its detail page alone" \
      "no view id was looked for, so nothing about exclusivity was judged"
    return
  fi
  if [ "$others" != "view-task" ]; then
    record FAIL "$label: opening a task from the Fleet board lands on its detail page alone" \
      "other views are on the page beside the task detail: $others"
    return
  fi
  record ok "$label: opening a task from the Fleet board lands on its detail page alone" \
    "the row's own task page is mounted alone at $hash, with all $others_checked view roots checked"
}

# The higher-stakes empty list, aggregated across every destination this width
# reached. "No leaks found" is worth nothing unless the scan can be shown to
# have run over every destination's rendered page, so the verdict requires one
# completed scan per VIEWS row and a real character count before an empty
# result is read as a clean page.
check_leak_aggregate() {  # <label>
  local label=$1 route_total
  route_total=$(printf '%s\n' "$VIEWS" | grep -c .)
  forced leak unverified && LEAK_SCANS=0
  if [ "$LEAK_SCANS" -ne "$route_total" ] || [ "$LEAK_CHARS_TOTAL" -eq 0 ]; then
    record "$UNVERIFIED" "$label: no credential-shaped or path-shaped value on any destination" \
      "the scan ran on $LEAK_SCANS of $route_total destinations over $LEAK_CHARS_TOTAL characters, so it cannot be shown to have covered the page"
    return
  fi
  if [ "$LEAK_PATTERNS_SHORT" = yes ]; then
    record "$UNVERIFIED" "$label: no credential-shaped or path-shaped value on any destination" \
      "a destination evaluated fewer than this check's $LEAK_PATTERN_COUNT patterns, so the scan was incomplete"
    return
  fi
  forced leak fail && LEAK_MATCHES="${LEAK_MATCHES}${LEAK_MATCHES:+; }forced: /home/"
  if [ -z "$LEAK_MATCHES" ]; then
    record ok "$label: no credential-shaped or path-shaped value on any destination" \
      "$LEAK_PATTERN_COUNT patterns over $LEAK_CHARS_TOTAL rendered characters across $route_total destinations"
  else
    record FAIL "$label: no credential-shaped or path-shaped value on any destination" \
      "matched $LEAK_MATCHES"
  fi
}
# --- task timeline ------------------------------------------------------------
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

check_live_stream() {
  browser resize 1440 900 > /dev/null || true
  # Before the open, because the open is a navigation and discards the bucket
  # the last width left behind.
  [ "$CONSOLE_PAGE_OPENED" = yes ] && console_collect "live-before-open"
  # All three task-timeline observations are recorded on every path out of this
  # function, the ones that give up early included. The second and third are
  # what make the first worth having - a timeline that is only the live tail
  # would pass it - so a path that recorded only some of them would be the
  # quietly smaller run this command exists to end.
  if forced open fail || ! browser open "$PAGE_URL#/task/fixture-ship" > /dev/null; then
    record FAIL "a live event appears on the open task page without a reload" \
      "the browser refused to open the page"
    record "$UNVERIFIED" "the task's earlier events survive unrelated fleet traffic" \
      "the page never opened, so this was never reached"
    record "$UNVERIFIED" "unrelated traffic stays off the task's own timeline" \
      "the page never opened, so this was never reached"
    return
  fi
  CONSOLE_PAGE_OPENED=yes
  sleep 3

  # 1. The task page is open and has not been reloaded since. An event posted
  #    for this task now must arrive on it by itself.
  if ! post_event fixture-ship tool_started fmcheck-live-now; then
    record FAIL "a live event appears on the open task page without a reload" \
      "the fixture dashboard refused the event"
    record "$UNVERIFIED" "the task's earlier events survive unrelated fleet traffic" \
      "the fixture dashboard refused an event, so this was never reached"
    record "$UNVERIFIED" "unrelated traffic stays off the task's own timeline" \
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
    0) record ok "a live event appears on the open task page without a reload" \
         "posted after the task page was open, and it arrived on that same page" ;;
    1) record FAIL "a live event appears on the open task page without a reload" \
         "the posted event never reached the open page" ;;
    *) record "$UNVERIFIED" "a live event appears on the open task page without a reload" \
         "the page could not be read while waiting for the event" ;;
  esac

  # 2. Give this task some earlier events, then replace the fleet-wide live
  #    tail several times over with another task's traffic. The task page reads
  #    its own timeline from the durable store, so its earlier events must
  #    still be on the page after the tail has long since dropped them.
  local index
  for index in 1 2 3; do
    post_event fixture-ship tool_started "fmcheck-persist-$index" >/dev/null 2>&1
  done
  for index in $(seq 1 8); do
    post_event_batch fixture-filler "fmcheck-filler-$index" 30 >/dev/null 2>&1
    sleep 0.3
  done
  sleep 4

  local survived
  if forced persist fail; then
    survived=absent
  elif forced persist unverified; then
    survived=unreadable
  else
    survived=$(page_contains "fmcheck-persist-1")
  fi
  case "$survived" in
    present)
      record ok "the task's earlier events survive unrelated fleet traffic" \
        "240 unrelated events later, the task's own earlier events are still on its page" ;;
    absent)
      record FAIL "the task's earlier events survive unrelated fleet traffic" \
        "the earlier events are gone from the task page, so its timeline is only the live tail" ;;
    *)
      record "$UNVERIFIED" "the task's earlier events survive unrelated fleet traffic" \
        "the page could not be read after the unrelated traffic" ;;
  esac

  # 3. And none of that unrelated traffic may appear on this task's timeline:
  #    a per-task page that renders the fleet-wide stream would have passed
  #    both observations above while showing the reader someone else's work.
  local strayed
  if forced isolation fail; then
    strayed=present
  elif forced isolation unverified; then
    strayed=unreadable
  else
    strayed=$(page_contains "fmcheck-filler-1-0")
  fi
  case "$strayed" in
    absent)
      record ok "unrelated traffic stays off the task's own timeline" \
        "none of the other task's 240 events is on this task's page" ;;
    present)
      record FAIL "unrelated traffic stays off the task's own timeline" \
        "another task's events are rendered on this task's page" ;;
    *)
      record "$UNVERIFIED" "unrelated traffic stays off the task's own timeline" \
        "the page could not be read" ;;
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
destination is reachable from the visible navigation
view is on the page
view rendered with real height
view is legible
no credential-shaped or path-shaped value on any destination
the History view displays the completion records it read
every completed row shows its usage cell'

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
  check_width "${spec%%x*}" "${spec#*x}"
done

printf '\n-- task timeline --\n' | tee -a "$RESULT_FILE"
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
  record "$INAPPLICABLE" "a live event appears on the open task page without a reload" \
    "not applicable to a dashboard this command does not own: proving it means posting an event into that dashboard's own store. Run without --url."
  record "$INAPPLICABLE" "the task's earlier events survive unrelated fleet traffic" \
    "same reason: it needs unrelated events posted into that dashboard's own store. Run without --url."
  record "$INAPPLICABLE" "unrelated traffic stays off the task's own timeline" \
    "same reason: it needs another task's events posted into that dashboard's own store. Run without --url."
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
