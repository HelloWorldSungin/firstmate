# Usage accounting

Firstmate records how many tokens the fleet actually spent and which task spent them.
[`bin/fm-usage.mjs`](../bin/fm-usage.mjs) is the single owner of the store, the harness collectors, the attribution ladder, and the rollups; its `--help` owns exact flags and environment names.
This page owns what is stored, how a task keeps its usage after cleanup, and what the numbers do and do not claim.

The collector is read-only towards every harness: it reads session records the harnesses already write and never asks a vendor API for anything.
Node.js 22 or newer is required for the built-in SQLite module, the same runtime floor the [dashboard](dashboard.md) already carries.

## Collect

```sh
bin/fm-usage.mjs ingest
bin/fm-usage.mjs report --by task
bin/fm-usage.mjs attribution
```

`ingest` scans this machine's Claude Code transcripts and Codex rollouts, stores every token-usage event, attributes what it can, and prints a JSON summary.
It is safe to run on any cadence, including concurrently with an earlier run that has not finished, because ingestion is idempotent rather than incremental-only.
Every derived table is rebuilt in place, and each rebuild commits its wipe and its repopulation together, so a failed run leaves the previous derivation rather than an empty table that would read as "nothing to report".
A stage that fails names itself in the summary's `failures` and in a non-zero exit status while the stages after it still run.
Four read-only projections print JSON without touching the store: `report --by task|project|harness|model|day`, `burn` for a bounded recent burn-rate series, `attribution` for the confidence breakdown and the percentage matched, and `sessions` for the session map itself.

The store lives at `data/usage.db` under the operational home and is private to it.

## What is stored

The store carries a `PRAGMA user_version` schema with forward-only migrations, so an existing store upgrades in place and a store written by a newer collector is refused rather than silently downgraded.

Each usage event carries a stable identity, its source provenance, and its raw counters:

| Group | Fields |
| --- | --- |
| identity | `event_id`, `session_id`, `occurred_at` |
| provenance | `harness`, `source_kind`, `source_path`, `source_ordinal`, `collector_version`, `ingested_at` |
| raw counters | `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens`, `model`, `cwd` |
| derived | `total_tokens`, `task_id`, `project`, `attribution_method`, `attribution_confidence` |

Raw fields carry the source's own numbers, adjusted only where a harness counts differently than the store does - both conversions are named below.
Derived fields are recomputed from raw fields and the durable task records on every ingest, so a corrected task record fixes history without re-reading a transcript.

The token columns are disjoint by contract: `input_tokens` counts input that was **not** served from a cache, `cache_read_tokens` and `cache_write_tokens` count the cached parts, and `total_tokens` is their sum plus output.
Harnesses disagree about that, so each adapter names the convention its own source uses and converts once, rather than letting the shared arithmetic assume one of them:

| Harness | Source convention | Conversion |
| --- | --- | --- |
| Claude Code | `input_tokens`, `cache_read_input_tokens`, and `cache_creation_input_tokens` are already disjoint | none |
| Codex | `cached_input_tokens` is a **subset** of `input_tokens`, and Codex's own `total_tokens` is input plus output | the cached part moves out of input, so the stored total matches Codex's own |

Reasoning tokens are a subset of the output count in both, so they are kept as a memo column and never added to a total.
A later OpenCode or Pi adapter names its convention the same way instead of inheriting whichever one was assumed.

`usage_session` holds one row per observed session, `usage_binding` the durable session-to-task map, `usage_task` the task facts attribution still needs after a task is gone, `usage_source` the per-file scan state that detects rotation and truncation, and `usage_cost_estimate` the optional estimate described below.

### Identity and idempotence

Reprocessing the same source never produces duplicate usage, because identity comes from the source content rather than from a file position.

- Claude Code writes the same API response to several transcript lines - once per streamed update, and again in a resumed or compacted transcript - each time with a fresh line identifier and the same numbers. The API message id is therefore the event identity, and the first write wins. On this fleet's own transcripts, roughly a third of assistant lines are such repeats.
- Codex reports cumulative session totals in each `token_count` event. The collector stores the monotonic growth of that counter, keyed by the rollout file and the event's ordinal within it, so a refresh that repeats the same totals adds nothing and a resumed session in a new rollout cannot collide with the old one.

A source is re-read whenever its size, modification time, or leading bytes changed; rotation and truncation both change one of those.
Re-reading a whole file is safe by construction, so the collector never has to trust a saved offset across a rotation.
A malformed, truncated, or unreadable line is counted and skipped: it cannot crash a scan or alter totals already stored.
A line that *is* a usage record but that an adapter cannot use - an unparseable timestamp, no usable identity, no readable counter - is counted separately as `events_skipped`, so a harness that renames one of those fields shows up as a number instead of as a quiet fleet.

## Attribution

Usage that loses its task at cleanup is worthless, so attribution is durable by design and conservative by default.

| Method | Confidence | Evidence |
| --- | --- | --- |
| `session_binding` | high | the session was observed in a live task's isolated worktree while that task held it, and the binding was recorded durably at that moment |
| `worktree_window` | medium | the session's working directory is a task's recorded worktree or a path inside it, and the usage falls inside that task's own start and completion stamps |
| `ambiguous` | none | more than one task claims that worktree for that moment, so no claim is made |
| `unknown` | none | no task claims it at all |

**A time window alone never attributes anything.**
Every claim starts from the task's own recorded worktree path, which the session must have run in or under; the task's own lifetime only bounds a claim that a path already supports.
Worktree paths are recycled between tasks, which is precisely why the bound exists and why an overlapping claim is disclosed as ambiguous instead of resolved by guessing.

A task counts as live only while its own `state/<id>.meta` is present in the scan that is running now, never because an earlier scan saw it.
Once that record is gone, the durable manifest supersedes what the live record said, and a task that left no manifest is retired at the moment its absence was first observed.
Either way the claim on the worktree ends when the task's hold on it ended, so the next task in that pool slot owns its own usage.

Task ids are operator-supplied slugs and `data/<id>/` outlives cleanup, so a stored task record describes one *occupancy* of an id.
Seeing an id live again while its record describes a finished occupancy starts that record over, which is why a re-dispatched slug gets its own window instead of inheriting the closed one.

Unattributed usage is preserved with explicit unknown fields and reported in every projection, including firstmate's own sessions, which belong to no task.
`bin/fm-usage.mjs attribution` reports the method and confidence breakdown plus the percentage of events and tokens matched.

### Surviving teardown

`state/<id>.meta` is the only structured record of a live task, and cleanup removes it.
The chain that carries attribution past that point has three steps:

1. While the task is live, `ingest` binds each session it observes in that task's worktree and publishes the map to `state/<id>.usage-sessions` (schema `fm-usage-sessions.v1`, at most 64 sessions).
   Cleanup refreshes that map once more before archiving, so the last session a task opened is not lost between collector runs.
   That refresh runs only when `data/usage.db` already exists, so a home that has never collected usage pays nothing.
   It is best-effort and time-bounded (`FM_TEARDOWN_USAGE_TIMEOUT`, 60 seconds by default): neither a failed nor a slow refresh can block cleanup, and either one degrades to the map the previous collector run already published.
2. [`bin/fm-outcome-manifest.sh`](../bin/fm-outcome-manifest.sh) copies that map into `attribution.sessions` in the durable outcome manifest, which is published **before** cleanup removes the volatile records ([fleet data contracts](fleet-data-contracts.md)).
3. A later `ingest` reads the manifest and restores the bindings, so a completed task keeps its token totals even if the store is deleted and rebuilt from the same transcripts afterwards.

A task whose usage was never collected simply archives with an empty session map; the manifest is never blocked on a collector having run.
Manifests written before this contract existed carry no session map and stay valid.

## Cost is an optional estimate

Cost is off by default and is never implied by tokens.
A subscription seat's tokens are not API dollars, so every projection reports tokens whether or not an estimate exists, and an unpriced model keeps its tokens with a null cost rather than an invented one.

To opt in, write the local, gitignored rate file described in [configuration](configuration.md#usage-cost-rates-configusage-ratesjson).
Every stored estimate carries the `rate_version` that produced it, and each rollup discloses how many of its events were priced and how many were not.

## Secret safety

The store needs no transcript content, so it never extracts any.

Each collector reads only enumerated fields from a source line: identity, timestamp, model, working directory, and numeric counters.
Prompts, responses, reasoning text, tool arguments, tool results, and system instructions are never parsed out, and every stored string is stripped of control characters and length-capped.
`tests/fm-usage.test.sh` plants sentinel prompt, response, tool-argument, and credential strings in both harnesses' fixtures and asserts none of them reaches the store.

## Harness coverage

Claude Code and Codex ship here.
OpenCode and Pi sit behind the same adapter interface - one function that turns a source line into the event shape above - and add no new store, attribution, or rollup surface when they land.

## Verification

```
$ bash tests/fm-usage.test.sh
$ bash tests/fm-outcome-manifest.test.sh
$ bash tests/fm-teardown.test.sh
```
