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
It is also a local date with no clock time, so its age runs from that day's local midnight and is an upper bound at day granularity; [`docs/fleet-data-contracts.md`](fleet-data-contracts.md#snapshot-projection) owns that field.
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
| Task activity | slowest live task that has not declared a wait reported within 900s, or every live task declared one | within 3600s | past 3600s | a live task that has not declared a wait has no readable event age |
| Workers | every live task's endpoint is present | - | any live task's endpoint is gone | any endpoint presence unreadable |
| Secondmates | every registered secondmate answers, or none registered | - | any secondmate agent is dead | any secondmate liveness unreadable |
| Inventory | every in-flight backlog item has a worker record | - | an orphan, or `main_inventory.valid` false | no inventory check reported |
| Away mode | off | on | - | no away-mode record |

The watcher's grace window is not a dashboard constant: it comes from the snapshot's own `supervision.watcher.grace_seconds`, which [`bin/fm-supervision-lib.sh`](../bin/fm-supervision-lib.sh) owns.
A stopped watcher therefore turns red on exactly the threshold supervision itself uses.

Away mode is amber rather than red because it is a chosen posture, not a fault.
It still earns a colour because it changes when escalations arrive.

The snapshot answers two different questions through one endpoint field, so the strip splits them.
For a secondmate it reports whether the agent is alive, so anything short of `alive` is not a live return channel.
For every other task it reports only whether the runtime endpoint is present, so a present endpoint is the strongest true statement available and an unreadable one stays unknown.

Task activity and Workers both read live tasks only, and neither counts a secondmate.
A secondmate writes a status event only when it is asked to do something, so an idle one is healthy; counting its silence as a stalled task would drive the whole strip to "Attention needed" in a home where nothing is wrong.
Secondmates report through their own signal instead.

### Declared waits

Task activity asks whether anything has gone quiet, and quiet a task announced is not quiet it fell into.
A task parked on a `paused:` external wait or a captain-held transfer is counted separately, never aged into amber or red, and reported as its own reading - "2 waiting by design", with how long the longest has waited.
Without that split the signal reddens a little more every day a decision correctly sits with the captain, which is the failure that ruins a monitoring surface: it teaches the reader to ignore the badge, so the day it means something they do not look.

A declared wait is green rather than a colour of its own because the strip's colours mean "does this need you", and a declared wait does not.
What it needed was a value that says what it is instead of an elapsed time that says nothing.

The check the elapsed-time verdict was protecting survives intact.
A task that has gone quiet without declaring it still drives the signal on its own age, an unreadable age on such a task is still unknown, and a fleet with one silent task and five declared waits still reads on the silent one.

What counts as a declared wait is not decided here.
The snapshot's `hints.last_event_declared_wait` carries the verdict, [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh) owns the vocabulary behind it, and the supervision watcher asks the same library the same question - so the dashboard and supervision cannot drift into two different definitions of a pause, which is exactly how they arrived at the same wrong answer separately.
A snapshot that does not carry the field, or carries anything other than `true`, keeps the strict elapsed-time verdict: an unproven declaration must not excuse a silent task.

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

The third pins the two snapshot fields this policy reads but does not decide: the backlog row's `since_age_seconds` and a task's `hints.last_event_declared_wait`.
