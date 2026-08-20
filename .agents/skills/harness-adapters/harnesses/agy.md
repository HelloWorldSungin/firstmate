## agy (CREW-ONLY, HERDR-ONLY - VERIFIED 2026-07-23)

`agy` (Antigravity CLI, Gemini) is a captain-approved divergence of firstmate's tracked surface, so crewmates can use the captain's paid Gemini subscription.
Upstream carries no agy support at all, so every mechanism below is fork-local; `cursor` is now an ordinary verified harness and [its own variant file](cursor.md) owns it.
The full rationale is in `data/captain.md` and the empirical evidence is `data/cursor-agy-verify/report.md` (agy 1.1.5, herdr 0.7.4).
agy is CREW-ONLY and HERDR-ONLY: never a primary runtime, never a secondmate launcher, and never on any non-herdr backend.
`bin/fm-spawn.sh` refuses a `--secondmate` agy spawn (crew-only) and refuses agy on a non-herdr backend (herdr-only), both before any backend or worktree work; the refusals are covered by `tests/fm-agy-adapter.test.sh`.
tmux is deliberately out-of-scope: it has no native agent detection, so the liveness, turn-end, and composer signals below would all be absent there.

The raw-launch-command escape hatch must never be used for `agy`; use the sanctioned `--harness` path so the required gates and supervision apply.
`bin/fm-launch-lib.sh`'s `fm_launch_raw_restricted_harness` and `fm_launch_write_raw_guard` comments own the early classifier, exec-time PATH-shim invariant, accepted same-user removal residual, and security-boundary rationale.
`tests/fm-launch-lib.test.sh` covers each bypass class, and `tests/fm-agy-adapter.test.sh` covers real-spawn guard installation.

On Herdr, native `agent get` supplies agy identity, liveness, and working status without a screen scrape.
`bin/fm-busy-lib.sh` owns the identity-gated busy-state contract.

agy installs no turn-end hook or status writer; the watcher instead converts its identity-gated, debounced herdr-native idle into the shared `state/<id>.turn-ended` wake notification without treating it as current-state truth or relaxing the event-stream policy.
`bin/fm-transition-lib.sh`'s `fm_transition_native_completion` comment owns the native-identity gate, debounce state machine, and re-arm behavior, while `bin/fm-watch.sh` owns its poll-loop integration.
After the cursor adoption that mechanism serves agy alone.
No repo `.agents/hooks.json` is ever written for agy, and no new shared global hook file is added.
Composer classification stays `unknown` for agy (the safe default) and no override is added.
agy's prompt shape is Pi's "separated" shape but native identity reports `agy`, not `pi`, so the Pi separated-shape gate in `bin/backends/herdr.sh` correctly rejects it.
A generic bare-glyph "empty" rule must NOT be added: agy's prompt glyph is literally `>`, identical to a dead bash shell, so a generic rule would be a dead-shell send hazard - any future override must be native-identity-gated exactly like the Pi gate.
The only cost of `unknown` is that the away-mode escalation injector defers rather than injects into an agy pane, which is a minor functional gap, never a safety hole.
[`docs/herdr-backend.md`](../../../../docs/herdr-backend.md#current-transport-behavior) owns agy prerequisites and atomic-prompt delivery semantics.
Treat `verdict=unverifiable` as possibly accepted and do not blindly resend it.

| Fact | Value |
|---|---|
| agy launch behavior | The initial prompt stays interactive and tool use is auto-approved by the verified template in `bin/fm-launch-lib.sh`. |
| Busy-pane signature | native herdr `agent_status == working` (generic, no screen-scrape). |
| Turn-end | watcher-side identity-gated, debounced native-idle wake notification; no hook installed and no repo or new global hook file written. |
| Composer state | `unknown` (safe default; no override). |

agy workspace trust is the one extra launch step.
An interactive agy launch gates on a per-workspace trust modal that `--dangerously-skip-permissions` does NOT cover, and trust is an EXACT-path entry (not a prefix) in agy's SINGLE global settings file `~/.gemini/antigravity-cli/settings.json` under `trustedWorkspaces`.
So spawn pre-seeds the exact crew-worktree path before launch and teardown removes only a firstmate-owned entry.
`bin/fm-agy-trust-lib.sh`'s header and function comments own the created-vs-preexisting signal, ownership-and-liveness lock, atomic mutation, abort rollback, teardown ordering, retry-evidence preservation, and fail-closed behavior.
An agy spawn aborts if that trust write does not land, because an unseeded launch would wedge on the modal.

