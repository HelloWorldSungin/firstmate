---
name: handoff
description: Compact a design session into a durable handoff document for a fresh crewmate context.
user-invocable: false
metadata:
  internal: true
  source: https://github.com/mattpocock/skills
  license: MIT
  copyright: Copyright (c) 2026 Matt Pocock
---

# Handoff

Vendored and adapted from Matt Pocock's `handoff` skill under the MIT license in `docs/licenses/mattpocock-skills-MIT.txt`.

Write a self-contained handoff so a fresh worker can continue without replaying the old conversation.
Use the durable handoff path named by the Firstmate design brief, not an operating-system temporary directory.

Include:

- the design question and current objective;
- decisions already resolved, with their evidence and stable keys;
- the open question, if any;
- investigated facts and rejected claims;
- ADR and glossary paths;
- prototype or other primary-source pointers;
- the next action;
- suggested vendored skills.

Reference existing ADRs, reports, commits, and diffs instead of duplicating them.
Redact secrets and personally identifiable information.
After writing the handoff, stop.
The supervisor owns relaunch and must not ask the same exhausted context to continue.
