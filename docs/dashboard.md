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
It writes a private environment file and `firstmate-dashboard.service` under the user configuration root (`$XDG_CONFIG_HOME`, or `~/.config` by default), then enables the service for boot-persistent startup.
Run `bin/fm-dashboard-install.sh --help` for the exact configuration flags and environment names.

Open `http://127.0.0.1:8787` on the same machine after the service starts.
The server accepts only the numeric loopback addresses `127.0.0.1` and `::1`.

## Runtime behavior

[`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs)'s header owns the environment configuration names and defaults.
The server runs the fixed adjacent `fm-fleet-snapshot.sh --json` command with a hard deadline, keeps at most one execution active, coalesces poll and debounced file triggers, and pushes result envelopes to the browser with server-sent events.
No HTTP input can select a command, argument, or fleet path.

A failed refresh keeps the last valid snapshot visible and labels it stale with bounded error detail.
The server also pushes a stale transition as soon as the last successful snapshot reaches the configured age threshold, even when the next poll has not started.
The empty, first-run, missing-command, timeout, malformed-JSON, unsupported-schema, and stale-last-good cases remain explicit in the same board surface.
The browser reconnects its event stream with bounded exponential backoff, while periodic polling guarantees eventual updates even when a filesystem notification is unavailable.

Every card column and displayed action comes directly from `tasks[].card` in the snapshot, and the top-level `card_precedence` array determines column order.
Each task card renders its id, title, project, kind, harness, model, effort, state detail, full PR URL, endpoint liveness, last-event age, and available work-item links from that same task row.
Unknown endpoint liveness remains distinct from alive or dead.
Work-item references with unavailable enrichment or an unsupported forge remain plain links, while a task without a reference has no work-item affordance.
Project, harness, model, kind, and state filters derive their choices from the snapshot.
The UI contains no forge adapter or independent fleet-state parser.
Persistent secondmates stay in their own lane.

## Updating configuration

Re-run the installer with the desired values to replace the environment file and restart the enabled service.
The environment file owns the operational home, loopback address, port, poll interval, snapshot timeout, and stale threshold for the service.
Use ordinary user-level systemd status and journal commands to inspect startup failures.
