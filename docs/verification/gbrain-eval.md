# GBrain retrieval quality and the embedding-migration playbook

Active empirical evidence for the evaluation and migration procedure in [`../gbrain.md`](../gbrain.md): the measured retrieval and synthesis quality of a real Firstmate home brain, and the recorded behaviour of the embedding migration, its rollback, its interruption, and the rebuild from durable source.

Measured 2026-08-05 against GBrain `0.42.69.0` at commit `3acd511b80bd4d2fe487290a70de75d4cf094730`, the pin recorded in [`../gbrain.md`](../gbrain.md).
Every migration, reinitialization, and rollback below ran on a disposable copy of the index under `/tmp`, never on the live one.

## The configuration every number below belongs to

| Field | Value |
| --- | --- |
| GBrain | `0.42.69.0`, engine `pglite`, schema pack `gbrain-base-v2`, schema version 125 |
| Embedding | `ollama:snowflake-arctic-embed2:568m`, 1024 dimensions, `http://127.0.0.1:11434/v1` |
| Reranker | `llama-server-reranker:qwen3-reranker-0.6b-q8_0`, enabled, `http://127.0.0.1:8081/v1` |
| Hosted synthesis | `minimax:MiniMax-M3` via `https://api.minimax.io/v1` |
| Corpus | 64 documents, 532 chunks, 532 embedded; revision `sha256:b29c2dd31c3f3ec59f77895fdf745345fe70eb6d1fb78c5c445b70aa71892d92` from the capture outbox |
| Query | `scope=local limit=8 top_k=5 excerpt=400 think_max_answer=8000` |
| Evaluation set | `fleet-history` v1, `sha256:51238ce03cbe265ce6d797575a60b4502dba03efe1661122c733d4c7d4f3985f` |

The corpus is the home's own captured task knowledge: 63 completed tasks composed from their durable outcome manifests and scout reports, plus one note.
Sixteen of those documents are manifest-only ship records whose entire body is a title, an outcome line, and a pull-request URL, so the set measures retrieval over both long reports and near-empty records.

## Baseline

```console
$ bin/fm-gbrain-eval.sh run --home /home/sungin/firstmate --label 'baseline: ...' --out baseline.json
```

Run `2026-08-05T00:13:57Z` to `2026-08-05T00:20:24Z`, all 20 questions, one synthesis call per question.

| Metric | Measured | Threshold | Verdict |
| --- | --- | --- | --- |
| search top-1 | 0.95 | 0.60 | met |
| search top-5 | 1.00 | 0.85 | met |
| search MRR | 0.975 | - | - |
| think answered | 0.90 | 0.95 | **missed** |
| think grounded | 1.00 | 0.80 | met |
| think key facts | 0.889 | 0.70 | met |
| think citation precision | 0.792 | - | - |

The thresholds were registered in the evaluation set before the first measurement and have not been moved since.

Retrieval clears its thresholds with a wide margin: every question retrieved an expected source within the first five results, and only `q01` placed it below rank one, at rank two.
Hosted synthesis misses its threshold, and the section below establishes why and by how much.

## The missed threshold: hosted synthesis, not retrieval

Two of twenty synthesis calls returned no usable answer, both with `LLM_OUTPUT_NOT_JSON` and `CITATIONS_REGEX_FALLBACK`.
The failing calls are the two longest answers in the run by a wide margin:

```console
$ jq -r '.questions[] | "\(.id)\t\(.think.answer_chars)\t\(.think.answered)"' baseline.json | sort -k2 -nr | head -4
q03	7899	false
q17	7514	false
q05	2909	true
q10	2749	true
```

MiniMax M3 returns a long prose answer instead of the JSON envelope GBrain asks for, GBrain records `synthesisOk: false`, and `bin/fm-recall.sh` correctly reports hosted synthesis as unavailable rather than passing a non-answer through.
The failure is per call rather than per question, and it is not deterministic: three separate runs of the same twenty questions answered 15, 17, and 18 of them on the first call.

Allowing one retry closes most of the gap:

```console
$ bin/fm-gbrain-eval.sh run --home /home/sungin/firstmate --phase think --think-attempts 2 --out think-retry.json
```

| Metric | 1 attempt | 2 attempts |
| --- | --- | --- |
| answered | 0.85 | 0.95 |
| grounded | 1.00 | 1.00 |
| key facts | - | 0.877 |
| citation precision | - | 0.754 |

Three questions needed the second call and two of them succeeded on it.
The one that failed twice, `q01`, produced 8003 characters on its retry, at the run's `think_max_answer` cap.

**The remaining gap is explicit**: at the shipped one-call setting the home answers 85 to 90 percent of synthesis questions against a 95 percent threshold, and the shortfall is entirely the hosted provider's output format on long answers.
No embedding or reranker change addresses it, because retrieval already succeeds on every one of those questions - `q03` and `q17` both retrieved their expected source at rank one in the same run.
A different embedding artifact was nevertheless measured, below, because the migration playbook had to be exercised end to end.

## An alternative embedding artifact changes nothing measurable here

The tag was verified against the registry before it was named, and its native width was probed rather than taken from a model card:

```console
$ curl -s -o /dev/null -w '%{http_code}\n' https://registry.ollama.ai/v2/library/nomic-embed-text/manifests/v1.5
200
$ curl -s -o /dev/null -w '%{http_code}\n' https://registry.ollama.ai/v2/library/bogus-embed-model/manifests/latest
404
$ ollama pull nomic-embed-text:v1.5
$ curl -s $ENDPOINT/embeddings -d '{"model":"nomic-embed-text:v1.5","input":"probe"}' | jq '{model, dimensions: (.data[0].embedding | length)}'
{"model": "nomic-embed-text:v1.5", "dimensions": 768}
```

The artifact is `nomic-embed-text:v1.5`, model layer `sha256:970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6`, 274290656 bytes, config `sha256:31df23ea7daa448f9ccdbbcecce6c14689c8552222b80defd3830707c0139d4f`.
It was pulled into a scratch `OLLAMA_MODELS` directory served by a second Ollama instance on a scratch port, so the shared endpoint's model inventory was never touched.

| Run | top-1 | top-5 | MRR |
| --- | --- | --- | --- |
| live brain, arctic-embed2 1024d | 0.95 | 1.00 | 0.975 |
| disposable copy, arctic-embed2 1024d | 0.95 | 1.00 | 0.975 |
| same copy migrated to nomic-embed-text 768d | 0.95 | 1.00 | 0.975 |
| same copy rolled back to arctic-embed2 1024d | 0.95 | 1.00 | 0.975 |

The rank of every question is identical across the two models and only the reported scores move, so the migration genuinely happened and the two artifacts are indistinguishable on this corpus.
That is a statement about a 64-document corpus and this question set, not a general claim about the two models.
The disposable copy reproducing the live numbers exactly, at the same corpus revision, is what makes it a valid test bed for everything below.

## What the reranker is contributing

Nothing that this evaluation set can measure.
With the reranker endpoint pointed at a dead port, `gbrain call search` returns byte-identical results:

```console
$ GBRAIN_HOME=$scratch/runtime gbrain call search '{"query":"paper trading silent since june","limit":8}' > live.json
$ gbrain config set provider_base_urls.llama-server-reranker http://127.0.0.1:9/v1
$ GBRAIN_HOME=$scratch/runtime gbrain call search '{"query":"paper trading silent since june","limit":8}' > dead.json
$ cmp live.json dead.json && echo identical
identical
```

The reranker is genuinely reached - the llama-server `llamacpp:n_decode_total` counter advances by 10 for a search with the endpoint live and by 0 with it dead, against 0 over a 6-second idle window - and `gbrain doctor` reports `reranker_health ok, No rerank failures in last 7 days`.
It simply did not change the returned set, the order, or the reported scores for these queries.
The same conclusion arrives independently from the rebuild below, which ran with the reranker configuration wiped and scored identically.

## The evaluation detects an incomplete migration; `gbrain stats` does not

A migration killed after 11 of 64 pages leaves a brain that reports as fully embedded:

```console
$ gbrain stats
Pages:     64
Chunks:    532
Embedded:  532
$ gbrain doctor --json | jq -r '.checks[] | select(.name | test("^embeddings$|embed_staleness")) | "\(.name)\t\(.status)\t\(.message)"'
embeddings	ok	100% coverage, 0 missing
embed_staleness	warn	418 stale chunks (small backlog)
```

`gbrain stats` reports every chunk embedded, and doctor's own `embeddings` check reports `ok` while its message contradicts itself.
Only `embed_staleness` warns, and the overall doctor status is `warnings` rather than a failure.
The evaluation is what actually shows the damage:

| Brain state | top-1 | top-5 | MRR |
| --- | --- | --- | --- |
| complete | 0.95 | 1.00 | 0.975 |
| killed after 11 of 64 pages | 0.80 | 0.95 | 0.875 |
| killed after 12 of 64 pages | 0.80 | 1.00 | 0.900 |
| resumed to completion | 0.95 | 1.00 | 0.975 |

Re-running the identical migration command resumed rather than restarted, re-embedding 328 chunks across the remaining 48 pages in 5 seconds, and the resumed brain scores exactly as an uninterrupted one.

## Recorded migration and rebuild costs

All on a 64-document, 532-chunk corpus, with the embedding endpoint pinned to one RTX 5060 Ti.

| Operation | Duration | Index size | GPU |
| --- | --- | --- | --- |
| `migrate embeddings --to ollama:nomic-embed-text:v1.5 --dim 768 --yes` | 9 s | 75,350,542 -> 80,052,746 bytes | 83 % peak utilization, 1331 MiB peak |
| resume after a kill at 12 of 64 pages | 5 s | - | - |
| `reinit-pglite` to the same model and width | 4 s | 72 MB preserved as `pglite.bak`, new index 42 MB | - |
| `bin/fm-gbrain-capture.sh process --force` rebuild of 65 documents | 79 s | 533 chunks, all embedded | - |
| `gbrain import` of a 64-document markdown archive | 34 s | 532 chunks, all embedded | - |

The index grows across a migration to a NARROWER vector: PGLite does not return the space the rebuilt column freed.
Plan for the larger of the two sizes, not the smaller.

Rollback was exercised in both directions.
Restoring the pre-migration copy of `pglite/` together with the pre-migration `embedding_model` and `embedding_dimensions` returned the brain to 64 documents, 532 chunks, and the baseline metrics exactly.
`reinit-pglite`'s automatic `<path>.bak` was present and complete after the reinitialization.

## A reinitialized brain silently loses its reranker and hosted model

`reinit-pglite` clears the brain's own database-plane configuration along with the index:

```console
$ GBRAIN_HOME=$scratch/runtime gbrain config get search.reranker.enabled
Config key not found: search.reranker.enabled
$ GBRAIN_HOME=$scratch/runtime gbrain config get models.think
Config key not found: models.think
```

The rebuilt brain retrieves without reranking and has no hosted synthesis model, and nothing reports this as an error.
The evaluation surfaces it because the run document records the reranker and hosted model as unknown, which is why those fields are read from the brain rather than from Firstmate's configured intent for it.

## Rebuilding from durable source, both ways

Both rebuild paths were exercised from an emptied index, and both reproduced the baseline exactly.

**From the capture outbox.**
This home has no `archive/` directory: its documents were captured directly from outcome manifests and reports, so its durable source is `data/gbrain-outbox/`.
After a `reinit-pglite` left the index empty, `bin/fm-gbrain-capture.sh process --force` re-delivered all 65 stored records in 79 seconds, producing 65 pages and 533 chunks with every chunk embedded, and the rebuilt brain scored 0.95 / 1.00 / 0.975.

The corpus revision moved from `sha256:b29c2dd3...` to `sha256:4c70ba98...` in that run because one extra note had been captured in the interim, and the run document recorded the change rather than presenting the two runs as like-for-like.

**From a markdown archive.**
The same 64 documents were written to a scratch directory laid out as `<archive>/<slug>.md`, so `gbrain import` derives the slugs the captured pages already had.

```console
$ gbrain reinit-pglite --path $scratch/pglite --embedding-model ollama:snowflake-arctic-embed2:568m \
    --embedding-dimensions 1024 --yes --no-sync        # 2 s, index emptied
$ gbrain import $scratch/archive
Import complete (33.9s):
  64 pages imported
  0 pages skipped (0 unchanged, 0 errors)
  532 chunks created
$ gbrain embed --stale
Embedded 0 chunks (0 stale found)
```

`import` embeds as it goes, so the `embed --stale` that follows it is a check rather than a step: it found nothing left to do.
That rebuild also scored 0.95 / 1.00 / 0.975 with `q01` again the only question below rank one, so neither rebuild path loses anything this evaluation can detect.

## Capture during a migration

A capture issued two seconds into a migration completed successfully, and so did the migration:

```console
$ FM_HOME=$scratch bin/fm-gbrain-capture.sh note --id migration-concurrency-probe ...
v1.home-c18f7f1c.note.migration-concurrency-probe captured firstmate/home-c18f7f1c/note/migration-concurrency-probe
$ gbrain stats
Pages:     65
Chunks:    533
Embedded:  533
```

The concurrently captured page was retrievable immediately afterwards and was embedded at the new width, because capture embeds on write at whatever width the configuration then holds.
This was one observation of one interleaving, not a concurrency guarantee: the page was not part of the migration's own plan, and nothing serializes a capture that arrives during the schema rebuild itself.
Quiesce capture for the migration window, as [`../gbrain.md`](../gbrain.md) requires.

## Open finding: the retrieval wrapper re-sorts away GBrain's own ranking

`bin/fm-recall.sh` merges results with `sort_by(-(.score // 0))`, which discards the order GBrain returned even when only one corpus was read.
GBrain does not rank by the score it prints: for `q01` it returns the correct document at position one with score 0.655 while a less relevant document carries 0.811.

Measured over all twenty questions on the same index, comparing GBrain's own order against the same rows re-sorted by score:

```sh
jq -r '.questions[] | [.id, .question, (.expect | tojson)] | @tsv' docs/gbrain-eval-set.v1.json \
| while IFS=$'\t' read -r id q expect; do
    GBRAIN_HOME=$scratch/runtime OLLAMA_BASE_URL=$endpoint \
      gbrain call search "$(jq -cn --arg q "$q" '{query: $q, limit: 8}')" \
    | jq -r --argjson expect "$expect" '
        def hit($s): any($expect[]; . as $e | ($s == $e) or ($s | endswith("/" + $e)));
        def rank($rows): [$rows[] | .slug] as $s
          | ([range(0; ($s | length)) | select(hit($s[.]))] | first);
        "native=\(rank(.))  sorted=\(rank(sort_by(-(.score // 0))))"'
  done | sort | uniq -c
```

```console
     19 native=0  sorted=0
      1 native=0  sorted=1
```

GBrain's own order answers every question at rank one; the wrapper's re-sort demotes `q01` to rank two.
That single re-sort is the entire difference between the 0.95 top-1 recorded above and 1.00, and it is not attributable to the embedding model, the reranker, or the corpus.

The merge order is a deliberate cross-brain contract owned by [`../gbrain-scoping.md`](../gbrain-scoping.md) - a rank there is meant to compare two brains' own scores rather than a Firstmate-computed relevance - so changing it is a change to that contract and was not made here.
The finding is recorded so the decision is taken with the measurement in hand: preserving each source's own order and interleaving only across sources would keep that contract's intent and recover the missing top-1.

## Refreshing this record

```sh
bin/fm-gbrain-eval.sh validate                                   # the set's shape, no brain needed
bin/fm-gbrain-eval.sh run --home <home> --out <run.json>          # the numbers, with their provenance
bin/fm-gbrain-eval.sh compare <baseline.json> <run.json>          # what moved, and whether it is like-for-like
bin/fm-test-run.sh tests/fm-gbrain-eval.test.sh                   # the scoring rules themselves, portable
```

`tests/fm-gbrain-eval.test.sh` pins the scoring rules, the provenance the run document carries, and the exit statuses against stubs, so it runs anywhere and proves nothing about a real corpus.
This record is the other half: it is the real corpus, and it has to be re-measured rather than re-reasoned.

Re-run the evaluation after any corpus, GBrain, embedding, or reranker change, and re-take the migration timings whenever the corpus grows enough that the recorded durations stop being useful for planning.
The two most perishable claims here are the reranker's null effect and the hosted synthesis failure rate: both are properties of a 64-document corpus and one provider's current output behaviour, and either could change without anything in this repository changing.
