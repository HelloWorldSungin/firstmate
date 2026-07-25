<!-- Adapted from Matt Pocock's domain-modeling skill. MIT License. Copyright (c) 2026 Matt Pocock. -->

# CONTEXT.md Format

Use a context title, one or two sentences describing the context, and a `## Language` section.
Define each domain term in one or two sentences and list discouraged synonyms under `_Avoid_:`.

Be opinionated, keep definitions tight, and include only concepts specific to the project domain.
Group terms only when natural clusters emerge.

When `CONTEXT-MAP.md` exists, follow its links and update the relevant bounded context.
Otherwise use a root `CONTEXT.md`, creating it only when the first domain term is resolved.
