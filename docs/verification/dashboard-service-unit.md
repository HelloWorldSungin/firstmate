# Verification: the generated dashboard systemd unit

Why this record exists: a systemd unit fails in a way `systemctl status` reports as green.
A directive systemd read past leaves a service that starts, stays active, and runs on defaults it was never configured with.
The guarantee under test is that `bin/fm-dashboard-install.sh` emits directives systemd actually accepts, preserves installed operator-facing values during a repair, restarts after clean or failed exits, and refuses to report success unless systemd reads the generated contract back and the service stays running.

Refresh with `bin/fm-test-run.sh tests/fm-dashboard-access.test.sh tests/fm-dashboard.test.sh`, which pin the portable half without systemd: the first covers the quoting and path forms systemd accepts, the second the hardening directives the unit must carry and the ones it must not.
The observations below need a systemd host and are what those portable suites cannot prove.

## The four 2026-08-12 reliability sequences

Date: 2026-08-12.
These separations record the current causal boundary for each measured defect rather than treating its containment as its diagnosis.

### A clean exit left the service down

Reproduction: the dashboard process terminated with status 0 while the installed unit used `Restart=on-failure`, after which the unit stayed inactive and the dashboard stopped answering HTTP.
The initiating trigger at the service boundary was the status-0 process termination.
The masking condition was that the old server logged neither the handled-signal path nor an unexpected event-loop drain, so the successful exit status did not identify what initiated the termination.
The visible symptom was a cleanly inactive service and an unreachable dashboard until an operator restarted it.
The initiating cause of that clean exit was not found.
The available evidence does not distinguish an external stop or handled signal from an unexpected event-loop drain or another explicit exit path.
The server now names handled signals and converts an unexpected event-loop drain to failure, which makes a recurrence attributable, but neither change retroactively diagnoses the 2026-08-12 exit.
`Restart=always` independently contains any future clean exit and is not evidence for, or a substitute for, the missing initiating cause.

### A slow snapshot kept the poller continuously busy

Reproduction: a snapshot with a 150 ms deadline ran across the 100 ms poll interval, and a poll arrived before that attempt completed.
The initiating trigger was the fixed interval firing while a previous snapshot attempt was still in flight.
The masking condition was a fleet whose snapshots completed inside the interval, because that timing never exercised the pending catch-up path.
The old `refreshing` guard prevented two snapshot children from running literally at once, but its `pending` bit launched another attempt immediately on completion, so the overlapping schedule appeared serialized while it removed every idle gap.
The visible symptom was back-to-back snapshot work and sustained CPU rather than one refresh followed by the configured interval.
A trigger arriving mid-snapshot now queues no catch-up attempt, callers continue to receive the current envelope, and the next routine poll starts one full interval after completion.

### New server code ran under an old unit

Reproduction: a server identified as `firstmate-dashboard.service` and carrying `INVOCATION_ID`, but lacking the generated `runtime-scratch-v1` marker, had no writable `TMPDIR` and previously reached a child command before exposing that mismatch.
The initiating trigger was deploying current server code without reinstalling the already-loaded unit that predated `RuntimeDirectory=` and `TMPDIR=`.
The masking condition was that systemd kept the old unit active and commands that did not need a temp file continued to work, so the missing grant appeared only when a snapshot path first needed scratch space.
The visible symptom was a raw `mktemp` or read-only-filesystem failure instead of an installation diagnosis.
The server now refuses to start polling under that stale installed contract and reports `rerun bin/fm-dashboard-install.sh` as the repair.
On systemd versions that provide `SYSTEMD_EXEC_PID`, the server requires it to match its own process id.
On older versions, the exact `firstmate-dashboard.service` component in `/proc/self/cgroup` supplies the same unit-specific boundary across legacy and unified cgroup formats.
An inherited `INVOCATION_ID` from an unrelated parent service therefore does not make a stand-alone dashboard process claim the installed-unit contract.
That repair preserves the installed address and trusted proxies unless explicit environment values or flags replace them.

### Missing snapshot data falsely condemned supervision

Reproduction: rendering an unavailable envelope with a null snapshot supplied no `supervision.watcher` object to the health builder.
The initiating trigger was the missing fleet snapshot, not a stopped watcher.
The masking condition was that the old watcher classifier treated an absent watcher record as equivalent to an explicit `{ "present": false }` reading, while red readings survived the unavailable-snapshot demotion.
The visible symptom was a red supervision value of `not running` even though no watcher observation had been made.
This false supervision verdict was downstream of the missing snapshot.
An absent watcher record now reports `unknown`, while an explicit `present: false` record still reports `not running`.

Portable regression command:

```console
$ bin/fm-test-run.sh tests/fm-dashboard.test.sh tests/fm-dashboard-inbox.test.sh
...
all fm-dashboard tests passed
...
all fm-dashboard-inbox tests passed
```

## Which quoting systemd accepts

Host: Ubuntu container, `systemd 255 (255.4-1ubuntu8)`, user manager.
Date: 2026-08-05.

Two throwaway user units were written, differing only in whether their path arguments were quoted, then read back through `systemctl --user show`.

```
$ systemctl --user show -p EnvironmentFiles --value fm-probe-quoted.service

$ systemctl --user show -p EnvironmentFiles --value fm-probe-unquoted.service
/home/…/.config/firstmate/dashboard.env (ignore_errors=no)

$ journalctl --user | grep 'not absolute'
… fm-probe-quoted.service:5: EnvironmentFile= path is not absolute, ignoring: "/home/…/.config/firstmate/dashboard.env"

$ systemctl --user show -p ReadWritePaths --value fm-probe-quoted.service
-/home/…/.local/state/firstmate/dashboard-events/…
$ systemctl --user show -p ReadWritePaths --value fm-probe-unquoted.service
-/home/…/.local/state/firstmate/dashboard-events/…
```

`EnvironmentFile=` takes a single path argument and does not accept a quoted one: the whole directive is dropped with one log line, and every variable the file carried silently becomes its default.
`ReadWritePaths=` is a list and does accept quoting; both forms resolve to the same grant on this version.

Only the first is load-bearing, and it is enough on its own to leave a dashboard configured with none of its settings.
The installer emits every path unquoted and refuses at generation time any path that would need quoting, so the two directives cannot diverge in behavior again.

## That the write grant is real under the unit's sandbox

The unit runs under `ProtectSystem=strict` and `ProtectHome=read-only` with narrow `ReadWritePaths` grants, and this probe covers the agent-event one; the unit's other grant, for this home's own brain directory, has its own control below, and [dashboard-events.md](../dashboard-events.md) owns why the dashboard has any write grant inside an operational home at all.
Probed with transient units carrying the same protections, on the same host and date:

```
with the unit's grant   : WRITABLE
without the grant       : REFUSED
```

The control matters: without it, a pass proves only that the directory is writable somewhere, not that the grant is what makes it writable inside the sandbox.

## That the pinned PATH is what makes the fleet snapshot work

The user manager gives a service a minimal PATH, and the fleet snapshot shells out to tools installed under the operator's own bin directories.

Before this change the unit set no PATH at all (`systemctl --user show -p Environment` returned empty).
Every snapshot ran to its 15-second deadline and the dashboard served HTTP 200 with `"phase": "unavailable"` and a null snapshot - a dashboard reporting itself healthy while showing nothing.

After, on the same host and date:

```
$ systemctl --user show -p Environment firstmate-dashboard.service
Environment=PATH=/home/…/.nix-profile/bin:/home/…/.npm-global/bin:/home/…/.local/bin:…

$ curl -s -u captain:… http://…:8787/api/snapshot | jq '{phase:.status.phase, error:.status.error, tasks:(.snapshot.tasks|length)}'
{"phase": "ready", "error": null, "tasks": 5}
```

The PATH gap was independent of the quoting defect: the previous installer wrote no PATH anywhere, so fixing the environment file alone would have left the empty view in place.

## That the read-only store opener needs no scratch path

The hardened unit pairs `ProtectSystem=strict` with `ProtectHome=read-only`, and at this date granted no writable scratch path of its own.
Together they make the whole system hierarchy read-only (including `/tmp`, `/var/tmp`, and `/usr/tmp`) and `$HOME` read-only, so SQLite has no writable path left for the temp file a read-only query needs.
Node bundles SQLite with `SQLITE_TEMP_STORE=1`, which means file-backed temp storage by default, so the token-usage collector exits `disk I/O error` while `data/usage.db` is healthy and reads cleanly from an ordinary shell.
Neither protection alone breaks it, which is why the defect survived earlier investigation.

Host: `systemd 255` user manager, Node v22.22.2, SQLite 3.50.4, against a 37 MB `data/usage.db` in `delete` journal mode.
Date: 2026-08-08.
Command: the production invocation, `bin/fm-usage.mjs report --by task --limit 500 --home /home/sungin/firstmate`, run through `systemd-run --user --pipe --wait --collect --property=<row>`.

| Sandbox                                                                 | Result   |
| ---                                                                     | ---      |
| `ProtectHome=read-only`                                                 | passes   |
| `ProtectSystem=strict`                                                  | passes   |
| `ProtectSystem=strict` + `ProtectHome=read-only` + `PrivateDevices=yes` | **fails** - `fm-usage: disk I/O error`, exit 1 |
| the same, after `PRAGMA temp_store = MEMORY` in the read-only opener    | passes   |

```console
$ systemd-run --user --pipe --wait --collect \
    --property=ProtectSystem=strict --property=ProtectHome=read-only --property=PrivateDevices=yes \
    node bin/fm-usage.mjs report --by task --limit 500 --home /home/sungin/firstmate
fm-usage: disk I/O error
Main processes terminated with: code=exited/status=1

$ systemd-run --user --pipe --wait --collect \
    --property=ProtectSystem=strict --property=ProtectHome=read-only --property=PrivateDevices=yes \
    node bin/fm-usage.mjs report --by task --limit 500 --home /home/sungin/firstmate \
  | jq -c '{schema, rows: (.rows|length), first: .rows[0].key, events: .rows[0].events}'
{"schema":"fm-usage-report.v1","rows":15,"first":"(unattributed)","events":62751}
```

Both rows are the same command against the same live store under the same sandbox; the only difference is whether `bin/fm-telemetry-store.mjs` sets `PRAGMA temp_store = MEMORY` on its `readOnly` open.
The fix goes in the reader rather than in the unit because that is the only place it holds everywhere: a stand-alone collector run outside the unit, a unit a later hardening pass edits, and a drop-in that overrides one all get the same guarantee, and a reader that never asks the filesystem for scratch space cannot be denied it.

## That the missing scratch directory was one cause under two panels

Host: `systemd 255` user manager, bash 5.2.21, Node v22.22.2.
Date: 2026-08-11.

Two panels reported a false absence at the same time, and they had one cause.
The semantic-search panel rendered "No corpus answered the search.: command exited 3" because `bin/fm-recall.sh` calls `mktemp`.
The History panel rendered "Nothing has completed in this home" over 61 completion records, which was less obvious: bash needs a temp file for any here-document or here-string larger than a pipe buffer, `fm_outcome_history_json` projected its records through `done <<<"$ordered"`, and with no writable temp the loop was fed nothing.

The mechanism, probed with a script that reads a small and a large here-string under the unit's own protections:

```console
$ # TMPDIR at a bad path, shared /tmp writable
TMPDIR=/proc/self/nonexistent writable=no
small here-string lines read: 1
large here-string lines read: 1

$ # ProtectSystem=strict + ProtectHome=read-only + PrivateDevices=yes, no grant
TMPDIR=<unset> writable=no
small here-string lines read: 1
probe.sh: line 12: cannot create temp file for here-document: Read-only file system
large here-string lines read: 0

$ # the same, plus RuntimeDirectory= and a TMPDIR pointing at it
TMPDIR=/run/user/1004/fm-tmp-probe writable=yes
small here-string lines read: 1
large here-string lines read: 1
```

The first row is why pointing `TMPDIR` at a bad path never detects this: bash validates `TMPDIR` and falls back to `/tmp` when it is unusable, so that test passes whether or not the code needs a temp file.
Only denying the whole hierarchy reproduces it, and the third row shows bash does honor a `TMPDIR` that works.
The small/large split is why it stayed hidden: the same code path is correct until a home accumulates enough records to cross the pipe buffer.

The record count under the real restrictions, the only difference between the two runs being the grant:

```console
$ systemd-run --user --pipe --wait --collect \
    --property=ProtectSystem=strict --property=ProtectHome=read-only --property=PrivateDevices=yes \
    --setenv=PATH=<the unit's pinned PATH> --setenv=FM_HOME=/home/sungin/firstmate \
    bin/fm-outcome-manifest.sh list --limit 500
bin/fm-outcome-lib.sh: line 1042: cannot create temp file for here-document: Read-only file system
{"total":61,"shown":0,"records":0,"malformed":0}   # exit 0

$ # the same, plus --property=RuntimeDirectory=… --setenv=TMPDIR=…
{"total":61,"shown":61,"records":61,"malformed":0}
```

Exit 0, `malformed` empty, and `total` disagreeing with `shown` by 61: the panel was given no signal it could act on, which is why it rendered the never-had-any empty state.

Confirmed against running dashboards rather than a shell, each under the unit's protections on its own loopback port:

| Instance | History | Semantic search |
| --- | --- | --- |
| pre-fix code, no grant | `phase: ready`, `total: 61`, `shown: 0` - "Nothing has completed in this home" | HTTP 503 `no_corpus_answered`, "command exited 3" |
| fixed code, with grant | `total: 61`, `shown: 61` - "1-25 of 61 completed records" | HTTP 200, 4 results, local source `ok` |
| fixed code, brain grant but no scratch grant | unaffected | HTTP 503 `search_setup_failed`, "mktemp: failed to create file … Read-only file system" |

The third row is the point of `bin/fm-recall.sh`'s exit 5: the same environment fault that used to read as a verdict about the brain now names itself, and the panel says "The search could not start, so nothing was asked of the brain."

The history read is fixed in the library as well as in the unit, and deliberately so.
`fm_outcome_history_json` documents itself as free of temp files because `bin/fm-fleet-snapshot.sh` runs it under hermetic restricted paths, and here-strings were quietly breaking that promise.
With process substitution instead, the read returns all 61 records under the hardened restrictions with no grant at all - so the guarantee no longer depends on the unit, and the unit's grant is what the panels that genuinely need scratch space spend.

## That the brain grant is what lets a search open the index

The unit's second `ReadWritePaths` grant is the operational home's `data/gbrain/`, and this is its control.
Both rows are on the host and date above, each a separate dashboard instance under the unit's protections on its own loopback port, identical but for that one grant; the scratch grant is present in both, so `mktemp` is not what either row measures.

| Instance | Semantic search |
| --- | --- |
| with the brain grant | local source `ok`, 3 results |
| without the brain grant | local source `failed`, 0 results - "GBrain: Timed out waiting for PGLite lock. Remove /home/sungin/firstmate/data/gbrain/pglite/.gbrain-lock and try again." |

That names the proximate mechanism: GBrain writes a lock file under `pglite/` before it can open the database at all, so the grant is needed for the lock before any of the index writes that follow it.
Those index writes are the deeper reason for the grant and are pinned in [gbrain-retrieval.md](gbrain-retrieval.md), and [../gbrain.md](../gbrain.md#archive-backup-and-rebuild) owns what a writing search means for a backup.

## That a search that never started is reported separately

`bin/fm-recall.sh` exit 3 means every requested corpus was asked and none answered, which a panel may render as a statement about the brain.
Exit 5 means no corpus was ever asked.
`tests/fm-recall.test.sh` pins all three outcomes together - setup failure, a corpus that was asked and refused, and a corpus that was read and had no match - because the distinction is only worth anything if the other two still hold.
Above the wrapper, `tests/fm-dashboard-gbrain.test.sh`'s `test_search_separates_a_search_that_never_started_from_one_no_corpus_answered` pins exit 5 to HTTP 503 `search_setup_failed` and exit 3 to HTTP 503 `no_corpus_answered` against the live endpoint, and `tests/fm-dashboard-gbrain-ui.test.sh` pins the label the operator reads and its red tone.
The tone is red rather than amber because the amber reasons all mean "wait and try again", and a search that cannot start will not start on a retry.

## That a lost history read cannot render as an empty fleet

`fm_outcome_history_json` refuses when records were counted off disk and none reached the result, and says so on stderr, naming how many records it counted and where.
A refusal that only exited non-zero would move the false absence rather than remove it: the operator would read `history_refresh_failed: command exited 1` and still not know a read had been lost.
`tests/fm-outcome-manifest.test.sh`'s `test_history_refuses_to_report_a_lost_read_as_an_empty_fleet` injects the fault rather than reproducing it, since the here-string is gone, and was confirmed to fail with the check removed.

Against a running dashboard with that fault injected, the panel renders "No history yet" under a red "Completed-work history unavailable" notice, whose copy reads "this list is empty because nothing has been read, not because nothing has finished".
The three genuine empty states were each demonstrated on their own instance and still render: a home with no completions says "Nothing has completed in this home", 61 records under a filter matching none say "Nothing matches these filters", and the read that did not land says "No history yet".

Note, 2026-08-16: the router rebuild rewrote the empty-state copy quoted in the two observations above, so read those strings as the copy of their own date.
A failed read now renders "Delivered work cannot be read." under the same red "Completed-work history unavailable." notice, a home with no completions renders "Nothing delivered yet.", and a filter matching none renders "Filtered to nothing.".
The distinction those runs were evidence for - a read that was lost never rendering as a fleet that delivered nothing - is what survives, and [`../dashboard.md`](../dashboard.md#history) owns the History page that renders it.

## That the fix is not bought with the fleet view

`PrivateTmp=yes` clears the same failures by giving the service a private writable `/tmp`, and it is the obvious reach, so the reason the unit does not use it is recorded here rather than left to be rediscovered.
`RuntimeDirectory=` is what the unit grants instead: it adds a writable directory without replacing `/tmp`, so the socket below stays reachable.

It replaces the shared `/tmp` with a private tmpfs, and the fleet's tmux server socket lives at `/tmp/tmux-$UID`.
`bin/fm-fleet-snapshot.sh` runs inside the service's namespace and probes endpoints through `fm_backend_target_exists` and `fm_backend_capture`, both of which shell out to `tmux`.
With the socket gone every probe fails, `endpoint_exists` comes back false, and the dashboard's primary view draws `endpoint absent` on every live tmux task while terminal evidence degrades to `terminal capture unavailable`.

```console
$ tmux -L fmverify new-session -d -s dashboard-probe 'sleep 120'

$ systemd-run --user --pipe --wait --collect \
    --property=ProtectSystem=strict --property=ProtectHome=read-only --property=PrivateDevices=yes \
    tmux -L fmverify ls
dashboard-probe: 1 windows (created Sat Aug  8 01:47:36 2026)

$ systemd-run --user --pipe --wait --collect \
    --property=ProtectSystem=strict --property=ProtectHome=read-only --property=PrivateDevices=yes \
    --property=PrivateTmp=yes \
    tmux -L fmverify ls
error connecting to /tmp/tmux-1004/fmverify (No such file or directory)
```

The read-only `/tmp` of the retained sandbox does not break the socket, because the kernel exempts an existing socket from the read-only mount check; only the private tmpfs, which removes the path entirely, does.
That is why this is a new failure rather than one the unit already had.

`tests/fm-dashboard.test.sh`'s `test_unit_grants_scratch_without_hiding_tmp_and_opener_keeps_temps_in_memory` pins these together: the generated unit must not set `PrivateTmp=yes`, must carry a relative `RuntimeDirectory=` with a `TMPDIR=` naming that same directory and a `RuntimeDirectoryMode=0700` matching the unit's own `UMask=0077`, and the shared opener must report `temp_store` 2 on a `readOnly` open while leaving a writable open on the SQLite default.
`RuntimeDirectoryMode=` is stated rather than left to systemd's 0755 default so the scratch space is private on its own terms instead of relying on `/run/user/$UID` being 0700 around it.
Pinning them in one case is deliberate - the grant and the `TMPDIR` are worthless apart, and the in-memory opener is what keeps the store reader from depending on either, so a pass that drops one is told what it just made load-bearing.
`bin/fm-dashboard-install.sh` reads both directives back from `systemctl --user show` before reporting success, for the same reason it reads back the environment file: a unit systemd read past leaves a green service running on defaults it was never configured with.

An already-installed unit does not pick any of this up on its own.
The generator owns the change, so an existing service takes it by rerunning `bin/fm-dashboard-install.sh`, which preserves the installed operator-facing settings by default, rewrites the unit, reloads, restarts, and verifies the readback.
The generated runtime-contract marker also lets current server code identify an older loaded unit before polling and report that same repair instead of surfacing the first command's scratch-space failure.
