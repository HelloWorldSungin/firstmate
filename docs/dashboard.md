# Fleet dashboard

The fleet dashboard is a mobile-first, read-only captain inbox, kanban view, completed-work history, and live agent-activity timeline over [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh)'s versioned JSON contract.
It never dispatches, steers, merges, tears down, or writes fleet state: its one write is the agent-event store it owns outside the operational home ([dashboard events](dashboard-events.md)).
Stopping the dashboard has no effect on Firstmate supervision.

It listens only on loopback unless you ask for something else, and asking for something else requires credentials first.
[Remote access](dashboard-remote-access.md) owns that whole posture: what authentication protects, what belongs to your own network rather than to Firstmate, and how to confirm the boundary from off the machine.

## Install the user service

Node.js 22 or newer and user-level systemd are required.
Run the installer from the tracked Firstmate checkout whose dashboard assets should be served:

```sh
bin/fm-dashboard-install.sh --fm-home /path/to/firstmate
```

The installer uses no sudo.
It writes a private environment file and `firstmate-dashboard.service` under the user configuration root (`$XDG_CONFIG_HOME`, or `~/.config` by default), then enables the service for boot-persistent startup.
Run `bin/fm-dashboard-install.sh --help` for the exact configuration flags and environment names.

Open `http://127.0.0.1:8787` on the same machine after the service starts.
The server accepts only a numeric bind address, and only `127.0.0.1` or `::1` without configured credentials.

### Install it from a checkout that will still be there

The unit names one dashboard server by absolute path and keeps naming it across reboots, so the installer refuses to write a persistent service that runs from a linked git worktree: whoever made that worktree will reclaim it, and the service would work until the day it silently did not.
The same refusal covers the operational home the unit pins, because a service whose fleet home and event store are reclaimed is as broken as one whose server is.

Trying a change from a worktree is legitimate, so `--allow-worktree` says that is what you meant.
To install the persistent service for a permanent checkout while running a newer installer from somewhere else, name it:

```sh
bin/fm-dashboard-install.sh --checkout /path/to/firstmate
```

With neither `FM_HOME` nor `--fm-home` set, the operational home follows `--checkout` rather than staying where the installer you ran happens to live.
Pass `--fm-home` when the fleet home is somewhere else.

## Runtime behavior

[`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs)'s header owns the environment configuration names and defaults.
The server runs the fixed adjacent `fm-fleet-snapshot.sh --json` command with a hard deadline, keeps at most one execution active, coalesces poll and debounced file triggers, and pushes result envelopes to the browser with server-sent events.
No HTTP input can select a command, argument, or fleet path.

A failed refresh keeps the last valid snapshot visible and labels it stale with bounded error detail.
The server also pushes a stale transition as soon as the last successful snapshot reaches the configured age threshold, even when the next poll has not started.
The empty, first-run, missing-command, timeout, malformed-JSON, unsupported-schema, and stale-last-good cases remain explicit in the same board surface.
The browser reconnects its event stream with bounded exponential backoff, while periodic polling guarantees eventual updates even when a filesystem notification is unavailable.

## Reading it on a phone or a foldable

The layout is fluid across the whole width range rather than correct at a few chosen sizes, and 320 CSS px is a supported width.
Nothing is placed behind a horizontal swipe: no region of the page scrolls sideways, so every fleet health signal, board column, and secondmate row is reachable by scrolling down.
The one exception is inside a rendered report, whose content is worker-written: a code block or table too wide for the screen scrolls inside its own box rather than stretching the page around it.
The fleet health signals appear in full as cards in the "Needs you" view at every width, and the compact chip row in the sticky bar is an additional summary carried only by the wide sidebar layout, where the header has room for it.
Full-height regions use dynamic viewport units, so a mobile browser's address bar sliding in and out does not clip content, and page edges respect safe-area insets.
Following a nav link, or a board card's Timeline button, lands the target section with its eyebrow and heading clear of the sticky bar rather than underneath it, at whatever height that bar's own contents have taken at the current width.

Folding or unfolding a device reflows the page while it stays loaded.
The page is never reloaded for that, so the selected view, open filter panels, filter and search choices, the history page being read, an open report, and in-flight data all survive it.
Because the number of columns changes, keeping the raw scroll offset would not keep the reader's place, so whatever was being read is put back at the same position on screen instead, including a card that a fleet update rebuilt in the meantime.
A height-only change, which is what the browser's own chrome produces, never moves the page.

Where a platform exposes a genuine hinge seam through the standard viewport-segment media features, grid gutters widen to it.
That is progressive enhancement only: a book-style foldable's inner display reports a single continuous panel in the normal case, and the layout does not depend on the seam being reported at all.

## Needs you

The first view is the captain inbox: open decisions, blockers, failures, credential requests, and pull requests whose normalized status is genuinely review or merge ready, sorted oldest first, above a fleet health strip.
[`docs/dashboard-inbox-policy.md`](dashboard-inbox-policy.md) owns that policy in full, including what makes a pull request green, what turns each health signal amber or red, and how overlapping signals deduplicate into one item.
The short version worth knowing before reading it: a pull request is shown as green only when its normalized checks, review, and mergeability all say so, and anything missing or stale is drawn as an explicit unknown rather than as a pass.

## Board

Every card column and displayed action comes directly from `tasks[].card` in the snapshot, and the top-level `card_precedence` array determines column order.
Each task card renders its id, title, project, kind, harness, model, effort, state detail, full PR URL, endpoint liveness, last-event age, and available work-item links from that same task row.
Unknown endpoint liveness remains distinct from alive or dead.
Work-item references with unavailable enrichment or an unsupported forge remain plain links, while a task without a reference has no work-item affordance.
Project, harness, model, kind, and state filters derive their choices from the snapshot.
The UI contains no forge adapter or independent fleet-state parser.
Persistent secondmates stay in their own lane.

## History

History lists completed work from the durable completion manifests in `data/<id>/outcome.json`, which [`docs/fleet-data-contracts.md`](fleet-data-contracts.md) owns.
This page states the history policy for humans, and [`assets/dashboard/history.js`](../assets/dashboard/history.js) is its single executable copy.
It is deliberately not built from task metadata or from the Done backlog: cleanup removes the volatile records and the backlog keeps only its recent Done entries, so a view sourced from either would lose a task that finished a few weeks ago.
A completed investigation therefore stays browsable, with its report, after cleanup and after backlog pruning.

Each record shows the task title and id, project, kind, harness, model, effort, its recorded timestamps and duration, the outcome, the complete pull request URL with the pull-request fields that were recorded at completion, any linked work item, and token usage when it is available.
Work delivered against an issue links back to that issue; an unreachable or unsupported tracker stays a plain link, and work with no linked item simply has none.
History computes no pull-request readiness verdict of its own - [`docs/dashboard-inbox-policy.md`](dashboard-inbox-policy.md) owns that judgment for live work, and history shows the observation that was recorded, including its unknowns.

Project, harness, model, kind, outcome, and completion-date filters, a bounded text search over the indexed fields, and pagination all run over the records the server read.
Search covers ids, titles, projects, dispatch metadata, outcome detail, pull request URLs, and work-item links; it does not read report bodies.
The server reads a bounded number of records per refresh, and says so in the view when more completed work is stored than was read - raise `--history-limit` to widen it.
A manifest that is missing, corrupt, or written against a schema version this dashboard does not accept is listed with its id and the reason it could not be used, never silently skipped.
Token usage is presence-gated on the fleet's token-usage collector and on its `data/usage.db` store existing under this home: with no store there is nothing to read, and no collector child is spawned at all.
Totals appear when that store has attributed usage to a task, and every other state renders with its reason rather than as a zero, because a blank cell would read as "this task cost nothing", which is a different claim from "we do not know".
Those states are deliberately not collapsed together. No collector, no store, usage reads switched off for this dashboard, no attributed row for this task, or a collected row with no readable total all read as `unavailable`, which is nothing to fix; a collector that failed, or one whose output this dashboard does not recognize, reads as needing attention and is drawn distinctly, which is.
A failed read keeps the last good one visible and says so, the way a failed snapshot refresh does, for two genuinely different reasons.
The store has writers - teardown refreshes it on every archive and bootstrap on every locked session start - and each holds it in WAL for the length of its window, so a writer that exits without closing leaves a store whose wal-index the dashboard's read-only open cannot build without write access to `data/`, and the read fails rather than reads empty.
The at-rest `delete` journal mode the store is normally found in is the outcome that contract protects, not evidence the failure cannot happen.
The collector can also fail because the host sandbox leaves SQLite no writable scratch path for the temp file a read-only query needs; the generated unit pairs `ProtectSystem=strict` with `ProtectHome=read-only`, which between them refuse `/tmp`, `/var/tmp`, `/usr/tmp`, and `$HOME`, and a read that reaches for a temp file there exits `disk I/O error` while the store itself is healthy.
That half is answered in the reader rather than in the sandbox: [usage-accounting.md](usage-accounting.md)'s shared opener keeps SQLite temp storage in memory on its read-only open, so no consumer of these stores asks the filesystem for scratch space and no unit can deny it.
The unit therefore carries no scratch directive of its own; [`docs/verification/dashboard-service-unit.md`](verification/dashboard-service-unit.md) pins the reproduced combination, the working fix, and why `PrivateTmp=yes` is the wrong answer to it.
A task the retained read does not carry yet says exactly that, so a just-archived record is never reported as having cost nothing.
[usage-accounting.md](usage-accounting.md) owns the store itself, including the read-only open that lets the hardened user service read it without write access to `data/`.
Semantic search over captured report content belongs to the separate [GBrain](#gbrain) panel; history is fully usable without it.

## Activity

The Activity view is a live per-agent event timeline: session started, prompt submitted, tool started, tool finished, turn ended, session ended, newest first and filterable by agent, harness, and event.
Each board card carries a Timeline button that narrows the view to that one agent.

It is off until you turn it on, and [`docs/dashboard-events.md`](dashboard-events.md) owns the whole contract: how to enable and disable it, which harnesses have an adapter and what the others degrade to, what an event may and may not contain, where the events are stored and why that is not the fleet's own data directory, and why a dashboard that is down or slow costs a working agent nothing.
The short version worth knowing before reading it: instrumentation is one command on and one command off, redaction is an allowlist at both the producing and the receiving end, and the reporting hooks are additive to the ones firstmate already installs and cannot change what any of them decide.

## GBrain

The GBrain panel is a read-only view of this home's optional brain: its presence, pinned version, index state, retrieval health, hosted-synthesis health, durable capture outbox, and maintenance state.
None of those are fleet health signals.
The brain is presence-gated and every read of it is bounded, so a brain that is absent, stopped, or slow degrades the panel and never the dashboard or Firstmate supervision.
The panel refreshes on the history poll rather than the faster snapshot poll, because a health read probes endpoints that can take seconds, and it says how old the last successful read is.
[`bin/fm-gbrain-health.sh`](../bin/fm-gbrain-health.sh) owns that read, its `fm-gbrain-health.v1` shape, and the single probe budget every step inside it draws from; the server bounds the child inside the same deadline it gives a snapshot refresh, so a brain that answers nothing cannot hold up a poll.

A home without a brain reports `configured: false` and renders one card that says so, which is the normal state of a fleet that has not adopted GBrain.
A configured home whose brain is not yet bootstrapped shows `index.state: absent`, which is not a fault; capture stays off and captured documents wait in the durable outbox.
A configured home whose embedding or reranker endpoint is unreachable reports `retrieval.state: degraded` and names the leg that went, while `synthesis.state` stays `ok` because local search keeps working.
A configured home whose hosted synthesis provider is down reports `synthesis.state: degraded` while retrieval stays `ok`.
A brain the operator has paused for care reports `maintenance.state: upgrading` or `reindexing` with the operator's own detail text, and [`docs/gbrain.md`](gbrain.md#announce-a-maintenance-window) owns when to announce that and how to clear it.

The search affordance below the strip is a POST to `/api/gbrain/search` that runs [`bin/fm-recall.sh`](../bin/fm-recall.sh) `search` over the read-only scopes this home already holds.
The query reaches the wrapper as an argument array after `--`, never interpolated into a shell command, so a shell metacharacter in a query is a character to search for rather than syntax.
The endpoint bounds the query size, the result count, and how long one search may take, and it admits one search at a time.
Results come back in a closed vocabulary - source, slug, title, score, excerpt, stale - with anything outside it dropped rather than passed through, and [`assets/dashboard/gbrain.js`](../assets/dashboard/gbrain.js) builds every result node with `createElement` and `textContent`, so nothing in a stored brain document can become markup or restructure the page.

The panel sits between Board and Activity, and it is presence-gated as a whole: removing `config/gbrain.json` removes the polling cost, the search affordance, and the probes together.

## Rendered reports

A retained report is arbitrary content written by a worker, so the dashboard renders it under an explicit policy that [`assets/dashboard/markdown.js`](../assets/dashboard/markdown.js) implements and `tests/fm-dashboard-history.test.sh` pins with hostile fixtures.

The renderer never produces an HTML string and the browser never parses one: Markdown becomes a tree of plain nodes that the page builds with `createElement`, `createTextNode`, and an attribute allowlist.
Raw HTML in a report is therefore never markup - a `<script>` tag arrives on the page as the literal characters a reader sees.
A link survives only when it is absolute and its protocol is `http`, `https`, or `mailto`; `javascript:`, `data:`, and every other protocol, along with protocol-relative and relative references, are refused and the refusal is shown next to the surviving label rather than hidden.
Images are rendered as labeled external links instead of `<img>` elements, because the page's content-security policy forbids remote images and a broken-image icon would read as a corrupt report rather than as policy.
Document size, line count, node count, and nesting are all bounded, and every truncation is stated above the report.

The report itself is fetched by task id, and that id selects nothing on its own: it must name a task the current history published with a retained report, and the file is then read from this home's own data directory rather than from the path recorded in the manifest.
A report that is missing, is no longer a plain file, or resolves outside that directory is refused with a reason, and a report larger than the configured byte limit is served truncated and labeled.

## Checking it in a browser

The module-level tests prove what each browser module returns; they cannot prove that the page loads, that the stylesheet arrived, that the layout holds at 390 CSS px, or that the console is clean.
[`bin/fm-dashboard-browser-check.sh`](../bin/fm-dashboard-browser-check.sh) drives the real page in a real browser and records what it rendered, at a phone width and a desktop width.

Run it with no arguments and it starts its own dashboard from this checkout on an ephemeral loopback port over a throwaway home, so it never touches an installed service.
Pass `--url` with `--user` and `--password-file` to point it at a running dashboard; the password is held by a loopback-only front and never enters the URL the browser opens, so it reaches neither the browser's history nor any evidence the check captures, and the dashboard's own exposure, authentication, and credentials are untouched.
That front does add one thing, which its header states rather than claims away: it attaches the credential to everything it forwards and authorizes nothing itself, so for the length of the check it is an unauthenticated door to the authenticated dashboard, bound to loopback on an ephemeral port and gone when the check exits.
On a host with other tenants that is worth weighing before running `--url`.
`--negative` proves the check can still fail, by running the same assertions against a page that renders nothing.
`FM_DASHBOARD_BROWSER_FORCE=<check>:<branch>` serves the same purpose one check at a time, forcing a named check down its failure or could-not-verify branch so that path can be executed and read rather than reasoned about; it is inert unless set and an injected run never exits 0, so it can never be mistaken for a check of the dashboard.

Each observation is recorded as `ok`, `FAIL`, `????`, or `n/a`.
`????` is not a pass: it means the observation could not be made at all, because a probe would not decode, a browser command failed, or a scan cannot be shown to have run, and a run carrying any `????` exits non-zero for the same reason a failing one does - a check that could not look is not a check that saw nothing wrong.
`n/a` is the separate case of an observation this mode was never able to make: the three live-stream observations under `--url`, which can only be proved by posting events into a dashboard this command does not own.
It is reported and counted but does not fail the run, so a healthy dashboard checked with `--url` exits 0; every other observation is made identically in both modes.

That last claim is structural rather than a promise anyone has to keep by hand.
Each mode declares the observations it makes and reconciles that list against the verdicts it recorded before it exits, so an observation left unrecorded, recorded twice, or recorded without having been declared fails the run by name and exits 4 rather than showing up as a quietly smaller result.

It is a command rather than a test CI runs, because one Chrome session per host is shared state that parallel test shards would fight over and CI has no browser at all; `tests/fm-dashboard-browser.test.sh` is the opt-in wrapper, and the script's header owns that tradeoff in full.
Run it after changing anything the page renders, and before believing any claim about what the dashboard shows.
[`docs/verification/dashboard-browser.md`](verification/dashboard-browser.md) records what the first run observed.

## Updating the installed service

Re-run the installer with the desired values to replace the environment file and restart the enabled service.
The environment file carries the service's value for every configuration name [`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs)'s header documents.
Use ordinary user-level systemd status and journal commands to inspect startup failures.

Updating the code is the other case, and it does not go through the installer.
The unit names the server by absolute path inside the checkout it was installed from and holds it open for the life of the process, so pulling that checkout and restarting the service is what loads new server or shared-store code; a running service keeps serving the code it started with until it is restarted.
Re-run the installer only to change what the unit or the environment file says, not to pick up a change in the code they point at.
