# Primary startup and hooks

Load this with the detected primary's tool reference before changing session startup, turn-end handling, pre-tool protection, watcher supervision, or secondmate integration.
The tool reference establishes either that identity's empirical path or its unsupported boundary.

## Turn end

`../../../docs/turnend-guard.md` owns the "no turn ends blind" contract, hook installation, per-surface blocking behavior, and tradeoffs when a hook cannot block.
`../../../docs/supervision-protocols/` and `../../../bin/fm-supervision-instructions.sh` own harness-specific wake protocols.
Never substitute another harness's wait shape.
`../../../bin/fm-busy-lib.sh` remains the semantic busy owner; a tool reference names only its source and evidence.

Validate any turn-end change against the real harness in a scratch project or throwaway home.
Update its executable or hook owner, concise tool fact, and `../../../docs/verification/supervision.md` under "Turn-end guard".

Where Firstmate installs a hook guarded, so that it exits silently and writes nothing unless its scoping conditions match the session that fired it, absence of effect proves nothing about invocation: no marker written is equally consistent with the guard declining and with the hook never running.
Prove invocation with an unguarded probe before concluding that the hook did not fire.

The same per-task hook files optionally carry the dashboard's agent-event reporting for `claude` and `opencode` when a home has instrumentation enabled.
Those entries are additive and always exit 0 silently off the critical path, so they cannot change any guard's decision, and they are absent entirely otherwise; `../../../docs/dashboard-events.md` owns that contract.
Preserve that property when editing the per-task wiring in `../../../bin/fm-spawn.sh`.

## Pre-tool protection

Supported primaries deny watcher-arm anti-patterns before execution, including shell `&`, truncating pipes, bundling, and broad `pkill -f fm-watch`.
`../../../docs/arm-pretool-check.md` owns hook commands, output quirks, and evidence.
The tool reference names the integration form.
Validate changes against the real harness in a scratch project before trusting them.

A primary must also account for built-in delegation that can create work outside Firstmate's durable records.
Claude's verified delegation guard is in `references/harness/claude.md`.
`../../../docs/subagent-guard.md` owns its full contract, local hardening, escape hatch, and per-harness applicability review.
Never generalize Claude tool names or permissions without live evidence.

## Session start

`../../../AGENTS.md` section 3 remains the behavioral owner.
`../../../docs/sessionstart-nudge.md` owns native tier assignment, transport, source routing, runtime bound, and fail-open behavior.
Read it before changing session-open behavior.
`../../../docs/verification/supervision.md` under "Native session-start delivery" owns active dated evidence.

## Watcher supervision

`../../../bin/fm-session-start.sh` prints exactly one block for the detected primary.
Follow only that rendered protocol.
When changing a watcher adapter, update its file under `../../../docs/supervision-protocols/`, update `../../../docs/turnend-guard.md` if shared idle or turn-end behavior changed, and refresh the tool fact.
An identity without a dedicated protocol uses its documented unsupported or unknown boundary; never invent one from a similar TUI.
