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
`n/a` exists because "I could not verify this" and "there was never anything here to verify" are different answers: the three task-timeline observations can only be proved by posting events into a dashboard the check does not own, so under `--url` they are `n/a` rather than unverified, and a healthy dashboard checked that way still exits 0.
Under `--url` against an idle fleet the four task-destination observations join them, because a board with no live task has no row to click and so no task page to open or measure, and the usage-cell observation joins them too, because a fleet that has delivered nothing renders History's designed empty state and has no completion row a cell could ever sit on.
Both stay `????` in fixture mode, where the fixture always publishes rows and their absence means something broke.
The leak scan is deliberately not among them: it reaches that destination in every mode by selecting a task address of its own, so an idle fleet does not reduce what it is required to have covered.
Proven, not assumed: a real server over an idle home, checked with `--url` on 2026-08-16, recorded `125 passed, 0 failed, 0 could not be verified, 23 not applicable to this target` with all 148 declared observations reconciled, and exited 0.

Which observations a run makes is not left to be kept in step by hand.
Each mode declares its observation set up front, and before the run exits that list is reconciled against the verdicts actually recorded; a declared observation with no verdict, one carrying two, or a verdict for something never declared names the offending observation and exits 4.
That pass exists because the same defect shape kept recurring in this harness - a verdict with no evidence behind it, evidence with no verdict reconciling it, a proof that passed with no assertion having run - and it caught a real instance on its own first run.

## The router-rebuild run

Host: Linux 6.14.11, Chrome via `chrome-devtools-axi`, fixture dashboard started by the check from this checkout.
Date: 2026-08-16, after the rebuild of the page into six destinations behind a hash router (issue 156).
Widths: 390x844 (phone), 899x844 and 900x844 (the two sides of the navigation boundary), 1440x900 (desktop).

The page under check is no longer one scrolling document, so the observation set changed shape with it: at every width, every destination is visited through the navigation control actually visible there, and the active view must be the only view in the DOM.
All 148 declared observations recorded `ok` and reconciled:

```
148 passed, 0 failed, 0 could not be verified
observation set reconciled: all 148 declared observations recorded exactly once
```

The set grew from 136 to 148 because the task detail now owes the same three per-destination measurements the five navigation destinations do - height, legibility, and sideways scroll - at each of the four widths.

What the run observed, with the load-bearing details:

- The document loads with title `Firstmate Fleet`, the body painted `rgb(10, 11, 13)`, and this stylesheet's own `--amber-soft` resolving, at all four widths.
- The rendered-page observation is structural, not a byte count: the router mounted a view root, the verdict strip carries its sentence, and the mounted view rendered its own designed content.
  It was a 200-character body-text floor until the idle fleet falsified it: the designed all-clear landing is 105 characters, so the quietest healthy page this dashboard ships failed the very check that claims a healthy dashboard passes.
  The structural form passes that page (observed: `the verdict strip reads [Nothing needs you] and #view-needs rendered 105 characters of its designed content`) and still fails the deliberately broken page, whose probe reads `mounted view [none], verdict [empty], 0 view characters`.
- At 390x844 and 899x844 every destination was reached through the bottom tab bar; at 900x844 and 1440x900 every destination was reached through the rail.
  That is the 899/900 boundary observed from both sides in one run - navigation vanishing below 900px is the defect that started the rebuild, so it is pinned per width rather than assumed from the stylesheet.
- At every width and every destination, the active view root was mounted and all 5 other view roots were absent from the DOM - absent, not hidden - and the address bar carried the destination's own hash.
- Opening a task from the Fleet board's own row landed on `#/task/<id>` with the task view mounted alone, all 6 view roots checked.
  That page is then held to the same three measurements the five navigation destinations are - real rendered height, its own landmark text, and nothing behind a horizontal swipe - because a destination a reader is sent to owes the same answers whether they reached it from a tab or from a board row.
  The fixture's first board row carries a pull request URL on purpose: that URL is the longest unbreakable token the page ever renders, so without one on the task the check opens, those measurements would run against a page that could not overflow whatever the stylesheet said.
- The History view displayed both of the fixture's completion records, agreeing with its own pager (`1-2 of 2`), each row carrying a non-empty usage cell.
  The fixture publishes those records through the real manifest writer, so this is the production record format rendering, not a lookalike envelope.
- No destination scrolls sideways: `scrollWidth <= viewport` on all six destinations at all four widths, the task detail included - 24 measurements, one per destination per width.
  The task detail is measured here for the first time in this record.
  Until it was, the sentence above was broader than the run beneath it: the check declared its swipe observation once per navigation destination, so the task page was opened and never measured, and it was in fact scrolling sideways at 390 CSS px (`scrollWidth` 421) and at 900 (`976`).
  A pull request URL is one unbreakable token, `flex-wrap` cannot break a single word, and the panel holding it is a grid item whose automatic minimum size is that token's width, so the shared track was widened past the viewport.
  Fixed in `assets/dashboard/styles.css` by letting the token wrap: `overflow-wrap: anywhere` on `.pr-line`, which is the one value that also shrinks a min-content width, and `min-width: 0` on `.panel` so the grid item can shrink to the track.
  The URL wraps whole and readable inside the panel; nothing is clipped, truncated, or hidden.
- The credential- and path-leak scan ran all 11 patterns over every destination's rendered page (6 scans per width) and matched nothing.
  What that scan covers is the operational chrome the dashboard itself composes - labels, filters, errors, status lines, notices - read as rendered attributes as well as rendered text, because a value written into a `title` or a `data-` attribute is on the page exactly as much as one written into a text node.
  It deliberately excludes worker-authored report bodies, which render as written with any absolute paths they narrate: that is the captain's decision on [issue 169](https://github.com/HelloWorldSungin/firstmate/issues/169), and the scan counts every `.report` region it skipped so an `ok` verdict states what it stepped over rather than implying it read it.
  The fixture registers every project and repo as a real absolute clone path, so an empty match is evidence about path-shaped data reaching the page rather than about a fixture that never held a path; the labels still render as the short names `label()` returns.
- The console was clean across all 37 windows read - one immediately before every navigation the run made and one after the last of each.

## The task timeline

Proven against the fixture dashboard, because proving these means posting events into the dashboard's own store; under `--url` all three record `n/a` with the reason in the line itself.

- An event posted for the open task after its page was up arrived on that page with no reload.
- The task's three earlier events were still on its page after 240 unrelated events had replaced the fleet-wide live tail several times over, because the task page's timeline is store-backed rather than a filtered view of the tail.
- None of those 240 unrelated events appeared on the task's page: a per-task timeline that rendered the fleet stream would have passed both observations above while showing the reader someone else's work.

## That the check can fail

A check that only ever reports success is worth nothing, so this is pinned rather than assumed.
`bin/fm-dashboard-browser-check.sh --negative` serves a page that answers 200 and carries the title `Firstmate Fleet` with an empty body, and requires every assertion that reads what rendered to record a refusal of its own.
Observed 2026-08-16:

```
8 passed, 28 failed, 108 could not be verified
observation set reconciled: all 144 declared observations recorded exactly once
negative proof PASSED: the check refuses a page that renders nothing (28 failed, 108 could not be verified, and every one of the 9 assertions that read what rendered recorded a FAIL or a ???? of its own)
```

The split recorded here previously read `32 failed, 92 could not be verified` against 132 declared.
That was wrong when it was written, not made wrong by this change: rerunning the pre-change script proves it, and it records 7 failed and 24 could not be verified at a single width - 28 and 96 over the four.
The twelve added observations are all `????` on a page with no board to open, which is the whole difference between 96 and 108.

On the empty page every destination's navigation control is missing, so the reachability assertion records `FAIL` at each width and the view assertions behind it record `????` - a destination that could not be reached is a view nobody observed, not a view seen to be fine.
The task destination records `????` the same way, because a page with no Fleet board has no row to open.
The nine named evidence assertions are the rendered text, the stylesheet, the reachability of each destination, the active view being the only one on the page, its height, its legibility, the leak scan, the History display, and the usage cells.
Requiring each to appear in `result.txt` as a `FAIL` or `????` line of its own is positive evidence it ran and refused; an earlier version inferred the proof from absences and once reported `PASSED` on a host whose browser bridge was busy.

## Executing each failure path rather than reasoning about it

`--negative` proves the assertions can fail as a set, against one broken page; `FM_DASHBOARD_BROWSER_FORCE=<check>:<branch>` makes each individual branch reachable on demand, and the script's header lists every pair.
An injected run stamps every forced branch into `result.txt`, refuses to run with `--negative`, and never exits 0.
Executed against the fixture on 2026-08-16, each printing its check's own wording:

```
$ FM_DASHBOARD_BROWSER_FORCE=nav:fail bin/fm-dashboard-browser-check.sh --width 390x844
     forced: nav:fail (FM_DASHBOARD_BROWSER_FORCE)
FAIL 390x844: the Needs you destination is reachable from the visible navigation - the route has 2 controls but none is visible at this width

$ FM_DASHBOARD_BROWSER_FORCE=view-present:fail bin/fm-dashboard-browser-check.sh --width 390x844
     forced: view-present:fail (FM_DASHBOARD_BROWSER_FORCE)
FAIL 390x844: only the Needs you view is on the page - another view is in the DOM beside it rather than absent: view-fleet

$ FM_DASHBOARD_BROWSER_FORCE=history:fail bin/fm-dashboard-browser-check.sh --width 390x844
     forced: history:fail (FM_DASHBOARD_BROWSER_FORCE)
FAIL 390x844: the History view displays the completion records it read - the fixture published 2 completion records but the page displays none

$ FM_DASHBOARD_BROWSER_FORCE=task-swipe:fail bin/fm-dashboard-browser-check.sh --width 390x844
     forced: task-swipe:fail (FM_DASHBOARD_BROWSER_FORCE)
FAIL 390x844: nothing is placed behind a horizontal swipe on Task detail - the document scrolls sideways at this destination: scrollWidth 630 > viewport 390
```

The task destination's other two branches were executed the same way on 2026-08-16: `task-height:fail` printed `only 10px tall`, and `task-legible:fail` printed `2 landmarks checked, missing: Task detail`.
An observation added to close a gap is worth nothing until its failure branch has been run rather than reasoned about, so these were executed before this record claimed the gap was closed.

`tests/fm-dashboard-browser.test.sh` pins those four pairs, the three `reconcile:` pairs that corrupt the emitted observation set itself, the refusal of unknown entries, and the refusal to combine injection with `--negative`.

## Limits of what a browser check can see here

`chrome-devtools-axi eval` truncates its result at about 8,060 characters.
Every text judgment - landmarks, leak patterns, row counts - is therefore made inside the page and returned as a short verdict with its coverage counts, so page size cannot break it and an empty result stays readable as evidence rather than as an absence.

`chrome-devtools-axi console` truncates its listing at 2,000 characters with no flag that lifts it, covers only the currently selected page since its last navigation, and its collector splits storage on Puppeteer's `framenavigated`, which fires for the fragment navigations every route click here performs, keeping just three buckets.
So the console is read while each bucket is still current - immediately before every navigation the check performs and once after the last of each window - with message ids accumulated across reads so a bucket seen twice counts once.
Each read is paged one message at a time, which puts the listing's own `Showing 1-1 of N` line in front of the verdict, and a read that does not produce that line records `????` instead of a clean console.

The browser this ran in has no colour emoji font, so any emoji glyph draws as an empty box; that is a property of this host's fonts rather than of the dashboard.

Every measurement in this record is taken in the dark theme.
That is what the page loads as by default, and no run here toggles away from it.
The stylesheet observation is written to be theme-independent by design - it requires a painted body and this stylesheet's own `--amber-soft`, both of which hold in either theme rather than pinning one theme's colours - but no observation renders the light theme, so nothing here is evidence about how the light theme paints.
