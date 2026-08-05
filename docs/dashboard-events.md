# Dashboard agent events

The [fleet dashboard](dashboard.md) can show a live timeline of what each agent is doing: session started, prompt submitted, tool started, tool finished, turn ended, session ended.
Events come from the harness's own hooks, land in a store the dashboard owns, and stream to the browser on the connection the board already holds.

Instrumentation is **off until you turn it on**, and turning it off is one command.
Everything below is written so that a dashboard which is down, slow, or absent costs a working agent nothing.

## Turn it on

```sh
bin/fm-dashboard-instrument.sh enable        # default target http://127.0.0.1:8787/events
bin/fm-dashboard-instrument.sh status
bin/fm-dashboard-instrument.sh disable
```

`enable` writes two private files under the user configuration root, and their presence is the whole switch:

| File | Read by | Holds |
| --- | --- | --- |
| `dashboard-events.json` | the dashboard | the ingest URL and the token it will accept |
| `dashboard-events.curlrc` | [`bin/fm-event-emit.sh`](../bin/fm-event-emit.sh) | the same token as private curl options, so it never appears in this machine's process list |

Both are mode 0600.
`enable` rotates the token every time it runs, so a leaked token is retired by running it again; a running dashboard notices the new token on its own and needs no restart.
The target must address the loopback dashboard - reporting fleet activity to another machine is refused here rather than discovered later.

Tasks dispatched **after** you enable it report events; tasks already running keep the wiring they were launched with.
`disable` removes both files, after which new tasks are wired exactly as they were before this feature existed, the emitter returns without doing anything, and the dashboard answers every post with "not configured".
Stored events stay browsable until they age out.

## Where events are stored, and why not in `data/usage.db`

Issue #14 pairs this with the [token-usage store](usage-accounting.md), and the two do share their store discipline: [`bin/fm-telemetry-store.mjs`](../bin/fm-telemetry-store.mjs) owns the opener, the forward-only `PRAGMA user_version` migrations, the WAL and busy-timeout behaviour, the private file mode, and the value sanitizers that both use.
Both spell a task id, a harness, a session id, and an instant the same way, so a task's events and a task's tokens join on `task_id`.

They are nevertheless two files, for one concrete reason: **the dashboard writes nothing a fleet program owns.**
`tests/fm-dashboard.test.sh` proves that by fingerprinting `data/`, `state/`, and `projects/` around a live server that is accepting events, and the installed user service is hardened to match with `ProtectSystem=strict` and `ProtectHome=read-only`.
Putting events in `data/usage.db` would require granting that service write access to the fleet's data directory, which is the exact guarantee the dashboard is built without.

So the event store lives outside the operational home, keyed by the home it describes:

```
$FM_DASHBOARD_EVENT_DB, or
${XDG_STATE_HOME:-~/.local/state}/firstmate/dashboard-events/<home-slug>/events.db
```

The slug carries the home's basename for a human plus a digest of its absolute path for uniqueness, so a main home and a secondmate home never share a store.
[`bin/fm-event-store.mjs`](../bin/fm-event-store.mjs) owns that rule; the installer asks it for the path rather than deriving its own, and grants the service write access to exactly that one directory.
It then pins the answer into the generated `dashboard.env`, because the systemd user manager does not inherit the installing shell's environment: a service left to re-derive the path would resolve a directory the unit never granted, fail to open its store under `ProtectHome=read-only`, and refuse every event for the life of the process.
The shared instrumentation configuration is pinned for the same reason.

Creating the store is presence-gated like everything else here: a dashboard with no configured ingest token never brings one into existence.
That matters because the store is the single fleet artifact that lives outside every operational home - an uninstrumented dashboard that created it on the first browser connection would leave a directory behind in the operator's state root, keyed to a home it can never write events for, and a store that exists reads as collection whether or not anything was ever collected.

Opening a store that is already there is the other half, and it is deliberately not gated: turning instrumentation off stops collection, it does not withdraw access to what was already collected.
So a disabled home still browses its own history until it ages out, while every post is still refused before its body is read.

```sh
bin/fm-event-store.mjs path
bin/fm-event-store.mjs stats
bin/fm-event-store.mjs list --task <id>
bin/fm-event-store.mjs prune
```

Retention is enforced by the writer after every accepted batch rather than by a separate sweep, so the store cannot grow unbounded because nobody ran a cleanup command: an age cap (7 days), a total row cap (50000), and a per-task row cap (2000), each overridable through the environment names in the server's header.
The age cap is index-bounded and applied every time; the two row caps each need a full table scan, so they are applied only when a cached row count says a cap can be crossed and then only far enough apart to amortize the scan, which leaves the store at most 1/64 of the row cap and a task at most 1/8 of the per-task cap above their limits between scans.
`bin/fm-event-store.mjs prune` always applies all three exactly.

## What may be in an event

The wire schema is `fm-agent-event.v1` and it is harness-agnostic on purpose: an adapter translates its harness's native event into the vocabulary below and contributes no field of its own, so the remaining harnesses can be added without a wire change.

| Field | Rule |
| --- | --- |
| `task_id` | the path-safe task id pattern |
| `harness` | a lowercase harness name |
| `type` | `session_start`, `prompt_submitted`, `tool_started`, `tool_finished`, `turn_ended`, `session_end`, `notification` |
| `occurred_at` | second-resolution UTC, inside the accepted window |
| `event_id` | producer-supplied identity, so a retry is the same event |
| `session_id` | an opaque session identifier, or absent |
| `tool` | a tool name, or absent |
| `outcome` | `ok`, `error`, `blocked`, `unknown`, or absent |
| `summary` | a short human summary, or absent |

**Redaction is an allowlist at both ends, not a filter.**
The producer never forwards free text: every field it sends is rebuilt from a value that matched its own pattern, and a value that does not match is dropped rather than sent.
The server then rebuilds the stored row from scratch under the same rules, so a document's other keys are not stored, not echoed, and not logged - they are never read.

That leaves nothing for a prompt, a response, a tool argument, a file body, or an environment value to travel in.
`summary` is the only field with any freedom, and it is bounded three ways: it may use only `A-Z a-z 0-9 space . , _ : # ( ) -`, so an absolute path, a URL, an assignment, an address, and base64 all fail on their own characters; no unbroken run may exceed 15 characters, because human summaries have spaces and tokens do not; and known credential shapes plus long mixed-case-and-digit runs are refused outright.
A session id is an opaque identifier by nature and is stored as one, exactly as the usage store already stores session ids.

The long-mixed-run rule belongs to `summary` alone, and that is a decision rather than an oversight.
It is a content-scanning rule, which is what a free-form value needs and what a known field does not: a tool name is one unbroken run by construction, so applying it to `tool` would classify every MCP tool name of 24 or more characters containing a digit - `mcp__github_v2__create_issue` and its kind - as a credential and silently blank the field a `tool_started` row exists to show.
`tool` is guarded by its own pattern plus the named credential prefixes, which have no false positives.
The residual is accepted and stated rather than left implicit: an unprefixed high-entropy token placed in `tool` by a hostile *authenticated* post would be stored, and closing that would take exactly the run-length rule that breaks real tool names.

`tests/fm-dashboard-events.test.sh` seeds a private path, a vendor key, and an opaque token at both boundaries and asserts none of them reaches the wire, the store file on disk, or the rendered page.

## The ingest boundary

`POST /events` is the one write the dashboard performs.

The cheap refusals come first and cost no body read: ingestion switched off, no configured token, a missing or wrong bearer token, a malformed `X-Firstmate-Source: <task>/<harness>` header, and a throttled source are each answered before a single body byte is accepted.
Only then is a bounded body read - at most 16 KiB, at most 32 events, under a 2 second deadline - and only allowlisted fields of it are looked at.

Rate limiting is a refilling token bucket per declared source plus a global one, which is why the source is declared in a header rather than discovered by parsing.
An event whose `task_id` or `harness` disagrees with that header is refused, so it cannot spend another agent's budget.

Replays are refused twice over.
`event_id` is the store's primary key, so a resent batch collapses rather than drawing a second entry.
And an event whose own instant falls outside the accepted window is refused by that timestamp, which is what stops a captured batch replayed hours later with fresh ids.

## The harness adapters

| Harness | Source | Events |
| --- | --- | --- |
| Claude Code (verified on 2.1.222) | additional entries in the per-task `.claude/settings.local.json` that [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) already writes: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd` | session start, prompt submitted, tool started, tool finished, turn ended, session ended |
| OpenCode (verified on 1.18.4) | additional handlers in the per-task `.opencode/plugins/fm-busy-state.js` that the same spawn already writes: `chat.message`, `tool.execute.before`, `tool.execute.after`, and the existing `session.idle` branch | prompt submitted, tool started, tool finished, turn ended |

The OpenCode adapter deliberately uses those semantic hooks rather than the `session.status` transitions the plugin's busy-state contract already watches.
OpenCode flips that status between busy and idle at every step inside one turn, which is exactly right for an idempotent state writer and would draw the same turn over and over on a timeline.
Claude's tool name arrives in the hook payload rather than in the command, so the producer pulls exactly that one field and the session id out of it by pattern and ignores everything else the payload carries.

Every other harness degrades to **no event source**: nothing is wired, nothing is reported, and the timeline says so for that task rather than showing an empty panel that reads as a fault.

Both adapters go through `bin/fm-event-emit.sh` rather than posting for themselves, so there is one producer-side redaction boundary and one wire format however many harnesses arrive later.

**Wiring is additive, and it has to stay that way.**
The event entries join the hook files firstmate already owns without altering, reordering, or displacing anything in them, and they are absent entirely when instrumentation is off.
The emitter exits 0 on every path, writes nothing to either stream, and does its work in a detached child, so an entry that fires on the same event as the [turn-end guard](turnend-guard.md) or the Claude Stop auto-arm cannot change that guard's exit status, its output, its timing, or its ordering.
The test suite runs each real guard in two identical homes - one with the emitter firing beside it against a deliberately hung dashboard - and requires an identical decision from both: for the turn-end guard an identical exit status, identical output, and an untouched state directory, and for the Claude Stop auto-arm an identical exit status, identical stderr, and an identical epoch ledger across both an actionable rewake close and a clean one.

## Why nothing is retried or spooled

The producer's foreground does argument validation and one fork.
Reading the hook payload, checking configuration, and the request itself all happen in the detached child, with a 0.3 second connect deadline and a 1.5 second total deadline.
A dashboard that is down, hung, or slow therefore costs an agent one fork rather than a timeout, and a lost event is a gap in a view.
A view is not worth a stalled agent, so there is no retry and no spool.

## Reading the timeline

The **Activity** view lists the fleet's events newest first, filterable by agent, harness, and event.
Each task card carries a Timeline button that narrows the view to that one agent and backfills its own events from the store, because the live stream carries a bounded fleet-wide tail and a busy fleet can scroll one agent out of it.
[`assets/dashboard/events.js`](../assets/dashboard/events.js) is the single executable copy of that policy.
Every value reaches the page through `textContent`, which is the second independent reason a stored event can never become markup.

## Verification

```
$ bash tests/fm-dashboard-events.test.sh
$ bash tests/fm-dashboard.test.sh
$ bash tests/fm-usage.test.sh
```
