# 0001 - Mount brain reads at the brief scaffold, and route by kind before retrieving

- Status: proposed, awaiting captain review
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

**The budget is exhausted.**
`bin/fm-startup-memory-budget.sh report` on 2026-08-19: `data/captain.md` 9,758 bytes = 3,253 estimated tokens, `data/learnings.md` 12,732 bytes = 4,244, total 7,497 of a 7,500 budget - 3 tokens of headroom, after a full consolidation pass on 2026-08-13 measured 7,944.
The residue is largely dated empirical evidence, the category the captain identified as belonging in retrieval.
The same pressure applies to `AGENTS.md` (71,876 bytes, ~23.9k estimated tokens, every session) and the `harness-adapters` skill (72,220 bytes, ~24.1k estimated tokens, loaded before every spawn).

**The write side is enforced; the read side is prose.**
`data/fm-gbrain-usage-inventory/report.md` (2026-08-19) established that capture runs as a structural teardown step while not one enforced read step exists anywhere in the fleet: no skill references recall, session start emits nothing from the brain, and the only read instruction is one always-loaded sentence plus a static section in generated briefs.
Recall is unmeasurable by construction - `fm-recall.sh` writes no log, no marker, nothing durable - so whether the instruction has ever been followed cannot be established.
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
   Re-established from the installed source and live probes: `context_pack` and `delta` still exist, additive at `protocol_version: 1`, semantics unchanged since 0.45.7 (the protocol document sections are byte-unchanged since 0.45.9; implementations were refactored into ops modules).
   New finding: **`context_pack` is empty on this corpus.**
   A live probe (`entities: "firstmate"`) returned zero cards, zero facts, zero threads, because this fleet's capture pipeline writes task and note pages only - the brain contains no entity cards or extracted facts for `context_pack` to pack.
   The release evaluation's "use native `context_pack` for session boundaries" is therefore inert here until capture itself changes, which is out of this design's scope.
   `delta` was probed live with a timestamp and works: it returned the pages captured since the given time, oldest first.
   The scope reduction "do not build a custom change cursor" holds; "do not build custom session-boundary packing" holds only vacuously, because there is nothing to pack and session-start retrieval is rejected on its own merits below.
2. `fm-gbrain-answer-protocol` was in validation for most of this interview, so every gate here was designed against its required behavior rather than its unlanded field names.
   It has since landed (PR 185, squash-merged, checks green) and this home runs it.
   The shipped behavior was verified against the merged source rather than against reported state: a search now frames what its rows are, and labels each local result with capture and live-source provenance.
   `bin/fm-recall.sh` owns that contract, and `AGENTS.md` now states its two always-loaded consequences and names that owner.

## Decision

### D1. The primary mount is the brief scaffold

`bin/fm-brief.sh` runs one `fm-recall.sh search` at scaffold time, using the task's own words as the query, scope local, and embeds a bounded, provenance-labeled citations block in the generated brief.
When results exist, the block replaces the current instruction-only Brain section; the instruction to search again mid-task remains.

Why this seam: the brain-presence branch already ships there and degrades to inert in production today; the task title and description are a real query, which session start lacks; the cost (measured 242-879 tokens of output per search at the bounds tested) is paid only when work is commissioned; and the moment is exactly when the knowledge would otherwise be re-derived at worker-investigation cost.

Bounds: the embedded block is capped at roughly 900 tokens (the measured `--limit 5 --excerpt 400` shape); the exact flags are implementation detail owned by `fm-brief.sh` when this lands.

### D2. A recall audit trail is a prerequisite, built into this design, sequenced first

One append per `fm-recall.sh` invocation into a gitignored state file: timestamp, caller seam, query hash, exit state, result count.

- **Query hash, never query text.**
  This is a decision, not an omission: a query can carry the substance of what someone was working on, and brain content is private to a home.
  What the hash buys is that free-text queries never land in a file on disk, so no person, backup, or later tool that ingests state files learns what was asked by reading the trail.
  What it does not buy is resistance to a guess, because the hash is unkeyed: anyone who can propose a candidate query can hash it and see whether that digest is already in the trail.
  What that costs differs by seam, so it is stated for each of the four seams this decision names rather than once for all of them:
  - Brief-scaffold queries are the task's own words, and task titles are readable from the backlog, so the candidate set is small and cheap to test - the weakest of the four, and the one D6's trigger reads, which is worth saying plainly instead of averaging away.
  - Dashboard queries are operator free text with no enumerable source to draw candidates from, so the hash withholds real content there.
  - Stow queries are the candidate learning's own content (D5), so a guess has to reproduce that text before the digest can confirm it.
  - Eval queries come from an evaluation set file, and the default set is tracked in this repository, so its questions are already public and the hash is protecting nothing that was private.
  The price, accepted deliberately, is that the trail can never answer "what were people searching for" - only whether recall ran, from where, and with what outcome.
- **The caller-seam field must distinguish** brief-scaffold, stow, dashboard, and eval invocations, or the trail cannot measure adoption, which is its purpose.
- **The trail must make pre-commission recall computable**: joined against task creation times, it must answer "was a recall run before this investigation was commissioned" (see D6 for why this specific question matters).
- **Who reads it, and when**: firstmate reviews the trail one week after the mount lands and again at 30 days.
  No seam-tagged brief-scaffold records while briefs were scaffolded means the mount is not exercising - an implementation defect to fix, not a finding to file.
  See D6 for the pre-commission reading and its trigger.
- Without a brain, what the trail holds is whatever still calls `fm-recall.sh`, taken seam by seam across the four above: nothing from D1 or D4, which do not run; two failed invocations per `/stow` from D5; and one record per dashboard or eval search, since both of those seams already call the wrapper today, independently of this design.
  Whatever it holds, it must never block or slow the read path it measures.

Without this trail, neither the mount's adoption nor its effect on re-derivation can ever be demonstrated - the loop's brokenness would stay unmeasurable one level up.

### D3. The worker-facing embed is hard-gated on the answer-protocol behavior

The brain cannot signal a miss, so an unframed embed would feed plausible irrelevant pages into every commissioned brief as trusted context - worse than today's unread brain.

The gate is **positive detection of behavior**, per home, at scaffold time: the installed `fm-recall.sh` must be observed to emit a framed nearest-or-none answer and per-result provenance carrying capture date and source state.
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
It is surfacing, not enforcement: nothing forces firstmate to read it, and its efficacy is measurable through the D2 trail.

### D5. `/stow` mounts a round-trip read - advisory, ungated, with a hard constraint

Before admitting a "new" learning to always-loaded memory, `/stow` runs one `fm-recall.sh search` at scope local over pruned notes for prior art; before creating a new pruned note, it runs a second search, also scope local, for an existing equivalent.
Both are pinned to scope local for the same reason D1 is: the three mounts this ADR adds - D1, D4, and D5 - all read this home's own corpus and none reaches the remote main brain, and inheriting the wrapper's default scope would mount one.
This fixes the only demonstrated defect in this area - the 2026-08-05 to 2026-08-16 round-trip - at the moment it occurs, which no other seam reaches (nothing is commissioned at prune time).

The constraint, which is not optional: **the read is advisory; a search hit may never, on its own, be the reason a learning is not captured.**
The brain always returns something, so "search found a match" would silently veto genuinely new learnings - and unlike the brief case, whose failure mode is visible added noise, this failure mode is invisibly deleted knowledge.
Concretely:

1. A decision not to admit a learning rests on an actual content comparison of the candidate against the new fact - never a hit count, a score, or "search returned something".
2. Symmetrically, a returned page is a candidate to read, never by itself proof an equivalent note exists.
3. Every case where a `/stow` read leads to something not being captured is recorded through the D2 trail: seam, result count, and the conclusion reached.

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

### D7. The split-by-kind rule conflicted with itself, and this design resolves it - with a third category the captain did not name

The captain's rule: deterministic safety rules and procedure stay in files because retrieval can fail; dated evidence and per-variant detail become retrieval.
On `harness-adapters`, those clauses collide: the per-variant sections **are** spawn procedure - trust dialogs, submission mechanics, exit paths - the same bytes are both.
A retrieval miss at spawn time means not knowing how to answer a trust dialog on a pane that is already waiting.

**Resolution: the safety clause wins.**
Per-variant harness procedure does not go to the brain.
It goes into per-harness files loaded deterministically by the resolved harness name - a third category, **file-to-file routing**, which is neither "stays in the always-loaded file" nor "becomes retrieval", and is better than both here: the load is deterministic, the failure mode is nonexistent, and the token cost falls to the variant actually being spawned.

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

- Brief-scaffold search: measured 242-879 tokens of output per commissioned task, ~0.75s, zero hosted tokens; zero cost for sessions that commission nothing.
- Nearest-prior-work line: one stdout line at scaffold time.
- `/stow` round-trip: two sub-second local searches per invocation (D5).
- Audit trail: one local file append per recall; no context cost.
- Always-cost added to any session: **zero** - of the four seams listed above, each is paid only when its own trigger fires, and none charges the startup files or the per-session context unconditionally.

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
- Retrieval there is an always-cost: 242-879 measured tokens per session, paid whether or not the session needs it, against ~50 tokens saved by pruning one more conditional fact - roughly a 12x-worse trade at the measured sizes.
- A brain read inside the digest adds failure surface to the most safety-critical path firstmate has, for the above negative return.
- And specifically for `context_pack`: the live probe on 0.46.21.0 returned an empty pack on this corpus, because capture writes pages, not the entities and facts `context_pack` packs.
  The candidate mechanism is not merely a poor trade here; it is currently inert on this fleet's data.

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
| D1 brief embed | Scaffold's existing presence branch omits the Brain section entirely - shipped behavior today | Wrapper timeout bounds the wait (60s default; measured worst case with a dead embed endpoint ~8.6s); on failure exits distinguish never-started from read-and-empty, and the scaffold falls back to the instruction-only section | Embed does not mount (positive detection, D3); instruction-only section ships |
| D4 nearest-prior-work line | Not printed | Same bounds as D1; absence of the line is silence about proximity, never a claim | Prints regardless (advisory; not gated) |
| D5 stow round-trip | `/stow` reaches the same outcome as today, having newly done and failed work: two `fm-recall.sh` searches per invocation that fail their source, after which the advisory step is skipped and capture proceeds | Advisory step waits or is skipped; capture is never blocked by a read | Runs regardless (advisory; not gated) |
| D2 audit trail | Appends one record per invocation of whatever still runs: nothing from D1 or D4, two failed-invocation records per `/stow` (D5), and one per dashboard or eval search, both of which call `fm-recall.sh` today independently of this design; the appends are gitignored and block nothing | Appends locally; never blocks or slows the read it records | Independent of it |

## Consequences

- **Nothing lands alone**: the D1 embed mounts only on homes passing the D3 contract detection (`fm-gbrain-answer-protocol` landed as PR 185 and this home passes; other homes gate themselves), and brain-destined offload is inert until the capture-trust gate passes.
  The captain should read the relief timeline in "The net, honestly" as the schedule: routing now, retrieval as homes pass the gate, deep offload last.
- The D2 trail's privacy trade is permanent: adoption and outcomes are measurable forever, and free-text queries are never written down, which resists reading the trail but not guessing against it - unevenly across the four seams D2 enumerates, and weakest at the brief scaffold, where the backlog supplies the candidates.
- D6 leaves a known, named gap open, with a dated instance and a concrete reopening trigger; anyone reading this ADR should not mistake D4's scaffold-time line for coverage of it.
- Alarm fatigue is the named risk of D4; the mitigation is its honest name and claim, and the D2 trail is how a fatigued, skimmed-past line would be detected (surfacing that never changes a dispatch decision).
- The recurring defect this interview kept meeting, in three different coats, is a positive standing without evidence: a search hit as a verdict, a capability assumed present, a check defaulting to "fine".
  The one-sentence rule that guards all of them: the brain may tell you where to look; it may not tell you that you have looked.
  It then appeared a fourth time, in this ADR's own prose - in the sentences written to fix the first three, which asserted properties over a set of seams nobody had enumerated: "the trail holds those failed invocations and nothing else", "the one difference the check found", "queries derive from task titles".
  Each was false exactly at the seams left uncounted, which is the most transferable lesson here and the general form of the same defect: a claim about a set is evidence only when the set is on the page, so scope it to an enumeration the reader can see or do not make it.
- Implementation is follow-up tracked work, per item: the audit trail (first), the scaffold search with its two outputs and two gates, the `/stow` advisory step, the `harness-adapters` split, and the tranche moves - each through the project's normal delivery path.
  This ADR authorizes none of them to skip their own validation.

## Open captain choices

Two choices surfaced by this design belong to the captain and are registered as captain-held items in the fleet's decision ledger; they are listed here so they cannot be lost in prose.

1. **The post-gate budget target** (`budget-target-post-gate`): keep the effective 7,500, or lower it toward 5,500 and then 5,000 as capture-tightening recommends once its gates pass and the tranches land.
   The budget knob is the captain's own local operating choice; nothing in this design moves it.
2. **Acceptance of the split-rule resolution** (`kind-split-safety-resolution`): the captain's own split-by-kind rule conflicted with itself on `harness-adapters`, and this design resolved it toward the safety clause by adding a routing category the rule did not name (D7).
   If the captain resolves it differently, D7 reopens, and so do the two tranche 1 moves whose destination is a per-harness file - the codex entry and the cursor/agy entry, ~305 of tranche 1's ~413 estimated tokens - because those destinations are what D7 creates.
   No other decision in this ADR depends on it: D1 through D6, D8, and D9 each stand whichever way the split rule is resolved.

The session-start reversal (above) is deliberately not a third held item: firstmate ruled that this ADR itself is the captain's decision point for it.
