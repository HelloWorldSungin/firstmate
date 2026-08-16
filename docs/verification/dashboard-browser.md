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

Which observations a run makes is not left to be kept in step by hand.
Each mode declares its observation set up front, and before the run exits that list is reconciled against the verdicts actually recorded; a declared observation with no verdict, one carrying two, or a verdict for something never declared names the offending observation and exits 4.
That pass exists because the same defect shape kept recurring in this harness - a verdict with no evidence behind it, evidence with no verdict reconciling it, a proof that passed with no assertion having run - and it caught a real instance on its own first run.

## The router-rebuild run

Host: Linux 6.14.11, Chrome via `chrome-devtools-axi`, fixture dashboard started by the check from this checkout.
Date: 2026-08-16, after the rebuild of the page into six destinations behind a hash router (issue 156).
Widths: 390x844 (phone), 899x844 and 900x844 (the two sides of the navigation boundary), 1440x900 (desktop).

The page under check is no longer one scrolling document, so the observation set changed shape with it: at every width, every destination is visited through the navigation control actually visible there, and the active view must be the only view in the DOM.
All 136 declared observations recorded `ok` and reconciled:

```
136 passed, 0 failed, 0 could not be verified
observation set reconciled: all 136 declared observations recorded exactly once
```

What the run observed, with the load-bearing details:

- The document loads with title `Firstmate Fleet`, the body painted `rgb(10, 11, 13)`, and this stylesheet's own `--amber-soft` resolving, at all four widths.
- At 390x844 and 899x844 every destination was reached through the bottom tab bar; at 900x844 and 1440x900 every destination was reached through the rail.
  That is the 899/900 boundary observed from both sides in one run - navigation vanishing below 900px is the defect that started the rebuild, so it is pinned per width rather than assumed from the stylesheet.
- At every width and every destination, the active view root was mounted and all 5 other view roots were absent from the DOM - absent, not hidden - and the address bar carried the destination's own hash.
- Opening a task from the Fleet board's own row landed on `#/task/<id>` with the task view mounted alone, all 6 view roots checked.
- The History view displayed both of the fixture's completion records, agreeing with its own pager (`1-2 of 2`), each row carrying a non-empty usage cell.
  The fixture publishes those records through the real manifest writer, so this is the production record format rendering, not a lookalike envelope.
- No destination scrolls sideways: `scrollWidth <= viewport` on every route at every width.
- The credential- and path-leak scan ran all 11 patterns over every destination's rendered page (6 scans per width) and matched nothing.
  What that scan covers is the operational chrome the dashboard itself composes - labels, filters, errors, status lines, notices - read as rendered attributes as well as rendered text, because a value written into a `title` or a `data-` attribute is on the page exactly as much as one written into a text node.
  It deliberately excludes worker-authored report bodies, which render as written with any absolute paths they narrate: that is the captain's decision on [issue 169](https://github.com/HelloWorldSungin/firstmate/issues/169), and the scan counts every `.report` region it skipped so an `ok` verdict states what it stepped over rather than implying it read it.
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
8 passed, 32 failed, 92 could not be verified
observation set reconciled: all 132 declared observations recorded exactly once
negative proof PASSED: the check refuses a page that renders nothing (32 failed, 92 could not be verified, and every one of the 9 assertions that read what rendered recorded a FAIL or a ???? of its own)
```

On the empty page every destination's navigation control is missing, so the reachability assertion records `FAIL` at each width and the view assertions behind it record `????` - a destination that could not be reached is a view nobody observed, not a view seen to be fine.
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
```

`tests/fm-dashboard-browser.test.sh` pins those three pairs, the three `reconcile:` pairs that corrupt the emitted observation set itself, the refusal of unknown entries, and the refusal to combine injection with `--negative`.

## Limits of what a browser check can see here

`chrome-devtools-axi eval` truncates its result at about 8,060 characters.
Every text judgment - landmarks, leak patterns, row counts - is therefore made inside the page and returned as a short verdict with its coverage counts, so page size cannot break it and an empty result stays readable as evidence rather than as an absence.

`chrome-devtools-axi console` truncates its listing at 2,000 characters with no flag that lifts it, covers only the currently selected page since its last navigation, and its collector splits storage on Puppeteer's `framenavigated`, which fires for the fragment navigations every route click here performs, keeping just three buckets.
So the console is read while each bucket is still current - immediately before every navigation the check performs and once after the last of each window - with message ids accumulated across reads so a bucket seen twice counts once.
Each read is paged one message at a time, which puts the listing's own `Showing 1-1 of N` line in front of the verdict, and a read that does not produce that line records `????` instead of a clean console.

The browser this ran in has no colour emoji font, so any emoji glyph draws as an empty box; that is a property of this host's fonts rather than of the dashboard.
