---
name: to-spec
description: Synthesize an established design conversation into an implementation-neutral specification.
user-invocable: false
metadata:
  internal: true
  source: https://github.com/mattpocock/skills
  license: MIT
  copyright: Copyright (c) 2026 Matt Pocock
---

# To Spec

Vendored and adapted from Matt Pocock's `to-spec` skill under the MIT license in `docs/licenses/mattpocock-skills-MIT.txt`.

Synthesize the current conversation and repository evidence.
Do not begin a new interview.
Respect existing domain vocabulary and ADRs.
Describe the highest useful behavioral test seams, preferring established seams and the smallest practical number.

Use these sections when they add value:

- Problem Statement
- Solution
- User Stories
- Implementation Decisions
- Testing Decisions
- Out of Scope
- Further Notes

Use implementation-neutral prose.
Avoid file paths and code snippets except for a small prototype-derived state machine, reducer, schema, or type shape that expresses a decision more precisely than prose.

Under Firstmate, write the specification only to the project path authorized by the brief.
Do not publish it to an issue tracker, create tickets, label work, invoke `to-tickets`, or invoke `implement`.
Firstmate's tasks-axi backlog and ship lifecycle are the single owners of decomposition and delivery.
