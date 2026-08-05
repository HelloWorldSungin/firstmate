# Local GBrain archive

This operator reference owns the Firstmate GBrain installation, archive setup, retrieval configuration, privacy boundary, quality evaluation, embedding-migration playbook, and recovery procedure for one brain.
How a Firstmate home scopes its OWN brain, and how the main brain is shared read-only with secondmate homes, is owned by [gbrain-scoping.md](gbrain-scoping.md).
The local embedding endpoint contract is in [gbrain-endpoints.md](gbrain-endpoints.md), the local reranker evidence is in [verification/gbrain-reranker.md](verification/gbrain-reranker.md), and the empirical installation evidence is in [verification/gbrain-init-retrieval.md](verification/gbrain-init-retrieval.md).
The measured retrieval and synthesis numbers, and the recorded migration timings, are in [verification/gbrain-eval.md](verification/gbrain-eval.md).

## Operating paths

The pinned GBrain source and executable live under `/home/sungin/.local/gbrain`.
The PGLite database and index live at `/home/sungin/.local/share/gbrain/pglite`.
The GBrain runtime configuration lives at `/home/sungin/.local/share/gbrain/runtime/.gbrain` through `GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime`.
The canonical markdown archive is the remote-less Git repository at `/home/sungin/.local/share/gbrain/archive`, outside both Firstmate project roots and the Firstmate source tree.
Do not add a third-party Git remote to that archive.
Those brain paths belong to this one deployment rather than to every home: a Firstmate home reaches them only when its `config/gbrain-local.json` sets `brain_root` to `/home/sungin/.local/share/gbrain`, and otherwise resolves its own `runtime/`, `pglite/`, and `archive/` under `$FM_HOME/data/gbrain` ([gbrain-scoping.md](gbrain-scoping.md)).
Run `bin/fm-gbrain.sh paths` for what a home actually resolves, and substitute those values for the absolute paths in the commands below.

## Pinned installation and upgrade

The installed GBrain release is `v0.42.69.0` at commit `3acd511b80bd4d2fe487290a70de75d4cf094730`, which is the first release whose tag contains GBrain's native MiniMax chat-touchpoint change for `MiniMax-M3`.
The installation uses GBrain's documented `git clone` plus `bun install` fallback because the tested standalone Linux release binaries did not initialize PGLite correctly.
The supporting Bun runtime is `1.3.14` at `/home/sungin/.local/gbrain/bin/bun`.

The executable is `/home/sungin/.local/gbrain/bin/gbrain`.
For a clean source installation with the pinned Bun binary already present, run:

```sh
mkdir -p /home/sungin/.local/gbrain/{bin,bun-global,cache}
git clone https://github.com/garrytan/gbrain.git /home/sungin/.local/gbrain/src
git -C /home/sungin/.local/gbrain/src checkout --detach 3acd511b80bd4d2fe487290a70de75d4cf094730
cd /home/sungin/.local/gbrain/src
BUN_INSTALL=/home/sungin/.local/gbrain/bun-global \
  /home/sungin/.local/gbrain/bin/bun install \
  --frozen-lockfile --ignore-scripts --cache-dir /home/sungin/.local/gbrain/cache
BUN_INSTALL=/home/sungin/.local/gbrain/bun-global \
  /home/sungin/.local/gbrain/bin/bun link
install -m 0755 /dev/stdin /home/sungin/.local/gbrain/bin/gbrain <<'GBRAIN_LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

exec /home/sungin/.local/gbrain/bin/bun /home/sungin/.local/gbrain/src/src/cli.ts "$@"
GBRAIN_LAUNCHER
```

The installed `/home/sungin/.local/gbrain/bin/gbrain` launcher executes `/home/sungin/.local/gbrain/src/src/cli.ts` with the pinned Bun binary, so runtime selection does not depend on a user-global `bun` command.
Set `PATH=/home/sungin/.local/gbrain/bin:$PATH` for operations that cause GBrain to spawn `gbrain` as a child process, including migrations.

### Upgrade policy

An upgrade changes the code that reads and writes the fleet's memory, so it is a deliberate, gated operation rather than a routine refresh.
GBrain's own `gbrain upgrade` and its `self_upgrade` notification are not the fleet's path, because they bypass the pin, the backup, and the gate below.
Every upgrade runs these seven steps in order, and any one of them failing is a rollback rather than a reason to continue:

1. **Pin.** The version in force is the one recorded above, and it moves only by editing this file in the same change that performs the upgrade.
   Select the new tag explicitly; `latest` is not a pin.
2. **Baseline.** Record an evaluation run on the current version first, because there is nothing to compare an upgraded brain against otherwise ([Measuring retrieval quality](#measuring-retrieval-quality)).
3. **Compatibility check.** Read the release notes between the two tags for schema, embedding, reranker, and MCP changes, and check the installed schema version with `gbrain doctor --json`, whose `schema_version` check reports the brain's version and the version the code expects.
4. **Back up.** Take the backup below with no writer running, and keep it until the upgraded brain has passed step 6.
5. **Upgrade and migrate.** Check out the new tag in the pinned source checkout, reinstall with `--frozen-lockfile --ignore-scripts`, then apply migrations with `--no-autopilot-install`, exactly as the commands below do.
6. **Smoke tests.** `gbrain doctor --json` must report `connection`, `schema_version`, `embeddings`, `embedding_provider`, `embedding_width_consistency`, and `reranker_health` as `ok`.
   Then run `tests/fm-recall.test.sh` for the wrapper contract and the live `tests/fm-gbrain-readonly-e2e.test.sh` for the real read-only share, and refresh [verification/gbrain-retrieval.md](verification/gbrain-retrieval.md).
7. **Gate.** Re-run the evaluation and compare it to the step-2 baseline with `bin/fm-gbrain-eval.sh compare`.
   A metric that falls below the evaluation set's threshold is a rollback trigger, not a new normal.

Rolling back is checking out the pinned commit again, reinstalling from the same lockfile, and restoring the step-4 backup.
Restore its archive, index, and runtime configuration together, because an index from one version under a runtime configuration from another is the one state neither the pin nor the smoke tests can detect.

To upgrade deliberately, select a newer verified GBrain tag, then run:

```sh
git -C /home/sungin/.local/gbrain/src fetch --tags origin
git -C /home/sungin/.local/gbrain/src checkout --detach <verified-tag>
cd /home/sungin/.local/gbrain/src
/home/sungin/.local/gbrain/bin/bun install --frozen-lockfile --ignore-scripts --cache-dir /home/sungin/.local/gbrain/cache
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
PATH=/home/sungin/.local/gbrain/bin:$PATH \
  /home/sungin/.local/gbrain/bin/gbrain apply-migrations \
  --yes --non-interactive --no-autopilot-install
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain doctor
```

Verify PGLite initialization in an isolated approved directory before adopting a new standalone release binary.
`--ignore-scripts` prevents Bun's postinstall hook from running an unguarded migration, and the explicit `--no-autopilot-install` migration skips the Phase F autopilot installation.
The story #6 deployment's migration-created unit has already been removed, so it has no autopilot unit eligible for routine cleanup.
If an autopilot unit exists before a future upgrade, leave it unchanged unless an ownership record proves that this deployment created it and confirms that no other story requires it.
A matching filename or generic GBrain-generated unit shape is not ownership proof.
Do not run `gbrain autopilot --uninstall` on this shared user home because its cleanup targets ignore `GBRAIN_HOME` and sweep user-home launchd, systemd, OpenClaw, crontab, and wrapper artifacts.
Clean up only an exact artifact with separate proof that this deployment created and still owns it.

## Initialize and configure retrieval

Initialize a new local PGLite brain with the verified local embedding model and its probed dimension:

```sh
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain init --pglite \
  --path /home/sungin/.local/share/gbrain/pglite \
  --embedding-model ollama:snowflake-arctic-embed2:568m \
  --embedding-dimensions 1024 \
  --non-interactive
```

Configure the local reranker and hosted synthesis routing with these verified commands:

```sh
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set provider_base_urls.llama-server-reranker http://127.0.0.1:8081/v1
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set search.reranker.model llama-server-reranker:qwen3-reranker-0.6b-q8_0
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set search.reranker.enabled true
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set provider_base_urls.minimax https://api.minimax.io/v1
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
  /home/sungin/.local/gbrain/bin/gbrain config set models.think minimax:MiniMax-M3
```

The embedding and reranking providers are local only.
Set `OLLAMA_BASE_URL=http://127.0.0.1:11434/v1` on every command that can embed or query, because GBrain does not persist the command-scoped endpoint and otherwise falls back to `http://localhost:11434/v1`.
The only configured hosted synthesis provider is `models.think=minimax:MiniMax-M3` through `https://api.minimax.io/v1`.
The current reranker service uses a 4096-token context with physical and micro-batch sizes both set to 4096, and archive-representative inputs complete with local reranking as recorded in [verification/gbrain-reranker.md](verification/gbrain-reranker.md).
An input beyond that service and context bound makes llama-server return HTTP 500, after which GBrain records a rerank failure and returns the non-reranked fallback ranking.
Operators must treat that visible failure as a failed rerank rather than successful reranking, even though retrieval still returns fallback results.

## Measuring retrieval quality

`bin/fm-gbrain-eval.sh` runs a versioned evaluation set against a home's brain and prints one run document.
Its `--help` owns the flags, the metric definitions, and the exit statuses; what follows is only what an operator has to decide.

The shipped set is [`gbrain-eval-set.v1.json`](gbrain-eval-set.v1.json): twenty fleet-history questions, each with the source documents that answer it and the key facts a good answer contains.
A question's expected source is a slug SUFFIX, so the same set measures any home rather than only the one it was written against.
Two of the twenty deliberately accept a family of near-duplicate documents, because a review thread that produced five revisions has no single correct member and scoring one of them as the answer would measure the set's arbitrariness rather than the brain's.

Local retrieval and hosted synthesis are scored and reported separately, and neither number is ever folded into the other.
They fail for unrelated reasons: a weak embedding model and an unreachable hosted provider are different problems with different fixes, and a combined score would hide which one is in force.

```sh
bin/fm-gbrain-eval.sh run --home <home> --label "<what changed>" --out <run.json>
bin/fm-gbrain-eval.sh compare <baseline.json> <candidate.json>
```

Every run records the GBrain version, the embedding model and its dimension, the reranker and whether it is enabled, the hosted synthesis model, the corpus revision, and the query settings.
Those travel with the numbers because a score without them cannot be compared to the next one.
The reranker and hosted model are read from the brain's own database plane rather than from Firstmate's configured intent for it, so a run can never be recorded as reranked while the brain has reranking off.
The corpus revision is a digest of the durable source a home actually holds: the per-document content versions in its capture outbox, or the archive's git revision when it is fed from an archive.
`compare` reports which of those fields moved between two runs, so a comparison across a changed corpus or a changed model is labelled rather than silently treated as like-for-like.

Re-run the evaluation after a corpus, GBrain, model, or reranker change, and after any migration below.
The exit status is usable as a gate: 0 when every threshold the set declares was met, 1 when one was missed, 2 for a refused configuration, and 3 when the brain could not be read at all.
A missed threshold is a result to record with its cause, never a reason to edit the threshold.

## MiniMax credential contract and privacy boundary

The MiniMax credential is read only at runtime from `/home/sungin/.pi/agent/auth.json`, field `minimax.key`.
The file must remain mode `0600`.
Do not place that value in GBrain configuration, a repository, a test, a log, or a service unit.
A home that uses per-home brain scoping may instead keep its own copy in that home's credential plane, `config/gbrain-secrets/<name>` named by `think.secret`, under the same mode `0600` requirement ([gbrain-scoping.md](gbrain-scoping.md)).
Either way the key reaches only the synthesizing process: `bin/fm-gbrain.sh` reports such a credential as present, absent, or refused and never prints its bytes.
A Firstmate worker never runs the raw path below: `bin/fm-recall.sh` is the retrieval surface it uses, and it performs this same one-process injection for `think` ([gbrain-scoping.md](gbrain-scoping.md)).
For a raw operator run, use an untraced shell to inject the key only into the `think` process:

```sh
task_minimax_key=$(jq -er '.minimax.key | select(type == "string" and length > 0)' /home/sungin/.pi/agent/auth.json)
MINIMAX_API_KEY="$task_minimax_key" \
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain think '<question>' --rounds 1
unset task_minimax_key
```

`search` and local `query --no-expand` keep retrieval on the host.
`think` sends the question and selected memory excerpts to MiniMax for synthesis.
When the MiniMax credential is absent, `think` returns no synthesis and reports that no LLM is available, while local `search` continues to return results.

## Archive, backup, and rebuild

Import and embed the local-only archive with:

```sh
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain import /home/sungin/.local/share/gbrain/archive
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain embed --stale
```

Stop every `gbrain serve` process before copying PGLite because it is a single-writer database.
Task-knowledge capture is the other writer of a home's index ([gbrain-capture.md](gbrain-capture.md)), so take the copy when no teardown and no `bin/fm-gbrain-capture.sh` run can start; a capture that finds the brain busy leaves a pending outbox item and is retried later.
Back up the archive, PGLite directory, and runtime configuration together to an on-box directory:

```sh
backup_dir=/home/sungin/.local/share/gbrain/backups/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$backup_dir"
cp -a /home/sungin/.local/share/gbrain/archive \
  /home/sungin/.local/share/gbrain/pglite \
  /home/sungin/.local/share/gbrain/runtime/.gbrain \
  "$backup_dir"/
```

### What a home can actually rebuild from

An index is disposable only to the extent that something else still holds the documents, and that something differs per home.
A home fed from the markdown archive rebuilds with `gbrain import`, as above.
A Firstmate home fed by task-knowledge capture has no archive at all: its durable source is `data/gbrain-outbox/`, where every captured document is stored whole and redacted before delivery is ever attempted ([gbrain-capture.md](gbrain-capture.md)).
That home rebuilds by re-delivering the outbox rather than by importing a directory:

```sh
bin/fm-gbrain-capture.sh process --force    # re-deliver every stored record, including already-captured ones
bin/fm-gbrain-capture.sh backfill           # additionally re-compose from any manifest or report not yet in the outbox
```

Check which one a home has before planning any destructive step, because a home with neither has no source to rebuild from and its index is the only copy.

### Rebuilding a damaged index

`reinit-pglite` wipes the index and re-creates it at a chosen model and dimension, preserving the old one as `<path>.bak`; rolling back is moving that directory back.
It also clears the brain's own database-plane configuration.
The reranker, the hosted synthesis model, and the provider base URLs are stored there, so a reinitialized brain silently retrieves without reranking until [Initialize and configure retrieval](#initialize-and-configure-retrieval) is applied again.
Re-apply that configuration before measuring or trusting the rebuilt brain, then restore the documents from whichever source the previous section identified.

```sh
GBRAIN_HOME=/home/sungin/.local/share/gbrain/runtime \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
PATH=/home/sungin/.local/gbrain/bin:$PATH \
  /home/sungin/.local/gbrain/bin/gbrain reinit-pglite \
  --path /home/sungin/.local/share/gbrain/pglite \
  --embedding-model ollama:snowflake-arctic-embed2:568m \
  --embedding-dimensions 1024 \
  --yes --no-sync
```

### Migrating to another embedding model

`gbrain migrate embeddings` is the forward path for a model or dimension change, and `reinit-pglite` is not: the migration keeps every page and re-embeds in place, handles the dimension change as a schema transition, and resumes after a kill.
Both are destructive to the stored vectors, because pgvector under PGLite cannot alter a vector column's width in place.
Neither is reversible from inside GBrain: `migrate embeddings` writes no `.bak` of its own, so the pre-migration copy is the only rollback, and rolling back means re-embedding the whole corpus again.

Run every step of a first migration on a disposable copy of the index before touching the live one.
Copy the index and the runtime directory to scratch, point a scratch home's `brain_root` at the copy, and rewrite the copy's `database_path`; a scratch home with the same outbox reports the same corpus revision, so the copy's evaluation is directly comparable to the live baseline.

1. Record a baseline evaluation run, and plan the change with `--dry-run`, which reports the source and target models, both dimensions, the chunk count, and that the stored vectors will be deleted.
2. Take the backup above, with no `gbrain serve` and no capture able to start.
3. Migrate with `gbrain migrate embeddings --to <provider:model> --dim <N> --yes`, under this home's `GBRAIN_HOME` and `OLLAMA_BASE_URL`.
4. Verify with `gbrain doctor --json`, whose `embedding_provider` check reports the live model, its measured dimension, and whether the database agrees, and whose `embedding_width_consistency` check compares the schema width with the configured one.
5. Re-run the evaluation and `compare` it with the step-1 baseline.

Verify a migration with the evaluation, never with `gbrain stats`.
A half-finished migration still reports every chunk as embedded there, while retrieval quality has already fallen; `gbrain doctor` catches it only as an `embed_staleness` warning.
An interrupted migration is completed by re-running the identical command, which re-embeds only what is left, or by `gbrain embed --stale --include-null-signature`.

The target artifact has to be verified before it is named, because a model that exists as a name does not necessarily exist as a tag.
Confirm the tag resolves and record its digest and native width before migrating:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://registry.ollama.ai/v2/library/<model>/manifests/<tag>
ollama pull <model>:<tag>
curl -sS <embedding endpoint>/embeddings -H 'Content-Type: application/json' \
  -d '{"model":"<model>:<tag>","input":"probe"}' | jq '{model, dimensions: (.data[0].embedding | length)}'
```

Pass the probed width as `--dim`, rather than a width from a model card, so the schema is rebuilt at the width the endpoint actually returns.

Capture and migration are not serialized against each other, and a capture that lands mid-migration is embedded at the new width and stays retrievable, but it is not part of the migration's own plan.
Quiesce capture for the migration window anyway, and if one did land, finish with `gbrain embed --stale` before the verification run.
