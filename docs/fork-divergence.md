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
The adapter contract lives in the [`harness-adapters` skill's agy variant file](../.agents/skills/harness-adapters/harnesses/agy.md), and its executable guards live in `bin/fm-spawn.sh`, `bin/fm-launch-lib.sh`, and [`tests/fm-agy-adapter.test.sh`](../tests/fm-agy-adapter.test.sh).
Herdr's atomic agy prompt emits a fork-local `unverifiable` send verdict for an acceptance it can prove neither way, which `bin/fm-send.sh` keeps distinct from upstream's `pending`: both exit 3, but `unverifiable` marks the request's delivery state unknown while `pending` discards it as undelivered.
This entry covered Cursor as well until 2026-08-18; see "Fork-local cursor crew adapter" under retired divergences.

### Pinned ShellCheck download retry budget

The fork keeps its own wall-time download retry budget in [`bin/fm-install-shellcheck.sh`](../bin/fm-install-shellcheck.sh) rather than upstream's `DOWNLOAD_ATTEMPTS` count.
Two fork CI failures on the portable serial lane measured how long a release-CDN blip actually lasts, and a count-based loop gave up while the same run's other installs succeeded; the script's own comment owns that evidence and the constants it justifies.
Upstream re-expressed the budget as a count in `kunchenguid/firstmate@4930d2ca`, so a round must keep the fork's budget rather than reading upstream's loop as newer.
That collision was reached on 2026-08-19 with `kunchenguid/firstmate#2546`, which also added multi-platform archive selection; the platform coverage was taken and the fork's wall-time budget kept, and `tests/fm-lint.test.sh` now pins the fork's two budget cases to linux/x86_64 so their pinned checksum stays the archive the installer selects on any host.

### LLM quota sidecar

The fork carries a host-published LLM quota reader, [`bin/fm-quota-sidecar.sh`](../bin/fm-quota-sidecar.sh) with [`tests/fm-quota-sidecar.test.sh`](../tests/fm-quota-sidecar.test.sh), which upstream has no equivalent of.
It exists because this fleet's crew-dispatch array routes to minimax, zai, opencode-go, and antigravity, four providers `quota-axi` does not model at all; without it those candidates have no evidence surface rather than a stale one, and a disclosed `UNKNOWN` with a measured age is a materially different dispatch input than silence.
The reader is additive evidence only and never merges, caches, ranks, or recommends routes.

Upstream's `kunchenguid/firstmate#2574` adopted `spendPriority` as the single quota-perspective ranker, which first collided with this entry on 2026-08-19.
The two do not compete and this is not a capability collision, so the remote-doctor precedent below does not apply: `spendPriority` ranks, while the sidecar supplies eligibility evidence for providers that ranker cannot see.
The reconciliation keeps upstream's TOON-first spine intact - the sidecar is a separate reader rather than a `quota-axi --json` call - confines sidecar evidence to the eligibility gate, and leaves `spendPriority` the sole ranker.
Where both sources cover a provider, `quota-axi` wins for selection and the sidecar stays corroborating diagnostic evidence with material disagreement disclosed.
Stale, missing, error, and unmodeled sidecar results all remain disclosed eligibility uncertainty and never become headroom, runway, a healthy default, or a block.
[`.agents/skills/quota-array-dispatch`](../.agents/skills/quota-array-dispatch/SKILL.md) owns that freshness and degradation policy, and [`docs/configuration.md`](configuration.md) owns the `fm-quota-sidecar.v1` producer contract.
This divergence went unrecorded from its introduction until 2026-08-19, which is why the collision arrived mid-merge instead of as a known one.

### Watcher restart hand-over

The fork guarantees that `bin/fm-watch-arm.sh --restart` never leaves this home without a live watcher, and never forks a second watcher while the first still holds the lock.
[`tests/fm-watcher-lock.test.sh`](../tests/fm-watcher-lock.test.sh) pins both halves: a fresh watcher takes the lock inside the arm's own stop budget, and the outgoing watcher is gone by the time it does.

The shape of that guarantee changed on 2026-08-18 without the guarantee itself moving.
Upstream's re-arm recovery (`kunchenguid/firstmate#2065`) makes any watcher that arms over a pending downtime marker resurface `check: rearm-resurface` and exit, which for an out-of-band restart would deliver a wake and leave no live watcher at all.
Upstream already models the case where one cycle deliberately succeeds another, through `FM_WATCH_PREDECESSOR_ARM_PID` and its handling-successor launch, so `--restart` now declares itself that successor rather than carrying a fork-local mechanism beside upstream's.
A restart therefore keeps the fork's hand-over guarantee while every other arm path keeps upstream's resurface behavior unchanged.

### Run-progress wedge hold

The fork carries [`bin/fm-run-progress.sh`](../bin/fm-run-progress.sh), which upstream has no equivalent of, and threads a per-pane hold-count file through `wedge_timer_check` in [`bin/fm-watch.sh`](../bin/fm-watch.sh) so a wedge escalation is held while the crew's validation run is demonstrably still moving.
That hold-count file is a required fifth parameter here and does not exist upstream, so every upstream change that adds a `wedge_timer_check` caller arrives one argument short and must be threaded through rather than taken verbatim.
It first collided on 2026-08-20 with `kunchenguid/firstmate#2619`, whose new `busy_turn_bound_check` absorber was adopted with the fork's hold-count argument added to its signature and its call.
`bin/fm-classify-lib.sh`'s `crew_wedge_progress` owns the policy and [`docs/architecture.md`](architecture.md) owns the supervisor-facing contract.

### Herdr pre-Enter footer read on a native working baseline

The fork skips the pre-Enter rendered-footer read entirely when herdr's native agent-state baseline is already `working`, because the rendered-footer conversion refuses a `working` baseline outright and the read can therefore produce no verdict.
Upstream reads that footer unconditionally whenever the baseline is not legibly idle.
The skip is behaviour-neutral and saves one pane read per submit, but it shifts the adapter's CLI call sequence by one on that baseline, so upstream tests that pin response indices for a `working` baseline need renumbering rather than being taken verbatim.
That renumbering was first applied on 2026-08-20 for the two `kunchenguid/firstmate#2647` cases in [`tests/fm-backend-herdr.test.sh`](../tests/fm-backend-herdr.test.sh) that assume the extra read.

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
Both were reached on 2026-08-19 and were not adopted; that round's merge conflicted on the explanatory comment alone while the value stayed `false`, which is exactly why the value must be re-read rather than trusted to a clean merge.

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

### GBrain per-home knowledge memory

The fork carries GBrain as per-home task-knowledge memory - search through [`bin/fm-recall.sh`](../bin/fm-recall.sh), capture through [`bin/fm-gbrain-capture.sh`](../bin/fm-gbrain-capture.sh), and the serving, pin, scoping, evaluation, and deployment tooling around [`bin/fm-gbrain.sh`](../bin/fm-gbrain.sh) - and upstream has no equivalent of any of it.
The fork-only files are the cheap half of every sync round; the recurring review cost is fork behavior inserted into paths upstream also owns.
Bootstrap calls the GBrain serving and pin checks and the periodic captured-knowledge sweep, and emits the `GBRAIN_SERVING_CREDENTIAL:`, `GBRAIN_PIN:`, and `GBRAIN_CAPTURE:` diagnostics in [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) with their handling contract in the [`bootstrap-diagnostics` skill](../.agents/skills/bootstrap-diagnostics/SKILL.md), and session start composes that serving-credential state into its detect-only digest in [`bin/fm-session-start.sh`](../bin/fm-session-start.sh).
Brief generation sources the fork-only brain library and injects a `# Brain` section into each relevant scaffold in [`bin/fm-brief.sh`](../bin/fm-brief.sh).
The inherited-config paths [`bin/fm-config-inherit-lib.sh`](../bin/fm-config-inherit-lib.sh), [`bin/fm-remote-inherit.sh`](../bin/fm-remote-inherit.sh), and [`bin/fm-remote-inherit-push.sh`](../bin/fm-remote-inherit-push.sh) source GBrain validation and special-case `config/gbrain.json` on the inherited shared plane.
Teardown captures the finished task's knowledge, republishes the capture receipt, and removes `state/<id>.gbrain` in [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), while [`AGENTS.md`](../AGENTS.md) and the `secondmate-provisioning` and `stow` skills carry the always-loaded recall instruction, the retirement-time client revocation, and the `/stow` capture calls.
The shared test routing and documentation catalogs carry the rest of the surface: [`bin/fm-test-run.sh`](../bin/fm-test-run.sh), `tests/fm-bootstrap.test.sh`, `tests/fm-brief.test.sh`, and `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`, plus `docs/architecture.md`, `docs/configuration.md`, `docs/documentation-audiences.json`, and `docs/scripts.md`.
A merge must preserve the read-only main-brain share that [`gbrain-scoping.md`](gbrain-scoping.md) owns: every home writes only its own brain, a reading home reaches the main brain only over its read-scoped client, and the write refusal is GBrain's own scope check rather than a Firstmate-side policy layer.
A merge must also preserve the presence-gating that [`gbrain-capture.md`](gbrain-capture.md) owns: a home with no brain creates no outbox, writes no receipt, and behaves exactly as it did before GBrain existed, and capture can never fail a teardown.
[`tests/fm-gbrain-readonly-e2e.test.sh`](../tests/fm-gbrain-readonly-e2e.test.sh), [`tests/fm-gbrain-capture.test.sh`](../tests/fm-gbrain-capture.test.sh), and [`tests/fm-recall.test.sh`](../tests/fm-recall.test.sh) pin those boundaries, with the dated share evidence in [`verification/gbrain-readonly-share.md`](verification/gbrain-readonly-share.md).

### Fleet dashboard and agent-event instrumentation

The fork carries a read-only fleet dashboard - the server and routed destinations behind [`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs) and [`assets/dashboard/`](../assets/dashboard), plus the agent-event store and emitter the dashboard itself owns - and upstream has no equivalent of any of it.
Two of its destinations render durable records the fleet owns rather than the dashboard: the completion manifests at `data/<id>/outcome.json` that [`fleet-data-contracts.md`](fleet-data-contracts.md) owns and [`bin/fm-outcome-manifest.sh`](../bin/fm-outcome-manifest.sh) composes, and the opt-in token-usage store at `data/usage.db` that [`usage-accounting.md`](usage-accounting.md) and [`bin/fm-usage.mjs`](../bin/fm-usage.mjs) own, both equally absent from upstream but neither removable as dashboard behavior.
Its recurring merge cost is likewise attachment rather than fork-only files: [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) composes the per-harness event emitters into the same per-task hook files the busy-state contract already owns, so every upstream change to hook construction arrives with fork wiring sitting beside it.
Teardown publishes both of those fleet-owned records inside the upstream-owned [`bin/fm-teardown.sh`](../bin/fm-teardown.sh): a best-effort refresh of the task's usage sessions that never blocks cleanup, and the completion manifest composed while the volatile records feeding it still exist; the same opt-in refresh is wired into the upstream-owned [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) at a locked session boundary, bounded by `FM_BOOTSTRAP_USAGE_TIMEOUT` and reporting on its own `USAGE_STORE:` diagnostic line.
The manifest publication deliberately blocks the lifecycle - teardown refuses to erase a task whose manifest could not be written, because a task that cannot be archived must not be erased - so a merge must preserve that refusal rather than relax it into a best-effort skip on the strength of this entry's off-the-critical-path posture.
[`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) and its `fm-fleet-snapshot.v1` contract are upstream-owned, so the divergence is the dashboard-consumed fields the fork adds to that snapshot, among them the quiet window owned in [`bin/fm-supervision-lib.sh`](../bin/fm-supervision-lib.sh) and consumed by [`bin/fm-watch.sh`](../bin/fm-watch.sh), published as `quiet_allowance_seconds` so the dashboard judges quiet on supervision's own tolerance rather than inventing a second one.
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) pins the Node 22 floor the usage collector requires, and [`bin/fm-test-run.sh`](../bin/fm-test-run.sh) classifies `tests/fm-dashboard-browser.test.sh` into the opt-in `live-harness-optin` family so the one suite needing a real browser stays out of every portable lane.
`tests/lib.sh` redirects the event config, the event store, and the dashboard credentials into a throwaway isolation root so no fixture home can reach a developer's real instrumentation, and `docs/configuration.md`, `docs/documentation-audiences.json`, and `docs/scripts.md` are the documentation catalogs this subsystem shares with the GBrain entry above.
A merge must preserve the additive wiring property that [`dashboard-events.md`](dashboard-events.md) owns: instrumentation is off until enabled, the wiring is absent entirely when off, and the emitter exits 0 on every path, writes nothing to either stream, and does its work in a detached child, so an entry firing beside the turn-end guard or the watcher auto-arm can never change that guard's exit status, output, timing, or ordering.
[`tests/fm-dashboard-events.test.sh`](../tests/fm-dashboard-events.test.sh) pins that by running the real guards in two identical homes with the emitter firing against a deliberately hung dashboard and requiring an identical decision from both.
A merge must also keep the dashboard off the fleet's critical path as [`dashboard.md`](dashboard.md) owns: the dashboard writes nothing a fleet program owns, its own writes go to the event store it owns outside the operational home, and stopping it has no effect on Firstmate supervision.
That rule has one granted exception that [`dashboard-events.md`](dashboard-events.md) owns and [`bin/fm-dashboard-install.sh`](../bin/fm-dashboard-install.sh) emits: a `ReadWritePaths` grant for `data/gbrain/`, because a GBrain search updates the index it reads.
The grant names the brain directory alone, so `data/` itself and every fleet record under it stay read-only to the service, and a merge must not read that grant as a violation of the rule above and narrow it away.
This entry and the GBrain entry above are bridged by the dashboard surfaces that read the home's brain read-only rather than duplicating it - the Knowledge view and health strip served behind [`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs) from `assets/dashboard/gbrain.js`, the read-only snapshot [`bin/fm-gbrain-health.sh`](../bin/fm-gbrain-health.sh) takes, the capture status the History view reads off each outcome record, and the `tests/fm-dashboard-gbrain.test.sh` and `tests/fm-dashboard-gbrain-ui.test.sh` suites that pin them - alongside the `data/gbrain/` grant above that lets a search write the index it reads.

## Retired divergences

### Separate decision-hold lifecycle - retired 2026-08-24

The fork's separate decision records and `decision-hold-lifecycle` completion owner were retired in favor of upstream's ordinary task held for the captain, adopted with `kunchenguid/firstmate#2728`.
This was a capability collision under the remote-doctor precedent: both implementations preserved unresolved captain calls across investigation completion, but upstream made the backlog task itself the identity and removed the parallel decision concept.
The fork's compatible guarantee for interactive design tasks survives by loading `captain-hold-lifecycle`, using `bin/fm-captain-hold.sh verify` during non-forced design teardown, and pinning that gate in `tests/fm-captain-hold-lifecycle.test.sh`.
The old skill and command remain only as one-release compatibility pointers for already-dispatched work; the old mechanism document and standalone test suite were retired after their surviving coverage moved to the upstream owner.

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

### Fork-local herdr queued-Enter conversion - retired 2026-08-20

The fork's own retries-exhausted busy-queue conversion in `bin/backends/herdr.sh` - a tail composer re-read plus a native agent-state read classified with the adapter's submit vocabulary, guarded by an explicit `baseline_raw != blocked` short-circuit - was retired in favour of upstream's shared `fm_composer_queued_enter_verdict` policy, adopted with `kunchenguid/firstmate#2647`.
Firstmate made that collision decision on 2026-08-20 under the already adopted TRACK strategy, applying the remote-doctor precedent above to two independently built implementations of one capability.
Upstream's version puts the policy in `bin/fm-composer-lib.sh` where tmux and herdr both consume it, so the fork stops carrying a second copy of a decision on its highest-collision file.
The blocked-baseline safety property the fork's guard existed for survives structurally rather than as a special case: upstream's `fm_backend_herdr_queued_enter_busy` counts only native `working` as delivery-busy, so a pane that was already blocked at a permission prompt still keeps the honest `pending` verdict that `HelloWorldSungin/firstmate#84` requires.
One behaviour narrows in the safe direction: a pane that reaches `blocked` only as a result of our Enter used to be converted to `empty` at the tail and now reports `pending`, so such a send is reported delivered-unconfirmed rather than confirmed.
The in-loop fast path is unchanged and still confirms that same transition, so the narrowing applies only after the full Enter retry budget is spent.
[`tests/fm-backend-herdr.test.sh`](../tests/fm-backend-herdr.test.sh) keeps the fork's blocked-baseline regression against the new implementation, and [`docs/herdr-backend.md`](herdr-backend.md) remains the operator-facing owner of that boundary.
This is the fifth capability collision resolved by the remote-doctor precedent above.

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
