---
name: batch-grill-me
description: Interview across every currently unblocked design-tree frontier in numbered rounds.
user-invocable: false
metadata:
  internal: true
  source: https://github.com/mattpocock/skills
  license: MIT
  copyright: Copyright (c) 2026 Matt Pocock
---

# Batch Grill Me

Vendored and adapted from Matt Pocock's `batch-grill-me` skill under the MIT license in `docs/licenses/mattpocock-skills-MIT.txt`.

Map the subject as a design tree.
In each round, ask every decision whose prerequisites are settled, number the questions, recommend an answer for each, and wait before recomputing the frontier.
Find environmental facts rather than asking for them.
The session ends only when every branch is settled.

This flow is intentionally unlocked for explicit uses outside the design crewmate profile.
Never invoke it inside a `kind=design` task because that profile requires exactly one question and one supervisor answer per turn.
