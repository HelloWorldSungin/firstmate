# Fleet dashboard

The fleet dashboard is a mobile-first, read-only captain inbox, kanban view, completed-work history, and live agent-activity timeline over [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh)'s versioned JSON contract.
It never dispatches, steers, merges, tears down, or writes fleet state: its one write is the agent-event store it owns outside the operational home ([dashboard events](dashboard-events.md)).
Stopping the dashboard has no effect on Firstmate supervision.

This first dashboard slice listens only on loopback.
Remote phone access, authentication, TLS, and Twingate exposure are intentionally outside its current boundary.

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
The server accepts only the numeric loopback addresses `127.0.0.1` and `::1`.

## Runtime behavior

[`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs)'s header owns the environment configuration names and defaults.
The server runs the fixed adjacent `fm-fleet-snapshot.sh --json` command with a hard deadline, keeps at most one execution active, coalesces poll and debounced file triggers, and pushes result envelopes to the browser with server-sent events.
No HTTP input can select a command, argument, or fleet path.

A failed refresh keeps the last valid snapshot visible and labels it stale with bounded error detail.
The server also pushes a stale transition as soon as the last successful snapshot reaches the configured age threshold, even when the next poll has not started.
The empty, first-run, missing-command, timeout, malformed-JSON, unsupported-schema, and stale-last-good cases remain explicit in the same board surface.
The browser reconnects its event stream with bounded exponential backoff, while periodic polling guarantees eventual updates even when a filesystem notification is unavailable.

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
Token usage is presence-gated on the fleet's token-usage collector: totals appear when that collector is installed in this home and has attributed usage to a task, and anything else - no collector, no attributed row, an output this dashboard does not recognize, an unreadable total - renders as `unavailable` with its reason rather than as a zero.
A blank cell would read as "this task cost nothing", which is a different claim from "we do not know".
Semantic search over report content is a separate integration; history is fully usable without it.

## Activity

The Activity view is a live per-agent event timeline: session started, prompt submitted, tool started, tool finished, turn ended, session ended, newest first and filterable by agent, harness, and event.
Each board card carries a Timeline button that narrows the view to that one agent.

It is off until you turn it on, and [`docs/dashboard-events.md`](dashboard-events.md) owns the whole contract: how to enable and disable it, which harnesses have an adapter and what the others degrade to, what an event may and may not contain, where the events are stored and why that is not the fleet's own data directory, and why a dashboard that is down or slow costs a working agent nothing.
The short version worth knowing before reading it: instrumentation is one command on and one command off, redaction is an allowlist at both the producing and the receiving end, and the reporting hooks are additive to the ones firstmate already installs and cannot change what any of them decide.

## Rendered reports

A retained report is arbitrary content written by a worker, so the dashboard renders it under an explicit policy that [`assets/dashboard/markdown.js`](../assets/dashboard/markdown.js) implements and `tests/fm-dashboard-history.test.sh` pins with hostile fixtures.

The renderer never produces an HTML string and the browser never parses one: Markdown becomes a tree of plain nodes that the page builds with `createElement`, `createTextNode`, and an attribute allowlist.
Raw HTML in a report is therefore never markup - a `<script>` tag arrives on the page as the literal characters a reader sees.
A link survives only when it is absolute and its protocol is `http`, `https`, or `mailto`; `javascript:`, `data:`, and every other protocol, along with protocol-relative and relative references, are refused and the refusal is shown next to the surviving label rather than hidden.
Images are rendered as labeled external links instead of `<img>` elements, because the page's content-security policy forbids remote images and a broken-image icon would read as a corrupt report rather than as policy.
Document size, line count, node count, and nesting are all bounded, and every truncation is stated above the report.

The report itself is fetched by task id, and that id selects nothing on its own: it must name a task the current history published with a retained report, and the file is then read from this home's own data directory rather than from the path recorded in the manifest.
A report that is missing, is no longer a plain file, or resolves outside that directory is refused with a reason, and a report larger than the configured byte limit is served truncated and labeled.

## Updating configuration

Re-run the installer with the desired values to replace the environment file and restart the enabled service.
The environment file carries the service's value for every configuration name [`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs)'s header documents.
Use ordinary user-level systemd status and journal commands to inspect startup failures.
