# Dashboard inbox and health policy

The dashboard's "Needs you" view answers one question: what is waiting on the captain right now.
This page is the single documented statement of how that answer is computed, and [`assets/dashboard/inbox.js`](../assets/dashboard/inbox.js) is its single executable copy.
The browser renders what that module returns and decides nothing on its own.

Every input comes from [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh)'s `fm-fleet-snapshot.v1` contract and the dashboard envelope.
Nothing in the inbox contacts a forge, re-reads `state/`, or re-derives fleet state a second way.
[`docs/fleet-data-contracts.md`](fleet-data-contracts.md) owns the field-ownership map those inputs come from.

## The rule that outranks the rest

Uncertainty is never rendered as good news.

A field that is missing, stale, or outside its documented enumeration resolves to an explicit `unknown` carrying its own reason.
It never resolves to a passing value, and it never resolves to blank space that the eye reads as fine.
An unreadable pull-request field is drawn as a dashed outline with the word `unknown` in it; an item whose age cannot be read is labelled "age unknown" and sorted to the top rather than filed quietly at the bottom.

## Pull-request readiness

A recorded pull-request URL proves only that a pull request exists.
Readiness is decided from the normalized `state`, `review`, `checks`, and `mergeable` observation described in [Normalized PR state](fleet-data-contracts.md#normalized-pr-state), and never from the presence of the URL.

The first matching rule below wins.

| Verdict | Tone | Wins when |
| --- | --- | --- |
| `none` | unknown | no PR URL is recorded |
| `merged` | green | `state: merged`, at any observation age |
| `closed` | unknown | `state: closed`, at any observation age |
| `unknown` | unknown | no observation is cached, the observation has no readable age or is older than the freshness limit, or any of the four fields is missing or `unknown` |
| `draft` | unknown | `state: draft` |
| `checks_failing` | red | `checks: failing` |
| `conflicting` | red | `mergeable: conflicting` |
| `changes_requested` | amber | `review: changes_requested` |
| `checks_pending` | amber | `checks: pending` |
| `merge_ready` | green | `checks: passing` **and** `review: approved` **and** `mergeable: mergeable` |
| `review_ready` | blue | everything else that is open and not failing |

Three consequences are deliberate.

`merge_ready` is the only green open verdict, and it requires all three fields to agree.
`checks: none` means the forge reported no checks at all, which is a definite reading but not a passing one, so it can never produce `merge_ready`; it downgrades to `review_ready` and states "no checks reported" as a caveat on the card.

Staleness is treated exactly like a missing field.
An observation older than the freshness limit described a pull request as it was, not as it is, so its verdict is withdrawn rather than shown with a caveat.
Withdrawal covers the individual fields too: a stale observation's `state`, `review`, `checks`, and `mergeable` chips all render as `unknown`, because a value the verdict above them has already disowned must not be drawn in the same confident style as one that still holds.
The limit is `POLICY.prStatusMaxAgeSeconds`, 900 seconds by default, and the age itself is always displayed next to the verdict.

`merged` and `closed` are the exception, and they are settled before the freshness gate rather than after it.
Both are monotonic, so an aged reading of either is still true, and letting age withdraw them would file every landed pull request back into the inbox as an unknown the captain can do nothing about.
Only the state itself survives that withdrawal; the other three fields of a stale terminal observation still render as `unknown`.

## Inbox items

An item is one row of work waiting on the captain, keyed by a stable identity: the task id, or the backlog id for a captain-held row with no live worker.
Overlapping signals never produce two rows.
A task with an open decision, a failing check, and a dead worker is one item carrying three reasons, and the card shows all of them.

These reasons open an item.

| Reason | Tone | Source |
| --- | --- | --- |
| `decision` | amber | an open `needs-decision` in `hints.open_decisions`, or a `captain_actionable` backlog row |
| `credential` | amber | one of the above whose own text names a credential, login, token, or authorization failure |
| `blocked` | red | an open `blocked` entry in `hints.open_decisions` |
| `failed` | red | `current_state.state` is `failed` |
| `pr_attention` | red or amber | a `checks_failing`, `conflicting`, or `changes_requested` pull request |
| `merge_ready` | green | a `merge_ready` pull request |
| `review_ready` | blue | a `review_ready` pull request |
| `pr_unknown` | unknown | a pull request whose normalized status could not be established |

`credential` is a reclassification, never a discovery.
It relabels a decision or blocker the crew already opened when that item's own text names a credential need, so a login request is visible as one instead of hiding among general blockers.
The inbox never scans prose to invent an item that the keyed status fold did not open.

A `checks_pending`, `draft`, `merged`, or `closed` pull request opens no item: it is a definite state with nothing for the captain to do.
A pull request whose status is unknown does open one, because "we cannot tell you whether this is ready" is itself something the captain needs to see.

Decision text is rendered in full and never truncated.
Pull-request links are rendered as complete `https://...` URLs, never as a bare `#number`.

### Ordering

Items sort oldest evidence first, because the longest-waiting item is the one most likely to have been forgotten.
An item whose age cannot be read sorts ahead of every dated one.
Ties break by reason severity, then by identity, so the order is stable between refreshes.

An item's age is the age of the oldest evidence supporting it, and the card names which evidence that was.
A decision that has waited three hours must not read as one minute old because its pull request was polled a minute ago.
The snapshot carries no per-decision timestamp, so a status-derived reason is aged by its task's last event (`last update`), a pull-request reason by its observation (`status observed`), and a captain-held backlog row by the date it was raised (`raised`).

That last label is deliberately not "held for".
The backlog's `since` date is written when the row is created and is not rewritten when the row goes on hold, so it says how long the item has been raised and nothing about when the hold began.
It is also day-granular rather than precise, so the age a card shows from it is an upper bound; [`docs/fleet-data-contracts.md`](fleet-data-contracts.md#snapshot-projection) owns the field and how its day start is resolved.
A row with no readable date still renders "age unknown" rather than a fabricated zero.

Ordering is the reason this matters more than the label does.
An age no item carries is an age every item ties on, and the order then collapses to reason severity and identity - which for a queue of captain decisions means alphabetical.
An inbox that cannot put the three-week-old decision above this morning's is not doing the one job an inbox has.

## Health strip

The strip carries seven signals plus one overall verdict.

| Signal | Green | Amber | Red | Unknown |
| --- | --- | --- | --- | --- |
| Snapshot | last refresh succeeded and is fresh | showing the last known good snapshot | no valid snapshot available | first snapshot has not completed |
| Supervision | beacon beating inside its grace window | past half the grace window | no beacon, or the snapshot marks it stale | beacon present with an unreadable age |
| Task activity | every working task was observed working and none of them has done nothing for the whole tolerated-quiet window, or the quietest unobserved one last did something inside half that window | past half that window, or an observed task has done nothing for the whole of it | an unobserved task is past the whole window | any working task has no readable activity age, observed or not, or the snapshot carries no window |
| Workers | every live task that has not declared a wait has its endpoint, or every live task declared one | - | an endpoint is gone on a task that declared no wait | endpoint presence unreadable on a task that declared no wait |
| Secondmates | every registered secondmate answers, or none registered | - | any secondmate agent is dead | any secondmate liveness unreadable |
| Inventory | every in-flight backlog item has a worker record | - | an orphan, or `main_inventory.valid` false | no inventory check reported |
| Away mode | off | on | - | no away-mode record |

Neither of the two windows on that table is a dashboard constant.
The watcher's grace window comes from the snapshot's own `supervision.watcher.grace_seconds`, and the tolerated-quiet window from `supervision.watcher.quiet_allowance_seconds` beside it; [`bin/fm-supervision-lib.sh`](../bin/fm-supervision-lib.sh) owns both.
A stopped watcher therefore turns red on exactly the threshold supervision itself uses, and a quiet task turns amber on exactly the one supervision itself tolerates.

Away mode is amber rather than red because it is a chosen posture, not a fault.
It still earns a colour because it changes when escalations arrive.

The snapshot answers two different questions through one endpoint field, so the strip splits them.
For a secondmate it reports whether the agent is alive, so anything short of `alive` is not a live return channel.
For every other task it reports only whether the runtime endpoint is present, so a present endpoint is the strongest true statement available and an unreadable one stays unknown.

Task activity and Workers both read live tasks only, and neither counts a secondmate.
A secondmate writes a status event only when it is asked to do something, so an idle one is healthy; counting its silence as a stalled task would drive the whole strip to "Attention needed" in a home where nothing is wrong.
Secondmates report through their own signal instead.

### What Task activity measures

Task activity asks whether any working task has gone quiet without a live reason.
It used to ask a different question - how long since the slowest task last appended to its status log - and that question has a wrong answer built into it.

The status log is a REPORTING cadence, not an activity one.
[`bin/fm-brief.sh`](../bin/fm-brief.sh) instructs every worker to append only on phase changes a supervisor would act on and explicitly not to file progress notes, so a healthy worker deep in one long step is INSTRUCTED to say nothing for a long time.
A signal that ages that log alone measures obedience and reports it as degradation, which is exactly what it did.

Two things answer for a quiet task, and either is enough.

The first is being caught in the act.
The snapshot's `current_state` is reconciled by [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh), and two of the sources it can answer with are readings taken during that refresh: `run-step`, the validation run's own current step, and `pane`, the harness's own busy verdict.
A task carrying a definite state from either was observed working, so ordinary quiet does not colour it; the one bound that still applies to it is below.
Every other source it can answer with is a memory or an absence - `run-step-degraded` replays a step a failed lookup could not re-confirm, `run-attribution` means a run was found but could not be tied to this task, `status-log` is the event log this signal already reads, and `timeout`, `not-attempted`, `row-unavailable` and `none` are readings that were not taken.
None of those excuses quiet, because the rule at the top of this page applies here too: not knowing is not the same as knowing it is fine.

The second is a completed turn.
Everything not observed working is aged on the newer of its last status append and its `paths.turn_ended` marker, which the runtime touches when a turn ends whatever the worker chooses to report.
That marker is a wake notification and an activity timestamp, never current state; [`bin/fm-watch.sh`](../bin/fm-watch.sh) owns it and already ages this exact file for the same purpose.
A task whose harness leaves no marker still ages on its status log alone, as before.

A task that has neither yet - no status line and no completed turn - is aged on `spawn_age_seconds`, how long ago it was dispatched.
That is not a third activity clock and is used only as a last resort, because a dispatch time is not an activity time.
It is here so that a task which has done nothing observable since it started still gets a bound rather than an exemption without end.
A task with no readable clock at all stays unknown, never green.

That field ages the `spawned_at` stamp recorded at dispatch, not the age of the `state/<id>.meta` file.
Firstmate rewrites that file in the course of its own work - recording a PR, flipping a kind, appending a decision review - so its mtime would reset a hung task's only clock and hand it a fresh quiet window, which is the same exemption hole in a different place.
[`docs/fleet-data-contracts.md`](fleet-data-contracts.md) owns the distinction and names the writers.
`bin/fm-watch.sh` does age the meta file for its own busy-pane bound, which is a different question it owns and answers correctly.

The window both are judged against is supervision's, not this page's.
`bin/fm-watch.sh` lets a busy pane go without a completed turn for `FM_BUSY_TURN_MAX_SECS` before treating it as worth inspecting, and that is the same question this signal asks, so the strip reads the window off the snapshot rather than holding a second opinion.
Amber is half of it, matching how Supervision treats its own grace window; red is all of it.
[`docs/verification/dashboard-fleet-health.md`](verification/dashboard-fleet-health.md) records the measurement that checks the published window is above a healthy step rather than inside one, and the 900-second constant this signal used to carry is the reason that check is written down.

The exemption a live reading buys is bounded the same way supervision bounds it.
A busy worker is excused until the newest clock it has reaches the window, not indefinitely, so a pane that renders as busy while its foreground call has hung still colours the strip - including a job that hung inside its first tool call and so has no status line and no completed turn to age at all.
The sentence the strip shows when that happens says the task has recorded no activity rather than naming a turn boundary, because the figure behind it is whichever clock was newest and attributing a status-log timestamp to a completed turn is the same conflation this signal was rebuilt to remove.
And a snapshot carrying no window at all reads unknown rather than green: without it there is no threshold to judge against, and picking one here is the defect this signal was rebuilt out of.

### Declared waits

Task activity and Workers both ask a question a declared wait answers differently, so both consult the declaration before they judge.
Task activity asks whether anything has gone quiet, and quiet a task announced is not quiet it fell into.
Workers asks whether a worker is still there, and an agent exited on purpose is not a worker that died.

A task parked on a `paused:` external wait or a captain-held transfer is counted separately by both and never coloured: Task activity leaves it out of the elapsed-time verdict, and Workers leaves it out of the endpoint counts, tallies it beside them, and names it in the card detail.
When every live task is waiting, that separate count becomes the whole value on both - "2 waiting by design" - and Task activity adds how long the longest has waited.
Without that split each signal reddens a little more every day a decision correctly sits with the captain, which is the failure that ruins a monitoring surface: it teaches the reader to ignore the badge, so the day it means something they do not look.

A declared wait is green rather than a colour of its own because the strip's colours mean "does this need you", and a declared wait does not.
What each signal needed was a value that says what it is instead of an elapsed time or an absent-endpoint count that says nothing.

Workers excludes a declared wait from its endpoint counts in both directions rather than counting it present.
Whatever that task's endpoint currently is, it is not evidence about fleet health: parking a captain-gated task exits its agent deliberately, precisely so a quiet pane does not read as a wedge.
Parking is fleet operating practice rather than a procedure this repo defines, so the signal never looks for a park at all - it reads only the declaration a park leaves in the status log.
Naming the waiting tasks rather than dropping them keeps the card honest about what it stopped counting.

The declaration is authoritative over the `data/<id>/parked.md` note a park also leaves behind.
The status declaration is what supervision acts on and what [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh) reconciles into current state, while `parked.md` is an operator note no tracked code reads, writes, or retracts - a resumed task would leave a stale one on disk, and a task parked for the captain's merge word need never have written one.

The check each strict verdict was protecting survives intact.
A task that has gone quiet without declaring it, and that nothing observed working, still drives Task activity on its own age; a worker that vanished without declaring anything still turns Workers red and is named there alone; an unreadable age or endpoint on such a task is still unknown; and a fleet with one silent task and five declared waits still reads on the silent one.

When several workers vanished at once, Workers names every one of them and phrases the qualifier to cover the whole list rather than trailing after it.
A qualifier that reads as attaching to the last name states the opposite of the truth about every other name, which would undo the one distinction this card exists to draw.

Inventory deliberately does not consult the declaration, because it never asked an endpoint question: it compares in-flight backlog rows against worker records, and a parked task keeps its record.
That is why it read green beside a red Workers card - the two were not disagreeing about the same fleet fact, one was simply wrong.

What counts as a declared wait is not decided here.
The snapshot's `hints.last_event_declared_wait` carries the verdict, [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh) owns the vocabulary behind it, and the supervision watcher asks the same library the same question - so the dashboard and supervision cannot drift into two different definitions of a pause, which is exactly how they arrived at the same wrong answer separately.
A snapshot that does not carry the field, or carries anything other than `true`, keeps the strict verdict on both signals: an unproven declaration must not excuse a silent task or a missing worker.

### Overall verdict

The overall verdict is the worst signal present, ranked `red` > `amber` > `unknown` > `green`.
`unknown` outranking `green` is the point: a fleet with a reading it could not take is never summarized as "Healthy". It reads "Partly unknown".

When the snapshot signal is itself amber or red, every other signal better than red is demoted to unknown, because those readings were true at the last successful refresh and are unverified now.
Red readings survive the demotion: an old alarm is still an alarm.

## Badges and alerts

The header shows one badge per non-empty inbox category and the sidebar shows the total.
When nothing is outstanding the header says so in words rather than showing an empty row.
One badge covers every attention state at once - a reported failure, failing checks, a conflict, or requested changes - and is labelled "Needs attention" rather than "Failing", because requested changes are amber and calling them a failure overstates them.

Desktop alerts are entirely client-side and off by default.
The toggle requests browser notification permission on click and nothing else; the server never learns that a browser wants them, and a denied or unsupported permission leaves the control off without affecting anything else on the page.
The choice is remembered in that browser's own local storage and restored on the next load only while the browser still grants permission, so it stays a per-browser preference rather than a fleet setting.
The first render that actually carries a fleet snapshot establishes the baseline, so alerts fire only for items that appear afterwards.
A first-run or unavailable render is skipped rather than treated as an empty baseline, because doing otherwise would alert on every item that was already waiting.

## Verification

```
$ bash tests/fm-dashboard-inbox.test.sh
$ bash tests/fm-dashboard.test.sh
$ bash tests/fm-fleet-snapshot-view.test.sh
```

The third pins the snapshot fields this policy reads but does not decide: the backlog row's `since_age_seconds`, a task's `hints.last_event_declared_wait`, and the bounded per-task read behind every one of them.
[`verification/dashboard-fleet-health.md`](verification/dashboard-fleet-health.md) records the measurements behind the tolerated-quiet window and the snapshot's own read bounds.
