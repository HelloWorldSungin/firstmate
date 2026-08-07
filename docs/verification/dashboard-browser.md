# Verification: the dashboard as a browser actually renders it

Why this record exists: every other dashboard test in this repo imports a browser module into node and asserts on the data it returns.
That proves the module and proves nothing about the page.
Seven dashboard stories shipped without anyone opening the result in a browser, so the guarantees below had never been observed at all - only inferred from module output.

Refresh with `FM_DASHBOARD_BROWSER_E2E=1 bin/fm-test-run.sh tests/fm-dashboard-browser.test.sh`, which runs the check against a fixture dashboard and against a deliberately broken page.
Point it at a running dashboard with `bin/fm-dashboard-browser-check.sh --url <url> --user <name> --password-file <path>`.
[`bin/fm-dashboard-browser-check.sh`](../../bin/fm-dashboard-browser-check.sh)'s header owns why this is an operator command rather than an unconditional CI test.

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
`bin/fm-dashboard-browser-check.sh --negative` serves a page that answers 200 and carries the title `Firstmate Fleet` with an empty body, and requires the assertions to fail:

```
$ bin/fm-dashboard-browser-check.sh --negative
6 passed, 24 failed
negative proof PASSED: the check refuses a page that renders nothing (24 assertions failed, as required)
```

The document-loaded assertion is among the six that still pass, which is the point of running this: a title alone satisfies it, and everything that reads what rendered does not.

## Limits of what a browser check can see here

`chrome-devtools-axi eval` truncates its result at about 8,060 characters with no error of its own, and a live fleet's page carries roughly 30,000.
Every text judgment is therefore made inside the page and returned as a short verdict; a probe that returned the rendered text would come back as invalid JSON on exactly the pages worth checking.

The browser this ran in has no colour emoji font, so the phone header's notification control drew as an empty box.
That is a property of this host's fonts rather than of the dashboard, and it is recorded because it is visible in the captured screenshots.
