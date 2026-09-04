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
The adapter contract lives in the [`harness-adapters` skill's agy reference](../.agents/skills/harness-adapters/references/harness/agy.md), reachable through that skill's routing artifact, and its executable guards live in `bin/fm-spawn.sh`, `bin/fm-launch-lib.sh`, and [`tests/fm-agy-adapter.test.sh`](../tests/fm-agy-adapter.test.sh).
Herdr's atomic agy prompt emits a fork-local `unverifiable` send verdict for an acceptance it can prove neither way, which `bin/fm-send.sh` keeps distinct from upstream's `pending`: both exit 3, but `unverifiable` marks the request's delivery state unknown while `pending` discards it as undelivered.
Upstream's durable steering inbox (`kunchenguid/firstmate#2856`, reached 2026-08-25) moved ordinary local text off the typed submit path, so both verdicts now describe the typed plane alone - a harness-native invocation or an explicit backend target - while an ordinary steer's delivery is its durable record.
The distinction itself is unchanged and still exits 3 either way; a round that touches the send verdicts must re-read which plane it is changing before assuming a verdict is dead code, and `tests/fm-agy-adapter.test.sh` names that plane explicitly so a verdict case cannot go vacuous by silently riding the inbox.
The inbox plane still owes this adapter its atomic prompt: a steering-inbox doorbell is ordinary text, so `fm_task_inbox_ring` takes the target's harness and passes it to the shared submit dispatch, without which cursor and agy would fall back to the typed composer text this entry exists to avoid.
Every ring caller - `bin/fm-send.sh`, `bin/fm-watch.sh`, and `bin/fm-remote-secondmate-control.sh` - resolves that harness from the target's own metadata, and the regression pinning it is `test_ordinary_agy_steer_rings_doorbell_through_atomic_prompt`.
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

### Scout completion gate reopened by a firstmate steer

A steer to a scout that already reported its captain calls reviewed reopens that completion gate in `bin/fm-send.sh`, because the follow-up can surface new calls and a stale `decisions_reviewed=1` would let teardown erase the task past the gate `captain-hold-lifecycle` owns.
Upstream has no equivalent, and the reopen lives inside an upstream-owned script, so it is a recurring merge cost rather than a fork-only file.
Its trigger is whatever counts as delivery on the plane the steer takes: a confirmed submit on the typed plane, restored when the send proves failed and deliberately left open when the submit is unconfirmed; and the durable enqueue on the steering-inbox plane upstream added in `kunchenguid/firstmate#2856`, restored when the record cannot be written.
That second half was added on 2026-08-25 when the inbox plane first collided with this divergence: an ordinary local steer stopped reaching the typed path at all, which would have silently retired the gate.
[`tests/fm-send-strict.test.sh`](../tests/fm-send-strict.test.sh) pins both planes, including the failure directions, so a future round that changes plane selection fails loudly instead of dropping the gate.
This divergence went unrecorded from its introduction on 2026-08-12 until 2026-08-25.

### Pre-move crash fixture does not perform the move it simulates crashing before

`tests/fm-backlog-handoff.test.sh`'s pre-move crash case arrived from upstream with a `tasks-axi` stub that kills the handoff and then execs the real `mv` anyway, leaving an orphan that lands the move about a second later.
Every later assertion that the item is still in the source backlog then holds or fails on how fast the runner is, which is why the case passes locally and failed the fork's CI on `kunchenguid/firstmate#2848`'s first round here.
The fork's stub exits instead of moving, because the scenario it exists to build is a handoff that died BEFORE its move landed.
Reproduced deliberately on 2026-08-25 by widening the window with a three-second wait after the simulated crash: the upstream stub fails that case and the fork's passes.
Upstream will most likely fix this itself, at which point this entry retires in favour of whatever it lands.

### Watcher restart hand-over

The fork guarantees that `bin/fm-watch-arm.sh --restart` never leaves this home without a live watcher, and never forks a second watcher while the first still holds the lock.
[`tests/fm-watcher-lock.test.sh`](../tests/fm-watcher-lock.test.sh) pins both halves: a fresh watcher takes the lock inside the arm's own stop budget, and the outgoing watcher is gone by the time it does.

The shape of that guarantee changed on 2026-08-18 without the guarantee itself moving.
Upstream's re-arm recovery (`kunchenguid/firstmate#2065`) makes any watcher that arms over a pending downtime marker resurface `check: rearm-resurface` and exit, which for an out-of-band restart would deliver a wake and leave no live watcher at all.
Upstream already models the case where one cycle deliberately succeeds another, through `FM_WATCH_PREDECESSOR_ARM_PID` and its handling-successor launch, so `--restart` now declares itself that successor rather than carrying a fork-local mechanism beside upstream's.
A restart therefore keeps the fork's hand-over guarantee while every other arm path keeps upstream's resurface behavior unchanged.

### Watcher stop-signal disposition

The fork's watcher installs no `HUP`/`INT`/`TERM` handler and lets those signals keep their default disposition, where upstream's [`bin/fm-watch.sh`](../bin/fm-watch.sh) installs `trap 'exit 1' HUP INT TERM` beside its `EXIT` trap and re-arms that same handler after the check-spawn deferral in `run_check_capture`.
A stop handler is a string bash parses at the moment the signal arrives, and that parse can fail while the shell is inside a command substitution: bash reports a trap diagnostic, runs no handler, and continues, so the watcher stayed deaf to its own stop for the rest of the poll interval (`HelloWorldSungin/firstmate#242`).
Upstream's triage of the identical diagnostic (`kunchenguid/firstmate#3565`) attributes it to a runtime-built handler restored through `trap -p` and `eval`, machinery neither repo carries, so adopting that direction would reinstall a parsed handler rather than remove the parse that fails.
Both upstream `trap 'exit 1'` sites are ordinary lines a round can take verbatim, which would silently retire this divergence, so [`tests/fm-watcher-lock.test.sh`](../tests/fm-watcher-lock.test.sh) requires the stopped watcher to exit 143 - true only when no handler is installed - with its singleton lock released and no trap diagnostic on stderr.
The `EXIT` trap is now entered from inside whatever command the signal interrupted and inherits its redirections, so `watcher_cleanup`'s retained-stale-lock warning writes to fd 4, a copy of stderr taken at startup, where upstream writes a bare `>&2`; taking that line back would send the operator's only notice of a deliberately retained stale lock into the `2>/dev/null` of the fork's own cycle wait.

Default disposition also means the herdr event wait's command substitution can be abandoned mid-wait, so the watcher allocates that wait's fifo directory itself, passes it as `FM_BACKEND_EVENT_WAIT_DIR`, and releases both it and the reader pid the adapter records inside it from the watcher's own `EXIT` path.
Upstream's `fm_backend_herdr_wait_transition` always allocates that directory with its own `mktemp -d`, so the caller-owned staging and its fail-closed return for a directory the caller has already released sit inside upstream-owned code in [`bin/backends/herdr.sh`](../bin/backends/herdr.sh) and the contract comment in [`bin/fm-backend.sh`](../bin/fm-backend.sh), with [`tests/fm-backend-herdr.test.sh`](../tests/fm-backend-herdr.test.sh) pinning both halves.
[`verification/supervision.md`](verification/supervision.md#watcher-stop-disposition) owns the measurements, the narrowed `HelloWorldSungin/firstmate#160` burst window, and the residual this leaves.

### Run-progress wedge hold

The fork carries [`bin/fm-run-progress.sh`](../bin/fm-run-progress.sh), which upstream has no equivalent of, and threads a per-pane hold-count file through `wedge_timer_check` in [`bin/fm-watch.sh`](../bin/fm-watch.sh) so a wedge escalation is held while the crew's validation run is demonstrably still moving.
That hold-count file is a required fifth parameter here and does not exist upstream, so every upstream change that adds a `wedge_timer_check` caller arrives one argument short and must be threaded through rather than taken verbatim.
It first collided on 2026-08-20 with `kunchenguid/firstmate#2619`, whose new `busy_turn_bound_check` absorber was adopted with the fork's hold-count argument added to its signature and its call.
It collided there again on 2026-09-02 with `kunchenguid/firstmate#3147`, which restructures that same function so a declared wait is read before the away-mode branch; the new branch was adopted whole and the fork's hold-count parameter kept on the `wedge_timer_check` call below it.
`bin/fm-classify-lib.sh`'s `crew_wedge_progress` owns the policy and [`docs/architecture.md`](architecture.md) owns the supervisor-facing contract.

### Watcher live declared-wait routing and self-widening recheck cadence

The fork routes a LIVE `paused:` or verified `captain-held` declaration into `handle_paused_stale` by changing `pause_state_class` in [`bin/fm-watch.sh`](../bin/fm-watch.sh) itself, where upstream leaves a live agent classified `none` and throttles further down in `surface_nonterminal_stale`.
Without that routing the designed long cadence was unreachable for exactly the crew the generated brief creates: two tasks parked on a human re-surfaced a bare `stale: <window>` every few minutes for the whole wait, measured at 320s, 341s and 449s gaps on 2026-08-14 (`HelloWorldSungin/firstmate#144`, `HelloWorldSungin/firstmate#51`).
The fork also widens the recheck window while one wait stands unchanged, through the `pause_streak_*` records and the shared `pause_resurface_window` owner in [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh) that both supervisors consume, where upstream keeps a fixed `FM_PAUSE_RESURFACE_SECS`.
The divergence lives inside upstream-owned functions on this repo's highest-collision file, so every upstream change to declared-wait handling arrives beside fork routing rather than as a fork-only file.
It first collided on 2026-09-02 with `kunchenguid/firstmate#3155` and `kunchenguid/firstmate#3147`: upstream's busy-pane routing and its away-mode handoff were both adopted, the daemon's `0)` busy arm was dropped as upstream requires while the fork's streak record moved to the surviving `2)` arm, and the fork's per-iteration window replaced upstream's fixed `pause_secs` read.
[`tests/fm-watch-triage.test.sh`](../tests/fm-watch-triage.test.sh) and [`tests/fm-daemon.test.sh`](../tests/fm-daemon.test.sh) pin both halves, the live-declaration routing and the streak reconciliation, beside upstream's own handoff cases, so a round that restores upstream's classification fails loudly instead of silently retiring the cadence.
It collided again on 2026-09-04 with `kunchenguid/firstmate#3268`, which made the away daemon advance a declared wait's recheck marker only when the escalation was actually buffered; that gating was adopted whole and the fork's `pause_streak_bump` moved inside it, so a recheck that was never recorded no longer widens the window it never sent.
This divergence went unrecorded from its introduction until 2026-09-02.

### Herdr pre-Enter footer read on a native working baseline

The fork skips the pre-Enter rendered-footer read entirely when herdr's native agent-state baseline is already `working`, because the rendered-footer conversion refuses a `working` baseline outright and the read can therefore produce no verdict.
Upstream reads that footer unconditionally whenever the baseline is not legibly idle.
The skip is behaviour-neutral and saves one pane read per submit, but it shifts the adapter's CLI call sequence by one on that baseline, so upstream tests that pin response indices for a `working` baseline need renumbering rather than being taken verbatim.
That renumbering was first applied on 2026-08-20 for the two `kunchenguid/firstmate#2647` cases in [`tests/fm-backend-herdr.test.sh`](../tests/fm-backend-herdr.test.sh) that assume the extra read.

### Remote job worker descendant reaping

The fork stops the whole supervised process tree rather than only the serving child in [`bin/fm-remote-job-worker.sh`](../bin/fm-remote-job-worker.sh), because a `--serve` child that spawns its own commands left orphans polling after the supervisor was gone.
`worker_reap_descendants` walks the descendant snapshot and escalates TERM to KILL, an `EXIT` trap runs it on every supervisor exit, `WORKER_STOP` stops a signalled serving child from returning to its poll loop, and exit 125 joins 0 and 75 as a terminal serving-child status the supervisor does not restart.
That replaced upstream's global `WORKER_SUPERVISED_PID` with a supervisor-local `child_pid`, so every upstream change to the restart loop arrives referring to a variable this fork no longer has.
It first collided on 2026-08-26 with `kunchenguid/firstmate#2942`, whose total-restart bound was adopted with the fork's `child_pid` and its terminal exit-125 branch kept, and [`tests/fm-remote-job-orphan-reap.test.sh`](../tests/fm-remote-job-orphan-reap.test.sh) pins the reaping half while `tests/fm-remote-job.test.sh` pins upstream's bound.
It collided again on 2026-09-03 with `kunchenguid/firstmate#3210`, which replaced the single supervised execution with an array of bounded transport lanes and rewrote `worker_stop_active_execution` around it.
Upstream's lane loop was adopted whole and the reap re-threaded to run ahead of it rather than beside each lane, because a lane's serving child spawns its own commands and those orphans are re-parented away from the supervisor the moment that child dies, after which the descendant walk can no longer reach them; a failed reap is folded into the loop's verdict so every lane still releases its recorded claim.
A future round that reorders that call after the lane loop silently retires the entry.

One consequence of the reaping, rather than a second divergence: a whole-group stop of this worker deliberately leaves ownership quarantined.
The supervisor and its serving child share one process group, and `worker_reap_descendants` escalates TERM to KILL in a single pass with no grace between them, so a group signal reaches both at the same instant and the supervisor kills the child between publishing its shutdown quarantine and clearing it.
`worker.pid`, `worker.ready`, `worker.identity`, and `lock/quarantine` therefore all survive such a stop, and the next `fm_remote_job_ensure_worker` refuses rather than starting.
That is the fail-safe working as designed, but it means any fixture that stops this worker in order to reach a stopped-and-releasable state must TERM the recorded serving child first and let it complete its own shutdown; the child's clean exit ends the supervisor with it.
`kunchenguid/firstmate#3299` moved `tests/fm-remote-job.test.sh`'s staged-record tamper setup to a bare whole-tree stop on 2026-09-04 and reached exactly that quarantined state, so the setup was re-sequenced around the child while upstream's assertions were kept byte-identical, with a bounded process-group check added after them so the tree stop cannot pass vacuously on an already-dead pid.
Whether the reap should instead grant its own serving child time to finish shutting down is a change to signal-time supervision behaviour and is deliberately not decided here.
This divergence went unrecorded from its introduction until 2026-08-26.

### Bounded remote job stdin capture

Upstream stops a caller-open stdin from stalling a remote command by handing ssh `/dev/null` unless `--stdin` is passed, taken byte-identical from `kunchenguid/firstmate#3210` on 2026-09-03; the fork keeps a second, independent bound underneath it in [`bin/fm-remote-job-lib.sh`](../bin/fm-remote-job-lib.sh).
`fm_remote_job_capture_stdin` runs the staging read under `FM_REMOTE_JOB_STDIN_TIMEOUT`, so a `--stdin` caller that never closes its stream is refused with `FM_REMOTE_JOB_ERROR` naming the unclosed stream rather than blocking staging forever, and the queue deadline is stamped after that capture so a slow but complete stream spends staging time instead of the budget a worker is given to admit the published job.
That makes [`bin/fm-timeout-lib.sh`](../bin/fm-timeout-lib.sh) a required dependency of the job library rather than an optional one, because degrading silently to the unbounded read is the defect `HelloWorldSungin/firstmate#178` reported.
Upstream's staging carries no time bound at all, so every upstream change to `fm_remote_job_stage` arrives against a capture this fork replaced, and [`tests/fm-remote-job.test.sh`](../tests/fm-remote-job.test.sh) pins the refusal, the byte-for-byte payload on every timeout mechanism arm, and that deadline ordering, so a round restoring the plain read fails loudly.

### Default per-script bound on every test sweep

[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) arms `DEFAULT_PER_SCRIPT_TIMEOUT_SECS` on every standard-mode sweep, introduced on 2026-09-03 in `HelloWorldSungin/firstmate#254`, so a hung script becomes an ordinary `exit=124` red instead of a sweep that ends with no verdict at all - the shape a deadlocked `tests/fm-on.test.sh` cost in `HelloWorldSungin/firstmate#178`.
Upstream bounds only its automatic `--changed` path through `CHANGED_DEFAULT_TIMEOUT_SECS`, which the fork takes unchanged, so a single named script, `--family`, `--lane`, and `--all` are bounded here and unbounded upstream.
Serving that bound, [`bin/fm-timeout-lib.sh`](../bin/fm-timeout-lib.sh) publishes the bounded command's process group id through `FM_TIMEOUT_PGID_FILE` on the arms that can, which is how the runner relays a terminal interrupt into a bounded script's own group rather than leaving it running to the deadline.
The rationale beside the constant owns why 480s and what the bound costs each CI lane, including the accepted margin on the required real-Herdr lane recorded in `HelloWorldSungin/firstmate#256`, and the script's `--help` owns the flag contract and its `0` opt-out.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh) pins the default arming, the opt-out, the exit 124 versus exit 125 distinction, and the signal relay, so an upstream round that rewrites the timeout wiring cannot retire the default silently.

### No-mistakes run attribution

The fork rewrote the branch-and-code-identity rule that binds a no-mistakes run to a task into a named relation table in [`bin/fm-nm-run-lib.sh`](../bin/fm-nm-run-lib.sh) - `fm_nm_head_relation` returning `equal`, `run-ahead`, `run-behind`, `unresolved`, `missing`, or `diverged`, consumed by `fm_nm_head_attributable` - and built the surrounding current-state surface upstream has no equivalent of: the `abandoned` verdict, the degraded run-step replay, and the recorded `branch=` task identity that makes a disagreeing ambient branch an attribution fault rather than another task's run.
Upstream keeps a single boolean head predicate plus a branch-custody exemption, so every upstream change to attribution arrives inside functions the fork rewrote.
`bin/fm-crew-state.sh` and [`tests/fm-crew-state.test.sh`](../tests/fm-crew-state.test.sh) carry that surface, and teardown deliberately uses only the strict equal-or-run-ahead predicate.

It first collided on 2026-09-03 with `kunchenguid/firstmate#3194`, and the reconciliation settled the one question the two designs answer differently.
Upstream's `fm_nm_run_is_pipeline_owned_active` was adopted and is OR'd with the fork's relation table at the `axi status` attribution site, so while `branch_sync.state=pipeline_owned` names a non-terminal run that run binds on any head at all, a `diverged` one included, and outside that custody the relation table alone decides.
The fork's own arm that accepted an `unresolved` head from any live branch-scoped answer was retired in the same pass: it was a proxy for pipeline custody written before `branch_sync` was readable, the fork's own pipeline-owned fixture already declares that state, and keeping it would have admitted a live run on a `synced` branch whose head merely never reached this worktree.
Upstream's separate `fm_nm_head_resolvable` was retired as a second owner of the proven-versus-unknown distinction the `unresolved` verdict already makes, and the coarse runs-listing scan keeps the fork's three-verdict result because that path carries no `branch_sync` evidence to reach the exemption with.
`test_pipeline_owned_unresolvable_head_attributes` and upstream's five new exemption cases pin both halves, so a round that restores the retired proxy or drops the exemption fails loudly.

### Fleet snapshot per-task timeout and abandoned child work

The fork bounds each task's current-state read in [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) with its own `FM_SNAPSHOT_TASK_TIMEOUT`, a floor of 2 so the inner bound sits strictly inside it, a `FM_SNAPSHOT_TASK_NM_TIMEOUT` hand-down to the no-mistakes lookup, a parallel fan-out, and a `source:"timeout"` record for a task that did not answer.
Upstream built the same bound independently as a single `FM_SNAPSHOT_CREW_STATE_TIMEOUT`, so a round must end with exactly one of these contracts rather than both names on one file.
The fork also carries `abandoned_children` beside upstream's `active_children` through the snapshot, the per-home summary ledger, and the bearings Underway rows.

Both halves collided on 2026-09-03 with `kunchenguid/firstmate#3222`, which added the `state/home-summary.json` ledger and [`bin/fm-home-summary-refresh.sh`](../bin/fm-home-summary-refresh.sh) in place of the per-home read the fork had extended.
The fork's single timeout contract was kept and upstream's second name was not introduced, `abandoned_children` was carried into the new ledger, and the ledger publisher now validates that field so a producer regression fails at publication rather than at the consumer that requires it.
`kunchenguid/firstmate#3210`'s deletion of `FM_SNAPSHOT_SECONDMATE_TIMEOUT` and its rewrite of the bearings per-child rows are the same collision continuing in later rounds, so a round touching either file must re-read this entry rather than trusting a clean merge.
Upstream reintroduced `FM_SNAPSHOT_CREW_STATE_TIMEOUT` a second time on 2026-09-04 with `kunchenguid/firstmate#3273`, which made this snapshot the producer behind the home-summary ledger; the fork's single contract was kept again, upstream's second name and its `docs/configuration.md` row were again not introduced, and `tests/fm-home-summary-refresh.test.sh`'s bounded-read case was repointed at `FM_SNAPSHOT_TASK_TIMEOUT` so it still bounds the read it names.

### Pi away-mode supervision standby

The fork's Pi watcher extension hands supervision to the away daemon while `state/.afk` exists: [`.pi/extensions/fm-primary-pi-watch.ts`](../.pi/extensions/fm-primary-pi-watch.ts) arms nothing, retires any arm child it already owns, injects no ordinary wake, and resumes exactly one extension-owned cycle once the flag clears.
Upstream has no away-mode awareness in that extension at all, and [`docs/watcher-continuity.md`](watcher-continuity.md) owns the contract.
The divergence lives inside an upstream-owned file and adds an away check on every delivery path, so an upstream change to wake delivery arrives beside fork guards rather than as a fork-only file.
It first collided on 2026-08-26 with `kunchenguid/firstmate#2939`, which added a `repairFailed` argument to `deliverActionableWake`; the argument was adopted and the fork's away check kept ahead of it, so a wake that arrives while away mode is active still stays with the daemon rather than reaching the supervision branch.
The away-standby cases in [`tests/fm-pi-watch-extension.test.sh`](../tests/fm-pi-watch-extension.test.sh) pin that behavior.
This divergence went unrecorded from its introduction until 2026-08-26.

### Fork-local no-mistakes compliance-gate event scope

The fork's `Require no-mistakes` workflow omits the `edited` pull-request event and coalesces on one per-PR concurrency group, adopted on 2026-08-14 with `HelloWorldSungin/firstmate#150` for the defect in `HelloWorldSungin/firstmate#98`.
Upstream evaluates every body edit independently on a per-event group, which on this fork left orphan failed check runs attached to a green PR after a truncated body was restored on an unchanged head.
[`tests/fm-no-mistakes-required-gate.test.sh`](../tests/fm-no-mistakes-required-gate.test.sh) pins the trigger list and the concurrency shape, and [`CONTRIBUTING.md`](../CONTRIBUTING.md)'s gate paragraph carries the same contributor-facing statement.
This entry's divergence lives in the workflow's `on:` and `concurrency:` blocks alone, so the compliance verdict itself is taken from upstream unchanged: `kunchenguid/firstmate#3027` replaced that step with the pinned shared `require-no-mistakes` action on 2026-08-26 and the fork adopted it whole, keeping only its own event scope above.
A round that takes the whole workflow from upstream silently restores the `edited` trigger, so those two blocks must be re-read rather than trusted to a clean merge.
This divergence went unrecorded from its introduction until 2026-08-26.
The `steps:` block carries a second, separately recorded divergence; see "Live pull-request body refresh before the compliance gate" below.

### Live pull-request body refresh before the compliance gate

A fork-local step ahead of the pinned `require-no-mistakes` action loads the live pull-request body into the event payload, so the gate judges the body the pipeline wrote rather than the webhook snapshot the run was triggered on.
[`.github/scripts/nm-required-refresh-event-body.py`](../.github/scripts/nm-required-refresh-event-body.py) is the fork-local helper that performs it and has no upstream counterpart; the pinned action itself is still taken unchanged, and this step neither checks out PR code nor moves the triggering head.
Adopted on 2026-09-04 for `HelloWorldSungin/firstmate#258`, where a synchronize run and every GitHub rerun of it replayed a snapshot taken before no-mistakes rewrote the body, so a fix round could not reach green no matter how many times it was retried.
The refresh is best effort by design: every way it can fail annotates the run with a warning and leaves the webhook snapshot for the pinned action to judge, because reddening a required check with no verdict is worse than the stale snapshot it replaces.
[`tests/fm-no-mistakes-required-gate.test.sh`](../tests/fm-no-mistakes-required-gate.test.sh) pins the step and the helper's degrade paths, and [`CONTRIBUTING.md`](../CONTRIBUTING.md)'s gate paragraph carries the contributor-facing statement.
A round that takes the whole workflow from upstream drops this step silently, so `steps:` must be re-read rather than trusted to a clean merge.
Retire this entry if the pinned action reads the live body itself, because the step then has nothing left to add.

### Merge-proof contract: one divergence accepted, one retired

This entry carries TWO differences in the same subsystem, and their statuses are no longer the same.
Read the status line on each before acting on either; they are recorded together because they were decided together, not because they stand or fall together.

#### RETIRED BY CAPTAIN DECISION on 2026-09-03: refusing a queued request

The fork briefly refused a merge-queue entry outright, where upstream's `kunchenguid/firstmate#3064` accepts one as `verified: queued` on exit 0 and names `--auto` in the retry it recommends.
The captain retired that divergence on 2026-09-03: [`bin/fm-pr-merge.sh`](../bin/fm-pr-merge.sh) reports a queued request exactly as upstream reports it, and the queue-required guidance carries upstream's concrete retry flags again rather than this fork's reworded refusal.
The reasons the stricter contract was argued for are kept because they explain the reversal rather than contradict it: this fleet has no merge queue for an enqueue to be deferred into, because fork `main` carries no branch protection and no rulesets, verified against the API on 2026-08-14.
A guarantee nothing in this fleet can reach buys nothing while widening the gap a future sync round has to reconcile, which is what decided it.
Fork PR `HelloWorldSungin/firstmate#241` was the earlier attempt and is superseded: the round-1 sync rebuilt this merge path underneath it, so the work was re-expressed against upstream's shape rather than reconciled hunk by hunk.
A future round must take upstream's queue behaviour unchanged rather than re-deriving this refusal; reopening it needs a fresh captain decision and a real merge queue to point at.

One consequence is left standing deliberately and is the thing to read before "fixing" it.
The forwarded-argument allow-list still refuses `--auto` by name, which is a separate rule about what a caller may hand the forge and not a claim about merge queues, so upstream's restored retry guidance names flags this script would itself turn away.
That allow-list is additive rather than divergent - it constrains what a caller may pass, admitting merge-method selectors, message arguments, post-execution branch cleanup, and head-binding arguments, each recorded with why it cannot defer execution.
Reconciling the two, by retiring that allow-list entry as well or by rewording the guidance a second time, is open work left to the captain who ordered the restoration; no issue tracks it yet, and `HelloWorldSungin/firstmate#259` is the allow-list's own open issue rather than a record of this.

#### ACCEPTED and standing: a failed command whose readback confirms the merge landed

Upstream fails the wrapper whenever the merge command exits non-zero, even when the forge then confirms the merge LANDED; this fork exits zero on that path and records the outcome.
The command's exit status reports whether the CALL succeeded, while the forge's own state reports whether the MERGE HAPPENED, and only the second is the question anyone acts on; when they disagree the forge is the system of record and the command status is a transport detail.
The failure modes are not symmetric, which is what decides it: exiting non-zero on a landed merge is a false negative that leaves work on the default branch while everything downstream reasons it is not, whereas exiting zero is only wrong if the forge lied about its own merged flag.
[`tests/fm-pr-merge.test.sh`](../tests/fm-pr-merge.test.sh) pins both directions, and `bin/fm-pr-merge.sh` states the verdict in one place, the comment above `report_landed_after_failed_command`, which names this entry as the divergence it implements and says that reversing or rewording the verdict is one edit there.
Keeping it to one edit site matters because an inverted form of this rule has already propagated into a test and into `docs/architecture.md` once.
Retiring the queue half above must not disturb this one: they were argued together and decided apart.

REACHABILITY, which is what separated the two verdicts and is why it stays recorded.
The retired queue refusal was UNREACHABLE in this fleet, because no project here uses a merge queue; it was a guarantee rather than a response to an observed failure.
This verdict is REACHABLE IN ORDINARY USE: any transport or response failure after a merge lands takes that path, on any repository, with no special configuration.

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
That comparison normalizes only the fields two separate processes cannot share, so an upstream change that adds one arrives as a false failure: `kunchenguid/firstmate#3156` added the claim identity as a second line of `state/.claude-autoarm-epoch` on 2026-09-02, and it is now normalized beside the owner pid and stamp, with its presence asserted separately so the comparison cannot go vacuous.
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

### Fork-local harness-adapters split and its routing script - retired 2026-09-04

The fork split the `harness-adapters` skill its own way in `HelloWorldSungin/firstmate#191`: a shared head in `SKILL.md` plus one variant file per harness under `harnesses/`, routed by a 114-line `bin/fm-harness-adapter-doc.sh` that refused an unknown harness name or an unreadable variant by name rather than serving the head alone.
Upstream split the same skill independently in `kunchenguid/firstmate#3289` into `references/common/*.md` and `references/harness/<h>.md`, routed by an embedded `harness-adapter-routing-v1` JSON object in `SKILL.md` and pinned by `tests/fm-harness-adapter-references.test.sh`.
Firstmate resolved that collision on 2026-09-04 under the already adopted TRACK strategy, applying the remote-doctor precedent above to two independently built implementations of one capability, and this is the sixth such resolution.
Upstream's layout and routing artifact were taken whole, the fork's `harnesses/` tree and `bin/fm-harness-adapter-doc.sh` were deleted with `tests/fm-harness-adapter-doc.test.sh`, and the fork-only material was re-homed rather than dropped: `harnesses/agy.md` became [`references/harness/agy.md`](../.agents/skills/harness-adapters/references/harness/agy.md) with an `agy` routing row, the crew-only secondmate gate and `bin/fm-launch-lib.sh`'s ownership of launch-command construction moved into `references/common/dispatch.md`, and the dashboard's additive per-task event wiring moved into `references/common/primary-hooks.md`.
The refusal property the fork's script existed for survives structurally rather than at runtime: upstream's own routing test fails the build when any routed target is unreadable, so a missing reference cannot reach a session at all, and the router's own text keeps a harness undispatchable until its entry and owners land.
Every consumer moved with it - `docs/documentation-audiences.json`, `docs/scripts.md`, `bin/fm-test-run.sh`'s changed-file family map, `docs/verification/muse.md`, `CONTRIBUTING.md`, and this ledger's agy link.

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
