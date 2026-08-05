# Reaching the fleet dashboard from off this machine

[The fleet dashboard](dashboard.md) installs loopback-only and stays that way until you ask for something else.
This page owns what "something else" means: what authentication protects, what it does not, and which parts of a remote path belong to you rather than to Firstmate.

Nothing here changes an existing install.
An install that never asks for exposure is unchanged by this page.

## The rule that makes exposure safe to reason about

Exposure is never a bind-address change alone.

`bin/fm-dashboard-install.sh --address` accepts an address beyond loopback only once credentials the server could actually serve behind exist, and [`bin/fm-dashboard-server.mjs`](../bin/fm-dashboard-server.mjs) refuses to start on such an address without them.
The installer asks the server itself whether the stored credentials are usable rather than checking that the file is there, so a credentials document that is readable by other users or will not parse is refused at install time instead of taking down the service it was written for.
Editing the environment file by hand does not get past that either: the server checks before it opens a socket, so there is no window in which the dashboard answers off this host with nothing in front of it.

Enforcement is also sticky.
A credentials file that is removed, corrupted, or made readable by other users refuses every request rather than reverting to an open dashboard.
That holds whether it broke while the dashboard was running or was already broken when the dashboard started: a credential this server cannot use is not the same as a decision not to have one.

An exposed dashboard keeps its loopback listener as well as the address you named.
The activity-timeline producers post only to the loopback dashboard ([dashboard events](dashboard-events.md)), and a browser on the machine itself reaches it the same way, so exposure adds an address instead of moving one.
Every listener answers through the same handler, so the same authentication applies to all of them.
A wildcard bind is already answering on loopback and gets no second listener.

## Set a password

```sh
bin/fm-dashboard-install.sh --set-password --username captain
```

The password is read from your terminal, or from standard input when there is no terminal.
It reaches the digest helper through a pipe and is never an argument, so it does not appear in the process table, your shell history, or a service log.

Only a salted scrypt digest is stored, in a file the installer creates mode `0600` under your user configuration root.
Rotating the password is the same command again; the server notices the new file within a second and does not need a restart.

Authentication is HTTP Basic over the transport you put in front of it.
The dashboard deliberately terminates no TLS of its own: the deployments this is built for already have a reverse proxy holding a certificate, and a second certificate to manage on the same host buys nothing.
That makes the transport your responsibility, and it is the difference between a password that is protected and a password that is on the wire.

## Expose it

```sh
bin/fm-dashboard-install.sh --fm-home /path/to/firstmate --address <interface-address>
```

Give the specific interface address the thing in front of the dashboard reaches, not a wildcard.
`0.0.0.0` and `::` bind every interface the machine has, including ones you were not thinking about; the installer warns about that rather than refusing it, because a container sometimes leaves no alternative.

The installer refuses a name, so what the service is reachable on is a thing you can read off your own configuration rather than a thing name resolution decides.

## Install it from a checkout that will still be there

The unit names one dashboard server by absolute path and keeps naming it across reboots, so the installer refuses to write a persistent service that runs from a linked git worktree: whoever made that worktree will reclaim it, and the service would work until the day it silently did not.

The same refusal covers the operational home the unit pins, because a service whose fleet home and event store are reclaimed is as broken as one whose server is.

Trying a change from a worktree is legitimate, so `--allow-worktree` says that is what you meant.
To install the persistent service for a permanent checkout while running a newer installer from somewhere else, name it:

```sh
bin/fm-dashboard-install.sh --checkout /path/to/firstmate
```

With neither `FM_HOME` nor `--fm-home` set, the operational home follows `--checkout` rather than staying where the installer you ran happens to live.
Pass `--fm-home` when the fleet home is somewhere else.

## The reverse proxy

Terminate TLS at a proxy you already run and forward to the dashboard's address and port.

Two properties matter more than the choice of proxy.

Being behind a proxy is not access control.
A proxy is usually reachable from your whole network, so the dashboard's own authentication has to hold for a request that arrives from the proxy exactly as it does for any other.
It does; there is no trusted-source exemption to configure, and no header is ever treated as proof of who you are.
The trusted-proxy setting below decides who a request is throttled as and nothing else: it can never admit a request, only tell two clients apart.

The dashboard pushes its live view over a server-sent event stream.
A proxy that buffers a proxied response will hold that stream and make a working dashboard look frozen, so turn response buffering off for this host and give it a read timeout long enough for an idle stream to survive.

## Tell the dashboard which proxy to believe

Failed-authentication throttling keys on who the client is, and by default the client is the address the request arrived from.
Behind a proxy every request arrives from the proxy, so with nothing configured every client behind it shares one budget and one of them guessing wrong passwords is one of them slowing all the others down.

Naming the proxy is what separates them again:

```sh
bin/fm-dashboard-install.sh --trusted-proxy 192.0.2.10 --address 192.0.2.110
```

`--trusted-proxy` is repeatable and takes a numeric address or a CIDR range, never a name.
It pins `FM_DASHBOARD_TRUSTED_PROXIES` into the environment file the way every other setting is pinned.

Nothing is trusted until you do this, and that is deliberate:

- With no trusted proxy configured the dashboard reads no forwarded header at all.
  Upgrading does not change that; only naming an address does.
- `X-Forwarded-For` is read only when the request arrived from an address on that list.
  From anyone else it is ignored entirely, because a header from an untrusted peer is a claim a client made about itself.
- The chain is then walked from the proxy end, discarding the entries your own proxies contributed, and the first entry that is not one of them is the client.
  The leftmost entry is whatever the client chose to send, so reading it would let one guesser mint unlimited identities and turn per-client throttling into none.
- A request whose client cannot be established at all is refused rather than being counted as some shared client.

RFC 7239 `Forwarded` is deliberately not read; `X-Forwarded-For` is what the proxies this is deployed behind send, and one header handled exactly is worth more than two handled approximately.

What throttling then guarantees: a wrong password spends its own client's budget before the key derivation it would cost, and a correct one is refunded as soon as it verifies, so a client guessing at any rate cannot hold a different client out of the dashboard.
Correct passwords are also remembered briefly, so one page load does not spend the budget once per asset.
What bounds the work rather than the rate is a cap on key derivations in flight at once; when that cap is reached a request is told to retry in a second rather than being locked out for minutes.

## Twingate and anything else that is yours

Firstmate configures nothing in your zero-trust network, your firewall, or your DNS.
It cannot: those live in consoles it has no access to, and a script that claimed to have configured them would be guessing.

For a Twingate-style private network the parts that stay yours are:

- A Resource that covers the name you will use, assigned to the group your device is in.
  Until such a Resource exists, a connected client resolves that name the way the public internet does, no matter how correct everything on the host is.
- Wildcard Resources match labels to the left of the suffix and do not match the apex, so a wildcard covering subdomains does not cover the bare domain.
- The Connector performs the real name lookup with its own host's resolver, so that host has to resolve your internal names internally.
  A Connector on a different host, or in a container with its own resolver, can resolve a name differently from the machine you tested on.
- Whether your firewall permits the proxy to reach the dashboard's port on this machine.

Verify the path from the device you actually intend to use.
A check from the dashboard's own host proves the service and the proxy; it does not prove the private network, because the host is not on it.

## Confirm it

Ask systemd what it accepted, rather than reading the unit you just wrote:

```sh
systemctl --user show -p EnvironmentFiles -p Environment -p ReadWritePaths firstmate-dashboard.service
```

The installer performs these same checks itself and refuses to report success without them, because a unit directive systemd read past leaves a service that starts, stays green, and runs on defaults it was never configured with.
It then waits for the service to have had time to fail and refuses to report success unless it is still running, since `systemctl restart` returns for a `Type=simple` service the moment the process forks and says nothing about whether it survived.

Then check the boundary from a machine that is not this one:

```sh
curl -o /dev/null -w '%{http_code}\n' https://<your-name>/api/snapshot                   # expect 401
curl -o /dev/null -w '%{http_code}\n' -u captain:<password> https://<your-name>/api/snapshot   # expect 200
```

A `200` for the first command is the one result that means stop and fix something.

## What is not here

Read-only terminal deep links into a running agent's pane are part of the same story and are deliberately not in this slice.
A link that can send input to a worker is a command-execution boundary rather than a convenience, and shipping one without being able to demonstrate that it cannot accept input would be shipping the boundary on a promise.
[Issue #15](https://github.com/HelloWorldSungin/firstmate/issues/15) keeps that scope open.
