# Local GBrain installation and operation

This operator reference owns the Firstmate GBrain installation, retrieval configuration, privacy boundary, quality evaluation, embedding-migration playbook, and backup and rebuild procedure for one brain.
How a Firstmate home scopes its OWN brain, and how the main brain is shared read-only with secondmate homes, is owned by [gbrain-scoping.md](gbrain-scoping.md).
The local embedding endpoint contract is in [gbrain-endpoints.md](gbrain-endpoints.md), the local reranker evidence is in [verification/gbrain-reranker.md](verification/gbrain-reranker.md), and the empirical installation evidence is in [verification/gbrain-init-retrieval.md](verification/gbrain-init-retrieval.md).
The measured retrieval and synthesis numbers, and the recorded migration timings, are in [verification/gbrain-eval.md](verification/gbrain-eval.md).

## Operating paths

The pinned GBrain source and executable live under `/home/sungin/.local/gbrain`.
That is the installation, and it is shared by every home on this host.

A brain's own directories are per home, so this page resolves them rather than naming them.
`bin/fm-gbrain.sh paths` is the authority for what a home actually resolves: its brain root, the `GBRAIN_HOME` runtime directory holding `.gbrain`, the PGLite database and index, and the archive location.
A home resolves those under `$FM_HOME/data/gbrain` unless its `config/gbrain-local.json` sets `brain_root` elsewhere ([gbrain-scoping.md](gbrain-scoping.md)).
Resolve them once from the Firstmate code root, and the command blocks below read the values from this shell:

```sh
FM_HOME=${FM_HOME:-/home/sungin/firstmate}
paths=$(FM_HOME="$FM_HOME" bin/fm-gbrain.sh paths --json)
gbrain_home=$(printf '%s' "$paths" | jq -er '.gbrain_home')
pglite=$(printf '%s' "$paths" | jq -er '.pglite')
archive=$(printf '%s' "$paths" | jq -er '.archive')
```

The command blocks below guard these variables, so an unresolved value refuses instead of silently creating or rewriting a brain under `$HOME/.gbrain`.
The upgrade, backup, and `reinit-pglite` blocks resolve the same values again behind their own guard, because a step that rewrites or copies a brain must not inherit a stale variable from an earlier shell.
The guards catch a value that was never resolved, while re-resolution replaces one that is real but stale, so the two cover different failures and neither replaces the other.
As one example of what that returns, the `/home/sungin/firstmate` home carries no `config/gbrain-local.json` and so resolves `/home/sungin/firstmate/data/gbrain`; read that as one deployment's values rather than as where a brain lives.
A hardcoded brain path is wrong for every home but the one it was written from, and it goes on looking right after the deployment it named is gone.

`paths` reports the archive location a home derives, not a directory that exists.
Only an archive-fed brain has one at all, and a Firstmate home fed by task-knowledge capture has none ([What a home can actually rebuild from](#what-a-home-can-actually-rebuild-from)).
Where an archive does exist it is a remote-less Git repository, and no third-party Git remote may be added to it.

## Pinned installation and upgrade

The installed GBrain release is `v0.46.21.0` at commit `649ffe5f8baf3ff7f979c77f4de3975904cfe029`.
The pin moved there from `v0.45.9.0` on 2026-08-19, backed up first to `data/gbrain/backups/20260819T045704Z`, and [verification/gbrain-memory-verbs.md](verification/gbrain-memory-verbs.md) records the like-for-like evaluation taken either side of that move, which measured retrieval unchanged and synthesis moved.
The earlier pin had moved from `v0.45.0.0` on 2026-08-13, and that same verification record holds the live upgrade evidence for it, the new boundary-retrieval verbs, and the unchanged privacy controls.
The pin before that moved from `v0.42.69.0` on 2026-08-12, and the same verification record preserves what that upgrade measured, including the capture guarantees it did not change.
The `v0.42.69.0` pin was held for a release carrying a per-model chat-touchpoint entry for `MiniMax-M3`; `v0.44.1.0` removed that allowlist entirely, so the configured `models.think` value no longer depends on a release shipping an entry for it.
The installation remains on GBrain's documented `git clone` plus pinned `bun install` fallback so a version upgrade does not also change the packaging path used for migration and rollback.
The old `v0.42.71.0` and `v0.42.72.1` standalone Linux binaries failed fresh PGLite initialization, while the `v0.45.9.0` standalone binary passed fresh isolated initialization with this deployment's embedding shape.
That fresh initialization does not prove an in-place production upgrade through the standalone packaging, so adopting it requires a separate isolated-copy migration and the full gate below.
The supporting Bun runtime is `1.3.14` at `/home/sungin/.local/gbrain/bin/bun`.

The executable is `/home/sungin/.local/gbrain/bin/gbrain`.
For a clean source installation with the pinned Bun binary already present, run:

```sh
mkdir -p /home/sungin/.local/gbrain/{bin,bun-global,cache}
git clone https://github.com/garrytan/gbrain.git /home/sungin/.local/gbrain/src
git -C /home/sungin/.local/gbrain/src checkout --detach 649ffe5f8baf3ff7f979c77f4de3975904cfe029
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
   That recorded string is also the version the dashboard's GBrain panel quotes: [`bin/fm-gbrain-health.sh`](../bin/fm-gbrain-health.sh) reports it rather than asking a running executable what it is, reading it through `fm_gbrain_documented_pin` in [`bin/fm-gbrain-lib.sh`](../bin/fm-gbrain-lib.sh), which takes the first backticked `v`-prefixed release token in this file.
   Keep the pin first among such tokens, so this step is what keeps the panel true as well.
   The clean-install recipe above names the same commit, so move both in that one edit: a recipe left on the previous commit hands an operator a binary the rest of this file no longer describes, while the panel still quotes the recorded pin.
   [`bin/fm-gbrain-pin-check.sh`](../bin/fm-gbrain-pin-check.sh) is the mechanical reader of both sides: it compares the recorded pin with what the installed executable reports and fails on drift, so a pin left behind by an upgrade is a finding rather than something a reviewer has to notice.
   Run it after step 5, and expect it to report `skipped` wherever no GBrain is installed, which is a genuine absence of evidence rather than a pass.
   Session start runs it too, through [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh), so a pin left behind by an upgrade performed outside this procedure surfaces as a `GBRAIN_PIN:` diagnostic on the next session rather than waiting for a reviewer to notice; a home with no GBrain installed and a run that agrees both stay silent.
2. **Baseline.** Record an evaluation run on the current version first, because there is nothing to compare an upgraded brain against otherwise ([Measuring retrieval quality](#measuring-retrieval-quality)).
3. **Compatibility check.** Read the release notes between the two tags for schema, embedding, reranker, and MCP changes, and check the installed schema version with `gbrain doctor --json`, whose `schema_version` check reports the brain's version and the version the code expects.
4. **Back up.** Record the current source commit, take the backup below with no writer running, record the resulting backup path in the upgrade's delivery evidence, and keep it until the upgraded brain has passed step 6.
5. **Upgrade and migrate.** Check out the new tag in the pinned source checkout, reinstall with `--frozen-lockfile --ignore-scripts`, then apply migrations with `--no-autopilot-install`, exactly as the commands below do.
6. **Smoke tests.** `gbrain doctor --json` must report `connection`, `schema_version`, `embeddings`, `embedding_provider`, `embedding_width_consistency`, and `reranker_health` as `ok`.
   Then run `tests/fm-recall.test.sh` for the wrapper contract and the live `tests/fm-gbrain-readonly-e2e.test.sh` for the real read-only share, and refresh [verification/gbrain-retrieval.md](verification/gbrain-retrieval.md).
7. **Gate.** Re-run the evaluation and compare it to the step-2 baseline with `bin/fm-gbrain-eval.sh compare`.
   A metric that falls below the evaluation set's threshold is a rollback trigger, not a new normal.

Rolling back is checking out the pre-upgrade commit recorded in the upgrade's delivery evidence, reinstalling from that commit's lockfile, and restoring the step-4 backup recorded there.
Restore its archive or outbox, index, and runtime configuration together, because an index from one version under a runtime configuration from another is the one state neither the pin nor the smoke tests can detect.

To upgrade deliberately, select a newer verified GBrain tag, then run the block below from the Firstmate code root.

`apply-migrations` rewrites whichever brain `GBRAIN_HOME` names, so this block resolves that home rather than naming one, exactly as the backup below does.
A hardcoded `GBRAIN_HOME` is wrong for every home but the one it was written from, and on a host carrying more than one brain directory it is worse than wrong: the migration succeeds against the wrong database and every step after it reports success, while the brain the home actually reads stays un-migrated under new code.
That is not hypothetical: this host has carried more than one brain directory at a time, and nothing stops that happening again.

```sh
FM_HOME=${FM_HOME:-/home/sungin/firstmate}
gbrain_home=$(FM_HOME="$FM_HOME" bin/fm-gbrain.sh paths --json | jq -er '.gbrain_home')
if [ ! -d "$gbrain_home/.gbrain" ]; then
  printf 'refusing upgrade: %s is not an initialized brain runtime for %s\n' "$gbrain_home" "$FM_HOME" >&2
  exit 1
fi
git -C /home/sungin/.local/gbrain/src fetch --tags origin
git -C /home/sungin/.local/gbrain/src checkout --detach <verified-tag>
(cd /home/sungin/.local/gbrain/src \
  && /home/sungin/.local/gbrain/bin/bun install --frozen-lockfile --ignore-scripts --cache-dir /home/sungin/.local/gbrain/cache)
GBRAIN_HOME=$gbrain_home \
PATH=/home/sungin/.local/gbrain/bin:$PATH \
  /home/sungin/.local/gbrain/bin/gbrain apply-migrations \
  --yes --non-interactive --no-autopilot-install
GBRAIN_HOME=$gbrain_home \
  /home/sungin/.local/gbrain/bin/gbrain doctor
```

Resolve `gbrain_home` before the checkout, as above, so the value is read while the working directory is still the Firstmate code root.

Verify PGLite initialization in an isolated approved directory before adopting a new standalone release binary.
`--ignore-scripts` prevents Bun's postinstall hook from running an unguarded migration, and the explicit `--no-autopilot-install` migration skips the Phase F autopilot installation.
The story #6 deployment's migration-created unit has already been removed, so it has no autopilot unit eligible for routine cleanup.
If an autopilot unit exists before a future upgrade, leave it unchanged unless an ownership record proves that this deployment created it and confirms that no other story requires it.
A matching filename or generic GBrain-generated unit shape is not ownership proof.
Do not run `gbrain autopilot --uninstall` on this shared user home because its cleanup targets ignore `GBRAIN_HOME` and sweep user-home launchd, systemd, OpenClaw, crontab, and wrapper artifacts.
Clean up only an exact artifact with separate proof that this deployment created and still owns it.

Since `v0.42.76.0` every command rejects a flag it does not recognize instead of ignoring it, so step 6 must exercise the wrapper scripts rather than the executable alone.
An invocation that had been passing a stray or misspelled flag was doing nothing with it and now fails outright.

### A home serving a main brain carries no hosted synthesis credentials

A home that serves its brain to another home must not point `models.think` at a hosted provider or hold that provider's credential.
The rule constrains hosted synthesis alone: local embedding, local reranking, retrieval, and capture are unaffected, and a home that serves no one keeps its hosted synthesis as configured.

The reason is that the boundary is no longer structural.
`v0.42.76.0` reclassified `think` from a write-scope operation to `scope: read`.
Before that change the read-only scope check refused the call outright, so no configuration could cross the boundary; now a holder of a read-only share reaches `think` on the serving home, and the synthesis runs on the serving home's configured model under the serving home's credential.
No serving option avoids it, because `--surface verbs` still exposes the equivalent `synthesize` verb.

The consequence of breaking the rule is that any holder of a read-only share can cause the serving home's own brain content to be sent to that hosted provider, at the holder's choosing and with no further consent gate.
Storage stays read-only regardless: writes are still refused and a remote caller still cannot persist a synthesis, and [`../tests/fm-gbrain-readonly-e2e.test.sh`](../tests/fm-gbrain-readonly-e2e.test.sh) proves both directly rather than inferring them from the operation being unreachable.
What that guard can no longer prove is that main-brain content cannot reach a hosted model, which is exactly the gap this rule fills.

The captain accepted the trade on 2026-08-12 while live exposure was zero: this fleet configured no shared main brain, so no home was serving one and the path was latent rather than in use.
Treat it as accepted-while-latent, and re-examine it before the first main brain is configured rather than assuming it was accepted under live traffic.
[verification/gbrain-memory-verbs.md](verification/gbrain-memory-verbs.md) records the measurement behind it.

The rule is checked rather than only stated, over a deliberately bounded set of surfaces.
[`bin/fm-gbrain.sh`](../bin/fm-gbrain.sh) `check` fails a `serving-credential` row when a home serves its brain and hosted synthesis is reachable on it, so that configuration exits non-zero instead of passing unnoticed.
`grant-read` warns at the moment of creation, because registering the first reading client is the ordinary action that turns a latent credential into a live boundary; registration still completes, since the fix is to remove the credential rather than to block the share, while the command exits non-zero so the required follow-up cannot be missed.
`serving-check` runs at every session start (via `bin/fm-bootstrap.sh`) and emits a `GBRAIN_SERVING_CREDENTIAL` line when a home is already in the forbidden configuration, so an existing violation cannot sit unnoticed between sessions.
The verdict keys off the actual planes and never a home's name, because deriving it from a name is the defect class this repository keeps relearning.
The serving relationship is `main_brain_owner` in the home-local plane, and it is read first: a home that provably serves nothing is clean whatever its credential plane holds, because the rule constrains serving homes alone.
Past that gate the verdict inspects Firstmate's declared surfaces (`think.secret` and `think.base_url` in `config/gbrain.json`, and `config/gbrain-secrets/<name>`), GBrain's own runtime configuration (`models.think` and the matching `provider_base_urls.<provider>` under `GBRAIN_HOME`), and `minimax.key` in the fleet-wide runtime credential store (`$HOME/.pi/agent/auth.json`).
Hosted synthesis is reachable if a named credential is held in the declared credential store, `minimax.key` is held in the runtime credential store, or the declared or runtime `think` route points at a base URL that leaves this host.
An unreadable serving relationship, declared plane, runtime plane, or credential store is reported as `unknown` and never as a pass, on every surface including `grant-read`, because a check that could not run must not look like one that found nothing.
`bin/fm-gbrain-lib.sh` owns the single verdict every surface shares; [`gbrain-scoping.md`](gbrain-scoping.md) points here for the rule and its enforcement.

### Announce a maintenance window

The brain stops answering while upgrade steps 4 and 5 run, and the same is true of a reindex or an embedding migration below.
Set `FM_GBRAIN_MAINTENANCE_STATE` to `upgrading` or `reindexing`, with any free text in `FM_GBRAIN_MAINTENANCE_DETAIL`, so the window reads as deliberate care rather than as an unexplained outage, and unset it once the step-7 gate passes.
`bin/fm-gbrain-health.sh` never infers the state, because only the operator's announcement has the timing to be true.
The dashboard's GBrain panel is what renders it, and it reads the value from the dashboard server's own environment rather than from any home's configuration.
For the installed user service that means a systemd drop-in: [`bin/fm-dashboard-install.sh`](../bin/fm-dashboard-install.sh) rewrites its environment file on every install and carries only the names [`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs) documents.
An unannounced window degrades rather than breaks: the panel reports the retrieval and synthesis legs it could not reach, capture keeps queueing into the durable outbox and drains on a later run, and fleet supervision is unaffected either way ([dashboard.md](dashboard.md#knowledge) owns what each panel state means).

## Initialize and configure retrieval

Initialize a new local PGLite brain with the verified local embedding model and its probed dimension:

```sh
GBRAIN_HOME=${gbrain_home:?run the Operating paths resolve block first} \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain init --pglite \
  --path "${pglite:?run the Operating paths resolve block first}" \
  --embedding-model ollama:snowflake-arctic-embed2:568m \
  --embedding-dimensions 1024 \
  --non-interactive
```

Configure the local reranker and hosted synthesis routing with these verified commands:

```sh
GBRAIN_HOME=${gbrain_home:?run the Operating paths resolve block first} \
  /home/sungin/.local/gbrain/bin/gbrain config set provider_base_urls.llama-server-reranker http://127.0.0.1:8081/v1
GBRAIN_HOME=${gbrain_home:?run the Operating paths resolve block first} \
  /home/sungin/.local/gbrain/bin/gbrain config set search.reranker.model llama-server-reranker:qwen3-reranker-0.6b-q8_0
GBRAIN_HOME=${gbrain_home:?run the Operating paths resolve block first} \
  /home/sungin/.local/gbrain/bin/gbrain config set search.reranker.enabled true
GBRAIN_HOME=${gbrain_home:?run the Operating paths resolve block first} \
  /home/sungin/.local/gbrain/bin/gbrain config set provider_base_urls.minimax https://api.minimax.io/v1
GBRAIN_HOME=${gbrain_home:?run the Operating paths resolve block first} \
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

The shipped set is [`gbrain-eval-set.v1.json`](gbrain-eval-set.v1.json), currently at set version 2: forty fleet-history questions, each with the source documents that answer it and the key facts a good answer contains.
Set version 1 held the first twenty, and version 2 added twenty more so a one-question effect could be sized against a wider set rather than only detected.
A question's expected source is a slug SUFFIX, so the same set measures any home rather than only the one it was written against.
Three questions deliberately accept a family of near-duplicate documents, because a review thread or a plan that produced several revisions has no single correct member and scoring one of them as the answer would measure the set's arbitrariness rather than the brain's.
The file name carries the set SCHEMA version and the `version` field carries the set's own, so widening the set bumps the field and leaves every recorded run comparable to the set version it names.

Local retrieval and hosted synthesis are scored and reported separately, and neither number is ever folded into the other.
They fail for unrelated reasons: a weak embedding model and an unreachable hosted provider are different problems with different fixes, and a combined score would hide which one is in force.
Both phases therefore report how many questions were actually read alongside how many were asked.
A question that never reached hosted synthesis at all - the local read failed, GBrain is absent, no hosted credential is installed, or the call was killed - is excluded from the synthesis rates and named as unread with the reason it was excluded, rather than counted as an answer the hosted provider failed to give.

```sh
bin/fm-gbrain-eval.sh run --home <home> --label "<what changed>" --out <run.json>
bin/fm-gbrain-eval.sh compare <baseline.json> <candidate.json>
```

Every run records the GBrain version, the embedding model and its dimension, the reranker and whether it is enabled, the hosted synthesis model, the corpus revision, and the query settings.
Those travel with the numbers because a score without them cannot be compared to the next one.
The reranker and hosted model are read from the brain's own database plane rather than from Firstmate's configured intent for it, so a run can never be recorded as reranked while the brain has reranking off.
The corpus revision is a digest of the durable source a home actually holds: the per-document content versions in its capture outbox, or the archive's git revision when it is fed from an archive.
`compare` reports which of those fields moved between two runs, so a comparison across a changed corpus or a changed model is labelled rather than silently treated as like-for-like.
A value that neither run could record is reported as `UNKNOWN` rather than as unchanged, because two absent values are not evidence that nothing moved, and the render names which value was missing.
A field whose recorded values differ is still reported as `CHANGED` even when an optional sibling value such as a base URL is absent, so a migration from 1024 to 768 dimensions is never hidden behind an unrecorded endpoint.

Re-run the evaluation after a corpus, GBrain, model, or reranker change, and after any migration below.
The exit status is usable as a gate: 0 when every threshold the set declares was met, 1 when one was missed, 2 for a refused configuration, and 3 when the brain could not be read at all.
A phase that ran and read nothing fails the gate on its own, whether or not the set declares any threshold for that phase, because a phase that measured nothing has shown nothing.
Its declared thresholds are additionally reported as unmeasured rather than dropped, so a threshold that could not be evaluated is never rendered as one that was met.
A missed threshold is a result to record with its cause, never a reason to edit the threshold.

## MiniMax credential contract and privacy boundary

The MiniMax credential is read only at runtime from `$HOME/.pi/agent/auth.json`, field `minimax.key`.
The file must remain mode `0600`.
Do not place that value in GBrain configuration, a repository, a test, a log, or a service unit.
A home that uses per-home brain scoping may instead keep its own copy in that home's credential plane, `config/gbrain-secrets/<name>` named by `think.secret`, under the same mode `0600` requirement ([gbrain-scoping.md](gbrain-scoping.md)).
A home that serves its brain to another home is the exception and keeps no hosted synthesis credential anywhere ([A home serving a main brain carries no hosted synthesis credentials](#a-home-serving-a-main-brain-carries-no-hosted-synthesis-credentials)).
Either way the key reaches only the synthesizing process: `bin/fm-gbrain.sh` reports such a credential as present, absent, or refused and never prints its bytes.
A Firstmate worker never runs the raw path below: `bin/fm-recall.sh` is the retrieval surface it uses, and it performs this same one-process injection for `think` ([gbrain-scoping.md](gbrain-scoping.md)).
For a raw operator run, use an untraced shell to inject the key only into the `think` process:

```sh
task_minimax_key=$(jq -er '.minimax.key | select(type == "string" and length > 0)' "$HOME/.pi/agent/auth.json")
MINIMAX_API_KEY="$task_minimax_key" \
GBRAIN_HOME=${gbrain_home:?run the Operating paths resolve block first} \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain think '<question>' --rounds 1
unset task_minimax_key
```

`search` and local `query --no-expand` keep retrieval on the host.
`think` sends the question and selected memory excerpts to MiniMax for synthesis.
When the MiniMax credential is absent, `think` returns no synthesis and reports that no LLM is available, while local `search` continues to return results.

## Archive, backup, and rebuild

An archive-fed brain imports and embeds its local-only archive with the commands below; a capture-fed brain has no archive to import and rebuilds from its outbox instead ([What a home can actually rebuild from](#what-a-home-can-actually-rebuild-from)).

```sh
GBRAIN_HOME=${gbrain_home:?run the Operating paths resolve block first} \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain import "${archive:?run the Operating paths resolve block first}"
GBRAIN_HOME=${gbrain_home:?run the Operating paths resolve block first} \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  /home/sungin/.local/gbrain/bin/gbrain embed --stale
```

Stop every `gbrain serve` process before copying PGLite because it is a single-writer database.
A home's index has two other writers: task-knowledge capture ([gbrain-capture.md](gbrain-capture.md)), and search itself, because every `bin/fm-recall.sh search` that succeeds rewrites files under `pglite/` ([verification/gbrain-retrieval.md](verification/gbrain-retrieval.md) records which ones and how that was measured), and the dashboard's GBrain panel lets an operator start a search on demand ([dashboard.md](dashboard.md#knowledge)).
So take the copy when no teardown, no `bin/fm-gbrain-capture.sh` run, and no search can start, a running dashboard's panel included.
Those writers contend for the same single-writer lock, and a dashboard search is one more source of a busy brain: a capture that finds it busy leaves a pending outbox item and is retried later, while a search that cannot take the lock fails outright with a lock timeout.
Back up the durable document source, PGLite directory, and runtime configuration together to an on-box directory:

```sh
FM_HOME=${FM_HOME:-/home/sungin/firstmate}
paths=$(FM_HOME="$FM_HOME" bin/fm-gbrain.sh paths --json)
brain_root=$(printf '%s' "$paths" | jq -er '.brain_root')
pglite=$(printf '%s' "$paths" | jq -er '.pglite')
gbrain_home=$(printf '%s' "$paths" | jq -er '.gbrain_home')
archive=$(printf '%s' "$paths" | jq -er '.archive')
outbox=$FM_HOME/data/gbrain-outbox
outbox_record=
outbox_unreadable=
if [ -d "$outbox" ]; then
  outbox_record=$(find "$outbox" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)
  outbox_unreadable=$(find "$outbox" -maxdepth 1 -type f -name '*.json' ! -readable -print -quit 2>/dev/null)
fi
if [ -n "$outbox_record" ] && [ -z "$outbox_unreadable" ]; then
  durable_source=$outbox
elif [ -d "$archive/.git" ] && git -C "$archive" rev-parse --verify HEAD >/dev/null 2>&1; then
  durable_source=$archive
else
  printf 'refusing backup: no readable outbox or valid Git archive exists\n' >&2
  exit 1
fi
[ -d "$pglite" ] && [ -d "$gbrain_home/.gbrain" ] || exit 1
backup_dir=$brain_root/backups/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$backup_dir"
cp -a "$durable_source" "$pglite" "$gbrain_home/.gbrain" "$backup_dir"/ || exit 1
printf '%s\n' "$backup_dir"
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

Announce the window first ([Announce a maintenance window](#announce-a-maintenance-window)), because a wiped index reads as a brain that lost its memory until it is rebuilt.
`reinit-pglite` wipes the index and re-creates it at a chosen model and dimension, preserving the old one as `<path>.bak`; rolling back is moving that directory back.
It also clears the brain's own database-plane configuration.
The reranker, the hosted synthesis model, and the provider base URLs are stored there, so a reinitialized brain silently retrieves without reranking until [Initialize and configure retrieval](#initialize-and-configure-retrieval) is applied again.
Re-apply that configuration before measuring or trusting the rebuilt brain, then restore the documents from whichever source the previous section identified.
Run the block below from the Firstmate code root.

```sh
FM_HOME=${FM_HOME:-/home/sungin/firstmate}
paths=$(FM_HOME="$FM_HOME" bin/fm-gbrain.sh paths --json)
gbrain_home=$(printf '%s' "$paths" | jq -er '.gbrain_home')
pglite=$(printf '%s' "$paths" | jq -er '.pglite')
if [ ! -d "$gbrain_home/.gbrain" ] || [ -z "$pglite" ]; then
  printf 'refusing to reinitialize: %s did not resolve an initialized brain runtime and an index path\n' "$FM_HOME" >&2
  exit 1
fi
GBRAIN_HOME=$gbrain_home \
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
PATH=/home/sungin/.local/gbrain/bin:$PATH \
  /home/sungin/.local/gbrain/bin/gbrain reinit-pglite \
  --path "$pglite" \
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
2. Take the backup above, under the no-writer precondition stated with it.
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
