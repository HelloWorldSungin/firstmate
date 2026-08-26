# 0002 - Make internal `/stow` a reset-safe session handoff

- Status: proposed
- Date: 2026-08-26
- Deciders: firstmate under the design interview authority, with the worker supplying repository evidence and recommendations

## Context

The home operator invokes the pass near-daily at session end, immediately before clearing context.
The internal skill currently combines session knowledge capture, open-record persistence, a complete startup-memory curation pass, a primary-to-secondmate cascade, and a reset-safety receipt.
Its trigger also permits periodic mid-session use.

The primary home's startup memory was exactly full at observation time.
On 2026-08-26 in the primary home, `bin/fm-startup-memory-budget.sh report` reported 7,500 estimated tokens against an effective budget of 7,500.
Every new startup-memory admission must therefore displace, consolidate, or offload something.

The primary home's cold archive shows repeated archival activity, not total stow cadence.
On 2026-08-26 in the primary home, inspection of `data/memory-archive.md` counted eight dated archival-pass headings from 2026-08-15 through 2026-08-26, including two headings dated 2026-08-19.
The stow contract creates such a heading only when a pass archives an entry, so eight is a lower bound on full passes rather than a pass-cadence measurement.
No durable per-pass ledger was available, and this ADR makes no claim about total stow cadence.
On 2026-08-26 in the primary home, `config/stow-pass-horizon` was observed present, so the current memory contract advances decay by both wall-clock age and unreinforced curation passes.

The brain and startup memory serve different retrieval moments.
On 2026-08-26 in the primary home, the capture outbox inventory exposed by `bin/fm-gbrain-capture.sh status --json` counted 302 archived documents: 41 notes and 261 task records.
That same dated primary-home inventory counted 30 of the 41 notes with a `source.id` in the `learnings-pruned-*` or `captain-reference-pruned-*` families, which demonstrates that `/stow` currently feeds the brain mainly when knowledge leaves startup memory.
The brain has no aggregate startup-style token allowance, while each captured body is independently bounded and redacted by the capture pipeline.
The dashboard's Knowledge page provides bounded, read-only search over the resulting corpus.

### Private-home evidence boundary

Each operational observation in this ADR names what was counted, its source, its date, and the primary home in which it was observed.
The underlying `data/`, `state/`, and `config/` content is captain-private and gitignored, so this shared ADR records only those dates, counts, shapes, and source names rather than copying a replay snapshot, record body, or configuration content.
The observations establish the design context on 2026-08-26 and are not claims about another home or a later date.

## Decision

### D1. One internal skill owns the handoff

The internal `/stow` skill remains the single owner of both session handoff and startup-memory curation.
It is redefined around that end-of-session transaction.
Startup-memory curation and the primary home's secondmate cascade remain phases inside that one owner.
They do not become a second user-facing skill or command whose invocation order a future session must remember.
The full path runs the existing complete startup-memory pass and the primary home's cascade rather than weakening either contract.

The same owner must also support real mid-session use without charging every invocation for the full end-of-session transaction.
The path-selection signal and the guarantees of that lighter path are decided separately below.

This keeps the reset-safety claim under one contract.
A split would make the claim depend on coordination between two skills and would expand the scoped redefinition into a second command.

### D2. Capture retrieval-worthy session knowledge before memory projection

The end-of-session path captures durable, retrieval-worthy findings into this home's brain as a first-class step.
It then projects only the actionable, must-be-present subset into startup memory.
Capture no longer waits for a learning to lose its startup-memory slot.

The admission test is whether a future session would need to find the knowledge after this conversation is gone and would otherwise have to re-derive it at meaningful cost.
An event is not admissible merely because it happened or occupied substantial session time.
Each admitted note is one coherent finding with enough evidence and context to be useful independently, not a chronological session summary.

First-class note capture also needs the per-candidate round-trip guard already decided by [ADR 0001 D5](0001-brain-read-mount.md#d5-stow-mounts-a-round-trip-read---advisory-ungated-with-a-hard-constraint).
That ADR remains the owner of the advisory-search, content-comparison, and conclusion-record contract.
Implementation applies the owned guard to every prospective new session note so repeated discovery updates an equivalent logical finding instead of accumulating dated duplicates, and this ADR does not restate the mechanism.

Transcripts, volatile state, open work, secrets, uncertain claims, and facts already held by a stronger live owner are refused.
`AGENTS.md` section 6 remains the single owner of the knowledge-routing table that determines the stronger destination.
This ADR does not reproduce that table.
Open work continues through its durable record owner rather than entering the brain as knowledge.
[`docs/gbrain-capture.md`](../gbrain-capture.md) remains the owner of capture inputs, body bounds, redaction, refusal, delivery, and retry behavior.

Every captured session note is a dated snapshot and carries its as-of date in the note's content and capture provenance.
It is evidence of what was established at that date, never an assertion about current repository, forge, fleet, or hardware state.
[`bin/fm-recall.sh`](../../bin/fm-recall.sh) remains the owner of retrieval framing, source-state vocabulary, staleness reporting, and the rule that a live source wins.
The note must not be phrased as current control-plane truth that only a live check could establish.

Startup memory becomes the bounded projection of what a session must be able to act on before it knows to search.
An entry kept there carries the actionable preference, authority boundary, safety rule, or frequently needed operating fact itself.
A bare pointer that only says to search is not a sufficient projection.

The 7,500-token startup-memory allowance is a ceiling, not a target occupancy.
Curation preserves headroom when it can do so without losing an actionable must-be-present entry.
Freed capacity is not an invitation to admit lower-value material.

### D3. Invocation intent selects a full or light path

`/stow` defaults to the full end-of-session path.
The light path is selected only by an explicit statement that the session will continue.
The canonical short form is `/stow light`, and any unambiguous plain-language equivalent such as "stow, but keep working" has the same meaning.
There is no magic phrase beyond the expressed continuation intent.
An absent or ambiguous signal selects full.
Neither path runs automatically through a daemon or hook.
Both remain captain-invoked uses of the skill.

The explicit invocation supplies the pacing signal.
The worker does not self-assess context pressure.

The light path captures and routes the session's retrieval-worthy findings under D2.
It also files or corrects open records that this session actually knows are missing or wrong.
It does not scan all startup memory, advance decay, run the secondmate cascade, or claim that the session is reset-safe.
Its receipt says that the checkpoint is complete for the session knowledge and named record changes it processed, and that a full `/stow` remains required before clearing context.
It runs the startup-memory budget report without interpreting every memory entry, and any rejected setting, rejected file, or over-budget result triggers visible promotion to full.

Light promotes to full when it discovers a must-be-present startup-memory change, an invalid memory setting or file, or a memory total above its effective budget.
The promotion is reported before the full-only work begins, naming the trigger.
It is never silent.

The pass horizon does not advance on a light invocation.
Its counter represents passes that evaluated an entry without reinforcement, and the light path evaluates no complete memory file.
Advancing it would record an evaluation that never happened.

#### Dated portability check

The execution-path selector does not depend on a cross-harness context-pressure reading because a 2026-08-26 portability review in the primary home found no such shared Firstmate adapter contract.
That review read nine tracked primary-harness adapter variants through `bin/fm-harness-adapter-doc.sh`.
It inspected the tracked primary-session, compaction, and adapter surfaces for context-window, remaining-token, usage, and compaction signal shapes.
It also inspected five installed harness help surfaces and four tracked-only adapter surfaces.
The inspected surfaces exposed product-specific configuration or display facts but no Firstmate helper or adapter contract that reports comparable live context pressure across all nine supported primary harness variants.
This is a dated absence observation, not a permanent claim about later tracked adapters or installed harness releases.

### D4. `/stow` does not reconcile durable records against live reality

Neither execution path performs a repository, worker, tracker, project-board, or forge reality sweep.
It files records that do not yet exist and corrects records this session already knows are wrong.
When the correction requires a judgment the session cannot make, it leaves the record unchanged and persists the question through the existing owner.

Record rot is a measured problem rather than a reason to widen `/stow`.
On 2026-08-26 in the primary home, a manual review inspected every card then visible on the rendered Bearings board across Captain's Call, Recently Landed, Underway, and Charted Next: approximately 40 cards, with three dead premises recorded in `data/learnings.md`.
The inspected population was the board as rendered at that moment, excluding suppressed deferred or superseded rows and completions outside its bounded current Recently Landed baseline.
The check belongs after the handoff gap, where it can observe the state the new session will act on, rather than immediately before a gap in which that state can change again.

Existing owners retain the concern.
`AGENTS.md` section 8 owns the judgmental heartbeat review of the whole structured fleet view, including suspicious task and PR state and the resulting backlog correction.
[`bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh) owns the deterministic current-state read for a recorded worker, while [`bin/fm-pr-status.sh`](../../bin/fm-pr-status.sh) owns bounded normalized PR reads from a forge and their timestamped cache.
[`bin/fm-project-board.sh`](../../bin/fm-project-board.sh) `reconcile` owns the bounded fleet-wide comparison of declared boards with their trackers and is armed periodically by locked startup.
That board sweep corrects only the membership and open-versus-closed status its complete listings can establish.
It does not pretend to resolve finer premise validity that requires the heartbeat review's judgment.

This placement keeps one owner per concern and avoids a duplicate check on the wrong side of the reset boundary.
The full `/stow` receipt explicitly says that reset-safe is never a claim that the home's durable records are correct.
It means only that this session's knowledge and known record changes can survive the reset under D5.

### D5. Reset safety proves survival, not service health

Only the full path may claim that the session is reset-safe.
The claim means that nothing durable this session knew depends on the conversation surviving.
It does not mean that the brain service is healthy, every brain page is searchable, or the home's durable records match current reality.

The receipt proves all of the following for the invocation:

1. Every identified durable finding names either the stronger durable owner written under `AGENTS.md` section 6 or its own intact brain outbox document.
2. A brain-backed finding's receipt names its document identity, as-of date, delivery state, truncation state, and redaction count.
3. A unique finding whose capture was refused, missing, unreadable, or truncated names another durable owner holding the complete safe body, or reset safety is refused.
4. Every open record this session knew was absent or wrong is filed, corrected, or explicitly left unchanged with the judgment it awaits.
5. The primary and every home reached by the full cascade finish within their own startup-memory budgets with no unresolved ownership exception or budget decision.

The capture pipeline writes an outbox record synchronously before attempting bounded delivery.
An intact record in `captured`, `pending`, or `failed` state after delivery attempts are exhausted therefore proves survival across reset.
Only `captured` proves that the finding was delivered for ordinary brain retrieval.
A pending or failed finding is reported in captain-facing language as surviving on disk but not searchable yet, together with the next action owned by [`docs/gbrain-capture.md`](../gbrain-capture.md).
The receipt never says merely that "the brain has it" when only the outbox does.
This distinction prevents a later unsuccessful search from being mistaken for proof that the finding does not exist.

Aggregate capture status remains part of the operational receipt but cannot prove preservation of this invocation's findings.
The proof is per finding because old corpus counts cannot identify a missing new note.
Existing unrelated audit or delivery degradation is service health and is disclosed without rewriting the survival verdict for an intact new record.

A home with no configured brain can still qualify as reset-safe.
Capture is deliberately inert there, so the home has fewer destinations and routes every durable finding through the non-brain owners that remain available under `AGENTS.md` section 6.
If no such destination holds a complete finding, the full path refuses reset safety rather than making brain adoption mandatory or losing the finding.

The light path reports only its bounded checkpoint outcome and always states that a full `/stow` remains required before reset.

### D6. The public skill stays independent and unchanged

This ADR governs only [`.agents/skills/stow/SKILL.md`](../../.agents/skills/stow/SKILL.md).
The installer-facing [`skills/stow/SKILL.md`](../../skills/stow/SKILL.md) remains unchanged.
Its header deliberately makes it a standalone product with no shared code or environment branching, and there is no evidence from its users that would authorize changing their workflow.

Most of this decision has no public equivalent because the public skill has no Firstmate brain, startup-memory budget, durable fleet records, or secondmate cascade.
The following generic conclusions are deliberately deferred for possible public consideration rather than copied now:

- distinguish an end-of-conversation reset pass from a lighter checkpoint while continuing;
- treat any future configured always-loaded memory allowance as a ceiling rather than an occupancy target;
- keep an end receipt's survival claim separate from the availability of an optional destination.

The public skill already refuses to become an accumulating journal and already uses local durable files, so those existing similarities do not justify coupling the implementations.

## Alternatives considered

### Split session handoff from memory curation

Rejected.
It would make a routine end-of-session reset depend on choosing and ordering two owners correctly.
It would also leave the relationship between the curation receipt and the handoff receipt vulnerable to drift.

### Capture only when startup memory prunes an entry

Rejected.
That model makes deletion the brain's admission trigger and leaves session-produced retrieval knowledge uncaptured until memory pressure happens to evict it.
The 2026-08-26 primary-home capture-outbox observation shows the effect: 30 of 41 existing notes arrived through the two pruning source-id families.

### Capture the session as a journal

Rejected.
Eventfulness does not establish retrieval value, and chronological transcripts mix durable findings with volatile state, secrets, and unresolved claims.
Atomic findings preserve the current skill's refusal to become a session journal.

### Reduce startup memory to an index of brain searches

Rejected.
A fresh session cannot search for a safety rule, authority boundary, or preference that it does not yet know exists.
The always-loaded projection therefore remains directly actionable.

### Infer mode from harness context pressure

Rejected.
No common Firstmate adapter contract exposes a comparable live reading, and explicit invocation is the authoritative handoff-pacing signal rather than worker self-assessment.
Explicit invocation intent is both portable and authoritative.

### Make every invocation full

Rejected.
The current trigger explicitly permits periodic mid-session use, so checkpoint use is part of the supported contract rather than an inference from archive frequency.
Charging a cascade and complete memory evaluation to a deliberate checkpoint would make that use unnecessarily expensive.

### Reconcile repository and forge reality before reset

Rejected.
The check would duplicate heartbeat and board-reconciliation owners and would run before a gap in which the observed state can change again.
It would add cost without making the reset-safety claim stronger.

### Require every new brain note to be searchable before reset

Rejected.
It would put an optional, slow, or unavailable service on the reset path even though the durable outbox already preserves the finding.
The receipt separates survival from searchability instead.

### Treat an unconfigured brain as a reset-safety failure

Rejected.
Brain integration is presence-gated by design, and a brainless home can preserve knowledge through its remaining authoritative destinations.

### Keep the internal and public skills synchronized

Rejected.
Their explicit separation is the product boundary, not an accidental duplication to remove.
Synchronizing them would either import Firstmate-only machinery into a general installer or add the environment branching both file headers reject.

## External prior art considered and rejected

Importing the installed mattpocock plugin's `handoff`, `claude-handoff`, or `ask-matt` workflow is rejected after reviewing all three as external prior art, and they change none of D1 through D6.
Their useful invariant is that a phase boundary preserves only what the next phase needs, references existing artifacts instead of duplicating them, and redacts sensitive content, which this ADR already applies through atomic capture and stronger-owner routing.
Their temporary Markdown handoff, background-agent launch, `CONTEXT.md`, local scratch tracker, and one-continuous-session assumptions do not fit Firstmate's durable multi-home fleet records or this task's ADR-only boundary, so none of that process, layout, or vocabulary is imported.

## Rationale

The design follows the boundary at which information would otherwise be lost.
Session-produced durable knowledge is captured before reset, while current operating truth stays with live owners that can recheck it after reset.
The startup projection retains only information a fresh session must act on before it knows to search, and the brain retains dated retrieval detail that does not justify an always-loaded cost.

One captain-invoked owner keeps the ordinary ritual atomic.
The explicit light path preserves the useful checkpoint behavior without pretending that a partial pass completed full curation or reset proof.
The receipt then states exactly which guarantee was earned rather than letting one command name imply work that did not run.

This arrangement answers the current pressure without moving it elsewhere.
It preserves the memory tier and pass-horizon reasons, prevents first-class capture from becoming a journal or duplicate-note stream, leaves volatile reality checks with their existing owners, and does not make an optional brain service a prerequisite for safely ending a session.

## Consequences

- The ordinary end-of-session ritual remains one invocation.
- The internal skill needs explicit full and light execution paths even though both remain under one owner.
- The enabled pass horizon continues to count actual startup-memory curation passes rather than every invocation that takes the light path.
- A light invocation may visibly promote to full when its findings require a startup-memory write or reveal invalid budget state.
- Brain note volume grows from capture-worthy findings rather than only from memory pruning, but capture remains bounded per body and filtered by retrieval value.
- Startup-memory curation optimizes for utility and headroom rather than filling the configured allowance.
- Consumers must treat session notes as dated evidence and consult a live source before making a current-state claim.
- Record truth may still drift across a reset, and the existing heartbeat and board owners must reconcile it after the gap.
- The public installer-facing skill receives no change from this ADR, while three transferable ideas remain explicitly deferred.
- First-class session capture must ship with ADR 0001 D5's round-trip guard rather than creating an unbounded duplicate-note path.
- Implementation is deferred to a separate task after this ADR lands.
