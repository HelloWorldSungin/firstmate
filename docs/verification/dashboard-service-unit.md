# Verification: the generated dashboard systemd unit

Why this record exists: a systemd unit fails in a way `systemctl status` reports as green.
A directive systemd read past leaves a service that starts, stays active, and runs on defaults it was never configured with.
The guarantee under test is that `bin/fm-dashboard-install.sh` emits directives systemd actually accepts, that the installer refuses to report success unless systemd reads them back, and that it refuses to report success over a service that did not stay running.

Refresh with `bin/fm-test-run.sh tests/fm-dashboard-access.test.sh tests/fm-dashboard.test.sh`, which pin the portable half without systemd: the first covers the quoting and path forms systemd accepts, the second the hardening directives the unit must carry and the ones it must not.
The observations below need a systemd host and are what those portable suites cannot prove.

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

The unit runs under `ProtectSystem=strict` and `ProtectHome=read-only` with a single `ReadWritePaths` grant for the agent-event directory.
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

The hardened unit pairs `ProtectSystem=strict` with `ProtectHome=read-only`.
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

## That a search that never started is reported separately

`bin/fm-recall.sh` exit 3 means every requested corpus was asked and none answered, which a panel may render as a statement about the brain.
Exit 5 means no corpus was ever asked.
`tests/fm-recall.test.sh` pins all three outcomes together - setup failure, a corpus that was asked and refused, and a corpus that was read and had no match - because the distinction is only worth anything if the other two still hold.

## That a lost history read cannot render as an empty fleet

`fm_outcome_history_json` refuses when records were counted off disk and none reached the result.
`tests/fm-outcome-manifest.test.sh`'s `test_history_refuses_to_report_a_lost_read_as_an_empty_fleet` injects the fault rather than reproducing it, since the here-string is gone, and was confirmed to fail with the check removed.

Against a running dashboard with that fault injected, the panel renders "No history yet" under a red "Completed-work history unavailable" notice, whose copy reads "this list is empty because nothing has been read, not because nothing has finished".
The three genuine empty states were each demonstrated on their own instance and still render: a home with no completions says "Nothing has completed in this home", 61 records under a filter matching none say "Nothing matches these filters", and the read that did not land says "No history yet".

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

`tests/fm-dashboard.test.sh`'s `test_unit_grants_scratch_without_hiding_tmp_and_opener_keeps_temps_in_memory` pins these together: the generated unit must not set `PrivateTmp=yes`, must carry a relative `RuntimeDirectory=` with a `TMPDIR=` naming that same directory, and the shared opener must report `temp_store` 2 on a `readOnly` open while leaving a writable open on the SQLite default.
Pinning them in one case is deliberate - the grant and the `TMPDIR` are worthless apart, and the in-memory opener is what keeps the store reader from depending on either, so a pass that drops one is told what it just made load-bearing.
`bin/fm-dashboard-install.sh` reads both directives back from `systemctl --user show` before reporting success, for the same reason it reads back the environment file: a unit systemd read past leaves a green service running on defaults it was never configured with.

An already-installed unit does not pick any of this up on its own.
The generator owns the change, so an existing service takes it by rerunning `bin/fm-dashboard-install.sh` with the same options, which rewrites the unit, reloads, restarts, and verifies the readback.
