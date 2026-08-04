# GBrain read-only main-brain share

Active empirical evidence for the guarantees in [`../gbrain-scoping.md`](../gbrain-scoping.md): that GBrain's own OAuth scope model can express a read-only share, that its mount model in the installed version cannot, and that a reading home can read the main brain and cannot mutate it.

Verified 2026-08-04 against GBrain `0.42.69.0` at commit `3acd511b80bd4d2fe487290a70de75d4cf094730`, the pin recorded in [`../gbrain.md`](../gbrain.md).

```console
$ gbrain version
gbrain 0.42.69.0
```

## The installed mount model cannot express a read-only share

A mount in this version carries direct transport only, so it cannot be given an OAuth credential:

```console
$ gbrain mounts add fm-main --path /tmp --mcp-url https://example.com/mcp
Unknown flag: --mcp-url: . Fix: See `gbrain mounts add --help`
```

The remaining transports are a PGLite data directory or a Postgres URL, both of which grant the reading process write access, and a PGLite brain accepts a single writer at a time.

The mount registry is also per UNIX user rather than per `GBRAIN_HOME`, so mounts cannot scope one Firstmate home against another.
A mount registered under one `GBRAIN_HOME` is visible from a different one on the same account:

```console
$ HOME=$tmp/fakehome GBRAIN_HOME=$tmp/gh-a gbrain mounts add probe-mount \
    --path $tmp/mountsrc --engine pglite --db-path $tmp/mountsrc/.pglite
Mount "probe-mount" added → /.../mountsrc
  engine: pglite

$ HOME=$tmp/fakehome GBRAIN_HOME=$tmp/gh-b gbrain mounts list
MOUNTS (1)
  probe-mount          pglite
    path:    /.../mountsrc

$ find $tmp/fakehome -name mounts.json
/.../fakehome/.gbrain/mounts.json
```

The registry landed under the UNIX home, and neither `GBRAIN_HOME` held one.

## The scope model can

`gbrain auth register-client` issues a client restricted to a single scope, and `gbrain serve --http` checks each operation's required scope against it:

```console
$ gbrain auth register-client fm-secondmate-read --scopes read --grant-types client_credentials
OAuth client registered: "fm-secondmate-read"

  Client ID:           gbrain_cl_<redacted>
  Client Secret:       gbrain_cs_<redacted>

  Grant types:         client_credentials
  Scopes:              read
  Write source:        default
  Federated reads:     default
```

With a token minted for that client against a served brain holding one seeded page, a read returns real content and every write-class call is refused:

```console
$ # tools/call get_page {"slug":"main-canary"}
{"result":{"content":[{"type":"text","text":"...xyzzy-mainbrain-canary..."}]}}

$ # tools/call put_page {"slug":"main-canary","content":"TAMPERED"}
{"error":"insufficient_scope","message":"Operation put_page requires 'write' scope","your_scopes":["read"]}

$ # tools/call delete_page {"slug":"anything"}
{"error":"insufficient_scope","message":"Operation delete_page requires 'write' scope","your_scopes":["read"]}
```

Re-reading the page after the refused writes returned the original content unchanged.

`gbrain auth create` tokens are a different mechanism and are not scoped: the permissions they persist select which takes-holders are visible, not which operations are allowed, which is why they cannot serve as a read-only credential.

## Revocation cascades to issued tokens

After rotating a reading home to a new client, a token minted from the revoked client stopped working immediately rather than remaining valid until expiry:

```console
$ # tools/call list_pages with the pre-rotation token
{"error":"invalid_token","error_description":"Invalid token"}
HTTP=401
```

## Registration and revocation need the served brain stopped

Both are database writes, and PGLite accepts one writer, so they are refused while `gbrain serve` holds the brain:

```console
$ fm-gbrain.sh grant-read fm-rot --home <reading-home> --replace
fm-gbrain: the main brain is currently being served, and its index takes one
writer at a time; stop the served main brain, register the read-only client,
then start it again
```

The refusal is safe: the reading home's previous client id and credential were unchanged afterwards.

## Refreshing this record

`tests/fm-gbrain-readonly-e2e.test.sh` is the reusable proof and rebuilds every claim above except the mount-model observations.
It creates two real brains, registers a real read-scoped client through `bin/fm-gbrain.sh`, serves the main brain, and drives real MCP tool calls, then stops the main brain and confirms the reading home's own search still answers.
It is opt-in because it needs a GBrain installation and a local embedding endpoint:

```sh
FM_GBRAIN_LIVE_E2E=1 FM_GBRAIN_BIN=<path-to-gbrain> bin/fm-test-run.sh tests/fm-gbrain-readonly-e2e.test.sh
```

Run it after any GBrain upgrade, and re-confirm the mount-model observations above before assuming a newer version still cannot carry an OAuth mount.
`tests/fm-gbrain-lib.test.sh` covers the Firstmate side portably and needs no GBrain installation.
