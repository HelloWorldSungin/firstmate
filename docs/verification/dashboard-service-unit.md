# Verification: the generated dashboard systemd unit

Why this record exists: a systemd unit fails in a way `systemctl status` reports as green.
A directive systemd read past leaves a service that starts, stays active, and runs on defaults it was never configured with.
The guarantee under test is that `bin/fm-dashboard-install.sh` emits directives systemd actually accepts, that the installer refuses to report success unless systemd reads them back, and that it refuses to report success over a service that did not stay running.

Refresh with `bin/fm-test-run.sh tests/fm-dashboard-access.test.sh`, which pins the portable half without systemd.
The observations below need a systemd host and are what the portable test cannot prove.

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

## That the sandbox gives SQLite a writable scratch path

The hardened unit pairs `ProtectSystem=strict` with `ProtectHome=read-only`.
Together they make the whole system hierarchy read-only (including `/tmp` and `/var/tmp`) and `$HOME` read-only, so SQLite has no writable path it can use for the temp file a read-only open needs.
The token-usage collector against `data/usage.db` exits `disk I/O error` while the store itself is healthy and reads cleanly from an ordinary shell.
Neither protection alone breaks it, which is why the defect survived earlier investigation.

Host: `systemd 255` user manager, Node 22, `bin/fm-usage.mjs report --by task --limit 25` against a 37 MB `data/usage.db` in `delete` journal mode.
Date: 2026-08-08.
Refresh: rerun each row with `systemd-run --user --pipe --wait --collect --property=<row>`.

| Sandbox                                                                 | Result   |
| ---                                                                     | ---      |
| `ProtectHome=read-only`                                                 | passes   |
| `ProtectSystem=strict`                                                  | passes   |
| `ProtectSystem=strict` + `ProtectHome=read-only` + `PrivateDevices=yes` | **fails** - `fm-usage: disk I/O error`, exit 1 |
| the same, plus `PrivateTmp=yes`                                         | passes   |

Adding `PrivateTmp=yes` gives the service a private writable `/tmp` without weakening either protection, and is the fix.
`tests/fm-dashboard.test.sh`'s `test_installer_emits_private_tmp_for_sqlite_scratch` pins the directive in the generated unit text and the comment that names the failure it prevents, so a future hardening pass cannot silently remove it as redundant.
