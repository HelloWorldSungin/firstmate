# Tracker write-back verification

Audience: maintainer verification.

This record supports the guarantees that cannot be proven against a fake GitHub, because they depend on what the real forge and the real client actually do:

1. One status comment per work item survives repeated milestones, because the marker lookup finds the comment a previous process created.
2. A story's parent issue is readable through GitHub's own GraphQL relationship, which is what lets epic progress roll up without a Firstmate-invented field.
3. The captain's board carries an option for every milestone this code maps, so the "no matching option" path is a real edge rather than the normal case.
4. The client surfaces this code depends on exist: `gh-axi` cannot edit a comment or reach Projects, and `gh api` can.

[`docs/configuration.md`](../configuration.md#project-issue-trackers) owns the operator-facing contract and the script headers own the mechanics.
`tests/fm-issue-writeback.test.sh` is the portable regression that pins idempotency, fail-open behavior, scope, and content discipline against a fake GitHub on every CI run; it needs no credential and contacts no host.
Task chronology and delivery evidence stay outside this record.

## Environment

Recorded 2026-08-04 on Linux 6.14.11-4-pve (x86_64) with GNU bash 5.3, gh 2.93.0, jq 1.8.1, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).
The authenticated account is `HelloWorldSungin`, whose token scopes are `admin:org`, `gist`, `notifications`, `project`, `repo`, and `workflow`.
The `project` scope is the one Projects v2 additionally requires; `repo` alone does not imply it.

## Client surfaces

`gh-axi issue --help` lists `list, view, create, edit, close, reopen, comment, delete, lock, unlock, pin, unpin, transfer, subissue`.
`comment` creates a comment and there is no subcommand that edits one, so an in-place update is only reachable through the REST `PATCH /repos/{owner}/{repo}/issues/comments/{id}`.
`gh-axi --help` lists the command surface `issue, pr, run, release, repo, label, secret, variable`, with no GraphQL entry point, so Projects v2 is unreachable through it at all.
Both paths therefore use `gh api` directly, which is the same exception `bin/fm-pr-check.sh` already makes for structured PR reads.

## One living comment

Two consecutive milestone runs against `https://github.com/HelloWorldSungin/firstmate/issues/36`, the second in a fresh process:

```
$ bin/fm-work-item-milestone.sh wb-live --milestone implemented --note-file <note>
created: https://github.com/HelloWorldSungin/firstmate/issues/36
board: https://github.com/users/HelloWorldSungin/projects/4 tracks https://github.com/HelloWorldSungin/firstmate/issues/36

$ bin/fm-work-item-milestone.sh wb-live --milestone implemented --note-file <note>
updated: https://github.com/HelloWorldSungin/firstmate/issues/36
board: https://github.com/users/HelloWorldSungin/projects/4 tracks https://github.com/HelloWorldSungin/firstmate/issues/36
```

The second run reported `updated`, not `created`, which is the marker lookup finding a comment no process memory carried.
The resulting comment count for that marker:

```
$ gh api --paginate repos/HelloWorldSungin/firstmate/issues/36/comments \
    --jq '[.[] | select(.body | contains("firstmate-status-comment"))] | length'
1
```

## The parent relationship

`Issue.parent` is a real field on the current GraphQL schema, so the epic a story belongs to is discoverable without a parallel scheme:

```
$ gh api graphql -f query='query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ issue(number:$number){ parent { number repository { name owner { login } } } } } }' \
    -f owner=HelloWorldSungin -f name=firstmate -F number=16 \
    --jq '.data.repository.issue.parent | "\(.repository.owner.login) \(.repository.name) \(.number)"'
HelloWorldSungin firstmate 4
```

Issue #16 is a story of epic #4, which is what the board needs to show epic-level progress through GitHub's native sub-issue rollup.

## The board and the milestone mapping

```
$ bin/fm-project-board.sh show
board: https://github.com/users/HelloWorldSungin/projects/4
title: Ark Firstmate project
status option: Backlog
status option: Ready
status option: In progress
status option: In review
status option: Done
```

Every milestone `bin/fm-project-board.sh` maps resolves against those options: `queued` to Backlog, `dispatched`/`implemented`/`validated`/`blocked` to In progress, `in-review` to In review, and `landed` to Done.
No milestone in the vocabulary needs an option this board does not already have, so no additive structural change is required to keep it true.

After the two runs above, that board holds exactly one card for the issue, at the status the milestone maps to:

```
$ gh api graphql -f query='...projectV2(number:4){ items(first:60){ nodes{ content{ ... on Issue { number } } fieldValues(first:20){ ... } } } }'
cards_for_36=1
status=In progress
```

`addProjectV2ItemById` answered the second run with the same item rather than adding a second card, which is the API-level property this code relies on for membership idempotency.

## What this record does not cover

Write-back to a tracker that is not the repository the pull request opens against is out of scope by design and has no credential path to verify.
Epic *status* rollup is deliberately not computed: only membership of the parent is ensured, and progress is read from GitHub's own sub-issue display.
