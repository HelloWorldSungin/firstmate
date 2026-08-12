# GBrain memory verbs and the v0.45.0.0 upgrade: measured behaviour

Dated empirical evidence for what GBrain `v0.45.0.0` provides to Firstmate's captured corpus, and for the upgrade that installed it.
It exists because the `v0.43.0.0` and `v0.45.0.0` release notes read as though they retire several of the capture guarantees Firstmate still owns, and the measurements below show which of those readings survive contact with the binary.
The installation and upgrade procedure itself is owned by [`../gbrain.md`](../gbrain.md); the delivery-side receipt proof is owned by [gbrain-capture.md](gbrain-capture.md); the retrieval quality numbers are owned by [gbrain-eval.md](gbrain-eval.md).

## Environment

Measured 2026-08-12 against `gbrain 0.45.0.0` at commit `d35c9c9e441e6cfc86dd5e84b0b168c6b18ee775`, upgraded from `0.42.69.0` at `3acd511b80bd4d2fe487290a70de75d4cf094730`, on Bun `1.3.14`.
Brain paths were resolved with `bin/fm-gbrain.sh paths` rather than from the absolute paths in the operator reference, because a second deployment tree exists under `~/.local/share/gbrain` and was not touched:

```text
brain_root  /home/sungin/firstmate/data/gbrain
gbrain_home /home/sungin/firstmate/data/gbrain/runtime
pglite      /home/sungin/firstmate/data/gbrain/pglite
```

Every `remember` and `recall` probe below ran against a disposable PGLite brain under a temp path, never against the live corpus.
No hosted synthesis and no hosted corpus analysis was run.

## The upgrade changed no measured capture or retrieval property

| Measure | `0.42.69.0` | `0.45.0.0` |
| --- | --- | --- |
| Schema version | 125, latest 125 | 125, latest 125 |
| Capture outbox | 156 archived, 0 pending, 0 failed, 0 unreadable | 156 archived, 0 pending, 0 failed, 0 unreadable |
| Active pages | 153 | 153 |
| All pages including soft-deleted | 156 | 156 |
| Corpus chunks / embedded | 835 / 835 | 835 / 835 |
| Corpus revision | `sha256:04266c51c0d3e3cbea83168d1e0e63e668a7111059d78b8dc98eed0e12e5452f` | identical |
| search top1 / topk / MRR | 0.925 / 0.95 / 0.9375 | 0.925 / 0.95 / 0.9375 |
| Retrieval misses | q24, q35 | q24, q35 |

`gbrain doctor --json` reported `connection`, `schema_version`, `embeddings`, `embedding_provider`, `embedding_width_consistency`, and `reranker_health` as `ok` on both versions, and its full set of non-`ok` checks was unchanged across the upgrade, so the upgrade introduced no new finding of its own.

Both columns are one snapshot taken either side of the upgrade with no capture running.
Unrelated fleet tasks completed afterwards and the corpus reached 159 outbox records against 156 active pages within the hour, so the absolute counts move; what the comparison establishes is that the upgrade changed none of them.

The three-record gap between the outbox and the active index is older than this upgrade and survived it unchanged, at both sizes.
The same three pages are soft-deleted on both versions and ordinary `get` returns `page_not_found` for each:

```text
firstmate/firstmate-bc8432f7/task/arknodelabs-deploy-hostkey-scan-fragile
firstmate/firstmate-bc8432f7/task/tsa-434-scope
firstmate/firstmate-bc8432f7/task/tsa-domain-model
```

## Facts and pages are separate stores, and the verbs reach only one

The `v0.43.0.0` memory verbs operate on the facts table.
Firstmate's entire captured corpus is pages, written by `gbrain capture`.

A page captured into the probe brain was invisible to `recall`'s facts arm and appeared only in its search arm:

```text
$ gbrain call recall '{"entity":"ct100"}'
facts:   ["CT100 OHLCV service is inactive today", "CT100 OHLCV service is active and enabled"]
results: 0

$ gbrain call recall '{"query":"CT100 OHLCV service state"}'
results: [{"slug":"probe/ct100-state"}]
```

The supersession audit log returned by `recall {"supersessions": true}` contains only facts and never pages.
Provenance, expiry, and supersession are therefore properties a fact can carry, not properties Firstmate's existing pages acquire by upgrading.

## `remember` enforces provenance

Omitting it fails rather than defaulting:

```text
$ gbrain call remember '{"fact":"CT100 OHLCV service is inactive"}'
Missing required parameter: provenance
```

The verb is reachable as a bare CLI subcommand even though `gbrain --help` does not list it:

```text
$ gbrain remember "probe fact" --provenance "probe"
remembered as fact #6
```

## Supersession is a near-duplicate string rule, not contradiction resolution

`src/core/facts/write-single.ts` describes it as a "minimal deterministic rule, zero LLM", frozen as implementation-defined: the new fact supersedes the top dedup candidate only when that candidate scores at or above a 0.95 cosine threshold with the same `kind` and different text.
Measured against the case that motivated the capture review:

| Second write, same entity `ct100` | Result |
| --- | --- |
| The identical string | `duplicate` - kept fact #1, nothing written |
| "CT100 OHLCV service is **active and enabled**" after "...is inactive" | `inserted` as fact #2 - **both remain active, neither expires** |
| "CT100 OHLCV service is inactive **today**" after "...is inactive" | `superseded` - fact #1 gets `expired_at`, `superseded_by: 3` |

The semantically contradictory pair does not supersede, and `recall` returns both claims as current with no stale marker.
The release note's "X joined acme-example" to "X left acme-example" example resolves only because those two strings are lexical near-neighbours.

Dedup and supersession are additionally skipped whenever `entity` is absent, so an identical fact written twice without an entity inserts twice.
Any Firstmate use of `remember` for current facts has to set `entity` to get either property.

## `recall` reports its own packing, which is not the capture-side cap

Budget packing is real and the server reports what it dropped:

```text
$ gbrain call recall '{"budget_tokens":20}'
{"budget_tokens":20,"budget_used":18,"dropped_count":2}

$ gbrain call recall '{"budget_tokens":5000}'
{"budget_tokens":5000,"budget_used":39,"dropped_count":0}
```

That governs response packing at read time.
Firstmate's own body cap is a separate mechanism at capture time, `FM_GBRAIN_CAPTURE_MAX_BYTES` in [`../../bin/fm-gbrain-capture-lib.sh`](../../bin/fm-gbrain-capture-lib.sh), still defaulting to 65536.
The corpus still holds one body of exactly 65536 bytes, `task/arknode-npm-hardening-plan`, and the outbox record schema has no truncation field, so a cut report is still indistinguishable from one that ended naturally.

## The `v0.45.0.0` bootstrap checks do not apply to this deployment

`bootstrapDoctorChecks` is gated on bootstrap state existing on the machine, and returns no checks at all when `gbrain bootstrap` has never run.
Firstmate does not run it, and no `bootstrap_*` check appeared in the post-upgrade `doctor` output.

`bootstrap_push_health`, the check the release note describes as push staleness, compares a `push-status.json` timestamp against a 48-hour threshold and runs `git status --porcelain` on the bootstrap workspace directory.
It reports whether a personal-agent workspace repository has unpushed commits, and has no relation to capture-outbox-to-index parity.

Measured against the live corpus, nothing native detects the divergence: with three pages soft-deleted and 156 outbox records marked captured, `doctor` reported `connection: ok, 153 pages` and every integrity-class check - `integrity`, `content_hash_duplicates`, `child_table_orphans`, `orphan_ratio`, `jsonb_integrity` - as `ok`.
The capture outbox is a Firstmate artifact that GBrain has no knowledge of, so no released check can compare the two inventories.

## The delivery receipt already carries more than the wrapper reads

`gbrain capture --json` returns a structured receipt:

```json
{"slug":"probe/receipt-shape","status":"created_or_updated","chunks":1,
 "content_hash":"377d6d98a09dfd5fcb00d724550eb82e78b7dd8932654b42b313bae5b4a43954",
 "written":false,"source_kind":"capture-cli","captured_at":"2026-08-12T00:35:00.215Z"}
```

`src/commands/capture.ts` is byte-identical between the two tags, so this is not an upgrade gain.
[`../../bin/fm-gbrain-capture.sh`](../../bin/fm-gbrain-capture.sh) parses the receipt for `.slug` alone and discards `status`, `chunks`, and `content_hash`, which are the values a stricter delivery postcondition and a later parity audit would compare against.

## `think` is reachable by a read-only share, and cannot persist through it

`src/core/operations.ts` declares `think` with `scope: 'read'`, changed from write scope in `v0.42.76.0` at commit `130d321d`.
A read-only client is therefore admitted rather than refused, which is what the operating rule in [`../gbrain.md`](../gbrain.md) exists to bound.

Measured through the live read-only share in `tests/fm-gbrain-readonly-e2e.test.sh`, calling `think` in its most dangerous form - explicitly asking to persist - over a token holding only `read`:

| Assertion | Result |
| --- | --- |
| The transport admits the call | No `insufficient_scope`; the call returns a result |
| A remote caller asking to persist is refused the persistence | `remote_persisted_blocked: true` |
| No synthesis page is recorded | `saved_slug: null` |
| The main brain's page set is unchanged | Slug set identical before and after |
| `put_page` and `delete_page` | Still refused with `insufficient_scope` |

With no hosted credential on the serving home the call degrades rather than exporting anything, which is the behaviour the operating rule relies on:

```text
"answer": "(no LLM available — set ANTHROPIC_API_KEY or pass `client`)",
"warnings": ["NO_ANTHROPIC_API_KEY"], "synthesisOk": false, "usage": null
```

`--surface verbs` is not an alternative bound: it still exposes the equivalent `synthesize` verb, so the surface setting cannot remove hosted synthesis from a served brain.

## What this leaves to Firstmate

| Capture guarantee | State after `v0.45.0.0` |
| --- | --- |
| Audit and health that fail on outbox-to-index divergence | Firstmate's. Nothing native compares the two inventories. |
| Capturing corrections and current facts, not only pruned text | Storage primitive is native through `remember`; every trigger is Firstmate's. |
| Verified delivery and bounded retry drain | Firstmate's, and cheaper than a fresh design: three of the four postconditions are already in the receipt above. |
| Provenance, validity, supersession | Native for facts under the 0.95 near-duplicate rule; absent for pages, which are the whole captured corpus. |
| Answer protocol over a retrieval miss | Firstmate's. Nothing native addresses it, and the coexisting contradictory facts above make it more necessary rather than less. |
| Evaluation gates for integrity and currency | Firstmate's. `eval brainbench` grades harness memory conformance over its own fixtures, not this corpus. |
| Explicit truncation of an over-cap body | Firstmate's. `recall`'s `dropped_count` is read-time packing, a different mechanism. |

`gbrain eval suspected-contradictions` is the closest native relative of the currency gates, but it judges sampled query pairs with an LLM through the configured model, which is hosted on this fleet.
Running it would send brain excerpts off the host, so it is recorded here and deliberately not run.

## Maintaining this file

Refresh it on the next GBrain pin move, and treat every row of the closing table as a claim that has to be re-measured rather than carried forward.
Keep the probes on a disposable brain, and keep the hosted-synthesis boundary in [`../gbrain.md`](../gbrain.md) rather than restating it here.
