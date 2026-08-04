# Fleet dashboard

The fleet dashboard is a mobile-first, read-only kanban view over [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh)'s versioned JSON contract.
It never dispatches, steers, merges, tears down, or writes fleet state.
Stopping the dashboard has no effect on Firstmate supervision.

This first dashboard slice listens only on loopback.
Remote phone access, authentication, TLS, and Twingate exposure are intentionally outside its current boundary.

## Install the user service

Node.js 22 or newer and user-level systemd are required.
Run the installer from the tracked Firstmate checkout whose dashboard assets should be served:

```sh
bin/fm-dashboard-install.sh --fm-home /path/to/firstmate
```

The installer uses no sudo.
It writes a private environment file under `~/.config/firstmate/`, writes `firstmate-dashboard.service` under the user systemd configuration directory, and enables the service for boot-persistent startup.
Run `bin/fm-dashboard-install.sh --help` for the exact configuration flags and environment names.

Open `http://127.0.0.1:8787` on the same machine after the service starts.
The server refuses a non-loopback bind address.

## Runtime behavior

[`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs)'s header owns the environment configuration names and defaults.
The server runs the fixed adjacent `fm-fleet-snapshot.sh --json` command with a hard deadline, keeps at most one execution active, coalesces poll and debounced file triggers, and pushes result envelopes to the browser with server-sent events.
No HTTP input can select a command, argument, or fleet path.

A failed refresh keeps the last valid snapshot visible and labels it stale with bounded error detail.
The empty, first-run, missing-command, timeout, malformed-JSON, unsupported-schema, and stale-last-good cases remain explicit in the same board surface.
The browser reconnects its event stream with bounded exponential backoff, while periodic polling guarantees eventual updates even when a filesystem notification is unavailable.

Every card column comes directly from `tasks[].card.column` in the snapshot.
The UI also consumes task model, effort, event age, endpoint status, PR URL, and work-item references from the same task row, and contains no forge adapter or independent fleet-state parser.
Persistent secondmates stay in their own lane.

## Updating configuration

Re-run the installer with the desired values to replace the environment file and restart the enabled service.
The environment file owns the operational home, loopback address, port, poll interval, snapshot timeout, and stale threshold for the service.
Use ordinary user-level systemd status and journal commands to inspect startup failures.
