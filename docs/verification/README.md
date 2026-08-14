# Dated verification records

This page is the owner of the append-only contract for dated entries under `docs/verification/`.

A dated entry is evidence.
It asserts that on that date, running the recorded commands produced exactly the recorded output.
Its value is that it was observed rather than reasoned about.

## Append-only

A dated entry is append-only.

When the verification can be re-run, supersede the stale entry with a new dated entry.
When it cannot be re-run, annotate the original with a dated note.
Never edit a dated observation in place.

Rewriting a transcript while keeping its original date makes a reconstruction indistinguishable from an observation.
There is then no marker, no diff, and nothing in the file that says it was rebuilt.
Inserting a line into recorded output that the recorded run could not have printed - a completion marker the suite gained afterwards, for instance - is the same failure, even when the line is accurate today.

## What this page does not own

What belongs in a verification record at all - active empirical facts rather than task chronology, and the date, version, commands, and output a record must carry - is owned by [`firstmate-coding-guidelines`](../../.agents/skills/firstmate-coding-guidelines/SKILL.md).
Audience classification is owned by [`../documentation-audiences.md`](../documentation-audiences.md).
