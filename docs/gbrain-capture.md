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

A cut body says so, in the body.
The cut appends a marker naming the byte count, after redaction so the redactor cannot rewrite it, and the page a reader opens carries that marker at the end of what survived.
The record carries `truncated: true` and `captured_bytes` beside it, so an audit can count cut documents without reading prose, and `status` reports that count.
The marker names how much was kept rather than how much was lost: the cap bounds the read as well, so at the point of the cut the only known fact is the byte count that survived.
It is part of the body, so it is part of the content version - a body that starts hitting the cap is a new revision and is re-delivered, and a record captured before the marker existed is counted as truncated only once it is recomposed.

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
bin/fm-gbrain-capture.sh status                 # archived, pending, failed, unreadable, truncated, redacted
bin/fm-gbrain-capture.sh process                # retry every pending item
bin/fm-gbrain-capture.sh process --force        # retry an item whose attempts are exhausted, and re-deliver one already captured
bin/fm-gbrain-capture.sh backfill               # sweep every task with a manifest or report, refreshing any whose source changed
bin/fm-gbrain-capture.sh backfill --dry-run     # report what a sweep would capture
bin/fm-gbrain-capture.sh audit                  # compare what the outbox says was captured against what the index serves
bin/fm-gbrain-capture.sh sweep --force          # run the periodic refresh and audit right now
```

Retry is bounded: an item that fails `FM_GBRAIN_CAPTURE_MAX_ATTEMPTS` times (default 5) stops being retried by an ordinary run and waits for `--force`, so one permanently broken document cannot consume every later run's budget.
Backfill is restartable by construction - each enqueue and each delivery is its own durable transaction - and reports scanned, enqueued, captured, already-captured, refused, and error counts.
A refused document is counted and receipted without stopping the sweep, and `backfill` is the one surface that reports a refusal as a count, because it is the command the refusal happened under.
Backfill writes each task's `state/<id>.gbrain` receipt but never republishes a manifest that is already on disk, so a task captured after its own teardown is found through `status` and `show` rather than through its manifest, while a task captured during teardown carries the reference in the manifest itself.

Run a backfill once after adopting a brain, and after a long outage.

The outbox is also what a capture-fed home rebuilds its index FROM, because such a home has no markdown archive to import; [`gbrain.md`](gbrain.md) owns that rebuild and the migration procedure that depends on it.
It is read once more at query time: [`bin/fm-recall.sh`](../bin/fm-recall.sh) judges whether a page it is about to serve still matches the live source it was composed from, using that record's stored body and capture time, so a body truncated at the cap or rewritten by redaction leaves the comparison with no evidence rather than with agreement.
`bin/fm-recall.sh --help` owns that comparison and the page states it produces.

## Recovering from a damaged record

An outbox record is written atomically, so a crash leaves the previous complete record or none.
A record that is nevertheless unreadable - hand-edited, or damaged on disk - is reported as `unreadable` by `status` and named by `process`; it is never treated as delivered and never delivered blind.
Recapturing the task recomposes the record from the durable manifest and report and repairs it.

## A page goes stale when its source is edited, so the refresh is on a clock

Capture fires at cleanup.
A report edited after that never reaches capture again, because the task it belonged to is gone - and the page keeps serving the old body with nothing marking it stale.
That is not hypothetical: two reports were edited after capture and their pages were never refreshed, one of them keeping a finding the captain had voided, which a live query then returned at rank 1.

The fix is a clock rather than a rule, because a rule that says "recapture after you edit a report" is a habit and habits are what this failed on.
`sweep` recomposes every captured task, re-delivers the ones whose content hash moved to the same page, and then audits stored against served.
A session start arms it unconditionally; it runs at most once per `FM_GBRAIN_CAPTURE_SWEEP_INTERVAL` (default 6 hours), is inert and silent in a home with no brain, and prints only what an operator must act on.
The worst case is therefore one interval of staleness rather than forever.

The refresh itself is `backfill`, not a second recomposition path: `backfill` already recomposes each task and re-delivers a changed body to the same page, so a separate path would only be one more thing to drift.
It now names and counts what it corrected - `refreshed <id>` and a `refreshed=` total - so a sweep reports the drift it closed instead of folding it into the ordinary captured count.
Both are claims about a delivery rather than about a recomposition, so neither is made until that document reached the index: a run that recomposed a changed body but could not deliver it reports its errors and says nothing about a refresh, because the page is still serving the body the source moved away from.
The record itself remembers which content version the index was last given, and only a landed delivery moves it, so a refresh whose first delivery failed is still named exactly once - on the later sweep that finally delivers it - rather than being corrected in silence.

What the `refreshed` line claims is that the SOURCE changed, so it is fired from a fingerprint of the source rather than from the stored body:

- The content version hashes the composed, redacted body, and it must move whenever that body moves, because that is what re-delivers a page that needs rewriting.
- The source version hashes `data/<id>/outcome.json` and `data/<id>/report.md` as they sit on disk, before composition, before redaction, and before the cap.
  A note has none, because a note's body arrives through `/stow` rather than from anything on disk to re-read.
- Only the source version may back a claim about the source, because everything this pipeline writes into a body is in the content version and none of it is a change in the thing being captured: the truncation marker, the redaction placeholders, the schema string in the front matter, the front-matter rendering, the heading and its bullet list, the section headings, and the YAML escaping.
  Manifest-derived values stay source-derived either way, because the manifest's own bytes are part of the source fingerprint.

A body this pipeline rewrote on its own is therefore re-delivered silently: the page is corrected, and nothing claims a report changed that nobody edited.
The first sweep after the truncation marker shipped is exactly that case, and a record captured before the source fingerprint existed has no recorded source for its served page, so its first re-delivery is silent too rather than guessed at.
`bin/fm-recall.sh` judges the same drift at query time and marks a result stale; that is the read side telling a reader not to trust a page, and this is the write side making the page true again.

## Captured is not the same as served

An outbox record marked captured proves the page was **accepted** once.
It does not prove the page still exists: GBrain soft-deletes, and a soft-deleted row is absent from ordinary retrieval while the record that produced it still reads as archived.
Measured on this fleet, capture reported 291 archived while the index served 288 pages, and the three missing documents were soft-deleted and unreachable by search.

`audit` compares the two sides directly, from the outbox's own captured slugs and the index's page listing:

- `ok` - every captured document is served.
- `gap` - it names each captured document the index no longer serves, and exits non-zero.
- `inconclusive` - the listing could not be read, or came back at exactly its own `FM_GBRAIN_CAPTURE_AUDIT_MAX_PAGES` ceiling and may be incomplete.
  A capped listing is never reported as a gap, because a false gap is what would train an operator to ignore a real one.
  The verdict is decided from whether the listing command succeeded, never from whether it happened to explain itself, so a listing that dies without a message is inconclusive rather than a gap naming every captured document.

A listing is the only thing that can say a page is absent, and absence from a listing is what EVERY way a listing can fail looks like, so the listing only proposes candidates and a direct read decides.
Each candidate is asked for by slug with `gbrain get`, and it is reported missing only when that read fails the same way this brain fails for a slug the home never captured - a signature the audit learns by asking for one.
A candidate the listing dropped but the brain still returns names the listing untrustworthy rather than the page gone, and a read that could not answer either way reaches no verdict at all.
`FM_GBRAIN_CAPTURE_AUDIT_MAX_PROBES` (default 25) bounds that verification: a candidate set larger than it is better evidence that the listing is wrong than that the pages are gone, so it is reported inconclusive rather than verified one read at a time.

Every direction the listing can fail, and what each does:

| direction | outcome |
| --- | --- |
| `gbrain` is not installed | inconclusive |
| the listing exits non-zero | inconclusive |
| the listing times out | inconclusive |
| it exits non-zero with nothing on stderr | inconclusive - the exit status is the signal, never the text |
| it returns exactly its row ceiling | inconclusive, with `active` a floor and `missing` a ceiling |
| it exits 0 with no parseable rows | inconclusive - the direct read returns the candidates |
| its columns move, so no row's first field is a slug | inconclusive - same path |
| it silently caps below the requested limit | inconclusive - the pages it dropped are still served |
| a shared brain returns only other homes' rows | inconclusive - same, and the prefix already scopes the comparison |
| the direct reads themselves fail | inconclusive - a page the listing does name is read back first, and a brain that cannot return that one is not trusted to say any page is gone |
| a complete listing and a genuinely deleted page | `gap`, which is the finding the audit exists for |

One direction stays narrowly open rather than being hidden.
When the listing names no page at all there is no served page to read back, so the absence signature is the only evidence available, and a brain that failed every read that same way would report a gap.
An oversized candidate set is refused rather than verified, which bounds that to a home whose whole corpus is small enough to have been lost.

Every count in the verdict says how far it can be trusted, and `bounds` in the record carries that for each one:

- `exact` - measured and believed whole, which is what `stored` and `truncated` always are, because both are counted from this home's own outbox.
- `at-least` - measured against a listing known to be partial, so the true value is this or higher. `active` is a floor on the ceiling branch: every page the listing named really is served, and the ones it dropped are still served too.
- `at-most` - the same partial listing in the other direction, so the true value is this or lower. `missing` is a ceiling on that branch, because a page the listing dropped looks absent whether or not it is, and `missing_slugs` there names unverified candidates rather than findings.
- `unmeasured` - the count is `null` and nothing was compared, which is what both `active` and `missing` are when the listing could not be read at all.
  A `null` is not a zero: an audit that could not count says so rather than reporting none, and `missing_slugs` is empty only because there was nothing to name.

It writes its verdict to `state/.gbrain-audit`, and that record is what the operator-facing surfaces replay:
the GBrain panel's Capture card turns degraded and names the missing count, and a session start relays the same verdict on a `GBRAIN_CAPTURE:` line.
Neither surface re-measures it, because the dashboard polls continuously and re-opening the index on every poll would put a repeated index read behind a poll that has to stay cheap.
Because it is replayed rather than re-measured, the Capture card renders how old the observation is beside the verdict: a gap already repaired by hand keeps reading red until the next sweep, and a clean answer measured weeks ago must not read like one measured minutes ago.
A home where the audit has never run reports that it has never run, rather than reporting a zero gap nobody measured, and has no age to render.

Only a verdict earns the card's green dot, because green is the positive claim that the parity check ran and passed:

- `gap` and a failed delivery are proven faults, so the card reads `degraded` in red.
- `inconclusive` reads `unverified` on the hollow ring, because an audit that could not compare the two sides must never be shown as a clean bill - that is the same complacency the fail-closed rule above exists to prevent.
  An outbox record that could not be read at all reads `unreadable` on the same ring, for the same reason and with the count beside the archived, pending and failed ones.
- `unknown` reads `unaudited` in blue, which is the panel's tone for a card making no claim in either direction.
  A home whose first sweep has not landed yet has nothing to read and nothing wrong with it, so it is neither counted as a nominal system in the panel's collapsed summary nor counted there as unreadable, and it does not turn that summary's dot into the hollow ring.
  Its wording is kept apart from the `unverified` wording for the same reason: one means an audit ran and could not compare, the other means none has run here yet.

A home with no brain is not an unaudited home; it renders nothing about capture at all, the way it did before GBrain existed.
A configured home whose local index is not bootstrapped keeps its own `off` state ahead of all of these.

A gap is not automatically a fault: a page deleted deliberately shows up here too.
Recapture the document if it should still be served, or restore it in GBrain if it was deleted by mistake.

Which recapture depends on what the document was captured from, because only one of the two kinds has a durable source to recompose from:

- A task is recomposed from its manifest and report under `data/`, so `backfill` repairs it.
- A note has no durable source under `data/` at all - `/stow` delivered it and the outbox record is the only copy - so `backfill` walks straight past it and repairs nothing.
  Re-deliver its stored body with `bin/fm-gbrain-capture.sh process --document <document-id> --force`, taking the document id from `status --json`.

Recapturing the wrong way is how a real gap gets ignored: an advised repair that silently does nothing leaves the same gap reported on every sweep.
