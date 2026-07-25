---
name: domain-modeling
description: Sharpen project terminology and record hard-to-reverse design decisions as concise ADRs.
user-invocable: false
metadata:
  internal: true
  source: https://github.com/mattpocock/skills
  license: MIT
  copyright: Copyright (c) 2026 Matt Pocock
---

# Domain Modeling

Vendored and adapted from Matt Pocock's `domain-modeling` skill under the MIT license in `docs/licenses/mattpocock-skills-MIT.txt`.

Actively sharpen the project domain model while designing.
Challenge vague or overloaded terms, invent edge cases, compare claims to the code, and capture a resolved term when it crystallizes.

## File structure

Most repositories use a root `CONTEXT.md` and `docs/adr/`.
When `CONTEXT-MAP.md` exists, use it to locate bounded-context glossaries and context-specific ADR directories.
Create any glossary or ADR directory lazily.

## During the session

- Call out conflicts with established glossary language immediately.
- Propose a precise canonical term for fuzzy language.
- Stress-test relationships with concrete edge cases.
- Cross-reference claims against code and documentation.
- Keep `CONTEXT.md` implementation-free and glossary-only.
- Follow [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md) when a term truly needs recording.

Use an ADR only for a decision that is hard to reverse, surprising without context, and the result of a real tradeoff.
Follow [ADR-FORMAT.md](./ADR-FORMAT.md).
The enclosing Firstmate design brief requires one final ADR even when the ordinary skill would not offer an additional record.
