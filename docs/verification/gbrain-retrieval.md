# GBrain retrieval through fm-recall.sh

Active empirical evidence for the retrieval guarantees in [`../gbrain-scoping.md`](../gbrain-scoping.md): that a query crosses the GBrain boundary as data rather than as shell input, that hosted synthesis failure is distinguishable from local retrieval failure, and that `fm-recall.sh think` runs only against a home's own brain.
It also records what a search does to the index it reads, which [`../gbrain.md`](../gbrain.md#archive-backup-and-rebuild) owns as a backup precondition.

Verified 2026-08-04 against GBrain `0.42.69.0` at commit `3acd511b80bd4d2fe487290a70de75d4cf094730`, which was the pin recorded in [`../gbrain.md`](../gbrain.md) at the time, except where a section carries its own date.
The pin has since moved, and what that later release changed for a read-only caller is recorded in [gbrain-memory-verbs.md](gbrain-memory-verbs.md) and marked in the `think` section below.

```console
$ gbrain version
gbrain 0.42.69.0
```

## The local read surface returns the operation's own JSON

`gbrain call <tool> '<json>'` is GBrain's trusted local dispatch, so a query crosses as one JSON value inside one argument rather than as text a shell would parse:

```console
$ GBRAIN_HOME=$tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
    gbrain call search '{"query":"canary","limit":3}'
[
  {
    "slug": "probe-canary",
    "title": "Probe Canary",
    "chunk_text": "The fleet uses zzqqxx-canary as its retrieval canary token.",
    "score": 0.8469165016865362,
    "stale": false,
    ...
  }
]
```

A query built with `jq --arg` and passed the same way retrieves normally and executes nothing, with every metacharacter preserved as content:

```console
$ body=$(jq -cn --arg q 'canary"; touch /tmp/PWNED; $(id) `whoami` && rm -rf /nope' \
    --argjson n 3 '{query:$q, limit:$n}')
$ GBRAIN_HOME=$tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
    gbrain call search "$body" | head -3
[
  {
    "slug": "probe-canary",
$ ls /tmp/PWNED
ls: cannot access '/tmp/PWNED': No such file or directory
```

An absent brain refuses on stderr with a non-zero status and writes nothing to stdout, which is what lets a local failure be reported as local:

```console
$ GBRAIN_HOME=$tmp/absent/runtime gbrain call search '{"query":"x"}'; echo "exit=$?"
No brain configured. Run: gbrain init
exit=1
```

## A failed synthesis still exits 0, which is why the flag is read instead

This is the fact `bin/fm-recall.sh` rests on: with no usable model GBrain returns a placeholder answer, an empty citation list, and exit 0, so a wrapper that trusted the exit status would report a non-answer as an answer.

```console
$ GBRAIN_HOME=$tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
    gbrain call think '{"question":"what is the canary token?","rounds":1}'; echo "exit=$?"
{
  "answer": "(no LLM available — set anthropic_api_key via gbrain config or ANTHROPIC_API_KEY env)",
  "citations": [],
  "pagesGathered": 1,
  "modelUsed": "minimax:MiniMax-M3",
  "warnings": ["LLM_OUTPUT_NOT_JSON", "CITATIONS_REGEX_FALLBACK"],
  "synthesisOk": false,
  ...
}
exit=0
```

`pagesGathered: 1` in that same document is the local half reporting that retrieval worked, which is what makes "the hosted provider failed, your own memory did not" a fact rather than an inference.
With the credential supplied to that one process, the same call answers with citations:

```console
$ MINIMAX_API_KEY=<key> GBRAIN_HOME=$tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
    gbrain call think '{"question":"what is the canary token?","rounds":1}' \
  | jq '{synthesisOk, modelUsed, citations}'
{
  "synthesisOk": true,
  "modelUsed": "minimax:MiniMax-M3",
  "citations": [{"page_slug": "probe-canary", "row_num": null, "citation_index": 1}]
}
```

## `think` runs only against a home's own brain, by wrapper construction

`fm-recall.sh think` calls `think` against the home's own brain alone and never over the main brain's read-only client, so the guarantee is construction rather than convention.
That construction is now the whole of it: a server-side scope check used to make the same call impossible, and `v0.42.76.0` retired it by reclassifying `think` as `scope: read`, so a read-scoped client is admitted.
[gbrain-memory-verbs.md](gbrain-memory-verbs.md) measures what a read-only share can and cannot trigger through it on the current pin, and the hosted-synthesis boundary that scope check used to cover is now an operating rule in [`../gbrain.md`](../gbrain.md).

The transcript below is the retired refusal as it stood on 2026-08-04 under `0.42.69.0`, over the real read-only share built by `tests/fm-gbrain-readonly-e2e.test.sh`.
It is kept as the record of what changed, not as current behaviour:

```console
$ curl -sS -X POST http://127.0.0.1:$PORT/mcp -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"think","arguments":{"question":"what is the canary?"}}}'
event: message
data: {"result":{"content":[{"type":"text","text":"{\"error\":\"insufficient_scope\",\"message\":\"Operation think requires 'write' scope\",\"your_scopes\":[\"read\"]}"}],"isError":true},"jsonrpc":"2.0","id":1}
```

A `search` over the same client succeeds on both pins, and the response is an SSE stream whose payload carries the operation's JSON as a string:

```console
$ curl ... -d '{...,"params":{"name":"search","arguments":{"query":"canary","limit":1}}}'
event: message
data: {"result":{"content":[{"type":"text","text":"[\n  {\n    \"slug\": \"main-canary\",\n    \"title\": \"Main Canary\",\n    \"chunk_text\": \"The main brain holds xyzzy-mainbrain-canary.\",\n    \"score\": 0.8379333077938883,\n    ...\n  }\n]"}]},"jsonrpc":"2.0","id":1}
```

Both the SSE framing and the in-band `isError` refusal are unpacked by the wrapper rather than by its renderer, so a refused read degrades one source instead of ending the run.

## A search that succeeds writes the index it read

A search is a writer, which is why [`../gbrain.md`](../gbrain.md#archive-backup-and-rebuild) names it in the backup precondition and why the dashboard's unit grants the brain directory ([dashboard-service-unit.md](dashboard-service-unit.md)).

Measured against the operator's own brain at `/home/sungin/firstmate/data/gbrain`, by taking an md5 of every file under it before and after each `bin/fm-recall.sh search` and diffing the two manifests, excluding the backups directory.
Content hashes rather than mtimes: an mtime probe is too coarse here and had already produced a false negative on this exact question.
Each measurement was bracketed by an idle window with no search running, so the brain was quiescent and the changes below are attributable to the search rather than to a background writer.

The 2026-08-11 measurement recorded three consecutive searches rewriting 26, 27, and 27 files under the PGLite directory, with idle windows of 0 changed files over 30 and 45 seconds, and a run-to-run range of 7 to 27 that was never zero for a search that succeeded.
That measurement was taken when a search meant ONE engine connect, and that premise no longer holds: the per-corpus floor read adds a second `gbrain config get` connect on a search with a judgeable local corpus.
The counts below supersede it.

Re-measured 2026-08-25 against the same brain at pin `v0.46.21.0`, idle window first: 0 files changed over 15 seconds across 1434 files hashed.

`gbrain config get search.autocut_min_top` on its own, three runs, changed 3, 4, and 4 files, always drawn from:

```
pglite/.gbrain-lock/lock
pglite/global/pg_control
pglite/pg_wal/<segment>
pglite/postmaster.pid
```

So the floor read is itself a writer of a handful of PGLite control files, even on this brain, where the key is absent from every plane.

Three consecutive `bin/fm-recall.sh search --json --scope local` runs on the two-connect path, each with the local source `ok`, changed 32, 11, and 8 files, taking 17.02s, 1.18s, and 1.16s of wall clock; all three disclosed the floor as a pinned default.

State this plainly rather than absorbing it.
The second connect adds 3 to 4 control files per search, not a second full search write, so this is not 26 plus 26.
The first two-connect run of the session wrote 32 files, which is above the previously published maximum of 27.
The two runs after it wrote 11 and 8, inside the old 7-to-27 range.
A search is still a writer, the floor read is now a second one, and the backup precondition in [`../gbrain.md`](../gbrain.md#archive-backup-and-rebuild) rests on both.

The same three runs are what sizes the floor read's own ceiling.
With the connect retry ladder disabled and the index lock free, `gbrain config get search.autocut_min_top` took 0.299s, 0.311s, and 0.300s, exiting 1 with `Config key not found: search.autocut_min_top` on stderr.
This fleet has never stored that key in the database plane, so the floor its searches apply is the bundle default 0.35, and disclosing `pinned-default` for this brain is accurate rather than a shrug.
`bin/fm-recall.sh` bounds the read at 1 second, more than three times the measured wall clock and still inside the one-second remainder a dashboard-shaped run tends to leave.

## Refreshing this record

Two suites rebuild the wrapper's claims, and neither asserts anything about the wrapper's source:

- `tests/fm-recall.test.sh` is portable and needs no GBrain installation. A recording stub captures the exact argv and JSON that reached the executable, which is what makes the argument-safety claim provable rather than assertable; it also covers home resolution from each supported task location, the local/hosted failure split, the SSE and refusal parsing, the caps, the per-corpus rerank miss verdict, and the presence-gated read record.
- `tests/fm-gbrain-readonly-e2e.test.sh` is the live proof and drives the wrapper against two real brains and the real read-only share:

```sh
FM_GBRAIN_LIVE_E2E=1 FM_GBRAIN_BIN=<path-to-gbrain> bin/fm-test-run.sh tests/fm-gbrain-readonly-e2e.test.sh
```

Re-run both after any GBrain upgrade.
The index-write measurement has no suite behind it: redo it by hand as described there, and redo it in particular if a future version claims to open the index read-only, because the backup precondition it supports would change with it.
The synthesis-flag observation above is the one most worth re-confirming: if a future version starts exiting non-zero when it has no model, the wrapper's verdict stays correct, but a version that stops emitting `synthesisOk` would need this record and `bin/fm-recall.sh` revisited together.

## `rerank_score` is the miss signal the wrapper used to drop, and it is judged per corpus

This section separates two kinds of claim, because they need different evidence.
Claims about what GBrain does are read from the installed pin `v0.46.21.0`, which [../gbrain.md](../gbrain.md) records as the installed release, and each one names the file it was read from.
Claims about what `bin/fm-recall.sh` does with what GBrain returns are wrapper contract, rebuilt by the portable suite `tests/fm-recall.test.sh` on 2026-08-25.
That suite is stub-driven, so it proves the wrapper's behavior and proves nothing about what a live GBrain stamps.
The only live measurement of search-row fields in this repo is [gbrain-memory-verbs.md](gbrain-memory-verbs.md) (2026-08-20); `tests/fm-gbrain-readonly-e2e.test.sh` drives real brains but asserts on the read-only share, scoped refusals, context packs, and delta cursors, and never inspects these fields, so it is not cited for them.

Why the printed blend cannot answer the miss question is measured live in [gbrain-memory-verbs.md](gbrain-memory-verbs.md), and is not restated here.
That record ran `gbrain call search` against the real corpus with an off-corpus nonsense query and measured `score` at roughly 0.78 to 0.81 while `rerank_score` on the same rows ran from about 0.00008 to 0.0037.
It records `score`, `rerank_score`, `evidence`, and `create_safety`; it records nothing about `cosine` and nothing about autocut, so neither is cited to it.

None of the four surfaced fields is guaranteed on every row, and the wrapper is written for that.
At the pin, `src/core/types.ts` declares `cosine?`, `rerank_score?`, `evidence?`, and `create_safety?` all optional.
`cosine` is documented there as absent on keyword-only and no-embedding paths, and `rerank_score` as undefined when no reranker fired and stamped only on the reranked head.
`cosine` has no live measurement anywhere in this repo and is surfaced unverified.
`bin/fm-recall.sh` copies each of the four onto the `fm-recall.v1` document when the retrieval path produced it and carries null when it did not.

The floor is GBrain's own `search.autocut_min_top`, not a Firstmate-invented threshold.
The bundle default is `DEFAULT_AUTOCUT.minTopScore = 0.35` in GBrain's own `src/core/search/autocut.ts` at the pin, and `src/core/search/mode.ts` accepts an operator value in [0, 1] over it.

Which plane holds the floor a search actually applied was checked at the pin, because two planes disagree and only one of them is the answer.
`gbrain config get` prefers the file/env plane over the database plane and prints which one answered on stderr (`src/commands/config.ts`).
Search does not share that order: `loadSearchModeConfig` resolves every search knob through `engine.getConfig` alone (`src/core/search/mode.ts`), and `PGliteEngine.getConfig` is a read of the database `config` table (`src/core/pglite-engine.ts`).
`autocutFromConfig` in `src/core/search/autocut.ts` is the only function at the pin that reads the nested file-plane shape, and nothing in `src` calls it.
`gbrain config set search.autocut_min_top` falls through to `engine.setConfig`, so the supported way to tune the knob writes the database plane; only `push.allow_unverified_remote` and `hooks.stop_push_debounce_min` are routed to the file plane.
A floor found in the configuration file is therefore a value this host can see, not a value the running search applied, and the wrapper does not judge against it.

The search reply cannot be asked for the floor instead.
`gbrain call search` returns a JSON array of result rows, which is what `reply_shape_ok` requires, and it carries no search metadata.
The autocut verdict travels on `SearchMeta` for `--explain` and capture rather than on that array, and `AutocutDecision` at the pin is only `{applied, signal, cut, kept, total, gapRatio}`, which names neither the floor nor whether the weak-top branch fired: that branch returns the same no-op as a list with no cliff.

So `bin/fm-recall.sh` reads the database plane through `gbrain config get` and accepts the number only when stderr reports that the database plane answered, treating a file/env answer as no answer at all.
That read is an engine connect, so it is fenced three ways: it is taken lazily and only for a corpus whose rows carry a `rerank_score` and can therefore be judged, it is bounded by a short slice of what is left of the budget `--timeout` granted with the runner's kill grace reserved out of that remainder so the run's real ceiling stays at the deadline rather than one grace past it, and it runs with GBrain's connect retry ladder disabled so a home whose daemon holds the index lock fails fast instead of spending seconds to arrive at the same fallback.
Anything short of a database answer inside that slice is the pinned default, and which of two facts that is gets disclosed rather than blurred.
A brain that answered and holds no usable value of its own really does apply the pinned default, and that reads as `pinned-default`.
A brain that could not be asked - the budget did not fit, the read was killed, the index lock was held, the binary is missing - applies whatever it applies, and that reads as `unconfirmed-default` instead, because this host does not know.
The notice attributes that gap to the read rather than to the brain, because a corpus only carries a floor at all when it returned rows and was judged, so the brain was searched and it is the floor plane that went unread.
The main brain is read over MCP and has no database plane this host can query at all, so its floor is always `unconfirmed-default` rather than this home's value borrowed across.
A value GBrain would itself refuse falls through to the bundle default inside GBrain too, so an out-of-range database answer is a confirmed `pinned-default` rather than an unknown one.

`bin/fm-recall.sh` judges confidence per corpus rather than from the head of the merged list.
Each corpus's own pool of returned rows is judged against that corpus's own floor, which is the quantity GBrain applies the knob to, and a corpus clears when its own top `rerank_score` is a number that is not below its floor.
Judging the merged list's head instead would let whichever corpus led the merge decide the other's verdict, and the merge puts this home's own index first on an equal rank, so a confident fleet answer at merged position 2 would be announced as `No confident match`.
Taking the maximum across the merged list would be wrong in the other direction, because two brains' rerank scores are different quantities and are not comparable with each other.
`answer.no_confident_match` is true only when no corpus cleared, and when one did, `answer.confident_corpora` names which, so a caller can tell local knowledge from fleet knowledge.
A corpus whose rows carry no `rerank_score` at all is left unjudged rather than counted a miss, and it is named as unjudged rather than folded into a sentence about a floor it was never measured against.
`answer.corpora` carries each corpus's own top score, whether it was judged, and whether it cleared, while `answer.floors` is the single owner of the floor and its provenance and carries a row only for the corpora that were actually judged.
When one corpus clears and another was judged and fell short, the notice names the one that fell short, because a consumer that renders only `kind` and `notice` would otherwise learn which brain holds the answer without learning which one does not.
`create_safety` is printed and is not the miss bit.

A home whose local index directory exists appends one JSON line to `state/recall.jsonl` for each search; a home with no local index writes nothing.
The line carries the query, the disposition of the read, each corpus's own top score in `corpus_tops`, and whether that miss verdict was given.
`rank1_rerank_score` is the head of the merged list and is named with the `rank1_corpus` it came from, because on a two-corpus read that row can belong to a corpus the verdict is not about.
The disposition separates `unread`, `unjudged`, `miss`, and `hit`, so a run that never reached a corpus cannot serialize as a read that returned an unjudgeable top row.
The file is home-wide and size-capped at 262144 bytes, overridable with `FM_RECALL_JSONL_MAX_BYTES`.
The append and the trim that follows it run under one advisory lock, because concurrent searches against one home would otherwise let a trim built from a stale tail overwrite the newest lines the cap exists to keep.
That lock is the directory `state/recall.jsonl.lock` beside the log, a stale hold left by a killed run is claimed by an atomic rename so only one sweeper can remove it and is swept by age on the next search after 30 seconds, and the wait for it is bounded by whichever comes first of a short ceiling or the run's own remaining budget, because the record is best-effort and must never be why a caller's kill deadline fires.
Past the cap the oldest lines go and the newest tail stays, a record larger than the cap on its own is kept rather than dropped, and the file is always safe to delete or trim.
The trim selects whole lines from the newest end until the cap is reached rather than cutting on a byte offset, because a record of this shape carries interior braces of its own and no leading-character test can tell a cut fragment from a whole line.

```sh
bin/fm-test-run.sh tests/fm-recall.test.sh
```
