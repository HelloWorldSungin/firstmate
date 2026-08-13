---
name: design-profile
description: Agent-only supervisor contract for dispatching and supervising an interactive design task whose tracked deliverable is an ADR. Load before scaffolding, dispatching, answering, completing, or cleaning up a kind=design task.
user-invocable: false
metadata:
  internal: true
---

# Design Profile

Use this profile when the requested product is an interactive decision process ending in an architectural decision record.
Use a ship when implementation is already authorized and remaining design uncertainty cannot materially change what to build.
Use a scout when the result is knowledge or a recommendation rather than a tracked ADR.

`bin/fm-brief.sh --design` owns the worker-facing interview and ADR contract.
`bin/fm-spawn.sh --design` owns task-kind metadata, delivery posture, branch identity, and verified harness launch.
This skill owns the supervisor decisions around those mechanics.

## Dependency boundary

The profile uses the installed `mattpocock-skills@mattpocock` plugin's `grilling` and `domain-modeling` skills.
`bin/fm-design-skills.sh` is the single owner of resolving those capabilities from Claude's installed-plugin registry.
It only reads the registry and skill files.
It never installs, updates, copies, vendors, pins, or modifies the plugin.
Only the captain upgrades that dependency through their own `/plugin` action.

Run `bin/fm-design-skills.sh check` before scaffolding.
If it refuses because the install or either required skill is absent, stop and ask the captain to refresh the plugin.
Never substitute copied skill text or run an installer from a worker.

The worker brief tells every harness to read the resolved skill files directly.
This avoids depending on harness-specific command spelling while preserving one exact installed dependency for Claude, Codex, and Pi.
Those dependencies supply modeling and interrogation capabilities only.
The profile's ADR-only contract takes precedence over any dependency direction to create or update `CONTEXT.md`.
Every resolved term is recorded only in the ADR, which remains the sole tracked project deliverable.

## Dispatch

Resolve the delivery mode and yolo posture exactly as for a ship because the ADR is a tracked project change.
Consult `config/crew-dispatch.json` at intake and pass the selected concrete harness, model, and effort axes to `fm-spawn.sh`.
The copyable design rule in `docs/examples/crew-dispatch.json` offers Claude, Codex, and Pi at `xhigh`, which all three current launch adapters support.
Do not hardcode one harness in the profile.
Do not infer or pin a model because each harness's current authenticated catalog owns model availability.

Scaffold with `bin/fm-brief.sh <id> <repo> --design --mode <mode>` plus any applicable work-item and Herdr flags.
Spawn with `bin/fm-spawn.sh <id> <repo-path> --design --mode <mode> --yolo <on|off> --harness <harness>` plus the selected model and effort when present.

## Interview authority

The design worker investigates factual questions from repository evidence and asks one decision question at a time.
Every question carries a stable key, evidence, and a recommended answer.
The worker stops until firstmate returns an answer with the same key.

Load `ask-user-authority` before answering any design question.
An answer that follows directly from accepted intent, repository evidence, an established rule, or a decision already returned in the same session is a correction within accepted intent.
A genuine product, engineering, security, destructive, irreversible, or externally visible choice goes to the captain unless current authority explicitly covers it.
Never answer merely to preserve momentum.

Require a matching `resolved` event before treating a later question as current.
When the interview has converged, require the worker to state the resulting decision back before drafting the ADR.

## ADR completion

Use an existing project ADR convention when one exists.
Otherwise the worker uses `docs/adr/NNNN-<slug>.md`, incrementing the highest existing number.
The ADR must stand alone with context, decision, rationale, relevant alternatives, and non-obvious consequences.
The task changes no product code, creates no `CONTEXT.md`, and does not implement the selected design.

Before the ADR is ready, load `decision-hold-lifecycle` and inventory every unresolved captain choice surfaced by the interview or ADR.
The task follows its selected delivery path exactly like another tracked documentation change.
Under no-mistakes, the same worker validates and ships the ADR through the pipeline.
Under direct-PR, the worker opens the ADR PR directly.
Under local-only, the worker stops on a clean ready branch.

Clean up only after the ADR has landed and the decision inventory verifies.
`fm-teardown.sh` enforces the decision inventory for `kind=design` in addition to the normal landed-work checks.
