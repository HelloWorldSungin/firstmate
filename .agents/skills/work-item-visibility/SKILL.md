---
name: work-item-visibility
description: >-
  Agent-only procedure for keeping a work item's tracker and the captain's project board true while its task runs.
  Use at intake before scaffolding a PR-based ship or design brief that carries a work item, and at every milestone the lifecycle scripts do not post themselves.
user-invocable: false
metadata:
  internal: true
---

# work-item-visibility

A tracker that shows no movement while its work is under way, and one machine line when it lands, tells a reader nothing.
This skill is the single owner of what firstmate does about that.

Two surfaces, one vocabulary, one command.
`bin/fm-work-item-milestone.sh` records a milestone on both the work item's living status comment and the captain's project board, so the two can never disagree.
Script headers own exact flags and mechanics; read them rather than reproducing them here.

## At intake

A PR-based ship or design brief that carries a work item also needs its PR target.
Resolve the reference with `bin/fm-issue-ref.sh` as always, then pass `--pr-target <forge>:<host>/<path>` to `bin/fm-brief.sh` naming the repository this task's PR opens against.
`bin/fm-brief.sh` refuses `--work-item` without it, because that is the one input that decides whether the worker owes the issue a substantive delivery summary or only a link.
For a project whose tracker and code are the same repository, the PR target is that repository's own tracker identity, which is exactly what the registry already declares.

## While the work runs

Dispatch, PR opened, and landed post themselves from `bin/fm-spawn.sh`, `bin/fm-pr-check.sh`, and `bin/fm-pr-merge.sh`, so they never depend on anyone remembering.
Firstmate posts the rest, each with a note written for a human reading the issue:

- `queued` when the work item is accepted and waiting for a worker.
- `implemented` when the change is committed and validation is about to start.
- `validated` when validation finishes, with the outcome in the note.
- `blocked` when work stops on something outside the task, and `stopped` when it is abandoned or superseded.

Post a milestone when the state a reader would care about actually changed.
A repeated milestone refreshes the same entry rather than adding another, so a duplicate is harmless, but a milestone per wake is noise in a place that is supposed to be readable.

## Writing the note

The note is the only free text firstmate puts in front of a stranger, so write it as the project outcome: what is happening, what changed, and what it cost or caught.
The hand-posted comments on issues #9, #12, #13, and #16 of this repository are the depth to aim for - a reader who never opens the PR should still understand the work.

Never write a credential, an absolute path, a task id, a worktree, a runtime or harness name, a delivery mode, an autonomy posture, or any captain-private strategy into a note.
`bin/fm-issue-comment.sh` withholds a note carrying those and records the milestone without it, warning on stderr with the reason; treat that warning as a rewrite to do, not a retry, because the milestone already landed and only the sentence is missing.
The same separation `AGENTS.md` section 6 draws for a project's `AGENTS.md` applies: project-relevant outcome belongs in the tracker, fleet-private operational detail does not.

## The board

`config/project-board` names the captain's board and nothing happens without it.
Firstmate keeps that board true; it does not reshape it.
Never delete or rewrite the captain's views, filters, layouts, or fields, and never remove an item they added.
When reflecting reality would need a structural change - a status option that does not exist yet - `bin/fm-project-board.sh` reports it and leaves the board alone; raise it with the captain rather than adding it, and never add one by hand either.
Adding or changing an option on a single-select field replaces the field's whole option set and detaches every item using the old ids, which blanked all twenty statuses on this board the one time it was tried, so a missing option is the captain's to add deliberately with a snapshot taken first.

Epic-level reading comes from GitHub's own parent/sub-issue relationship: a story's parent is ensured on the board so native sub-issue progress rolls up without a firstmate-invented field.
Projects boards are GraphQL-only and `gh-axi` does not implement them, which is why that one path uses `gh api graphql` directly and needs the `project` token scope.

## When a surface is unreachable

Every failure here is decoration failing, never work failing.
An unreachable, unauthenticated, or rate-limited forge warns and the task proceeds untouched; that is the designed behavior and not something to retry into a blocker.
What it is never allowed to be is silent, so treat a warning as a real signal that the tracker or board is currently lying, and say so to the captain if it persists.
