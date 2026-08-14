---
name: sync-upstream
description: >-
  Check whether the firstmate fork is behind upstream, evaluate the next full-merge round, and dispatch that round as a reviewable fork PR.
  Use when the captain says "check upstream", "are we behind upstream", "sync firstmate with upstream", "bring firstmate up to date with upstream", or invokes /sync-upstream.
user-invocable: true
metadata:
  internal: true
---

# sync-upstream

This skill owns the standing upstream-sync round procedure.
[`bin/fm-upstream-status.sh`](../../../bin/fm-upstream-status.sh) is the only drift reader, and [`docs/fork-divergence.md`](../../../docs/fork-divergence.md) is the only ledger of deliberate fork differences.
The fork follows the TRACK strategy recorded in that ledger, so evaluation decides when to merge, where to split contiguous history into reviewable rounds, and what is likely to collide.
Evaluation never decides which isolated upstream changes to cherry-pick.

A plain status question such as "are we behind upstream" stops after the read-only evaluation unless the captain also asks to sync.
An explicit `/sync-upstream` or sync request is the on-request trigger and proceeds to dispatch even when the detector's ambient trigger has not crossed.
A bootstrap drift report whose summary says the standing trigger crossed also proceeds unless a stronger current captain instruction says not to.

## Measure once

Run:

```sh
bin/fm-upstream-status.sh --details
```

No output means the fork already contains upstream HEAD or has no `upstream` remote.
An `UPSTREAM: unable to measure` line is a blocker to report rather than a reason to guess from stale refs.
Treat the `UPSTREAM_TARGET` SHA as the measured ceiling for this invocation so upstream movement during planning cannot silently widen the round.
Do not run `git fetch upstream` in the primary copy and do not implement another count from GitHub compare data, local remote-tracking refs, or a forge CLI.

## Evaluate the round

Use the summary, grouped full-form references, and overlap paths from the detector to judge urgency, review size, and collision risk.
Consult the current `gh-axi --help` before inspecting an upstream PR, and pass `--repo kunchenguid/firstmate` on every upstream lookup because `gh-axi` otherwise resolves to upstream ambiguously.
Pass `--repo HelloWorldSungin/firstmate` on every fork issue or PR operation because issue and PR numbers share one number space across the two repositories.

Prefer one round when the pending contiguous range remains reviewable.
When the count or semantic overlap would concentrate too much risk in one review, split only at upstream first-parent boundaries and record exact endpoint SHAs for each round.
Each planned round takes one contiguous prefix after the prior round, and the final planned endpoint is the measured `UPSTREAM_TARGET`.
Never split by selecting wanted patches, never cherry-pick, and never dispatch a later round before its predecessor lands and advances the merge base.

Inspect every overlap involving `AGENTS.md`, `.agents/skills/`, `bin/`, or a capability independently implemented on both sides.
Use the remote-doctor retirement in the divergence ledger as the precedent for a capability collision under TRACK.
Record genuine contract contradictions for firstmate decision instead of resolving them during intake.

If the captain asked only for status, report the count, trigger verdict, likely collisions, and recommended round count now and stop.
Otherwise continue.

## Scaffold and dispatch

Create one ordinary ship task for the first round through the lifecycle in `AGENTS.md` section 7.
Use a task id and branch shaped as `fm-upstream-sync-<YYYY-MM-DD>` for one round or `fm-upstream-sync-<YYYY-MM-DD>-round-<N>` for a split plan.
Scaffold it explicitly as `direct-PR` with `bin/fm-brief.sh`, then replace the generated `{TASK}` placeholder with a rendered copy of [`sync-round-brief-template.md`](sync-round-brief-template.md).
Fill every placeholder from the detector output and the evaluation, including the exact round endpoint, fork base, merge base, round count, and overlap paths.
Do not hand-copy old private task instructions into the new brief.

Record later rounds as dependent queued work with their exact contiguous endpoint SHAs.
Resolve the current dispatch profile and approval posture normally, load `harness-adapters`, and spawn only the first unblocked round through `bin/fm-spawn.sh`.
The worker opens the PR against `HelloWorldSungin/firstmate` and stops.
The sync invocation never merges upstream in the primary copy and never merges the resulting PR.

## Review and landing boundary

A sync PR is expected to carry the red `PR must be raised via no-mistakes` check while that workflow still enforces the pipeline signature.
The round deliberately uses `direct-PR` because no-mistakes rebases onto `origin/main`, which would replay and linearize a merge-only branch.
Every other required check must pass, the PR must be mergeable, and the body must carry the applicability table and fork-survival evidence before it is reported ready.

Register the ready PR through the normal task lifecycle and stop for the configured merge authority.
When that authority later approves landing, the normal merge handler must use:

```sh
bin/fm-pr-merge.sh <task-id> <full-PR-url> -- --merge
```

The trailing `-- --merge` is mandatory because `bin/fm-pr-merge.sh` defaults to squash.
Squashing destroys the upstream merge parent, leaves the merge base behind, and makes every later round see the same upstream commits again.
Never use the GitHub Sync fork button, rebase, force-push, squash, or cherry-pick for a sync round.

Prefer fix-forward if a landed sync merge needs correction.
Reverting a sync merge with `git revert -m 1` marks its upstream commits as merged, so that revert must itself be reverted before a later sync can take those commits again.
After a round lands, refresh through the guarded fleet path, rerun the sole drift reader, and dispatch the next recorded contiguous round only when its dependency has cleared.
