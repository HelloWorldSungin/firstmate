---
name: harness-adapters
description: >-
  Agent-only reference for firstmate harness operations.
  Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
  Contains verified facts for claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, and muse, plus the crew-only herdr-only agy adapter.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

## Load the variant file for the harness you are acting on

This file is the shared head: every fleet-wide rule, every cross-harness comparison, and every contract no adapter may copy.
Each harness's own facts - busy source, exit command, interrupt, dialogs, launch shape, resume path, quirks - live in one variant file under `harnesses/`, and exactly one variant loads per operation.

Resolve it by harness name, never by guessing the filename:

```bash
bin/fm-harness-adapter-doc.sh <harness>          # prints the variant file's path
bin/fm-harness-adapter-doc.sh --print <harness>  # prints the variant file's contents
```

The harness name comes from the same place the operation does: `bin/fm-harness.sh crew` or `secondmate` for a spawn, the resolved dispatch profile when one matched, an explicit captain override, or `harness=` in `state/<id>.meta` for recovery and every action against an existing worker.
`pi` and `pi-signed` share one variant because they are one verified adapter with two launch identities; every other verified harness has its own file.

The resolver refuses rather than degrading, which is the whole reason it exists: an unrecognized name (including `default`, `unknown`, and any harness with no variant file yet) and a missing or unreadable variant file each exit non-zero naming what failed.
Never answer a harness-specific question from this shared head alone when the resolve failed - a partial answer about a trust dialog or an exit path is exactly the failure this split must not introduce.
Read the head plus one variant; open a second variant only for a deliberate cross-harness comparison, never to fill a gap a failed resolve left.

There is deliberately no variant table here to read instead: an index would be an unguarded second copy of the routing table, and a copy is exactly what lets a lookup half-succeed.
`--list` prints the names that resolve.

## Shared contracts and where each harness's own facts live

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
Optional dispatch profiles in `config/crew-dispatch.json` can override that static default for one crewmate or scout dispatch by selecting concrete harness, model, and effort axes at intake.
When a matched rule or default is a profile array, load `quota-array-dispatch` for the completion-aware candidate choice after this skill establishes harness and model/provider facts.
The captain may override that file at session start or later; a per-task instruction such as "run this one on codex" overrides it for that dispatch only.
`default` means mirror firstmate's own harness.

Secondmates have their own harness knob, so a secondmate can run on a different adapter than crewmates.
`config/secondmate-harness` is the harness the primary uses to launch SECONDMATE agents, resolved through the fallback chain `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own.
An absent or `default` `config/secondmate-harness` therefore behaves exactly as the crew harness did before this knob existed (secondmates launched on the crew harness); setting it splits the two.
The `agy` crew-only gate is the exception: if that fallback resolves to it, configure a different concrete secondmate harness before spawning.
The [`secondmate-provisioning` skill](../secondmate-provisioning/SKILL.md) owns the complete inherited-local-material allowlist and propagation contract.
This skill owns only the harness-relevant consequence: a secondmate's own crewmates use the primary's inherited dispatch profiles and static harness value, while `config/secondmate-harness` is the primary's own setting and is never inherited - secondmates do not spawn secondmates.
Inheritance copies the literal `config/crew-harness` file, so for a secondmate's own crewmates to run on the primary's crewmate harness the captain must set `config/crew-harness` to a concrete adapter name, such as `codex`.
If `config/crew-harness` is unset or `default`, there is no concrete value to inherit, so the secondmate's own crewmates fall back to the secondmate's own/detected harness rather than the primary's effective crewmate harness.
Inheritance also copies the literal `config/crew-dispatch.json` file, so secondmates apply the same best-fit profile rules for their own crewmates.

Each adapter splits into mechanics and knowledge.
Exact launch-command construction, including the autonomy flag and the model and effort flags, lives in `bin/fm-launch-lib.sh`.
The surrounding per-task gates, workspace-trust orchestration, and any enabled crewmate turn-end hook installation live in `bin/fm-spawn.sh`.
Agent lifecycle mechanics - which key interrupts a turn, how many times it must be sent, whether the composer needs clearing afterwards, which command exits the agent, and which task kinds the adapter can run - are owned by the executable control plane in `bin/fm-control-lib.sh` and delivered by `bin/fm-control.sh <task-id> interrupt|exit|relaunch`.
Never hand-type an interrupt key or exit command through `fm-send`: a routing-marked lifecycle command becomes chat the agent reasons about instead of executing, which is the defect the control plane exists to remove ([`docs/agent-control.md`](../../../docs/agent-control.md)).
The per-adapter `Exit command` and `Interrupt` rows below remain the verification record for those values; the executable owner is what firstmate actually runs, so a newly verified adapter is not reachable by the control plane until its rows land in that owner.
The primary-session "no turn ends blind" guard contract and harness hook installation paths live in `docs/turnend-guard.md`.
The primary-session watcher wake protocols are rendered from `docs/supervision-protocols/` by `bin/fm-supervision-instructions.sh`.
The supervision knowledge lives here: busy state, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.
Each adapter's `Busy state` row names only which semantic source that harness uses; `bin/fm-busy-lib.sh` owns the contract itself, including verdicts, source attribution, and the verification gates that keep an unverified harness at unknown.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, tell the captain under `AGENTS.md` section 9 that the requested worker runtime is not verified yet, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime before future use.
The verified-but-restricted `agy` adapter follows its own variant file instead of this unverified-adapter fallback.
Do not pause current work for that future-verification choice, and never launch an unverified adapter.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, its semantic busy source and trust gate in `bin/fm-busy-lib.sh`, any new composer shape, prompt glyph, or idle placeholder in the shared screen classifier under "Shared composer classifier" below, the tmux agent-process liveness classification in `bin/backends/tmux.sh` when the harness can launch a secondmate, and the verified knowledge in a new `harnesses/<name>.md` variant file plus its row in `bin/fm-harness-adapter-doc.sh`'s routing table - until both land, the resolver refuses that harness by name rather than silently serving this head alone.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
Within the Pi family, only the exact launch-boundary marker `FM_PI_HARNESS=pi-signed` alongside `PI_CODING_AGENT=true` selects the signed identity; unmarked shared launcher ancestry remains `pi`.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness` (absent or `default` -> own).
`bin/fm-harness.sh secondmate` resolves the secondmate-launch harness through the chain `config/secondmate-harness` -> `config/crew-harness` -> own, so an unset `config/secondmate-harness` matches the crew harness.
`bin/fm-spawn.sh` uses `crew` mode for a crewmate/scout launch and `secondmate` mode for a `--secondmate` launch, re-resolving on every spawn so the split is durable across respawns; an explicit per-spawn harness arg overrides either resolution but never the cursor/agy kind and backend gates.
On `unknown`, ask the captain instead of guessing.
A captain override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## Primary turn-end guard

The primary integrations for `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, and `cursor` have empirically validated hook paths for the "no turn ends blind" guard.
`claude` and `codex` block directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`opencode`, `pi`, and `pi-signed` expose passive lifecycle callbacks and force one bounded follow-up when the shared predicate blocks.
Grok selects native blocking or its pre-native bounded resume fallback from the exact running Stop payload; [`docs/turnend-guard.md`](../../../docs/turnend-guard.md) owns that contract.
Kimi is outside the primary turn-end guard scope, while `docs/turnend-guard.md` owns its separate guarded global hook for crew wake signals.
muse is CREWMATE/SCOUT ONLY and has no primary integration at all: its plugin engine (its only hook surface) is disabled in the default build, and its Claude-compatible hook dialect names `asyncRewake` and model reawakening as explicitly unsupported, which is exactly what a firstmate primary's turn-end supervision needs.
`bin/fm-spawn.sh` refuses a `--secondmate` launch on muse for that reason.
cursor HAS a full hooks system: 20 lifecycle events configurable at project scope in `.cursor/hooks.json`, plus a Claude-Code compatibility name map that also loads `<project>/.claude/settings.json`.
Its `stop` step cannot block - exit 2 there is a silent no-op - so `bin/fm-turnend-guard-cursor.sh` parks the turn boundary on the watcher and returns one bounded `followup_message` instead.
Because Cursor loads the tracked Claude settings too, every Claude-shaped entrypoint whose event Cursor covers stands down on a Cursor-delivered payload.
The exact hook files, commands, scoping rules, and fail-open tradeoffs are owned by `docs/turnend-guard.md`.
`docs/verification/supervision.md` "Turn-end guard" owns active validation evidence.
When changing any primary turn-end hook, validate the real harness behavior in a scratch project or throwaway home before trusting it, then update that doc and the relevant concise fact below.

The same per-task hook files optionally carry the dashboard's agent-event reporting for `claude` and `opencode` when a home has instrumentation enabled.
Those entries are additive and always exit 0 silently off the critical path, so they cannot change any guard's decision, and they are absent entirely otherwise; [`docs/dashboard-events.md`](../../../docs/dashboard-events.md) owns that contract.
Preserve that property when editing the per-task wiring in `bin/fm-spawn.sh`.

## Primary pre-arm (PreToolUse) seatbelt

The primary integrations for `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, and `cursor` also have wired PreToolUse-equivalent hooks that deny a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs.
`claude` and `codex` block directly through PreToolUse hooks; `grok` blocks the same way but requires every `$VAR` reference in its hook `command` string to carry an inline `:-default` or it fails to launch the hook entirely.
`opencode`, `pi`, and `pi-signed` block by throwing from `tool.execute.before` / returning `{block: true}` from `tool_call`.
The exact hook files, commands, output-shaping quirks (Claude Code only honors the deny when stdout is empty), and validation transcripts are owned by `docs/arm-pretool-check.md`.
When changing any watcher-arm PreToolUse hook, validate the real harness behavior in a scratch project before trusting it, then update that doc.
## Primary delegation-shape guard

Claude exposes built-in delegation, scheduling, and worktree tools that a primary session can use to create work with no `state/<id>.meta`, which makes the whole guard stack inert because every guard counts that metadata.
The shipped mechanism is `bin/fm-subagent-pretool-check.sh`, a primary-home PreToolUse guard that denies a delegation-SHAPED tool name.
Claude primaries should also use an untracked per-home local `permissions.deny` list as hardening for known Claude delegation tools, because it removes them from the model's schema so they are never offered.
That deny list must not ship in tracked `.claude/settings.json` because it is Claude-only rather than harness-agnostic, and because tracked project settings propagate into linked worktrees where they disarm legitimate crewmates.
`docs/subagent-guard.md` owns the full contract, the local deny-list recommendation, the `FM_ALLOW_SUBAGENT=1` escape hatch, and the per-harness applicability review.

Two verified facts worth pinning here.
The subagent tool presents to the model as `Agent`, and on Claude Code 2.1.217 both `Agent` and `Task` work as `permissions.deny` keys, verified by an A/B with a nonsense-name control.
`permissions.allow` is a pre-approval list rather than an availability list, so there is no fail-closed positive allowlist.

## Primary session start

AGENTS.md section 3 remains the behavioral owner for session start, while tracked native adapters enforce it idempotently at session open through one of two tiers.
Before inspecting or changing session-open behavior, read `docs/sessionstart-nudge.md`, the single owner of tier assignment, per-surface transports, source routing, the runtime bound, and fail-open behavior.
`docs/verification/supervision.md` "Native session-start delivery" owns active dated commands, payloads, and evidence.

## Primary watcher supervision

At session start, `bin/fm-session-start.sh` prints exactly one watcher supervision block for the detected primary harness.
Do not substitute another harness's wait shape when resuming supervision.
Claude's Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns tokenless re-arm around `bin/fm-watch-arm.sh`, and Grok uses tracked background-notify cycles around `bin/fm-watch-arm.sh`.
Codex uses bounded foreground checkpoints through `bin/fm-watch-checkpoint.sh` because Codex cannot reason while a foreground tool call is running.
OpenCode uses `.opencode/plugins/fm-primary-watch-arm.js`, which coordinates with the turn-end guard plugin and wakes the TUI with `client.session.promptAsync`.
Pi and pi-signed use the tracked `.pi/extensions/fm-primary-turnend-guard.ts` plus the tracked `.pi/extensions/fm-primary-pi-watch.ts`, both project-local extensions the Pi engine auto-discovers once trusted.
When changing any primary watcher adapter, update `docs/supervision-protocols/`, `docs/turnend-guard.md` if a shared idle or turn-end hook changed, and the relevant concise fact below.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values chosen by firstmate at intake.
Do not make the shell scripts parse or match natural-language dispatch rules.

Effort precedence is an explicit per-task captain instruction first, then any applicable standing dispatch profile or secondmate pin, then the generic fallback below.
Never replace an effort value supplied by either higher-precedence source.
Use the fallback only when neither the captain nor applicable standing configuration specifies effort.
Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design.
Choose intermediate levels proportionally as complexity, uncertainty, blast radius, or open-ended reasoning increases.
When a verified adapter lacks `xhigh`, cap the choice at its highest supported non-`max` level rather than omitting the intended effort silently.
Never select `max` from this fallback; use it only when the captain has explicitly expressed that per-task or standing preference.

The supported launch-profile flags below are summarized as verified selection axes; each row records its evidence, while `bin/fm-launch-lib.sh` owns their exact command-line rendering.

| Harness | Model axis | Effort axis | Notes |
|---|---|---|---|
| claude | `--model <model>` | `--effort <low\|medium\|high\|xhigh\|max>` | Verified on Claude Code 2.1.196. |
| codex | `--model <model>` | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` | Verified on codex-cli 0.142.1. The installed binary schema contains `model_reasoning_effort`, the active config uses it, and the bundled model catalog advertises only low/medium/high/xhigh. `max` is omitted. |
| grok | `--model <model>` | `--reasoning-effort <low\|medium\|high>` | Verified on grok 0.2.99 (2026-07-13). `--effort` is an alias, but firstmate's profile axis is reasoning effort. As of 0.2.99 the ceiling is `high`; both `xhigh` and `max` are rejected with `use one of: high, medium, low`, so firstmate omits them. |
| pi / pi-signed | `--model <model>` | `--thinking <low\|medium\|high\|xhigh\|max>` | Verified 2026-07-27 on Pi and pi-signed 0.82.0. Both expose the same accepted thinking levels and completed the same model-qualified max-thinking smoke. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |
| kimi | `--model <model>` | none | Verified 2026-07-25 on Kimi Code CLI 0.29.1. |
| cursor | `--model <model>` | none | Verified 2026-08-11 on Cursor Agent CLI 2026.08.11-e8db854. No effort flag exists, so firstmate records the requested effort in task metadata and omits it from the launch. Validate ids against `cursor-agent --list-models` rather than assuming a low/medium/high family: the live catalog carries only `-high` Grok ids. |
| agy | `--model <model>` | `--effort <low\|medium\|high>` | Crew-only and herdr-only (see the agy section). Verified on agy 1.1.5, whose `--help` advertises only these three levels; `xhigh` and `max` are omitted. |
| muse | `--model <model>` | `--reasoning-effort <low\|medium\|high\|xhigh>`, and `ultra` only for an explicit `max` | Verified 2026-08-05 on Muse Code 0.1.0-R708.1. The flag accepts `none\|minimal\|low\|medium\|high\|xhigh\|ultra` and defaults to `high`. `ultra` is muse's max-class level, so it is reachable only through an explicit captain `max`, never from the generic fallback; `none` and `minimal` sit below the shared vocabulary and stay unreachable. |

The concrete `harness` field owns adapter identity independently of the model provider: `harness=pi` with `model=xai/grok-*` is Pi using xAI, not `harness=grok`, and does not require Grok CLI login; `harness=grok` remains the standalone Grok Build CLI adapter.
Likewise, `harness=cursor` with `model=cursor-grok-4.5-*` is Cursor Agent CLI routing a Grok model, not the xAI Grok Build `grok` harness.
No script resolves that split for you: establish which credential store a tuple reads from the discovery surfaces below plus `quota-axi auth --json`'s per-provider sources, and show that reasoning rather than inferring it from a harness, model, or source name.

### Model support discovery

Treat model and provider knowledge as current source-of-truth discovery, not as a permanent namespace or provider mapping.
Use the discovery surface in the current authenticated environment because supported and available models can change by version, account, and configuration.

| Harness | Authoritative discovery surface |
|---|---|
| claude | Open the current interactive session's `/model` picker; `claude --help` documents the accepted alias or full-model-name input shape. |
| codex | Open the current interactive session's `/model` picker. |
| opencode | Run `opencode models [provider]`, which lists available provider/model identifiers. |
| pi / pi-signed | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |
| grok | Run `grok models`, which lists the models available to the current Grok installation and account. |
| kimi | Run `kimi provider list --json`, which lists the current provider and model configuration. |
| cursor | Run `cursor-agent --list-models` (or the legacy `agent --list-models`), which lists the ids available to the current Cursor account. `cursor` is not the CLI name. |

For an unfamiliar harness or model namespace, establish support and provider identity from that harness's authoritative CLI help, model listing, or current documentation rather than guessing from a name or prefix.
A listing that reaches the account and does not contain the model is concrete evidence the model is unsupported: block that candidate and quote the result.
A discovery surface you could not reach establishes nothing; report that as uncertainty rather than turning it into a supported or unsupported verdict.

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness.
This preserves launch success instead of passing a known-bad value.
For Cursor, select the intended reasoning class through a model id the account's own `--list-models` actually returns, and leave the separate effort axis unset.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi and pi-signed: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- grok: `/<skill>`, for example `/no-mistakes` (same form as claude). Verified end to end: grok discovers the user-level `no-mistakes` skill, `/no-mistakes` invokes it, and grok drives a real `no-mistakes axi run`. Like codex's `$`/`/` popups, typing `/<skill>` opens grok's slash-autocomplete, so a too-fast Enter selects the popup entry instead of sending, and for an argument-taking command (like `/no-mistakes`'s optional task-first argument) that first Enter only expands the popup selection into an argument-hint placeholder rather than submitting - a genuine second Enter is required (see [the grok variant file](harnesses/grok.md) for the 2026-07-03 incident and fix). `fm_tmux_submit_core`'s retried Enter (used by `fm-send` on the tmux backend) handles this through the shared structural composer classifier; the herdr backend needed a dedicated fix (`fm_backend_herdr_composer_state`, docs/herdr-backend.md) because its prior delta-based verification false-positived on that same popup-close content change.
- kimi: `/<skill>`, for example `/no-mistakes`.
- cursor: `/<skill>`, for example `/no-mistakes`. Cursor discovers firstmate's user-level skills. Its slash popup swallows the first Enter, so a genuine second Enter submits; the shared submit retry handles it.

## Submission acknowledgement hazards

A send or key action reporting success is not proof that the intended action happened.
OpenCode can accept and queue an Enter while leaving text visible, Grok can consume Enter in its slash popup without submitting, and Kimi can silently drop a message sent before readiness even though the send returns success.
The shared symptom is a healthy-looking pane with no work in progress, so each adapter must verify the observable postcondition that is specific to its TUI.

The shared submit core covers the popup class generically: it retries Enter and asks the shared composer classifier below whether text is still pending, so the second Enter that a `/` or `$` autocomplete popup needs is delivered without any adapter carrying its own popup logic.
That is why a harness whose popup swallows the first Enter needs no special case, and why a harness whose first Enter submits cleanly needs no exception.
Each adapter's own postcondition - which token, transcript record, or lifecycle event proves the turn actually started - is in its variant file.

## Trust and first-launch dialogs

Several harnesses gate a first launch in a not-yet-trusted directory behind a modal, and firstmate's spawn path suppresses that modal where a launch flag can.
Where it cannot, the dialog is a post-launch step, and the procedure is the same for every harness that has one.

After every spawn, peek the pane within about 20 seconds.
If a dialog is showing, accept it from an active firstmate session using `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, unless `FM_HOME` is already set to the active firstmate home; then verify the brief started processing.

Which dialog a harness shows, which key or choice accepts it, whether a launch flag suppresses it, and where the decision persists are per-harness facts in the variant file.
A harness whose trust state is seeded before launch rather than accepted after it says so there, and its spawn aborts when the seeding does not land rather than launching into a modal.

## Shared composer classifier

`bin/fm-composer-lib.sh` is the ONE fleet-wide owner of composer classification: every composer shape, prompt glyph, and idle placeholder, and the `empty` / `pending` / `pending-unproven` / `unknown` decision.
No adapter and no backend may carry its own copy, and teaching it a new shape gives every backend that shape in the same commit.
Four properties of that owner are load-bearing for every harness, so they are stated here and never restated per variant.

It reads the composer structurally.
The classifier locates the complete composer box and classifies every content row, so no backend depends on a terminal cursor row or a fixed offset, and a composer that has grown to multiple rows is covered without adapter shape scans.
Real text on any proven content row is positive evidence that submission is still pending.

It strips ghost text before classifying.
`fm_composer_strip_ghost` drops dim/faint SGR 2 runs and dark or muted 24-bit TRUECOLOR foregrounds (perceived luminance below `FM_COMPOSER_GHOST_LUMA_MAX`, default 128) on every styled reader - tmux, herdr, and Zellij all route through it - so a placeholder or predicted-prompt suggestion reads as an empty composer rather than typed text.
The luminance half assumes a dark terminal theme, the fleet reality; the SGR 2 half is theme-independent.
[`docs/herdr-backend.md`](../../../docs/herdr-backend.md) "Composer and injection safety" owns the broader handling and that tradeoff.

It converts a busy pane's proven-pending composer rather than calling it a swallow.
Once the Enter retries are spent, a structurally pending composer on a delivery-busy pane means the Enter was accepted and queued, not swallowed, so the caller must not re-send; an idle or unreadable pane keeps `pending` as a genuine swallow.
`fm_composer_queued_enter_verdict` (`bin/fm-composer-lib.sh`) is the ONE owner of that policy and both tmux and herdr delegate to it, supplying only their own busy primitive; the backend-specific signals are documented in [`docs/tmux-backend.md`](../../../docs/tmux-backend.md) and [`docs/herdr-backend.md`](../../../docs/herdr-backend.md).
Regression coverage is `tests/fm-tmux-submit-busy.test.sh`, `tests/fm-composer-lib.test.sh`, and `tests/fm-backend-herdr.test.sh`; the live Herdr Claude guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 tests/fm-herdr-submit-confirm-live-e2e.test.sh`.
The exception was found on opencode, but nothing in it is opencode-specific: any harness whose pane is busy with pending text reaches the same verdict.

The styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

A variant file carries only its own harness's instance of this: its glyph and colors, the placeholder it draws, the dated capture that proved the threshold, and any native-identity-gated exception.
Never the rule itself.

## Dated verification evidence

Each variant's `VERIFIED` header and its version observations are pointers to evidence, not the evidence.
[`docs/verification/runtime-backends.md`](../../../docs/verification/runtime-backends.md) owns the dated per-harness captures and commands, and [`docs/verification/supervision.md`](../../../docs/verification/supervision.md) owns the turn-end guard and native session-start records.
Refresh the liveness and identity evidence for every INSTALLED harness with the fleet-wide opt-in drift guard, and re-run it after any harness upgrade before trusting a refreshed per-harness fact:

```bash
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```
