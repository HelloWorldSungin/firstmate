# One owner per fact

A fact has exactly one authoritative home.
Every other mention of it is a pointer to that home, never a second copy.

This repository already works that way in code, and says so where it does it.
[`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh) declares itself the one definition of a declared wait; supervision reads it directly, and [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) projects its *verdict* into the snapshot so the browser can act on it without holding a JavaScript copy of the vocabulary.
Carrying the verdict rather than the vocabulary across a boundary the consumer cannot cross is the whole idea.
This page extends it to prose.

## Why a copy goes stale even when everyone is careful

A change updates the files in its own blast radius.
A reader arrives by navigation: they open the vault page, the issue body, the call site.
Those two orderings are unrelated, so the copy that gets corrected and the copy that gets read are routinely different files.
Nothing about that is a lapse in care, which is why "remember to update the other place" does not fix it and a named convention plus a mechanical check does.

## The rule, in four parts

1. **A declared owner.**
   One file states the fact in full, and says it is the owner where both a reader and an editor will see it.
2. **Every other mention is a pointer.**
   A pointer may summarise in one clause so the sentence still reads, and it names the owner.
   It may not carry the detail: carried detail is exactly what drifts.
3. **A pointer points; it does not certify itself.**
   "and deliberately not restated here", "this is not a copy", "kept in sync with": a claim a pointer makes about its own compliance is unverifiable, ages independently of the clause it defends, and takes away the reader's only defence, which is judging the clause on sight.
   Name the owner and stop.
4. **Pointers are mechanically verified to resolve.**
   A pointer nobody can follow is worse than no pointer, because it reads as diligence.

## Pointers cross systems, so the check has to as well

The shapes that occur here, all of them real:

- Prose to prose in one repository, and code comment to the doc that owns the policy it executes.
  [`assets/dashboard/inbox.js`](../assets/dashboard/inbox.js) executes the inbox policy and points at [`docs/dashboard-inbox-policy.md`](dashboard-inbox-policy.md) rather than restating it.
- Repository to repository, including into a **private** repository, such as an operations vault page pointing at the design record that owns a decision.
- Prose to an issue-tracker body, where the owner is a sealed document and the epic body carries the pointer and a dated note rather than an independent statement.

Two checks divide that surface, one class each, and neither re-implements the other:

| Class | Owner | What it resolves |
| --- | --- | --- |
| In-repo pointers | [`bin/fm-doc-audience-check.sh`](../bin/fm-doc-audience-check.sh) | Local Markdown links and their anchors, plus the declared `requiredOwnerPointers` in [`documentation-audiences.json`](documentation-audiences.json), which is how a pointer living in a **code comment** gets pinned to its owner |
| Cross-system pointers | [`bin/fm-pointer-check.sh`](../bin/fm-pointer-check.sh) | Every `http(s)` pointer leaving the file's own repository, resolved against the target system |

Each script's header and `--help` own its exact flags and mechanics.
Run both after a documentation change:

```sh
bin/fm-doc-audience-check.sh
bin/fm-pointer-check.sh
```

## Broken and could-not-verify are different answers

A private repository answers an unauthenticated request with 404, exactly as a repository whose owner never existed does.
A checker with only two verdicts must therefore call one of those two cases wrong, and both mistakes are expensive: a correct pointer reported broken teaches contributors to ignore the check, and a broken pointer reported fine is the failure the check exists to catch.

So `bin/fm-pointer-check.sh` reports four outcomes, and an unauthenticated 404 is never read as either of the first two:

- `ok` resolved.
- `broken` provably does not resolve, and only failing evidence taken **with** a credential earns this.
  An owner account that does not exist is definitive, because account existence is public even when every repository under it is private.
  A path missing at a ref the credential has confirmed exists is definitive too, as is a missing issue in a repository it can see.
- `unverified` could not be resolved either way: no credential, a repository this credential cannot see, a throttled lookup, or a URL whose ref and path the API cannot separate.
  It never fails a run, and it is never counted as a pass.
- `skipped` no adapter claims the pointer: a host this check has no resolver for, a placeholder, a GitHub surface that is not a repository pointer.
  Never counted as verified, always in the counts, and listed with its reason under `--verbose` or `--json`.
  Vanishing from the count is the failure the check exists to prevent; the default output stays quiet about skipped pointers because a check nobody can stand to read gets ignored.

`--require-credential` turns a run that resolved nothing into an explicit refusal - no usable credential, or no pointer that reached a resolver at all - so an automated run cannot quietly report success having verified nothing, and cannot satisfy the flag by absence.
[`verification/pointer-check.md`](verification/pointer-check.md) records each of those outcomes observed against the real API, including the private repository and the nonexistent owner that an unauthenticated request cannot tell apart.

## What this convention does not do

**No check here proves that prose does not restate a fact it should have pointed at.**
Semantic duplicate detection is not attempted, and there is deliberately no registry of duplicated facts: such a registry would rot faster than the copies it tracks, and a stale registry is another owner to keep true.

What is enforced is narrower and worth stating plainly: the convention is written, known duplicates are converted, and pointers resolve mechanically.
An author restating instead of pointing remains a review concern.
It is a smaller one once there is a named convention to review against, but it is not solved, and this page should not be read as claiming otherwise.

## Propagating a correction into a system no check can reach

A check reports that a pointer resolves; it cannot notice that a landed change made some other page's prose false.
Where that risk is routine, the propagation belongs in the operating instructions rather than in a tool.
A home's private captain preferences may carry a pairing rule for its own domain, such as filing the documentation-vault update alongside the change that makes the vault stale.
Such a rule is this convention's propagation step for that domain, not a competing mechanism, and it stays where it is.

## Maintaining this page

This page is the owner of the one-owner convention.
[`CONTRIBUTING.md`](../CONTRIBUTING.md) and the agent-only [`firstmate-coding-guidelines`](../.agents/skills/firstmate-coding-guidelines/SKILL.md) skill point here and state how to apply it in their own contexts; neither restates the rule.
Keep mechanics in the checks' own headers and `--help` output rather than copying flags into this page.
