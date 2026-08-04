# Capturing task knowledge into a home's brain

This operator reference owns how a finished task's knowledge reaches a Firstmate home's own brain: what is captured, what is refused, when delivery happens, and how to retry or backfill it.
[`gbrain-scoping.md`](gbrain-scoping.md) owns which brain a home writes, [`gbrain.md`](gbrain.md) owns the installation and archive procedure, [`fleet-data-contracts.md`](fleet-data-contracts.md) owns the durable completion manifest that carries the capture receipt, and [`verification/gbrain-capture.md`](verification/gbrain-capture.md) holds the dated live evidence.
`bin/fm-gbrain-capture.sh --help` and `bin/fm-gbrain-capture-lib.sh` own the exact commands, flags, and wire shapes.

## Why it exists

Cleanup removes a task's volatile records and the backlog prunes its Done row, so a completed task used to leave nothing but its durable manifest and, for an investigation, its report.
Knowledge that survives only while the task exists is not memory.
Capture turns each finished task into a page in the home's own brain, addressed by a reference the durable manifest keeps, so the task stays retrievable after everything volatile about it is gone.

Capture is inert until a home has an initialized brain.
A home that has not adopted GBrain creates no outbox, writes no receipt, and its cleanup behaves exactly as it did before.
Inertness covers the subcommands a lifecycle step or `/stow` calls; the two operator sweeps below, `process` and `backfill`, instead name the missing index and exit non-zero, because they were asked to work on an outbox that cannot exist.

## What is captured, and what is never read

The composer's inputs are enumerated rather than discovered:

- the task's durable completion manifest, `data/<id>/outcome.json`;
- the task's report, `data/<id>/report.md`, when it has one;
- a note routed deliberately by `/stow`, whose body the invoker supplies.

It never opens a brief, a prompt, a transcript, a tool-argument log, an environment file, a credential store, or anything under a project.
That is why "no raw tool arguments, no environment values, no private file excerpts" is a property of the code path rather than a promise about content.

The composed body is capped at `FM_GBRAIN_CAPTURE_MAX_BYTES` (65536 by default) so an enqueue on the cleanup path costs a bounded read and a bounded write however large a report grew.
An unusually long report is captured truncated at that cap rather than refused, so raise the cap before a backfill if a home's reports routinely exceed it.

## Redaction happens before enqueue

Once a body reaches the outbox it is on disk, so redaction runs before the record is written, not before delivery.
Credential-shaped material is rewritten in place and counted by class: brain client secrets, GitHub tokens, Slack tokens, AWS access keys, JWTs, `sk-` API keys, URL userinfo, `Authorization` headers, bearer tokens, uppercase environment assignments whose name ends in a credential word, and credential-shaped assignments or command-line arguments.
A complete `BEGIN … END PRIVATE KEY` block is replaced whole.

The redacted body is then re-checked, and a body that still carries credential-shaped content is **refused**: nothing is written to the outbox, nothing is delivered, and the refusing command reports the reason.
The case that reaches this by design is an unterminated private-key block: with no `END` marker there is no way to know where the key material stops, so the document is refused rather than partially rewritten.

### Where a refusal is visible

A refusal deliberately leaves no outbox record, so `status` cannot report one.
Where it *is* reported differs per subcommand, because each has a different caller and a different tolerance for failure, so read the one you called rather than a single rule.

- `task` writes `state/<id>.gbrain` with `status=skipped` and the reason, warns on stderr, and **exits 0**.
  That is deliberate: capture must never be able to fail a teardown.
  `--require-brain` is the opt-in that makes a missing brain fatal for a caller that wants it to be.
- `backfill` writes the same per-task receipt, reports `refused <id>: <reason>` on **stdout** as part of its run summary, counts it under `refused` rather than `errors`, and **exits 0**, for the same reason.
- `note` writes **no receipt at all**, because a receipt is keyed to a task id and a note has none.
  It prints the reason on stderr and **exits non-zero**: a refused note is a real failure, and nothing downstream depends on it succeeding.
  This is the subcommand `/stow` calls, so `/stow` takes a refusal from that non-zero exit and stderr.

Do not collapse those three into one rule.
No single signal covers them: the receipt does not exist for a refused note, and the exit status does not move for `task` or `backfill`.

`bin/fm-gbrain-capture.sh status` reports how many values were redacted, and `show <document-id>` prints one stored record including its redacted body.

## Identity, and why delivery is idempotent

A document's **logical identity** is the schema version, the home, the source kind, and the source id.
That identity produces the page address, so recapturing a task updates the same page instead of accumulating copies.
The home is part of it, so the same task id in two homes is two documents, never a collision.

The **content version** is a hash of the redacted body, and the **revision id** combines the two: it names one exact revision of one logical document.
A changed body is a new revision of the same document, not a new document.
Replaying an outbox item is therefore safe, and the live proof confirms that a supplied slug upserts rather than accumulates.

## Cleanup never waits on the brain

Cleanup publishes the durable manifest, then captures, then removes anything.
Capture writes its outbox record synchronously first and only then attempts delivery, bounded by `FM_GBRAIN_CAPTURE_TIMEOUT` (default 20 seconds).
A brain that is stopped, locked, or slow leaves a durable pending item and a warning; the cleanup continues and the task's records are still removed on schedule.
Nothing is lost, because the pending item already carries the knowledge.

The capture receipt is written before the manifest is republished, which is the only reason a torn-down task's manifest can carry its capture state at all.
The receipt always names the page address, even while the item is pending, because that address is deterministic - so a manifest published before delivery still points at where the document will live.

## Retrying and backfilling

```sh
bin/fm-gbrain-capture.sh status                 # archived, pending, failed, unreadable, redacted
bin/fm-gbrain-capture.sh process                # retry every pending item
bin/fm-gbrain-capture.sh process --force        # retry an item whose attempts are exhausted
bin/fm-gbrain-capture.sh backfill               # sweep every task with a manifest or report
bin/fm-gbrain-capture.sh backfill --dry-run     # report what a sweep would capture
```

Retry is bounded: an item that fails `FM_GBRAIN_CAPTURE_MAX_ATTEMPTS` times (default 5) stops being retried by an ordinary run and waits for `--force`, so one permanently broken document cannot consume every later run's budget.
Backfill is restartable by construction - each enqueue and each delivery is its own durable transaction - and reports scanned, enqueued, captured, already-captured, refused, and error counts.
A refused document is counted and receipted without stopping the sweep, and `backfill` is the one surface that reports a refusal as a count, because it is the command the refusal happened under.
Backfill writes each task's `state/<id>.gbrain` receipt but never republishes a manifest that is already on disk, so a task captured after its own teardown is found through `status` and `show` rather than through its manifest, while a task captured during teardown carries the reference in the manifest itself.

Run a backfill once after adopting a brain, and after a long outage.

## Recovering from a damaged record

An outbox record is written atomically, so a crash leaves the previous complete record or none.
A record that is nevertheless unreadable - hand-edited, or damaged on disk - is reported as `unreadable` by `status` and named by `process`; it is never treated as delivered and never delivered blind.
Recapturing the task recomposes the record from the durable manifest and report and repairs it.
