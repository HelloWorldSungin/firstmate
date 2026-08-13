# Fleet data contracts

Firstmate's durable records are produced by one script each and consumed by many.
This page owns the field-ownership map across those producers and consumers.
Exact flags, exact commands, and exact paths stay in each script's header and `--help`.
[`bin/fm-outcome-lib.sh`](../bin/fm-outcome-lib.sh) owns the stored-artifact and history wire shapes, while [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh)'s header owns the snapshot projection.

Three artifacts carry the contract.

| Artifact | Schema | Producer | Lifetime |
| --- | --- | --- | --- |
| `data/<id>/outcome.json` | `fm-outcome-manifest.v1` | [`bin/fm-outcome-manifest.sh`](../bin/fm-outcome-manifest.sh) | durable, survives teardown |
| `data/<id>/work-items.json` | `fm-work-items.v1` | [`bin/fm-work-item.sh`](../bin/fm-work-item.sh) | durable, survives teardown |
| `state/<id>.pr-status` | `fm-pr-status.v1` | [`bin/fm-pr-status.sh`](../bin/fm-pr-status.sh) | volatile, removed by teardown |

[`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) is the read-only projection that exposes all three, plus live task state, as schema `fm-fleet-snapshot.v1`.

## Why a manifest exists

`state/<id>.meta` is the only structured record of a task's dispatch, and teardown removes it.
The backlog's Done section is pruned to a configured recent window.
Before this contract, a task that finished and was cleaned up left nothing structured behind except a scout report, so nothing could attribute its usage, ingest its outcome, or show it in history.

The manifest closes that gap: teardown publishes it atomically before removing the volatile records it is composed from.
A task that cannot be archived is not erased - [`bin/fm-teardown.sh`](../bin/fm-teardown.sh) refuses the cleanup and keeps every record for a retry, because the manifest is the canonical structured completion record.

## Manifest field ownership

Every externally sourced field is composed from a record that already exists at completion time.
The manifest never contacts a forge and never reads brief contents, a prompt, a tool argument, or a credential-bearing artifact; it inspects only the brief's mtime for timestamp provenance.

| Field | Source of truth | Notes |
| --- | --- | --- |
| `schema`, `task_id`, `home`, `recorded_at` | the writer | identity and provenance of the record itself |
| `title` | the task's structured backlog row | metadata, URLs, and report pointers stripped; null for secondmates because they are not backlog items |
| `project`, `kind`, `mode`, `yolo` | `state/<id>.meta` | the delivery contract the task shipped under |
| `harness`, `model`, `effort` | `state/<id>.meta` | the dispatch decision, retained for usage attribution |
| `timestamps.*` | see below | each value's provenance is named in `timestamp_sources` |
| `outcome.state` | the last terminal status event, the task kind, or the teardown mode | `done`, `failed`, `discarded`, `retired`, or `unknown` |
| `outcome.detail` | that event's note | single-line, control characters stripped, length capped |
| `outcome.forced` | the teardown invocation | true when cleanup discarded work under explicit authority |
| `pr.url`, `pr.provider`, `pr.host`, `pr.path`, `pr.number` | `state/<id>.meta`, parsed by `bin/fm-pr-lib.sh` | forge-agnostic identity, GitLab paths may nest |
| `pr.head` | `state/<id>.meta`'s recorded `pr_head` | validated as a SHA or dropped |
| `pr.status.*` | the cached observation, see [Normalized PR state](#normalized-pr-state) | never refreshed at write time |
| `report.path`, `report.present` | `data/<id>/report.md` | the scout deliverable pointer |
| `attribution.*` | `state/<id>.meta` | the references a later usage read needs, see below |
| `attribution.sessions` | `state/<id>.usage-sessions` | the live session-to-task map, so token usage keeps its task after cleanup |
| `work_items` | `data/<id>/work-items.json` | embedded so the manifest is self-contained |
| `gbrain` | `state/<id>.gbrain`, written by [`bin/fm-gbrain-capture.sh`](../bin/fm-gbrain-capture.sh) | `status` is `absent` until a receipt exists, permanently so in a home with no brain; see [`gbrain-capture.md`](gbrain-capture.md) |

Every listed manifest key is required except the additive `attribution.sessions` described below, while fields whose source may be absent retain an explicit null value with the documented type-or-null contract.
A null `title` is intended for a secondmate because secondmates are never backlog items, and an absent capture receipt retains null receipt, observation, and detail fields.
Teardown captures the task's knowledge between publishing this manifest and removing anything, then republishes it, which is how a torn-down task's manifest carries the capture receipt at all.
Task identifiers are capped at 64 characters, general text at 240, paths at 480, source and backend tokens at 40, session identifiers at 128, receipts at 200, URLs at 512, and hosts at 253 characters.
The shared reader validates the complete shape, types, enums, nullability, caps, task identity, and timestamp provenance before a manifest reaches `show`, history, or the fleet snapshot.

### Timestamps and their provenance

The records firstmate keeps do not all carry an explicit stamp, so the manifest names where each value came from instead of implying a precision it does not have.

- `created` comes from the brief's mtime (`brief_mtime`), falling back to the backlog row's `since` date at UTC midnight (`backlog_since`).
- `started` comes from the task metadata's mtime (`meta_mtime`), which spawn writes.
- `completed` is the write time (`manifest_write`) unless the caller pins one (`explicit`).

The `created` fallback's UTC day start is this write path's own convention and is known to disagree with the snapshot's, which reads the same `since` field at local midnight; [Snapshot projection](#snapshot-projection) owns that divergence and names the item tracking it.

A future explicit recorded stamp can supersede any of these without a schema change: only the `timestamp_sources` value moves.

Teardown's republish is one such pin, so which token a torn-down task carries records which write path ran, not how its completion was obtained.
A home with a brain republishes the manifest so the capture receipt can reach it, and that republish supplies the completion the first write recorded rather than deriving a second one, which is exactly what `explicit` names.
The pin is what keeps the manifest agreeing with the body already captured from it, because re-deriving would move the recorded completion forward by the whole capture window.
A home with no brain has nothing to capture, so it never republishes and its single write records `manifest_write`.

### Attribution after teardown

`attribution` retains what a delayed usage read needs once the task's runtime is gone: the backend, the endpoint target and its task id, the worktree, the per-task temp root, the trace context when trace propagation is enabled, and the secondmate home for a retired secondmate.
The project it ran against is the top-level `project` field, recorded once so the two can never disagree.
The worktree and the recorded timestamps are what a later usage read matches a session against, while `harness`, `model`, and `effort` describe what the matched usage was spent on.

`attribution.sessions` carries the harness sessions that were bound to the task while it was live, each as `harness`, `session_id`, and `source_kind`, capped at 64 entries.
[`bin/fm-usage.mjs`](../bin/fm-usage.mjs) publishes that map to `state/<id>.usage-sessions` and [usage accounting](usage-accounting.md) owns the attribution ladder; the manifest is the durable handoff, published before teardown removes the volatile map.
The field is additive: a manifest written before this contract carries no `sessions` key and stays valid, and a task whose usage was never collected archives with an empty list rather than failing to archive.

## Work-item references

Most tasks trace back to an issue in the **managed project's** tracker, not in this repository, so the reference is forge- and host-agnostic.
A task may carry several references or none.

Each reference stores the canonical URL plus the parsed `forge`, `host`, project `path`, `owner`, `repo`, `number`, and item `kind`.
`owner` is everything before the last path segment, so a nested GitLab group round-trips as faithfully as a two-segment GitHub path.
An unrecognized host stores `forge: "unknown"` rather than being rejected or guessed at, and an explicit forge override is available for a self-hosted instance.

`origin` marks each reference as `intake` (declared by the captain or the brief) or `pr-linked` (derived later from a PR's linked-issue metadata).

`enrichment` carries `title`, `state`, `observed_at`, and `source`, all nullable.
**Consumers must render a reference that has never been enriched.**
A forge that cannot be reached is a missing title, never a rendering failure.

The shared reader accepts only the exact reference shape produced by this contract.
URLs are capped at 512 characters, hosts at 253, project paths at 480, owners at 400, repositories at 200, forge tokens at 32, enrichment titles at 240, and enrichment sources at 40.
Parsed identity fields must reconstruct the canonical URL, numbers must be positive integers or null, origins and kinds must use their documented tokens, enrichment state must be `open`, `closed`, `merged`, `unknown`, or null, and enrichment timestamps must be ISO-8601 UTC or null.
Read-only projections replace an absent or invalid store with the documented empty reference list, while `add`, `remove`, and `clear` refuse to overwrite a present invalid store.

`bin/fm-work-item.sh` owns storage and transport only.
Deciding which work item a task references, resolving it against a project's registry, and refreshing per-forge enrichment belong to the project-issue-linkage owner, which calls `add` here rather than introducing a second schema.
The legacy `issue=<number>` field in task metadata records a same-repository GitHub issue and is not migrated into this store by this contract; that migration belongs to the same linkage owner.

## Normalized PR state

A recorded PR URL does not say whether work is waiting on review, waiting on checks, conflicting, or already merged.
`bin/fm-pr-status.sh` is the one network caller for this normalized observation and the one place that maps each forge's vocabulary onto these enumerations.

| Field | Values |
| --- | --- |
| `state` | `open`, `draft`, `closed`, `merged`, `unknown` |
| `review` | `approved`, `changes_requested`, `review_required`, `none`, `unknown` |
| `checks` | `passing`, `failing`, `pending`, `none`, `unknown` |
| `mergeable` | `mergeable`, `conflicting`, `blocked`, `unknown` |

The observation is cached at `state/<id>.pr-status` with an `observed_at` stamp, and the snapshot reports `status_age_seconds` as the age of that cached record.
Read-only consumers report the cached value with its age and never call a forge themselves, so the fleet snapshot stays offline and fast.
`bin/fm-pr-check.sh` seeds the cache when it arms a merge watch, `bin/fm-pr-merge.sh` refreshes it after a merge, and `bin/fm-teardown.sh` refreshes it when the cached observation cannot already prove the merge it needs before reaping a task branch; all are best effort, and a failed refresh leaves the previous observation in place rather than overwriting a good reading with `unknown`.
Best effort is not silent: the callers whose own operator line depends on that reading, the post-merge warning in `bin/fm-pr-merge.sh` and the kept-branch reason in `bin/fm-teardown.sh`, fold in the bounded one-line cause the refresh printed, so an operator reads why the observation could not be refreshed instead of only that it was not.
Every cache read validates the canonical PR identity, the normalized enumerations, the draft type, the head SHA, the ISO-8601 UTC observation stamp, and the provider source before exposing it.
A cache whose URL does not match the task's current canonical PR URL projects the documented unknown observation, while a failed refresh for the same URL retains the previous valid observation.
GitLab review state combines the merge request approvals endpoint's current `approved`, `approvals_required`, `approvals_left`, and `approved_by` values to distinguish `none`, `review_required`, and `approved`, and ambiguous or unavailable results degrade to `unknown`.
A present `approvals_left` is authoritative: a positive value is `review_required`, zero requires a consistent result, and only a missing value falls back to `approved` plus `approvals_required`.

## Snapshot projection

`fm-fleet-snapshot.v1` grows additively.
Every field below is new; a v1 consumer that reads only the fields it already knows keeps working unchanged, so no renderer migration is required.

Per task: `model`, `effort`, `paths.status_log.last_event_at` and `last_event_age_seconds`, the parsed PR identity with `head`, `status`, `status_age_seconds`, and `status_freshness`, the `work_items` list, and the computed `card`.
`status_freshness` is `cached` for a valid matching observation and `absent` otherwise; consumers use `status_age_seconds` when they need an age policy.

Also per task: `hints.last_event_declared_wait`, a boolean saying whether the newest status line declares its own quiet - a `paused:` external wait or a captain-held transfer.
[`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh) owns that vocabulary and `status_is_paused_or_captain_held` decides it, the same call the supervision watcher makes, so a renderer never reimplements the token list and the two surfaces cannot disagree about what a declared wait is.
A consumer that has not adopted the field reads it as absent and keeps its previous behavior, whether that verdict is an elapsed time or an endpoint-presence reading.

Also per task: `paths.turn_ended`, the age of `state/<id>.turn-ended` - the harness-neutral turn-boundary wake marker written either by a verified turn-end producer or by cursor/agy's identity-gated, debounced Herdr-native idle detector.
[`bin/fm-watch.sh`](../bin/fm-watch.sh) owns that marker and already ages this exact file to bound how long a busy pane may go with no turn-boundary wake, so it stays what that owner says it is: a wake notification and an activity timestamp, never current state or terminal attestation.
It exists here because the status log is a REPORTING cadence rather than an activity one - the crew brief instructs workers to append only on phase changes - so a surface that wants to know when a task last DID anything needs a clock the worker does not choose.
An absent marker reports `present: false` with a null age, because a harness with no observed turn-boundary wake and one that never touches the marker have the same projection, and neither is evidence of a stall.

Also per task: `spawn_age_seconds`, how long ago the task was DISPATCHED.
It ages the `spawned_at` epoch [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) stamps into `state/<id>.meta` at dispatch, and it is null when no readable stamp is present.
It is published for one reason: it is the clock a renderer falls back to when a task has neither reported nor completed anything, so such a task still has a bound instead of an exemption without end.
A surface reaching for it before the status log or the turn marker would be reading a dispatch time as an activity time; it is a last resort, not a third activity clock.

It is deliberately the recorded VALUE and not the age of the `state/<id>.meta` file, because those two mean different things.
The file is rewritten after dispatch by firstmate's own routine actions: [`bin/fm-pr-check.sh`](../bin/fm-pr-check.sh) rebuilds it when it records a PR, [`bin/fm-promote.sh`](../bin/fm-promote.sh) rewrites it on a kind flip, and [`bin/fm-decision-hold.sh`](../bin/fm-decision-hold.sh) appends to it.
Its mtime therefore means "when anything last touched this record", and using it as an activity clock would let arming a PR check on a hung task silently re-buy that task a full quiet window.
Every one of those writers preserves the `spawned_at` line, so the stamped epoch stays what it says it is.

[`bin/fm-watch.sh`](../bin/fm-watch.sh)'s `busy_turn_over_age` does age the meta FILE, and that is a different question with a different correct answer.
It bounds how long a BUSY PANE may go with no turn-boundary wake, it owns that choice, and a file an operator action touched is a defensible floor for it.
It is not wrong and must not be changed to match this field.

Also per task: two further `current_state.source` values the snapshot can produce for itself, beside the existing `timeout`.
`not-attempted` means no bounded runner could be started, so the current-state read was never made - which is not the same fact as a read that ran past its bound, and only the caller that can tell them apart can report either honestly.
`row-unavailable` means the task's whole row could not be built; the row is still listed, with every value it would have read filled by that field's explicit unknown.
A task that was enumerated is never absent from `tasks[]`, because a missing row reads as a fleet that does not contain that task, and an id for which not even the degraded row can be produced fails the whole command by name rather than publishing an incomplete document.
None of the three is evidence of anything, so no consumer may treat them as a pass.

Per backlog record: `since_age_seconds`, the age of the row's `since` date.
`tasks-axi` writes `since` when the row is created and does not rewrite it on hold, so this measures how long the item has been raised and never how long a hold has stood; a surface that needs hold duration needs a hold stamp the backlog does not yet record.
The backlog stores a LOCAL date with no clock time - `tasks-axi` stamps the writer's own calendar day, not a UTC one - so the age runs from that day's local midnight on the observing host and is an upper bound at day granularity.
The snapshot resolves each date to its local-midnight instant itself rather than letting `jq`'s UTC `strptime`/`mktime` decide the day start, which on a host ahead of UTC would put the start after the instant the date was written and under-report the age.
It is null when no readable date is present, and 0 rather than negative for a row dated ahead of the observation, matching the clock-skew convention the snapshot's file ages already use.

The same `since` field is read with two different day-start conventions today, and they are known to disagree.
This projection reads it at local midnight, while the manifest's `created` fallback ([Timestamps and their provenance](#timestamps-and-their-provenance)) reads it at UTC midnight, so the two day starts differ by the observing host's UTC offset for that date.
Reconciling the manifest's timestamp provenance is a behavior change in that write path, tracked separately as `fm-since-day-start-convention-split`.

Top level: `card_precedence`, `supervision` (watcher beacon age against the shared grace window from `bin/fm-supervision-lib.sh`, that library's `quiet_allowance_seconds`, plus away-mode state and age), and `history`.

`supervision.watcher.quiet_allowance_seconds` is how long a live worker may stay quiet before the quiet is worth inspecting.
It is published for the same reason `grace_seconds` is: supervision already decides it, and a renderer that picks its own number ends up disagreeing with supervision about one fleet.
[`bin/fm-supervision-lib.sh`](../bin/fm-supervision-lib.sh) owns the window and [`docs/configuration.md`](configuration.md) documents its `FM_BUSY_TURN_MAX_SECS` override.

`history` is schema `fm-outcome-history.v1`, built from every `data/<id>/outcome.json` in the home, newest completion first and bounded by `FM_SNAPSHOT_HISTORY`.
A manifest that no longer parses, lacks the complete required shape, is not a plain file, or exceeds the read bound is disclosed in `history.malformed` with its reason rather than dropped, so a consumer can distinguish "nothing completed" from "one record is unreadable".
History orders readable same-schema candidates before applying full value conformance, then validates only enough newest candidates to fill the requested bound.
A read that counted completion records and then produced none of them is refused with a non-zero exit and a message naming the count and the directory, never published as an empty document: a lost read and a fleet that has finished nothing are the same bytes on the wire, and only the caller that sees the refusal can tell its operator which one happened.

### Card precedence

Signals overlap constantly: a task can have an open decision, an open PR, and a `done` event at the same time.
Exactly one column wins per task, resolved against this ladder in order, and `card.rank` is its 1-based position.
`card.signals` records the inputs that produced the verdict, so a surprising column is inspectable rather than opaque.

| Rank | Column | Action | Wins when |
| --- | --- | --- | --- |
| 1 | `needs_decision` | `decide` | a keyed decision is still open |
| 2 | `blocked` | `unblock` | a keyed blocker is still open |
| 3 | `parked` | `respond_to_gate` | validation is parked at a gate |
| 4 | `failed` | `investigate` | the task reported a failure |
| 5 | `review` | `review_pr` | a PR is recorded and not confirmed merged |
| 6 | `done` | `close_out` | the task reported completion with nothing left open |
| 7 | `waiting` | `recheck` | a declared external wait |
| 8 | `active` | `supervise` | the worker is working |
| 9 | `secondmate` | `route_work` | a persistent secondmate with no higher-priority task signal |
| 10 | `idle` | `inspect` | no current signal |

The ordering encodes four judgements worth stating.
An open decision outranks everything because it is unanswered work for firstmate or the captain even when a PR is already open.
A blocker outranks a failure because the worker is still there and asking.
A failure outranks an open PR because the PR is not the live problem.
An open PR outranks `done` because a task that reported "PR checks green" has not landed until that PR is merged.

## Secret safety

Manifests and snapshots carry no credentials, no raw prompts, no tool arguments, and no captured payloads.

That is enforced, not just documented.
Shared work-item and PR-status readers validate every stored value against its wire type, enumeration, canonical shape, and documented length cap before exposing it to a manifest or snapshot.
`fm_outcome_manifest_keys_valid` also checks a composed manifest against a fixed recursive key allowlist, and the writer refuses to publish a document carrying any path the allowlist does not name.
Every artifact reader and atomic publisher requires exactly one top-level JSON object, so concatenated records are refused rather than partially selected.
Adding a field is therefore a deliberate act in one place.
Producer-owned title and outcome detail values pass through `fm_outcome_text`, which strips control characters, collapses the value to a single line, and caps its length, while every other stored free-text value is rejected when it violates the same shape or its field-specific cap.
The PR observation stores only the enumerated tokens above and a head SHA; no API response body reaches disk.

`tests/fm-outcome-manifest.test.sh` plants sentinel secrets in private runtime records and in non-conforming allowlisted values inside present work-item and PR-status stores, then asserts none of it appears in a manifest or a snapshot.
The crew's own status line is deliberately outside that set: it is a single-line supervisor-facing field firstmate designed and has always surfaced, not a store of credentials or captured payloads.

## Verification

```
$ bash tests/fm-outcome-manifest.test.sh
$ bash tests/fm-fleet-snapshot-view.test.sh
$ bash tests/fm-teardown.test.sh
```
