# GBrain memory verbs and pin upgrades: measured behaviour

Dated empirical evidence for what pinned GBrain releases provide to Firstmate's captured corpus, and for the upgrades that installed them.
It exists because release notes can read as though they retire several of the capture guarantees Firstmate still owns, and the measurements below show which of those readings survive contact with the binary.
The installation and upgrade procedure itself is owned by [`../gbrain.md`](../gbrain.md); the delivery-side receipt proof is owned by [gbrain-capture.md](gbrain-capture.md); the standalone retrieval and synthesis quality baseline and the embedding-migration numbers are owned by [gbrain-eval.md](gbrain-eval.md), while the runs taken either side of a pin move stay here.

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

## The 2026-08-13 upgrade to `v0.45.9.0`

The live source installation moved from `v0.45.0.0` at `d35c9c9e441e6cfc86dd5e84b0b168c6b18ee775` to `v0.45.9.0` at `1ec6a6e842a15f2bde2ebe8c3a686a6fa6b17aa5` with Bun `1.3.14`.
The upgrade used the existing source checkout and pinned Bun path, and the pre-upgrade copy retained the PGLite index, runtime configuration, and capture outbox together.
No archive existed for this home, so its outbox remained the durable document source.

The installed runtime and schema reported:

```text
$ git -C /home/sungin/.local/gbrain/src rev-parse HEAD
1ec6a6e842a15f2bde2ebe8c3a686a6fa6b17aa5
$ /home/sungin/.local/gbrain/bin/gbrain --version
gbrain 0.45.9.0
$ /home/sungin/.local/gbrain/bin/bun --version
1.3.14
connection                  ok  Connected, 197 pages
schema_version              ok  Version 126 (latest: 126)
embeddings                  ok  100% coverage, 0 missing
embedding_provider          ok  ollama:snowflake-arctic-embed2:568m, 1024 dims, DB aligned
embedding_width_consistency ok  Schema width (1024d) matches gateway embedding_dimensions
reranker_health             ok  No rerank failures in last 7 days
```

The explicit `apply-migrations --yes --non-interactive --no-autopilot-install` command first reported `All migrations up to date`.
The immediately following `doctor --json` invocation detected schema 125, applied only migration 126 for `session_context_state`, and then reported schema 126 current.
No reindex, re-embedding, bootstrap, or autopilot installation ran.

The release evaluation itself had been captured after its 199-record intake snapshot, so the live baseline was already 200 archived records before this upgrade began.
The four capture counts were identical before and after the upgrade:

```text
archived   200
pending    0
failed     0
unreadable 0
```

Local recall after the upgrade returned the known evaluation record as a scored first result:

```text
local:firstmate/firstmate-bc8432f7/task/fm-gbrain-release-evaluation  score=0.8827
```

The new zero-LLM boundary retrieval commands both ran against the live corpus.
A known-record `context-pack` call returned one card within its budget:

```json
{"protocol_version":1,"cards":1,"budget_tokens":1000,"budget_used":33,"dropped_count":0,"degraded_reason":null}
```

A stateless `delta` call returned the six pages changed since `2026-08-13T00:00:00Z` and an advancing keyset:

```json
{"protocol_version":1,"pages":6,"has_more":false,"next_cursor":{"since":"2026-08-13T03:40:03.840Z","slug":"firstmate/firstmate-bc8432f7/task/fm-gbrain-release-evaluation"},"budget_tokens":1000,"budget_used":241,"dropped_count":0}
```

The source release's disposable PGLite MCP test independently exercised `context_pack`, stateless `delta`, and two session-cursor calls that did not redeliver the page.
It completed with `8 pass`, `0 fail`, and `50 expect() calls`.

The forty-question local retrieval evaluation was like-for-like across the pin move:

```text
search_top1  92.5% -> 92.5%  (0%)
search_topk  95% -> 95%  (0%)
search_mrr   93.8% -> 93.8%  (0%)
```

The corpus stayed at 197 active documents, 993 chunks, 993 embedded chunks, and revision `sha256:b83b7f2663be04dd7383b91e83d4b1bacaed313560bdec0f6df5d06f8024c027` for both runs.
The local wrapper suite completed with every case passing.
The opt-in real read-only sharing suite also completed with every case passing, including refusal of every remote write, credential-free degradation of remote synthesis, unchanged served pages, and no leaked client secret.
The same suite used only disposable brains and two distinct disposable read-scoped OAuth clients to verify the new remote privacy and cursor guarantees through the public HTTP MCP interface.
It requested `context_pack` with `include_private=true` after seeding world and private commitment sentinels, and the remote response retained the world sentinel in both fact-bearing arms while omitting the private sentinel everywhere.
It established the same `session_id` independently for both OAuth clients, created a new page through a separate write-scoped HTTP MCP client, and then showed that each read client received the page once even though client one advanced before client two read it.
The exact command and relevant observed output were:

```text
$ mkdir -p .review-tmp
$ TMPDIR=$PWD/.review-tmp FM_GBRAIN_LIVE_E2E=1 FM_GBRAIN_BIN=/home/sungin/.local/gbrain/bin/gbrain tests/fm-gbrain-readonly-e2e.test.sh
observed remote context_pack: {"include_private_requested":true,"cards":["main-canary"],"facts":["WORLD-CONTEXT-PACK-SENTINEL is visible remotely."],"open_threads":["WORLD-CONTEXT-PACK-SENTINEL is visible remotely."],"private_present":false}
ok - remote context_pack stays world-only when include_private is requested
observed remote delta cursors: {"session_id":"fm-shared-delta-session","client_one_after_write":["isolated-delta-canary"],"client_two_after_client_one":["isolated-delta-canary"],"client_one_followup":[],"client_two_followup":[]}
ok - distinct OAuth clients keep isolated cursors for one delta session id
all fm-gbrain-readonly-e2e tests passed
```

No hosted synthesis was invoked against the live corpus during the upgrade.
The rule and authorization boundary remain owned by [`../gbrain.md`](../gbrain.md), while the new boundary verbs completed locally without a hosted-provider call.
No `dream.<phase>.enabled` or `cycle.<phase>.enabled` key was configured for any phase, and no dream or autopilot process, unit, timer, or cron entry existed after the migration.
The only GBrain units remained the local embedding and reranker services, and the runtime integration hooks directory contained no hook file.
Dreaming therefore remained disabled, and the upgrade added no scheduler, persistence hook, or outbound data path.

The `mounts --mcp-url` implementation remained absent at the pinned source commit.
The current source still labels HTTP MCP mounts and OAuth as not yet shipped, so [`../gbrain-scoping.md`](../gbrain-scoping.md) required no correction.

## The 2026-08-19 upgrade to `v0.46.21.0`

The live source installation moved from `v0.45.9.0` at `1ec6a6e842a15f2bde2ebe8c3a686a6fa6b17aa5` to `v0.46.21.0` at `649ffe5f8baf3ff7f979c77f4de3975904cfe029`, backed up first to `data/gbrain/backups/20260819T045704Z`.
Firstmate ran the evaluation either side of that move and supplied the numbers below from its own run artifacts.
Those artifacts are `baseline-0.45.9.0.json`, `baseline-run.log`, `after-0.46.21.0.json`, `after-run.log`, and `rollback.md` under `/home/sungin/firstmate/data/gbrain-upgrade-2026-08-19/`, which is in the home's gitignored `data/` and therefore unreachable from a checkout of this repository.
This entry is consequently the durable copy of the observation rather than a pointer to one, so it carries its provenance inline.

The baseline run on `v0.45.9.0`, labelled `pre-0.46.21.0`, started `2026-08-19T04:34:25Z` and finished `2026-08-19T04:56:38Z`.
The post-upgrade run on `v0.46.21.0`, labelled `post-0.46.21.0`, started `2026-08-19T04:59:32Z` and finished `2026-08-19T05:19:36Z`.
Both asked the same forty questions at `top_k` 5 against `brain_root /home/sungin/firstmate/data/gbrain`, the brain that home resolves rather than the second deployment tree under `~/.local/share/gbrain`.

Everything a like-for-like comparison has to hold fixed was identical in the two runs:

| Field | Both runs |
| --- | --- |
| Evaluation set | `fleet-history` v2, `docs/gbrain-eval-set.v1.json`, `sha256:8246d22fefc1d1abc3ea1430357758db7655de3fb2b44eb970017d41e11f3e38` |
| Corpus | 257 documents, 1146 chunks, 1146 embedded, revision `sha256:fa060f67f9a1ece0e4ea62fc8504ffcb6b298b5b6dbe866e18fc606d7858811d` |
| Embedding | `ollama:snowflake-arctic-embed2:568m`, 1024 dimensions |
| Reranker | `llama-server-reranker:qwen3-reranker-0.6b-q8_0`, enabled |
| Engine | `pglite`, schema pack `gbrain-base-v2` |

Retrieval did not move across the pin:

| Metric | `0.45.9.0` | `0.46.21.0` |
| --- | --- | --- |
| search top-1 | 0.925 | 0.925 |
| search top-5 | 0.95 | 0.95 |
| search MRR | 0.9375 | 0.9375 |

That agreement is question by question rather than only in aggregate: the same two questions missed in both runs, `q24` and `q35`, and the same one fell to rank two, `q26`.

Synthesis did move, so the upgrade is like-for-like on retrieval alone and nothing here supports a wider claim:

| Metric | `0.45.9.0` | `0.46.21.0` |
| --- | --- | --- |
| think answered | 0.8205 over 39 scored | 0.80 over 40 scored |
| think grounded | 0.9375 | 0.96875 |
| think key facts | 0.78125 | 0.734375 |
| think citation precision | 0.5154 | 0.5289 |
| Unread questions | `q39`, `local_retrieval_failed` | none |

Two facts make those numbers readable.
The scored counts differ because the baseline failed local retrieval on `q39` and scored 39 questions, while the post-upgrade run read all 40.
The 0.95 `think_answered` threshold was missed in both runs, so that miss predates this upgrade rather than being a regression it introduced.
Unlike the disposable-brain probes elsewhere in this file, the synthesis half of both runs read the live corpus through the configured hosted model, which is the export boundary [`../gbrain.md`](../gbrain.md) owns.

## The 2026-08-20 re-measurement against `v0.46.21.0`

Measured 2026-08-20 against `gbrain 0.46.21.0` at commit `649ffe5f8baf3ff7f979c77f4de3975904cfe029`, with Bun `1.3.14`.
Read-only probes ran against this home's brain at the paths `bin/fm-gbrain.sh paths` resolves.
Probes that had to write ran against a disposable PGLite brain under `.probe-tmp` inside this worktree; that directory was removed after the probes, and `.probe-tmp/` is in `.gitignore` so an interrupted re-measurement cannot leave a brain database staged for commit.
`core/config.ts` rejects a relative `GBRAIN_HOME`, so every disposable-brain command below passes it as `$PWD/.probe-tmp/runtime` and is run from the repository root.

The installed version and commit:

```text
$ /home/sungin/.local/gbrain/bin/gbrain --version
gbrain 0.46.21.0
$ git -C /home/sungin/.local/gbrain/src rev-parse HEAD
649ffe5f8baf3ff7f979c77f4de3975904cfe029
$ /home/sungin/.local/gbrain/bin/bun --version
1.3.14
```

This home's brain paths:

```text
$ FM_HOME=/home/sungin/firstmate bin/fm-gbrain.sh paths
brain_root  /home/sungin/firstmate/data/gbrain
gbrain_home /home/sungin/firstmate/data/gbrain/runtime
pglite      /home/sungin/firstmate/data/gbrain/pglite
archive     /home/sungin/firstmate/data/gbrain/archive
```

The disposable brain was created for this entry and used for every probe that writes:

```text
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain init --pglite --non-interactive \
  --path "$PWD/.probe-tmp/pglite" --embedding-model ollama:snowflake-arctic-embed2:568m \
  --embedding-dimensions 1024 2>&1 | grep -E 'PGLite|Embedding:|schema|migration'
Setting up local brain with PGLite (no server needed)...
  Embedding: ollama:snowflake-arctic-embed2:568m (1024d)
  Setting up brain schema (v132)...
  127 migration(s) applied
[init] Using schema pack: gbrain-base-v2 (override with --schema-pack <name>)
0 pages. Engine: PGLite (local Postgres).
```

Its probes ran as one session in this order: the two captures, the `remember` calls, then the `recall` reads.
The sections below group them by the table row they answer rather than by that order, so a `recall` transcript can show facts a later section records creating.

Two prior scouts already established the shape of this install: `data/fm-gbrain-usage-correctness-research/report.md` and `data/fm-gbrain-release-and-unused-features/report.md`.
Both sit in the home's gitignored `data/` tree and are unreachable from a checkout of this repository, so every claim below that leans on them also carries its own transcript here, and this entry stays the durable copy of the observation.
This entry does not re-measure what those reports already measured; it refreshes the closing table with live probes for each claim.

### What this leaves to Firstmate after `v0.46.21.0`

| Capture guarantee | State after `v0.46.21.0` |
| --- | --- |
| Audit and health that fail on outbox-to-index divergence | Firstmate's. Nothing native compares the two inventories. |
| Capturing corrections and current facts, not only pruned text | Storage primitives are native through `remember` and same-slug recapture; every trigger is Firstmate's. |
| Verified delivery and bounded retry drain | Firstmate's, and the receipt still carries the postconditions the wrapper does not read. |
| Provenance, validity, supersession | Native for facts under the 0.95 near-duplicate rule; absent for pages, which are the whole captured corpus. |
| Answer protocol over a retrieval miss | Firstmate's. Nothing native addresses it, and a nonsense query still returns a populated list. |
| Evaluation gates for integrity and currency | Firstmate's. `eval brainbench` grades harness memory conformance over its own fixtures, not this corpus. |
| Explicit truncation of an over-cap body | Firstmate's. `recall`'s `dropped_count` is read-time packing, a different mechanism. |

#### Audit and health that fail on outbox-to-index divergence

Outbox and active-index counts still disagree on this home:

```text
$ FM_HOME=/home/sungin/firstmate bin/fm-gbrain-capture.sh status | head -n 5
archived   273
pending    0
failed     0
unreadable 0
redacted   25 value(s)
```

```text
$ GBRAIN_HOME=/home/sungin/firstmate/data/gbrain/runtime \
  OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain stats 2>/dev/null
Pages:     270
Chunks:    1240
Embedded:  1240
Links:     1
Tags:      17
Timeline:  0

By type:
  firstmate-task: 235
  firstmate-note: 35
```

`gbrain doctor --json` applies a pending schema migration to whatever brain it opens - the 2026-08-13 entry above records that invocation moving this home's brain from schema 125 to 126 - so it is a read-only probe here only because the installed build's schema is already current, which the run's own output reports rather than a check that preceded it:

```text
$ GBRAIN_HOME=/home/sungin/firstmate/data/gbrain/runtime \
  OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain doctor --json 2>/dev/null > /tmp/doctor-2026-08-20.json
$ jq -r '.checks[] | select(.name == "schema_version") | .message' /tmp/doctor-2026-08-20.json
Version 132 (latest: 132)
```

Every check this build runs, with the category GBrain assigns it and its status, read back from that one saved run rather than from a name list chosen here:

```text
$ jq -r '.checks[] | "\(.category) \(.name) \(.status)"' /tmp/doctor-2026-08-20.json
skill resolver_health fail
skill retrieval_reflex_health warn
skill volunteer_channels ok
skill memory_verbs_usage ok
skill skill_conformance ok
skill skill_brain_first ok
skill skills_manifest_integrity ok
skill skill_currency warn
skill skill_preconditions ok
brain nightly_quality_probe_health ok
brain extract_health ok
brain conversation_facts_backlog ok
brain extract_atoms_backlog ok
brain conversation_format_coverage ok
ops progressive_batch_audit_health ok
brain conversation_parser_probe_health ok
ops home_dir_in_worktree warn
ops npm_squat ok
ops connection ok
ops pgvector ok
ops rls ok
meta schema_version ok
ops rls_event_trigger ok
brain embeddings ok
brain embedding_provider ok
brain embedding_column_registry ok
brain embedding_env_override ok
brain embedding_migration_state ok
brain graph_coverage ok
brain brain_score warn
brain orphan_ratio ok
brain integrity ok
brain jsonb_integrity ok
brain takes_weight_grid ok
brain child_table_orphans ok
brain raw_provenance ok
brain source_config_shape ok
skill whoknows_health ok
brain cross_modal_modality_backfill ok
brain unified_multimodal_coverage ok
brain markdown_body_completeness ok
brain oversized_pages ok
brain scraper_junk_pages ok
brain content_sanity_audit_recent ok
brain quarantined_pages ok
brain flagged_pages ok
brain unverified_extractions ok
brain frontmatter_integrity ok
meta eval_capture ok
brain contradictions ok
brain facts_extraction_health ok
brain effective_date_health ok
brain salience_health ok
ops queue_health ok
ops subagent_capability ok
brain facts_health ok
brain image_assets ok
brain ocr_health ok
brain sync_freshness ok
ops sync_consolidation ok
brain links_extraction_lag warn
brain cycle_freshness ok
brain content_hash_duplicates ok
brain undeclared_db_only_pages ok
ops db_only_collector_collision ok
ops search_mode ok
brain hidden_by_search_policy ok
brain eval_drift ok
ops reranker_health ok
ops batch_retry_health ok
ops wedged_queue ok
ops orphaned_private_queue ok
ops autopilot_fanout_concurrency ok
brain graph_signals_coverage ok
ops brainstorm_health ok
brain link_resolution_opportunity ok
ops ze_embedding_health ok
ops provider_sunset ok
brain embedding_width_consistency ok
brain facts_embedding_width_consistency ok
brain source_routing_health ok
ops oauth_confidential_client_health ok
ops oauth_client_scope_health ok
ops autopilot_lock_scope ok
ops stale_locks ok
meta cycle_phase_scope ok
brain embed_staleness ok
brain entity_link_coverage ok
brain timeline_coverage ok
brain takes_count warn
meta pack_upgrade_available ok
meta type_proliferation ok
brain dangling_aliases ok
```

Of the 93 checks, 86 report `ok`, and that first column is the build's own classification: 54 `brain`, 24 `ops`, 10 `skill`, 5 `meta`.
`brain` is the class `core/doctor-categories.ts` describes as the data-integrity signals, and it is not uniformly clean here: three of the seven non-`ok` checks belong to it, each `warn` - `brain_score`, `links_extraction_lag`, and `takes_count`.
The other four are `resolver_health` (`fail`), `retrieval_reflex_health`, and `skill_currency` in `skill`, and `home_dir_in_worktree` in `ops`; their messages are not reproduced here.
The five integrity checks named in the 2026-08-12 `v0.45.0.0` measurement, under `The v0.45.0.0 bootstrap checks do not apply to this deployment` above, all report `ok` - `integrity`, `content_hash_duplicates`, `child_table_orphans`, `orphan_ratio`, and `jsonb_integrity` - as does `connection`, which this build files under `ops` rather than `brain`.
The build scores those classes itself, out of the same saved run:

```text
$ jq -c '{brain_checks_score, category_scores}' /tmp/doctor-2026-08-20.json
{"brain_checks_score":85,"category_scores":{"brain":85,"skill":70,"ops":95,"meta":100}}
```

No name in the listing contains `outbox` or `divergence`, so the capture outbox is still a Firstmate artifact that GBrain has no knowledge of.

#### Capturing corrections and current facts, not only pruned text

Capturing the same slug twice, with the file rewritten in between, returned two receipts carrying different `content_hash` values:

```text
$ printf '# CT100 OHLCV service is now active\n\nCT100 OHLCV service is now active\n' > .probe-tmp/probe.md
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain capture --file .probe-tmp/probe.md \
  --slug probe/ct100-state --json 2>/dev/null
{
  "slug": "probe/ct100-state",
  "status": "created_or_updated",
  "chunks": 1,
  "content_hash": "17baeb21ad4bc67c228ef9d03495cae771cdb16cc7164c241c0b71abbf0495b8",
  "written": false,
  "source_kind": "capture-cli",
  "captured_at": "2026-08-20T18:13:56.205Z"
}

$ printf '# CT100 OHLCV service is now inactive\n\nCT100 OHLCV service is now inactive\n' > .probe-tmp/probe.md
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain capture --file .probe-tmp/probe.md \
  --slug probe/ct100-state --json 2>/dev/null
{
  "slug": "probe/ct100-state",
  "status": "created_or_updated",
  "chunks": 1,
  "content_hash": "d0f466f9c37ac14b9df0e1ec3b871cab5dfb343bc2d6eb37e5260484c90d3c0a",
  "written": false,
  "source_kind": "capture-cli",
  "captured_at": "2026-08-20T18:13:57.018Z"
}
```

The receipt cannot say on its own which of the two happened: `created_or_updated` is one collapsed status, and `written` is the write-through-to-file flag rather than a database signal.
What settles it is the brain's own count after both calls, one page rather than two:

```text
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain stats 2>/dev/null | head -3
Pages:     1
Chunks:    1
Embedded:  1
```

That page was still invisible to `recall`'s facts arm and appeared only in its search arm, whose stored chunk is the second body:

```text
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call recall '{"entity":"ct100"}' 2>/dev/null | \
  jq -c '{facts: [.facts[] | {id, fact}], results: (.results|length)}'
{"facts":[{"id":3,"fact":"CT100 OHLCV service is inactive today"},{"id":2,"fact":"CT100 OHLCV service is active and enabled"}],"results":0}

$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call recall '{"query":"CT100 OHLCV service state"}' 2>/dev/null | \
  jq -c '{facts: (.facts|length), results: [.results[] | {slug, chunk}]}'
{"facts":2,"results":[{"slug":"probe/ct100-state","chunk":"# CT100 OHLCV service is now inactive\n\nCT100 OHLCV service is now inactive"}]}
```

`remember` still requires provenance:

```text
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call remember '{"fact":"CT100 OHLCV service is inactive"}' 2>&1
UPGRADE_AVAILABLE 0.46.21.0 0.46.24.0
gbrain 0.46.21.0 -> 0.46.24.0 available. Run: gbrain self-upgrade
Missing required parameter: provenance
```

The storage primitives are native, but the triggers that decide when to correct a page or write a current fact are still Firstmate's.

#### Verified delivery and bounded retry drain

`gbrain capture --json` still returns a structured receipt carrying `status`, `chunks`, `content_hash`, `written`, `source_kind`, and `captured_at`; the two receipts recorded above are that shape.

[`../../bin/fm-gbrain-capture-lib.sh`](../../bin/fm-gbrain-capture-lib.sh) still caps the body at `FM_GBRAIN_CAPTURE_MAX_BYTES` default 65536:

```text
$ grep -n 'FM_GBRAIN_CAPTURE_MAX_BYTES\|head -c' bin/fm-gbrain-capture-lib.sh
36:FM_GBRAIN_CAPTURE_MAX_BYTES=${FM_GBRAIN_CAPTURE_MAX_BYTES:-65536}
391:  head -c "$FM_GBRAIN_CAPTURE_MAX_BYTES" "$raw" \
```

The receipt is parsed in [`../../bin/fm-gbrain-capture.sh`](../../bin/fm-gbrain-capture.sh), not in the library, and it still takes `.slug` alone and discards `status`, `chunks`, and `content_hash`, unchanged from the delivery-receipt section above:

```text
$ grep -n "jq -r '\.slug // empty'" bin/fm-gbrain-capture.sh
189:  page=$(printf '%s\n' "$out" | sed -n '/^[[:space:]]*{/,$p' | jq -r '.slug // empty' 2>/dev/null)
```

Delivery verification and bounded retry are still Firstmate's.

#### Provenance, validity, supersession

On the disposable brain, the identical string was still a duplicate, the semantically contradictory pair still coexisted, and the near-duplicate still superseded:

```text
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call remember \
  '{"fact":"CT100 OHLCV service is inactive","entity":"ct100","provenance":"probe"}' 2>/dev/null | jq -c
{"id":"1","status":"inserted","status_text":"remembered as fact #1","entity_slug":"ct100","valid_until":null,"protocol_version":1}

$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call remember \
  '{"fact":"CT100 OHLCV service is inactive","entity":"ct100","provenance":"probe"}' 2>/dev/null | jq -c
{"id":"1","status":"duplicate","status_text":"already knew this — kept fact #1","entity_slug":"ct100","valid_until":null,"protocol_version":1}

$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call remember \
  '{"fact":"CT100 OHLCV service is active and enabled","entity":"ct100","provenance":"probe"}' 2>/dev/null | jq -c
{"id":"2","status":"inserted","status_text":"remembered as fact #2","entity_slug":"ct100","valid_until":null,"protocol_version":1}

$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call remember \
  '{"fact":"CT100 OHLCV service is inactive today","entity":"ct100","provenance":"probe"}' 2>/dev/null | jq -c
{"id":"3","status":"superseded","status_text":"updated — fact #3 supersedes the previous version","entity_slug":"ct100","valid_until":null,"protocol_version":1}
```

The two survivors carry no stale marker: widening the entity projection to the supersession fields returns `expired_at` and `superseded_by` as `null` on both `#3` and `#2`, and no page in the same response:

```text
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call recall '{"entity":"ct100"}' 2>/dev/null | \
  jq -c '{facts: [.facts[] | {id, fact, expired_at, superseded_by}], results: (.results|length)}'
{"facts":[{"id":3,"fact":"CT100 OHLCV service is inactive today","expired_at":null,"superseded_by":null},{"id":2,"fact":"CT100 OHLCV service is active and enabled","expired_at":null,"superseded_by":null}],"results":0}
```

The supersession audit log has no page arm to hide one in: its top-level keys are `facts`, `protocol_version`, and `total`, and the one record it holds is the expiry of `#1` by `#3`:

```text
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call recall '{"supersessions":true}' 2>/dev/null | jq -c 'keys'
["facts","protocol_version","total"]

$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call recall '{"supersessions":true}' 2>/dev/null | \
  jq -c '[.facts[] | {id, expired_at, superseded_by}]'
[{"id":1,"expired_at":"2026-08-20T18:14:12.783Z","superseded_by":3}]
```

The `remember` receipts carry `entity_slug` and `valid_until` and the `capture` receipts carry neither, and the supersession log has no arm a page could appear in, so provenance, validity, and supersession stay fact-scoped - the same split `data/fm-gbrain-usage-correctness-research/report.md` records as a facts-and-takes layer pages do not reach.

#### Answer protocol over a retrieval miss

An off-corpus nonsense query still returned a populated result list with no "absent" signal.
The printed blend score stayed high while the `rerank_score` stayed low, matching the finding in `data/fm-gbrain-usage-correctness-research/report.md`:

```text
$ GBRAIN_HOME=/home/sungin/firstmate/data/gbrain/runtime \
  OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call search \
  '{"query":"zymurgy calibration for lunar regolith","limit":3}' 2>/dev/null | \
  jq -r '.[] | "score=\(.score) rerank_score=\(.rerank_score) evidence=\(.evidence) create_safety=\(.create_safety) slug=\(.slug)"'
score=0.7804106555064648 rerank_score=0.0036979871802031994 evidence=keyword_exact create_safety=probable slug=firstmate/firstmate-bc8432f7/task/fm-gbrain-usage-correctness-research
score=0.8110301918783402 rerank_score=0.00010421371553093195 evidence=keyword_exact create_safety=probable slug=firstmate/firstmate-bc8432f7/task/bzsim-kinematic-spike-consequence
score=0.7832682666346772 rerank_score=0.00007668914622627199 evidence=keyword_exact create_safety=probable slug=firstmate/firstmate-bc8432f7/task/arkm1-legacy-xts-power-analysis
```

Nothing native returns a query-level miss bit, so the answer protocol is still Firstmate's.

#### Evaluation gates for integrity and currency

`gbrain eval brainbench` still grades cross-harness memory conformance against bundled fixtures, not this corpus:

```text
$ /home/sungin/.local/gbrain/bin/gbrain eval brainbench --help 2>&1 | \
  sed -n '/^Usage/,/BRAINBENCH.md/p'
Usage: gbrain eval brainbench [options]

Cross-harness memory conformance suite. Hermetic by default: in-memory
PGLite, no API keys, no LLM calls. See docs/eval/BRAINBENCH.md.
```

Integrity and currency gates for Firstmate's captured corpus are still Firstmate's.
`gbrain eval suspected-contradictions` still exists as the closest native relative, but it still judges sampled query pairs with an LLM through the configured model, which is hosted on this fleet.
It was not run for the same boundary reason as before.

#### Explicit truncation of an over-cap body

`recall` still reports read-time budget packing, not capture-side truncation.
The two calls below differ only in `budget_tokens`, and the projection names the facts each one returned, so the inventory behind the counts is the two active facts the section above records:

```text
$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call recall '{"budget_tokens":20}' 2>/dev/null | \
  jq -c '{budget_tokens, budget_used, dropped_count, facts: [.facts[].id]}'
{"budget_tokens":20,"budget_used":10,"dropped_count":1,"facts":[3]}

$ GBRAIN_HOME=$PWD/.probe-tmp/runtime OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain call recall '{"budget_tokens":5000}' 2>/dev/null | \
  jq -c '{budget_tokens, budget_used, dropped_count, facts: [.facts[].id]}'
{"budget_tokens":5000,"budget_used":21,"dropped_count":0,"facts":[3,2]}
```

At 20 tokens the call returned `#3` and reported one dropped; at 5000 it returned `#3` and `#2` and reported none.

Firstmate's own body cap at 65536 bytes and the absence of a truncation marker in the outbox record are unchanged, so explicit truncation signalling is still Firstmate's.

## Maintaining this file

Refresh it on the next GBrain pin move, and treat every row of the closing table as a claim that has to be re-measured rather than carried forward.
Keep the probes on a disposable brain, and keep the hosted-synthesis boundary in [`../gbrain.md`](../gbrain.md) rather than restating it here.
