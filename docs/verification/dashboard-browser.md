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
`n/a` exists because "I could not verify this" and "there was never anything here to verify" are different answers: the two live-stream observations can only be proved by posting events into a dashboard the check does not own, so under `--url` they are `n/a` rather than unverified, and a healthy dashboard checked that way still exits 0.

## The first run against a live fleet

Host: Linux 6.14.11, Chrome via `chrome-devtools-axi`, dashboard served by the installed user service.
Date: 2026-08-07.
Widths: 390x844 (phone) and 1440x900 (desktop).

Everything below was observed on the rendered page, not read out of an API response.

| Observation | Phone | Desktop |
| --- | --- | --- |
| Document loads, title `Firstmate Fleet` | yes | yes |
| Stylesheet applied (body surface painted) | `rgb(243, 244, 246)` | `rgb(243, 244, 246)` |
| Rendered text on the page | 30,073 characters | 30,233 characters |
| No sideways scroll | `scrollWidth 390 <= viewport 390` | `scrollWidth 1440 <= viewport 1440` |
| Captain inbox renders | 9,302px tall, legible | 6,656px tall, legible |
| Board renders | 3,068px tall, legible | 1,373px tall, legible |
| GBrain panel renders | 839px tall, legible | 587px tall, legible |
| Activity renders | 199px tall, legible | 161px tall, legible |
| History renders | 10,745px tall, legible | 8,251px tall, legible |
| Browser console | nothing printed | nothing printed |

The console was clean at both widths: no errors, no warnings, no failed subresource.

Two observations failed against the live service and are recorded as failures rather than smoothed over.
Absolute host paths are on the rendered page, which the next section covers.
Anchor navigation landed every section underneath the sticky bar, covered by 135px at phone width and 119px at desktop; that defect is fixed in [`assets/dashboard/styles.css`](../../assets/dashboard/styles.css) and [`assets/dashboard/app.js`](../../assets/dashboard/app.js) and is now pinned by the check.

The table above is what that run recorded, and it predates four things the harness was subsequently given: an assertion that the browser really is at the width each section is named after, an assertion that every completed record carries its usage panel, a requirement that the leak scan report how many patterns it ran over how many characters before an empty result counts as clean, and a console read taken after every navigation instead of once at the end.
Re-running against the live fleet needs its captain credential, so those four are recorded below from the runs that could be made rather than backfilled into a table they were not part of.

## The usage panel

Token usage is not a view of its own, which is why it needed saying separately.
It renders as a `USAGE` panel inside every completed-work card in History, one panel per record, so a board-level landmark would never have noticed it disappearing.

The check now counts the completion records on the page and the labelled usage panels among them, and requires one per record.
Observed on a fixture dashboard the check started itself, at both widths: 2 labelled panels across 2 completed records.
Both render the documented unavailable-with-reason form, `USAGE / unavailable / token usage could not be read (exit_nonzero)`, because no usage collector answers on this host.
That is the correct rendering of an absent collector and is not treated as a failure; what is treated as a failure is a record whose panel is not there at all.

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
The GBrain panel separately prints this home's index path in two adjacent cards, which is health detail from `bin/fm-gbrain-health.sh`.
At phone width the path is truncated to `/home/sungin/first…` in a card's project slot, which identifies nothing.

This is left as an observation rather than a fix: changing what `project` means is a fleet-data contract change reaching the snapshot, the board filter's identity, and completion manifests already written with those values.

## The live-stream guarantees

Proven against a fixture dashboard started by the check itself, because proving them against an installed dashboard would mean writing events into that dashboard's own store.
The server binary, the browser, and the page are real in both cases.

- An event posted while the page was open appeared on that page with no reload.
- A selected agent's earlier events were pushed out of the bounded fleet-wide tail by 240 unrelated events, confirmed absent from the page, fetched back by selecting that agent, and were still on the page after a further event replaced the live stream.

The second is the failure [`assets/dashboard/events.js`](../../assets/dashboard/events.js) says the backfill slot exists to avoid, so it is checked by driving the page rather than by reading the module.

## That the check can fail

A check that only ever reports success is worth nothing, so this is pinned rather than assumed.
`bin/fm-dashboard-browser-check.sh --negative` serves a page that answers 200 and carries the title `Firstmate Fleet` with an empty body, and requires the assertions that read what rendered to stop reporting `ok`:

```
$ bin/fm-dashboard-browser-check.sh --negative
6 passed, 24 failed, 4 could not be verified
negative proof PASSED: the check refuses a page that renders nothing (24 failed, 4 could not be verified, and no assertion that reads what rendered reported ok)
```

Counting failures would not have been enough.
A harness that had degraded to noticing nothing but a missing heading would still report a failure count, so the negative proof names the assertions that read the rendered page - the text, the stylesheet, each view's presence, height and landmarks, the leak scan, the nav landing, the usage panel - and requires that none of them reported `ok`.

Six observations still pass on that page and are meant to: the document loaded, because a title alone satisfies it; the browser was at the requested width, because it was; and nothing scrolls sideways, because nothing is there to.
Four record `????`, which is the third verdict earning its place: the leak scan reports `11 pattern(s) over 0 characters - the scan cannot be shown to have run` rather than declaring an empty page clean, and the usage observation reports that there was no completion record to carry a panel.

## Limits of what a browser check can see here

`chrome-devtools-axi eval` truncates its result at about 8,060 characters with no error of its own, and a live fleet's page carries roughly 30,000.
Every text judgment is therefore made inside the page and returned as a short verdict; a probe that returned the rendered text would come back as invalid JSON on exactly the pages worth checking.

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
