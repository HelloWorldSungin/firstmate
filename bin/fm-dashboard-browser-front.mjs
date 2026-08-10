#!/usr/bin/env node
// fm-dashboard-browser-front.mjs - a loopback-only authenticating front for a
// browser check of an already-running, already-authenticated dashboard.
//
// The dashboard authenticates every browser-facing route, and a browser check
// needs a URL it can simply open. The obvious shortcut, putting the password
// into that URL, writes the credential into the browser's own history and into
// every snapshot, screenshot, and console dump the check captures - which is
// the opposite of what a check that exists to look for exposed credentials
// should do. This holds the credential instead: it reads the password from a
// private file, adds the Authorization header the dashboard already requires,
// and forwards everything else untouched.
//
// What that costs, stated plainly rather than claimed away: this front attaches
// the credential to every request it forwards and performs no authorization of
// its own, so while it is running it is an unauthenticated door to an
// authenticated dashboard. Any local process, and any other user on the host,
// can read that dashboard by connecting to this port without knowing the
// password - the dashboard enforces authentication on loopback binds too once
// credentials are configured, and this front is what satisfies it. The door is
// bound to loopback only, on an ephemeral port, and it exists only for the
// length of one operator-run check.
//
// The parts of the rationale that do hold: the credential never enters the URL
// the browser opens, so it cannot reach the browser's history or any evidence
// the check captures; the dashboard's own authentication is unchanged and still
// enforced, and what arrives there is an ordinary authenticated request; this
// process refuses any bind but loopback; and nothing of it persists once the
// check exits. bin/fm-dashboard-browser-check.sh starts and stops it; running it
// by hand is for debugging that check.
//
// Whether to close the door - a per-run bearer token in the path the check
// opens is the obvious shape - is a decision for the operator of a shared host,
// not something this comment should imply has already been made.
//
// Bodies are streamed rather than buffered, so the dashboard's server-sent
// event stream reaches the browser as it is produced. That matters: the live
// event observation this front exists to enable is precisely the one a
// buffering proxy would break.
//
// usage:
//   fm-dashboard-browser-front.mjs --target <url> --user <name> --password-file <path> [--port <n>]
//
//   --target        base URL of the dashboard to front, for example
//                   http://192.168.68.110:8787
//   --user          username to present
//   --password-file file holding the password, and nothing else, trailing
//                   newline permitted. It must not be readable by other users,
//                   the same rule the dashboard applies to its own credentials
//                   file, and this refuses to start otherwise
//   --port          loopback port to listen on (default: an ephemeral port)
//
// It prints one line, "listening <url>", once it is ready to serve, and exits
// non-zero with a diagnostic if it cannot start.

import http from "node:http";
import { readFileSync, statSync } from "node:fs";

const LOOPBACK = "127.0.0.1";
// Beyond this the front is not the bottleneck the check is measuring; a
// dashboard that has not answered a browser request in a minute is the
// finding, not a timeout to tune away.
const UPSTREAM_TIMEOUT_MS = 60_000;

function usage(message) {
  process.stderr.write(`${message}\n\nusage: fm-dashboard-browser-front.mjs --target <url> --user <name> --password-file <path> [--port <n>]\n`);
  process.exit(2);
}

function parseArguments(argv) {
  const options = { target: "", user: "", passwordFile: "", port: 0 };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    switch (flag) {
      case "--target": options.target = value; index += 1; break;
      case "--user": options.user = value; index += 1; break;
      case "--password-file": options.passwordFile = value; index += 1; break;
      case "--port": options.port = Number(value); index += 1; break;
      case "--help": case "-h": usage("fm-dashboard-browser-front.mjs"); break;
      default: usage(`unknown argument: ${flag}`);
    }
  }
  if (!options.target) usage("--target is required");
  if (!options.user) usage("--user is required");
  if (!options.passwordFile) usage("--password-file is required");
  if (!Number.isInteger(options.port) || options.port < 0 || options.port > 65_535) {
    usage("--port must be a port number");
  }
  return options;
}

const options = parseArguments(process.argv.slice(2));

let target;
try {
  target = new URL(options.target);
} catch {
  usage(`--target must be a URL: ${options.target}`);
}
if (target.protocol !== "http:") {
  // Only http upstreams, because that is what a Firstmate dashboard serves.
  // Refusing rather than quietly attempting https keeps a mistyped target from
  // looking like an unreachable dashboard.
  usage(`--target must be an http:// URL: ${options.target}`);
}

// A password file readable by other users is not a credential, and this front
// exists to keep one out of sight. Refusing is the same judgment the dashboard
// itself makes about its own credentials file, by the same rule: any bit set
// outside the owner's own. Reading it anyway would take a secret the operator
// was told they had and serve it on loopback for the length of the run.
let info;
try {
  info = statSync(options.passwordFile);
} catch (error) {
  process.stderr.write(`cannot read the password file ${options.passwordFile}: ${error.message}\n`);
  process.exit(1);
}
if ((info.mode & 0o077) !== 0) {
  const mode = (info.mode & 0o7777).toString(8).padStart(4, "0");
  process.stderr.write(
    `the password file must not be readable by other users: ${options.passwordFile} is mode ${mode} - run chmod 600 ${options.passwordFile}\n`,
  );
  process.exit(1);
}

let password;
try {
  password = readFileSync(options.passwordFile, "utf8").replace(/\r?\n$/, "");
} catch (error) {
  process.stderr.write(`cannot read the password file ${options.passwordFile}: ${error.message}\n`);
  process.exit(1);
}
if (!password) {
  process.stderr.write(`the password file ${options.passwordFile} is empty\n`);
  process.exit(1);
}

const authorization = `Basic ${Buffer.from(`${options.user}:${password}`, "utf8").toString("base64")}`;
// The credential is now only in this process's memory. Nothing below ever
// writes it to a log line, an error body, or a response header.
password = "";

const server = http.createServer((request, response) => {
  const headers = { ...request.headers, authorization, host: target.host };
  // Hop-by-hop headers belong to this connection, not to the forwarded one.
  delete headers["proxy-authorization"];
  delete headers.connection;

  const upstream = http.request(
    {
      host: target.hostname,
      port: target.port || 80,
      method: request.method,
      path: request.url,
      headers,
    },
    (upstreamResponse) => {
      response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    },
  );
  upstream.setTimeout(UPSTREAM_TIMEOUT_MS, () => {
    upstream.destroy(new Error(`the dashboard did not answer within ${UPSTREAM_TIMEOUT_MS}ms`));
  });
  upstream.on("error", (error) => {
    if (response.headersSent) {
      response.destroy();
      return;
    }
    // A plain-text body, so a check that renders this page sees the reason
    // rather than an empty document it would have to guess about.
    response.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    response.end(`the dashboard at ${target.origin} could not be reached: ${error.message}\n`);
  });
  request.on("error", () => upstream.destroy());
  request.pipe(upstream);
});

server.on("error", (error) => {
  process.stderr.write(`the authenticating front could not listen: ${error.message}\n`);
  process.exit(1);
});

server.listen(options.port, LOOPBACK, () => {
  const address = server.address();
  process.stdout.write(`listening http://${LOOPBACK}:${address.port}\n`);
});
