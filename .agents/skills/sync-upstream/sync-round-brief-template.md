Merge upstream round {ROUND_NUMBER} of {ROUND_COUNT} into the firstmate fork as one reviewable merge PR on branch `{ROUND_BRANCH}`.
This round takes the contiguous upstream range ending at `{UPSTREAM_LABEL}@{UPSTREAM_TARGET}` from fork base `{FORK_BASE}` and measured merge base `{MERGE_BASE}`.

## Standing strategy and scope

Retain the generated Setup section's worktree-isolation assertion and stop before branching if this is the primary copy rather than the disposable task copy.
Read `docs/fork-divergence.md` before changing anything.
That ledger is the owner of the TRACK strategy, current deliberate divergences, parked branches, and the remote-doctor collision precedent.
Preserve every active divergence and exclude every parked branch listed there.
Do not merge, resurrect, rebase onto, or cherry-pick from a parked branch.

This round is a full merge of a contiguous upstream prefix.
Never cherry-pick a subset, rebase, force-push, squash, rewrite fork `main`, or use GitHub's Sync fork button.
The round contains exactly one upstream merge at the endpoint above, and no later upstream commit may enter it if upstream advances while the task runs.

The measured paths changed on both sides are:

{OVERLAP_PATHS}

Treat that list as collision risk, not proof that every listed path will conflict textually.
Inspect independently implemented capabilities even when Git reports no textual conflict.

## Baseline before merging

Fetch `origin` and `upstream` without changing either remote configuration.
Confirm the task branch starts at `{FORK_BASE}` and the exact upstream endpoint resolves to `{UPSTREAM_TARGET}`.
Stop if either identity differs from the instructions rather than silently widening or rebasing the round.

Establish the repository's full test and lint baseline on both parents before creating the merge commit.
Use isolated temporary copies for the parent baselines so the task branch and its merge structure stay untouched.
Record fork-parent failures and upstream-parent failures separately.
An unattributed final failure is a blocker, not something to fix quietly inside the sync.

## Merge and conflict policy

Create the upstream merge with:

```sh
git merge --no-ff {UPSTREAM_TARGET}
```

Resolve on meaning rather than by mechanically choosing ours or theirs.
Keep both intents when they are compatible.
For a genuine contradiction in `AGENTS.md` or `.agents/skills/`, report a decision to firstmate and stop rather than choosing a fleet contract yourself.
For two implementations of the same capability, use the remote-doctor retirement recorded in the divergence ledger as the TRACK precedent and escalate if applying it is not clear.

Run the complete test suite and `bin/fm-lint.sh` on the merge result.
Verify every deliberate divergence in the ledger still behaves, not merely that its files remain present.
Update the ledger in this PR when the round creates, changes, or retires a deliberate divergence.

## PR evidence

Open the PR against fork repository `HelloWorldSungin/firstmate`, base `main`.
Consult current `gh-axi --help` and pass `--repo HelloWorldSungin/firstmate` on every fork PR or issue command because `gh-axi` defaults elsewhere and bare numbers are ambiguous.
Use full `owner/repo#number` upstream references in the PR body, never a bare `#number`.

The PR body must include:

- An applicability row for every upstream first-parent change in this round, classified as taken cleanly, adapted with a reason, or conflicted with fork work and resolved with an explanation.
- The baseline-versus-final test and lint comparison.
- Survival evidence for every active deliberate divergence.
- Per-file reasoning for every changed contract file.
- A pointer to the ledger's parked-branch list and confirmation that none entered the round.
- Any ledger entry added, changed, or retired by the round.
- The exact pushed head SHA and an explicit mergeability check.
- The expected red-check explanation below.

## Delivery and landing warning

This round ships `direct-PR`, not through no-mistakes.
The no-mistakes pipeline rebases onto `origin/main`, which would replay and linearize the merge-only branch.
While the fork's compliance workflow still requires a no-mistakes signature, this direct PR carries the red `PR must be raised via no-mistakes` check by design.
Every other required check must pass.

Do not merge the PR.
Report its full URL and stop for the configured merge authority.
The landing handler must use `bin/fm-pr-merge.sh <task-id> <full-PR-url> -- --merge` because the script defaults to squash.
The explicit `--merge` is load-bearing: squashing loses upstream parentage, prevents the merge base from advancing, and makes future rounds re-present these same commits.
