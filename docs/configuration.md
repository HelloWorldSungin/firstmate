# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `FM_HOME` contains private operational directories.
`data/` holds durable private fleet records such as the project and secondmate registries, captain preferences, optional shared captain preferences, learnings, backlog, briefs, scout reports, per-task completion manifests, per-task work-item references, and the token-usage store described in [usage-accounting.md](usage-accounting.md).
[`fleet-data-contracts.md`](fleet-data-contracts.md) owns the durable manifest, work-item, and normalized PR-observation contracts and the field ownership across their producers and consumers.
`state/` holds runtime records such as task metadata, append-only status events, endpoint signals, watcher and wake-queue coordination, inactive terminal-outcome receipts under `state/terminal-outcomes/`, away-mode state, generated Relay artifacts, private secondmate config-reread generations with their retry and quarantine state, and parent-owned secondmate pending-reply records under `state/pending-replies/` (`bin/fm-pending-reply-lib.sh`).
`config/` holds local gitignored operating choices, and `projects/` holds the local project clones that Firstmate reads but changes only through the narrow guarded and concrete captain-approved exceptions in `AGENTS.md`.
The firstmate repository's home-root clone uses the canonical registry name `firstmate`, and `bin/fm-brief-repo-lib.sh` offers the home root as its resolution candidate when `FM_HOME` and `FM_ROOT` share the same git object database.
That structural comparison is the sole authority, so registry prose does not control detection and a path matching the home root resolves to the `firstmate` registry entry without a new registry field.
A `.fm-secondmate-home` marker can also open the home-root candidate for secondmate fallback resolution, but it never replaces the final object-database comparison.

`bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.
The producing PR and Relay helpers own the fields they append, `bin/fm-classify-lib.sh` owns status-event vocabulary, and `bin/fm-crew-state.sh` owns current-state reconciliation.
Wake, watcher, away-mode, and Relay-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

`bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`bin/fm-startup-network.sh`'s header owns the deferred network stage that keeps every external-network call off that digest's blocking path, including its state files and the safety argument for running them later.
`docs/sessionstart-nudge.md` owns the native session-open adapter tiers that run or nudge the digest command, and the source routing between them.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.
Ordinary dead-direct-report recovery is owned by `stuck-crewmate-recovery`, while persistent-secondmate recovery is owned by `secondmate-provisioning`.

## Project issue trackers

A task's work item almost always lives in the managed project's own tracker rather than in the Firstmate repository, and Firstmate manages projects across several forges and hosts.
A bare `#42` is therefore meaningless without a project, and the tracker is never implied by a git remote: a project may be mirrored on one host while its issues are tracked on another, so the declaration below is the only authority.

Each newly registered project must carry one explicit `tracker=` declaration inside the existing bracket annotation in `data/projects.md`; legacy entries may still omit it and remain undeclared:

```
- <name> [<mode> +yolo tracker=<forge>:<host>/<path>] - <desc> (added <date>)
- <name> [<mode> tracker=none] - <desc> (added <date>)
```

`<forge>` is `github`, `gitlab`, or `gitea`; `<host>` is the tracker's DNS host; `<path>` is `owner/repository` on GitHub and Gitea, and the full nested namespace on GitLab.
`tracker=none` declares that a project has no tracker, which is distinct from an absent token meaning undeclared; both refuse to resolve a bare reference, with different reasons.
The token rides inside the delivery-posture annotation that `bin/fm-project-mode.sh` already parses, so adding it never changes a project's registered mode or yolo posture.

`bin/fm-issue-lib.sh` is the single owner of this declaration and of the reference forms resolved against it: a full canonical issue URL, a `<forge>:<url>` prefixed URL for the self-hosted shape several forges share, `<owner>/<repo>#<n>`, and a bare `#<n>` or `<n>`.
Firstmate resolves references once at intake with `bin/fm-issue-ref.sh`, exactly as it resolves delivery mode and yolo, and passes the resolved result explicitly onward.
`bin/fm-brief.sh --work-item` accepts only a fully qualified reference and reads no tracker declaration from the registry.
`bin/fm-spawn.sh` records those resolved markers as they stand and consults the registry only to upgrade a legacy bare `issue=` number through the project's declared tracker, reporting rather than guessing when that project declares none.
A task may carry several references or none, and one unresolvable reference refuses the whole set rather than recording a partial one.
Resolved references are recorded as `work_item=<origin>|<forge>|<url>` lines in task metadata, and `bin/fm-issue-ref.sh --format json` emits the reference-object array in the shape defined by issue #18's outcome-manifest contract.
`bin/fm-pr-merge.sh` closes a recorded work item when its forge has a write adapter - a `github.com` issue through the ambient `gh-axi` authentication, or a Gitea issue on any host through that host's `config/forge-tokens/<host>` credential - and always in the repository that record names; only the legacy bare `issue=` number falls back to the repository the pull request landed in, which is all a bare number can mean.
A work item on a forge or host with no write adapter, or one whose credential is absent, loose, or refused, is reported with that distinct reason rather than being retargeted at `github.com`: the merge still succeeds and the link stays recorded and resolvable, but the close is left to whoever owns that host.

Firstmate also writes back, so a tracker shows where its work stands without anyone opening the pull request.
`bin/fm-work-item-milestone.sh` records one lifecycle milestone - `queued`, `dispatched`, `implemented`, `validated`, `in-review`, `landed`, `blocked`, or `stopped` - on every surface Firstmate keeps true, so those surfaces cannot drift into different opinions about the same task.
`bin/fm-milestone-lib.sh` owns that vocabulary, so a token one surface knows is a token every surface knows.
`bin/fm-spawn.sh`, `bin/fm-pr-check.sh`, and `bin/fm-pr-merge.sh` post `dispatched`, `in-review`, and `landed` themselves, each after the line that reports its own success; Firstmate posts the rest with a note written for a human reading the issue.
The whole fan-out is bounded as one operation by `FM_WORK_ITEM_MILESTONE_TIMEOUT` seconds (default 40), of which the comment surface may spend at most half and the board gets the rest, because per-call bounds alone would add up to minutes on a black-holing network.
Every argument is validated before either surface runs, so a caller's mistake is one usage error with nothing written, and after that neither surface's failure can stop or fail the other.

`bin/fm-issue-comment.sh` owns the tracker comment: ONE living status comment per work item, created once and thereafter edited in place, located idempotently by a Firstmate-owned marker in its body so a restart, a partial failure, or a repeated milestone all correct the same comment rather than adding another.
It carries the current status, the note, the pull request when one is recorded, and a short dated timeline of the milestones so far.
The task's worker owns exactly one separate comment, its substantive delivery summary, which `bin/fm-brief.sh` requires of it before the PR is ready.
Write-back targets only the task's own recorded work item - exactly one `work_item=` line, in the repository the PR opens against, which `bin/fm-brief.sh --pr-target` records as `pr_target=` in task metadata - never a reference parsed from prose, a PR body, or a git remote.
Within that scope it is per-forge: `github.com` writes ride the ambient `gh` authentication, and Gitea on any host writes with the same `config/forge-tokens/<host>` credential the read side uses, while GitLab and self-hosted GitHub have no write adapter yet and say so honestly.
`bin/fm-forge-lib.sh` is the single owner of the credential rules, the argv-free transport, the complete write-operation allowlist (the status comment, the linking close comment, and the close itself - never any branch, release, settings, permission, or repository mutation), and the minimum viable token scope per forge, so a narrow credential is sufficient by construction and a wide one gains no extra reach.
That allowlist is structural rather than advisory: the transport and the request builder are private to that library, so no caller is offered a way to name a method, URL, or body of its own, and its exported surface is pinned by a test that fails if a general transport reappears.
Every skipped write states which distinct fact applies: no credential on disk, a credential file present but empty, a credential present but the forge unsupported, or a credential the forge refused for permissions.
The note is withheld when it carries a Firstmate marker, a credential, an absolute filesystem path, or a value the task's own record marks as private, because a leak cannot be undone and a marker in a note could forge entries into the machine-owned timeline.
Withholding is not losing: the milestone still lands without the note and one warning on stderr says what was withheld and why, so a false positive costs a sentence rather than the whole update.
An absolute path is recognised by the roots a filesystem path actually starts at, so a project's own route such as `/api/v2/reports`, and a Markdown link whose target starts at the site root, read as the project prose they are.
Each call is bounded by `FM_ISSUE_COMMENT_TIMEOUT` seconds (default 10), and the marker lookup asks for 100 comments per page on GitHub and 50 on Gitea so a busy issue does not spend that bound on round trips.
A page shorter than the one it asked for never ends that lookup, because a forge is free to clamp a list to its own maximum, and a walk that stopped there would miss the living comment and post a second one.
A comment is created only where the lookup proved there is none to edit; wherever it could not prove that - the page cap ran out, the host re-served a page the walk had already seen, a page carried no readable comment id, or the comment was found under an id that cannot be addressed - nothing is written and the uncertainty is reported, because guessing in the create direction is what accumulates a comment per milestone.
`bin/fm-pr-merge.sh` bounds each of its own per-host verify and close calls by `FM_ISSUE_CLOSE_TIMEOUT` seconds (default 10).

Firstmate also keeps the captain's GitHub Projects boards true, and two different facts name a board, each with one owner.
A project declares its own board with a `board=` token beside `tracker=` in the same bracket annotation, and `config/project-board` is this home's fallback for a project that declares nothing:

```
- <name> [<mode> +yolo tracker=<forge>:<host>/<path> board=https://github.com/orgs/<org>/projects/<n>] - <desc> (added <date>)
- <name> [<mode> tracker=<forge>:<host>/<path> board=none] - <desc> (added <date>)
```

The board URL is `https://github.com/orgs/<org>/projects/<n>` or `https://github.com/users/<login>/projects/<n>`, and `config/project-board` holds one such line and nothing else.
`board=none` declares that a project has no board, which is distinct from an absent token meaning undeclared: the first skips even where a home fallback exists, and the second falls back to it.
`bin/fm-board-lib.sh` is the single owner of board identity, of that resolution rule, and of every request Firstmate can send to a board; a home with neither declaration nor fallback does nothing and contacts no host.
A home with no board anywhere is answered before any target is looked at, so `sync` there prints nothing and exits 0 whatever it was handed.

`bin/fm-project-board.sh sync` is the lifecycle update for a task Firstmate is running.
It resolves the board from the issue's own tracker through the registry and falls back to the home board, adds board membership for the tracked work item, drives the board's existing Status field from the same milestones, and ensures a story's parent issue is a member too so epic progress reads through GitHub's own sub-issue relationship rather than a Firstmate-invented field.
Each call is bounded by `FM_PROJECT_BOARD_TIMEOUT` seconds (default 15).

`bin/fm-project-board.sh reconcile` is the fleet-wide drift sweep, and it is the one that catches work Firstmate never dispatched: on 2026-08-04 the Ark-Signal board carried 222 items that no lifecycle update could ever have corrected, three of which had drifted.
It uses DECLARED boards only and never the home fallback, so a sweep can only reach a board somebody named for that project by hand.
Because it never reads that fallback, a malformed `config/project-board` does not stop it either: only `sync` and `show` resolve the fallback, and only they report it and stop.
For each such project every tracker issue is made a board member, a closed issue is moved to `Done`, and an open issue is moved out of `Done`; nothing finer is invented, because closed-versus-open is the only truth available for work Firstmate did not dispatch.
Membership is reconciled against a real issue listing rather than a repository's REST `open_issues_count`, which includes pull requests and once had Firstmate reporting a missing item on a board that was already complete at 76 of 76.
An item no tracker issue matches is left exactly where it is, because a card a human added by hand is not drift.
The repository identity the two sides are matched on is normalized once per side rather than compared byte-exactly, because the board's own reference always carries GitHub's canonical casing while the registry carries whatever was typed, and GitHub resolves an owner/repo pair case-insensitively.
One function in `bin/fm-board-lib.sh` owns that normalization, and both this join and the tracker lookup `sync` resolves its board through build their key with it, so a project's declared board cannot be lost on one path while the other matches.
A listing reports whether it is complete rather than having that inferred from its shape, and a sweep that saw only part of a board or of a tracker plans no changes at all for that project and says so: an issue is missing from a board only if it is on no page of it, so a partial view cannot tell a missing item from an unread one.
The sweep is bounded as a whole operation by `FM_BOARD_SWEEP_TIMEOUT` seconds (default 240) - a tighter inherited `FM_WRITE_BACK_BUDGET` wins, a larger or unreadable one cannot loosen it - reads at most `FM_BOARD_SWEEP_MAX_PAGES` pages of 100 per listing (default 20), and performs at most `FM_BOARD_SWEEP_MAX_CHANGES` writes per run (default 50); a bound that truncates anything says so, because a silent cap reads as complete coverage.
The whole-operation budget says so wherever it truncates, on a read as much as on a write, down to a call refused on the last row of the last project.
Every call the sweep makes reports its failure through one function that is the only thing deciding whether the board or the budget was at fault, so a budget that runs out is reported as the truncation it is rather than as one more board the run could not reach, and no failure inside the sweep goes unreported.
A run that stops early records the last registry entry it FINISHED in `state/.board-sweep-cursor` and the next run starts after it, wrapping, so a budget too small to cover the whole fleet at once still covers all of it across a bounded number of runs rather than reconciling the same first projects forever.
Finished rather than reached: an entry the run was cut short inside was not reconciled, so the next run starts AT it rather than skipping it, which would make the one entry a bounded sweep cannot afford the one entry it never retries.
The single exception is a run that finished nothing at all, which advances past the entry it died in so that one pathologically expensive entry cannot block every other entry from ever being read.
That cursor is deliberately a different file from the `state/.board-sweep` interval marker, which `bin/fm-bootstrap.sh` truncates every time it starts a sweep; a resume point kept there would be erased just before the walk that reads it.
A truncated run also names the entries it did not finish, because "drift may remain" and "these boards were not looked at" are different facts.
A listing the walk could not follow to its end - the page cap reached, or a page that promised more and then named no cursor to follow - is reported the same way and is never mistaken for a listing that ended; where that listing is the board's items, membership is left alone entirely, because an issue is missing from a board only if it is on no page of it and a page that was never read cannot say.
`--dry-run` charges each rehearsed write against `--limit` exactly as the run it previews would, so an issue that is both absent and closed counts as two and the preview truncates where the real sweep truncates.
`bin/fm-bootstrap.sh` runs it once per locked session start, at most every `FM_BOARD_SWEEP_INTERVAL` seconds (default 21600), and relays only its actionable `BOARD_SWEEP:` lines - a board one run could not reach is not a fleet diagnostic, because the next sweep re-derives exactly the same drift.
That run takes half of what is left of the deferred network stage's own `FM_STARTUP_NETWORK_TIMEOUT` bound rather than its own larger default, and is skipped outright when too little of the stage remains, because a sweep the stage kills part-way through takes every check after it down too, and a board problem is never allowed to become a fleet problem.

Neither command ever creates, renames, or deletes a view, filter, field, status option, or item, and neither writes any field but Status: a milestone or a closed issue with no matching status option is reported and the status left alone.
That is a hard safety rule rather than a matter of taste, because `updateProjectV2Field` replaces a single-select field's whole option set and reassigns every option id, which detaches every item already using them: adding one option to the real Firstmate board blanked the status of all twenty items instantly.
A missing option is therefore the captain's to add by hand.
Projects v2 is GraphQL-only and `gh-axi` does not implement it, so that one path uses `gh api graphql` directly and additionally needs the token's `project` scope, which `repo` does not imply.
`config/project-board` is inherited by secondmate homes, so a secondmate's work reaches the same fallback board.

Every write-back path fails open exactly as enrichment does: an unreachable, unauthenticated, rate-limited, or missing target prints one warning on stderr and exits 0, so it can never block or fail dispatch, validation, merge, or cleanup.
What it is never allowed to be is silent, which is why each non-write reports its own reason rather than passing quietly.

`bin/fm-issue-status.sh` adds optional title and open/closed enrichment behind per-forge adapters: `github.com` and Gitea on any host are implemented, while a self-hosted GitHub host and GitLab report that they have no adapter and keep the plain link.
Enrichment is decoration on a link that already resolves: an unreachable host, an expired or missing credential, an unsupported forge, a deleted issue, or a private repository degrades to the canonical URL plus a one-line reason and still exits 0, so no consumer stalls or blanks.
Results are cached under `state/issue-status/` for `FM_ISSUE_STATUS_TTL` seconds (default 900), and that cache is what stops repeated dashboard refreshes hammering a forge: every refresh inside the TTL is answered from disk without contacting the host at all.
The live lookups that miss the cache are additionally spaced per host by `FM_ISSUE_STATUS_MIN_INTERVAL` seconds (default 2).
Each live request is bounded by `FM_ISSUE_STATUS_TIMEOUT` seconds (default 10); an empty, zero, or non-numeric value uses the default.
That spacing is deliberately best-effort rather than guaranteed: there is no lock, so two concurrent processes may each observe no recent call and each perform one lookup.
Cache entries and the per-host timestamp are replaced atomically, so a concurrent reader always sees a whole record rather than a torn one.

Per-host credentials live in `config/forge-tokens/<host>`, which must be a regular file with mode 0600; a token stored more loosely is refused rather than used, on the read and write sides alike, because `bin/fm-forge-lib.sh` resolves it once for both.
GitHub needs no entry because it uses the ambient `gh-axi` authentication.
Gitea uses its host entry for both enrichment and write-back; an absent entry, or one whose file is present but empty, still allows an unauthenticated read of public repositories, while write-back reports which of those two it found rather than blurring them.
That library's header states the minimum viable token scope per forge - Gitea needs only `read:issue` plus `write:issue`, never repository admin - so the captain can issue a narrow token and revoke a wider one.
`config/` is gitignored in full, and `forge-tokens` is deliberately absent from the inheritable-config allowlist in `bin/fm-config-inherit-lib.sh`, so a secondmate home never receives another home's forge credentials.
The token reaches `curl` through a stdin config file, so it never appears in process arguments, output, or the cache.

## Dashboard agent events (dashboard-events.json)

The dashboard's live per-agent activity timeline is configured outside the operational home, because its store and its credential belong to the dashboard rather than to the fleet.
`bin/fm-dashboard-instrument.sh enable` writes `dashboard-events.json` and `dashboard-events.curlrc` under the user configuration root (`$XDG_CONFIG_HOME/firstmate`, or `~/.config/firstmate`), both mode 0600, and their presence is the entire switch.
[`docs/dashboard-events.md`](dashboard-events.md) owns that contract, the store location, the retention environment names, and what an event may contain.

## Dashboard credentials (dashboard-auth.json)

The dashboard's credentials live beside its event configuration under the same user configuration root, and for the same reason: they belong to the dashboard rather than to the fleet, so a secondmate home never inherits them.
`bin/fm-dashboard-install.sh --set-password` writes `dashboard-auth.json` mode 0600 holding a salted digest and never the password itself.
Their presence is what makes a bind beyond loopback possible at all; [`docs/dashboard-remote-access.md`](dashboard-remote-access.md) owns that posture.

## Usage cost rates (config/usage-rates.json)

Token accounting is always on once [`bin/fm-usage.mjs`](../bin/fm-usage.mjs) runs, while a cost estimate is opt-in and absent by default.
[usage-accounting.md](usage-accounting.md) owns what is stored, how a task keeps its usage after cleanup, and why tokens never imply dollars.

Write the local, gitignored `config/usage-rates.json` under the effective Firstmate home to opt in, or point `FM_USAGE_RATES` at another file.
Rates are per million tokens in the file's declared currency:

```json
{
  "schema": "fm-usage-rates.v1",
  "rate_version": "2026-08-01",
  "currency": "USD",
  "models": {
    "claude-opus-5": {"input": 15, "output": 75, "cache_read": 1.5, "cache_write": 18.75}
  }
}
```

`rate_version` is stored with every estimate it produces, so a rate change is a new version rather than a silent rewrite of history.
A model with no entry stays explicitly unpriced and keeps its tokens, and an absent, unreadable, or wrong-schema file means no estimate at all rather than a zero.
This file is local to each Firstmate home and is not part of secondmate inherited configuration.

## Pi Calm preference (config/calm)

The Pi Calm extension stores the captain's home-local presentation choice in gitignored `config/calm` under the effective Firstmate home, resolved from `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `FM_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
The values it writes are `on` and `off`, each followed by one newline; an absent, unreadable, or unrecognized value defaults to off.
`max` is the legacy value written by a removed third presentation level whose behavior is now ordinary Calm, and it is still read as `on`, so a home upgraded from it keeps Calm on rather than dropping to off.
The `/calm` command replaces the file atomically before changing live presentation, so a failed write leaves the current choice unchanged rather than claiming persistence.
The extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.
This preference is local to each Firstmate home and is not part of secondmate inherited configuration.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations.
Secondmate handoffs are separate and unconditional: `fm-backlog-handoff.sh` keeps only its own fleet-level validation and always delegates the item move to `tasks-axi mv`, the single owner of the backlog format.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the installed build passes the shared version and feature probe owned by [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh), including the atomic multi-ID move required by handoff delegation.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

## Runtime backend (config/backend / FM_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend (see [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends (see [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md), and [`docs/cmux-backend.md`](cmux-backend.md)).
Treehouse remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; Orca provides both the task worktree and terminal endpoint.
New spawns choose the backend in this order: an explicit `--backend` flag that current authority for that exact task alone has authorized (a present captain instruction or the task's own accepted brief; never later-task precedent by analogy), then `FM_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.
Auto-detected herdr or cmux prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Zellij and Orca are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `FM_BACKEND=<name>`, or by telling the first mate in chat.
Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`fm-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, and `cmux` for ship, design, and scout tasks; `backend=orca` and `backend=cmux` both still refuse `--secondmate` until secondmate launch semantics are designed for each.
`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.
The session-start secondmate liveness sweep uses the recovery-grade `fm_backend_agent_state` classifier where verified.
The comment above that function in `bin/fm-backend.sh` is the single owner of its detailed state contract and recovery authorization.
The compatibility helper `fm_backend_agent_alive` continues to collapse those detailed results to `alive`, `dead`, or `unknown` for older callers.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.
A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.
A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its opaque runtime endpoint.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=fm-<id>` kept as the shared firstmate alias.
A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.
Legacy tmux metadata remains cleanup-compatible when its exact window name is `fm-<id>`; opaque non-tmux endpoints require their recorded `endpoint_task_id=` binding.
The locked bootstrap sweep `bin/fm-endpoint-binding-migrate.sh` examines non-tmux records written before that binding existed, adds the binding only when the recorded endpoint's backend-specific live identity still proves it belongs to that task, and reports rather than binds every endpoint it cannot prove.
`FM_HOME` determines Herdr's home label: the primary home uses `firstmate`, and a secondmate home marked by `.fm-secondmate-home` uses `2ndmate-<secondmate-id>`.
[`herdr-backend.md`](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior.
The local `config/herdr-presentation-spaces` file instead opts a home out of, or explicitly in to, Herdr's default-on disposable single-task visual projection; [Presentation spaces](herdr-backend.md#presentation-spaces) owns its accepted values, default, Herdr version floor, migration, behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
The setting is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
For normal zellij operations, `FM_ZELLIJ_SESSION` selects the named session and defaults to `firstmate`.
Zellij has no per-home workspace split: primary and secondmate tasks share that one session, and visible tab titles are scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.
cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `fm-<id>`, but the actual cmux workspace title is scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Test cleanup must use the guarded path in [`docs/cmux-backend.md`](cmux-backend.md#current-operation-and-safety), never enumerate-and-close every workspace.
`config/backend` is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux|herdr` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `firstmate:0` tmux fallback with a warning.
Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the current channel reference, [`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) for active evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Trace context propagation (config/trace-context / FM_TRACE_CONTEXT)

The optional local, gitignored `config/trace-context` presence flag enables default-off native W3C trace-context propagation.
`FM_TRACE_CONTEXT` overrides the file: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked home session resolves those inputs once, and all spawns from that home use the frozen decision until a new session starts.
When launching a Secondmate, the primary copies the presence flag into its home and passes the primary session's frozen decision as a non-empty `FM_TRACE_CONTEXT=on|off` override for the Secondmate's own session start.
A Secondmate on a remote route is covered the same way: the primary resolves and records that task's carrier, and the configured host exports it and receives the same enablement snapshot.
The presence flag is session-scoped enablement, so it transfers at launch and is left unchanged by live convergence into a running home.
See [`trace-context.md`](trace-context.md) for carrier semantics, supported routes, the manual fleet-restart requirement, the session boundary, and safety limits; `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records repeatable evidence.

## Brain scoping (config/gbrain.json, config/gbrain-local.json, config/gbrain-secrets/)

Each Firstmate home owns exactly one GBrain brain and writes only that brain.
The brain's default location and directory layout are owned by [`gbrain-scoping.md`](gbrain-scoping.md#one-brain-per-home), and [`gbrain.md`](gbrain.md#what-a-home-can-actually-rebuild-from) owns whether its durable document source is an archive or the capture outbox.
The location is derived from the home path, so two homes never collide by omission; a home already running a GBrain deployment elsewhere points at it with `brain_root` in `config/gbrain-local.json`.

The configuration is split across three local, gitignored planes because they must propagate differently.
`config/gbrain.json` is fleet-shared and IS inherited: it holds the local embedding and reranker endpoints and models, the hosted synthesis provider reference, the main brain's addresses and mount name, and the *names* of credentials.
Its schema is closed, so it refuses an unknown field, a `brain_root` or `client_id` that belongs to one home alone, a credential pasted where a credential name belongs, a `main_brain.scopes` value other than exactly `read`, and a main-brain URL that would carry a client secret in plaintext to a non-loopback host.
That closure is what lets the file be inherited verbatim while every home still writes its own brain, and it is enforced at each boundary that copies the file - local propagation and both ends of the remote route - so a credential pasted into the file is refused before any home or config-reread instruction receives it.
`config/gbrain-local.json` holds this home's `brain_root` override, its own OAuth `client_id`, and `main_brain_owner` when this home's brain is the one the fleet reads, and is never inherited.
`config/gbrain-secrets/<name>` holds one credential per file, each a regular file with mode 0600 and refused when stored more loosely, exactly as `config/forge-tokens/<host>` is; it is never inherited, so a rotation never copies a secret through inherited configuration.

`bin/fm-gbrain-lib.sh` owns validation, path derivation, home resolution, credential reading, and the main-brain token mint, `bin/fm-gbrain.sh` is the operator surface, `bin/fm-recall.sh` is the agent-facing retrieval surface, and `bin/fm-config-inherit-lib.sh` carries only the shared plane.
[`gbrain-scoping.md`](gbrain-scoping.md) owns the read-only main-brain share, how a brain is read, source precedence, offline behavior, rotation, revocation, and retirement cleanup, and [`verification/gbrain-readonly-share.md`](verification/gbrain-readonly-share.md) records the evidence.
[`gbrain-capture.md`](gbrain-capture.md) owns what a finished task writes into that brain, and `data/gbrain-outbox/` holds its durable pending records.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` sets `test.evidence.store_in_repo: true` and pins `commands.lint` to `bin/fm-lint.sh` so local lint matches CI.
Storing evidence in the repo publishes each run's test artifacts to the orphan `no-mistakes/evidence` branch and links them from the PR body, instead of keeping them on local disk under the no-mistakes home.
That branch shares no history with code branches, so evidence never enters a pushed feature branch or the default branch; the worktree's `.no-mistakes/` stays local and CI rejects tracked entries under that path.
It does not set `commands.test` to a complete `tests/*.test.sh` walk.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the firstmate-specific local test policy and entry points.
Portable shard evidence and coverage rules are in [fm-test-portable-shards.md](fm-test-portable-shards.md); [herdr-backend.md](herdr-backend.md#destructive-lab-safety) owns the real-Herdr lane's isolation boundary, and [runtime-backends.md](verification/runtime-backends.md#herdr) owns active evidence.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Domain-local preferences for one captain's fleet live locally in each home's `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and curate the matching bullet in place under the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) tiering and archive contract; add a new bullet only for a genuinely new durable preference.
Shared captain preferences that apply across secondmate domains live only in the primary home's optional `data/captain-shared.md`.
`secondmate-provisioning` owns its propagation contract, including the required header, read-only secondmate copies, quarantine diagnostics, and the rollout rule that existing homes trim `data/captain.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) aging-tier and cold-archive contract: inspect the current file first and curate it instead of appending forever.
There is no shared learnings file by captain decision.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-home allowance for the startup prompt-memory surface: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` together.
The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.
To select another allowance, replace the primary home's file with one valid positive value in the exact format below; the next locked bootstrap convergence or `bin/fm-config-push.sh` propagates it to registered secondmates.
A secondmate does not create an independent default and instead receives the primary value through the inherited-local-material contract in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.
Use `bin/fm-startup-memory-budget.sh read` to validate and print the effective value, or `bin/fm-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.
An inherited `data/captain-shared.md` counts in a secondmate's total but remains primary-owned and read-only there.
The internal [`/stow` skill](../.agents/skills/stow/SKILL.md) owns curation and its automatic secondmate cascade, which accounts every home against this same per-home allowance separately rather than against a fleet total.
The helper's header owns exact parsing, publication, and report output mechanics.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
The concise single-line route contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), including the parser-compatible fields, one-sentence summary requirement, `home:` pointer to the seeded charter, and limit on extra registry prose.
A remote route adds `host:` and `root:` before the existing fields and places the whole secondmate home on that SSH host; it does not make ordinary workers remotely placeable.
[`remote-secondmates.md`](remote-secondmates.md) owns current remote setup, operation, and safety behavior.
Use `fm-home-seed.sh validate` to check the complete operational registry contract documented by the command itself.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh local firstmate worktree for the secondmate home.
For remote provisioning, including supplied project origins, follow [Remote second mates](remote-secondmates.md#provision-a-route).
Use the deliberate `--no-projects` signal only for a firstmate-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog queued items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent and refuses In flight, Done, or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.
The seeded home's `data/charter.md` owns the standard secondmate lifecycle and escalation contract; the route file points to it through the existing `home:` field instead of adding another pointer.
Each seed writes an `.fm-secondmate-home` identity marker at the home root, alongside a durable `.fm-secondmate-parent` record of the home's route to its parent (see "Provision a route" in [`docs/remote-secondmates.md`](remote-secondmates.md)).
The tracked root `.gitignore` ignores both markers, so validation can read them without making a freshly seeded home appear dirty to porcelain-based safety checks.
This does not relax protection for any other untracked file.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatefirstmate`'s origin refresh instead.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
Before `fm-brief.sh`, `fm-spawn.sh`, or `fm-afk-launch.sh` persists a path or passes it to another process, it resolves each applicable relative `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` directory against the caller's working directory, preserves absolute spellings unchanged, and rejects an unresolvable relative directory with the offending variable named.
Bootstrap applies the same relative `FM_HOME` resolution only when embedding that home in the generated Relay poll shim; other transient consumers retain their existing shell-relative behavior.
For the herdr backend, `FM_HOME` also determines the workspace label used by the adapter.
For the zellij backend, `FM_HOME` does not split containers, but it determines the readable home prefix embedded in visible tab titles; use `FM_ZELLIJ_SESSION` when a separate zellij session is needed.
The full zellij home label also includes a short hash of the resolved `FM_ROOT` path.
For the cmux backend, `FM_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read from, while `FM_HOME` determines the default config path and readable home prefix embedded in workspace titles.
The full cmux home label also includes a short hash of the resolved `FM_ROOT` path, and there is no per-home container split.

## Harness support

claude, codex, opencode, pi, pi-signed, grok, kimi, and cursor are empirically verified for crewmate and secondmate launches; [README requirements](../README.md#requirements) own the set supported for the primary session.
A cursor secondmate or primary runs the tracked project-scope `.cursor/hooks.json` in its own home and must be launched with `--trust`, or no project hook loads; [`docs/supervision-protocols/cursor.md`](supervision-protocols/cursor.md) owns its supervision protocol.
Cursor delivery confirmation is verified on tmux and Herdr only.
On Zellij, cmux, and Orca a Cursor steer lands, but `fm-send` reports delivery unconfirmed and exits non-zero because their shared submit core does not consult the busy footer; [runtime backend verification](verification/runtime-backends.md#cursor-agent-cli) owns the evidence and transcript-state boundary.
agy (Antigravity CLI/Gemini) is additionally verified only for crewmate and scout launches on the herdr backend; it is never a primary harness, a secondmate launcher, or available on another backend.
muse is verified for crewmate and scout launches ONLY, and `fm-spawn.sh` refuses it for a secondmate, because muse ships no usable hook surface for a primary session's turn-end supervision; [`docs/verification/muse.md`](verification/muse.md) owns that evidence.
muse also needs a worker-reachable credential before spawning, and the portable fleet path is the `<config>/muse/auth.json` credential stored by `muse login`, because a caller-only `META_API_KEY` does not cross a long-lived backend daemon.
New harnesses get verified through a supervised trial task before joining either set.
The verified adapter evidence - each harness's busy-state source, interrupt and exit behavior, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
The executable interrupt and exit mechanics live in [`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh), and [`docs/agent-control.md`](agent-control.md) owns their lifecycle-control architecture.
Exact launch-command construction, including the verified templates and model/effort flags, lives in [`bin/fm-launch-lib.sh`](../bin/fm-launch-lib.sh); [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) owns the surrounding gates, workspace-trust orchestration, and non-template hook installation.
Pi-family launches adapt the regular-TUI safeguard to the installed CLI's capabilities so fullscreen mode cannot rewrite scrollback and bury steers; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact version-safe launch mechanics.
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) owns its separate captain-approved crew wake hook.
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Cursor's stop hook parks on the watcher, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When pi-signed is selected, Firstmate preserves `FM_PI_HARNESS=pi-signed` and refuses the launch if the selected executable is unavailable rather than falling back to pi; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns executable resolution and launch mechanics.
Plain Pi launches set `FM_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
Selecting cursor or agy here requires the herdr runtime backend; `fm-spawn.sh` refuses either adapter when another backend resolves.
Because an absent or `default` secondmate harness falls back to `config/crew-harness`, a home that selects cursor or agy for crews must configure a different concrete secondmate harness before launching a secondmate.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`fm-harness.sh secondmate-model` and `fm-harness.sh secondmate-effort` expose only the optional tokens from `config/secondmate-harness`; `config/crew-harness` remains a bare adapter-name file.
Changing this pin affects the next secondmate spawn or control-plane relaunch; the relaunch profile rules are owned by [`docs/agent-control.md`](agent-control.md#transactional-relaunch).
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; for a local route, an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
Remote secondmate routes accept verified harness adapters only and reject raw launch commands.
cursor and agy are invalid secondmate harnesses even when explicitly configured or passed; `fm-spawn.sh` refuses them before backend or worktree setup.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
The inherited-local-material contract is owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); its harness-relevant consequence is that a secondmate's own crewmates use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.
`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi crews, `fm-spawn.sh` runs `fm-kimi-turnend-hook.sh install`, drops a per-task `.fm-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.
Kimi continues to use the captain's normal Kimi home, including the existing config, skills, and memory; Firstmate does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the captain's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.
Its `remove` action excises only the marker-delimited Firstmate region and removes Firstmate's hook files.
For Pi and pi-signed secondmate launches, `fm-spawn.sh` starts the selected executable with `-e` pointed at the secondmate home's own tracked `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts`, both already present from the secondmate home's git worktree.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best matching rule with judgment, resolves its profile object or array under the operating contract in `AGENTS.md` section 4 and `quota-array-dispatch`, and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Secondmate spawns are exempt and still resolve through `config/secondmate-harness` and its optional model and effort tokens.
This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the completion-aware profile-array selection procedure.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`.
If no dispatch rule fits, firstmate resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
If a selected profile carries an effort value the chosen harness does not accept, `fm-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `CREW_DISPATCH` diagnostic when it is visible in the file.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
When a valid profile selects cursor or agy while the resolved backend is not herdr, bootstrap reports `CREW_DISPATCH: backend mismatch - ...`, and `fm-spawn.sh` still refuses the launch.
While the file remains present, no crewmate or scout spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.
Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## LLM quota sidecar

The optional LLM quota sidecar is a read-only host-published evidence source that adds visibility for subscriptions `quota-axi` may not cover.
Producer files live at `$HOME/shared/quota/<provider>.json` by default, and `FM_QUOTA_SIDECAR_DIR` or `bin/fm-quota-sidecar.sh --dir` selects another mounted directory.
The directory may disappear while the publishing laptop sleeps or the share is unmounted, so its absence means unavailable evidence rather than an operating failure.

This section is the single owner of the producer schema and timestamp semantics.
Each file uses `fm-quota-sidecar.v1`:

```json
{
  "schema": "fm-quota-sidecar.v1",
  "provider": "minimax",
  "captured_at": "2026-08-11T18:03:01.520Z",
  "last_attempt_at": "2026-08-11T18:03:01.520Z",
  "status": "ok",
  "windows": [
    {
      "id": "session",
      "percent_remaining": 97,
      "resets_at": "2026-08-11T20:00:00.000Z"
    }
  ]
}
```

`provider` is the stable provider id and matches the filename stem exactly; it uses only ASCII letters, digits, `.`, `_`, and `-`, and never begins with `._`.

Every timestamp in the document is UTC ISO 8601 with a literal `Z` suffix - `YYYY-MM-DDTHH:MM:SSZ`, optionally with fractional seconds.
A numeric offset such as `+00:00`, a local-time string, and a missing suffix are all non-conforming even when the instant they denote is correct.
The producer host's own zone is irrelevant to the file: a Pacific-time MacBook must convert to true UTC before formatting, never append `Z` to local wall-clock time, because an unconverted timestamp is indistinguishable from a real seven- or eight-hour drift.
Producer and consumer clocks are not assumed to agree, and the reader tolerates a bounded drift in either direction before reporting the observation as unusable, so keep the producing host's clock synchronized rather than relying on that tolerance.

`captured_at` is the UTC time of the last successful quota collection and remains unchanged after a failed attempt.
`last_attempt_at` is the UTC time of the latest collection attempt, whether it succeeded or failed, and is never earlier than `captured_at`.
`status` is `ok` after a successful attempt or `error` after a failed one.
On an error, the producer retains the last successful `windows` so a reader can report their age without treating them as current.
A conforming document therefore always carries at least one window: the producer publishes nothing until its first collection succeeds, because a document with no window behind it carries no observation to age and would only misreport an empty collector as a source of quota evidence.
Each window has a stable `id` of 1 to 64 characters matching `^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`, numeric `percent_remaining` from 0 through 100, and a UTC `resets_at` timestamp in the same form as above or `null` when the producer cannot supply one.
Producer files must contain no credentials.
Consumers must still project only the fields they need rather than printing arbitrary fields from a mounted file.

There is no partial conformance: a document that breaks any constraint above supplies no quota evidence at all, so a producer that cannot yet satisfy one of them publishes nothing for that provider rather than an approximation.

[`bin/fm-quota-sidecar.sh`](../bin/fm-quota-sidecar.sh) owns the reader interface, safe field projection, and freshness enforcement mechanics.
The agent-only [`quota-array-dispatch`](../.agents/skills/quota-array-dispatch/SKILL.md) skill owns when to read the sidecar, the freshness decision rule, source precedence, uncertainty handling, and selection procedure.
The sidecar is additive and never overrides or shadows quota evidence that `quota-axi` owns.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, no-mistakes v1.31.2 or newer, compatible gh-axi, chrome-devtools-axi, compatible lavish-axi, compatible tasks-axi per "Backlog backend" above, and compatible quota-axi.
[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns the axi-family floor policy and the gh-axi and lavish-axi floors, while [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) and [`bin/fm-quota-axi-lib.sh`](../bin/fm-quota-axi-lib.sh) hold their own tools' floor constants.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, no-mistakes runs the validation pipeline, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
That delta is owned in code by `fm_backend_required_tools` in `bin/fm-backend.sh`: the resolved backend's own session-provider CLI (`tmux`, `herdr`, `zellij`, `orca`, or `cmux`), `jq` for the JSON-emitting experimental adapters (`herdr`, `zellij`, `cmux`) whose spawn and liveness paths parse the backend's JSON output, and the `treehouse` worktree provider for every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`).
Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, or cmux home is therefore never told `tmux` is missing, and the `treehouse` durable-lease upgrade check runs only for the backends that actually use treehouse.
When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
When Relay is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
`tasks-axi` and `quota-axi` are required bootstrap tools in every profile, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)`; when `config/backlog-backend` is not `manual` and compatible `tasks-axi` is on `PATH`, bootstrap stays silent and firstmate uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
An absent or incompatible `gh-axi` reports `MISSING: gh-axi (install: npm install -g gh-axi && gh-axi setup hooks)`.
An absent or incompatible `lavish-axi` reports `MISSING: lavish-axi (install: npm install -g lavish-axi && lavish-axi setup hooks)`.
An absent or too-old `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)`; firstmate cannot resolve a profile array without a compatible binary.
That floor exists because it is the first build reporting per-credential auth sources, which Firstmate uses when the candidate's authoritative catalog does not itself establish the selected authentication surface.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
The locked session-start deferred network stage runs bootstrap's best-effort project clone refresh through `fm-fleet-sync.sh`.
Its fetch prunes stale remote-tracking pointers but never local branches; exact-task local branch cleanup belongs to `fm-teardown.sh` and requires its proven-merge check.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
The same locked step then runs a bounded best-effort `bin/fm-usage.mjs ingest`, but only when `data/usage.db` already exists, so a home that never opted into token accounting pays nothing for it.
A completed refresh is silent; one that timed out, could not be bounded on this host, or ran and exited non-zero reports itself on a single `USAGE_STORE:` line.
The timeout line carries the bound and the elapsed seconds, the failure line carries the collector's exit status and the elapsed seconds, and the unbounded-host line carries neither because nothing ran.
`FM_BOOTSTRAP_USAGE_TIMEOUT` owns that bound (default 120 seconds) and [`usage-accounting.md`](usage-accounting.md) owns the cadence it shares with teardown.
After that refresh, bootstrap runs the read-only `fm-vault-drift.sh` detector and emits `VAULT_DRIFT:` for stale vaults or external vault locations whose drift cannot be measured.
The same detector runs in lock-refused detect-only sessions because it never writes project clones or vaults; the script header owns the vault-shape, threshold, and diagnostic contracts.
Every session start also runs the read-only [`bin/fm-gbrain-pin-check.sh`](../bin/fm-gbrain-pin-check.sh) comparison between the GBrain release [`gbrain.md`](gbrain.md) records and the one this host actually runs, and emits `GBRAIN_PIN:` only for drift or for a side it could not read.
Agreement and a home with no GBrain installed are both silent, that script alone decides whether this host has a gbrain to compare against, `FM_BOOTSTRAP_PIN_TIMEOUT` owns that bound (default 10 seconds), and [`gbrain.md`](gbrain.md) owns the recorded pin, its upgrade policy, and the verdicts that line carries.
If bootstrap kills a timed-out clone refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
That same stage runs the fleet-wide project-board drift sweep straight after the clone refresh; "Project issue trackers" above owns its declaration gate, its bounds, its resume point, and its `BOARD_SWEEP:` reporting.
The same deferred network stage runs bootstrap's guarded secondmate sync for recorded live homes, then propagates declared inherited local material into each validated live home.
Local routes use direct guarded filesystem operations, while remote routes delegate sync and allowlisted transfer through their configured SSH host without probing any unconfigured fleet.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_SECONDMATES:` with the failure reason.
The same bootstrap run emits `SECONDMATE_LIVENESS:` only when a registered secondmate is skipped or its relaunch fails; already-live and successfully relaunched secondmates are handled silently.
For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each declared inherited item's result for each live home as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero for real propagation errors or config-reread send failures.
The declared set is the `FM_INHERITABLE_CONFIG` items plus `data/captain-shared.md`, owned by `bin/fm-config-inherit-lib.sh`; the inventory in `AGENTS.md` section 2 records whether each config item is inherited.
When an allowlisted config item changes for an already-running local home, it sends the literal-content reread pointer described in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
A changed remote home instead receives one durably recorded marked re-read instruction after the allowlisted bytes have transferred because primary-local generation paths are not meaningful on another host.
The locked bootstrap inheritance pass uses the same placement-specific behavior; see `secondmate-provisioning` for the single contract owner.
That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## Relay (.env)

Relay lets a firstmate instance answer public mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It covers both public surfaces the relay supports: `@myfirstmate` mentions on X, and mentions of the myfirstmate bot in a Discord server where it is installed.
Both surfaces are the same opt-in and the same machinery - one pairing token, one relay poll, and one reply path - so everything below applies to Discord mentions unless a line names a platform explicitly.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while its surrounding conversation context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

To turn it on:

1. Sign in at [myfirstmate.io](https://myfirstmate.io) with X or Discord.
2. For the Discord surface, use the dashboard's install link to add the myfirstmate bot to a server you administer; the X surface needs no install step.
3. Copy the pairing token from the dashboard into this firstmate home's gitignored `.env` as `FMX_PAIRING_TOKEN=<token>`.
4. Start a new firstmate session so bootstrap picks the token up, then mention `@myfirstmate` on X or mention the bot in a server where it is installed.

The dashboard owns account creation, identity linking, bot installation, and token issuance; this document owns only what the local firstmate home does with the token once it is in `.env`.

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.
The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section is the single owner of the Relay cadence contract: a Relay instance polls every 30 seconds instead of the default 300, only a Relay instance speeds up because a non-Relay home has no `config/x-mode.env`, and the session-start supervision operating block includes the cadence instruction when that file exists.
The active primary-harness supervision protocol owns how that sourced cadence reaches the watcher process.
Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a watcher is already running, or opt-out - is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap deliberately never restarts the watcher itself.
While away mode is active the daemon owns the watcher and its default cadence applies; away-mode Relay cadence is a deferred follow-up.
When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.
Relay remains additive to non-Relay lifecycle behavior: homes without the generated artifacts keep the default watcher cadence and do not run the Relay poll.
Its request handling remains in Relay-specific `bin/` scripts and the `fmx-respond` skill, while the watcher owns authenticated dispatch from the generated local identity shim.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.
Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake firstmate again.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
The preserved object may also carry `in_reply_to_chain`, an optional oldest-first transcript of the surrounding conversation: entries shaped `{author_handle, text, unavailable, images}` plus an optional `kind` of `reply` (a reply ancestor), `thread_starter` (the message a thread grew from), or `history` (a recent nearby message), where an absent `kind` means a legacy reply-ancestor or thread-starter entry.
The chain is untrusted third-party public input and is often absent today (the relay currently sends it only for Discord reply chains and thread starters), so consumers treat it as strictly optional, tolerate unknown or missing fields, and read an entry with `unavailable: true` as a gap rather than content; the `fmx-respond` skill owns how firstmate reads it for referent resolution.
At the same time the poll records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) from the same authoritative relay payload, best-effort and keyed by `request_id` so concurrent requests never overwrite each other; it survives the inbox cleanup that follows the acknowledgement, so a delayed follow-up can recover the original platform and split budget even with no task link.
`recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, finishing with a `--final` one for ordinary Relay-linked work. When a typed promised-final commitment is registered, `bin/fm-public-followup.sh` owns the terminal reply and clears the legacy link after its receipt is validated.
That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.
Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` owns the source order: the durable per-request registry is consulted first, then the still-present inbox payload, then - for a follow-up posted live by request_id - an authoritative relay lookup via `POST /connector/request-context` (`{request_id}` in, `{platform, reply_max_chars}` back).
This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.
The link is home-local by construction, because it lives in that home's own `state/<task-id>.meta`: work routed to a secondmate has no record here, so `bin/fm-x-link.sh` refuses it, names the registered secondmate home the task was found in when it can, and points at the promised-final path (`bin/fm-public-followup.sh register ... --work-home secondmate:<id>`), which is the only follow-up mechanism that binds work in another home.
`bin/fm-x-link.sh` follows the same ordering when recording a fresh link's context and requires `jq`; its request-context lookup is best-effort: no token or `curl`; a non-2xx response; an unresolved response; or a relay version without that endpoint leaves the context unknown.
In that case the link is still recorded but `bin/fm-x-link.sh` prints a loud warning; and when either a follow-up's platform or explicit budget cannot be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses it (fail-safe exit 8) rather than posting with a local default - firstmate holds and retries it once both values are recoverable.
Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.
A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
`fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.
Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_DISCORD_REPLY_MAX_CHARS` defaults to 1900, clamps to a minimum of 50, and resets values above Discord's 2000-character limit back to 1900.
`FMX_X_THREAD_MAX` defaults to 25 and caps oversized reply threads for every platform, marking the last retained message with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 604800 (7 days) and controls the local completion follow-up window; `FMX_FOLLOWUP_MAX_COUNT` defaults to 3 and controls the local follow-up cap.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

### Promised public replies (state/public-followup)

A relay request that spawns real work can leave firstmate owing a specific public reply in a specific thread.
That promise is a typed `kind=public-followup` obligation owned entirely by `tasks-axi public-followup`, with the full private request context staying in `state/x-context/`; firstmate keeps no parallel copy of either.
`bin/fm-public-followup.sh` is firstmate's side: it registers a commitment, reconciles typed terminal work results into it, and posts the final reply through `bin/fm-x-reply.sh --followup`.
Run `bin/fm-public-followup.sh --help` for the exact subcommands and flags.

Registration is what creates this home's private transport under `state/public-followup/` (mode 0700): `registry/` for the bounded public-safe binding of each live commitment, `events/` for typed terminal results awaiting reconciliation, `consumed/` for the accepted-event ledger, `rejected/` for refusals kept with a one-line reason, and `surfaced` for the poll's last-surfaced signature.
The home that owns the commitment also owns the outward post, because only it holds the relay consent, the request context, and the opaque thread binding.
Work routed elsewhere reports a typed terminal result with `bin/fm-public-followup-emit.sh` and never looks for the thread; that emitter refuses to write into a home with no registration for the named obligation.
A terminal event's id is derived from its identity tuple, so a duplicate report, a retry, or a replay after restart resolves to the same event and changes nothing.

Activation is the same `.env` `FMX_PAIRING_TOKEN` contract as the rest of Relay, with no second flag.
A home without that token runs one file test and stops: no `tasks-axi` call, no backlog or request-context scan, and no `state/public-followup/` directory.
Ordinary startup, polling, cleanup, and silent read-side subcommands also produce no output; commands that require an active relay report that configuration error after the same gate.
A relay-enabled home with no registered commitment stops at an O(1) directory presence check, so the empty state costs no CLI call and adds no periodic scan.
Unreconciled terminal results ride the existing 30-second relay poll rather than a new process or timer: `bin/fm-x-poll.sh` compares the pending-event signature against `surfaced` and wakes firstmate once per new result set.
The session-start digest separately prints an "Public commitments awaiting delivery" subsection from disk when, and only when, this home is relay-active and still owes a reply, so compaction and restart are non-events.
`bin/fm-teardown.sh` refuses to clean up a task while this home still owes a public reply for exactly that work, unless `--force` carries explicit discard approval.
`FM_PF_RETRY_BACKOFF_SECS` (default 900) sets the next-attempt time recorded with a retryable delivery error.
See [verification/public-followup.md](verification/public-followup.md) for the current maintainer evidence behind the restart end-to-end and the relay-disabled zero-overhead guarantee.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/fm-procevent.sh` owns the generic contract; `bin/fm-procevent-lavish.sh` is the first adapter and wraps only the currently published `lavish-axi poll` interface.

The `when` adapter (`bin/fm-procevent-when.sh`) turns this channel into a condition->action primitive: it registers a deterministic condition and a deterministic action once, its blocking child polls the condition without waking firstmate, and a stable true fires the action at most once before one terminal outcome is durably captured and published as a wake that remains eligible for re-announcement until handled.
The (condition, action) spec is stored privately under `state/when/` and hash-bound by a trust record the same way `bin/fm-check-register.sh` binds a custom check, while the spec separately binds the resolved action executable's bytes; a mutated or unregistered spec or a changed action executable is refused before the action runs.
Every failure path - a mutated spec or action executable, a condition error past its budget, an expired deadline, a failed action, or an earlier fire whose outcome was never captured - produces a terminal captured outcome that wakes firstmate rather than a silent retry, and a durable single-fire marker claimed before the action makes restarts and re-polls unable to fire it twice.
The adapter automates only the exact deterministic subset: anything needing judgment, and anything destructive, irreversible, or security-sensitive, keeps the ordinary check-fires-then-firstmate-decides flow, and the adapter's header and `--help` own its commands, flags, and outcome document.

This section is the single owner of the runner's operating contract.
Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before any announcement or event can reference it.
By default, results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable wake queue, so the runner adds no second notification control plane.
The self-announcing adapter exception and its fail-safe ordering are defined below.
The watcher delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a default or fallback publication reaches firstmate through the same rewake path every other wake uses and never waits for a manual drain.
A queued `check` delivery is reported at most once per captured source and sequence while any records for that key remain queued.
A durable handled acknowledgement stops future source re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain's sequence-bound post-handling acknowledgement consumes it.

Discovery is never a timer.
Each registered source has its own child process blocking on that source, and the watcher's per-cycle `reconcile` republishes every captured result with no durable handled acknowledgement yet - regardless of any earlier publication - restarts a source whose owner is gone, and stops this home's runner when reconciliation runs after its registration disappeared unexpectedly.
In supported steady state, a home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

Whether a captured result ends its source is adapter knowledge, never the runner's.
After capture - and after initial `check` publication for the default ordering - the runner calls `bin/fm-procevent-<adapter>.sh terminal <result-file>` and retires the registration on exit 0 alone, dropping only the exact registration generation captured by its claim and releasing that claim only after removal succeeds under one source boundary; a missing command, an error, or any other exit keeps the source armed, so an adapter with no notion of ending needs no change.
A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work, while explicit `retire` stays the supported and idempotent path afterwards.
For Lavish that verdict covers an ended session, a missing session, and the final feedback of a `Send & End` review, which the published poll marks with `session_ended` before it returns only empty ended sessions.
A missing *artifact* is deliberately outside that set: unlike a missing session, a deleted review file can reappear - an editor rewriting it in place - so such a source stays armed and retiring it remains the handler's call.

Applying a captured result is adapter knowledge too, and some results carry no judgement at all: they must simply be applied idempotently to this home's own durable state.
Leaving that to a handler means it can silently not happen, so immediately after the terminal check above the runner calls `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` and lets the adapter apply and acknowledge its own result.
That call runs strictly after terminal retirement, because a handling adapter re-arms its own next source and retiring afterwards would drop that fresh registration and leave the source silently dead.
Exit 0 means the adapter fully applied and acknowledged the result; a missing command, an error, or any other exit is not a capture failure but leaves the result unacknowledged and therefore still eligible for re-announcement, so a handler receives it exactly as before and an adapter with no such command needs no change.
Announcement ordering is adapter-declared through `bin/fm-procevent-<adapter>.sh self-announcing`: an adapter that answers exit 0 declares that every result its autohandle fully applies is announced through a durable downstream channel of its own, so the runner applies first and publishes a `check` wake only for what remains unhandled afterwards; every other adapter keeps the strict publish-before-apply order, and its autohandle runs only when this capture's own wake was successfully appended to the durable queue.
The remote-secondmate reply adapter declares itself self-announcing: a captured reply reaches its local status mirror and settles its correlated pending-reply expectation without any handler step, the mirrored status bytes are the single wake for one remote note through the same signal classification a local secondmate's append gets, a byte-identical replayed capture adds no bytes and stays quiet, and only a capture the adapter could not fully apply is published as a `check` wake, whose adapter handling remains idempotent.

Keyed captain answers use one more seam of the same kind, and the runner still decides nothing about them.
Some sources carry the captain's answer to a durable decision, and what such an answer means is owned once by `bin/fm-decision-hold.sh`'s keyed-answer intake rather than by any channel.
A source bound to a decision origin with `bin/fm-decision-hold.sh bind <source-id> <origin-id>` therefore has each captured result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints is piped straight into that intake.
The adapter reports only what the captain chose; the intake owns every rule about what happens next, so the runner names no adapter, parses no result, and carries no decision rule, and a future source needs nothing here beyond an `answers` command and a binding.
Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, because recording the answer is transcription while acting on it is firstmate's judgement.
An unbound source, an adapter with no `answers` command, and a failure on either side all leave the capture untouched and still announced.

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.
Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`).
Each claim binds its home and runner PID to a process identity, unique claim generation, and exact registration-file generation.
Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.
Retirement and orphan reconciliation signal a runner process group only while its recorded process identity still matches, or when the recorded leader is gone and only its own owned group survives.
A runner leads its own process group, so a claim counts as reclaimable only when that whole generation is gone: a crashed leader whose group still has members is not stale, and reconcile stops that surviving group and releases its generation before starting any replacement.
If identity cannot be established for a live PID, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
A live PID whose identity no longer matches is a reused PID, so it is treated as stale and its process group is never signalled.

Supported secondmate retirement preflights each target home's bounded `sweep-home` command before destructive teardown, snapshots its registrations outside the target, then runs the sweep at that home's final deletion or return boundary.
If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
The sweep retires local registrations and machine-wide claims physically owned by that home through the same identity-checked, generation-bound retirement path, and leaves foreign-home claims untouched.
Teardown refuses with the home, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.
Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.

`FM_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.
`bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
Default and fallback `check` publication is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
The published `lavish-axi poll` clears feedback destructively before returning it, so a result lost between that clearing and the runner reading process output is unrecoverable.
Never describe this path as at-least-once, no-loss, or lossless.
`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target, and zellij/cmux home-title hash; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity reads in fm-wake-lib.sh and fm-teardown.sh, mainly for tests
FM_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux support ship/design/scout spawns, codex-app is not accepted
FM_TRACE_CONTEXT=       # optional trace-context override; see "Trace context propagation"
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Current transport behavior")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_ZELLIJ_SESSION=firstmate  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest; each line is capped by bin/fm-line-cap-lib.sh
FM_SESSION_START_QUEUED_LIMIT=20   # plain queued backlog rows in the session-start digest; in-flight, held, and blocked rows are never bounded and done rows are never listed
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_BOOTSTRAP_NETWORK=all   # internal session-start phase split: all, skip (local steps only), or only (network steps only); see bin/fm-bootstrap.sh
FM_STARTUP_NETWORK_TIMEOUT=120   # seconds bounding the whole deferred network stage; hitting it prints an actionable NETWORK_CHECKS line
FM_TASKS_AXI_COMPATIBLE=   # internal one-hop handoff of an already-computed tasks-axi compatibility verdict (0 or 1); consumed when bin/fm-tasks-axi-lib.sh is sourced
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # printed with every operator-visible alarm so a warning is not read as a refusal; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_INACTIVE_RECONCILE_SECS=900  # 60..1800-second watcher cadence and inactivity threshold; locked session start also scans immediately
FM_INACTIVE_RECONCILE_BUDGET_SECS=10  # 1..30-second scan deadline; wedged-scan kill backstop follows one second later
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or Relay dispatch)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_ISSUE_STATUS_TTL=900   # seconds a cached work-item enrichment result stays fresh
FM_ISSUE_STATUS_MIN_INTERVAL=2   # best-effort minimum seconds between live work-item lookups to one host
FM_ISSUE_STATUS_TIMEOUT=10   # seconds allowed per live work-item status request
FM_ISSUE_COMMENT_TIMEOUT=10   # seconds allowed per forge call fm-issue-comment.sh makes for the living status comment, on GitHub and on a per-host forge alike
FM_ISSUE_CLOSE_TIMEOUT=10   # seconds allowed per per-host forge call fm-pr-merge.sh makes to verify and close a landed work item
FM_PROJECT_BOARD_TIMEOUT=15   # seconds allowed per GitHub GraphQL call fm-project-board.sh makes for the captain's board
FM_BOARD_SWEEP_TIMEOUT=240   # seconds bounding the whole fleet-wide board reconciliation sweep; a tighter inherited FM_WRITE_BACK_BUDGET wins and a larger one cannot loosen it (see "Project issue trackers")
FM_BOARD_SWEEP_MAX_PAGES=20   # pages of 100 that sweep reads per board or tracker listing; a listing it could not finish reading plans no changes for that project and says so
FM_BOARD_SWEEP_MAX_CHANGES=50   # board writes one sweep may make before it stops, names the entries it did not finish, and leaves them to the next run
FM_BOARD_SWEEP_INTERVAL=21600   # minimum seconds between sweeps, measured from state/.board-sweep by bin/fm-bootstrap.sh
FM_WORK_ITEM_MILESTONE_TIMEOUT=40   # seconds allowed for one whole fm-work-item-milestone.sh fan-out; the comment surface may spend at most half and the board gets the rest
FM_GBRAIN_BIN=gbrain    # gbrain executable used by fm-gbrain.sh to register, revoke, and retire read-only main-brain clients, by fm-recall.sh to read this home's own brain, by fm-gbrain-capture.sh to deliver a captured document, by fm-gbrain-eval.sh to read the version, brain-plane configuration, and corpus counts an evaluation run records, by fm-gbrain-health.sh to resolve the brain root and validate the configured planes, and by fm-gbrain-pin-check.sh to read the installed release the recorded pin is compared against; see "Brain scoping"
FM_GBRAIN_TIMEOUT=10    # seconds allowed per main-brain token mint, in either surface, and per reachability probe in fm-gbrain.sh check
FM_GBRAIN_MAINTENANCE_STATE=   # optional operator announcement fm-gbrain-health.sh surfaces on the dashboard GBrain panel: ready | upgrading | reindexing; see docs/gbrain.md "Announce a maintenance window"
FM_GBRAIN_MAINTENANCE_DETAIL=   # optional free text shown with that announcement, e.g. the release being installed
FM_RECALL_TIMEOUT=      # optional seconds per fm-recall.sh retrieval call, overriding its per-command defaults (search 60, think 300); search sizes its result-provenance pass from the same value, once per corpus it reads
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
FM_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/firstmate/procevent-claims
FM_WHEN_OUTPUT_TAIL_BYTES=8192          # bound on the command-output tail inside one condition->action outcome document
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh; bin/fm-fleet-snapshot.sh derives its own value from its per-task bound for the reads it makes, so this override does not reach those, and that script's header owns the derivation
FM_TEARDOWN_NM_TIMEOUT=10    # seconds allowed per no-mistakes query or abort inside fm-teardown.sh
FM_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes run rows scanned when axi status cannot be attributed to the worktree
FM_CREW_STATE_DEGRADED_MAX_AGE=900   # seconds a recorded run-step may stand in as the degraded answer while the no-mistakes lookup cannot complete; 0 disables the degrade
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage
FM_RUN_PROGRESS_BIN=bin/fm-run-progress.sh   # test override for the validation-run progress reader consulted at the wedge-escalation point
FMX_PAIRING_TOKEN=      # Relay pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional Relay endpoint override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct Relay client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews Relay replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting Relay completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on Relay completion follow-ups per linked mention
FM_PF_RETRY_BACKOFF_SECS=900   # seconds before the next attempt after a retryable promised-public-reply delivery error
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
FM_CLAUDE_AUTOARM_ATTEMPTS=2   # bounded Stop-owned arm attempts per Claude auto-arm cycle; accepted values are 1, 2, or 3
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for watcher health, a role-verified Stop auto-arm claim, or a fresh epoch before deciding recovery ownership or failure progression
FM_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm outcome remains eligible for the current event epoch's recovery or failure decision
FM_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before the verified one-time attended fail-open; safely below Claude Code's 8-block override
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED; default 30 on Git Bash/MSYS
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows to stay above the MSYS confirm budget
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows to stay above the MSYS confirm budget
FM_PI_AWAY_POLL_MS=2000   # milliseconds between Pi extension checks for away-mode ownership transitions
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode give a still-running unready successor to exit; an arm observed exited when the deadline verdict settles gets one additional grace period of this length for close and stream teardown
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane or a confidently dead parked-decision repeat escalates; other first-sighting stale states surface immediately unless they declare the pause verb
FM_BUSY_TURN_MAX_SECS=3600         # maximum age of a busy pane's latest state/<id>.turn-ended marker, or its state/<id>.meta spawn record before any turn-boundary wake arrives, before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart. bin/fm-supervision-lib.sh owns the window, and bin/fm-fleet-snapshot.sh publishes it as supervision.watcher.quiet_allowance_seconds so the dashboard's Task activity signal judges quiet against this same tolerance instead of a constant of its own; docs/dashboard-inbox-policy.md owns that signal and what renders it today
FM_PAUSE_RESURFACE_SECS=3600       # seconds before an idle declared external wait re-surfaces for a recheck in the watcher or away-mode daemon; the away-mode clock runs from when the hold began and is never restarted by the crew rewriting its paused reason
FM_PAUSE_RESURFACE_MAX_STREAK=3    # how many times an unchanged declared wait may double the WIDTH of its recheck window before the cadence stops widening; 0 restores a fixed FM_PAUSE_RESURFACE_SECS cadence, and the streak restarts whenever the wait itself changes, which only ever narrows the window back toward the base. Clamped internally to 12 doublings and a one-day window, so a misconfigured value cannot overflow into a permanent re-surface
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_RUN_STRANDED_SILENCE_SECS=1800  # how long an actively-executing no-mistakes step may report NO activity before a wedge escalation stops being held for it. Both supervisors consult bin/fm-run-progress.sh at the escalation point only, so a crew parked on a run that is still moving stops alarming for as long as the hold lasts (bounded by FM_RUN_PROGRESS_HOLD_MAX below), while a stranded run and a confidently dead agent still alarm. docs/architecture.md owns the always-on watcher's no-evidence fallback for a surviving declared wait. Above the pipeline's own 10m step_quiet_warning on purpose: that marker is a liveness clue, and review or test steps routinely go 10-18 minutes on one opening line. Raising it delays a real wedge alarm by the same amount
FM_RUN_PROGRESS_NM_TIMEOUT=10      # seconds allowed for that bounded `no-mistakes axi status` read; a read that cannot complete is no evidence and never positive evidence that may hold a wedge escalation
FM_RUN_PROGRESS_HOLD_MAX=15        # consecutive run-progress holds one pane may spend before it wedge-escalates anyway, in both supervisors. Run progress is evidence about the RUN, not about the WORKER, so a moving pipeline may DELAY an alarm but never silence it: past the cap the escalation fires however healthy the run looks, carrying the progress detail so it reads as "still moving, this pane is not". 15 holds x FM_STALE_ESCALATE_SECS (240) is one hour, the same allowance FM_BUSY_TURN_MAX_SECS and FM_PAUSE_RESURFACE_SECS already give a live-but-quiet endpoint, and it clears this repo's own routine pipeline steps (review 11m median, test 6m) so only a genuinely long step ever reaches it. The forced escalation resets the hold count, not the escalation count. Raising it widens the blind window for a hung worker by the same amount; lowering it re-introduces routine noise on long healthy steps
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_BOOTSTRAP_USAGE_TIMEOUT=120       # seconds allowed for bootstrap's best-effort token-usage refresh, which runs only when data/usage.db exists; blank, non-numeric, or zero falls back to 120, because zero is what GNU timeout reads as "no timeout"
FM_BOOTSTRAP_PIN_TIMEOUT=10          # seconds allowed for bootstrap's read-only GBrain recorded-pin comparison, which runs wherever this code root carries a docs/gbrain.md; blank, non-numeric, or zero falls back to 10
FM_TEARDOWN_USAGE_TIMEOUT=60         # the same bound for the refresh task teardown runs before archiving a task; blank, non-numeric, or zero falls back to 60
FM_RUN_ATTRIBUTION_MIGRATION_TIMEOUT=10   # seconds allowed for each GitHub PR-head lookup the legacy run-attribution transition makes; blank, non-numeric, or zero falls back to 10
FM_RUN_ATTRIBUTION_MIGRATION_BUDGET=30    # seconds allowed for that whole sweep, so a hung forge costs one budget at session start rather than one timeout per candidate; a tighter inherited FM_WRITE_BACK_BUDGET wins, and candidates left unattempted stay diagnosed instead of migrated (bin/fm-run-attribution-legacy-transition.sh)
FM_VAULT_DRIFT_COMMITS=20            # project commits landed since a vault update before bootstrap reports drift
FM_VAULT_DRIFT_DAYS=7                # commit-to-commit drift-window days before bootstrap reports drift
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
FM_COMPOSER_IDLE_RE=    # optional fleet-wide idle-placeholder regex override (bin/fm-composer-lib.sh); a match alone does not prove emptiness because shape-specific position and ANSI de-emphasis safety gates still apply
FM_COMPOSER_CAPTURE_LINES=20   # fleet-wide bound for tail-capture composer reads; tmux instead supplies its bounded visible pane, while the other adapters use this small window so stale scrollback banners stay out of the candidate set
FM_COMPOSER_PI_MAX_LINES=8     # fleet-wide: maximum rows admitted between Pi's identity-corroborated separator pair; taller or ambiguous candidates stay unknown
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, used by styled tmux, herdr, and Zellij reads)
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful text submit; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
FM_SUPERVISOR_TARGET=              # optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|command:<cmd>; absent = auto (macOS -> an OS notification)
FM_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
