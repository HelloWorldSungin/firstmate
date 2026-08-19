# Fork divergence ledger

This page is the authoritative ledger of deliberate differences between `HelloWorldSungin/firstmate` and `kunchenguid/firstmate`.
A sync round must preserve every active entry, update an entry when its intent changes, and retire an entry when upstream replaces it.
Task chronology and transient conflict evidence belong in the sync PR rather than this ledger.

## Tracking strategy

The fork follows TRACK, adopted on 2026-08-04.
It periodically takes upstream through full contiguous merges, never through a standing cherry-pick policy and never as a hard fork.
Each round brings one upstream merge through its own reviewable PR, and the configured merge authority lands that PR with a merge commit.
[`sync-upstream`](../.agents/skills/sync-upstream/SKILL.md) owns the round procedure, while [`bin/fm-upstream-status.sh`](../bin/fm-upstream-status.sh) owns drift measurement and the standing trigger verdict.
[`updatefirstmate`](../.agents/skills/updatefirstmate/SKILL.md) remains a separate fast-forward-only update from the fork and never performs an upstream merge.

## Active divergences

### Agy crew adapter

The fork carries an Antigravity CLI adapter so workers can use the operator's paid Gemini subscription.
Upstream has no agy support at all, so every part of it is fork-local.
It is deliberately crew-only and Herdr-only because Herdr supplies the native identity, liveness, working-state, and delivery signals needed to supervise that CLI without treating screen text as authority.
It is not selectable for the primary firstmate or a persistent second mate, and its raw-command bypass is rejected so the kind, backend, trust, and supervision guards cannot be skipped.
The adapter contract lives in [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md), and its executable guards live in `bin/fm-spawn.sh`, `bin/fm-launch-lib.sh`, and [`tests/fm-agy-adapter.test.sh`](../tests/fm-agy-adapter.test.sh).
This entry covered Cursor as well until 2026-08-18; see "Fork-local cursor crew adapter" under retired divergences.

### Pinned ShellCheck download retry budget

The fork keeps its own wall-time download retry budget in [`bin/fm-install-shellcheck.sh`](../bin/fm-install-shellcheck.sh) rather than upstream's `DOWNLOAD_ATTEMPTS` count.
Two fork CI failures on the portable serial lane measured how long a release-CDN blip actually lasts, and a count-based loop gave up while the same run's other installs succeeded; the script's own comment owns that evidence and the constants it justifies.
Upstream re-expressed the budget as a count in `kunchenguid/firstmate@4930d2ca`, which is the first round to collide with it, so a future round must keep the fork's budget rather than reading upstream's loop as newer.

### Watcher restart hand-over

The fork guarantees that `bin/fm-watch-arm.sh --restart` never leaves this home without a live watcher, and never forks a second watcher while the first still holds the lock.
[`tests/fm-watcher-lock.test.sh`](../tests/fm-watcher-lock.test.sh) pins both halves: a fresh watcher takes the lock inside the arm's own stop budget, and the outgoing watcher is gone by the time it does.

The shape of that guarantee changed on 2026-08-18 without the guarantee itself moving.
Upstream's re-arm recovery (`kunchenguid/firstmate#2065`) makes any watcher that arms over a pending downtime marker resurface `check: rearm-resurface` and exit, which for an out-of-band restart would deliver a wake and leave no live watcher at all.
Upstream already models the case where one cycle deliberately succeeds another, through `FM_WATCH_PREDECESSOR_ARM_PID` and its handling-successor launch, so `--restart` now declares itself that successor rather than carrying a fork-local mechanism beside upstream's.
A restart therefore keeps the fork's hand-over guarantee while every other arm path keeps upstream's resurface behavior unchanged.

### Upstream tracking mechanism

This fork carries the optional drift detector, bootstrap diagnostic, sync-round skill and template, and this ledger.
The feature is inert when no `upstream` git remote exists so upstream users do not acquire fork behavior merely by taking another change.
The detector fetches only into a disposable repository and never changes the source repository's objects, refs, index, branch, or worktree.
A sync request dispatches an isolated merge task and PR rather than merging in the primary copy or extending `/updatefirstmate` with merge behavior.

### Repository-local validation evidence

The fork keeps `.no-mistakes.yaml` `test.evidence.store_in_repo` set to `false`, confirmed on 2026-08-14, so routine test evidence stays local instead of becoming committed repository content.
Upstream flipped the same key to `true` in `kunchenguid/firstmate@12384026`.
That commit was reached on 2026-08-18 and the flip was resolved back to `false` with the fork's own explanatory comment retained.
The file does not conflict textually, so git takes the flip silently: every future round that touches it must re-check the value rather than trusting a clean merge.
Upstream's later `kunchenguid/firstmate#2548` and `kunchenguid/firstmate#2549` reconcile upstream's own docs to `true`; this fork does not adopt that setting, so it does not adopt those doc reconciliations either.

### Upstream-read-only posture in shared tracked docs

The fork adds a sixth [`AGENTS.md`](../AGENTS.md) hard rule, "Never write to a third-party upstream repository", adopted on 2026-08-16.
It is inserted as rule 2 rather than appended, so the previous rules 2 through 5 are renumbered to 3 through 6.
That renumbering is a guaranteed collision surface in every future sync round because upstream's list keeps the pre-insertion numbering, and the next person merging should expect a conflict in the whole hard-rule block rather than discovering it mid-merge.
[`tests/fm-agents-hard-rules.test.sh`](../tests/fm-agents-hard-rules.test.sh) pins the numbering shape, the boundary each numeric hard-rule citation in tracked prose is expected to name, and the boundary's required clauses, so a merge that flattens the rule away, drops one of its clauses, or leaves a citation pointing at the rule that inherited its number fails loudly instead of silently.
The citation below is registered in that test, so a future insertion above the upstream boundary cannot quietly retarget it.
The rule is written for this fork specifically because the fork is the case that has a third-party upstream at all.

[`CONTRIBUTING.md`](../CONTRIBUTING.md) drops upstream's instruction to clone the parent or point a local `origin` back at `git@github.com:kunchenguid/firstmate.git`, and tells a contributor to clone this repository so `origin` is the repository their PR opens against.
A full upstream merge must not restore that instruction, because pointing a fork contributor's `origin` at the parent is the exact misconfiguration hard rule 2 forbids.
No test guards `CONTRIBUTING.md`'s content, so this ledger entry is the only standing record of intent for that half and must be consulted when a sync round touches the contributor workflow section.
[`README.md`](../README.md)'s install instruction still clones upstream rather than this fork, a known and deliberately unresolved divergence tracked in `HelloWorldSungin/firstmate#172`, and a sync round must not read it as evidence that this fork intends upstream as its PR base.

## Retired divergences

### Fork-local remote doctor - retired 2026-08-04

The fork's own 53-line `bin/fm-remote-doctor.sh` design was retired in favor of upstream's remote-second-mate implementation.
Firstmate made that collision decision under the already adopted TRACK strategy after the authorized sync round exposed two independently built versions of the same capability.
Keeping the smaller fork implementation would have selected permanent semantic divergence despite the decision to follow upstream through full merges.
The upstream implementation was also the safer of two not-yet-live paths in this fleet because no registered second mate was using the fork implementation, upstream carried its own broader job-worker and doctor tests, and the fork's compatible `fm-remote-inherit*` additions could survive alongside it.
This is the precedent for future capability collisions: apply TRACK to prefer upstream while preserving compatible fork-only intent, and escalate a genuine contradiction rather than silently blending two designs.

### Fork-local composer blank fold - retired 2026-08-18

The fork's `fm_composer_blank_normalize` and its `FM_COMPOSER_BLANKS` list were retired in favor of upstream's `FM_COMPOSER_UNICODE_SPACES` normalization, adopted with the composer consolidation in `kunchenguid/firstmate#2102`.
Upstream's set is derived from the Unicode `White_Space=Yes` property rather than an enumerated guess, and it covers U+00A0, the only pad the fork's own incident evidence ever observed.
The one behavior the fork gives up is folding the zero-width format characters U+200B and U+FEFF, which upstream deliberately excludes because Unicode gives them `White_Space=No`.
That loss is safe in the one direction that matters: a composer padded with a zero-width character reads `pending`, which defers injection and eventually raises the wedge alarm, rather than injecting on an unproven verdict.
This is the third capability collision resolved by the remote-doctor precedent above.

### Fork-local cursor crew adapter - retired 2026-08-18

The fork's own Cursor Agent CLI adapter was retired in favor of upstream's cursor support, adopted with `kunchenguid/firstmate#2238` and `kunchenguid/firstmate#2305`.
The captain made that collision decision on 2026-08-14 from the evidence in the fork's upstream evaluation, under the already adopted TRACK strategy.
The fork's design rested on trusting Herdr's native `agent_status` for cursor, which the fork's own issue 140 proved untrustworthy - Herdr reports a Cursor pane `blocked` in every state - so it could not be incrementally repaired.
Upstream instead reads cursor's own durable per-conversation transcript, which is backend-agnostic, and is verified from crewmate through primary on both tmux and Herdr with its own regression suites.
Retiring the fork arm also removed the standing cost of carrying a parallel implementation of a harness upstream actively develops, on the fork's highest-collision files.
Concretely, the round deleted the fork's cursor launch template, its crew-only and Herdr-only spawn gates, its cursor half of the raw-launch restricted-harness guard, and its cursor arm of the Herdr atomic-prompt submit path, and narrowed the shared cursor/agy mechanisms - the native-idle debounce in `bin/fm-transition-lib.sh`, the identity-gated Herdr busy arm, and the adapter suite now at [`tests/fm-agy-adapter.test.sh`](../tests/fm-agy-adapter.test.sh) - to agy alone.
Cursor is now an ordinary verified harness here, so `AGENTS.md` section 4's crew-only, Herdr-only sentence restricts agy alone.
This is the fourth capability collision resolved by the remote-doctor precedent above.

## Parked branches outside the fork baseline

The branches below are deliberately unlanded and are not part of fork `main` or any upstream sync round:

- `fm/fm-afk-injection-wedge`
- `fm/fm-crew-state-blind-during-fix-round`
- `fm/fm-parked-decision-stale-noise`
- `fm/fm-subagent-model-routing-guard`
- `fm/fm-vault-drift-check`

Their presence on a remote is not authorization to merge, rebase onto, resurrect, or cherry-pick from them.
Remove or reclassify an entry only when the branch's underlying decision is resolved through its own work.

## Maintaining the ledger

Keep only current intent and concise safety rationale here.
A sync PR that creates, changes, adopts upstream for, or retires a deliberate divergence updates this page in the same round.
Use full `owner/repo#number` references when a durable rationale needs a PR pointer because fork and upstream numbers occupy separate overlapping spaces.
