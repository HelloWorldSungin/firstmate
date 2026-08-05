# Dispatched-model verification

This document is the authoritative human-readable contract for checking that a dispatched worker actually ran on the model firstmate recorded for it.

The shipped mechanism is `bin/fm-model-verify.sh`, a read-only verifier surfaced through `bin/fm-fleet-snapshot.sh` and `bin/fm-fleet-view.sh`.
It is unrelated to the delegation fence in [`subagent-guard.md`](subagent-guard.md), which stops a primary from creating work the fleet never sees.
This one assumes dispatch happened correctly and asks a different question: did the worker run on the tier it was dispatched with?

## Why this exists

Firstmate resolves a concrete model and effort at intake, sometimes after a deliberate quota-balanced choice across candidate profiles, and `bin/fm-spawn.sh` records `model=` in `state/<id>.meta`.

That record is what was **requested**.
Nothing verified what **ran**.
A worker served below its dispatched tier still reports done, and the record still reads as the intended model, so every later quota-aware dispatch decision built on that record is fiction.

The failure class was reproduced one level down, in the harness's own subagent routing, and documented in the 2026-07-28 investigation.
Model resolution there is explicit model, then the named subagent type's own definition frontmatter, then the parent - so a contract assuming an omitted model inherits the parent is wrong about the middle clause.
Real transcripts on the development host showed an Opus 4.8 parent's omitted-model dispatch running on Sonnet 5, and a Fable 5 parent's running on Opus 4.8.
Other dispatches in the same sample did inherit correctly, which is what makes the class dangerous: it is right often enough to look right.

## Where the check belongs

Three placements were considered.

- **At spawn time.** Rejected: at spawn the worker has produced no turn, so there is nothing to compare against. Verification is necessarily after the fact.
- **In a `PostToolUse` guard.** Rejected as the primary mechanism: that surface observes `resolvedModel` for the harness's own delegation tool, which a firstmate primary already denies, and it never observes a `bin/fm-spawn.sh` dispatch - the record actually at risk. The empirical work behind that lever is recorded in [`verification/model-verification.md`](verification/model-verification.md) and stays available if the delegation surface ever needs its own check.
- **Folded into `bin/fm-crew-state.sh`.** Rejected: that helper owns one contract, reconciling a crew's current run state. Model provenance is orthogonal to run state.

The shipped placement is a standalone verifier rendered by the structured fleet snapshot, which firstmate already reviews every heartbeat, and required by non-forced teardown before any evidence or task metadata is removed.

## Evidence

The evidence is the harness's own session transcript.
The runtime writes it, the agent never authors it, and it records the model that served each assistant turn.
This matters more than convenience: a check that asked the worker what it ran on would be asking the one party that cannot see the answer and has every incentive to report the requested tier.

Only a harness with an empirically verified evidence source is ever treated as verifiable.

| Harness | Evidence source | Status |
| --- | --- | --- |
| Claude | `<transcript-store>/projects/<encoded-cwd>/<session>.jsonl`, `.message.model` per assistant record | Verified and wired. |
| Codex, OpenCode, Pi, Grok, Kimi | not established | Reported `unverifiable`, never assumed correct. |

`<transcript-store>` is the canonical `model_evidence_store=` persisted in the dispatch record.
`bin/fm-spawn.sh` resolves symlinks and parent components in filesystem order for `$CLAUDE_CONFIG_DIR` when set, else `~/.claude`, and records that physical transcript-store identity before launch.
When firstmate has an explicit `$CLAUDE_CONFIG_DIR`, spawn forwards it so the worker uses the same credential, config, and transcript store even though the pane daemon does not inherit firstmate's environment.
When the variable is unset or empty, spawn does not export it: Claude's default config comes from `~/.claude.json`, while transcript evidence remains under `~/.claude`.
If the resolved physical path contains a newline, canonicalization fails and spawn refuses before serializing or launching with an altered store.
Later verification never replaces that recorded store with the verifier process's ambient configuration.
The directory name encodes the worker's working directory with every character outside `[A-Za-z0-9]` replaced by `-`.

The bounded follow-up for the unverified harnesses is the same shape as the Codex procedure in [`subagent-guard.md`](subagent-guard.md): on a host with the binary installed, establish where that harness records the serving model, then add an adapter and extend the verification record.
Wiring an unvalidated evidence path would trade a known gap for a false verdict, which is worse than the gap.

## Verdicts

A verdict is never `match` unless a model was actually read and actually compared.

| Verdict | Meaning | Exit |
| --- | --- | --- |
| `match` | every model attributed to this worker satisfies the record | 0 |
| `mismatch` | at least one attributed model does not | 3 |
| `unverifiable` | the record cannot be checked at all | 4 |
| `unstarted` | beneath an inspectable recorded evidence store, the runtime wrote no transcript parent at all or no session path entry for this worker, so it has no evidence of its own | 4 |
| `unarmed` | verification was never armed for this dispatch, so no verdict can ever exist for it; the predicate below owns the exact record shape | 4 |
| `pending` | a session exists and the worker has not produced a model-attributed turn yet | 0 |
| `unpinned` | `model=default`: no tier was pinned, so there is no record for the runtime to contradict | 0 |

`unstarted`, `unarmed`, `pending`, and `unpinned` are explicitly no-verdict outcomes, not passes.
Nothing may render them as verified.
Only the exact record `model=default` is unpinned.
A missing or empty `model=` is malformed dispatch metadata and therefore `unverifiable`.

`unverifiable` covers a harness with no evidence adapter, a recorded evidence store that is malformed, missing, or inaccessible, a transcript parent or session path entry that exists as a non-directory or broken symbolic link or is inaccessible, evidence that cannot be read, `jq` absent, a durable record that names no working directory, and evidence that cannot be attributed to this dispatch.
`unstarted` is separated from it because the two ask different questions of a caller: evidence that exists or may exist behind an uninspectable path may belong to a worker that ran, while a genuinely absent transcript parent or per-worktree session path entry beneath an inspectable store has no turn of its own to read at all.
`unarmed` is separated from both, and is the one no-verdict outcome that is decided by the shape of the dispatch record rather than by anything on disk.
It is also the only narrowing this guard makes, so its predicate is stated in full here and nowhere else; every other mention of it in this repository cross-references this section rather than restating any part of it.

**A dispatch is `unarmed` when all three of the following hold, and `unverifiable` when any one of them fails.**

1. The record names no `model_evidence_store=`.
2. The record carries no arming marker, meaning no `model_evidence_watermark=` line and no `model_evidence_before=` line.
3. The record is not a remote secondmate route record, meaning `kind=secondmate` together with any of `remote_host=`, `remote_root=`, `remote_backend=`, or `remote_target=`.

A missing store line is the shape of a never-armed record, but absence alone does not prove it, because a pre-guard record is a strict subset of today's schema and so carries no positive "never armed" marker of its own.
Conditions 2 and 3 supply that proof, and they are kept separate because they prove different things.
An arming marker fails condition 2: `capture_claude_watermark` emits `model_evidence_store=` and `model_evidence_watermark=claude-transcript-v1` together on both of its success paths, along with its `model_evidence_before=` rows, and `bin/fm-spawn.sh` appends that block whole, so either marker present without a store proves that the capture ran and the record was damaged afterwards.
A remote route fails condition 3: `spawn_remote_secondmate` writes `kind=secondmate` with those route fields and no store line for a secondmate that DID launch and run, and its armed record lives in that remote host's own state, so its evidence is not absent, only unreadable from this home.
Each of those two shapes therefore keeps the blocking `unverifiable` verdict, and the release rests on positive proof rather than on absence alone.
`bin/fm-spawn.sh` writes `model_evidence_store=` for every Claude dispatch it launches and exits 1 without rendering a launch command when that capture fails or omits the store, so a record satisfying all three conditions can only be a dispatch that predates the guard or a spawn that aborted before launching anything, and neither ever ran.
Only such a record can have produced no evidence attributable to the task, so only there is there no verdict to fail, no evidence location to protect, and nothing any later event could ever supply.
That is a gap in the record, not a safety signal, and the separation is drawn from what the record itself establishes rather than from a dispatch timestamp a future record could also carry.
A store line that is present and unusable - malformed, missing on disk, or unreadable - fails condition 1, so it is a damaged armed record, stays `unverifiable`, and keeps blocking.
`unarmed` never authorizes reading an ambient store: an unknown evidence location is never resolved against whatever the environment happens to point at, because that would attribute another dispatch's transcripts to this task.
None of these is a pass, and all exit 4.
This is the load-bearing design rule: **a guard that silently passes when it cannot read the truth is worse than no guard, because it manufactures false confidence.**
Every unreadable path therefore ends in `unverifiable`, never in silence and never in `match`.

## Comparison granularity

A record is compared at the granularity it expresses.

- A bare family alias (`opus`) promises a tier, so any member of that family satisfies it.
- A specific model id (`claude-opus-4-8`) promises that model, so another version of the same family is a mismatch.

The runtime appends a context-window suffix such as `claude-opus-5[1m]`; it names the same model and is stripped before comparison.
`<synthetic>` is a runtime placeholder for messages no model served.
It names no model, so it is dropped: it can neither manufacture a mismatch nor stand in as evidence of a match.

## Binding evidence to one dispatch

Before launching Claude, `bin/fm-spawn.sh` records the canonical `model_evidence_store=`, `model_evidence_watermark=claude-transcript-v1`, and one `model_evidence_before=` row for every transcript identity already present in the worker's transcript directory.
The endpoint, worktree, requested model, and dispatch timestamp are published first, so watermark failure leaves a recoverable durable record rather than an unowned live endpoint.

A worktree drawn from a reusable pool can still carry the transcripts of a previous occupant, whose model would otherwise be attributed to the current task.
The verifier excludes exactly those identities, so a prior transcript and the new worker's transcript remain distinguishable even when both files share the one-second modification timestamp recorded by the filesystem.

`spawned_at=` remains as a compatibility anchor for records that have a persisted evidence-store identity but no identity watermark.
A transcript whose modification time equals that legacy anchor is ambiguous and therefore `unverifiable`, never a match.
A present but empty or nonnumeric `spawned_at=` is malformed and therefore `unverifiable`; only a genuinely absent field enters weaker legacy attribution, and only when the persisted store still binds the evidence location.
A record with no persisted evidence-store identity has an unknown evidence location, so the verifier reads no ambient Claude store, and it reports `unarmed` only when the `unarmed` predicate under Verdicts holds in full.
That record was never armed for this check, so the check itself does not block its cleanup: it names the gap plainly and hands the task to the ordinary teardown path, where the landed-work, uncommitted-change, completion-manifest, and endpoint-identity refusals all still apply unchanged.
Nothing is discarded by that hand-off which the check was ever protecting: teardown removes the task's own volatile records and, once the landed-work proof passes, its worktree, and it never touches a transcript store.
The metadata it removes carries no binding to any evidence, which is exactly why no verdict could ever be produced from it.
This replaces an earlier rule under which such a record was untearable without `--force`.
That rule made a historical gap permanent: nothing that happens after dispatch can retroactively record which model ran, so every affected task kept a live endpoint and a recurring staleness escalation forever, and the set only grew.

A record with a persisted evidence-store identity but written before either time binding existed cannot be time-bound.
In that case unanimous evidence from the recorded store is still attributed, with the weaker binding disclosed in the detail text, and disagreeing evidence is reported `unverifiable` rather than guessed at.

## Surfacing

`bin/fm-fleet-snapshot.sh` carries `model:{verdict,recorded,actual[],source,detail}` per task.
An unreadable or absent verifier answer becomes an explicit `unverifiable` verdict there, so a broken verifier can never render as a clean one.

`bin/fm-teardown.sh` always runs terminal verification before cleanup, and always surfaces the verdict, so no worker's model provenance is discarded unseen.
Only the refusal is conditional.
Terminal verification returns a blocking status on `mismatch` always, and on `unverifiable`, `unstarted`, or `pending` only when the dispatch was verifiable in principle: a harness with an evidence adapter, a pinned model, and a record the `unarmed` predicate under Verdicts does not accept.
A dispatch missing an evidence adapter or a pinned model, or one that predicate does accept, was never armed for the check and is never blocked by it; every other dispatch keeps blocking on every one of its failure modes.
Teardown states the never-armed case explicitly in its output, so an operator can tell it apart from a verification that ran and failed without reading source.
That explicit line is the discriminator, and it says every other cleanup check still applies.
An unarmed task takes the ordinary cleanup path, so any other check may still refuse in the same output; the absence of a refusal therefore says nothing about which case the operator is in.
Non-forced teardown ordinarily turns that status into a refusal that preserves the worktree, transcript evidence, and task metadata for inspection, subject only to the narrow proven-no-turn path and its unknown-liveness retention rule below.
Refusing whenever a verdict was absent would make non-forced cleanup impossible for every harness that can never produce one, which is a fleet-wide regression rather than the boundary this refusal exists to draw.

One further boundary sits inside that refusal, for the same reason.
For a worker with an `unstarted` or `pending` result, retained records alone cannot create the absent first model-attributed turn, so retaining a task that is no longer authoritatively live can become permanent rather than protective and strand the endpoint name it holds.
Non-forced teardown therefore proceeds for such a task when its recorded worktree independently proves there is nothing to preserve: inspectable, on no branch, with no `refs/heads/fm/<task-id>` task branch, carrying no commit that no existing local or remote-tracking branch already contains, and clean after enumerating every untracked file, including ignored files, apart from `.claude/settings.local.json`, `.opencode/plugins/fm-turn-end.js`, `.opencode/plugins/fm-busy-state.js`, `.fm-grok-turnend`, and `.fm-kimi-turnend`, which `bin/fm-spawn.sh` writes itself.
Before that allowance reaches record removal, teardown consults the recorded backend's strongest available liveness evidence, attempts the existing best-effort endpoint close when no live worker is authoritatively reported, and then recomputes the terminal model-routing verdict and complete on-disk proof immediately before cleanup.
The allowance requires four backend-independent protections to hold together: no model-attributed turn, no current or task branch and no commit of the worker's own, no tracked or staged modification, and no untracked file, whether ignored or non-ignored, beyond the exact harness-owned allowlist.
A recovery-grade classifier that authoritatively reports a live worker refuses and preserves the endpoint, worktree, and metadata.
A recovery-grade `dead` or `missing` result permits the best-effort close and on-disk proof to decide, while `ambiguous`, `unreadable`, or `unverified` liveness is stated plainly and does not become either a safety proof or a permanent block.
A turn or worktree change observed by the recomputation refuses under the ordinary terminal-verdict and work-preservation rules.
When liveness is unknown after the no-turn condition is proven, task cleanup publishes the durable outcome and removes the volatile task records, but retains the worktree and task temp root rather than resetting, returning, removing, or recycling them.
The teardown output names that retained worktree and the unknown liveness reason, leaving any later committed or uncommitted write recoverable.
A recorded-but-unusable evidence location is different: it cannot prove the no-turn condition at all, so non-forced teardown refuses outright and preserves both the worktree and task metadata for inspection.
An `unarmed` record never reaches this allowance at all, because the terminal check does not report it as blocking; it takes the ordinary cleanup path instead, which keeps every other refusal intact rather than substituting this narrower proof for them.
The residual gap pending separately tracked confirmed-termination support is one possible unverified model attribution: a worker can begin its first turn after the final recomputation, and neither a best-effort endpoint close nor an authoritative `dead` or `missing` liveness verdict claims that writes have stopped or termination was confirmed.
The absent verdict is stated plainly in the teardown output either way.
Both halves are required for recycling and both are read from evidence rather than a flag: a worker whose recorded evidence shows that it ran without a usable verdict keeps refusing even on a spotless worktree, and any change visible to the worktree proof or unlanded commit keeps refusing even when no turn was ever taken.
Forced teardown surfaces the verdict but retains its existing authority to discard, including for every recursively cleaned secondmate child.

`bin/fm-fleet-view.sh` renders a `## Model Routing` section listing every task whose verdict is `mismatch`, `unverifiable`, `unstarted`, or `unarmed`.
It deliberately omits `pending` because every healthy worker is briefly pending before its first model-attributed turn, and a routine false alarm would make the section less useful.
The residual gap is explicit: a worker whose runtime opened a session it never took a turn in remains `pending` and is not raised in the human fleet view, while its no-verdict state remains visible in the structured snapshot's per-task model object and enters the non-forced teardown refusal path when that dispatch was verifiable in principle, subject to the no-turn boundary above.
`unstarted` is listed rather than omitted, because a dispatched worker whose runtime wrote no session at all is not the routine transient state `pending` is.
`unarmed` is listed for the same reason: its cleanup is no longer blocked, but the dispatch still has no verifiable model provenance, and it stays visible until the task is cleaned up.
Deliberate `unpinned` dispatches are also omitted, and correctly routed work therefore looks exactly as it did before.

## Automated validation

`tests/fm-model-verify.test.sh` owns the acceptance matrix and is registered in the `pure-contract-unit` family in `bin/fm-test-run.sh`.
It covers family-alias and pinned-id comparison, the context-window suffix, a downgrade below the dispatched family, a mid-dispatch model change where one value still matches, enumeration and modification-time failures, the `pending`, `unstarted`, and exact-`default` `unpinned` outcomes, missing model metadata, malformed timestamps, canonical evidence-store binding across ambient configuration changes, symlink-plus-parent paths, and newline-bearing physical paths, the synthetic placeholder in both directions, exact transcript-identity binding including the equal-second boundary, legacy timestamp binding, secondmate evidence resolved from its own home, `--all` exiting on the worst verdict, and the structured output.
It also owns the `unarmed` boundary at verifier level: a record the `unarmed` predicate accepts reports `unarmed` at the same exit severity as every other no-verdict outcome while not blocking terminal cleanup, never resolves against an ambient store or attributes its transcripts, and a recorded store that is missing, unreadable, or malformed stays `unverifiable` and keeps blocking in terminal mode.
The same file pins each way that predicate can be failed, so it cannot survive only in prose: with no store line, a record carrying `model_evidence_watermark=`, a record carrying a `model_evidence_before=` row, and a `kind=secondmate` record carrying the remote route fields each report `unverifiable` rather than `unarmed` and each keep blocking terminal cleanup.

`tests/fm-fleet-snapshot-view.test.sh` covers the snapshot field and the view section, including that a correctly routed fleet renders no section and that an `unarmed` dispatch stays listed with no attributed model.
It also proves that bounded secondmate-home summaries do not scan model transcripts.

`tests/fm-spawn-dispatch-profile.test.sh` covers durable metadata publication before watermark capture, preservation when capture fails, explicit config forwarding over a backend daemon's ambient configuration, default config discovery without conflating it with the transcript store, and refusal before launch for a newline-bearing physical store.

`tests/fm-teardown.test.sh` covers terminal refusal before cleanup on a mismatch, unchanged teardown on a match, forced surfacing without loss of discard authority, and recursive child surfacing.
It also owns the never-started boundary: both no-turn shapes and a fresh inspectable store with no transcript parent tearing down on a worktree with nothing to lose while still reporting the absent verdict, and continued refusal for an uninspectable evidence store or transcript path, uncommitted changes including ignored files and any non-allowlisted file under `.claude/`, a surviving task branch even with detached clean HEAD, commits on a task branch, a worker that ran on unattributable evidence with a clean worktree, and a first mismatched turn produced during the best-effort close before the final recomputation.
The same coverage proves that each on-disk protection refuses independently, all protections together permit cleanup, authoritative live-agent evidence refuses, authoritative dead-agent evidence recycles normally, and unknown liveness completes record cleanup with explicit disclosure while retaining the worktree and task temp root.

It owns the never-armed boundary in the same file, because narrowing a safety refusal is only as good as the proof of what still refuses.
A record the `unarmed` predicate accepts tears down when its work has landed and its worktree is spotless, without attributing or deleting a mismatching ambient transcript for that same worktree, and states the never-armed case in its output.
On that exact record shape, teardown still refuses for uncommitted changes, for unlanded commits, for a completion manifest that cannot be published, and for an endpoint that does not validate.
The paired cases pin the boundary that must not move: the same landed, spotless fixture with a recorded evidence store and a failing verdict keeps refusing, as does a recorded store with a damaged dispatch anchor, and so does a record carrying an arming watermark but no store.
The remote secondmate route shape is pinned at verifier level only, because `bin/fm-teardown.sh` routes a genuine remote secondmate to its own teardown before the model check ever runs, so a teardown fixture for it could only be faked.

Run:

```sh
bin/fm-lint.sh
tests/fm-model-verify.test.sh
tests/fm-fleet-snapshot-view.test.sh
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-teardown.test.sh
```
