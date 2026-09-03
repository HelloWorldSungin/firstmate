# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, wedge-escalation, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
That cold positional-prompt check established eventual custom-message delivery, but it did not submit immediately after `/new` while native digest generation was still running, so its earlier race-free inference is superseded by the provider-prerequisite evidence below.
The installed pi-signed 0.82.0 wrapper repeated the shared Pi primary extension and session-start path on 2026-07-27.
[`runtime-backends.md`](runtime-backends.md#tmux) owns the shared-ancestry evidence and authoritative selection-marker boundary.

### Run-tier source vocabulary and context-reset injection

The run tier depends on three facts only the vendor can supply: the session-open source it reports, whether hook stdout reaches model context on a context-RESET open rather than only a cold one, and whether a worker the hook detaches survives the hook returning.
The first two were measured on 2026-08-05 against a throwaway Firstmate-shaped lab carrying each harness's own tracked registration with a recorder standing in for `bin/fm-sessionstart-run.sh`.
Each open printed a source-stamped token, and the model was asked to quote that token back, so producing hook stdout could never be mistaken for delivering it.
The third is recorded below.

| Harness | Version verified | Cold open | Context reset | Context-preserving reopen |
| --- | --- | --- | --- | --- |
| Claude | 2.1.222 (Claude Code) | `source=startup`, token quoted back in both `-p` and the TUI | `/clear` reports `source=clear` and `/compact` reports `source=compact`; both re-injected a fresh token that the model quoted back | `claude --continue` reports `source=resume` |
| Codex | codex-cli 0.146.0 | `source=startup` under `codex exec`, token quoted back | Not reachable from a tracked project registration; see the limit below | `codex exec resume --last` reports `source=resume` |
| Pi | 0.82.0 | `source=startup`, token quoted back in both `-p` and the TUI | `/new` raises `session_start` reason `new`, which the extension maps to `clear`; `/compact` raises `session_compact`, and both freshly injected source-stamped tokens were quoted back | `pi -c` reports reason `startup`, not `resume` |

Two harness-specific consequences are load-bearing rather than incidental.

Codex's interactive TUI fired no project `SessionStart` hook at all in the same lab where `codex exec` fired it reliably, which matches the earlier 2026-07-28 finding for 0.145.0.
Codex's run tier is therefore verified only for `codex exec` startup and context-preserving resume.
The interactive TUI is a known uncovered gap: Firstmate has no tracked session-open, compaction, or re-emit channel there, ships no global hook, and does not claim instruction-refresh delivery for that surface.

Pi compaction was verified on 2026-08-05 with Pi 0.82.0 in the same throwaway lab after setting `.pi/settings.json` `compaction.keepRecentTokens` to 200 and completing one substantial assistant-prose turn before issuing `/compact`.
Pi reported `Compacted from 7,697 tokens`, the recorder observed `session_compact`, and the model quoted the freshly injected `source=compact` token back.
Both preconditions are load-bearing: the stock 20,000-token keep window exceeds a small lab session, and `AgentSession.compact()` aborts an in-flight turn before measuring compactable history, which otherwise discards that turn and reports `Nothing to compact (session too small)`.
Tool output alone does not grow compactable context; the completed assistant prose does.

Observed compaction output and recorder source:

```text
Compacted from 7,697 tokens
compact
```

Pi disagrees with Claude and Codex on `resume`: a new Pi process continuing a session reports `startup`, and Pi's `resume` reason is reserved for an in-process session switch.
The current adapter classification and baseline mechanics are owned by [`../sessionstart-nudge.md`](../sessionstart-nudge.md#harness-transports) and the `bin/fm-session-start.sh` header.
Their continuation classification is covered by portable tests, not claimed as live validation in this record.

### Pi `/new` provider prerequisite

The real offline Pi regression ran on 2026-08-26 with Pi 0.84.0, an isolated home and session directory, a barrier-controlled native digest, and a deterministic local `streamSimple` provider.
The provider makes no HTTP request and requires no user credential.
Its missing-native branch deliberately requests `bin/fm-session-start.sh`, so an escaped first call reproduces the duplicate-producing manual path rather than passing vacuously.

```sh
FM_PI_SESSIONSTART_RACE_LIVE_E2E=1 \
  tests/fm-sessionstart-hook-live-e2e.test.sh
```

Observed output:

```text
ok - Pi 0.84.0: immediate and completed-before-prompt /new paths each made one first provider call with exactly one native startup context and no manual execution
# fm-sessionstart-hook-live-e2e.test.sh: offline Pi /new race assertions passed
```

The immediate case submitted its first prompt only after the native `clear` child published `started`, held the child behind a release barrier, and proved the provider log remained absent for 500 milliseconds before release.
After release, the first payload reported one native context and no manual result, the session persisted one matching custom message, and the fixture recorded one native execution.
The control case let native generation complete before prompt submission and produced the same first-payload result.
The portable public-event regression in `tests/fm-sessionstart-nudge.test.sh` separately covers interruption, process-tree retirement, two rapid replacements, stale completion, empty output, spawn error, timeout output, truncation, ineligible stand-down, and compaction cancellation.
Pi and pi-signed load the same tracked extension bytes; pi-signed was not installed on this host for a separate 0.84.0 live rerun.

### Post-start instruction refresh

The isolated real-Pi instruction-refresh regression ran on 2026-08-11 with Pi 0.84.0.
It used a scratch `FM_HOME`, a private tmux socket, and a disposable Firstmate checkout.
The historical `origin/main` implementation first reproduced the stale original marker after a real compaction.
The current implementation then recorded `source=startup`, changed and committed the lab's `AGENTS.md`, compacted the same real Pi session, and answered with the replacement marker.
The fixed run also proved that the true-start baseline remained different from the updated file after compaction.

```sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=origin/main \
FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=stale \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 reproduces stale AGENTS.md after a real compact

FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 re-injects updated AGENTS.md after a real compact in an isolated session
```

This is live coverage only for Pi compaction.
The portable session-start tests cover continuation classification, baseline immutability, and source-routing behavior.
Pi compaction is the only supported stale-cache refresh pair.
Codex exec exposes only startup and context-preserving resume through tracked registration; Codex interactive reset behavior remains uncovered rather than inferred from direct wrapper invocation.

### Detached session-open workers survive the hook

Session start composes its digest from local reads and runs every external-network call in a worker detached by the hook (`bin/fm-startup-network.sh`), so a harness that reaped the hook's process tree would silently stop running the sweeps rather than merely delaying them.
Verified on 2026-08-06 with Claude Code 2.1.222 in a throwaway lab whose `bin/fm-bootstrap.sh` sleeps 6s before writing a marker, so the marker can exist only if the worker outlived the hook and the whole `claude -p` process.

```text
$ claude -p --permission-mode bypassPermissions '<quote the session-start token>'
FMHOOKTOKEN-startup-1-abc123
--- claude exited at 13:38:40; polling for the detached worker's marker ---
MARKER at +4s: detached worker survived the hook
state=done
started=1786048716
finished=1786048723
```

The worker started before the harness exited and published 6s after it was gone.

The latency this buys was re-measured on 2026-08-06 against default-branch tip `8398d31`, in a throwaway home holding one remote secondmate whose host hangs 25s per SSH connection (an `FM_SSH_BIN`-shaped stub; no real host was contacted).
Both runs used the same fixture and the same `bin/fm-session-start.sh` invocation, differing only in which checkout supplied the script:

```text
before (8398d31)   real 1m21.15s   3 blocking SSH attempts inside the digest
after              real 0m3.36s    digest prints IN PROGRESS; the same 3 SSH attempts
                                   run in the detached worker and finish at +77s
```

The remaining seconds are entirely local subprocess work; the `NETWORK CHECKS` section named GitHub authentication, dead-secondmate relaunch, secondmate convergence, pending handoff delivery, and project clone refresh as not yet confirmed.

Deferring the sweeps changed only when they run, not what they conclude.
The deferred worker's published report was byte-identical to the three sweep lines the blocking baseline printed, on the same fixture:

```text
SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown; route preserved on remote-mac
SECONDMATE_SYNC: secondmate ios: skipped: remote tracked-file sync failed on remote-mac:
SECONDMATE_SYNC: secondmate ios: skipped: remote inheritance failed on remote-mac:
```

The unreachable route was preserved rather than relaunched in both runs, and the result surfaced durably as a queued `check: startup-network` wake once the worker finished.

Codex and Pi were not installed as run-tier labs in this measurement, so their evidence for this fact is NOT refreshed; `tests/fm-sessionstart-hook-live-e2e.test.sh` asserts it for each installed Claude, Codex exec, and Pi adapter and is the command that refreshes their record.
Cursor's separate primary live guard covers its source-free session-open transport but does not claim this detached-worker measurement.
A harness that did reap the worker degrades loudly rather than silently: the leftover record reads as an abandoned run needing a rerun, and the next session start re-derives every finding, because these sweeps are idempotent detectors.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-session-start.test.sh
tests/fm-startup-network.test.sh
FM_SESSIONSTART_HOOK_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_PI_SESSIONSTART_RACE_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

`tests/fm-sessionstart-hook-live-e2e.test.sh` is the command that refreshes the Claude, Codex exec, and Pi table above; run it after upgrading any of those harnesses.
It reports an absent adapter explicitly, asserts Pi compaction rather than noting it, and refuses to pass when none of those three adapters was installed.
Cursor's refresh command is `FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh`, recorded under [Cursor primary park](#cursor-primary-park-2026-08-13).

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| OpenCode | 1.17.18 | Plugin `session.status` | In a real TUI pane: seed, then `busy source=opencode-plugin event=session-busy`, then `idle source=opencode-plugin event=session-status-idle`. |
| Claude | 2.1.220 (Claude Code) | Hooks `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | `UserPromptSubmit` fired for the argv launch prompt and each steer, and `Stop` closed every completed turn. A mid-stream Escape interrupt fired no closing hook, which is why the firstmate-controlled clear exists. `StopFailure` and `SessionEnd` are wired from the four hook names present in the installed binary; only the abnormal paths they cover were not reproduced live. |
| Codex | codex-cli 0.145.0 | None usable | See below; classifies `unknown codex-unverified`. |
| Kimi (standalone) | not installed | None usable | No binary on `PATH`, so the gate stays closed and it classifies `unknown kimi-unverified`. |
| Grok | 0.2.112 | Isolated rendered-tail fallback | Retained unconverted; the approved audit could not credit a live structured-lifecycle run. |

Codex was probed two ways, both refused:

```sh
codex app-server daemon start
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

The daemon refused with `managed standalone Codex install not found`, and an interactive TUI worker neither starts nor attaches to the app-server control socket, so no client can observe its turns.
In this 2026-07-28 Codex 0.145.0 semantic-busy probe, Firstmate-written lifecycle project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while an untracked global probe fired in the same runs; Firstmate does not ship, install, recommend, or depend on that global path.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Turn-end guard

The blocking and bounded-follow-up mechanisms were validated across six harnesses on 2026-07-08 through 2026-08-13, with Claude's replacement Stop-owned path revalidated on 2026-07-24 and Cursor's stop-hook park validated on 2026-08-13.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |
| Cursor | 2026.08.11-e8db854 | Awaited `stop` hook park returning one `followup_message` | Exit 2 ended the turn normally, proving it cannot block; a returned follow-up ran a genuine second turn; a sleeping hook held the boundary open and the wake landed after it; `loop_limit` stopped the hook being invoked at its ceiling. |

### Cursor primary park, 2026-08-13

Cursor was validated as a primary on 2026-08-13 against the installed CLI on macOS 26.5.2 arm64 with tmux 3.6a, in a throwaway firstmate home on a private tmux socket, never against a live home and never with a user-scope hook.

Mechanism facts established first, in a separate throwaway workspace:

| Question | Method | Result |
| --- | --- | --- |
| Can `stop` block? | hook exits 2 | No. The turn ended normally; Cursor's blocked-response mapper returns `{}` for the `stop` step. |
| Can `stop` force one turn? | hook returns `{"followup_message":...}` | Yes. A genuine second turn ran and answered. |
| Can `stop` park? | hook sleeps, then returns a follow-up | Yes. It is awaited; a 20s sleep held the boundary and the follow-up landed after it. |
| What is `loop_count`? | four consecutive follow-ups, then a real user message | `0,1,2,3`, then `0` again. It counts follow-up-driven stops since the last real user message. |
| Does `loop_limit` bind? | `loop_limit: 2` with an always-follow-up hook | Yes. The hook was invoked at `loop_count` 0 and 1 and never at 2. |
| Does a captain message terminate an existing park? | captain message typed during a 600s park | No. Cursor leaves the park running, and without a baton an older park can still deliver after the captain turn's next `stop` has started another park. |
| Does Cursor load `.claude/settings.json`? | Claude-shaped `SessionStart`, `PreToolUse`, `Stop` in the same workspace | `SessionStart` and `PreToolUse` fired with a CURSOR-shaped payload carrying `cursor_version`; `Stop` did not fire. |

The integration itself is exercised by the opt-in guard:

```sh
FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh
```

Observed output:

```text
harness: cursor-agent 2026.08.11-e8db854
ok - cursor primary: the sessionStart hook takes the fleet lock as the Cursor process itself
ok - cursor primary: the run-tier session start completes every stage
ok - cursor primary: sessionStart additional_context reaches model context before the first turn
ok - cursor primary: the stop-hook park delivers a real watcher wake as one follow-up
ok - cursor primary: the park owns exactly one arm cycle with a live watcher beacon
ok - cursor primary: the captain keeps control and the older park stands down after the next stop claim
ok - cursor primary: an away-mode escalation is delivered, confirmed, and processed
```

The live run proved that session start acquires the fleet lock through Cursor's structural process identity in `bin/fm-cursor-lib.sh`; `tests/fm-session-lock-ancestry.test.sh` pins the same ancestry path portably.
It also proved that Cursor's `autoarm` supervision model lets the mid-turn pull guard accept a fresh beacon after the between-turn watcher closes; `tests/fm-guard-stale-banner.test.sh` pins that model-aware verdict.
The baton is claimed only by the next `stop`, so an actionable close before that claim can still produce one real follow-up from the sole existing park; durable wake handling is idempotent, and any older park still running after the claim stands down.
Cursor's `beforeSubmitPrompt` step could close that exact window because it fires once on a real captain message and not on hook-driven follow-ups, but registering it is deliberately deferred alongside `preCompact`.

Away-mode delivery needed no daemon change once the composer reader was correct for Cursor; [`runtime-backends.md`](runtime-backends.md#composer) owns that evidence.

Cursor compaction instruction refresh is DEFERRED and not shipped, so a Cursor primary does not re-emit its digest after a compaction.
Two static facts decided that: `PreCompactRequestResponse` carries only `user_message`, and `preCompact` is absent from the `additional_context` step set (`index.js` @ 4814884), so the step cannot inject a digest and any delivery has to be routed through a later boundary.
A staged-then-delivered design is rejected because carrying a digest across two concurrently running `stop` hooks can deliver it twice or strand it indefinitely, while closing those races enlarges a critical section inside a hook Cursor awaits at the turn boundary.
Native `preCompact` firing was not observed because a real compaction could not be forced in the isolated session, so the surface has no empirical basis yet.
It is therefore recorded as uncovered in the same sense as the Codex interactive TUI, and `tests/fm-cursor-primary.test.sh` asserts `preCompact` stays unregistered so it cannot return unnoticed without its own design and evidence.

The Grok adaptive matrix ran on 2026-07-28 with separate scratch repositories and homes, dedicated tmux sockets, one target plus one control window, ambient tmux variables removed, and a socket-bound wrapper first in `PATH`.

```sh
FM_GROK_STOP_LIVE_E2E=1 \
  FM_GROK_NATIVE_BIN="$native_grok_0_2_112" \
  FM_GROK_LEGACY_BIN="$official_pre_native_grok_0_2_73" \
  tests/fm-grok-stop-live-e2e.test.sh
```

Observed bounded output:

```text
ok - grok 0.2.112 (9bbd559437aa) [stable] native Stop kept one session across false->true, two model turns, and zero resume processes
ok - grok 0.2.73 (9ff14c43bbe5) [stable] legacy Stop omitted capability, resumed exactly once, and stopped normally
ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival
```

The same run proved the Claude-compatible Stop entries stay inert under `GROK_AGENT`, the legacy resume carries `GROK_TURNEND_GUARD_ACTIVE=1`, and every replacement root is removed after exact target cleanup while its control window survives.
That inertness result is scoped to the builds it exercised: it did not establish that `GROK_AGENT` reaches a Grok HOOK process, and on grok 1.0.0 it does not, so the marker set was widened to `GROK_HOOK_EVENT` as well (docs/turnend-guard.md "Harness integrations").
`tests/fm-turnend-guard.test.sh` now pins every tracked `.claude/settings.json` hook entry against a real grok 1.0.0 hook environment so the inertness contract is covered deterministically rather than only by the opt-in live matrix.

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.
`tests/fm-watch-arm.test.sh` runs real watcher and arm cycles against durable on-disk state to verify that a delivered reason survives until post-handling acknowledgement and stops replaying after acknowledgement, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.
The same suite ingests a keyed remote-secondmate parent reply through the real adapter, establishes the incremental OPEN DECISIONS cursor, interrupts supervision, and proves re-arm replays every unacknowledged queue row plus the still-open decision through the ordinary drain path.
It also covers decision-only recovery, interrupted handling, handling-window generation reuse, non-fatal moved-generation acknowledgement with sequence-bounded consumption, and a persistent successor remaining live after recovery is acknowledged.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_GROK_STOP_LIVE_E2E=1 FM_GROK_NATIVE_BIN="$native_grok" FM_GROK_LEGACY_BIN="$pre_native_grok" tests/fm-grok-stop-live-e2e.test.sh
```

The Claude auto-arm false-failure, guard-predicate, and monotonic bounded fail-open correction was verified on 2026-08-02 with the installed ShellCheck 0.11.0 and isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=61 local_links=174
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=102585
```

The model-aware pull-guard predicate correction (`bin/fm-guard.sh` no longer reports a false watcher-down mid-turn under the Claude Stop auto-arm model, where the watcher runs only between turns) was verified on 2026-08-04 with the installed ShellCheck 0.11.0 and the same isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=64 local_links=188
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=80078
```

The Pi extension-model pull-guard correction (`bin/fm-guard.sh` no longer reports a false watcher-down on a Pi primary during the extension's own watcher hand-off) was verified on 2026-08-13 with the installed ShellCheck 0.11.0 and isolated behavior suites.
The guard verdict itself reads only state files and process liveness, so the portable suites are the enforcing evidence; `bin/fm-harness.sh`'s Pi marker detection, which selects the model, is exercised in the same suite through `PI_CODING_AGENT`.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-session-start.test.sh tests/fm-pi-watch-extension.test.sh tests/fm-watch-arm.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=67 local_links=243
FM_TEST_SUMMARY total=5 failed=0 skipped_gate=0 duration_ms=280160
```

The same correction was verified against a live Pi primary's own supervision evidence on 2026-08-13.
The hand-off was captured live at beacon age 63s, then the home's `state/.lock`, `state/.last-watcher-beat`, both `state/.pi-*-extension-loaded` markers, and both `.pi/extensions/*.ts` builds were copied into an isolated fixture with no watcher lock.
The fixture's copied beacon was fresh at 0s in the output below; the deterministic stale-beacon case separately verifies the grace boundary.

```sh
FM_SUPERVISION_MODEL=persistent FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
FM_SUPERVISION_MODEL=extension FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
```

Observed output, before and after the model correction, then with the recorded Pi session pid replaced by a dead one:

```text
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
(silent)
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
```

The broader relevant regression pass was rerun on 2026-08-02 without live-home or daemon mutation.

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watcher-lock.test.sh tests/fm-afk-inject-e2e.test.sh tests/fm-afk-return.test.sh tests/fm-x-mode.test.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-safety.test.sh
```

Observed output:

```text
FM_TEST_SUMMARY total=8 failed=0 skipped_gate=0 duration_ms=617507
```

The actionable-close ordering correction was reverified on 2026-08-02 against an identity-matched live successor.

```sh
tests/fm-claude-stop-autoarm.test.sh >/dev/null && echo "fm-claude-stop-autoarm: ok"
```

Observed output:

```text
fm-claude-stop-autoarm: ok
```

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-07-27 against the tracked extension with a faithful in-process factory rebind (module cache retained, real arm children):

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, and `/fork`, plus same-instance shutdown-plus-start, the replacement generation armed again without a Pi restart and without the `watcher: not armed - Pi session is shutting down` refusal.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner; other primary harnesses are not applicable because they do not use this Pi extension lifecycle.

### Watcher stop latency

Measured on 2026-08-01 against an isolated temporary home, sending the signal to a watcher that had already taken its lock and entered its cycle wait.
Before the interruptible cycle wait in `bin/fm-watch.sh`, exit latency tracked `FM_POLL` exactly, because bash defers a trapped signal until the running foreground command returns.

| FM_POLL | Signal | Before | After |
| --- | --- | --- | --- |
| 1 | TERM | 0.54s | 0.05s |
| 5 | TERM | 4.54s | 0.06s |
| 15 (default) | TERM | 14.53s | 0.06s |
| 15 (default) | HUP | 14.52s | 0.06s |

`bin/fm-watch-arm.sh --restart` allows the outgoing watcher 50 iterations of `sleep 0.1`, a 5s budget, before forking a replacement.
At the 15s default the old latency exceeded that budget outright, so a restart forked a second watcher while the first was still alive and still holding the lock.
The singleton lock is released in every measured case.

Current limit: the herdr push path in `event_wait_or_sleep` waits inside a foreground command substitution, so a push-capable home remains up to `FM_POLL` deaf to its own stop signal.
That reader owns a fifo directory and a child reader process that it removes on its own return path, so interrupting it from the caller would leak both on every stop.

### Watcher stop disposition

Measured on 2026-09-02 on `GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)`, superseding the stop-path mechanism recorded above.
The latency table above still holds; what changed is how the stop signal is received.

A stop-signal HANDLER is a string bash parses at the moment the signal arrives.
That parse can fail while the shell is inside a command substitution.
Bash then prints a trap diagnostic, runs no handler, and CONTINUES, so the watcher ignored the stop for the rest of its poll interval (issue #242).

The handler text is not what is malformed.
`bin/fm-watch.sh` installed `trap watcher_stop_signal HUP INT TERM`, a single well-formed word, and `trap -p` read out of a live watcher at the moment of failure showed only well-formed entries.
The diagnostic names whichever sourced file was executing when the signal landed, not where any trap is installed, which is why CI reported `bin/fm-wake-lib.sh` - a file that installs no trap at all.

Reproduce with two loops that differ only in whether the body performs a command substitution, sending one TERM per run at a randomised offset:

```sh
# arm A: command substitution in the loop
printf '%s\n' '#!/usr/bin/env bash' 'trap "exit 1" TERM' 'while :; do c=$(date +%s); done' > /tmp/arm-a.sh
# arm B: same loop shape, no command substitution
printf '%s\n' '#!/usr/bin/env bash' 'trap "exit 1" TERM' 'while :; do printf -v c "%s" "$SECONDS"; done' > /tmp/arm-b.sh
# for each arm: start it, sleep 0.02-0.35s, send one TERM, record whether the
# process survived a further second and whether stderr carried a trap diagnostic
```

Observed, interleaved so load drift hits both arms equally:

| arm | runs | trap diagnostics | ignored TERM |
| --- | --- | --- | --- |
| command substitution in loop | 700 | 5 | 4 |
| no command substitution | 600 | 0 | 0 |

The same failure was reproduced against the real watcher at 2 occurrences in 640 signalled runs (`FM_POLL=0.05`, one TERM per run at a randomised offset).
One of those runs also printed `bin/fm-watch.sh: line 515: unexpected EOF while looking for matching ')'`, bash failing to parse its own script source, which a malformed handler string cannot cause.

The watcher therefore installs no HUP/INT/TERM handler and lets those signals keep their default disposition.
Bash still runs the EXIT trap for an untrapped fatal signal, so `watcher_cleanup` is unchanged:

```sh
printf '%s\n' '#!/usr/bin/env bash' 'cleanup() { echo EXIT_TRAP_RAN >&2; }' 'trap cleanup EXIT' 'trap - TERM' 'echo READY >&2' 'sleep 30' > /tmp/exit-probe.sh
```

Signalling that probe with TERM prints `EXIT_TRAP_RAN` and yields wait status 143.
A real watcher signalled the same way exits 143 with `state/.watch.lock/pid` removed, so child reaping, private check-file removal and lock release all still run.
Issue #160's burst case also still holds, because `watcher_cleanup`'s first statement ignores further stop signals.

After the change, 250 signalled runs of the real watcher produced no trap diagnostic and no ignored TERM.
`tests/fm-watcher-lock.test.sh` pins the mechanism rather than only the effect: the watcher must exit 143, which is true only with no handler installed, and must still have released its lock.
That case fails deterministically with status 1 against a watcher carrying a stop handler.

Not reproduced, and recorded so a later reader does not chase it: upstream `kunchenguid/firstmate#3565` attributes the same diagnostic to a runtime-built handler restored through `_FM_SIGNAL_DEFER_RESTORE=$(trap -p HUP INT TERM)` and `eval`.
Neither `fm_signal_defer` nor `trap -p` exists in `bin/` at this fork's HEAD, at upstream `d22318ea`, or at the merge base `60bedde5`.
The minimal reproduction above carries no `eval` and no dynamically built handler and still produces the identical message, so that mechanism is not required to explain it.

### Watcher stop disposition: burst window, abandoned event wait, cleanup diagnostic

Measured on 2026-09-03 on `GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)`.
This entry supersedes one claim in the 2026-09-02 entry above and the `Current limit` paragraph in the 2026-08-01 entry above.
Both originals stay exactly as recorded.

Correction 1: issue #160's burst case does NOT still hold unchanged, as the 2026-09-02 entry claimed.
Default disposition narrows that window rather than preserving it.
`watcher_cleanup`'s `trap '' HUP INT TERM` covers only signals arriving after that statement has executed.
A second stop signal delivered between the kernel delivering the first and that statement running makes bash take its `_exit(128+sig)` path and abandon the EXIT trap where it stands.

Re-measured with an EXIT trap whose ignore is preceded by a delay, placing the second TERM on either side of it:

```sh
printf '%s\n' '#!/usr/bin/env bash' \
  'cleanup() { echo CLEANUP_ENTER >>"$LOG"; sleep 0.3; trap "" HUP INT TERM; sleep 0.3; echo CLEANUP_DONE >>"$LOG"; }' \
  'trap cleanup EXIT' 'echo READY >>"$LOG"' 'sleep 30' > /tmp/probe-burst.sh
# start it, send one TERM after 0.3s, then a second TERM 0.1s later (before the
# ignore) and, in a second run, 0.5s later (after the ignore)
```

The comparison arm restores the design this change replaced, a stop handler that disarms and exits, over the same script:

```sh
printf '%s\n' '#!/usr/bin/env bash' \
  'cleanup() { echo CLEANUP_ENTER >>"$LOG"; sleep 0.3; trap "" HUP INT TERM; sleep 0.3; echo CLEANUP_DONE >>"$LOG"; }' \
  'stop_signal() { trap "" HUP INT TERM; exit 1; }' \
  'trap cleanup EXIT' 'trap stop_signal HUP INT TERM' 'echo READY >>"$LOG"' 'sleep 30 & wait $!' > /tmp/probe-burst-handler.sh
```

| second TERM | default disposition | previous `watcher_stop_signal` handler |
| --- | --- | --- |
| before the ignore | `CLEANUP_ENTER` only, status 143 | `CLEANUP_ENTER` and `CLEANUP_DONE`, status 1 |
| after the ignore | `CLEANUP_ENTER` and `CLEANUP_DONE`, status 143 | `CLEANUP_ENTER` and `CLEANUP_DONE`, status 1 |

The handler design absorbed the second delivery at both offsets, through bash's in-progress-trap guard.
Inside the narrowed window the dead-pid lock reclaim backstops the LOCK ONLY.
Sleep-child reaping, event-wait release, active check process-group stop, private check-output removal and custom check snapshot removal have no backstop there.
The burst case in `tests/fm-watcher-lock.test.sh` does not cover this window either, because it SIGSTOPs the sleep child on purpose to place its second signal INSIDE cleanup.

Correction 2: the `Current limit` paragraph in the 2026-08-01 entry no longer describes the code.
The herdr push path in `event_wait_or_sleep` is now interrupted by a stop signal like every other wait, so a push-capable home is no longer up to `FM_POLL` deaf to its own stop signal.
The fifo directory and reader child that paragraph says the reader removes on its own return path were never safe there: a `SIGKILL` or a crash of the watcher abandoned that command substitution and leaked both long before stop signals took their default disposition.
The watcher therefore allocates that directory itself, exports it as `FM_BACKEND_EVENT_WAIT_DIR`, and releases it plus the reader pid the backend records inside it from `watcher_cleanup`.
The backend fails closed with its `event path unusable` code when that variable is set but no longer names a directory, instead of falling back to a private `mktemp -d`.
A caller that has already released the directory it named is a caller that could never release a private one either, so allocating one would re-create exactly the orphan this cleanup exists to remove.
The `mktemp -d` path stays for a caller that leaves the variable unset, which is a caller that can guarantee its own return path.

Observable: a watcher stopped while blocked in the event wait leaves no `fm-*eventwait.*` directory under `TMPDIR` and no live reader process.
`tests/fm-watcher-lock.test.sh` pins it against a real watcher process with a fake herdr and a fake stream reader, and fails if either survives the stop.
`tests/fm-backend-herdr.test.sh` pins the released-directory case at the adapter: the wait returns 2, starts no stream reader, and leaves no FIFO directory behind.

Correction 3, recorded because it changes what an operator sees rather than what the watcher does: an EXIT trap entered from a signal inherits the interrupted command's redirections.

```sh
printf '%s\n' '#!/usr/bin/env bash' 'cleanup() { echo CLEANUP_DIAG >&2; }' 'trap cleanup EXIT' \
  'sleep 30 & SPID=$!' 'echo READY >&2' 'wait "$SPID" 2>/dev/null || true' > /tmp/probe-stderr.sh
```

Signalling that probe with TERM yields status 143 with `READY` on stderr and `CLEANUP_DIAG` nowhere, because the interrupted `wait` still carried `2>/dev/null`.
The watcher's normal stop point is exactly that shape, so `watcher_cleanup`'s retained-stale-lock warning now writes to fd 4, a copy of stderr saved at startup, rather than to a bare `>&2`.
The `2>/dev/null` on the wait itself stays, because `interruptible_sleep_stop` can legitimately report that the sleep child is not a child of this shell.

### Watcher stop disposition: the trap parse is relocated, not removed

Measured on 2026-09-03 on `GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)`.
The claim this entry corrects was never recorded in this file, so do not look above for it: it was the rationale comment in `bin/fm-watch.sh` introduced by the commit whose subject is `fix(bin): stop the watcher on default signal disposition`, which read "Default disposition removes the parse entirely - the kernel terminates the process - while bash still runs the EXIT trap below".
Both halves of that claim are false, and that comment was corrected on this same branch.
This entry records the measurement behind that correction rather than superseding anything above it.
The 2026-08-01, 2026-09-02 and preceding 2026-09-03 entries above stay exactly as recorded.

The kernel does not terminate the process.
Bash installs its own terminating-signal handler and must, or it could not run the EXIT trap at all, which the 2026-09-02 entry above already observed it doing.

A trap body is a string bash parses when the trap runs, not when it is installed:

```sh
bash -c 'trap "echo A; )" EXIT; echo body'
```

That prints `body`, exits 0, and only then reports `bash: exit trap: line 1: syntax error near unexpected token ')'`.
So `trap watcher_cleanup EXIT` is parsed at signal-delivery time, from inside whatever command the stop interrupted - the same command-substitution context issue #242 identifies as the parse-failure trigger.
What default disposition removes is the STOP-HANDLER parse, and that is what makes the stop itself unconditional.
The parse is relocated, not removed.

Traced end to end over the watcher's real stop shape, with a deliberately malformed EXIT trap standing in for a parse that fails:

```sh
cat > /tmp/bad.sh <<'EOS'
#!/usr/bin/env bash
trap 'echo CLEANUP_RAN >&2; touch "$MARK"; )' EXIT
sleep 30 & SPID=$!
echo READY >&2
wait "$SPID" 2>/dev/null || true
EOS
# start it, TERM it after 0.4s, then read the wait status, the marker and stderr
```

| EXIT trap | interrupted command | status | cleanup marker | stderr |
| --- | --- | --- | --- | --- |
| well formed | `wait "$SPID" 2>/dev/null` | 143 | present | `READY` only |
| malformed | `wait "$SPID" 2>/dev/null` | 143 | absent | `READY` only |
| malformed | `wait "$SPID"` | 143 | absent | `READY`, then `exit trap: line 1: syntax error near unexpected token ')'` |

A failed EXIT-trap parse therefore skips `watcher_cleanup` in full and says nothing, because the interrupted command's redirections swallow the diagnostic exactly as they swallow the operator warning that fd 4 exists to carry.
The no-trap-diagnostic assertion in `tests/fm-watcher-lock.test.sh` cannot observe that case.

Which disposition loses less is measured rather than assumed.
Each arm is the same command-substitution loop, signalled once per run at a randomised offset, with the arms interleaved so load drift hits both equally.
Cleanup is detected by a marker file rather than by stderr, for the reason the table above records.
A run still alive one second after the TERM is escalated to `SIGKILL`, which is what the supervising harness does and which runs no EXIT trap at all.

```sh
cat > /tmp/arm-handler.sh <<'EOS'
#!/usr/bin/env bash
cleanup() { touch "$MARK"; }
stop_signal() { trap '' HUP INT TERM; exit 1; }
trap cleanup EXIT
trap stop_signal HUP INT TERM
: > "$READY"
while :; do
  a=$(/bin/echo x)
  b=$(/bin/echo "$(/bin/echo y)")
done
EOS
# the default-disposition arm is the same script without its `trap stop_signal` line
# the control is the default-disposition arm with `trap 'touch "$MARK"; )' EXIT`
```

| arm | signalled runs | cleanup lost |
| --- | --- | --- |
| stop handler installed | 900 | 3 |
| stop handler installed, independent re-run | 900 | 2 |
| default disposition | 900 | 0 |
| default disposition, independent re-run | 900 | 0 |
| control: default disposition, malformed EXIT trap | 30 | 30 |

The control confirms the detector sees a lost cleanup, so the two zeros are a real absence rather than a blind detector.
The residual stands, as a residual and not as a guarantee: this EXIT trap's own parse can fail, and when it does the singleton lock is backstopped by the dead-pid reclaim while sleep-child reaping, event-wait release, active check process-group stop, private check-output removal and custom check snapshot removal are not.

### Recovery-loop continuity

The once-per-generation recovery bound and immediate handling-successor poll were verified on 2026-08-21 with the tracked Pi extension, real watcher processes, and an isolated home.
The regression forced handling confirmation to fail, observed one recovery follow-up across the former repeat window, confirmed the successor remained live, and then proved a separate handling successor durably queued a crew event within the bounded poll window.

```sh
bin/fm-test-run.sh tests/fm-watch-recovery-loop.test.sh
```

Observed output:

```text
ok - a resurfacing handling successor stays alive and supervises instead of going blind
ok - unacknowledged recovery is announced at most once per generation and the successor stays alive
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=59357
```

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-watch-arm.test.sh
tests/fm-watch-recovery-loop.test.sh
tests/fm-wake-queue.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.

## Validation-run progress evidence

The wedge-escalation hold reads the pipeline's own step activity, so the fields it parses are a `no-mistakes` contract rather than an assumption of firstmate's.
This pass ran on 2026-08-05 against no-mistakes v1.41.2 (867d64d), reading a live mid-pipeline run of another task read-only.

```sh
no-mistakes axi status
```

Observed shape, which is what `bin/fm-run-progress.sh` parses:

```
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    test,running,7m9s,"7m4s ago: log: I'll start by understanding the change and the repository layout.","2698359",starting
```

`last_activity` is quoted and carries commas of its own, the declared row count bounds the table, and the pipeline prefixes the field with `quiet` once its own `step_quiet_warning` (`10m` in the installed default configuration) elapses.
Against that same live run:

```sh
FM_HOME=<home> bin/fm-run-progress.sh <task-id>
# progress: progressing · test running, last activity 14m23s ago (silent 863s, bound 1800s)

FM_HOME=<home> FM_RUN_STRANDED_SILENCE_SECS=60 bin/fm-run-progress.sh <task-id>
# progress: stranded · test running, last activity 14m24s ago (silent 864s, past the 60s bound)
```

The same task's supervision had produced five consecutive `possible wedge` escalations against this run, which is the behavior the hold removes.
`tests/fm-run-progress.test.sh` pins that parse and every class portably against this recorded shape; refresh this record when the `active_steps` fields or the `quiet` rendering change.

## Composer emptiness on an idle primary

The away-mode injector types only into an affirmatively `empty` composer, so what a real idle primary renders decides whether escalations are delivered or deferred.
This pass ran on 2026-08-01 with Claude Code 2.1.220 under Herdr 0.7.5 on Linux, against the live primary supervisor pane, and with GNU bash 5.2.21.

Claude renders its EMPTY composer row as the agent glyph followed by a NO-BREAK SPACE, not an ASCII space:

```sh
herdr pane read <pane> --format ansi | hexdump -C   # composer row only
```

Observed output:

```
00000000  e2 9d af c2 a0 0d                                 |......|
```

Those bytes are `❯` (U+276F), U+00A0 NO-BREAK SPACE, and CR.

Bash's own `[:space:]` trims leave that pad in place under every locale the fleet runs:

```sh
for L in C C.utf8 en_US.utf8 POSIX; do
  ( export LC_ALL=$L; c=$(printf '\xe2\x9d\xaf\xc2\xa0'); printf '%s' "${c%"${c##*[![:space:]]}"}" | hexdump -C | head -1 )
done
```

Observed output, identical for all four locales and showing the pad surviving as apparent typed content:

```
00000000  e2 9d af c2 a0                                    |.....|
```

Check this with bash rather than grep: glibc's `grep -E '^[[:space:]]+$'` DOES match U+00A0 in both C and `en_US.utf8`, so a grep spot check suggests the opposite of what the trims actually do.
`fm_composer_normalize_trim_var` (`bin/fm-composer-lib.sh`) folds U+00A0 and every other code point Unicode gives `White_Space=Yes` outside ASCII to a plain ASCII space before the verdict, which is safe in one direction only: every folded character is invisible, so any visible byte still reads `pending`.
Zero-width format characters (U+200B, U+FEFF) carry `White_Space=No` and are deliberately outside that set, so a pane padded with one reads `pending` and defers injection rather than being folded on an unproven verdict ([`fork-divergence.md`](../fork-divergence.md)).

Under an EXPORTED C/POSIX locale, bash counts pattern-prefix characters as bytes, so a leading multibyte glyph must be removed as a literal prefix rather than by character count:

```sh
( export LC_ALL=C; c='❯ hello'; printf '%s' "${c#??}" | hexdump -C )
```

Observed output, the two trailing bytes of `❯` surviving as spurious content:

```
00000000  af 20 68 65 6c 6c 6f                              |. hello|
```

Both conditions are covered by `tests/fm-composer-lib.test.sh` and, at the adapter level with the captured row, by `tests/fm-backend-herdr.test.sh`.

A genuinely mid-turn primary is a separate case that the current away-mode path deliberately does not inject into.
Herdr's native agent state reports `busy` for a Claude pane during its turn, so the busy guard rejects `inject_msg` rather than typing into an in-use composer.
`escalate_flush` retains the durable buffer after that rejection, and every housekeeping retry follows the same guarded path until the turn ends.
Normal pane delivery resumes after the turn ends, but this does not provide in-turn responsiveness and can defer for the full duration of the turn.
For a genuinely urgent away-mode escalation, configure the existing active alert through `config/wedge-alarm`, whose channel contract is owned by [`docs/wedge-alarm.md`](../wedge-alarm.md).
That alert reports the delivery wedge and points to the durable marker, but it does not carry the buffered escalation digest itself.
