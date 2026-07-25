---
name: ask-matt
description: Route a Firstmate design session to the appropriate vendored Matt Pocock design skill without creating a rival delivery system.
user-invocable: false
metadata:
  internal: true
  source: https://github.com/mattpocock/skills
  license: MIT
  copyright: Copyright (c) 2026 Matt Pocock
---

# Ask Matt

Vendored and adapted from Matt Pocock's `ask-matt` skill under the MIT license in `docs/licenses/mattpocock-skills-MIT.txt`.

Choose the smallest flow that answers the current design need.

## Firstmate design flow

1. Invoke `grilling` for an evidence-first, one-question-at-a-time interview.
2. Invoke `domain-modeling` when terminology, boundaries, scenarios, or the ADR need sharpening.
3. Invoke `to-questionnaire` when a named outside expert holds facts the supervisor cannot supply.
4. Request a prototype detour when a runnable answer is required.
   The supervisor launches a separate scout-shaped task using `prototype`; the design worker never prototypes on its ADR branch.
5. Invoke `to-spec` only when the requested design deliverable includes a separate specification.
6. Invoke `handoff` when firstmate calls a context handoff or the runtime ceiling fires.

`grill-me` is a convenience entry point for the same sequential interview.
`batch-grill-me` is unlocked but forbidden inside `kind=design`, whose contract requires exactly one question at a time.

## Context hygiene

Keep the active design phase in one unbroken context while it remains under firstmate supervision.
The worker reports context position and session depth at every supervisor-actionable question and completion event.
Firstmate judges the work produced and decides when to hand off.
The worker must not use its own feeling of staleness as a pacing decision.
The runtime hard ceiling is only a fail-closed backstop when live supervision misses the signal.

When firstmate requests a handoff, invoke `handoff`, stop, and let firstmate relaunch a fresh worker against that document.
Do not compact mid-phase.

## Deliberate exclusions

Do not invoke `grill-with-docs`.
Its useful behaviors are owned explicitly by this profile, and the marketplace copy is model-disabled.

Do not invoke or recreate `to-tickets` or `implement`.
Firstmate's tasks-axi backlog and ship lifecycle are the single owners of work decomposition and delivery.

Do not invoke `triage` from this profile.
It handles incoming external issues rather than interactive design.
