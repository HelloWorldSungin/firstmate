# Calm-mode harness feasibility

This document owns the version-scoped feasibility evidence, Pi transcript taxonomy, and supported-API boundaries for Firstmate calm mode.
[`calm.md`](calm.md) owns the current user-facing `/calm` usage and limitation contract.

## Required extension surface

A qualifying implementation must auto-load from the trusted project, persist the toggle choice for the effective Firstmate home across Pi session starts and resumes, keep working activity visible, emit no Calm status row, redraw already-rendered controllable rows, remove supported hidden rows without gaps, restore ordinary rendering, and leave delivery, tool execution, model context, session storage, export and share operation, diagnostics, and expansion state unchanged.
The governing presentation policy allows genuine original user prompts, genuine user-facing assistant text, and working activity.
Working activity may be presented through Pi's stock row or through a supported Calm-owned widget, but Calm must leave the stock row untouched whenever Calm is off.
Changing persisted context to remove hidden content, filtering provider context, patching installed harness code, or claiming coverage outside a supported renderer does not satisfy that boundary.

## Compatibility evidence

[`calm.md`](calm.md#pi-compatibility) owns the current Pi compatibility contract.
Pi 0.81.1 was installed when Calm was first built, and Pi 0.82.0, 0.83.0, and 0.84.1 are the later reverification targets recorded in the dated sections below.
This paragraph is the authoritative statement of that verified range.
Six later statements in this file restate it inline as "Pi 0.81.1 through 0.84.1" and each has to be found and edited by hand whenever the range moves; issue [#119](https://github.com/HelloWorldSungin/firstmate/issues/119) owns consolidating those six behind this single owner.
Across those versions only Pi 0.84 introduced a relevant presentation API change, the 4th `UserMessageComponent` Markdown-transformer argument, which both of Calm's user-row construction sites now forward: the operational-user adapter reads it off the `InteractiveMode` it patches, and the legacy synthetic entry renderer reads it off the host captured for it.
The adapters gate on the exact method they patch rather than on a version number, so those versions remain verification evidence rather than compatibility bounds.
The exported classes used by the adapters (`AssistantMessageComponent` and `InteractiveMode`) are undocumented internals with no stated version guarantee.
`tests/fm-calm-pi-extension.test.sh` records the installed Pi version as evidence without gating on it and covers both newer synthetic versions and an unavailable adapter seam.

### Built-in tool override constraints

[`calm.md`](calm.md#pi-compatibility) owns the current user-facing collision behavior and limitation.
Inspection of Pi 0.80.10 and 0.82.0 established that extensions override a built-in tool by registering the same name, the first registered extension wins the complete `ToolDefinition` without merging, and Pi exposes no unregister operation.
Pi loads project-local extensions before global or CLI-configured extensions, so Firstmate's tracked Calm extension previously won those collisions even when its persisted preference was off.
The losing definition's execution and render functions are both discarded, so unconditionally registering Calm's wrappers would replace another extension's same-named tool rather than changing presentation alone.

Pi's `getAllTools()` exposes tool metadata and source identity but not the executable or rendering functions needed to wrap another extension's full definition.
It is also usable for reliable collision detection only after extension binding, which makes it suitable for the first same-session `/calm` activation but not for synchronous extension loading.
Deferring registration to `session_start` is not an equivalent path: Pi constructs restored tool rows from an earlier tool-registry snapshot during reload, new-session, fork, and session switching, so those rows retain the definition captured before `session_start`.
`tests/fm-calm-pi-extension.test.sh` covers the resulting split contract: no load-time claims while Calm is off, synchronous claims while it is already on, collision-checked first activation with a warning, preservation of a contested tool's execution, and the non-retroactive bound for rows rendered before first activation.

## Pi 0.81.1 end-to-end reproduction

The Pi version installed at the time was verified on 2026-07-22.

```text
$ pi --version
0.81.1
```

### Original transcript cleanup

The pre-cleanup reproduction used a real isolated Pi TUI at 180 columns by 44 rows with the tracked Calm and watcher extensions, an isolated `FM_HOME`, and a live home-owned watcher cycle.
The model called `fm_watch_arm_pi`, the real tool returned `watcher: started Pi extension arm child 1`, and a `done:` status write caused the watcher extension to inject `FIRSTMATE WATCHER WAKE: signal: ...` followed by the stable drain instruction.
With Calm off, the captured transcript contained the genuine user prompt, the full watcher tool shell, the synthetic user-role wake, four collapsed `Thinking...` labels, built-in tool rows from wake handling, and the final assistant response.
With the pre-cleanup implementation's Calm mode on, the existing seven built-in tool rows disappeared, but the watcher tool shell, synthetic wake, and all four `Thinking...` labels remained.
The final screenshot-scale regression reproduced the same transcript after the cleanup and verified that Calm removed those remaining controlled rows while retaining the genuine prompt, a watcher-shaped genuine near-miss prompt, and the genuine assistant responses.

The original proven comparison path was a built-in text tool.
Calm owned both of that tool's supported renderer slots and switched its shell to `renderShell: "self"`, so returning empty components removed the complete row and `setToolsExpanded` redrew existing tool components.
Adding supported empty renderer slots to a scratch copy of `fm_watch_arm_pi` likewise removed its row while the real watcher still started and the model still returned `PROBE_COMPLETE`.
Legacy synthetic presentation entries use `CustomEntryComponent`, whose host adds spacing only when its renderer returns content, so an undefined Calm renderer result removes the complete row and can later restore it through the ordinary expansion redraw.
The later duplicate-turn evidence below supersedes custom-message rerouting as an acceptable implementation for current operational input.

### Hidden-block height regression

The 2026-07-23 end-user-aligned reproduction used the installed Pi 0.81.1 TUI at 100 columns by 44 rows, an isolated project and `FM_HOME`, the real `/skill:ahoy` command path, and a deterministic provider that produced five thinking-bearing read calls, five tool results, final hidden thinking, and a visible final response.
With Calm on and Pi's thinking display collapsed, the completed turn left 14 empty rows between the visible collapsed `[skill] ahoy` content row and the first final assistant row.
With Calm off, the same sequence rendered all six `Thinking...` labels and all five read rows instead of an empty field.
A controlled baseline containing only the skill row and final response had two standard visible-row separators.
Adding one final thinking block increased that gap from two rows to four, while adding a tool call without a result or a completed tool call and result left it at two.
Removing only all six thinking blocks from the failing persisted session left all five tool calls and results intact and reduced the gap from 14 rows to the two-row baseline.
Enabling Pi's `terminal.clearOnShrink` on the unchanged failing session left the gap at 14 rows, which rules out stale terminal allocation as the cause.

The initiating trigger was a non-empty thinking block in an assistant message that Pi rendered through `AssistantMessageComponent`.
The masking condition was the combination of Calm being active and Pi's thinking display being collapsed, because Calm replaced the visible label with an empty string while Calm off or explicit thinking expansion filled those rows with visible content.
The visible symptom was the large empty vertical field between the intentionally visible collapsed skill row and final assistant response.

The earliest divergent layout path was `AssistantMessageComponent.updateContent`, before terminal differential rendering or tool-result composition.
Pi computed `hasVisibleContent` from the original thinking data and added a leading `Spacer` before applying the hidden-thinking presentation.
Pi then styled the empty label before constructing `Text`, so the resulting ANSI-only string occupied one rendered row, and a thinking block followed by assistant text also added its ordinary inter-block spacer.
Each thinking-only tool turn therefore retained two empty rows, while the final thinking-plus-text turn retained two extra rows beyond the final response's normal leading separator.
The proven tool path diverged through `ToolExecutionComponent`, where the Calm self-render shell returned zero lines for both call and result slots and contributed no residual height.

The smallest counterfactual was the thinking-only removal from the same persisted session, which preserved the skill, tools, results, final response, session ordering, and terminal settings while eliminating every unwanted row.
The single-thinking, tool-call-only, tool-result, Calm-off, and `clearOnShrink` controls deliberately sought disconfirming evidence and isolated collapsed thinking layout from skill, tool, result, and terminal-cache candidates.
PR 927 made Calm persistent and described controlled rows as gapless while retaining a documented unsupported boundary for collapsed-thinking spacing.
PR 936 removed the unsafe operational-input reroute and preserved legacy zero-height entries but did not change assistant-message layout.

The fix installs one idempotent presentation adapter, verified on Pi 0.81.1 through 0.84.1, on the exported `AssistantMessageComponent.updateContent` method.
The adapter probes for that exact method and, per the [compatibility contract](calm.md#pi-compatibility), degrades independently with a diagnostic rather than gating on a version number.
Only while Calm is active and Pi has collapsed thinking does the adapter pass a shallow thinking-free presentation copy into Pi's ordinary layout calculation, then retain the original message on the component for invalidation and thinking expansion.
The persisted assistant message, provider context, tool execution, export data, and expansion history remain unchanged.
Collapsed thinking-only assistant messages now render zero rows, thinking before visible assistant text adds no spacing beyond the text-only baseline, and expanding thinking still renders the original reasoning.

The disconfirming checks deliberately retain supported boundaries.
An arbitrary third-party custom tool and a built-in read image remain visible because Pi exposes neither a global tool renderer nor image-row control.
Expanded thinking remains visible by design, while re-collapsing it returns to zero-height Calm presentation.
Ordinary user-role near misses remain visible, including quoted current markers, ASCII-only labels, unrelated text before a marker, unrelated text after U+2063, and image-bearing input.

## Duplicate-turn regression and semantic boundary

The captain-visible regression reproduced three consecutive times in a persisted Pi session under `~/.pi/agent/sessions/`.
Assistant `bb83873b` was followed by hidden custom input `9d087b52` and distinct duplicate assistant `f4232aa3`.
Assistant `3a388d8c` was followed by adjacent hidden custom inputs `e1914f28` and `cfdefb09` and distinct duplicate assistant `47c81eeb`.
Distinct provider response identifiers and signatures prove separate model turns rather than duplicate TUI paint.

The initiating trigger was `pi.sendUserMessage(..., { deliverAs: "followUp" })` from the watcher or turn-end adapter after a captain-facing response.
The exposure condition was Calm's loaded `input` handler from commit `6db3b09`, which ran whether the persisted toggle was on or off, returned `handled`, replaced the user message with `pi.sendMessage`, and triggered a nested custom-message turn.
The visible symptom was a second assistant row repeating the prior captain answer.
The earliest persisted divergence was the operational entry type: Calm loaded produced `custom_message` with role `custom` before provider conversion, while Calm absent produced a normal `message` with role `user`.
The earliest lifecycle divergence was that the replacement path bypassed Pi's normal user-prompt processing after the `input` event.

A native deterministic Pi TUI reproduction on landed PR 927 produced `CAPTAIN_VISIBLE_ANSWER` twice with Calm loaded and explicitly on, and produced the same duplicate with Calm loaded and explicitly off.
The same exact typed notification with Calm absent produced one captain answer followed by `MONITOR_NOTIFICATION_HANDLED`.
Removing only the input reroute from a scratch copy while leaving Calm loaded and on produced the same proven result and restored the operational entry to role `user`.
This is the smallest counterfactual and proves extension loading, not the active toggle, was the required exposure condition.
The extension-absent success path is evidence against an independent Pi-core duplicate-turn cause for the same sequence, but it does not claim Pi core could never contain a separate duplication bug.

PR 936 removed Calm's semantic input handler and custom-message delivery path because Pi 0.81.1 exposes no supported ordinary-user renderer and that replacement duplicated model turns.
That correction preserved current operational input as an exact ordinary user-role message with its ordering and authority unchanged, but deliberately left the row visible until a presentation-only boundary was proven.
Legacy `firstmate-synthetic-input-presentation` entries remained renderable so existing sessions preserved their stored presentation and zero-height hidden-row behavior.

## Operational user-row zero-height regression

The 2026-07-23 end-user-aligned reproduction used the installed Pi 0.81.1 TUI at 160 columns by 36 rows, the tracked Calm extension persisted on, an isolated home and session directory, and a deterministic in-process provider.
The injected user message began with exact U+2063 plus `FIRSTMATE_OP:` and carried the watcher status path from the durable captain screenshot followed by the blank line and stable drain instruction.
The exact U+2063 bytes, both payload lines, user role, and ordering survived live delivery and process restart.
The provider observed one matching user message, returned `OPERATIONAL_PROCESSED occurrences=1`, and the session contained one matching user entry and one matching assistant entry.

The failing viewport rendered the operational input as a five-cell-high user box on rows 1 through 5 and placed the assistant text on row 7 after Pi's normal assistant separator.
The same persisted session reproduced those coordinates after restart.
Calm off rendered the same user component geometry, proving the active toggle had no presentation effect on this path.
The initiating trigger was the exact watcher-generated user message.
The exposure condition was PR 936's safe ordinary-user delivery path combined with the absence of a user-row presentation adapter, not marker loss, event-source drift, failed classification, persistence, replay, or duplicate delivery.
The visible symptom was the complete two-line synthetic user box and its five rows of terminal height.

The earliest meaningful layout divergence from proven hidden presentation entries was `InteractiveMode.addMessageToChat`.
Its ordinary-user branch added a leading `Spacer` when applicable and then a `UserMessageComponent`, whose `Box` contributes vertical padding around the three Markdown lines.
The legacy custom-entry path instead checks renderer content before mounting a transcript child, and the completed assistant-thinking fix removes hidden thinking before assistant layout.
Those behaviors have different owners and remain separate.

The smallest counterfactual returned only from the transcript owner's ordinary-user branch for that exact watcher input.
The real Pi viewport moved the unchanged assistant text from row 7 to row 2, rendered no operational text, and still persisted one exact user entry and one exact response.
The leading cause would have been falsified if the row or height remained, the provider lost or duplicated the message, or the persisted role or bytes changed.
None occurred.

The fix installs a separate idempotent presentation adapter, verified on Pi 0.81.1 through 0.84.1, on the exported `InteractiveMode.addMessageToChat` method.
The adapter probes for that exact method and, per the [compatibility contract](calm.md#pi-compatibility), degrades independently with a diagnostic rather than gating on a version number.
It delegates current recognition to `bin/fm-operational-input.sh`, adds only the evidence-backed bare-U+2063 `Supervisor escalate (` presentation compatibility shape, mounts a `UserMessageComponent` subclass that preserves Pi's stock row plus leading spacer while Calm is off, and returns zero rendered lines while Calm is on.
It never intercepts the input event, rewrites the message, changes its role, filters model context, or changes session data.
Messages containing an image are left on Pi's ordinary path even when their text equals an operational envelope because Firstmate's authoritative producers are text-only.

A native exact-watcher run and its process-restart replay kept the neighboring assistant text at the two-row visible-only spacing while retaining one exact user entry and one processing response.
An adjacent two-notification run retained the same two-row neighboring-assistant coordinates, proving both operational components contributed zero height.
Calm off, an absent Calm preference, and an absent Calm extension retained ordinary rows.
The current exact marker and the narrow bare-U+2063 `Supervisor escalate (` compatibility shape hid under Calm, while quoted markers, ASCII `FIRSTMATE_OP:` without U+2063, ordinary text before the current marker, unrelated text after U+2063, and image-bearing input remained visible.

## Calm working presentation

Calm replaces Pi's stock working row with a small animated boat while Calm is on and one logical agent run is active.
This path uses only public extension API and patches nothing: `ExtensionUIContext.setWorkingVisible(false)` hides the stock row, and `setWidget()` installs a temporary component factory above the editor.
Pi's documented custom working-indicator frames are static and width-blind, so they cannot own responsive geometry; a widget component receives `render(width)` and can.

`.pi/extensions/fm-calm.ts` remains the sole owner of the presentation choice and the only caller of `setWorkingVisible()`, while `.pi/extensions/lib/fm-calm-working-ship.ts` owns the sprite geometry, the bounce track, and the widget.
Visibility follows `agent_start` through `agent_settled` rather than turns or tool calls.
Pi emits `agent_settled` from a `finally` block once a run will not continue automatically, so retries, automatic continuations, queued follow-ups, and compaction inside one run never remove the boat, while settle, abort, and failure all reach the same cleanup.
Repeated `agent_start` events inside one run are idempotent, and Pi disposes the previous component before installing a replacement under the same key and when it clears extension widgets, so the frame timer cannot duplicate or outlive the widget.
Pi's above-editor widget container reserves one spacer row whether or not a widget is present, so removing the boat leaves no residual blank row.

The sprite is two rows when the usable width admits the complete hull: a two-cell mainsail centered over a symmetric `\__/` hull that replaces water on its row rather than adding a third row.
The sail is directional because a mainsail extends aft of the mast, so it renders `<|` while travelling right and `|>` while travelling left.
Direction reverses the moment the boat lands on an endpoint, so the endpoint frame itself already shows the new heading and no frame at or after a bounce shows the previous sail.
The water row fills the complete supplied width, the track is recomputed and clamped from that width on every frame so a resize cannot wrap or strand the boat offscreen, and widths too narrow for the hull fall back to a deterministic single row.

One scheduler drives two logically independent clocks.
Every tick advances a bounded fixed-cell water phase, and only every fourth tick moves the boat, so at a 220ms tick the water ripples several times between boat steps and the boat travels one column every 880ms.
Ticks rather than wall-clock timestamps drive every state change, so tests seek animation time exactly, and disposing the widget stops both clocks together.
Water phases are single-column ASCII, so advancing them never changes visible width, adds a row, or moves the hull column.

Colors are standard ANSI foreground codes rather than theme lookups: blue for every water cell and yellow for the complete boat, with no bright variant, 256-color, or RGB escape.
Each colored run is closed with a default-foreground reset so styling cannot bleed into the sail row's padding, neighbouring UI, or a later frame, and geometry is always computed from visible cells rather than escape bytes.

The presentation is TUI-only and visual-only.
It adds no session entry, transcript row, model context, or export or share content, and its widget takes no keyboard input, so editor focus and Escape abort are unchanged.
Compaction and retry loaders remain stock because Pi exposes no supported replacement for them.

## Central visibility and input policy

`.pi/extensions/lib/fm-calm-visibility.ts` owns only the allowlist-style transcript presentation policy.
`bin/fm-operational-input.sh` owns current cross-language operational-input construction and parsing, while the thin Pi adapter lives at `.pi/extensions/lib/fm-operational-input.ts`.
Only `genuine-user-prompt`, `genuine-agent-response`, and `working-status` are policy-visible.
Every other audited class is policy-hidden when Pi exposes a supported presentation boundary, but semantic input is never transformed to enforce that preference.
The home-local persistence schema is owned by [`docs/configuration.md`](configuration.md#pi-calm-preference-configcalm).

Current session-start, watcher, turn-end guard, away supervisor, and launch-brief inputs retain their versioned U+2063 static envelopes.
The established leading `[fm-from-firstmate]` plus U+2063 routing carrier remains current so running secondmate charters remain compatible.
An exact current static envelope remains sufficient provenance without nonce, source-authentication, replay-prevention, secondary-token, blocking, redaction, or private-retrieval machinery.
Calm classifies only at Pi's transcript-presentation owner through the canonical parser and never replaces, reorders, or weakens those messages.

The session-start nudge already originates as a non-displayed custom message, so it remains on that existing path while retaining model context and session persistence.
Legacy Calm custom entries and messages remain in existing session artifacts, and their presentation entry still uses the supported zero-height renderer while active.
Cycling tool expansion and restoring its original value rebuilds controllable rows and leaves final `Ctrl+O` state unchanged.
Exported and shared HTML retain genuine user prompts, genuine assistant responses, current operational user messages, ordinary tool rendering, and the complete session artifact.
Serialized session data and Pi 0.81.1's sidebar tree also retain legacy hidden operational custom messages.

## Complete currently reachable Pi transcript taxonomy

The taxonomy was derived from Pi 0.81.1's installed public declarations, documentation, examples, `interactive-mode.js`, and its exported component implementations.
The test fixture enumerates every class below through the centralized policy, and the interactive fixture exercises the screenshot classes, current user-role operational input, and legacy synthetic presentation entries.

| Policy class | Pi transcript path | Calm result (verified on Pi 0.81.1 through 0.84.1) |
| --- | --- | --- |
| `genuine-user-prompt` | `UserMessageComponent` | Visible, including every tested operational near miss. |
| `genuine-agent-response` | Assistant text in `AssistantMessageComponent` | Visible. |
| `assistant-thinking` | Thinking content in `AssistantMessageComponent` | Collapsed reasoning is removed from the shallow presentation copy before layout and occupies zero rows; explicit expansion renders the original reasoning. |
| `assistant-tool-call` | `ToolExecutionComponent` | Seven built-ins and `fm_watch_arm_pi` hidden; arbitrary custom tools remain an unsupported boundary. |
| `tool-result` | `ToolExecutionComponent` | Text results for the controlled tools hidden; arbitrary custom results remain an unsupported boundary. |
| `tool-image` | Image children appended outside tool renderer slots | Unsupported boundary; remains visible. |
| `user-bash` | `BashExecutionComponent` for `!` and `!!` | Unsupported boundary; remains visible. |
| `skill-invocation` | `SkillInvocationMessageComponent` plus parsed user text | Unsupported boundary; remains visible. |
| `custom-message` | `CustomMessageComponent` when `display` is true | The session-start nudge and legacy Calm context messages use `display: false`; arbitrary extension messages remain an unsupported boundary. |
| `custom-entry` | `CustomEntryComponent` with a registered renderer | Legacy Calm presentation entries rebuild to zero children without a residual spacer and restore through ordinary expansion redraw when mounted, and while Calm is off they render a stock user row built from the mounting host's Markdown theme, output padding, and Markdown transformers; arbitrary extension entries remain an unsupported boundary. |
| `compaction-summary` | `CompactionSummaryMessageComponent` | Unsupported boundary; remains visible. |
| `branch-summary` | `BranchSummaryMessageComponent` | Unsupported boundary; remains visible. |
| `working-status` | `WorkingStatusIndicator`, or the Calm working-ship widget while Calm is active | Always visible. Calm off leaves Pi's stock row untouched; Calm on hides that row for the duration of one logical agent run and renders the working ship instead. |
| `command-status` | Interactive command result and status rows | Calm emits no enable notice, but generic Pi command rows remain an unsupported boundary. |
| `system-notice` | `showStatus`, `showError`, compaction, retry, and startup warning rows | Unsupported boundary; remains visible. |
| `cache-notice` | Non-persisted cache-miss `Text` row | Unsupported boundary; remains visible. |
| `project-trust-warning` | Non-persisted startup `Text` row | Unsupported boundary; remains visible. |
| `synthetic-user` | Firstmate extension `sendUserMessage`, terminal-injected input, Firstmate-generated Pi positional brief, or the already non-displayed session-start nudge | Canonically classified text-only operational user messages stay ordinary semantic user messages but render through the zero-height adapter (verified on Pi 0.81.1 through 0.84.1) under Calm; legacy entries stay gaplessly controllable, and the session-start nudge retains its existing non-displayed custom-message path. |
| `synthetic-assistant` | No authoritative Firstmate source found | Policy-hidden, but Pi exposes no generic assistant-role renderer. |
| `unknown` | Future or unclassified transcript component | Policy-hidden, but no generic renderer exists; never claimed as covered. |

The installed extension API has no supported global transcript filter, user-message renderer, assistant-message renderer, chat-container API, or generic custom-tool wrapper.
Pi 0.81.1 through 0.84.1 export `AssistantMessageComponent` and `InteractiveMode`, so Calm uses separate idempotent, API-probed adapters for assistant thinking layout, the complete operational-user transcript row, and the live-host capture the legacy synthetic entry renderer needs, while leaving all message data and non-Calm rendering unchanged; see the [compatibility contract](calm.md#pi-compatibility) for how a future Pi lacking one of those exports is handled.
General component replacement, ANSI cursor erasure, provider-context mutation, and installed-file patching remain rejected as unsupported or preservation-breaking workarounds.

## Cross-harness verification record

The original five-harness inspection was performed on 2026-07-22, with every integration surface rechecked and Pi reverified at 0.81.1 on 2026-07-23 for the latest Calm presentation change.

```text
$ claude --version
2.1.218 (Claude Code)
$ codex --version
codex-cli 0.144.6
$ opencode --version
1.17.18
$ pi --version
0.81.1
$ grok --version
grok 0.2.106 (bde89716f679)
```

| Harness | Conclusion | Evidence |
| --- | --- | --- |
| Claude Code 2.1.218 | Not feasible through the inspected supported project surface. | Project hooks can observe lifecycle and tool events, while the plugin CLI packages supported components; neither inspected surface exposes a transcript-row renderer or transcript-wide redraw API. |
| Codex CLI 0.144.6 | Not feasible through the inspected supported project surface. | The tracked hooks expose session, pre-tool, and stop handling, while the plugin and feature inventories expose no TUI tool-row renderer or transcript redraw control. |
| OpenCode 1.17.18 | Not feasible without violating the preservation boundary. | Plugins expose events and tool execution hooks, not a built-in transcript-row renderer; same-name tool replacement changes execution rather than presentation alone. |
| Pi (verified 0.81.1 through 0.84.1) | Partially feasible with three API-probed exported-class adapters. | Public APIs control working visibility, collapsed labels, known tool slots, custom entries, and expansion redraws; exported assistant and interactive-mode classes provide the collapsed-thinking layout, operational-user layout, and legacy synthetic entry host boundaries, gated on the exact method's presence rather than a version number, while generic user, tool, and status filtering remains unavailable. |
| Grok CLI 0.2.106 | Not feasible through the inspected supported project surface. | Project hooks expose lifecycle and tool interception, while the plugin CLI exposes no row-renderer contract; `--minimal` changes the whole screen mode rather than selected transcript rows. |

These conclusions are deliberately limited to the named versions and supported surfaces.
They do not claim that a harness can never add the missing renderer API.
For the duplicate-turn fix and the latest presentation change, the launch templates for Claude, Codex, OpenCode, Pi, and Grok and the watcher, turn-end, session-start, away-supervisor, and from-firstmate producers were re-inspected.
The canonical encoder and every non-Pi delivery path remain unchanged, and the tmux, Herdr, Zellij, Orca, and cmux runtime surfaces continue to transport the same input selected by the harness adapter.
Only Pi's Calm presentation implementation changed; every producer and non-Pi transport remains unchanged.

## Regression coverage

`tests/fm-calm-pi-extension.test.sh` compares wrapped and stock renderers, verifies all seven built-ins plus `fm_watch_arm_pi`, exercises redraw of already-rendered tool, thinking, current operational-user, and legacy synthetic rows, and covers every policy class.
It covers persisted preference restoration across every session-start reason and a real restart, proves the working-ship presentation and Calm-off stock `Working...` row through a delayed deterministic provider, asserts no Calm status row, verifies operational messages remain exact ordinary user-role session entries and complete exports, and drives genuine 100 by 44, 160 by 36, and 180 by 44 terminal fixtures.
A native deterministic `/skill:ahoy` turn produces thinking, tool-call, and tool-result blocks, asserts that the collapsed skill-to-final gap equals the two-row visible-only baseline, expands and re-collapses original thinking, restores Calm-off rendering, verifies persisted hidden history, and repeats the geometry assertion after restart with `terminal.clearOnShrink` explicitly off.
The operational provider path covers Calm loaded on, loaded off, default preference, extension absent, exact watcher delivery, narrow bare-marker legacy input, persisted restart replay, a genuine captain prompt, and adjacent notifications coalesced into one intended processing turn.
It asserts one persisted and rendered captain answer, exact user-role operational envelopes in order, no replacement custom messages, one processing result, zero operational transcript rows, and the two-row neighboring-assistant geometry for live, adjacent, and restart paths.
Quoted current markers, ASCII-only labels, ordinary text before a marker, unrelated U+2063 placement, and image-bearing input remain visible in component and native transcript checks.
`tests/fm-pi-primary-live-e2e.test.sh` also proves the working ship replaces the built-in `Working...` row while Calm is active on the credentialed provider path, and that it clears when the run settles, before continuing its ordinary watcher lifecycle.
`tests/fm-pi-primary-types.test.sh` performs strict no-emit TypeScript checking against the Pi declaration package named by `FM_PI_PACKAGE_DIR`, defaulting to the globally installed one, so each dated record below names the declaration version its own run covered rather than pinning one version here.
That check exits 0 with `skip: tsc not found for Pi extension typecheck` where TypeScript is absent, no `tsc` version is pinned anywhere in this repository, and `.github/workflows/ci.yml` installs Node without TypeScript, so a green suite is evidence of this check only when the environment that produced it had `tsc` installed.

CI does not exercise this suite.
CI run `31630144139` executed both Pi-dependent test scripts, but the Pi package was absent, so `tests/fm-pi-primary-types.test.sh` and `tests/fm-calm-pi-extension.test.sh` both exited successfully after skipping their Pi-dependent checks rather than running them.
Those are the only two suites in that run that skipped for a missing package: the log contains seven matching skip lines because the Calm suite reports the absent package from six separate subtests, while the typecheck reports it once.
The per-lane log summaries expose only aggregate `skipped_gate=1` counts, while the GitHub run summary names neither skipped suite and reports every job successful.
The strict typecheck and runtime guards therefore both skip silently in CI.
The evidence for this fix is local, dated, and reproducible by hand; it is not enforced anywhere.
A future Pi version bump will reintroduce this class of drift without any check failing.
Issue [#118](https://github.com/HelloWorldSungin/firstmate/issues/118) owns the question of whether CI can install and pin real Pi or needs another non-stub compatibility guard, and folds in TypeScript pinning plus strict-typecheck enforcement.

The relevant commands are:

```sh
tests/fm-calm-pi-extension.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
tests/fm-pi-primary-types.test.sh
```

## 2026-07-23 verification record

The deterministic provider preserves the complete real Pi TUI rendering path without using credentials.
The credentialed live regression remains opt-in and was not required because this change does not alter watcher delivery or provider integration.

```text
$ pi --version
0.81.1

$ tests/fm-calm-pi-extension.test.sh
ok - Pi calm extension is presentation-only with one persisted visibility choice, no Calm status row, native working visibility, supported redraw controls, and the Firstmate watcher-tool integration
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps native working visible, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi calm native E2E keeps Working and captain turns visible, hides exact operational user rows without changing persistence, restores them Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-test-run.sh --changed --base origin/main
FM_TEST_SUMMARY total=38 failed=0 skipped_gate=7 duration_ms=166881
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=192 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=31 duration_ms=165384 failed=0

$ tests/fm-pi-primary-live-e2e.test.sh
skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression
```

## 2026-07-26 Pi 0.82.0 compatibility verification

Pi 0.82.0 preserved both API-probed presentation seams and every deterministic Calm TUI guarantee.
The globally installed declaration package remained 0.81.1, so the strict typecheck continued to cover that earlier declaration-evidence version while the real CLI exercised 0.82.0.

```text
$ pi --version
0.82.0

$ tests/fm-calm-pi-extension.test.sh
ok - Pi calm extension is presentation-only with one persisted visibility choice, no Calm status row, native working visibility, supported redraw controls, and the Firstmate watcher-tool integration
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps native working visible, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi calm native E2E keeps Working and captain turns visible, hides exact operational user rows without changing persistence, restores them Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1
```

## 2026-07-30 Calm working-presentation verification (superseded)

This record captures the first working-presentation implementation and is retained as pipeline history.
Its same-orientation sail, theme-derived colors, and single-cadence motion were all replaced later the same day; the revision record at the end of this document owns current behavior.

The working ship was verified against the installed Pi 0.82.0 CLI with a deterministic in-process provider and no credentials.
The globally installed declaration package remained 0.81.1, so the strict typecheck continued to cover that declaration-evidence version while the real CLI exercised 0.82.0.
The real-TUI regression captures two frames at different hull columns, resizes the same running TUI, asserts the reflowed water row equals the new width on a single wave row, types into the editor while the animation runs, aborts with Escape, and then proves Pi's stock `Working...` row returns with Calm off.

```text
$ pi --version
0.82.0

$ tests/fm-calm-pi-extension.test.sh
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm compatibility evidence never rejects a Pi version for being newer than 0.82.0, and still fails closed on a missing or malformed version
ok - a missing collapsed-thinking presentation API degrades only that Calm adapter with a clear skip reason, while the rest of Calm still registers
ok - missing Pi presentation class exports reach the independent adapter degradation path
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps Pi's stock working row visible while no run is active, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi Calm working ship renders an exact two-row full-width sprite, clamps every resize, bounces at both edges, falls back deterministically when narrow, and installs and removes one timer-owning widget across starts, settle, abort, failure, shutdown, reload, replacement, and Calm toggles
ok - Pi calm native E2E replaces the stock working row with a moving, resize-clamped working ship that clears on abort, keeps captain turns visible, hides exact operational user rows without changing persistence, restores stock rendering Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=57 local_links=160

$ bin/fm-test-run.sh --changed --base origin/main
FM_TEST_SUMMARY total=32 failed=0 skipped_gate=7 duration_ms=196009
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=202 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=25 duration_ms=194670 failed=0
```

One rendered frame at 120 columns, with Pi's stock working row hidden and the boat directly above the editor:

```text
 |>
\__/~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

The same run after resizing that TUI to 64 columns, showing the waves refilled to the new width on one row with the boat still on screen:

```text
                         |>
~~~~~~~~~~~~~~~~~~~~~~~~\__/~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

Colors at that time were confirmed from an escape-preserving capture as theme-derived entries; the revision below replaced them with standard ANSI blue and yellow.
Pressing Escape during a run left `Operation aborted` with no boat and no residual blank row, and toggling Calm off restored Pi's stock `⠴ Working...` row on the next run.

## 2026-07-30 Calm working-presentation revision verification

The revision replaced the single-cadence, theme-colored, same-orientation sprite with a slower boat over independently animated water, standard ANSI colors, and a directional mainsail.
It was verified against the installed Pi 0.82.0 CLI with a deterministic in-process provider and no credentials.

```text
$ pi --version
0.82.0

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=57 local_links=163

$ bin/fm-test-run.sh --changed --base origin/main
FM_TEST_SUMMARY total=32 failed=0 skipped_gate=7 duration_ms=386738
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=257 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=25 duration_ms=383010 failed=0
```

Real Pi TUI observations from the isolated deterministic trial at 100 columns.
The hull column held steady across consecutive samples while the water pattern shifted, then advanced about one column every 880ms, which separates the two cadences:

```text
hull_col=12  water=~-~~~-~~~-~\__/~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~
hull_col=12  water=~~~-~~~-~~~\__/-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-
hull_col=13  water=~~-~~~-~~~-~\__/~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~
hull_col=16  (about 2.6s later)
```

An escape-preserving capture confirmed standard ANSI foreground codes only, blue water and yellow boat, with a default-foreground reset closing each run:

```text
^[[34m~~~-~~~-~~~-~~~^[[33m\__/^[[34m-~~~-~~~-~~~-~~~-...
^[[33m<|^[[39m
```

Resizing the same running TUI to 12 columns shortened the track enough to observe both reversals, each already showing the heading it was about to travel:

```text
left-heading :          |>  over  ~-~~~-~~\__/
right-heading:  <|          over  \__/~~-~~~-~
```

At 3 columns the sprite fell back to a single exact-width row, `<|~`.
Escape aborted the run leaving `Operation aborted`, no boat, and no stale sprite rows, and the trial exited 0 after deleting its temporary state.

## 2026-08-12 Pi 0.84.1 compatibility verification

### The deterministic base failure: Pi 0.84's Markdown-transformer argument

Initiating trigger: Pi 0.84 gave `UserMessageComponent` a 4th `markdownTransformers` constructor argument and made `InteractiveMode.addMessageToChat` feed every user row `this.getMarkdownTransformers()`.
Masking package version: Pi 0.83.0's `UserMessageComponent` constructor is `(text, markdownTheme = getMarkdownTheme(), outputPad = 1)` and its `interactive-mode.js` contains no occurrence of `getMarkdownTransformers` at all, so nothing asked a host object for that method until 0.84.
Changed emitted behavior: the real-component fixture in `tests/fm-calm-pi-extension.test.sh` drives `InteractiveMode.prototype.addMessageToChat` with a hand-built host object, and that object had no such method.
Visible symptom at base `b5cf66e`: `not ok - Pi calm renderer and lifecycle contract failed: TypeError: this.getMarkdownTransformers is not a function`, thrown on the first of the 50 ordinary replay rows.
Smallest outcome-flipping counterfactual, reduced to two calls against the installed 0.84.1 package:

```text
$ node -e '...InteractiveMode.prototype.addMessageToChat.call(hostWithoutTheMethod, userRow)...'
THROW: TypeError: this.getMarkdownTransformers is not a function
OK with getMarkdownTransformers
```

Disconfirming evidence checked and ruled out: this is not a redraw race.
The throw is synchronous, in-process, and has no tmux, timer, or terminal involvement; it reproduces on every run and on the first replay row rather than intermittently.

### PR 1271's three transient active-screen checks predate this work

kunchenguid/firstmate PR 1271's three transient active-screen checks were already present on this fork's base, added by commit `8a97167` ("Stabilize locale and Calm regression checks", 2026-07-29), long before this branch.
They are the three `! grep -Fq` guards - `Thinking...`, `fm_watch_arm_pi`, and `FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status` - inside the first `/calm` redraw wait loop of `test_interactive_terminal_e2e`.
Nothing in this change transplanted them, and they are not what fixed the failure above: they gate a terminal wait loop, while the deterministic 0.84.1 failure is a synchronous `TypeError` in a node fixture that never starts tmux.

Only two of the three still change the loop's outcome, and the record should not claim otherwise.
All three were distinct when `8a97167` added them - the loop's first condition was then `! grep -Fq "CALM_E2E_OUTPUT"` - but `71f0b3f` ("fix(pi): gate Calm built-in overrides by activation state", #1724) later replaced that first needle with `Thinking...`.
As the loop now stands its first condition and the guard `8a97167` added are byte-identical members of the same `&&` conjunction, so removing the added `Thinking...` line alone could not change when the loop breaks; only the `fm_watch_arm_pi` and `FIRSTMATE WATCHER WAKE: signal: /tmp/probe.status` guards independently keep it from sampling a half-redrawn transcript.
All three are preserved untouched anyway: the duplicate is harmless, and the two load-bearing guards still protect the live redraw race they were written for.

### Fix: forward Pi's Markdown transformers through the Calm adapter

The fixture now supplies `getMarkdownTransformers`, and - the part the fixture alone did not cover - `CalmOperationalUserMessageComponent` in `.pi/extensions/lib/fm-calm-operational-user-layout.ts` now forwards `this.getMarkdownTransformers?.()` into its `super(...)` call.
Without that forward the adapter substituted a row that silently dropped every transformer stock Pi applies (Pi's own mermaid transformer plus any a third-party Pi extension registered), which contradicts the adapter's promise to change only spacer-and-row presentation.
The optional call keeps Pi 0.83.0 rendering unchanged: that release has neither the host method nor the constructor argument, so the forward resolves to `undefined` and 0.83.0 renders exactly as before.

Getting the declaration-level contract to hold for both releases took a correction worth recording.
The first attempt implemented firstmate's instruction literally - pass the transformers straight through - by typing the new parameter as `ConstructorParameters<typeof UserMessageComponent>[3]` and calling `super(...)` with four arguments.
That reads Pi's own constructor tuple, which has three elements before 0.84, so it compiled only against 0.84.1.
The compatibility requirement made a real 0.83.0 typecheck mandatory, and that run caught it before it shipped, with `TS2493 ... has no element at index '3'` twice and `TS2554: Expected 1-3 arguments, but got 4`.
The adapter now describes both the transformer list and the stock constructor locally instead of indexing Pi's tuple, and re-types the stock class once so `super(...)` may carry the 4th argument.
That is one source with no version sniffing: 0.84 receives the forwarded transformers, 0.83 drops the extra argument the way JavaScript always has, and an `undefined` reaching 0.84 selects the same empty default a three-argument call would have.

The regression coverage is behavioral, not structural.
The fixture's host now returns a real marker transformer rather than an empty list, because a baseline built the same wrong way would drop transformers identically and the comparison would stay green.
The fixture first asks the installed Pi whether a stock `UserMessageComponent` honors the 4th argument at all - on 0.83.0 it does not and the guard stands down - and only then requires the substituted operational row to carry the same transformed text.
Re-introducing the drift by passing `undefined` as the 4th `super(...)` argument instead of the forwarded list fails the suite:

```text
$ tests/fm-calm-pi-extension.test.sh
not ok - Pi calm renderer and lifecycle contract failed: file:///tmp/fm-calm-pi-extension.KWUtm5/renderer/[eval1]:227
Error: Calm operational user rendering dropped Pi's Markdown transformers
```

### The second construction site: the legacy synthetic entry renderer

Forwarding the transformers through `CalmOperationalUserMessageComponent` alone left the same drop reachable one row over.
`registerFirstmateSyntheticPresentation` in `.pi/extensions/lib/fm-calm-visibility.ts` also builds a Pi user row - for the `firstmate-synthetic-input-presentation` entries Calm versions before 2026-07-23 persisted - and it built that row with two arguments.
The reachable path needs no new session: with Calm off `calmPresentationHides("synthetic-user")` is false, so any session still holding one of those legacy entries rendered it with `markdownTransformers` defaulting to `[]` and with `UserMessageComponent`'s own default `outputPad`, while every stock user row beside it in the same transcript got `[mermaid, ...extension transformers]` and the host's padding from `InteractiveMode`.

The two sites differ in what they can reach, which is why the first fix did not cover both.
The operational adapter runs inside an `InteractiveMode` method and reads those inputs off `this`.
An entry renderer is called as `(entry, options, theme)` and `EntryRenderOptions` declares only `expanded`, so it has no host to ask; `ExtensionAPI` exposes `registerMarkdownTransformer` but no matching getter, so the supported extension surface cannot answer the question either.

Exactly one Pi method mounts these entries, `InteractiveMode.addCustomEntryToChat`, and its body is byte-identical in 0.81.1, 0.83.0, and 0.84.1.
It constructs `CustomEntryComponent`, whose constructor runs the renderer synchronously inside that same frame.
Calm now installs a third API-probed adapter that records that method's receiver and calls straight through unchanged, and the renderer builds its row from the recorded host: `getMarkdownThemeWithSettings()`, `outputPad`, and `getMarkdownTransformers?.()`, each falling back to Pi's own constructor default when the host or that method is absent.
The recorded reference deliberately outlives the mounting frame, because the later expansion redraws re-run the renderer from `CustomEntryComponent.invalidate` with no `InteractiveMode` on the stack.
The captured host lives in a `Symbol.for` registry rather than in module scope, so a reloaded extension instance reads the same live host the already-installed patch records.
Like the other two adapters it degrades alone with a diagnostic if a future Pi drops the method, and on that path the row falls back to exactly the two-argument rendering it had before.

Both construction sites now build against one re-typed stock constructor owned by `fm-calm-visibility.ts`, so a future Pi constructor argument cannot be honored at one site and silently dropped at the other.

Finding the second site by following the first one is not evidence that there is no third, so every production construction of a Pi transcript component on this branch was enumerated and audited individually.
The sweep was repository-wide rather than adapter-by-adapter: the seven tracked files importing `@earendil-works/pi-*`, and every `new <Name>Component|Message|Entry|Markdown|Container|Box|Text|Spacer(` outside `tests/`.

| Production site | Component | Can it carry Markdown transformers? | Audit result |
| --- | --- | --- | --- |
| `lib/fm-calm-operational-user-layout.ts:147` | `CalmOperationalUserMessageComponent`, a `UserMessageComponent` subclass | Yes | Preserves the contract; forwards `this.getMarkdownTransformers?.()` off the patched `InteractiveMode`. |
| `lib/fm-calm-visibility.ts:192` | `UserMessageComponent`, re-typed as the stock constructor | Yes | Was dropping them; now forwards the captured host's theme, `outputPad`, and transformer list. |
| `lib/fm-calm-assistant-layout.ts:48` | `AssistantMessageComponent` | Not applicable | Patches `prototype.updateContent` and constructs nothing, so it supplies no constructor arguments; Pi keeps the transformer list it built the component with. |
| `fm-calm.ts:241`, `fm-calm.ts:264`, `fm-calm.ts:282`, `fm-calm.ts:291` | `Box`, `Container` | Not applicable | pi-tui layout primitives returned from built-in tool render slots; no Markdown pipeline and no text argument. |
| `fm-primary-pi-watch.ts:80`, `:562`, `:564`, `:567`, `:571`, `:577`, `:581`, `:582`, `:584` | `Box`, `Container`, `Text` | Not applicable | Same tool-slot shape for `fm_watch_arm_pi`; `Text` takes an already-styled string rather than Markdown. |
| `lib/fm-calm-working-ship.ts:222` | An object literal satisfying `Component & { dispose(): void }` | Not applicable | Imports only `type Component` and `type TUI` and constructs no Pi class; the boat's `render(width)` returns computed strings. |
| `fm-primary-turnend-guard.ts` | none | Not applicable | Imports only `type ExtensionAPI` and constructs no component. |
| `ToolExecutionComponent` | - | Yes, in Pi's hands | Never constructed in production. Pi owns every instance; Calm supplies only `renderCall` and `renderResult`. The only constructions are in `tests/fm-calm-pi-extension.test.sh`, which uses the real class to compare Calm's slots against a stock baseline. |
| `CustomEntryComponent` | - | Not applicable | Never constructed in production. Pi constructs it inside `addCustomEntryToChat`; Calm supplies only the renderer, which is the site fixed above. |

`registerEntryRenderer` appears exactly once in production, and `registerMessageRenderer` and `registerMarkdownTransformer` do not appear at all, so the legacy synthetic entry is the only Calm-owned custom row that builds its own component.

The regression coverage drives Pi's real `addCustomEntryToChat` rather than constructing `CustomEntryComponent` directly, which is what puts the host capture inside the assertion rather than beside it.
Both ways of losing the forward were reintroduced and run against the installed 0.84.1, and both fail the same guard:

```text
# renderer keeps the captured host but passes undefined as the 4th argument:
$ tests/fm-calm-pi-extension.test.sh
not ok - Pi calm renderer and lifecycle contract failed: file:///tmp/fm-calm-pi-extension.Y6LoKN/renderer/[eval1]:514
Error: Calm legacy synthetic presentation dropped Pi's Markdown transformers
# exit 1

# host-capture adapter never installed, so no host is ever recorded:
$ tests/fm-calm-pi-extension.test.sh
not ok - Pi calm renderer and lifecycle contract failed: file:///tmp/fm-calm-pi-extension.hUYdE4/renderer/[eval1]:514
Error: Calm legacy synthetic presentation dropped Pi's Markdown transformers
# exit 1
```

### The `/export` success row: Calm overwrites it, and this is not Pi drift

The earlier reading of this - that Pi "can complete `/export` without retaining the success status row long enough for the terminal capture" - was wrong, and the correction matters because it points at Calm rather than at Pi.
`showStatus` appends a `Spacer` plus a `Text` to `chatContainer` with no timer and no expiry, so the row is permanent; and `handleExportCommand` only calls it after `exportToHtml` has already returned.
The coalescing branch is the mechanism: when the last two chat children are still the spacer and text `showStatus` appended for the previous status, the next status **rewrites that text in place** instead of appending.
Calm's own post-export handler in `.pi/extensions/fm-calm.ts` restores Calm rendering on a `setTimeout(..., 0)` and forces every rendered row to rebuild with `setToolsExpanded(!expanded); setToolsExpanded(expanded)`, and each of those toggles ends in that same `showStatus`.
So Calm's `Tool output:` row lands on top of Pi's `Session exported to: <path>` and the confirmation never reaches a drawn frame.

Counterfactual, two otherwise identical Pi 0.84.1 tmux sessions differing only in whether `fm-calm.ts` is present:

```text
calm-loaded : html_written=yes status_row_seen=no  last_status_row=Tool output: collapsed
calm-absent : html_written=yes status_row_seen=yes last_status_row=Session exported to: /tmp/fm-export-probe.1YevZh/export.html
```

This is a Calm defect, not a Pi one, and it is older than Pi 0.84: the `showStatus` coalescing branch is byte-identical in 0.82.0, 0.83.0, and 0.84.1, and the toggle has been Calm's redraw mechanism since PR #895/#936.
Pi's extension API offers no render-invalidation call without a status side effect, so fixing it needs a deliberate change to Calm's export redraw (or a Pi API addition) rather than a test edit; that fix is not attempted here.
Until then the E2E records the behavior in both directions: it waits for the completed HTML document, fails if Pi's confirmation *does* appear (which would mean the clobber was fixed and this record is stale), and requires the editor to have cleared and Calm's redraw status row to be on screen.
The structural export check is unchanged and still fails on a missing or incomplete HTML document, missing rendered tool data, or missing synthetic provenance.

Tested scope, stated exactly: the counterfactual above compares Calm loaded and active against `fm-calm.ts` being absent, and the E2E assertion covers `/export` with Calm on.
Two adjacent paths are exercised in neither direction and are not claimed as covered.
The extension loaded with Calm off is one: the handler is registered in `session_start` with no Calm-state check and its body tests only the submit keybinding and the command text, so reading the code says the redraw and its clobber still happen, but no run pins that.
`/share` is the other: the same handler intercepts it, and Pi writes `Share URL: <url>` through `showStatus` only after the upload resolves, so that row plausibly lands after Calm's `setTimeout(..., 0)` toggle and survives - plausibly, because nothing here tests it.
Deciding whether the E2E should cover either path is deliberately left open rather than settled by this record.

### Evidence

Component fixtures resolve their Pi through `FM_PI_PACKAGE_DIR`, so the second command below exercises the Calm adapters against Pi 0.83.0's real rendering components; the tmux E2E always drives the installed `pi` binary, which was 0.84.1 for both runs.

```text
$ pi --version
0.84.1

$ tests/fm-calm-pi-extension.test.sh
$ FM_PI_PACKAGE_DIR=<pi-0.83.0-package> tests/fm-calm-pi-extension.test.sh

# both runs, identical output, exit 0:
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm compatibility evidence never rejects a Pi version for being newer than 0.82.0, and still fails closed on a missing or malformed version
ok - a missing collapsed-thinking presentation API degrades only that Calm adapter with a clear skip reason, while the rest of Calm still registers
ok - missing Pi presentation class exports reach the independent adapter degradation path
ok - Calm registers none of its 7 built-in tool wrappers at load while config/calm is off, and all 7 synchronously at load while config/calm is on
ok - Calm's first same-session /calm activation claims every uncontested built-in, leaves a foreign bash tool fully intact and callable, warns prominently and logs the contested name, and only rows constructed before that activation - the documented bound - fail to retroactively collapse
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps Pi's stock working row visible while no run is active, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi Calm working ship moves on a slow independent cadence over faster fixed-cell blue water, paints the complete boat standard yellow with balanced resets, keeps ANSI-stripped width exact, flips the directional sail on the exact bounce at both edges and every width, clamps visible and hidden resizes, falls back deterministically when narrow, freezes and resumes column/direction across settle/start without hidden-time jumps or duplicate timers, resets only on a fresh session, and installs and removes one scheduler-owning widget across starts, settle, abort, failure, shutdown, reload, replacement, and Calm toggles while leaving Calm-off visibility untouched
ok - Pi calm native E2E replaces the stock working row with a moving, resize-clamped working ship that freezes and resumes across two working periods in one Pi session, clears on abort, keeps captain turns visible, hides exact operational user rows without changing persistence, restores stock rendering Calm-off, survives restart, and preserves export plus Ctrl+O behavior
```

### Strict typecheck against the 0.84.1 and 0.83.0 declarations

Every earlier dated section above records `tests/fm-pi-primary-types.test.sh` against the 0.81.1 declaration package, which stayed globally installed through all of those runs.
This is the first section whose installed declarations are 0.84.1, and the first to run the check against two declaration packages, which is what the Pi 0.83.0 compatibility requirement needs.

```text
$ tsc --version
Version 5.9.3

$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.1
# exit 0

$ FM_PI_PACKAGE_DIR=<pi-0.83.0-package> tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.83.0
# exit 0
```

Both commands failed before this change, for two independent reasons, and only the second was this branch's own doing.
The 0.83.0-only constructor errors are described in the fix section above.
The other reason was `fm-calm.ts`, and it was neither Pi drift nor introduced here:

```text
# base b5cf66e, against the same installed 0.84.1 package and against 0.83.0 alike:
../../../../../../tmp/fm-pi-primary-types.tgJQhp/fm-calm.ts(402,57): error TS2345: Argument of type '(data: string) => void' is not assignable to parameter of type 'TerminalInputHandler'.
  Type 'void' is not assignable to type '{ consume?: boolean | undefined; data?: string | undefined; } | undefined'.
# exit 1
```

`TerminalInputHandler` is declared `(data: string) => { consume?: boolean; data?: string } | undefined` in Pi 0.81.1, 0.82.0, 0.83.0, and 0.84.1 alike - byte-identical in all four `dist/core/extensions/types.d.ts` - while Calm's submit handler returned nothing.
So the earlier `ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1` lines above are not reproducible today: replaying the 2026-07-23 record's own tree (`1c4d210`) against a freshly installed 0.81.1 package reports that same handler error now, alongside an unrelated `TS2322` in the same file.
Those dated records stand as written for what they claimed at the time; this is the first one whose typecheck transcript still reproduces on the tree it documents.

The repair here is a signature correction that preserves behavior exactly: the handler is annotated `(data): undefined`, which is what it already returned on every path.
Calm only observes the keystroke and never returns a `{ consume, data }` directive, so Pi's own input handling is untouched, and the annotation is erased at run time.

The gap was not visible earlier because nothing forced the check to run; see [Regression coverage](#regression-coverage) for that caveat, which still applies.
