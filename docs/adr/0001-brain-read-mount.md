# 0001 - Mount brain reads at the brief scaffold, and route by kind before retrieving

- Status: accepted 2026-08-20, when the captain answered both open captain choices below; implementation remains the follow-up tracked work named under "Consequences"
- Date: 2026-08-19
- Deciders: the design interview between the `fm-gbrain-read-integration-design` worker and firstmate, with two choices held for the captain (see "Open captain choices")

## The headline finding, first

The captain asked how to get firstmate's always-loaded files inside the startup-memory budget, and framed retrieval as the mechanism.
The measurement says the mechanism is routing: putting facts in the files that already load at the right moment, not moving them into the brain.

- The largest immediate relief - a per-spawn drop from an estimated 24.1k to roughly 9.5k tokens for `harness-adapters`, plus roughly 413 estimated tokens off the startup files - comes from file-to-file routing that depends on neither the brain nor any in-flight work.
- Retrieval-based relief is real but smaller, and it is gated twice: once on the `fm-gbrain-answer-protocol` work landing, and once on the capture-trust gate that `data/fm-gbrain-capture-tightening/report.md` established.
- This design therefore frees zero tokens through the brain on the day it lands, and says so plainly rather than quietly not delivering.

Routing is available now.
Retrieval arrives in tranches, each behind a named gate.
The arithmetic is in "Budget arithmetic" below.

## Context

All numbers below use the fleet's own estimator, `ceil(UTF-8 bytes / 3)`, unless marked otherwise.
Byte counts are measured; token figures derived from them are estimates by that conversion, deliberately conservative.
Figures imported from another document are restated in this estimator, and wherever that document's own figure is quoted alongside it is attributed to that source's units, so a reader can reconcile the two rather than finding an unexplained disagreement.
The measured claims in this document were reproduced against the live fleet during its validation, including a live re-measurement of the brief-scaffold search at the exact shape D1 names.

**The budget is exhausted.**
`bin/fm-startup-memory-budget.sh report` on 2026-08-19: `data/captain.md` 9,758 bytes = 3,253 estimated tokens, `data/learnings.md` 12,732 bytes = 4,244, total 7,497 of a 7,500 budget - 3 tokens of headroom, after a full consolidation pass on 2026-08-13 measured 7,944.
The residue is largely dated empirical evidence, the category the captain identified as belonging in retrieval.
The same pressure applies to `AGENTS.md` (71,876 bytes, ~23.9k estimated tokens, every session) and the `harness-adapters` skill (72,220 bytes, ~24.1k estimated tokens, loaded before every spawn).

**The write side is enforced; the read side is prose.**
`data/fm-gbrain-usage-inventory/report.md` (2026-08-19) established that capture runs as a structural teardown step while not one enforced read step exists anywhere in the fleet: no skill references recall, session start emits nothing from the brain, and the only read instruction is one always-loaded sentence plus a static section in generated briefs.
Recall was unmeasurable by construction on 2026-08-19 - `fm-recall.sh` wrote no log, no marker, nothing durable - so whether the instruction had ever been followed could not be established.
One round-trip defect is proven: a learning pruned into the brain on 2026-08-05 was re-derived and re-admitted to always-loaded memory on 2026-08-16, with nothing intercepting it.

**Retrieval is fast, local, and good - but cannot signal a miss.**
`data/fm-gbrain-capability-research/report.md` (2026-08-19) measured search at ~0.75s wall, fully local, zero hosted tokens, with quality top-1 0.925, top-5 0.95, MRR 0.9375 over 40 questions.
It also measured that empty result lists were never observed and that the printed score cannot separate a hit from nonsense: deliberate nonsense queries scored 0.72-0.80 while a genuine correct paraphrase hit scored 0.41.
There is no calibrated presence test, so any design that treats "search returned something" as "the thing exists" - or "returned nothing relevant" as "the thing does not exist" - is built on a signal that does not exist.
`fm-recall.sh think` is a separate command that sends the question and selected excerpts to a hosted provider; no ambient or structural path in this design may reach it.

**Capture is not yet trustworthy enough for offload.**
`data/fm-gbrain-capture-tightening/report.md` found records marked captured but soft-deleted from the active index, pages never refreshed after their durable sources were corrected (including a captain-voided finding served at rank 1 with no stale marker), and an exact current fact absent from every indexed body.
Its verdict: further startup-memory offload waits for a capture audit, repairs, two consecutive clean integrity audits, and eval parity.
This ADR honors that gate rather than relitigating it.

**Two moving facts this design was required to verify, not assume.**

1. GBrain on this host is now 0.46.21.0.
   `docs/gbrain.md` owns the recorded pin and still states `v0.45.9.0`, so a reader who opens both files meets two different installed versions, and this one is the current build.
   That pin cannot move in this change: `docs/gbrain.md`'s own upgrade procedure moves the recorded version and the clean-install recipe's checkout commit in a single edit, and the existing task `fm-gbrain-doc-upgrade-wrong-home` owns that edit together with the same file's wrong-brain-path correction.
   The discrepancy is named here, with its owner, rather than left for a reader to discover as a contradiction.
   Re-established from the installed source and live probes: `context_pack` and `delta` still exist, additive at `protocol_version: 1`, semantics unchanged since 0.45.7 (the protocol document sections are byte-unchanged since 0.45.9; implementations were refactored into ops modules).
   **Corrected claim: an earlier round of this document reported "`context_pack` is empty on this corpus", and that claim is withdrawn.**
   Review raised it by cross-checking this document against `docs/verification/gbrain-memory-verbs.md`, the repository's owner for measured GBrain verb behavior, which records a live `context-pack` call against this corpus at the prior pin returning `{"cards":1,"budget_used":33}`.
   What the original probe supports is narrower than what it was written as saying: it passed the entity name `firstmate`, and a re-run confirms that name resolves through none of the four arms the card builder uses - alias, exact title, exact slug, slug suffix - so an empty pack was that probe's expected result rather than a fact about the corpus.
   `context_pack` assembles its cards from the `pages` table through exactly those arms, per the installed 0.46.21.0 `src/core/verbs/entity-card.ts`, so a corpus of pages does produce cards: a live probe on this brain naming an exact page title returned one card, alongside the `firstmate` re-run that returned none.
   The claim that `context_pack` is inert on this fleet's data is therefore not established, and it is withdrawn rather than narrowed.
   The release evaluation's "use native `context_pack` for session boundaries" is not adopted here because D9 rejects session-start retrieval on its own merits, not because there is nothing to pack.
   `delta` was probed live with a timestamp and works: it returned the pages captured since the given time, oldest first.
   The scope reduction "do not build a custom change cursor" holds; "do not build custom session-boundary packing" holds on that same D9 rejection rather than vacuously.
2. `fm-gbrain-answer-protocol` was in validation for most of this interview, so every gate here was designed against its required behavior rather than its unlanded field names.
   It has since landed (PR 185, squash-merged, checks green) and this home runs it.
   The shipped behavior was verified against the merged source rather than against reported state: a search now frames what its rows are, and labels each local result with capture and live-source provenance.
   `bin/fm-recall.sh` owns that contract, and `AGENTS.md` now states its two always-loaded consequences and names that owner.

## Decision

### D1. The primary mount is the brief scaffold

`bin/fm-brief.sh` runs one `fm-recall.sh search` at scaffold time, using the task's own words as the query, scope local, and embeds a bounded, provenance-labeled citations block in the generated brief.
When results exist, the block replaces the current instruction-only Brain section; the instruction to search again mid-task remains.

Why this seam: the brain-presence branch already ships there and degrades to inert in production today; the task title and description are a real query, which session start lacks; the cost (3,103-3,209 measured bytes of output per search = 1,035-1,070 estimated tokens, re-measured live at the `--limit 5 --excerpt 400` shape this decision names) is paid only when work is commissioned; and the moment is exactly when the knowledge would otherwise be re-derived at worker-investigation cost.
`data/fm-gbrain-usage-inventory/report.md` states the same seam as 969-3,518 measured bytes = 242-879 tokens in that report's own `bytes / 4` units, which is 323-1,173 estimated tokens under this document's estimator.
At 1,035-1,070 estimated tokens per commissioned task, this decision still holds comfortably: the cost is charged only when work is commissioned, against re-derivation that costs a worker investigation in the tens of thousands of tokens.

Bounds: the embedded block is capped at roughly 1,100 estimated tokens, the live re-measurement of the `--limit 5 --excerpt 400` shape under this document's estimator; the exact flags are implementation detail owned by `fm-brief.sh` when this lands.
The wait is pinned too, with an explicit `--timeout` of 10 seconds rather than the wrapper's 60-second default, following the dashboard's existing call site in pinning its own bound rather than inheriting that default: 10 clears the measured ~8.6s worst case with margin, and a hung endpoint must not charge a minute to a dispatch path that costs nothing today.
That budget covers the provenance pass as well as the retrieval, because the wrapper sizes both from the same `--timeout`, and the tradeoff is taken rather than engineered around: on a search slow enough to consume most of the 10 seconds, rows the pass did not reach carry a null capture date and an unknown source state.
Both are supported states of the landed contract, so the gate's fields-present predicate still passes and the block mounts with those rows labeled unknown - which is the honest label, and better than either dropping them or waiting longer before every dispatch.

### D2. A recall audit trail is a prerequisite, built into this design, sequenced first

One append per `fm-recall.sh search` invocation in a home whose local index is present, into a gitignored state file: record id, timestamp, caller seam, query hash, exit state, result count.
`fm-recall.sh think` never appends: it is the other command the wrapper offers, hosted synthesis with its own exit vocabulary and no result count, and this trail measures search adoption.
The record id identifies one invocation, and exists so a later record written by a caller can name the read it followed without either record carrying the other's datum (D5).
The wrapper both writes it on the trail record and returns it in the search output document the caller already consumes, so a caller learns its own read's id from that read; nothing in this design reads the trail back to find it.
Returning it is an additive field on the `fm-recall.v1` document that `bin/fm-recall.sh` owns, and the implementing task plans that change there alongside the seam declaration below rather than discovering it mid-flight.

The append condition is local brain presence - the same resolve-the-paths-and-find-the-PGlite-directory predicate `bin/fm-brief.sh` already gates its Brain section on - evaluated before the read and never from the read's outcome.
Both of the properties that matter then hold structurally, rather than being asserted over a list of cases someone had to think of first:

- A home with no local index appends nothing, because the predicate is false there.
  That holds however an invocation turns out and whatever else that home can reach, including the supported configuration where a fleet main brain is reachable from a home with no brain of its own.
- Every search invocation in a home that does have an index appends, so the exit state carries information.
  Ran-and-its-read-failed is a record; never-ran is the absence of one; keying the append on success instead would have collapsed those two into the same silence and left the exit-state field constant.

A second record kind, owned by `/stow` rather than by the wrapper, carries D5's conclusion; it is specified under D5's third constraint below.
It inherits the same inertness without a second copy of the predicate, by derivation rather than by restatement: a conclusion record exists only for a candidate that a read informed, it names that read by the id the read returned, and an id exists only for an invocation that appended.
A home with no local index therefore produces no append, no returned id, no informed candidate, and no conclusion record.
The chain is what keeps the two writers from drifting apart, because a copied presence test is a second thing that can be edited and a derivation is not.

- **Query hash, never query text.**
  This is a decision, not an omission: a query can carry the substance of what someone was working on, and brain content is private to a home.
  What the hash buys is that free-text queries never land in a file on disk, so no person, backup, or later tool that ingests state files learns what was asked by reading the trail.
  What it does not buy is resistance to a guess, because the hash is unkeyed: anyone who can propose a candidate query can hash it and see whether that digest is already in the trail.
  What that costs differs by seam, so it is stated for each of the five seam values this decision names rather than once for all of them:
  - Brief-scaffold queries are the task's own words, and task titles are readable from the backlog, so the candidate set is small and cheap to test - worth saying plainly instead of averaging away.
  - Dashboard queries are operator free text with no enumerable source to draw candidates from, so the hash withholds real content there.
  - Stow queries are the candidate learning's own content (D5), so a guess has to reproduce that text before the digest can confirm it.
  - Eval queries come from an evaluation set file, so the protection depends on which set was run: the shipped default set is tracked in this repository and its questions are already public, so the hash protects nothing private there, while an operator-supplied `--set` file can be private, and there the hash withholds real content.
  - Undeclared queries are ad-hoc, and include firstmate's own pre-commission consult, whose words come from the investigation being weighed and land close to the task title it becomes - so the backlog is again a candidate list, which makes this value and brief-scaffold the two weakest.
  The price, stated per seam above rather than once for all of them, is that the trail records outcomes rather than content, and it does so unevenly across those five values - weakest at brief-scaffold and undeclared, the two whose candidates the backlog supplies.
- **The caller-seam field must distinguish** brief-scaffold, stow, dashboard, and eval invocations, or the trail cannot measure adoption, which is its purpose.
  It carries a fifth value meaning exactly no seam was declared, which is what an ad-hoc wrapper call from a conversation records - including firstmate's own pre-commission consult, the recall D6's trigger has to count and no mounted seam produces.
  Every mounted seam declares its value; undeclared is for calls no mount owns, never a default a mount is allowed to fall back to.
  If undeclared ever dominates the trail, seam tagging has stopped measuring what it exists to measure, and that is a finding to surface rather than a state to live with.
  Two of the four mounted values already invoke `bin/fm-recall.sh` today and pass no seam identifier: the dashboard server's operator search and the eval harness.
  Satisfying this field therefore means editing those two call sites or adding a wrapper-side seam declaration they adopt, and the implementing task plans for those files rather than discovering them mid-flight.
- **The trail must make pre-commission recall computable**: joined against task creation times, it must answer "was a recall run before this investigation was commissioned" (see D6 for why this specific question matters).
- **Who reads it, and when**: firstmate reviews the trail one week after the mount lands and again at 30 days.
  On a home whose brain resolves, no seam-tagged brief-scaffold records while briefs were scaffolded means the mount is not exercising - an implementation defect to fix, not a finding to file.
  Failing the D3 gate does not soften that verdict: a pre-contract home still runs the scaffold search for D4's ungated advisory line, so it still appends brief-scaffold records, and what the gate withholds there is the embed rather than the record.
  Only a missing local index makes the silence normal, because that is the one condition under which the append predicate is false.
  See D6 for the pre-commission reading and its trigger.
- Without a local index the trail is empty by construction rather than by enumeration, across both of the writers this decision names: the append predicate is false, so the wrapper writes nothing, and `/stow`'s conclusion record cannot exist because the chain above gives it no read and no id to name.
  No list of which callers still run has to be right for that to hold.
  Wherever it does hold records, it must never block or slow the read path it measures.

Without this trail, neither the mount's adoption nor its effect on re-derivation can ever be demonstrated - the loop's brokenness would stay unmeasurable one level up.

### D3. The worker-facing embed is hard-gated on the answer-protocol behavior

The brain cannot signal a miss, so an unframed embed would feed plausible irrelevant pages into every commissioned brief as trusted context - worse than today's unread brain.

The gate is **positive detection of behavior**, per home, at scaffold time: the installed `fm-recall.sh` must be observed to emit a framed nearest-or-none answer and per-result provenance fields for capture date and source state.
Detection tests that those fields are present in the emitted document, never that they hold particular values: a null capture date and an unknown source state are supported outputs of the landed contract, produced by a home with an index but no capture outbox, and a non-null test would refuse to mount there while making it look identical to a home running an old wrapper - a false negative in the safety direction.
Absence of the contract means do not mount; the fallback is today's instruction-only Brain section - shipped behavior, not a new degraded mode.
The gate is deliberately not a version check or config flag: it is true per home while secondmates update independently, it degrades to known behavior, and it closes itself under a rollback.
The concrete binding, now that `fm-gbrain-answer-protocol` has landed: the gate detects the installed wrapper emitting the `fm-recall.v1` document with its answer framing and per-result provenance present.
`bin/fm-recall.sh` owns that contract's full definition.
The gate was designed behavior-first while that work was still in validation, and stays defined by the behavior: if the contract ever changes shape, the gate follows the owner.

### D4. The same search also prints a firstmate-facing "nearest prior work" line - advisory, ungated

At scaffold time, before dispatch, `fm-brief.sh` prints one stdout line naming the closest existing completed report and its path.
One search, two outputs, two audiences, two gates: the worker-facing embed is hard-gated (D3) because it becomes trusted context; the firstmate-facing line is advisory and ungated because its reader is firstmate actively deciding, and a candidate to compare is never trusted context.
The line **never enters the generated brief**; if the two outputs ever collapse into one, the gate collapses with them.

This line claims proximity, never duplication.
222 of the 261 records in this brain are task records, so any rule that fires on "the top result is a completed report" fires at base rate; a flag that fires every time is a line firstmate learns to skim, and alarm fatigue would make this feature worse than nothing by looking like coverage.
It is surfacing, not enforcement: nothing forces firstmate to read it, and nothing measures whether it was.
D4 has no seam of its own, because it rides D1's search and the two share one brief-scaffold record; none of that record's fields - record id, timestamp, caller seam, query hash, exit state, result count - says whether a line was printed, read, or acted on.
The trail shows the shared search ran and what it returned, and stops there.

### D5. `/stow` mounts a round-trip read - advisory, ungated, with a hard constraint

The searches are per candidate item, not per invocation: one `fm-recall.sh search` at scope local over pruned notes for prior art before admitting each "new" learning to always-loaded memory, and one, also scope local, before creating each new pruned note.
A pass that admits nothing and prunes nothing runs none; a pass that admits two learnings and prunes three notes runs five.
Both kinds are pinned to scope local for the same reason D1 is: the three mounts this ADR adds - D1, D4, and D5 - all read this home's own corpus and none reaches the remote main brain, and inheriting the wrapper's default scope would mount one.
This fixes the only demonstrated defect in this area - the 2026-08-05 to 2026-08-16 round-trip - at the moment it occurs, which no other seam reaches (nothing is commissioned at prune time).

The constraint, which is not optional: **the read is advisory; a search hit may never, on its own, be the reason a learning is not captured.**
The brain always returns something, so "search found a match" would silently veto genuinely new learnings - and unlike the brief case, whose failure mode is visible added noise, this failure mode is invisibly deleted knowledge.
Concretely:

1. A decision not to admit a learning rests on an actual content comparison of the candidate against the new fact - never a hit count, a score, or "search returned something".
2. Symmetrically, a returned page is a candidate to read, never by itself proof an equivalent note exists.
3. Every candidate a `/stow` read informed gets a conclusion record, not only the ones that ended in nothing being captured: a second append `/stow` itself writes after deciding, carrying the record id of the read it followed and one bounded outcome value from a closed set - captured, not-captured, or no-comparison-made.
   That id is the whole coupling: the wrapper returns it with the read and also writes it on the read record, `/stow` echoes it on the conclusion record, and neither record is widened to carry the other's datum, because the wrapper returns before the content comparison that produces the conclusion and cannot know it.
   It is also what keeps the pair unambiguous when a pass runs the same query twice, which the per-candidate searches above make ordinary rather than exceptional.
   Recording every outcome rather than only the not-captured ones is what buys the property: a read record with no conclusion record then means exactly one thing, that the procedure did not complete, instead of being ambiguous between that and capture proceeding normally.
   The not-captured outcomes this constraint exists to make auditable are recorded either way, and absence of a record still never becomes a record of absence.

It is ungated by D3 for the same reason D4 is: constrained to advisory-with-comparison, these results are never trusted context.

The rule under D4 and D5, and under this whole design: **the brain may tell you where to look; it may not tell you that you have looked.**

### D6. Firstmate's pre-commission consult stays prose - a known gap, left open deliberately

The `AGENTS.md` section 7 instruction to search the brain before commissioning an investigation remains as it is.
This is chosen over moving the requirement into a skill (a second copy of one sentence, with no added enforcement - prompt-level prose relocated is prose still) and over building an intake gate (intake is conversational; no script seam exists, and inventing one fails the simplest-direct-path rule).

Stated plainly: **this seam is unenforced, D1 does not cover it, and the failure it permits is duplicate commissioning.**
The brief-scaffold search runs after the commission decision; it cannot prevent commissioning an investigation into something already investigated.
The recorded instance is from 2026-08-19, in this project: two investigations into this fleet's brain usage were commissioned while an authorized design task covering that ground sat in the queue, and the duplicate was discovered only afterwards.
D4 narrows the window from "discovered afterwards" to "flagged at scaffold time, before tokens are spent", but the commission decision is already made by then.

The revisit trigger, concrete rather than "with data": if the D2 trail over its first 30 days shows a pre-commission recall for fewer than half of commissioned investigations, this decision reopens - with the skill option, or a seam not yet found.
The record it counts is an undeclared-seam recall in the 24 hours before a task's creation time, which is why D2's seam vocabulary carries that fifth value: the consult this decision leaves as prose is an ad-hoc wrapper call, so no mounted seam can produce the evidence, and a brief-scaffold record could never serve because that search runs after the commission decision.
The 24-hour window is the captain's decision of 2026-08-19, recorded here as theirs rather than as a default this design chose, because the number's owner is the point.
It has to be bounded at all for a structural reason: undeclared is a shared bucket for every ad-hoc call, so an unbounded lookback would let one old record count as the pre-commission recall for every task created after it, driving the measured fraction to one and leaving the trigger unable to fire.

### D7. The split-by-kind rule conflicted with itself, and this design resolves it - with a third category the captain did not name

The captain's rule: deterministic safety rules and procedure stay in files because retrieval can fail; dated evidence and per-variant detail become retrieval.
On `harness-adapters`, those clauses collide: the per-variant sections **are** spawn procedure - trust dialogs, submission mechanics, exit paths - the same bytes are both.
A retrieval miss at spawn time means not knowing how to answer a trust dialog on a pane that is already waiting.

**Resolution: the safety clause wins.**
Per-variant harness procedure does not go to the brain.
It goes into per-harness files loaded deterministically by the resolved harness name - a third category, **file-to-file routing**, which is neither "stays in the always-loaded file" nor "becomes retrieval", and is better than both here: the load is deterministic, it has no retrieval failure mode to miss on (a missing or unreadable file still fails, and fails visibly), and the token cost falls to the variant actually being spawned.

Measured shape: the skill is 23,164 bytes of shared head plus 49,056 bytes across nine per-harness sections.
A spawn today loads all 72,220 bytes (~24.1k estimated tokens); split, it loads the shared head plus one variant, roughly 28,600 bytes (~9.5k estimated tokens) for an average variant - a ~60% per-spawn reduction with zero retrieval risk.

Constraints on the split, decided here and binding on the implementing task:

- **Cross-cutting content is identified before anything moves, and is never orphaned into one variant's file.**
  The shared head is not simply "the part before the variants": sections like the submission-acknowledgement hazards deliberately compare opencode, grok, and kimi in one place, and the composer classifier is one fleet-wide owner no adapter may copy.
  A cross-cutting fact landing in one variant file stops loading for every other variant's spawn - a safety regression dressed as a token saving.
- **No shared rule is restated per variant.**
  `docs/one-owner.md` governs; nine copies of one gate rot in nine places and are worse than the current single file.
- Dated verification evidence (the VERIFIED headers' version observations and re-verification notes) points at its existing owner, `docs/verification/runtime-backends.md`, rather than being duplicated or moved to the brain.
- Only incident narratives - the stories behind the facts - are brain candidates, and those follow the D8 gate.

**This ADR decides the split; it does not perform it.**
The refactor is its own tracked work with its own validation.

### D8. Brain-destined offload happens in tranches, behind the capture-trust gate

Nothing moves into the brain as its only home until the capture-tightening gate passes: capture audit live, known repairs done, two consecutive clean integrity audits, eval parity.
The tranche structure and arithmetic are the next section; the point of the decision is that tranche membership is determined by **destination**: a move whose destination is another file (tranche 1) is not gated by capture trust, while a move whose destination is the brain (tranches 2 and 3) is.

### D9. What session start gets: nothing from retrieval

No retrieval section is added to the session-start digest.
This overturns a stated candidate and is treated at length under "The overturned candidate" below.
A one-line brain-awareness fact (record count, last capture time, ~10 tokens, no retrieval) was considered and is deferred as optional follow-up work rather than decided here, to keep this design's surface minimal; it charges the digest, not the startup-file budget, either way.
`delta` at a periodic seam (heartbeat, bearings) is likewise deferred: it works (verified live), but it serves freshness-awareness, not the budget goal, and mounting it now would widen this design without moving the number the captain asked about.

## Budget arithmetic

The captain asked for a number: what moves, what that frees, what the seams cost, and the net.
Estimator: `ceil(UTF-8 bytes / 3)`, the same conservative estimator `bin/fm-startup-memory-budget.sh` uses; byte counts measured 2026-08-19.

**Starting position: 7,497 of 7,500 estimated tokens** (`captain.md` 3,253 + `learnings.md` 4,244).

### Tranche 1 - file-to-file routing; ungated, available now

| Move | Measured bytes | Est. tokens freed | Destination |
| --- | --- | --- | --- |
| `learnings.md` codex per-variant entry | 313 | 105 | that harness's per-variant file (D7) |
| `learnings.md` cursor/agy per-variant entry | 598 | 200 | those harnesses' per-variant files (D7) |
| `learnings.md` no-mistakes `config.yaml` facts, shrunk to a pointer at the file that already owns them | 446 - ~120 kept | ~109 | `~/.no-mistakes/config.yaml`'s own comments (already there) |
| **Tranche 1 total** | **~1,237** | **~413** | |

Startup files after tranche 1: **~7,084 of 7,500** - headroom ~416 tokens instead of 3.
Plus the D7 spawn-path relief, ~14.6k estimated tokens per spawn, which is outside the 7,500 budget but is the largest single number in this design.
Sequencing note: the per-variant entries route into the per-harness files (or their pending sections), so tranche 1 lands with or after the D7 split rather than inflating the unsplit skill.

### Tranche 2 - dated evidence out of always-loaded entries; gated on capture trust and the D3 contract

The rule stays; the incident evidence behind it becomes a brain page with a pointer.
Measured anchors: the Z.AI quota incident (~226 of 406 bytes is evidence), the week-reset story in `captain.md` (~299 of 549), the cursor/agy adoption history (~173 of 293), the merge-burst and big-merge incident details (~180), plus scattered dated fragments (~150-250).
**Tranche 2 total: ~1,028-1,128 bytes, ~343-376 estimated tokens.**
Startup files after tranches 1+2: **~6,708-6,741**.

### Tranche 3 - the deep offload; gated the same, scoped by capture-tightening's own list

Long rationale and history behind stable preferences, resolved decision history, detailed topology reference, incident narratives - the categories `fm-gbrain-capture-tightening` section 6 already names as safe to move once its conditions hold, at the 5,000-5,500 target it already computed.
That means moving a further ~1,200-1,700 estimated tokens beyond tranche 2.
This ADR adopts that target as the destination of the tranche system and holds the exact budget number for the captain (see "Open captain choices").

### What the seams cost

- Brief-scaffold search: 3,103-3,209 measured bytes of output per commissioned task = 1,035-1,070 estimated tokens, ~0.75s, zero hosted tokens; zero cost for sessions that commission nothing.
- Nearest-prior-work line: one stdout line at scaffold time.
- `/stow` round-trip: sub-second local searches per candidate item processed, so the count is proportional to what a pass admits and prunes rather than fixed (D5).
- Audit trail: one local file append per `search` in a home with a local index, plus one conclusion record per candidate a `/stow` read informed (D5); no context cost.
- Always-cost added to any session: **zero** - of the four seams listed above, each is paid only when its own trigger fires, and none charges the startup files or the per-session context unconditionally.

The headline is unaffected by these seam costs, by construction: the brief-scaffold figure is per-commissioned-task context and not startup memory, no tranche figure above is derived from it, and the 7,497 to ~7,084 arithmetic stands exactly as computed.

### The net, honestly

- Day one, with only this design landed: **~413 estimated tokens freed (tranche 1) plus the ~60% per-spawn cut once the D7 refactor ships; zero tokens freed through the brain.**
- With `fm-gbrain-answer-protocol` landed (PR 185; it landed during this design's own validation window): the D1 embed can mount on any home whose installed wrapper passes the D3 detection - this home already does; still no budget relief from retrieval, but re-derivation pressure starts falling and becomes measurable.
- After the capture-trust gate passes: tranches 2 and 3, ~1,543-2,076 further estimated tokens, taking the startup files to the 5,000-5,500 region capture-tightening computed.

## The overturned candidate - session-start retrieval

The captain's 2026-08-13 framing for this task named `context_pack` at session start as the candidate mechanism, in preference to further trimming.
This design rejects session-start retrieval outright.
That is a reversal of the captain's stated candidate, and it must be read as one.

What changed is that both investigations ran after that framing was written, and they measured the things it had to assume:

- Session start has no query.
  The digest knows fleet state, not the work about to be commissioned; a query-free "recent captures" section duplicates the backlog's Done history.
- Retrieval there is an always-cost: 1,035-1,070 estimated tokens per session, paid whether or not the session needs it, against roughly 67 estimated tokens saved by pruning one more conditional fact.
  That 67 is `data/fm-gbrain-usage-inventory/report.md`'s ~50 tokens of pruning savings restated in this document's estimator, the same bytes under `ceil(bytes / 3)` rather than that report's `bytes / 4`.
  With both sides in one estimator the trade is roughly 15x worse rather than the 12x that report computed, so the case against session-start retrieval is stronger than it was previously argued, not weaker.
- A brain read inside the digest adds failure surface to the most safety-critical path firstmate has, for the above negative return.
- And specifically for `context_pack`: its `--entities` argument has to be supplied, and session start is the one moment with nothing to supply it from - no query, and no principled basis for choosing which entities the session is about before the work is named.
  A pack for a name that matches no page returns empty arrays, exit 0, and no error, verified live on 0.46.21.0, so the caller cannot distinguish a badly chosen entity name from an absent one.
  That is the same cannot-signal-a-miss shape the rest of this design guards against, arriving here as an unreadable result from an unmotivated choice; the corrected finding in the context above is what this bullet now rests on instead of a claim about the corpus.

If the captain still wants session-start packing with these numbers in front of them, that is their call; the evidence above is what it would be made against, and firstmate ruled that this ADR - not a silent default - is where they make it.

## Alternatives considered and rejected

- **Session-start retrieval, including `context_pack`** - rejected above, with measurements.
- **A score threshold to detect misses** ("below X, report not found") - disproved by measurement before design: nonsense scores 0.72-0.80 overlap real hits at 0.41; no calibrated threshold exists, so none is invented anywhere in this design.
- **Skill-level recall requirements replicated across skills** - prompt-level enforcement relocated is the same weakness with N copies to drift; even the single-skill variant adds a second copy of a one-line requirement with no enforcement gained (D6).
- **An intake-time script gate for firstmate's own consult** - no natural seam exists at a conversational moment; machinery without a blocker fails the direct-path rule.
- **Per-variant harness detail into the brain** - rejected by the safety clause (D7): spawn procedure must not sit behind a path that can fail.
- **Hosted synthesis (`think`) on any structural path** - excluded outright, and the boundary is not "off-host".
  D1 embeds brain excerpts in a brief that a hosted harness reads, so excerpts leave this host either way; what separates the two is who receives them and on whose choosing.
  A commissioned crewmate already reads this home's material - the repo, the reports, the code it is about to change - so brain excerpts in its brief are that same material reaching that same reader by a shorter path.
  `think` instead routes brain content to a synthesis provider as a side effect of a read, which adds a recipient nobody commissioned; no structural or ambient path here may do that.
  This is the same rule D2's privacy decision applies to the trail - a read must not create a new holder of brain content, whether that is a hosted provider or a query written in plain text into a file - and it is why D1, D4, and D5 are each a scope-local search.
  Dreaming stays disabled.
  Neither privacy boundary relaxes.
- **`delta` at heartbeat or bearings** - works, verified live, deferred: it serves a different goal than the one this design was commissioned for (D9).
- **A soft mount before the answer-protocol lands** - rejected because an unframed embed is trusted context that cannot be trusted (D3).

## Degradation, per mount

A home with no brain must keep working as it does now, and that is checked per mount rather than asserted once: each of the four rows below states what its mount does on a brainless home, including work it newly performs and fails.
Read across those four rows, none blocks capture, dispatch, or a session, and none changes what a brainless home produces; where a row adds work that does not happen today, the row says so rather than rounding it to "no change".

| Mount | Brain absent | Brain slow or degraded | Answer-protocol contract absent |
| --- | --- | --- | --- |
| D1 brief embed | Scaffold's existing presence branch omits the Brain section entirely - shipped behavior today | The pinned 10s `--timeout` bounds the wait (measured worst case with a dead embed endpoint ~8.6s); on failure exits distinguish never-started from read-and-empty, and the scaffold falls back to the instruction-only section | Embed does not mount (positive detection, D3); instruction-only section ships |
| D4 nearest-prior-work line | Not printed | Same bounds as D1; absence of the line is silence about proximity, never a claim | Prints regardless (advisory; not gated) |
| D5 stow round-trip | `/stow` reaches the same outcome as today, having newly done and failed work: its per-candidate-item searches fail their source, after which the advisory step is skipped and capture proceeds | Advisory step waits or is skipped; capture is never blocked by a read | Runs regardless (advisory; not gated) |
| D2 audit trail | Appends nothing from either writer - the append predicate is "local index present", which is false here, so the wrapper writes nothing and `/stow`'s conclusion record has no read and no id to name; the file is never created | Appends with whatever exit state the run produced, so a slow or failed read is a record rather than a silence; never blocks or slows the read it records | Independent of it |

## Consequences

- **Nothing lands alone**: the D1 embed mounts only on homes passing the D3 contract detection (`fm-gbrain-answer-protocol` landed as PR 185 and this home passes; other homes gate themselves), and brain-destined offload is inert until the capture-trust gate passes.
  The captain should read the relief timeline in "The net, honestly" as the schedule: routing now, retrieval as homes pass the gate, deep offload last.
- The D2 trail's privacy trade is permanent: adoption and outcomes are measurable forever, and free-text queries are never written down, which resists reading the trail but not guessing against it - unevenly across the five seam values D2 enumerates, and weakest at brief-scaffold and undeclared, the two whose candidates the backlog supplies.
- D6 leaves a known, named gap open, with a dated instance and a concrete reopening trigger; anyone reading this ADR should not mistake D4's scaffold-time line for coverage of it.
- Alarm fatigue is the named risk of D4, and its only guard is the line's honest framing as proximity rather than duplication; a skimmed-past line is not detectable from the trail, whose fields say a search ran and nothing about what the line did.
- The recurring defect this interview kept meeting, in three different coats, is a positive standing without evidence: a search hit as a verdict, a capability assumed present, a check defaulting to "fine".
  The one-sentence rule that guards all of them: the brain may tell you where to look; it may not tell you that you have looked.
  It then appeared a fourth time, in this ADR's own prose - in the sentences written to fix the first three, which asserted properties over a set of seams nobody had enumerated: "the trail holds those failed invocations and nothing else", "the one difference the check found", "queries derive from task titles".
  Each was false exactly at the seams left uncounted.
  It then appeared once more inside the repair itself: the option chosen to restore D2's inert property asserted that a brainless home appends nothing, which is a universal over a configuration set nobody had enumerated, and it was false wherever a fleet main brain is reachable from a home with no local index of its own.
  Its sharpest instance is the withdrawn `context_pack` finding in the context above: one probe on one unenumerated entity name was written up as a universal cause about the whole corpus, and it sat in the section whose entire job is to say what was actually checked, which is the one place a reader has no reason to re-check.
  It survived every reading of this document by its own authors and was caught only when review cross-checked the repository's verification owner - so the lesson is not that probes lie, but that a probe's scope has to be written next to its conclusion or the conclusion outgrows it.
  That is the most transferable lesson of this design, and it tightens the rule rather than restating it: a claim about a set must be structurally true or explicitly enumerated, because the case you did not think of is by definition the one you cannot think of - which is why D2's append condition is now a predicate that makes the property hold rather than a sentence that asserts it.
  The closing lesson, for whoever reads this next: when a property keeps needing to be restated, stop restating it and make the structure produce it.
  That move solved this design three times - inverting a default so the whole class cannot occur, keying the trail's append on presence rather than on the read's outcome, and deriving the second writer's inertness from the causal chain instead of copying the predicate onto it.
  Each time, the sentence that kept being wrong stopped being load-bearing, which is the only repair that does not have to be made again.
- The process rule this design paid a round to learn: a review finding that collides with a decided property escalates to that decision's owner and is never applied as a correction.
  A round of review here did exactly that, trading away D2's decided "inert without a brain" for a more accurate description of an unspecified detail, and the finding's apparent correctness is precisely what made the override invisible - a wrong decision is arguable, whereas a right-looking correction is not read as a decision at all.
- Implementation is follow-up tracked work, per item: the audit trail (first, and carrying the seam declaration at the dashboard and eval call sites that D2 names), the scaffold search with its two outputs and two gates, the `/stow` advisory step, the `harness-adapters` split, and the tranche moves - each through the project's normal delivery path.
  This ADR authorizes none of them to skip their own validation.

## Open captain choices

Two choices surfaced by this design belong to the captain and are registered as captain-held items in the fleet's decision ledger; they are listed here so they cannot be lost in prose.

1. **The post-gate budget target** (`budget-target-post-gate`): keep the effective 7,500, or lower it toward 5,500 and then 5,000 as capture-tightening recommends once its gates pass and the tranches land.
   The budget knob is the captain's own local operating choice; nothing in this design moves it.
2. **Acceptance of the split-rule resolution** (`kind-split-safety-resolution`): the captain's own split-by-kind rule conflicted with itself on `harness-adapters`, and this design resolved it toward the safety clause by adding a routing category the rule did not name (D7).
   If the captain resolves it differently, D7 reopens, and so do the two tranche 1 moves whose destination is a per-harness file - the codex entry and the cursor/agy entry, ~305 of tranche 1's ~413 estimated tokens - because those destinations are what D7 creates.
   No other decision in this ADR depends on it: D1 through D6, D8, and D9 each stand whichever way the split rule is resolved.

The session-start reversal (above) is deliberately not a third held item: firstmate ruled that this ADR itself is the captain's decision point for it.
