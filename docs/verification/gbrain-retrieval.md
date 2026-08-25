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

Measured 2026-08-11 against the operator's own brain at `/home/sungin/firstmate/data/gbrain`, by taking an md5 of every file under it before and after each `bin/fm-recall.sh search` and diffing the two manifests.
Content hashes rather than mtimes: an mtime probe is too coarse here and had already produced a false negative on this exact question.
Each measurement was bracketed by an idle window with no search running, which reported 0 changed files over 30 seconds and again over 45 seconds, so the brain was quiescent and the changes below are attributable to the search rather than to a background writer.

Three consecutive searches, each returning results with the local source `ok`, rewrote 26, 27, and 27 files under the PGLite directory:

```
pglite/global/pg_control
pglite/pg_wal/<segment>
pglite/pg_xact/0000
pglite/base/5/<relation files>
```

Three in a row make this steady state rather than a cold-start or first-open artifact, and it is not an artifact of the service sandbox either: it happens both under the dashboard unit's restrictions and in an ordinary shell.
Counts vary run to run, 7 to 27 observed, but were never zero for a search that actually succeeded.

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

Verified 2026-08-25 against the portable suite `tests/fm-recall.test.sh`.
Live corpus measurements that show why the printed blend cannot answer the miss question remain in [gbrain-memory-verbs.md](gbrain-memory-verbs.md) (2026-08-20) and are not restated here; that record measures `score` at roughly 0.78 to 0.81 while `rerank_score` on the same rows runs from about 0.00008 to 0.0037.
It records nothing about autocut, so the floor's provenance is cited separately below rather than borrowed from it.

The floor is GBrain's own `search.autocut_min_top`, not a Firstmate-invented threshold.
GBrain resolves that knob per-call, then from the brain's configuration, then from its bundle default, so the only honest value is the one the brain being read would itself use.
`bin/fm-recall.sh` therefore reads the effective value from each brain's own configuration plane through the same bounded `gbrain config get` path `bin/fm-gbrain-eval.sh` reads its own knobs through.
The bundle default is `DEFAULT_AUTOCUT.minTopScore = 0.35` in GBrain's own `src/core/search/autocut.ts` at the pinned release `v0.46.21.0`, which [../gbrain.md](../gbrain.md) records as the installed release.
The wrapper falls back to that pinned default only when a plane cannot be read at all - no binary, no key, a non-numeric value, or a timeout - and it discloses on every answer which floor each corpus was judged against and whether that value came from configuration or from the fallback.
The main brain is read over MCP and has no configuration plane this host can query, so it borrows this home's readable value when there is one and the pinned default otherwise, disclosed the same way.

GBrain already returns `rerank_score`, `cosine`, `evidence`, and `create_safety` on every search row.
`bin/fm-recall.sh` now copies those fields onto the `fm-recall.v1` document and judges confidence per corpus rather than from the head of the merged list.
Each corpus's own pool of returned rows is judged against that corpus's own floor, which is the quantity GBrain applies the knob to, and a corpus clears when its own top `rerank_score` is a number that is not below its floor.
Judging the merged list's head instead would let whichever corpus led the merge decide the other's verdict, and the merge puts this home's own index first on an equal rank, so a confident fleet answer at merged position 2 would be announced as `No confident match`.
Taking the maximum across the merged list would be wrong in the other direction, because two brains' rerank scores are different quantities and are not comparable with each other.
`answer.no_confident_match` is true only when no corpus cleared, and when one did, `answer.confident_corpora` names which, so a caller can tell local knowledge from fleet knowledge.
A corpus whose rows carry no `rerank_score` at all is left unjudged rather than counted a miss.
`create_safety` is printed and is not the miss bit.

A home whose local index directory exists appends one JSON line to `state/recall.jsonl` for each search, carrying the query, the disposition of the read, the rank-1 rerank score, and whether that miss verdict was given; a home with no local index writes nothing.
The disposition separates `unread`, `unjudged`, `miss`, and `hit`, so a run that never reached a corpus cannot serialize as a read that returned an unjudgeable top row.
The file is home-wide and size-capped at 262144 bytes, overridable with `FM_RECALL_JSONL_MAX_BYTES`; past the cap the oldest lines go and the newest tail stays, so it is always safe to delete or trim.

```sh
bin/fm-test-run.sh tests/fm-recall.test.sh
```
