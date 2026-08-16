# Fleet dashboard

The fleet dashboard is a mobile-first, read-only view of the fleet over [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh)'s versioned JSON contract: five destinations behind a hash router - Needs you, Fleet, Backlog, History, Knowledge - plus a per-task detail page, with exactly one view rendered at a time.
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

With neither `FM_HOME` nor `--fm-home` set, the operational home follows an explicit `--checkout` rather than staying where the installer you ran happens to live.
A later run with no checkout or home override preserves the installed home; pass `--fm-home` to replace it independently of the checkout.

## Runtime behavior

[`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs)'s header owns the environment configuration names and defaults.
The server runs the fixed adjacent `fm-fleet-snapshot.sh --json` command with a hard deadline, keeps at most one execution active, and pushes result envelopes to the browser with server-sent events.
A trigger arriving during a snapshot reads the last completed result rather than queueing a catch-up run, and the next periodic poll waits its full interval after completion, so a snapshot slower than its poll interval cannot keep the reader continuously saturated.
No HTTP input can select a command, argument, or fleet path.

A failed refresh keeps the last valid snapshot visible and labels it stale with bounded error detail.
The server also pushes a stale transition as soon as the last successful snapshot reaches the configured age threshold, even when the next poll has not started.
The empty, first-run, missing-command, timeout, malformed-JSON, unsupported-schema, and stale-last-good cases remain explicit in the same board surface.
The browser reconnects its event stream with bounded exponential backoff, while periodic polling guarantees eventual updates even when a filesystem notification is unavailable.

Raw error text reaches a reader through one funnel and never reaches the DOM: [`assets/dashboard/errors.js`](../assets/dashboard/errors.js) turns a typed failure into a display-safe sentence for its kind and carries the underlying message and stderr on a non-enumerable property, which is what keeps them out of the envelope the browser receives.
Kept out is not thrown away - every server-side failure, the per-source knowledge failures and the event-ingest refusal included, logs its raw reason to the service journal, so an operator can read why a source failed while the page and the posting agent still see only what can be said safely.
That log is remembered per source and cleared by that source's own next success, so a source that is simply still broken says so once while a failure that returns after a recovery says so again.

A data refresh reconciles the mounted view rather than replacing it: results update in place, and the control a reader is on keeps its focus, its live value, and its caret across every push.
That rule belongs to the reconciliation boundary rather than to a list of protected elements, so it holds for a filter chip, a state tab, a pager button, or a disclosure toggle exactly as it does for a search box - including on views that have no search box at all.
Focus is carried by what a control is rather than by where it sits: its own id when the renderer gave it one, otherwise the tag and the words the reader was looking at, and its position among controls that are genuinely indistinguishable.
The words a control is known by exclude the values that tick - a filter chip's count, a row's age, duration and cost - because a count moving from 3 to 4 is the fleet changing, not the reader's chip becoming a different control; every such region is marked where it is rendered rather than recognized afterwards by which control it sits in.
A refresh that reshapes a list - a state column emptying out, a row leaving the queue - therefore restores nothing rather than re-aiming the keyboard at whichever control inherited the position, because a refresh may drop focus but may never move it.
Clearing a filter is the one thing that replaces a value under the reader's hand, because it is an explicit committed transition rather than a refresh.

## Navigation and reading it on a phone

The five destinations live behind a hash router (`#/needs`, `#/fleet`, `#/backlog`, `#/history`, `#/knowledge`, plus `#/task/<id>`), and [`assets/dashboard/router.js`](../assets/dashboard/router.js) owns the routing contract: a hash resolves to exactly one view, that view is the only one in the DOM, and an unknown or stale hash lands on Needs you rather than a blank page.
Navigation exists at every width: a left rail from 900 CSS px up (collapsing to icons below 1200), and a sticky bottom tab bar below 900, both carrying the Needs-you count badge.
The layout is fluid across the whole width range rather than correct at a few chosen sizes, and 320 CSS px is a supported width.

The verdict strip is the one sticky element above every view: a single plain-words sentence - nothing needs you, N decisions waiting, N tasks blocked, fleet unavailable - beside a per-task tone segment bar.
When the newest snapshot is stale, the strip says how old the data is and greys every claim it can no longer stand behind.

Nothing is placed behind a horizontal page swipe: the document itself never scrolls sideways.
Two regions scroll inside their own box instead of stretching the page: the Fleet board's column strip at desktop widths, and worker-written content inside a rendered report.
One page edge is inset-aware: the bottom tab bar pads itself past the home indicator with `env(safe-area-inset-bottom)`, which is the only safe-area inset this stylesheet applies - the horizontal page edges use a plain gutter, and [issue #174](https://github.com/HelloWorldSungin/firstmate/issues/174) tracks the viewport decisions the rebuild dropped.
A route change puts the reader at the top of the destination they asked for.
Folding or unfolding a device reflows the current view while the page stays loaded; the address carries the route, so the selected view and its filter state survive.
The page loads dark whatever the system prefers, and the navigation's theme toggle is the only thing that changes it: loading stores nothing, so a browser holding no choice is a reader who has not made one rather than one who accepted a default.

## Needs you

The landing view is the captain inbox: open decisions, blockers, failures, credential requests, and pull requests whose normalized status is genuinely review or merge ready, rendered as roomy cards sorted oldest first.
[`docs/dashboard-inbox-policy.md`](dashboard-inbox-policy.md) owns that policy in full, including what makes a pull request green and how overlapping signals deduplicate into one item.
The short version worth knowing before reading it: a pull request is shown as green only when its normalized checks, review, and mergeability all say so, and anything missing or stale is drawn as an explicit unknown rather than as a pass.
A card opens its task's detail page, and a fleet with nothing waiting says so as designed content - the all-clear is what the captain sees most often, and it reads as reassurance rather than as a blank page.
A card's pull-request shortcut opens the recorded address only when it passes the same protocol allowlist every other link on the page passes - absolute `http`, `https`, or `mailto`, and nothing else - so a snapshot cannot turn a captain's click into script in the dashboard's own origin; a refused address keeps the pull request on the card and loses only the jump.
An unreachable snapshot is its own explicit state on this view and on Fleet, never rendered as the calm first-run page.

## Fleet

The Fleet board groups every worker by state, one column per `tasks[].card` column key with the top-level `card_precedence` array determining order, and one-tap state filters with live counts above it.
A row carries the task's title, project, runtime and model, and age; everything deeper - state detail, PR, linked work items, timeline, report - lives on the task's detail page, one click away.
Unknown endpoint liveness remains distinct from alive or dead, persistent secondmates stay in their own column, and the UI contains no forge adapter or independent fleet-state parser.
At desktop widths the columns read side by side and the strip scrolls inside itself; below 900 the board stacks into single-column sections.

## Backlog

The Backlog page is the read-only queue: every current backlog record with its project, kind, priority, age, and - for anything held or blocked - the reason, in the backlog file's own order, because that order is Firstmate's queue decision.
It reads `GET /api/backlog`, which serves the full record set from the same snapshot backlog parse the fleet state reads - one owner for the file format, one freshness story - rather than the bounded slice the compact fleet listing shows.
[`assets/dashboard/backlog.js`](../assets/dashboard/backlog.js) is the page policy's single executable copy: state tabs, project, kind, and priority facets, bounded text search, and pagination, with delivered work excluded because completed items belong to History.
A row is drawn as blocked only while the snapshot still lists an unresolved blocker for it, never on the presence of a `blocked-by:` token alone, so an item whose blocker has since been delivered reads as queued rather than staying red until someone edits the file.
A current row the parse could not read as a queue item is counted and disclosed above the list, the way History discloses an unreadable completion record, because queued work missing from the queue with nothing saying so is this page's worst failure.
The page changes nothing: ordering and state changes are Firstmate's, and it says so on the page.

## Task detail

`#/task/<id>` is one task's whole story on one page: its title and id, project, kind, runtime and model, delivery mode, age or completion date, current state with the recorded detail sentence, the full pull request URL with its recorded readiness, linked work items, the retained report, and the recorded per-task activity timeline.
It resolves the id against the live snapshot first, then the durable completion records, then the queue, and a task in none of them says so explicitly.
Timeline rows carry an outcome chip where an outcome is a meaningful claim: an observed success is green, an observed failure red, and an outcome nobody observed is an explicit dashed unknown, never a bare row that reads as fine beside a green one.
The timeline is store-backed and live: an event arriving while the page is open appears without a reload, earlier events survive later unrelated fleet traffic, and other tasks' events never appear on it.
There is deliberately no global event feed in primary navigation: the feed is structurally blind to uninstrumented runtimes, so promoting it would be a permanently empty marquee, and a task page that says "this runtime does not report activity" is the honest version of the same fact.

## History

History lists completed work from the durable completion manifests in `data/<id>/outcome.json`, which [`docs/fleet-data-contracts.md`](fleet-data-contracts.md) owns.
This page states the history policy for humans, and [`assets/dashboard/history.js`](../assets/dashboard/history.js) is its single executable copy.
It is deliberately not built from task metadata or from the Done backlog: cleanup removes the volatile records and the backlog keeps only its recent Done entries, so a view sourced from either would lose a task that finished a few weeks ago.
A completed investigation therefore stays browsable, with its report, after cleanup and after backlog pruning.

The page opens with a roll-up - delivered and failed counts, total tokens, median duration - over the filtered range, and lists each record as a dense row: title, outcome, kind, project, duration, token usage, and age.
The rest of a record - its timestamps, the complete pull request URL with the fields recorded at completion, linked work items, and the retained report - lives on that task's detail page.
Work delivered against an issue links back to that issue; an unreachable or unsupported tracker stays a plain link, and work with no linked item simply has none.
History computes no pull-request readiness verdict of its own - [`docs/dashboard-inbox-policy.md`](dashboard-inbox-policy.md) owns that judgment for live work, and history shows the observation that was recorded, including its unknowns.

Project and outcome filters, a completion-date range (7, 30, 90 days, or all time), a bounded text search over the indexed fields, and pagination all run over the records the server read.
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
The unit does grant one scratch directory of its own, through `RuntimeDirectory=` and a `TMPDIR=` pointing at it, so a panel whose command genuinely needs a temp file has one without being rewritten to do without it - semantic search is the current such panel, and the grant is made once rather than per panel.
The store reader still asks for no scratch path at all, so it keeps reading outside this unit too and that grant is not what makes the usage panel work.
[`docs/verification/dashboard-service-unit.md`](verification/dashboard-service-unit.md) pins the reproduced combinations, both fixes, and why `PrivateTmp=yes` is still the wrong way to grant scratch space here.
A task the retained read does not carry yet says exactly that, so a just-archived record is never reported as having cost nothing.
[usage-accounting.md](usage-accounting.md) owns the store itself, including the read-only open that lets the hardened user service read it without write access to `data/`.
Semantic search over captured report content belongs to the separate [Knowledge](#knowledge) page; history is fully usable without it.

## Agent activity events

The per-task activity timeline on the [task detail page](#task-detail) is fed by agent lifecycle events: session started, prompt submitted, tool started, tool finished, turn ended, session ended.
Reporting is off until you turn it on, and [`docs/dashboard-events.md`](dashboard-events.md) owns the whole contract: how to enable and disable it, which harnesses have an adapter and what the others degrade to, what an event may and may not contain, where the events are stored and why that is not the fleet's own data directory, and why a dashboard that is down or slow costs a working agent nothing.
The short version worth knowing before reading it: instrumentation is one command on and one command off, redaction is an allowlist at both the producing and the receiving end, and the reporting hooks are additive to the ones firstmate already installs and cannot change what any of them decide.

## Knowledge

The Knowledge page is a read-only search over this home's optional GBrain brain, with the brain's health folded into a collapsible strip: presence, pinned version, index state, retrieval health, hosted-synthesis health, durable capture outbox, and maintenance state.
None of those are fleet health signals.
The brain is presence-gated and every read of it is bounded, so a brain that is absent, stopped, or slow degrades the page and never the dashboard or Firstmate supervision.
A home with no brain configured keeps Knowledge in the navigation and renders a quiet explanation page - nothing is broken, there is simply nothing to search - rather than demoting the destination out of primary navigation.
The health read refreshes on the history poll rather than the faster snapshot poll, because it probes endpoints that can take seconds, and a health strip that was never read draws the hollow unknown ring rather than a green dot.
[`bin/fm-gbrain-health.sh`](../bin/fm-gbrain-health.sh) owns that read, its `fm-gbrain-health.v1` shape, and the single probe budget every step inside it draws from; the server bounds the child inside the same deadline it gives a snapshot refresh, so a brain that answers nothing cannot hold up a poll.

A home without a brain reports `configured: false`, which is the normal state of a fleet that has not adopted GBrain and what renders the explanation page above.
A configured home whose brain is not yet bootstrapped shows `index.state: absent`, which is not a fault; capture stays off and captured documents wait in the durable outbox.
A configured home whose embedding or reranker endpoint is unreachable reports `retrieval.state: degraded` and names the leg that went, while `synthesis.state` stays `ok` because local search keeps working.
A configured home whose hosted synthesis provider is down reports `synthesis.state: degraded` while retrieval stays `ok`.
A brain the operator has paused for care reports `maintenance.state: upgrading` or `reindexing` with the operator's own detail text, and [`docs/gbrain.md`](gbrain.md#announce-a-maintenance-window) owns when to announce that and how to clear it.

The search itself is a POST to `/api/gbrain/search` that runs [`bin/fm-recall.sh`](../bin/fm-recall.sh) `search` over the read-only scopes this home already holds.
The query reaches the wrapper as an argument array after `--`, never interpolated into a shell command, so a shell metacharacter in a query is a character to search for rather than syntax.
The endpoint bounds the query size, the result count, and how long one search may take, and it admits one search at a time.
The page holds itself to that same one-at-a-time rule and says it is searching, rather than sending a second request whose busy refusal could land after the first search's results and replace answers the reader can see with an error about a search they never started.
A search that never started - the wrapper could not create the working files it needs, so no corpus was asked - is reported as its own state rather than as a corpus that did not answer, because the second sends you to look at your brain for a fault in the service's own environment.
Results come back in a closed vocabulary - source, slug, title, score, excerpt, stale - with anything outside it dropped rather than passed through, and [`assets/dashboard/gbrain.js`](../assets/dashboard/gbrain.js) builds every result node with `createElement` and `textContent`, so nothing in a stored brain document can become markup or restructure the page.

The brain integration is presence-gated as a whole: removing `config/gbrain.json` removes the polling cost, the search, and the probes together, leaving the explanation page.

## Rendered reports

A retained report is arbitrary content written by a worker, so the dashboard renders it under an explicit policy that [`assets/dashboard/markdown.js`](../assets/dashboard/markdown.js) implements and `tests/fm-dashboard-history.test.sh` pins with hostile fixtures.

The renderer never produces an HTML string and the browser never parses one: Markdown becomes a tree of plain nodes that the page builds with `createElement`, `createTextNode`, and an attribute allowlist.
Raw HTML in a report is therefore never markup - a `<script>` tag arrives on the page as the literal characters a reader sees.
A link survives only when it is absolute and its protocol is `http`, `https`, or `mailto`; `javascript:`, `data:`, and every other protocol, along with protocol-relative and relative references, are refused and the refusal is shown next to the surviving label rather than hidden.
Images are rendered as labeled external links instead of `<img>` elements, because the page's content-security policy forbids remote images and a broken-image icon would read as a corrupt report rather than as policy.
Document size, line count, node count, and nesting are all bounded, and every truncation is stated above the report.
A report's own headings are scaled to the panel that holds it rather than left at the browser's defaults, because an unstyled `#` line renders larger and heavier than the page's own title and inverts the hierarchy - a worker's report is content on the task page, not the task page.

The report itself is fetched by task id, and that id selects nothing on its own: it must name a task the current history published with a retained report, and the file is then read from this home's own data directory rather than from the path recorded in the manifest.
A report that is missing, is no longer a plain file, or resolves outside that directory is refused with a reason, and a report larger than the configured byte limit is served truncated and labeled.

A report body is the one region the no-filesystem-paths rule does not cover, and that is a decision rather than an oversight.
The rule is scoped to the operational chrome the dashboard itself composes - labels, filters, errors, status lines, notices, and every attribute or text node built from a record value, all of which go through [`assets/dashboard/display.js`](../assets/dashboard/display.js)'s `label()`.
A worker's report renders as written, absolute paths included, because a report narrating the path it worked in is the deliverable saying what it did, and deciding what to redact there belongs to whoever writes it.
That is the captain's decision on [issue 169](https://github.com/HelloWorldSungin/firstmate/issues/169); the browser check's leak scan excludes the `.report` subtree by name and counts what it skipped rather than narrowing what it claims.
In fixture mode that exclusion is exercised rather than stated: the check seeds a completed task whose retained report body carries an absolute clone path, visits that task's page, and requires the exempt region to be present, to carry a path-shaped value, and the scan over everything else to come back clean - so a run disclosing zero skipped regions fails its own coverage verdict.

## Checking it in a browser

The module-level tests prove what each browser module returns; they cannot prove that the page loads, that the stylesheet arrived, that the layout holds at 390 CSS px, or that the console is clean.
[`bin/fm-dashboard-browser-check.sh`](../bin/fm-dashboard-browser-check.sh) drives the real page in a real browser and records what it rendered, at a phone width, both sides of the 899/900 navigation boundary, and a desktop width, visiting every destination through the navigation control visible at each and asserting the active view is the only one in the DOM.
Which control that was is a verdict of its own rather than a line of detail: below 900 CSS px the destination must have been reached through the bottom tab bar and at 900 and above through the rail, so a section named after one side of the boundary cannot report green while the page was showing the other side's control.
Its credential- and path-leak scan runs over every destination's rendered text and its rendered attributes alike, since a value written into a `title` or a `data-` attribute is on the page exactly as much as one written into a text node; it excludes the worker-authored report bodies [issue 169](https://github.com/HelloWorldSungin/firstmate/issues/169) exempted, and states how many of those regions it stepped over.

Run it with no arguments and it starts its own dashboard from this checkout on an ephemeral loopback port over a throwaway home, so it never touches an installed service.
Pass `--url` with `--user` and `--password-file` to point it at a running dashboard; the password is held by a loopback-only front and never enters the URL the browser opens, so it reaches neither the browser's history nor any evidence the check captures, and the dashboard's own exposure, authentication, and credentials are untouched.
That front does add one thing, which its header states rather than claims away: it attaches the credential to everything it forwards and authorizes nothing itself, so for the length of the check it is an unauthenticated door to the authenticated dashboard, bound to loopback on an ephemeral port and gone when the check exits.
On a host with other tenants that is worth weighing before running `--url`.
`--negative` proves the check can still fail, by running the same assertions against a page that renders nothing.
`FM_DASHBOARD_BROWSER_FORCE=<check>:<branch>` serves the same purpose one check at a time, forcing a named check down its failure or could-not-verify branch so that path can be executed and read rather than reasoned about; it is inert unless set and an injected run never exits 0, so it can never be mistaken for a check of the dashboard.

Each observation is recorded as `ok`, `FAIL`, `????`, or `n/a`.
`????` is not a pass: it means the observation could not be made at all, because a probe would not decode, a browser command failed, or a scan cannot be shown to have run, and a run carrying any `????` exits non-zero for the same reason a failing one does - a check that could not look is not a check that saw nothing wrong.
`n/a` is the separate case of an observation this mode was never able to make: under `--url`, the three task-timeline observations, which can only be proved by posting events into a dashboard this command does not own, and the retained-report exclusion, which needs a completed task this command authored.
The checked fleet's own state puts observations out of reach the same way: a fleet with no live task has no board row to open, so the four task-destination observations are `n/a` there, and one that has delivered nothing has no completion row for a usage cell to sit on.
Each is reported and counted but does not fail the run, so a healthy dashboard checked with `--url` exits 0 even when its fleet is idle; every observation outside that set is made identically in both modes.

That last claim is structural rather than a promise anyone has to keep by hand.
Each mode declares the observations it makes and reconciles that list against the verdicts it recorded before it exits, so an observation left unrecorded, recorded twice, or recorded without having been declared fails the run by name and exits 4 rather than showing up as a quietly smaller result.

It is a command rather than a test CI runs, because one Chrome session per host is shared state that parallel test shards would fight over and CI has no browser at all; `tests/fm-dashboard-browser.test.sh` is the opt-in wrapper, and the script's header owns that tradeoff in full.
Run it after changing anything the page renders, and before believing any claim about what the dashboard shows.
[`docs/verification/dashboard-browser.md`](verification/dashboard-browser.md) records what the first run observed.

## Updating the installed service

Re-run the installer to replace the environment file and restart the enabled service.
With no setting flags, it preserves the installed operational home, bind address, trusted proxies, authentication file, polling, timeout, staleness, history, and report limits; an environment value or option overrides the preserved value, and the first explicit `--trusted-proxy` replaces the installed proxy list.
The generated unit carries a runtime-contract marker that the server checks under systemd before starting snapshot reads, so code running behind an older unit reports that the installer must be rerun instead of exposing a denied temporary-file operation forever.
Use ordinary user-level systemd status and journal commands to inspect startup failures.

Updating the code is the other case, and it does not go through the installer.
The unit names the server by absolute path inside the checkout it was installed from and holds it open for the life of the process, so pulling that checkout and restarting the service is what loads new server or shared-store code; a running service keeps serving the code it started with until it is restarted.
Re-run the installer only to change what the unit or the environment file says, not to pick up a change in the code they point at.
