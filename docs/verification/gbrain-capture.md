# GBrain task-knowledge capture: live evidence

Dated empirical evidence for the delivery half of [`../gbrain-capture.md`](../gbrain-capture.md), the half a stub cannot establish.
The Firstmate-owned half - redaction before enqueue, durable outbox, bounded delivery, deterministic identity, restartable backfill - is enforced portably by `tests/fm-gbrain-capture.test.sh` and needs no installation.

Refresh this record with:

```sh
FM_GBRAIN_LIVE_E2E=1 FM_GBRAIN_BIN=/home/sungin/.local/gbrain/bin/gbrain \
  bin/fm-test-run.sh tests/fm-gbrain-capture-e2e.test.sh
```

## Environment

Verified 2026-08-04 against `gbrain 0.42.69.0` at `/home/sungin/.local/gbrain/bin/gbrain`, with the local embedding endpoint `http://127.0.0.1:11434/v1` serving `ollama:snowflake-arctic-embed2:568m` at 1024 dimensions.
The proof builds its own disposable PGLite brain under a temp home and never touches the operator's brain.

## The delivery command's receipt is structured, not a bare slug

`gbrain capture --quiet` does not print only the slug in this version.
It prints a labelled block, so a line-shaped parse records the label rather than the page:

```
$ gbrain capture --file /tmp/probe.md --slug probe/four --type note --quiet
captured:
  slug:          probe/four
  status:        created_or_updated
  content_hash:  635c8732328da11b…
  captured_at:   2026-08-04T19:47:03.866Z
```

`--json` is the machine-readable form, and import warnings precede it on the same stream:

```
$ gbrain capture --file /tmp/probe.md --slug probe/three --type note --json
[import] WARNING: probe/three shares content_hash with probe/one (05b65b14) but has different frontmatter.id. Indexing both.
{
  "slug": "probe/three",
  "status": "created_or_updated",
  "chunks": 1,
  "content_hash": "635c8732328da11be65ef056cd67282538965762b0f162f960652dea83cd0a32",
  "written": false,
  "source_kind": "capture-cli",
  "captured_at": "2026-08-04T19:44:44.543Z"
}
```

`bin/fm-gbrain-capture.sh` therefore reads the page reference from `.slug` in that document, starting at the first `{`, and treats an unparseable receipt as a failed delivery rather than assuming the slug it supplied.

## A supplied slug upserts one page

The live proof captures one task, changes its report, and captures again.
The brain holds one page for that slug both times, carrying the newer revision:

```
$ gbrain list --limit 20
probe/four	note	2026-08-04	hello brain
firstmate/home-b7604cb1/task/ship-live	firstmate-task	2026-08-04	Bound the reranker input
```

Capturing byte-identical content again returns `"status": "skipped"`, so GBrain's own content hash also short-circuits a redundant write.

## The knowledge outlives the task

The proof reads the page back with `gbrain get <slug>` using only the reference the durable manifest carries, after deleting the capture receipt and the report.
The task's findings still come back, which is the guarantee the whole capture path exists for.

```
ok - a captured task is retrievable from a real brain by the receipt the manifest carries
ok - recapturing a changed task updates the same page instead of accumulating copies
ok - the captured knowledge outlives the task's own records
all fm-gbrain-capture-e2e tests passed
```
