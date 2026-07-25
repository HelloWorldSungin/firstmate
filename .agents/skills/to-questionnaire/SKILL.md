---
name: to-questionnaire
description: Turn knowledge a decision-maker lacks into a focused Markdown questionnaire for the person who holds it.
user-invocable: false
metadata:
  internal: true
  source: https://github.com/mattpocock/skills
  license: MIT
  copyright: Copyright (c) 2026 Matt Pocock
---

# To Questionnaire

Vendored and adapted from Matt Pocock's `to-questionnaire` skill under the MIT license in `docs/licenses/mattpocock-skills-MIT.txt`.

Grill the send, not the subject.
First identify the recipient's role, expertise, and relationship to the decision-maker.
Then identify the exact facts or decisions that person must provide.

Write `to-questionnaire-<slug>.md` at the project-appropriate documentation path.
Include purpose, sender and recipient, how answers will be used, brief context, answering instructions, most-important-first themed questions, answer stubs, and a final catch-all.
Each question covers one idea.
Add a short reason only where a question may be misunderstood.

The Firstmate design profile still routes any question to firstmate one at a time.
Do not contact an external recipient or publish the questionnaire without separately established authority.
