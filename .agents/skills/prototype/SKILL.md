---
name: prototype
description: Build throwaway code on a scratch branch to answer one logic, state-model, or UI design question.
user-invocable: false
metadata:
  internal: true
  source: https://github.com/mattpocock/skills
  license: MIT
  copyright: Copyright (c) 2026 Matt Pocock
---

# Prototype

Vendored from Matt Pocock's `prototype` skill under the MIT license in `docs/licenses/mattpocock-skills-MIT.txt`.

A prototype is **throwaway code that answers a question**.
The question decides the shape.

## Pick a branch

- For "Does this logic or state model feel right?", follow [LOGIC.md](LOGIC.md).
- For "What should this look like?", follow [UI.md](UI.md).

If the question is ambiguous and the supervisor cannot resolve it, use the shape that best matches the surrounding code and record the assumption at the top of the prototype.

## Rules that apply to both

1. Mark it as throwaway from day one and place it close to the real code whose context it needs.
2. Provide one command to run through the project's existing task runner.
3. Keep state in memory unless persistence is the exact question.
4. Skip polish, tests, generalization, and production-grade error handling.
5. Surface the full relevant state after every action or variant switch.
6. Commit the prototype to a throwaway scratch branch that must never land on the default branch.
7. Record the question, verdict, commit, branch, run command, and relevant context pointer in the scout report.

The Firstmate design profile deliberately runs this skill only through the separate `--prototype` variant, which records `kind=scout` plus `profile=prototype`.
The ADR branch receives the validated answer and a useful primary-source pointer, never the prototype code.
