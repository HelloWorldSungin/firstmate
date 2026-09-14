# Antigravity CLI

Antigravity's `agy` TUI, verified end to end on 2026-09-10 with agy 1.2.0 on Linux through the Herdr backend.
Verified as a CREWMATE and SCOUT adapter on Herdr only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no agy wake protocol.
`../../../../../docs/verification/agy.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `agy` from `PATH`, refused if absent; a Go-compiled single binary, so the live process name is exactly `agy` with `argv[0]=agy`. |
| Launch | `agy --prompt-interactive "<brief>" --model <id> --effort <level> --dangerously-skip-permissions`, with the resolved absolute binary; the brief auto-submits with no extra Enter. The spawn pre-registers the worktree in agy's trust store first, then waits for a busy turn (answering the folder-trust dialog if it renders anyway) before reporting success. |
| Busy state | No hook or plugin writer, so nothing is armed and no record is seeded; on Herdr only native `working` status classifies busy, and unavailable native evidence stays unknown. |
| Rendered tail | Busy status row carries `esc to cancel` on the left; the idle row shows `? for shortcuts` instead. The `Generating...` word beside the braille spinner is free-floating output and is not a signal. |
| Turn end | No hook is installed; the watcher emits identity-gated, debounced native-idle notifications through `bin/fm-transition-lib.sh`. |
| Exit | `/quit`, one Enter; the process exits. |
| Interrupt | Single `Escape`, which prints the Interrupted row and leaves an idle composer with no repollution, so no clear key follows. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--dangerously-skip-permissions` auto-approves tool calls for the run. |
| Marker | None; a live TUI carries no `AGY_*` or `ANTIGRAVITY_*` variable. |
| Resume | `--continue` and `--conversation` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Model | `--model <id>` with the bare catalog id from `agy models` (for example `gemini-3.8-flash-high`); `bin/fm-spawn.sh` refuses a requested id a reachable listing omits. The listing is a remote fetch, so the probe runs stdin-detached under the shared hard bound and an unreachable or hung listing launches unvalidated with a notice. |
| Effort | `--effort low\|medium\|high`; `xhigh` and `max` stay in task metadata under the record-and-omit contract. |
| Composer | Borderless bare `>` row, which the shared classifier reads as `unknown` under the dead-shell rule, never `empty`; steering confirms delivery through native agent-state and the delivery footer instead, the cursor precedent. |

## Fork boundaries and trust ownership

The fork retains the crew-only and Herdr-only spawn gates, raw-launch refusal, atomic prompt delivery, and ownership-aware workspace trust cleanup recorded in [`docs/fork-divergence.md`](../../../../../docs/fork-divergence.md).
`bin/fm-agy-trust-lib.sh` owns trust mutation, created-versus-preexisting ownership, abort rollback, and cleanup retries.
A failed trust write refuses the spawn; successful registration is followed by upstream's readiness gate before dispatch reports success.
`bin/fm-transition-lib.sh` owns native completion notification, and `bin/fm-busy-lib.sh` requires matching native identity before accepting a busy verdict over an untrusted record.
The shared composer classifier keeps a bare `>` unknown, never empty.
`docs/herdr-backend.md` owns atomic-prompt delivery semantics; an `unverifiable` verdict may already have been accepted and must not be blindly resent.

## Credential precondition

A verified agy worker ran under a signed-in Google account with no key export and no dialog.
The unauthenticated failure mode was not observed, so treat any auth prompt or refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `agy`, never `*agy*`.
No environment marker is promoted: `AGENT=1` observed on a live TUI is an inherited launcher value, not an agy identity, and agy does not clear an inherited `CLAUDECODE` - but a structural agy ancestor now outranks that retained marker, which `../../../../../bin/fm-harness.sh` decides without depending on the spawn's own launch-boundary marker clearing.
agy is deliberately absent from the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where muse, gemini, and rovo are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms no busy generation for agy and writes no sidecar, exactly because no writer could ever clear a seeded record.
The shared rendered-tail helper remains available for standalone non-Herdr observations, but does not authorize a supervised Herdr busy verdict.
Teardown removes only the workspace trust entry this task created, using the durable ownership marker; preexisting trust remains untouched.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no agy protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
