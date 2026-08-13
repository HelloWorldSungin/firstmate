# Per-home GBrain scoping and read-only main-brain sharing

This operator reference owns how a Firstmate home scopes its own brain and how the main brain is shared with secondmate homes without letting them write it.
[`gbrain.md`](gbrain.md) owns the GBrain installation, archive, and rebuild procedure for a single brain, [`gbrain-endpoints.md`](gbrain-endpoints.md) owns the local embedding endpoint, [`configuration.md`](configuration.md) owns the configuration schemas, and [`verification/gbrain-readonly-share.md`](verification/gbrain-readonly-share.md) plus [`verification/gbrain-retrieval.md`](verification/gbrain-retrieval.md) hold the dated evidence for the guarantees below.

## One brain per home

Every Firstmate home owns exactly one brain and writes only that brain.
A home's brain lives under `$FM_HOME/data/gbrain/`, with the runtime configuration in `runtime/`, the index in `pglite/`, and an `archive/` directory only when that brain is archive-fed.
[`gbrain.md`](gbrain.md#what-a-home-can-actually-rebuild-from) owns whether the durable document source is that archive or the capture outbox.
`GBRAIN_HOME` is that `runtime/` directory, so every GBrain call a home makes resolves that home's own configuration and index.

The location is derived from the home path rather than configured, which is what makes two homes impossible to collide by omission: a home that has never been configured still resolves a private brain.
A home that already runs a GBrain deployment elsewhere may point at it with `brain_root` in `config/gbrain-local.json`, which is home-local and never propagates.
Run `bin/fm-gbrain.sh paths` to see what a home resolves, and `bin/fm-gbrain.sh env` for the environment a GBrain call against it needs.

## Why GBrain's own model rather than a Firstmate router

GBrain has two orthogonal native concepts: a `mount` is a separate database reachable as `--brain <id>`, and a `source` is one repository within a single database, reachable as `--source <id>`.
The installed version's `mounts` support is its PR-0 stage and carries direct transport only: a mount entry names a PGLite directory or a Postgres URL, and `gbrain mounts add --mcp-url` is documented in that version's own help as not yet implemented.
A direct mount is therefore read-write by construction, because it hands the reading home filesystem or connection access to the served brain, and a PGLite brain additionally takes a single writer at a time, so a second attached process is a corruption and lock hazard rather than a read.
That version also resolves its mount registry from the UNIX user's home directory rather than from `GBRAIN_HOME`, so mounts are shared by every Firstmate home on one account, which is the opposite of per-home scoping.

GBrain's OAuth 2.1 server is shipped and does enforce read-only access: `gbrain serve --http` checks the required scope of each operation against the token's granted scopes and refuses the call with `insufficient_scope`.
So the read-only share uses that native mechanism, and Firstmate adds no access model of its own: no Firstmate-side scope check and no precedence engine deciding what a home may read.
[Reading a brain](#reading-a-brain) does query both corpora in one command and merge their results into one list, but only over what each brain already agreed to return.
When GBrain ships mounts over HTTP MCP with OAuth, a mount entry consumes the same read-scoped client registered here, so this is the forward-compatible shape rather than a parallel one.

## The three configuration planes

The planes are separate because they propagate differently, and merging them would either leak a credential downstream or point two homes at one brain.
All three live under a home's gitignored `config/`.

| Plane | File | Propagation | Holds |
| --- | --- | --- | --- |
| Shared | `config/gbrain.json` | inherited by every secondmate home | endpoints, model choices, the main brain's address, and the *names* of credentials |
| Home-local | `config/gbrain-local.json` | never inherited | this home's `brain_root` override, its own OAuth `client_id`, and `main_brain_owner` when this home's brain IS the main brain |
| Credentials | `config/gbrain-secrets/<name>` | never inherited | one credential per file, regular file, mode 0600 |

The shared plane has a closed schema, so it cannot carry what must not propagate.
An unknown field is refused rather than ignored, a `brain_root` or `client_id` is refused with the instruction to use the home-local file, a credential pasted where a credential *name* belongs is refused, and `main_brain.scopes` is refused unless it is exactly `read`.
A main-brain URL that would carry a client secret in plaintext to a non-loopback host is refused; a loopback `http://` endpoint is the ordinary single-machine shape and stays allowed.
The result is that the shared file can be inherited verbatim by any number of homes and still leave each of them writing its own brain.

Credentials follow the same restrictive-path precedent as `config/forge-tokens/<host>`: a credential that is a symlink, is not a regular file, or is readable beyond its owner is refused rather than quietly used, and the refusal names the file.
`bin/fm-config-inherit-lib.sh` carries `config/gbrain.json` and deliberately carries neither of the other two planes, so a rotation never copies a secret through inherited configuration.
The schema is checked at every boundary that copies the file rather than only where `bin/fm-gbrain.sh` later reads it: the local propagation path, the remote sender, and the remote receiver, which validates against its own code root rather than trusting the pushing one.
A credential pasted into the file is therefore refused before any home receives it and before it can be inlined verbatim into that home's config-reread instruction.

## Sharing the main brain read-only

The home that owns the main brain serves it over GBrain's own HTTP MCP transport with `gbrain serve --http`, bound to loopback by default.
Each reading home gets its OWN OAuth client, registered with the single scope `read` and the `client_credentials` grant, so access can be revoked for one home without disturbing another:

```sh
FM_HOME=<main-home> bin/fm-gbrain.sh grant-read <label> --home <reading-home>
```

That records the client id in the reading home's `config/gbrain-local.json` and writes the client secret to its `config/gbrain-secrets/` at mode 0600, reporting the new client id and the credential's path but never the secret itself.
Once that registration succeeds it also records `main_brain_owner` in the granting home's own `config/gbrain-local.json`, because a home whose brain accepted the registration is by construction the brain the others read.
A registration the brain refused records nothing, so a refused grant leaves the granting home's local plane exactly as it found it.
That home reads its own index directly and never grants itself a client, so `bin/fm-gbrain.sh check` reports it as reading the main brain rather than as having lost access to it.
The reading home then mints a short-lived token with `bin/fm-gbrain.sh token` and calls the main brain's read tools with it, which is what [Reading a brain](#reading-a-brain) does for a worker.

Read operations succeed and every write-class operation is refused with `insufficient_scope`, enforced inside GBrain per operation rather than by a Firstmate convention.
That refusal bounds what a reading home can store, not everything it can spend: `think` is a read-scope operation, so a read-only holder reaches hosted synthesis on the serving home under the serving home's model and credential, which is why a serving home carries no such credential ([`gbrain.md`](gbrain.md#a-home-serving-a-main-brain-carries-no-hosted-synthesis-credentials) owns that rule, its reason, and the bounded check that now enforces it).
Do not use `gbrain auth create` tokens or any legacy bearer token as a read-only credential: those carry no scope and are full-access.
Do not enable Dynamic Client Registration's consent-bypassing `client_credentials` variant to obtain one, because a self-registering client would choose its own scopes.

## Reading a brain

`bin/fm-recall.sh` is the retrieval surface firstmate and every crewmate use, and no worker calls a raw GBrain command.
The wrapper exists because a raw call resolves whatever brain the caller's directory implies, and because GBrain returns a placeholder answer and exit 0 when it has no usable model, so a raw `think` reports a non-answer as an answer.
Its `--help` owns the flags, the caps, and the `fm-recall.v1` document it prints; what follows is only the part an operator has to know.

`search` reads this home's own index and, when the main brain is configured and this home holds a read-only client, the main brain's index too, labelling each result `local:<slug>` or `main:<slug>`.
`think` is a separate command rather than a flag, because it sends the question and the excerpts it selects to the configured hosted provider.
It runs only against this home's own brain because the wrapper calls it there and never over the main brain's client, which is construction rather than convention.
That construction is now the whole of the guarantee: `v0.42.76.0` reclassified `think` as `scope: read`, so a read-scoped client is admitted rather than refused, and what still makes the share read-only is the write-class refusal above, which `think` no longer belongs to.
The hosted-synthesis boundary that scope check used to cover is now an operating rule in [`gbrain.md`](gbrain.md), measured in [`verification/gbrain-memory-verbs.md`](verification/gbrain-memory-verbs.md).

The home a command reads is resolved from `--home`, then `FM_HOME`, then the directory the wrapper was invoked from, and a candidate that is a source checkout rather than an operating home is refused by name.
That refusal matters because a crewmate on a firstmate task stands in a worktree of this repository: without it, the wrapper would build an empty brain inside a directory that cleanup is about to delete and report success while doing it.

Each corpus a search reads, and hosted synthesis, are reported as separate facts and never as one outcome.
A main brain that is stopped, unreachable, or not shared with this home reads as a degraded source and does not fail a run that also read this home's own index, so a home's own memory never depends on another home being up.
The same independence runs the other way: a home with no GBrain installed reports its own index as failed and still reads the shared corpus, which needs only `curl` and a token.
A search fails as a retrieval failure only when no corpus it was asked for could be read at all, so an empty result list with exit 0 means at least one requested corpus was read and had no match, and the per-source rows say which were read and which were not.
A run that could not create its own working files is the third state and exits 5 instead: no corpus was ever asked there, and reporting it as a corpus that did not answer would send you to your brain for a fault in the environment the command ran in.
A hosted provider that is unusable fails on its own, and the refusal names `search` as the path that still works.

A crewmate learns this from its brief rather than from memory: `bin/fm-brief.sh` adds one instruction naming the command, the citation label, and the hosted-provider boundary, and adds it only when the home actually has an index, so a fleet with no brain carries no dead pointer.

## Source precedence and name collisions

A home's own brain is the only thing it writes, and a GBrain call against that home reads that brain alone.
The main brain is a separate database reached only over the shared read-only client, so the two are never one index: `bin/fm-recall.sh search` reads each on its own terms and merges the results into one list, which is why every result carries its `local:` or `main:` label.
The merge preserves each brain's own ordering and interleaves the two by rank: the first result of each corpus, then the second of each, cycling in the order the corpora were read, so this home's own index leads on an equal rank and a corpus that runs out simply drops out.
It does not sort on the score column, for two independent reasons.
A brain's returned order is its own verdict rather than that column: reranking runs inside the brain, so its ordering carries a contribution the score does not expose, and re-sorting discards it.
And two brains' scores are not the same quantity, because each has its own embedding model, reranker, and corpus, so comparing them ranks on a number that only looks shared.
A rank therefore compares two brains' own opinions of their own results rather than a Firstmate-computed relevance, and a printed score explains one row within its corpus rather than ordering across corpora.
A single-corpus search is the same rule with nothing to interleave, so it returns exactly what that brain returned.
Within a single brain, GBrain's own sources decide breadth: a federated source appears in cross-source default search, and an isolated source is searched only when named with `--source`.

Because the two brains are separate databases, a slug that exists in both is two distinct pages rather than a collision.
The local page is the one this home writes, and the main brain's page is read-only, reached over `main_brain.mcp_url` with the read-scoped token.
`main_brain.mount` names that remote brain: today it is the fleet-wide label that distinguishes "the main brain's copy" from "this home's copy" wherever both are cited, and it is the mount id a future GBrain mount entry would carry once mounts can hold an OAuth client.
Keep it stable across the fleet for both reasons.

## Offline behavior

Local retrieval never depends on the main brain or on the hosted synthesis provider.
When the main brain is stopped or unreachable, the reading home's own search continues to answer from its own index, `bin/fm-gbrain.sh check` reports the main brain as degraded, and the run still exits 0.
A search asking for the main corpus alone with `--scope main` has no local half to fall back on, so the same outage fails that run with exit 3 rather than reporting an empty result list as an answer.
When the MiniMax credential is absent or its endpoint is down, synthesis is unavailable and local search is unaffected, matching the single-brain behavior in [`gbrain.md`](gbrain.md).
A credential that is present but stored too loosely to use fails the check outright instead of degrading it, because that is a finding rather than an outage.
So does a serving home whose own declared configuration makes hosted synthesis reachable, which no outage explains either ([`gbrain.md`](gbrain.md#a-home-serving-a-main-brain-carries-no-hosted-synthesis-credentials) owns that rule, the surfaces the check reads, and the ones it does not).

## Rotation, revocation, and retirement

Rotate a reading home's access in one step, which installs the new client before revoking the old one:

```sh
FM_HOME=<main-home> bin/fm-gbrain.sh grant-read <new-label> --home <reading-home> --replace
```

Revoking a client cascades to its issued tokens, so a rotated-away token stops working rather than lingering until it expires.
Revoke without replacing with `bin/fm-gbrain.sh revoke-read <client-id>`.

Registering and revoking are database writes, and a PGLite brain takes one writer at a time, so both are refused while `gbrain serve` holds that brain.
Stop the served main brain, run the rotation, then start it again; the refusal is safe, leaving the reading home's previous client and credential exactly as they were.

Retiring a secondmate revokes its client and removes its credentials and its own brain:

```sh
FM_HOME=<main-home> bin/fm-gbrain.sh retire <retiring-home> --yes
```

Retirement removes only what this tool creates: the retiring home's `config/gbrain-secrets/` and the `runtime/`, `pglite/`, and `archive/` directories it derives under that home's brain root.
The brain root itself is left in place, because a configured `brain_root` may name a GBrain deployment Firstmate did not create and whose neighbours are not Firstmate's to delete.
A path that is not a plain directory this tool would have created is refused rather than guessed at, and nothing is removed until every path has passed that check.

Revocation happens first and a revocation that fails stops the retirement with nothing removed, because a home whose local record of the credential is gone while its client still reads the main brain leaves access no one can find again.
Re-run the command once the reported cause is cleared, most often a served main brain holding the single-writer lock.

This destroys that home's index, so it refuses without `--yes` and belongs with the rest of the retirement decision in [`.agents/skills/secondmate-provisioning/SKILL.md`](../.agents/skills/secondmate-provisioning/SKILL.md), never as a routine cleanup.
