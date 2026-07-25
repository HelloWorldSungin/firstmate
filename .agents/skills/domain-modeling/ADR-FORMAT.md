<!-- Adapted from Matt Pocock's domain-modeling skill. MIT License. Copyright (c) 2026 Matt Pocock. -->

# ADR Format

Prefer the project convention when one exists.
Otherwise place ADRs in `docs/adr/` with sequential names such as `0001-slug.md`.
Create the directory lazily and increment the highest existing number.

An ADR may be only a title and a short paragraph stating the context, decision, and reason.
Add status, considered options, or consequences only when they carry information a future reader needs.

Good ADR subjects include architectural shape, integration boundaries, costly technology choices, non-obvious constraints, and deliberate deviations from the expected path.
Easy-to-reverse or obvious choices do not need separate ADRs.
