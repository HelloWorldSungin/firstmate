# Dashboard fleet-health verification

Repeatable evidence for the two numbers behind the dashboard's fleet health strip: how long a working task may be quiet before the strip says so, and how long the fleet snapshot behind it may take.
Current behavior is owned by [`../dashboard-inbox-policy.md`](../dashboard-inbox-policy.md), the snapshot contract by [`../../bin/fm-fleet-snapshot.sh`](../../bin/fm-fleet-snapshot.sh)'s header, and the quiet window itself by [`../../bin/fm-supervision-lib.sh`](../../bin/fm-supervision-lib.sh); this page records evidence only.

Date: 2026-08-12.
Host: Linux 6.14.11, GNU bash 5.x, 9 to 10 live task records in the observed home.
Comparison base: `main` at `0bc0f95`.

## How long a healthy task stays quiet

The strip used to age a task on its status log alone, amber past 900 s.
That measures a REPORTING cadence: `bin/fm-brief.sh` instructs every worker to append only on phase changes a supervisor would act on, so the number had to be justified against how long a healthy worker legitimately says nothing.

The fleet's own token-usage store records one row per agent turn with its epoch, so the gap between consecutive turns of one session is a direct measurement of how long a single agent step runs - the floor under any status-log quiet, because a status line can only be appended between steps.
Over 4072 consecutive-turn gaps across 34 crew tasks in `data/usage.db`, discarding gaps over an hour as session resumptions rather than steps:

| Percentile | Gap |
| --- | --- |
| p50 | 10 s |
| p90 | 37 s |
| p95 | 89 s |
| p99 | 639 s (10.7 min) |
| p99.5 | 991 s (16.5 min) |
| p99.9 | 2358 s (39.3 min) |
| max | 3039 s (50.6 min) |

52 gaps exceeded 600 s, 26 exceeded 900 s, and 10 exceeded 1800 s.
The old 900 s threshold therefore sat at roughly the 99.4th percentile of a SINGLE agent step, before the "report sparingly" instruction that makes real quiet a sum of many steps.

Reproduce with a read-only query against the store; `bin/fm-usage.mjs` owns the schema:

```console
$ node -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync(process.argv[1],{readOnly:true});
const rows=db.prepare("select task_id,harness,session_id,occurred_epoch from usage_event where task_id is not null order by task_id,harness,session_id,occurred_epoch").all();
const g=[];let p=null;
for(const r of rows){const k=`${r.task_id} ${r.harness} ${r.session_id}`;
  if(p&&p.k===k){const d=Number(r.occurred_epoch)-p.e; if(d>0&&d<=3600)g.push(d);} p={k,e:Number(r.occurred_epoch)};}
g.sort((a,b)=>a-b);const q=x=>g[Math.floor((g.length-1)*x)];
console.log(g.length,q(0.99),q(0.999),g[g.length-1]);
' ~/firstmate/data/usage.db
4072 639 2358 3039
```

Firstmate already had an owned answer to this question, and it is above every one of those measurements.
`FM_BUSY_TURN_MAX_SECS` (3600 s) is how long `bin/fm-watch.sh` lets a busy pane go with no completed turn before routing it to wedge escalation, and [`../configuration.md`](../configuration.md) records that the same hour is what `FM_PAUSE_RESURFACE_SECS` and `FM_RUN_PROGRESS_HOLD_MAX` allow a live-but-quiet endpoint.
The strip therefore reads that window out of the snapshot instead of carrying a fourth number: `bin/fm-supervision-lib.sh` owns it, `supervision.watcher.quiet_allowance_seconds` publishes it, and the measurements above are the independent check that the window it publishes is above a healthy step rather than inside one.

## What the snapshot's runtime is spent on

`bin/fm-dashboard-server.mjs` bounds every snapshot at `FM_DASHBOARD_TIMEOUT_SECONDS`, 15 s by default.
Three consecutive runs against the live home at 10 task records, on `main` at `0bc0f95`:

```console
$ for i in 1 2 3; do /usr/bin/time -f "run $i: %e s" \
    env FM_HOME=~/firstmate bash bin/fm-fleet-snapshot.sh --json >/dev/null; done
run 1: 14.65 s
run 2: 7.80 s
run 3: 14.62 s
```

Per-task endpoint liveness was the obvious suspect and is not the cost.
A timestamped trace attributes the runtime to one `bin/fm-crew-state.sh` call per task record, which the snapshot made one after another:

```console
$ PS4='+ ${EPOCHREALTIME} ${BASH_SOURCE##*/}:${LINENO}: ' \
    FM_HOME=~/firstmate bash -x bin/fm-fleet-snapshot.sh --json >/dev/null 2>trace.txt
$ perl -ne 'if (/^\++ (\d+\.\d+) (\S+): (.*)$/) { if (defined $pt) { my $d=$1-$pt;
    printf("%.3f  %s\n",$d,substr($pc,0,70)) if $d>0.5 } ($pt,$pc)=($1,$3); }' trace.txt | sort -rn
6.805  bin/fm-crew-state.sh arkstudio-pricing-review-fable
1.615  bin/fm-crew-state.sh fm-dashboard-fleet-health-truth
1.585  bin/fm-crew-state.sh bzsim-610-failing-timing-quarantine
0.808  bin/fm-crew-state.sh fm-procevent-retire-missing-artifact
0.805  bin/fm-crew-state.sh fm-pr-status-gh-axi-json
0.804  bin/fm-crew-state.sh hermes-vault-refresh
```

12.4 s of a 14.6 s run, in one call per task; every endpoint read fell below the 0.15 s reporting floor.
The single 6.8 s outlier is the bimodality in the timings above: `fm-crew-state.sh` bounds its own no-mistakes lookup at 10 s, and a saturated daemon pushes one call toward that bound.

Those calls are independent, and running them together costs no more than the slowest one - the no-mistakes daemon showed no saturation penalty at 10 concurrent lookups:

```console
$ # all 10 crew-state reads at once, three times
parallel run 1: 1.64 s
parallel run 2: 1.63 s
parallel run 3: 1.62 s
$ # the same 10 reads one after another, three times
serial   run 1: 4.22 s
serial   run 2: 5.72 s
serial   run 3: 5.71 s
```

## Result

Before and after on the same fleet, one minute apart, 9 task records:

```console
$ git stash push -q && bash beforeafter.sh before; git stash pop -q && bash beforeafter.sh after
before run 1: 7.88 s
before run 2: 7.92 s
before run 3: 7.97 s
after run 1: 3.10 s
after run 2: 3.07 s
after run 3: 3.10 s
```

`FM_SNAPSHOT_TASK_JOBS` defaults to 8: measured per-task cost is under 1.7 s in the common case, so eight at a time clears a fleet of that size in one window, and the fan-out refills oldest-first so one slow task delays only itself.
`FM_SNAPSHOT_TASK_TIMEOUT` defaults to 8 s: it is above the 6.8 s worst per-task cost observed under a saturated daemon, and it bounds the tail so that a snapshot whose slowest task hits the bound still lands near 10 s rather than losing everything at 15 s.
A task that hits it reports `current_state.state: "unknown"` with `source: "timeout"`, which is why one unreadable task now costs its own row instead of the whole fleet view.
That bound runs through `bin/fm-timeout-lib.sh`, the declared owner of bounded external execution, rather than this script's older local helper: only the owner escalates to `SIGKILL` after the polite signal, and a per-task deadline a wedged child can outlive by ignoring `SIGTERM` is not a deadline.
The owner also distinguishes a bound that elapsed (124 or 137) from a runner that could never start (125), so the second case reports `source: "not-attempted"` instead of claiming a timeout that was never reached.

### Why the inner lookup bound is 3 s below the outer one

`fm-crew-state.sh` bounds its own no-mistakes lookup at `FM_CREW_STATE_NM_TIMEOUT`, 10 s by default, and answers a lookup that fails with a bounded `run-step-degraded` replay of the last recorded step.
With the outer bound at 8 s and the inner at 10 s the outer always fires first, so that designed answer was unreachable from the snapshot: under exactly the saturated-daemon load measured above, a task that would have answered `working` degraded instead came back `unknown` with `source: "timeout"`, dropped out of the live-evidence sources the strip trusts, and was aged on its status log - which for an obediently quiet worker past the window is the reported defect returning.

The fix is the ORDERING, and it is corrected by lowering the inner bound rather than widening the outer one, so the dashboard's budget is untouched: the outer per-task bound is still 8 s and the runtime figures above still hold.
Making the degraded fallback reachable and staying inside the budget therefore do not conflict here.
The snapshot passes `FM_CREW_STATE_NM_TIMEOUT` to the child derived from its own bound, `max(1, FM_SNAPSHOT_TASK_TIMEOUT - 3)`, which is 5 s at the default, so retuning the outer bound cannot silently invert the two again.
`FM_SNAPSHOT_TASK_TIMEOUT` is refused below 2 for the same reason: at an outer bound of 1 the derivation's floor of 1 would equal it rather than sit inside it, which is the very arrangement this derivation exists to prevent, and the refusal is explicit rather than a silent clamp.

The 3 s of headroom cover `fm-crew-state.sh`'s non-lookup work, measured under a second on this fleet: the whole call costs 0.00-0.06 s for a task that never reaches the daemon and 0.80-1.61 s for one that does, per the per-task trace above.
A healthy lookup is nowhere near the lowered bound - `FM_CREW_STATE_NM_TIMEOUT=5` answered correctly in 0.80 s against a live task - so only a pathological lookup reaches it, and there the degraded replay is a better answer than the outer bound's `unknown`.

One corner is deliberately left as it is, recorded here so the next reader does not have to rediscover it.
A single `fm-crew-state.sh` invocation can make two bounded lookups - an `axi status` call, and a `runs --limit` scan when the first answered without attributing a run - so the worst case is roughly twice the inner bound plus overhead, about 10 s against the 8 s outer bound.
That corner does not reach the degraded replay, and it degrades to the pre-existing `timeout` row rather than to anything new.
It is not the path this derivation is about: the saturated-daemon path measured above is single-call by design, because `fm-crew-state.sh` deliberately skips the second lookup when the primary one timed out, so the degraded replay is genuinely reachable exactly where the load that motivated this change puts it.

## Regression coverage

```console
$ bash tests/fm-fleet-snapshot-view.test.sh | tail -2
ok - per-task reads run concurrently, so a fleet-sized snapshot stays inside half its budget
ok - one unreadable task reports unknown with a timeout source and the rest of the snapshot survives
$ bash tests/fm-dashboard-inbox.test.sh | tail -1
ok - health signals produce the documented states and never summarize uncertainty as healthy
```

The concurrency case asserts against half of the dashboard's 15 s deadline rather than all of it, so the test fails while there is still headroom instead of at the moment the view already breaks.
It drives 12 task records through a stand-in current-state reader that costs a known second each: 12 s serially against a 7 s ceiling, about 2 s concurrently.
Both halves of that arithmetic are asserted, so the case cannot pass by being cheap.
Confirming it bites:

```console
$ FM_SNAPSHOT_TASK_JOBS=1 bash tests/fm-fleet-snapshot-view.test.sh | tail -1
not ok - a 12-task snapshot took 13s, past 7s (half the 15s the dashboard allows it); the per-task reads are summing again
```

The activity cases assert that a task quiet for 40 minutes reads green when either the snapshot observed it working or its runtime completed a turn recently.
Against the module as it shipped, both read amber and the fleet read Degraded, which is the reported defect.

Five further cases cover the bounds themselves rather than the numbers.

`a per-task read that ignores SIGTERM is killed inside its bound` drives a stand-in reader that ignores `SIGTERM` and `exec`s into a 30 s sleep, so only the kill escalation can end it; it fails if the per-task bound stops escalating to `SIGKILL`.
The existing timeout case cannot see that, because `sleep` dies politely.

`the child's lookup bound is derived from the per-task bound and stays strictly inside it` has the stand-in report the `FM_CREW_STATE_NM_TIMEOUT` it was handed, and asserts 5 s at the default, 9 s when the outer bound is raised to 12 s, and the 1 s floor at the smallest legal outer bound of 2 s - plus that an outer bound of 1 is refused outright.
It fails if the inner bound stops being derived from the outer one, or if the invariant holds only at the comfortable values, which is how the equal-at-the-minimum case got through the first probe set.

`a task whose reader failed is still listed, as an explicit unknown rather than absent` makes one task's reader die before the jq that prints its row, and asserts the task COUNT as well as the row's contents - a case inspecting only the rows present cannot see a missing one.
It fails if the collector stops reconciling the ids it launched against the rows it got back.

`the collector adds no per-task cost of its own` drives 48 task records through a stand-in reader that costs nothing, so the only thing being measured is what the collector spends per row rather than the stand-in's own sleep.
The size is chosen: at the ~10 ms a jq process per row costs, 48 rows is roughly half a second of purely serial overhead and is measurable against a stated fraction of the budget, while the 12-record concurrency case pays about a tenth of a second and cannot see it.
It fails if per-task work is added back to the collector, whether or not that work is a jq process.
The 12-record case stays exactly what it was, the concurrency test.

`the spawn clock comes from the recorded stamp, not the meta file's mtime` fails if the clock the activity signal falls back to stops being published, or if it goes back to ageing `state/<id>.meta` - which it asserts by touching that file and requiring the published age not to move.
Its dashboard half is the pair asserting that a busy task with no status line and no completed turn colours the strip once its dispatch passes the window and stays green inside it.

## Updated reproduction, 2026-08-12

On 2026-08-12 a trailing completion marker was added to these suites by this change, so the positional `tail` commands recorded above no longer select the same lines.
The cases below are selected by name from a current rerun.

```console
$ bash tests/fm-fleet-snapshot-view.test.sh | grep -E '^ok - (per-task reads run concurrently|one unreadable task reports unknown)'
ok - per-task reads run concurrently, so a fleet-sized snapshot stays inside half its budget
ok - one unreadable task reports unknown with a timeout source and the rest of the snapshot survives
$ bash tests/fm-dashboard-inbox.test.sh | grep -E '^ok - health signals produce'
ok - health signals produce the documented states and never summarize uncertainty as healthy
```

`fail` reports on stderr and exits there, so the failing-case command merges stderr into the pipe:

```console
$ FM_SNAPSHOT_TASK_JOBS=1 bash tests/fm-fleet-snapshot-view.test.sh 2>&1 | tail -1
not ok - a 12-task snapshot took 13s, past 7s (half the 15s the dashboard allows it); the per-task reads are summing again
```
