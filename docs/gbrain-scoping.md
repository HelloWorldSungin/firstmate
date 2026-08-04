# Per-home GBrain scoping and read-only main-brain sharing

This operator reference owns how a Firstmate home scopes its own brain and how the main brain is shared with secondmate homes without letting them write it.
[`gbrain.md`](gbrain.md) owns the GBrain installation, archive, and rebuild procedure for a single brain, [`gbrain-endpoints.md`](gbrain-endpoints.md) owns the local embedding endpoint, [`configuration.md`](configuration.md) owns the configuration schemas, and [`verification/gbrain-readonly-share.md`](verification/gbrain-readonly-share.md) holds the dated evidence for the guarantees below.

## One brain per home

Every Firstmate home owns exactly one brain and writes only that brain.
A home's brain lives under `$FM_HOME/data/gbrain/`, with the runtime configuration in `runtime/`, the index in `pglite/`, and the markdown archive in `archive/`.
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
So the read-only share uses that native mechanism, and Firstmate adds no router of its own: no query fan-out, no result merging, and no Firstmate-side precedence engine.
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

That records the client id in the reading home's `config/gbrain-local.json`, writes the client secret to its `config/gbrain-secrets/` at mode 0600, and prints neither.
Once that registration succeeds it also records `main_brain_owner` in the granting home's own `config/gbrain-local.json`, because a home whose brain accepted the registration is by construction the brain the others read.
A registration the brain refused records nothing, so a refused grant leaves the granting home's local plane exactly as it found it.
That home reads its own index directly and never grants itself a client, so `bin/fm-gbrain.sh check` reports it as reading the main brain rather than as having lost access to it.
The reading home then mints a short-lived token with `bin/fm-gbrain.sh token` and calls the main brain's read tools with it.

Read operations succeed and every write-class operation is refused with `insufficient_scope`, enforced inside GBrain per operation rather than by a Firstmate convention.
Do not use `gbrain auth create` tokens or any legacy bearer token as a read-only credential: those carry no scope and are full-access.
Do not enable Dynamic Client Registration's consent-bypassing `client_credentials` variant to obtain one, because a self-registering client would choose its own scopes.

## Source precedence and name collisions

A home's own brain is the only thing it writes and the only thing its ordinary local search reads.
The main brain is a separate database, reached only through an explicit read over the shared client, so there is no implicit fan-out and no merged ranking to reason about.
Within a single brain, GBrain's own sources decide breadth: a federated source appears in cross-source default search, and an isolated source is searched only when named with `--source`.

Because the two brains are separate databases, a slug that exists in both is two distinct pages rather than a collision.
The local page is the one this home writes; the main brain's page is read-only and is addressed through the configured `main_brain.mount` name.
Keep that mount name stable across the fleet, since it is what distinguishes "the main brain's copy" from "this home's copy" wherever both are cited.

## Offline behavior

Local retrieval never depends on the main brain or on the hosted synthesis provider.
When the main brain is stopped or unreachable, the reading home's own search continues to answer from its own index, `bin/fm-gbrain.sh check` reports the main brain as degraded, and the run still exits 0.
When the MiniMax credential is absent or its endpoint is down, synthesis is unavailable and local search is unaffected, matching the single-brain behavior in [`gbrain.md`](gbrain.md).
A credential that is present but stored too loosely to use is the one credential-related condition that fails the check outright, because that is a finding rather than an outage.

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
