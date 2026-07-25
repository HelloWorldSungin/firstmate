---
name: design-profile
description: Agent-only supervisor contract for dispatching, pacing, answering, handing off, completing, and tearing down a kind=design crewmate or its prototype scout detour.
user-invocable: false
metadata:
  internal: true
---

# Design Profile

Use this skill before dispatching or supervising a `kind=design` crewmate, answering one of its questions, calling its context handoff, launching its prototype detour, treating its ADR as complete, or tearing it down.

`bin/fm-brief.sh --design` owns the worker-facing contract.
`bin/fm-spawn.sh --design` owns kind metadata, worktree isolation, skill mounting, verified harness admission, and context telemetry hooks.
This skill owns the supervisor decisions around those mechanics.

## Intake and dispatch

Use `design` when the requested product is an interactive decision process ending in an ADR.
Use `ship` when implementation is already authorized and unresolved design will not materially change what to build.
Use `scout` for knowledge-only investigation that does not require a sequential decision interview.

Load `harness-adapters`, apply the normal dispatch selector, and require a Claude profile.
The initial implementation admits only Claude because both model invocation and the transcript-backed context ceiling were empirically verified there.
Do not bypass a spawn refusal with a raw command or another harness.

Scaffold with `bin/fm-brief.sh <id> <repo> --design`, replace `{TASK}`, then spawn with `bin/fm-spawn.sh <id> <repo-path> --harness claude --design` plus the selected model and effort.
The project delivery mode controls the ADR branch exactly as it controls another tracked project document.
The design worker does not open a PR by itself under no-mistakes because no-mistakes owns that mode's review, fixes, push, PR, and CI.
Under direct-PR it opens the ADR PR, and under local-only it stops on a clean branch.

## Question authority

A design worker never addresses the captain.
It investigates facts, asks firstmate one question with one recommendation, appends a keyed `needs-decision` event, and stops.

The captain explicitly grants firstmate standing authority to answer an obvious design question on the captain's behalf.
An answer is obvious only when it follows directly from accepted task intent, repository evidence, an established project rule, or a decision already returned in the same session.
Return that answer promptly so the interview does not stall.
Record the source of the answer in the steer.

A genuine choice has viable alternatives whose product, engineering, security, destructive, irreversible, or externally visible tradeoff is not already settled.
Load `ask-user-authority` and escalate that choice under the configured authority.
Send the returned answer to the same worker with the stable question key.
Require the matching `resolved` event before treating later questions as current.
Never answer a question merely to preserve momentum.

## Live pacing and structural ceiling

Each supervisor-actionable question and completion event includes the worker's current context tokens, 110000-token hard limit, and main-chain turn count from `bin/fm-design-context.sh show <id>`.
Read that position against the quality, novelty, and coherence of the work actually produced.
Firstmate, not the worker, decides whether to continue or hand off.

Call a handoff when the interview is approaching the model's useful context zone, when the produced reasoning is losing coherence, or when the next design phase needs a clean window.
Do not wait for the hard ceiling.
Low remaining context in an ordinary task is not itself a wedge, but a design-profile handoff is an intentional pacing action and must be honored.

The runtime updates `state/<id>.design-context` on every Claude turn.
At 110000 tokens, or when telemetry becomes unavailable, it appends a keyed blocked event.
That event is a fail-closed ceiling, not evidence that work below it is automatically sound.

To hand off:

1. Steer the worker to invoke `handoff` and write `data/<id>/handoff.md`.
2. Require the handoff to reference the current ADR, resolved keys, evidence, open question, and prototype pointers.
3. After the worker stops, run `bin/fm-design-context.sh reset <id>` and use `stuck-crewmate-recovery` to preserve the same worktree and relaunch a fresh Claude context against the brief plus handoff.
4. Tell the fresh worker this is a resume on the existing branch, to skip initial branch creation, and to read the handoff before doing design work.
5. Clear context-ceiling and context-handoff blockers only after the fresh context is live, using matching `resolved` events.

Never compact the design worker mid-phase.
Never ask the worker whose context has hit the ceiling to make one more design decision.

## Prototype detour

A prototype is a scout-shaped variant, not a ship and not a fifth crewmate kind.
The design worker requests one exact runnable question and stops.
Firstmate scaffolds it with `bin/fm-brief.sh <scout-id> <repo> --prototype` and spawns it with `bin/fm-spawn.sh <scout-id> <repo-path> --harness claude --prototype`.
Those mechanics record `kind=scout` plus `profile=prototype`, mount only the invocable `prototype` skill, and refuse a backend that cannot preserve the local branch.
The prototype brief:

- names the one question and the design task that consumes the answer;
- requires a throwaway `prototype/<scout-id>` branch and scratch commit;
- forbids pushing, PR creation, default-branch landing, and production implementation;
- requires `data/<scout-id>/report.md` to record the question, verdict, branch, commit, run command, evidence, and context pointer.

The report is the durable result.
Normal teardown discards the worktree but preserves the local `prototype/<scout-id>` branch as the report's primary-source context pointer.
The branch is never pushed or merged and can be explicitly discarded later when no decision record refers to it.
Return the report pointer and verdict to the design worker.
The ADR records the decision and the report plus branch pointer, but no prototype code lands on its branch or on main.

This preserves the original prototype skill's explicit throwaway-branch rule while using Firstmate's existing scout lifecycle.

## Completion

The design worker invokes `decision-hold-lifecycle` before its ready or done event.
Every unresolved captain choice surfaced in the interview, ADR, glossary work, questionnaire, specification, or prototype report becomes a durable hold.
An explicit `--none` attestation is required when none remain.

Run `bin/fm-teardown.sh` only after the ADR has landed according to the project mode and the decision inventory verifies.
Teardown enforces the same decision gate for `kind=design` that it enforces for a scout.
Never use `--force` to bypass that gate without explicit captain discard authority.

## Vendored skill boundary

The mounted toolkit is adapted from the `mattpocock` marketplace plugin under the MIT license, Copyright (c) 2026 Matt Pocock.
The complete license is `docs/licenses/mattpocock-skills-MIT.txt`.

The integration was verified on 2026-07-24 against plugin version 1.2.0 and Claude Code 2.1.218.
The marketplace contained 41 skills, 24 with `disable-model-invocation: true`.
`grill-with-docs` was locked, while `grilling`, `domain-modeling`, and `prototype` carried no lock.
Live Claude `Skill` tool calls loaded the vendored `ask-matt`, `grilling`, and `domain-modeling` skills.
The spawn adapter admits no other harness until both model invocation and the context backstop have equivalent empirical evidence.

The design profile wires:

- `ask-matt`
- `grilling`
- `grill-me`
- `to-questionnaire`
- `handoff`
- `to-spec`
- `domain-modeling`

`batch-grill-me` is vendored and model-invocable but prohibited inside the sequential design profile.
`prototype` is vendored without a model-invocation lock and runs only in the separate scout detour.
`grill-with-docs`, `to-tickets`, `implement`, and `triage` are not mounted into this profile.
