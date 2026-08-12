# GBrain retrieval quality and the embedding-migration playbook

Active empirical evidence for the evaluation and migration procedure in [`../gbrain.md`](../gbrain.md): the measured retrieval and synthesis quality of a real Firstmate home brain, the measured effect of the retrieval wrapper's own result ordering before and after it was corrected, and the recorded behaviour of the embedding migration, its rollback, its interruption, and the rebuild from durable source.

Measured 2026-08-05 against GBrain `0.42.69.0` at commit `3acd511b80bd4d2fe487290a70de75d4cf094730`, which was the pin recorded in [`../gbrain.md`](../gbrain.md) at the time.
The pin has since moved, and [gbrain-memory-verbs.md](gbrain-memory-verbs.md) records the retrieval measurements taken either side of that move.
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
| Evaluation set | `fleet-history` v1, `sha256:51238ce03cbe265ce6d797575a60b4502dba03efe1661122c733d4c7d4f3985f`, the twenty-question version those runs were taken against |

That 64-document corpus was the home's own captured task knowledge: 63 completed tasks composed from their durable outcome manifests and scout reports, plus one note.
Sixteen of those documents were manifest-only ship records whose entire body was a title, an outcome line, and a pull-request URL, so the runs below measured retrieval over both long reports and near-empty records.
That is the composition those runs were taken against rather than a description of the live corpus, which has since grown; what it holds now is recorded with the post-fix runs below.

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

Every think rate above is over the questions that reached hosted synthesis, which in this run was all twenty of them.
All 20 calls returned a synthesis block: eighteen exited 0, and the two that exited 4 did so because GBrain set `synthesisOk: false` on an answer it had already produced, not because `bin/fm-recall.sh` refused before reaching the provider.
None exited 3, the local side, so the harness's later correction to exclude a question that never reached hosted synthesis from the synthesis rates leaves every number in this record unchanged.
That correction is why a run document now reports `think.read` alongside `think.questions`, and it changes nothing about the missed threshold discussed below: the two failures were hosted refusals of a successful local read, not corpora that could not be read.

Retrieval clears its thresholds with a wide margin: every question retrieved an expected source within the first five results, and only `q01` placed it below rank one, at rank two.
That single demotion is not the brain's: it was produced by the retrieval wrapper's own score re-sort, measured below and since replaced.
Hosted synthesis misses its threshold, and the next section establishes why and by how much.

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

**The remaining gap is explicit**: at the shipped one-call setting the home answered 75 to 90 percent of synthesis questions across the three runs above, against a 95 percent threshold, and the shortfall is entirely the hosted provider's output format on long answers.
No embedding or reranker change addresses it, because retrieval already succeeds on every one of those questions - `q03` and `q17` both retrieved their expected source at rank one in the same run.
A different embedding artifact was nevertheless measured, below, because the migration playbook had to be exercised end to end.

## The hosted-synthesis numbers have not been independently reproduced

The two halves of this record do not carry the same weight of evidence, and the gap is wide enough that a reader should not average over it.

**The replication asymmetry.**
The retrieval half was independently reproduced by a separate verification pass at top-1 0.95 / top-5 1.00 / MRR 0.975, using the then-shipped evaluation set unchanged, the twenty-question v1, on a live corpus that had since grown to 65 documents under a new revision hash, not the 64-document revision the baseline above was recorded against.
The hosted-synthesis half was measured only by the worker that implemented this harness, from its own runs, and nobody has re-run it since.
That is the weak case, and it should be read as one: an implementer confirming its own work is weaker evidence than an independent reproduction, so the four hosted numbers deserve less confidence than the retrieval numbers printed beside them.

**The run-to-run spread is the reason it matters.**
Across three separate runs of the same twenty questions against the same home, first-call synthesis answered 15, 17, and 18 of 20.
The baseline above is the 18-of-20 run, which is what makes answered 0.90, and allowing one retry reached 0.95 answered with 0.85 on the first call.
So 0.90 is one draw from a spread of roughly 0.75 to 0.90, not a stable figure that a re-run would be expected to land on again.

**What closing the gap costs.**
An independent reproduction against the current evaluation set is roughly 40 paid outbound calls to the hosted provider, each carrying excerpts of this home's captured cross-project knowledge off the host.
That count is derived rather than measured: the set holds forty questions and the harness makes one synthesis call per question at the shipped `--think-attempts 1`, so it doubled when the set was widened to forty and not because any single call became more expensive.
That export is a named privacy boundary of this repository, which is why authorizing it is the repository owner's decision rather than an agent's, and why the gap is recorded here instead of quietly measured away.
The command is `bin/fm-gbrain-eval.sh run --home <home> --phase think --out think.json`, which scores the synthesis half alone and leaves the retrieval metrics above untouched.
Unqualified it runs the default set, so it measures the current forty questions rather than the twenty the numbers above were taken against.
Reproducing those recorded numbers like-for-like needs `--set` pointing at the twenty-question v1 set, whose bytes survive only in git history because the file name was deliberately kept: recover it with `git show efe56f4:docs/gbrain-eval-set.v1.json`, and it hashes to the `sha256:51238ce0...` named in the configuration table above.

**What this limitation does not reach.**
It is scoped to the hosted-synthesis metrics alone: think answered, think grounded, think key facts, and think citation precision.
The retrieval numbers, the migration and rebuild timings, the wrapper re-sort result, the reranker finding, and every other measurement in this document were taken locally and are unaffected by it.

## The retrieval wrapper re-sorted away GBrain's own ranking

This is a measured result of the baseline run, not an aside: it is where the missing top-1 above went.
It records the wrapper as it behaved when the baseline was taken; the next section is the correction and its own before-and-after measurement.

The wrapper then merged results with `sort_by(-(.score // 0))`, which discards the order GBrain returned even when only one corpus was read.
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

The set path in that snippet then held the twenty-question v1 set, recoverable from git history as above; against the forty-question set shipped today it reads forty rows instead.

| Ordering | top-1 |
| --- | --- |
| GBrain's own order | 20 / 20 |
| `bin/fm-recall.sh` score re-sort | 19 / 20 |

The one question the re-sort loses is `q01`, "Why did the ArkNode NVMe controller wedge a third time, and what was actually writing to the drive?", whose correct source `task/arknode-nvme-wedge-third-occurrence` is demoted from rank one to rank two.
That demotion is the entire difference between the 0.95 top-1 recorded above and 1.00, and it is not attributable to the embedding model, the reranker, or the corpus: the same index, read in GBrain's own order, answers every question at rank one.

**The mechanism is established; the magnitude is not.**
One question on one 64-document corpus at one point in time is enough to show that the wrapper overrides an ordering that was better here, and it sizes nothing.
A single case cannot say whether the re-sort costs one question in twenty generally, more, or almost nothing on a different corpus, and this record should not be read as if it had measured that.

The section below is the fix for that defect and its measurement, so the numbers above remain the pre-fix record they were taken as.

## The wrapper now preserves each corpus's own ranking

[Issue 49](https://github.com/HelloWorldSungin/firstmate/issues/49) replaced the score sort with a rank merge: each corpus keeps the order it returned, and two corpora are interleaved by rank rather than compared on a score column that is a different quantity in each brain.
The merge contract is owned by [`../gbrain-scoping.md`](../gbrain-scoping.md), which describes the rank merge rather than the superseded score sort.

The evaluation set was widened from twenty questions to forty for this measurement, so the one-question effect above could be sized against a wider set rather than only re-detected.
The two runs below - `score re-sort (pre-fix), set v2` and `rank merge (post-fix), set v2` - were both measured against `fleet-history` **v2**, `sha256:8246d22fefc1d1abc3ea1430357758db7655de3fb2b44eb970017d41e11f3e38`, on a live corpus that had grown to 78 documents, 547 chunks, revision `sha256:66a3805ea001e62fc3d658f3e97a47fd01827f0b23a6f0f5ba9c034d98043e6f`, with the GBrain version, embedding model, reranker, and query settings unchanged from the configuration table above.
That corpus is 73 completed tasks and 5 notes, 30 of them manifest-only ship records, so the widened set still measures retrieval over both long reports and near-empty records.
The baseline run drives the pre-fix wrapper through the harness's own `FM_RECALL_BIN`, so both runs are the same harness reading the same index and differ only in the wrapper's merge:

```console
$ FM_RECALL_BIN=$scratch/oldbin/fm-recall.sh bin/fm-gbrain-eval.sh run \
    --home /home/sungin/firstmate --phase search \
    --label 'score re-sort (pre-fix), set v2' --out v2-before.json
$ bin/fm-gbrain-eval.sh run --home /home/sungin/firstmate --phase search \
    --label 'rank merge (post-fix), set v2' --out v2-after.json
$ bin/fm-gbrain-eval.sh compare v2-before.json v2-after.json
LIKE-FOR-LIKE
  same     eval_set
  same     corpus
  same     gbrain
  same     embedding
  same     reranker
  same     think_model
  same     query

METRICS
  search_top1  92.5% -> 97.5%  (+5%)
  search_topk  100% -> 100%  (0%)
  search_mrr  96.3% -> 98.8%  (+2.5%)
```

| Ordering | top-1 | top-5 | MRR | below rank one |
| --- | --- | --- | --- | --- |
| score re-sort (pre-fix) | 0.925 | 1.00 | 0.9625 | `q01`, `q26`, `q35` |
| rank merge (post-fix) | 0.975 | 1.00 | 0.9875 | `q26` |

So on forty questions the re-sort demoted three, and the fix recovers two of them.
`q26` is demoted by GBrain itself and not by the wrapper: read in the brain's own order its expected source `task/arknode-backfill-services-audit` still sits at rank two behind `task/arknode-nvme-wedge-third-occurrence`, which is a related report on the same outage.
That is the honest boundary of this change - it stops the wrapper from overriding the brain's ranking, and it does not improve the brain's ranking.

The magnitude is now measured on this corpus rather than only detected: three questions in forty, all recoverable ones recovered, on a 78-document corpus at one point in time.
It remains a statement about this corpus and this question set, not a general claim about how much a score re-sort costs elsewhere.

The regression that pins the behavior is `tests/fm-recall.test.sh`, which asserts that a single corpus comes back in exactly the order the brain returned and that two corpora interleave by rank with fixture scores built so a score sort would produce a different list.

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
Three claims here are the most perishable, and all three are properties of one corpus at one point in time and one provider's current behaviour rather than of this repository: the reranker's null effect, the hosted synthesis failure rate, and the size of what the wrapper's score re-sort cost before it was replaced.
Any of them can change without anything here changing.
The first two still rest on the 64-document corpus and the twenty-question set; the third was re-measured on forty questions and 78 documents when the re-sort was replaced, and stays a statement about that corpus rather than a general one.
