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

## That the fix is not bought with the fleet view

`PrivateTmp=yes` clears the same failure by giving the service a private writable `/tmp`, and it is the obvious reach, so the reason the unit does not use it is recorded here rather than left to be rediscovered.

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

`tests/fm-dashboard.test.sh`'s `test_unit_does_not_use_private_tmp_and_opener_keeps_temps_in_memory` pins both halves together: the generated unit must not set `PrivateTmp=yes`, and the shared opener must report `temp_store` 2 on a `readOnly` open while leaving a writable open on the SQLite default.
Pinning them in one case is deliberate - each half is what makes the other unnecessary, so a future pass that drops one is told which other one it is about to make load-bearing.
