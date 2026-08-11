# Verification: the dashboard as a browser actually renders it

Why this record exists: every other dashboard test in this repo imports a browser module into node and asserts on the data it returns.
That proves the module and proves nothing about the page.
Seven dashboard stories shipped without anyone opening the result in a browser, so the guarantees below had never been observed at all - only inferred from module output.

Refresh with `FM_DASHBOARD_BROWSER_E2E=1 bin/fm-test-run.sh tests/fm-dashboard-browser.test.sh`, which runs the check against a fixture dashboard and against a deliberately broken page.
Point it at a running dashboard with `bin/fm-dashboard-browser-check.sh --url <url> --user <name> --password-file <path>`.
[`bin/fm-dashboard-browser-check.sh`](../../bin/fm-dashboard-browser-check.sh)'s header owns why this is an operator command rather than an unconditional CI test.

Every observation below is one of four verdicts, not two.
`ok` means the thing it names was seen to happen, `FAIL` means it was seen not to happen, `????` means it could not be observed at all, and `n/a` means it does not apply to the target being checked in this mode.
`????` exists because folding "I could not read the evidence" into `ok` is precisely how a harness comes to rubber-stamp a page nobody looked at, which is the failure this whole area exists to end; a run carrying any `????` exits non-zero.
`n/a` exists because "I could not verify this" and "there was never anything here to verify" are different answers: the three live-stream observations can only be proved by posting events into a dashboard the check does not own, so under `--url` they are `n/a` rather than unverified, and a healthy dashboard checked that way still exits 0.

Which observations a run makes is not left to be kept in step by hand.
Each mode declares its observation set up front, and before the run exits that list is reconciled against the verdicts actually recorded; a declared observation with no verdict, one carrying two, or a verdict for something never declared names the offending observation and exits 4.
That pass exists because the same defect shape kept recurring in this harness - a verdict with no evidence behind it, evidence with no verdict reconciling it, a proof that passed with no assertion having run, and an observation that produced no verdict at all under `--url` while this file and the script header both claimed both modes observe identically.
Nothing structurally guaranteed that the set a mode claims to make equals the set it emits, and the reconciliation pass is that guarantee.

It found another instance of the same shape on its first real run, which is the clearest evidence it was needed.
"The X view is on the page" had a `FAIL` branch for an absent view and a `????` branch for an unreadable probe, and no verdict at all on the path where the view is present - so on a healthy page, five of the fifteen per-width view observations produced nothing, and every assertion that named them still passed.
The run recorded 48 verdicts against 58 declared and named all ten missing observations; the presence observation now records `ok` with the section it found, and the same run reconciles.

## The first run against a live fleet

Host: Linux 6.14.11, Chrome via `chrome-devtools-axi`, dashboard served by the installed user service.
Date: 2026-08-07 (table refreshed after issue 65 landed on the branch, live re-run the same day).
Widths: 390x844 (phone) and 1440x900 (desktop).

Everything below was observed on the rendered page, not read out of an API response.

Every row below was recorded against the captain's own running dashboard rather than a fixture, by a harness that already carried every assertion the table names.
An initial live run was made before the harness was strengthened; it was re-run afterwards so that no row here comes from an assertion the recorded run did not actually make.
The re-run carries both changes the first one predated: the token-totals observation beside the usage panel, and the leak scan widened from the five view sections to the whole rendered page, which is why the failing leak row now states the characters it covered and why that figure equals the rendered-text figure at the same width.

| Observation | Phone | Desktop |
| --- | --- | --- |
| Document loads, title `Firstmate Fleet` | yes | yes |
| Browser really is at this viewport | page reports 390x844 CSS px | page reports 1440x900 CSS px |
| Stylesheet applied | `rgb(243, 244, 246)`, `--gutter` resolves to `clamp(12px, 3.6vw, 20px)` | same |
| Rendered text on the page | 30,584 characters | 30,819 characters |
| No sideways scroll | `scrollWidth 390 <= viewport 390` | `scrollWidth 1440 <= viewport 1440` |
| Captain inbox renders | 10,132px tall, all 2 landmarks | 7,200px tall, all 2 landmarks |
| Board renders | 2,537px tall, all 4 landmarks | 1,373px tall, all 4 landmarks |
| GBrain panel renders | 839px tall, all 2 landmarks | 587px tall, all 2 landmarks |
| Activity renders | 199px tall, all 3 landmarks | 161px tall, all 3 landmarks |
| History renders | 10,673px tall, all 3 landmarks | 8,125px tall, all 3 landmarks |
| Every completed record shows its usage panel | 25 panels across 25 records | 25 panels across 25 records |
| Collected usage shows token totals where attributed | no attributed totals on the page (home may not collect yet) | same |
| No credential-shaped or path-shaped value | **failed**, 11 patterns over 30,584 characters, see below | **failed**, 11 patterns over 30,819 characters, see below |
| Anchor navigation lands clear of the sticky bar | **passed**, heading 12-23px below the bar | **passed**, heading 12-23px below the bar |
| Browser console | 7 windows read, all empty | 8 windows read, all empty |

The console result is worth stating precisely, because the earlier version of this check could not have supported it.
The browser tool returns only the current navigation's messages and its collector discards all but the last three navigation buckets, so a single read taken at the end of a width saw almost nothing.
The run above took a console read immediately before every navigation it made and one after the last of each: seven windows at the first width, eight at the second because the second width's own page open is a navigation with a bucket standing before it, fifteen in total.
Every one was empty: no errors, no warnings, no failed subresource.
The check records one console verdict for the whole run rather than one per width, so the split above says where those windows were read, not that the verdict was reached twice.

One observation failed against the live service and is recorded as a failure rather than smoothed over.
Absolute host paths are on the rendered page, which the next section covers.

The refresh run above recorded anchor navigation landing clear of the sticky bar on the live service at both widths, with the heading 12-23px below the bar after each link was followed.
That matches the fixture behaviour this branch's assets define; an earlier live run on the same day still had the section hidden under the bar before those assets reached the installed checkout.

## The usage panel

Token usage is not a view of its own, which is why it needed saying separately.
It renders as a `USAGE` panel inside every completed-work card in History, one panel per record, so a board-level landmark would never have noticed it disappearing.

The check now counts the completion records on the page and the labelled usage panels among them, and requires one per record.
Observed against the captain's live dashboard on the refresh run, at both widths: 25 labelled panels across 25 completed records, so no record is missing its panel.
The token-totals observation beside it recorded `ok` with no attributed totals on the page, which the check words as the home possibly not collecting usage yet rather than a collector failure on every card.
An earlier live run the same day still showed `exit_nonzero` on each panel before the issue 65 fix reached the running service; that symptom is filed as [issue 65](https://github.com/HelloWorldSungin/firstmate/issues/65), whose store half - read-only store opens and a self-contained at-rest store shape - is owned by [usage accounting](../usage-accounting.md).
Landing that half does not retire the `exit_nonzero` form: the collector failure behind it was reproduced on this same home on 2026-08-08 against a healthy 37 MB store, because the hardened unit's sandbox left SQLite no writable scratch path for a read-only query's temp file.
[The generated unit record](dashboard-service-unit.md) owns that second mechanism, its reproduction, and the read-only opener that removes it.
Epic 4's criterion that token usage is visible per task still needs a live run where at least one completion record carries attributed totals; this refresh records the panel and observation machinery honest about the current fleet state rather than smoothing over it.

A panel that is present is not yet a number, so the check now makes a second observation per width beside it: where a completion record carries attributed usage, its panel shows the token total.
It records `ok` when at least one record on the page renders a total, and `????` when there is no completion record to look at, on the same reasoning as the panel observation above.
It records `FAIL` for the shape issue 65 produced - a record whose panel shows the operational form, meaning the collector ran and failed - and `ok` with that stated when no record shows attributed totals at all, because a home that has not collected usage yet is not a page this check can improve by refusing it.

A home with no completed work has no history cards, and therefore no usage panel to look at.
That case records `????` rather than a pass or a failure, and was observed that way against a dashboard started over an empty home:

```
???? 390x844: every completed record shows its usage panel - no completion record is on the page, so there is no usage panel to look at
```

## Absolute host paths reach the rendered page

The board and history cards render `tasks[].project` verbatim, and on this fleet that field carries an absolute path:

```
$ curl -sS -u captain:… http://127.0.0.1:8787/api/snapshot | jq -c '[.snapshot.tasks[].project] | unique'
["/home/sungin/firstmate","/home/sungin/firstmate/projects/BZ-SIM","/home/sungin/firstmate/projects/arknode-vault"]
```

So the value originates in the fleet snapshot, not in the dashboard's rendering, and the dashboard is faithfully showing what it was given.
The GBrain panel separately prints this home's index path in two adjacent cards, which is health detail from `bin/fm-gbrain-health.sh`, and at phone width that path wraps mid-token rather than at a path separator.
At phone width the path is truncated to `/home/sungin/first…` in a card's project slot, which identifies nothing.

This is left as an observation rather than a fix: changing what `project` means is a fleet-data contract change reaching the snapshot, the board filter's identity, and completion manifests already written with those values.

What that row does and does not carry is worth being exact about, because a failure that cannot state its coverage is the same defect as a pass that verified nothing wearing the other mask.
The pattern count is established by the verdict itself: the scan reaches `ok` or `FAIL` only after the page confirms it compiled all eleven of this check's patterns, and records `????` otherwise, so a recorded failure is a recorded eleven-pattern scan.
The character count is carried by the row above, because the re-run was made after the failing branch began printing its coverage and after the scan was widened from the five view sections to the whole rendered page; it equals the rendered-text figure at the same width, which is what covering the whole page looks like from here.
The widening matters here specifically: `assets/dashboard/index.html` puts `<section id="notice-region">` outside `.board-content`, and `assets/dashboard/app.js` renders a failed snapshot command's raw `stderr` into a `<code>` element inside it, which is the likeliest carrier of an absolute host path anywhere on the page and was outside what the scan covered.

## Two more observations from that run

The Activity view's Agent filter offers only the agents that have events in the bounded live tail the page is currently holding, because its choices are derived from those events rather than from the fleet.
An agent whose events have already aged out of that tail is absent from the filter, while a board card's Timeline button still reaches it, because that button selects the task directly and fetches its backfill.

On a phone the board's empty columns take roughly 450px before the first populated column, so a reader arriving at the board scrolls past several empty column headings before reaching any work.

Both are questions about what these views should offer rather than faults in how they render, so this run records them instead of changing them.

## The live-stream guarantees

Proven against a fixture dashboard started by the check itself, because proving them against an installed dashboard would mean writing events into that dashboard's own store.
The server binary, the browser, and the page are real in both cases.

- An event posted while the page was open appeared on that page with no reload.
- A selected agent's earlier events were pushed out of the bounded fleet-wide tail by 240 unrelated events, confirmed absent from the page, fetched back by selecting that agent, and were still on the page after a further event replaced the live stream.

The second is the failure [`assets/dashboard/events.js`](../../assets/dashboard/events.js) says the backfill slot exists to avoid, so it is checked by driving the page rather than by reading the module.

Against the captain's live dashboard these observations record `n/a` rather than a pass or a `????`, and the run says why in the line itself:

```
n/a  a live event appears without a reload - not applicable to a dashboard this command does not own: proving it means posting an event into that dashboard's own store. Run without --url.
```

The run recorded above emitted two such lines rather than three.
The middle observation - that the agent's earlier events really did leave the live stream, which is what makes the backfill result mean anything more than the live tail - resolved to no verdict at all in that mode, so a `--url` result was one observation shorter than a fixture one with nothing saying so.
It now records `n/a` alongside the other two, for the same reason they do, and the reconciliation pass is what makes a mode dropping an observation a hard failure rather than a shorter file.

That distinction is what lets a healthy live check exit 0 at all.
While these two folded into `????`, every `--url` run failed by construction however healthy the page was, which left the only mode that can be pointed at the real dashboard with no usable exit status to automate against.

## That the check can fail

A check that only ever reports success is worth nothing, so this is pinned rather than assumed.
`bin/fm-dashboard-browser-check.sh --negative` serves a page that answers 200 and carries the title `Firstmate Fleet` with an empty body, and requires every assertion that reads what rendered to record a refusal of its own:

```
$ bin/fm-dashboard-browser-check.sh --negative
6 passed, 44 failed, 6 could not be verified
negative proof PASSED: the check refuses a page that renders nothing (44 failed, 6 could not be verified, and every one of the 8 assertions that read what rendered recorded a FAIL or a ???? of its own)
```

The six unverified verdicts are three per width: the usage panel and the token totals, on a page with no completion record to carry either, and the leak scan, which over an empty body cannot be shown to have run at all.
The console is not among them, because `--negative` exits after the widths, before the live stream and the console, and declares its observation set accordingly.
The eight named assertions are unchanged, and the new observations are not among them.

Counting failures would not have been enough.
A harness that had degraded to noticing nothing but a missing heading would still report a failure count, so the negative proof names the assertions that read the rendered page - the text, the stylesheet, each view's presence, height and landmarks, the leak scan, the nav landing, the usage panel - and checks each one individually.

What it requires of each is the point, and it is the same rule every observation above obeys.
An earlier version required only that the assertion was absent from the run's pass log, which an assertion that never executed satisfies just as well as one that refused the page: on a host whose browser bridge was busy, `browser resize` failed at both widths, the run recorded two early failures, the pass log was empty, and the negative proof reported `PASSED` having never rendered anything.
It now requires each named assertion to appear in `result.txt` as a `FAIL` or a `????` line of its own, which is positive evidence that it ran and refused, rather than an inference from two absences.

Six observations still pass on that page and are meant to: the document loaded, because a title alone satisfies it; the browser was at the requested width, because it was; and nothing scrolls sideways, because nothing is there to.
Six recorded `????` in that run, which is the third verdict earning its place: at each width the leak scan reports `11 pattern(s) over 0 characters - the scan cannot be shown to have run` rather than declaring an empty page clean, and both usage observations report that there was no completion record to carry a panel or a total.

## Executing each failure path rather than reasoning about it

`--negative` proves the assertions can fail as a set, against one broken page.
It cannot reach a branch that page does not happen to trigger - a probe that will not decode, a console window that could not be read, an event that never arrives - and reading the code and concluding those branches would work is not evidence that they do.

`FM_DASHBOARD_BROWSER_FORCE=<check>:<branch>,...` makes each one reachable on demand.
Each entry corrupts the single value the named check judges - the measured width, the scanned character count, the landing offset - so the check's own branch runs and prints its own detail; nothing rewrites a verdict after the fact.
The script's header lists every pair it accepts, an entry outside that list is a usage error rather than a silent no-op, and it refuses to run alongside `--negative`, whose meaning it would destroy.

It cannot be mistaken for a check of the dashboard: it is inert unless set, it stamps every forced branch into `result.txt` as it takes it, and an injected run never exits 0 whatever the page did.

```
$ FM_DASHBOARD_BROWSER_FORCE=nav:fail bin/fm-dashboard-browser-check.sh --width 390x844
     forced: nav:fail (FM_DASHBOARD_BROWSER_FORCE)
FAIL 390x844: the Captain inbox link lands on that section's heading - the sticky bar hides the top of the section by 119px
```

The thirty pairs that existed when this was written were each executed against the fixture dashboard, and each printed the branch it names.
Two of them first ran alongside another forced fault that removed their precondition, so each was re-forced on its own to get there, for the reason the script's header gives under the variable.
The three `reconcile:` pairs added afterwards corrupt the emitted observation set rather than a measurement, because that set is what the reconciliation pass judges; `tests/fm-dashboard-browser.test.sh` executes all three and requires each to fail the run by naming the observation at fault.

Two more pairs came with the issue 65 fix, `usage:tokens` and `usage:operational`, and they reach the two answering branches of the token-totals observation.
Each supplies the state its branch is reached from rather than only the value that branch judges, because both are decided after earlier branches that would otherwise answer first - setting the operational count alone on a page whose totals really did render returns `ok` above it and proves nothing - and the script's comment at that check says so.
Both were executed against the fixture dashboard on 2026-08-07:

```
$ FM_DASHBOARD_BROWSER_FORCE=usage:tokens bin/fm-dashboard-browser-check.sh --width 390x844
     forced: usage:tokens (FM_DASHBOARD_BROWSER_FORCE)
ok   390x844: collected usage shows token totals where attributed - 1 completion record(s) rendered token totals

$ FM_DASHBOARD_BROWSER_FORCE=usage:operational bin/fm-dashboard-browser-check.sh --width 390x844
     forced: usage:operational (FM_DASHBOARD_BROWSER_FORCE)
FAIL 390x844: collected usage shows token totals where attributed - 1 completion record(s) show an operational usage failure instead of totals
```

`tests/fm-dashboard-browser.test.sh` pins both pairs the same way it pins `nav:fail`.

## Limits of what a browser check can see here

`chrome-devtools-axi eval` truncates its result at about 8,060 characters, and a live fleet's page carries roughly 30,000.
It says so and offers a way out: `eval` is registered with a `--full` flag, and on truncation it emits `Result was truncated - re-run with --full flag`.
So a probe that shipped the rendered text out could be made to work, and the reason every text judgment is instead made inside the page and returned as a short verdict is not that limit.
It is that a verdict is a fixed small result whatever the fleet is doing, so page size cannot break it at all, while a probe returning the rendered text sits one page growth away from coming back truncated on exactly the pages worth checking - and it carries the coverage counts that make an empty result readable as evidence rather than as an absence.

`chrome-devtools-axi console` has the same shape of limit and two more besides: it truncates its listing at 2,000 characters, head only, with no flag that lifts it; the listing covers only the currently selected page since its last navigation; and the collector behind it splits its storage on Puppeteer's `framenavigated`, which fires for same-document navigations too, keeping just three buckets.
Each of the five nav-link clicks the check makes is a fragment navigation, so the bucket holding everything the page printed while loading and first rendering is discarded outright five clicks later.
Measured on this host, not inferred: a message logged at load was gone from the listing after five fragment navigations.

So a read taken once per width at the end would see the moment after the last nav click and nothing else.
The console is instead read while each bucket is still the current one - immediately before every navigation the check performs, which captures that bucket entire, and once after the last navigation of each window - and the message ids are accumulated across those reads so a bucket two adjacent reads both see is counted once.
Each read is paged one message at a time, which puts the listing's own `Showing 1-1 of N` line - the count of everything there is, not of what fitted - in front of the verdict.
A read that does not produce that line, or a browser command that exits non-zero, is a console window this run could not read, and it records `????` instead of a clean console.

The nav landing is measured rather than inferred: the check scrolls away from the target, follows the link, waits inside the page for the scroll to stop moving, and then requires the address bar to name the section and its heading to come to rest clear of the sticky bar and within 48px of it.
On the fixture that lands at 12px for a section with no top rule and 23px for one with, and where a section is too near the end of the document to be scrolled that far, the check requires the page to have reached its scroll limit with the heading on screen rather than accepting any offset.

The browser this ran in has no colour emoji font, so the phone header's notification control drew as an empty box.
That is a property of this host's fonts rather than of the dashboard, and it is recorded because it is visible in the captured screenshots.
