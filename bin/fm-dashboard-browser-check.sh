#!/usr/bin/env bash
# fm-dashboard-browser-check.sh - drive the real dashboard page in a real
# browser and record what it actually renders.
#
# Every other dashboard test in this repo imports a browser module into node and
# asserts on the data it returns. That proves the module, and it is worth
# keeping. It cannot prove the page: that the document loads at all, that the
# stylesheet and the module graph arrive, that the server-sent event stream
# connects from a browser, that the layout holds at 390 CSS px, that the console
# is clean. This command is the missing half, and it is deliberately a command
# rather than an unconditional test - see "Why this is a command" below.
#
# Usage:
#   fm-dashboard-browser-check.sh [--url <url> --user <name> --password-file <path>]
#                                 [--out <dir>] [--width <w>x<h>]... [--keep]
#                                 [--negative]
#
# Options:
#   --url            check an already-running dashboard instead of a fixture.
#                    With no --url this command starts its OWN dashboard server
#                    from this checkout, on an ephemeral loopback port, over a
#                    throwaway fixture home. It never starts, stops, installs,
#                    reconfigures, or repoints an operator's dashboard service,
#                    and there is no flag that makes it do so.
#   --user           username for --url, when that dashboard authenticates.
#   --password-file  file holding that password and nothing else. The password
#                    is handed to bin/fm-dashboard-browser-front.mjs, which
#                    holds it in memory and adds the header the dashboard
#                    already requires; it never enters the URL the browser
#                    opens, so it cannot reach the browser's history or any
#                    evidence captured here.
#   --out            evidence directory (default: a temp directory, kept and
#                    named on exit). Holds a screenshot and the rendered text of
#                    every view at every width, the console transcript, and
#                    result.txt.
#   --width          a viewport to check, repeatable, as <css-px>x<css-px>.
#                    Default: 390x844 (phone) and 1440x900 (desktop). The phone
#                    width is not an afterthought - this dashboard is read on
#                    one.
#   --keep           leave the fixture server running and print its URL.
#   --negative       prove the check can fail. Runs the identical assertions
#                    against a deliberately broken page and exits non-zero
#                    unless they fail. A check that cannot tell "rendered
#                    correctly" from "rendered nothing" is worse than no check,
#                    so this is how that property stays true rather than being
#                    asserted once and assumed forever.
#
# Why this is a command and not a test that CI runs
#
#   The two things this drives - a browser and a dashboard service - are shared
#   machine state. chrome-devtools-axi drives ONE Chrome session per host, so
#   two of these running at once fight over the same page, and the standard test
#   suite runs its files in parallel shards. CI has no Chrome at all. Making
#   this an unconditional test would therefore buy a check that is either
#   skipped everywhere it runs or flaky everywhere it does not.
#
#   So the harness is this command, and tests/fm-dashboard-browser.test.sh is a
#   thin opt-in wrapper that runs it end to end, including --negative, when the
#   operator asks for it. The tradeoff accepted: a rendering regression is not
#   caught by an ordinary CI run, and is caught by running this - after a
#   dashboard change, and before believing any claim about what the page shows.
#   The module-level dashboard tests are unaffected and still run everywhere.
#
# What it asserts, and why those things
#
#   The failure this exists to catch is a page that came up empty or broken
#   while something claimed it was fine, so no assertion here is satisfied by a
#   page that loaded. Each view must be present, must have real rendered
#   height, and must contain its own landmark text; the document must carry no
#   sideways scroll at any width, because reaching a fleet signal by horizontal
#   swipe is a defect this dashboard specifically promises against; the rendered
#   text must contain no credential-shaped or absolute-path-shaped value; and
#   the console must be clean. The fixture run additionally proves the live
#   stream: an event posted while the page is open appears with no reload, and a
#   selected agent's backfilled history survives the next event rather than
#   being discarded with the stream that gets replaced.
#
#   The structural assertions are written against the page's own contract, not
#   against fixture data, so this same command is what you point at a live
#   dashboard. Extending it for a new view means adding a row to VIEWS below.
#
# Exit status: 0 when every assertion passed, 1 when any failed, 2 on a usage
# or setup problem. The full per-observation result is printed and written to
# <out>/result.txt either way.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
FRONT="$ROOT/bin/fm-dashboard-browser-front.mjs"
BROWSER=${FM_DASHBOARD_BROWSER_CLI:-chrome-devtools-axi}

# Each row is: <section id>|<label>|<landmark>;<landmark>...
# The landmarks are the view's own furniture - its eyebrow, its heading, the
# controls it owns - so they hold against fixture data and against a live fleet
# alike. A new view is a new row here and nothing else.
VIEWS='inbox|Captain inbox|Captain inbox;Needs you
board|Board|Read-only fleet snapshot;Board;Secondmates;Filters
gbraintron|GBrain|GBrain health and search;Search captured knowledge
activity|Activity|Live agent events;Activity;Filters
history|History|Durable completion records;History;Filters and search'

DEFAULT_WIDTHS='390x844 1440x900'

MODE=fixture
TARGET_URL=
AUTH_USER=
PASSWORD_FILE=
OUT_DIR=
WIDTHS=
KEEP=no
NEGATIVE=no

SERVER_PID=
FRONT_PID=
NEGATIVE_PID=
WORK_DIR=
PASSES=0
FAILURES=0
RESULT_FILE=

usage() {
  cat <<'TEXT'
usage: fm-dashboard-browser-check.sh [options]

Drives the real dashboard page in a real browser and records what it renders.

  --url <url>             check an already-running dashboard. With no --url this
                          starts its own server from this checkout on an
                          ephemeral loopback port over a throwaway fixture home,
                          and never touches an installed dashboard service.
  --user <name>           username for --url, when that dashboard authenticates
  --password-file <path>  file holding that password; it is held by
                          bin/fm-dashboard-browser-front.mjs and never enters
                          the URL the browser opens
  --out <dir>             evidence directory (default: a temp directory)
  --width <w>x<h>         a viewport to check, repeatable
                          (default: 390x844 and 1440x900)
  --keep                  leave the fixture server running
  --negative              prove the check can fail, by running the same
                          assertions against a page that renders nothing

Exit status: 0 when every assertion passed, 1 when any failed, 2 on a usage or
setup problem. The per-observation result is written to <out>/result.txt.
TEXT
}

die() {
  printf 'fm-dashboard-browser-check: %s\n' "$1" >&2
  exit 2
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  for pid in "$FRONT_PID" "$NEGATIVE_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  if [ -n "$SERVER_PID" ] && [ "$KEEP" != yes ]; then
    kill "$SERVER_PID" 2>/dev/null
  fi
  [ -n "$WORK_DIR" ] && [ "$KEEP" != yes ] && rm -rf "$WORK_DIR"
  return 0
}
trap cleanup EXIT HUP INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --url) TARGET_URL=${2:-}; MODE=url; shift 2 ;;
    --user) AUTH_USER=${2:-}; shift 2 ;;
    --password-file) PASSWORD_FILE=${2:-}; shift 2 ;;
    --out) OUT_DIR=${2:-}; shift 2 ;;
    --width) WIDTHS="${WIDTHS} ${2:-}"; shift 2 ;;
    --keep) KEEP=yes; shift ;;
    --negative) NEGATIVE=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$WIDTHS" ] || WIDTHS=$DEFAULT_WIDTHS
for tool in node curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
command -v "$BROWSER" >/dev/null 2>&1 \
  || die "$BROWSER is required to drive a real browser (set FM_DASHBOARD_BROWSER_CLI to name another)"
[ -n "$PASSWORD_FILE" ] && [ -z "$AUTH_USER" ] && die "--password-file needs --user"
[ "$MODE" = fixture ] && [ -n "$PASSWORD_FILE" ] && die "--password-file only applies with --url"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-browser.XXXXXX") || die "could not create a work directory"
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$WORK_DIR/evidence"
fi
mkdir -p "$OUT_DIR" || die "could not create the evidence directory $OUT_DIR"
RESULT_FILE="$OUT_DIR/result.txt"
: > "$RESULT_FILE"

record() {  # <verdict> <observation> [detail]
  local verdict=$1 observation=$2 detail=${3:-}
  if [ "$verdict" = ok ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
  fi
  printf '%-4s %s%s\n' "$verdict" "$observation" "${detail:+ - $detail}" | tee -a "$RESULT_FILE"
}

note() {  # <line>
  printf '     %s\n' "$1" | tee -a "$RESULT_FILE"
}

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

# --- fixture dashboard ------------------------------------------------------
#
# A real server binary from this checkout, over a throwaway home, with a
# snapshot command that returns fixture data. The point is a page whose content
# is known in advance, so "the board rendered" can be checked against what the
# board was given rather than against whatever the fleet happens to be doing.

EVENT_TOKEN=0123456789abcdef0123456789abcdef

write_fixture_snapshot() {  # <path>
  cat > "$1" <<'JSON'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-08-07T00:00:00Z",
  "tasks": [
    {
      "id": "fixture-ship",
      "kind": "ship",
      "project": "firstmate",
      "harness": "claude",
      "model": "claude-opus-5",
      "effort": "high",
      "backlog": {"title": "Land the browser check"},
      "current_state": {"state": "working", "detail": "Implementing the harness"},
      "endpoint": {"exists": true, "status": "alive"},
      "paths": {"status_log": {"last_event_age_seconds": 12}},
      "pr": {"url": "https://github.com/HelloWorldSungin/firstmate/pull/64"},
      "work_items": [],
      "card": {"rank": 8, "column": "active", "action": "supervise", "reason": "contract-defined"}
    },
    {
      "id": "fixture-scout",
      "kind": "scout",
      "project": "firstmate",
      "harness": "claude",
      "model": "claude-opus-5",
      "effort": "xhigh",
      "backlog": {"title": "Investigate the empty board"},
      "current_state": {"state": "needs_decision", "detail": "Two viable layouts"},
      "endpoint": {"exists": true, "status": "alive"},
      "paths": {"status_log": {"last_event_age_seconds": 40}},
      "pr": {"url": null},
      "work_items": [],
      "card": {"rank": 10, "column": "needs_decision", "action": "decide", "reason": "contract-defined"}
    },
    {
      "id": "fixture-mate",
      "kind": "secondmate",
      "project": "",
      "harness": "codex",
      "model": "gpt-5.6-terra",
      "effort": "medium",
      "current_state": {"state": "idle", "detail": "Standing by"},
      "endpoint": {"exists": true, "status": "alive"},
      "paths": {"status_log": {"last_event_age_seconds": 30}},
      "work_items": [],
      "card": {"rank": 9, "column": "secondmate", "action": "route_work", "reason": "contract-defined"}
    }
  ],
  "card_precedence": ["needs_decision","blocked","parked","failed","review","done","waiting","active","secondmate","idle"],
  "supervision": {"watcher":{"present":true,"age_seconds":3,"stale":false},"afk":{"active":false}}
}
JSON
}

# A completed task recorded the way a real one is, published through the real
# manifest writer, so the History view is reading the format it reads in
# production rather than something shaped like it.
seed_completed_task() {  # <home> <id> <kind> <title> [pr-url]
  local home=$1 id=$2 kind=$3 title=$4 pr=${5:-}
  mkdir -p "$home/state" "$home/data/$id"
  {
    printf 'window=%s\n' "fm:$id"
    printf 'kind=%s\n' "$kind"
    printf 'project=firstmate\n'
    printf 'harness=claude\n'
    printf 'model=claude-opus-5\n'
    printf 'effort=high\n'
    printf 'mode=no-mistakes\n'
    printf 'yolo=off\n'
    printf 'backend=tmux\n'
    [ -n "$pr" ] && printf 'pr=%s\n' "$pr"
  } > "$home/state/$id.meta"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf 'working: started\ndone: finished\n' > "$home/state/$id.status"
  printf -- '- [x] %s - %s (since 2026-08-01)\n' "$id" "$title" >> "$home/data/backlog.md"
  FM_HOME="$home" "$ROOT/bin/fm-outcome-manifest.sh" write "$id" >/dev/null 2>&1 \
    || die "could not publish the fixture completion record for $id"
}

build_fixture() {
  local runtime home
  runtime="$WORK_DIR/runtime"
  home="$WORK_DIR/home"
  mkdir -p "$runtime" "$home/data" "$home/state" "$home/projects" "$WORK_DIR/control"
  # The server resolves every command it runs - the snapshot, the completion
  # manifests, usage, GBrain health - relative to its own directory, so the
  # whole tracked tree is staged and only the two commands this check wants to
  # hold still are replaced below. Staging less would mean discovering, one
  # missing helper at a time, which of them the server happens to need.
  cp -R "$ROOT/bin" "$ROOT/assets" "$runtime/" || die "could not stage the dashboard runtime"
  write_fixture_snapshot "$WORK_DIR/control/snapshot.json"

  cat > "$runtime/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat "${DASH_CHECK_CONTROL:?}/snapshot.json"
SH
  chmod +x "$runtime/bin/fm-fleet-snapshot.sh"

  # A brain that answers, so the GBrain panel renders its full strip rather
  # than the single "no brain configured" card. Both are legitimate states; the
  # populated one is the one worth looking at in a browser.
  cat > "$runtime/bin/fm-gbrain-health.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat <<'JSON'
{
  "schema": "fm-gbrain-health.v1",
  "generated": "2026-08-07T00:00:00Z",
  "home": "fixture",
  "health": {
    "configured": true,
    "version": "0.9.3",
    "index": {"state": "ok", "detail": "index present"},
    "capture": {"enabled": true, "archived": 12, "pending": 1, "failed": 0, "unreadable": 0,
                "last_capture_at": "2026-08-06T22:00:00Z", "last_error": null, "detail": "capture on"},
    "retrieval": {"state": "ok",
      "embedding": {"state": "ok", "model": "snowflake-arctic-embed2", "endpoint": "local", "detail": "reachable"},
      "reranker": {"state": "ok", "model": "bge-reranker", "endpoint": "local", "detail": "reachable"},
      "main_brain": {"state": "same-as-local", "model": null, "endpoint": null, "detail": "this home is the main brain"}},
    "synthesis": {"state": "ok", "model": "hosted", "endpoint": "hosted", "detail": "reachable"},
    "maintenance": {"state": "ready", "detail": "no maintenance window"}
  }
}
JSON
SH
  chmod +x "$runtime/bin/fm-gbrain-health.sh"

  seed_completed_task "$home" "fixture-done-ship" ship "Ship the foldable layout" \
    "https://github.com/HelloWorldSungin/firstmate/pull/58"
  seed_completed_task "$home" "fixture-done-scout" scout "Investigate the merge poll"

  printf '{"schema":"fm-dashboard-events-config.v1","url":"http://127.0.0.1:%s/events","token":"%s"}\n' \
    "$FIXTURE_PORT" "$EVENT_TOKEN" > "$WORK_DIR/dashboard-events.json"

  FM_HOME="$home" \
    FM_DASHBOARD_PORT="$FIXTURE_PORT" \
    FM_DASHBOARD_ADDRESS=127.0.0.1 \
    FM_DASHBOARD_AUTH=off \
    FM_DASHBOARD_POLL_SECONDS=1 \
    FM_DASHBOARD_TIMEOUT_SECONDS=10 \
    FM_DASHBOARD_HISTORY_POLL_SECONDS=3 \
    FM_DASHBOARD_EVENTS_CONFIG="$WORK_DIR/dashboard-events.json" \
    FM_DASHBOARD_EVENT_DB="$WORK_DIR/events.db" \
    DASH_CHECK_CONTROL="$WORK_DIR/control" \
    node "$runtime/bin/fm-dashboard-server.mjs" > "$WORK_DIR/server.log" 2>&1 &
  SERVER_PID=$!

  local _
  for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$FIXTURE_PORT/api/snapshot" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  die "the fixture dashboard did not start: $(cat "$WORK_DIR/server.log")"
}

post_event() {  # <task> <type> <tool>
  curl -fsS -o /dev/null -X POST "http://127.0.0.1:$FIXTURE_PORT/events" \
    -H "Authorization: Bearer $EVENT_TOKEN" \
    -H "X-Firstmate-Source: $1/claude" \
    -H "Content-Type: application/json" \
    -d "{\"schema\":\"fm-agent-event.v1\",\"events\":[{\"event_id\":\"$3\",\"task_id\":\"$1\",\"harness\":\"claude\",\"type\":\"$2\",\"tool\":\"$3\",\"occurred_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}"
}

# One request carrying <count> events, used only to push earlier events out of
# the dashboard's bounded fleet-wide tail. The server caps a batch, so the
# caller sends several of these rather than one large one.
post_event_batch() {  # <task> <prefix> <count>
  local task=$1 prefix=$2 count=$3 body
  # shellcheck disable=SC2016  # the node program interpolates its own argv, not the shell's
  body=$(node -e '
    const [task, prefix, count] = process.argv.slice(1);
    const at = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    const events = Array.from({ length: Number(count) }, (unused, index) => ({
      event_id: `${prefix}-${index}`,
      task_id: task,
      harness: "claude",
      type: "tool_started",
      tool: `${prefix}-${index}`,
      occurred_at: at,
    }));
    process.stdout.write(JSON.stringify({ schema: "fm-agent-event.v1", events }));
  ' "$task" "$prefix" "$count")
  curl -fsS -o /dev/null -X POST "http://127.0.0.1:$FIXTURE_PORT/events" \
    -H "Authorization: Bearer $EVENT_TOKEN" \
    -H "X-Firstmate-Source: $task/claude" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# --- browser -----------------------------------------------------------------

browser() {
  "$BROWSER" "$@" 2>&1
}

# chrome-devtools-axi prints `result: <json>` for an eval, and every probe below
# returns a JSON string, so what is printed is JSON wrapped around JSON. How
# many times it is wrapped is the browser tool's business and has changed
# between its versions, so this unwraps until it stops being a string rather
# than assuming a depth. A value that never stops being a string is a failure,
# not something to hand on as if it had decoded.
browser_eval() {  # <js-expression> <destination> <object|text>
  local expression=$1 destination=$2 want=$3 raw
  raw=$(browser eval "$expression") || return 1
  printf '%s\n' "$raw" | node -e '
    const want = process.argv[1];
    const chunks = [];
    process.stdin.on("data", (chunk) => chunks.push(chunk));
    process.stdin.on("end", () => {
      const text = chunks.join("");
      const line = text.split("\n").find((candidate) => candidate.startsWith("result: "));
      if (!line) { process.stderr.write(text); process.exit(1); }
      let value;
      try { value = JSON.parse(line.slice("result: ".length)); } catch { process.exit(1); }
      // Unwrap until the value stops being a string, keeping the last string
      // seen: a text probe wants that string, an object probe wants what it
      // decodes to.
      let previous = value;
      for (let depth = 0; depth < 4 && typeof value === "string"; depth += 1) {
        let next;
        try { next = JSON.parse(value); } catch { break; }
        previous = value;
        value = next;
      }
      if (want === "text") {
        process.stdout.write(typeof value === "string" ? value : previous);
        return;
      }
      if (value === null || typeof value !== "object") process.exit(1);
      process.stdout.write(JSON.stringify(value));
    });
  ' "$want" > "$destination" || return 1
  [ -s "$destination" ]
}

browser_eval_json() {  # <js-expression> <destination>
  browser_eval "$1" "$2" object
}

browser_eval_text() {  # <js-expression> <destination>
  browser_eval "$1" "$2" text
}

is_number() {  # <candidate>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

json_field() {  # <file> <js-path-expression>
  # shellcheck disable=SC2016  # the node program interpolates its own argv, not the shell's
  node -e '
    const data = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    const value = (new Function("d", `return ${process.argv[2]}`))(data);
    process.stdout.write(value === undefined || value === null ? "" : String(value));
  ' "$1" "$2" 2>/dev/null
}

# --- assertions --------------------------------------------------------------

# Values that must never be on the page. Absolute paths and credential shapes
# are the two the dashboard's own redaction is written against, so this is the
# rendered-page end of that guarantee. These are evaluated as JavaScript regular
# expressions inside the page.
LEAK_PATTERNS='/home/;/root/;/etc/;-----BEGIN;sk-[A-Za-z0-9];gh[pousr]_[A-Za-z0-9];github_pat_;glpat-;xox[abprs]-;AKIA[A-Z0-9];AIza[A-Za-z0-9]'

# The one probe every observation is read from.
#
# Every judgment about text - which landmarks are present, whether anything
# leak-shaped is on the page - is made INSIDE the page and comes back as a short
# list, rather than shipping the rendered text out to be searched here. That is
# not an optimization. The browser tool truncates an eval result at about 8000
# characters with no error of its own, and a real fleet's page carries three
# times that, so a probe that returned the text would come back as invalid JSON
# on exactly the pages worth checking - and a check that breaks on real data and
# works on fixtures is the failure this whole command exists to end. Returning a
# verdict keeps the result a fixed small size whatever the fleet is doing.
build_probe_js() {
  # shellcheck disable=SC2016  # the node program interpolates its own argv, not the shell's
  node -e '
    const views = process.argv[1].trim().split("\n").map((row) => {
      const [id, name, landmarks] = row.split("|");
      return { id, name, landmarks: (landmarks || "").split(";").filter(Boolean) };
    });
    const leaks = process.argv[2].split(";").filter(Boolean);
    process.stdout.write(`() => {
      const config = ${JSON.stringify({ views, leaks })};
      const doc = document.documentElement;
      const out = {
        title: document.title,
        bodyTextLength: document.body.innerText.length,
        clientWidth: doc.clientWidth,
        scrollWidth: doc.scrollWidth,
        stylesheetApplied: getComputedStyle(document.body).backgroundColor,
        views: {},
      };
      for (const view of config.views) {
        const element = document.getElementById(view.id);
        if (!element) { out.views[view.id] = { present: false }; continue; }
        const box = element.getBoundingClientRect();
        const text = element.innerText;
        const lower = text.toLowerCase();
        out.views[view.id] = {
          present: true,
          height: Math.round(box.height),
          textLength: text.length,
          missing: view.landmarks.filter((landmark) => !lower.includes(landmark.toLowerCase())),
          leaks: config.leaks.filter((pattern) => new RegExp(pattern).test(text)),
        };
      }
      return JSON.stringify(out);
    }`);
  ' "$VIEWS" "$LEAK_PATTERNS"
}

# A bounded slice of each view, saved so a human can read what the check saw.
# Evidence only - nothing is asserted from it, so the bound costs no coverage.
capture_view_text() {  # <label> <view id>
  browser_eval_text "() => document.getElementById('$2') ? document.getElementById('$2').innerText.slice(0, 2000) : ''" \
    "$OUT_DIR/text-$1-$2.txt" 2>/dev/null || true
}

check_width() {  # <width> <height>
  local width=$1 height=$2 label="${1}x${2}" probe id name
  probe="$OUT_DIR/probe-${width}x${height}.json"

  browser resize "$width" "$height" > "$OUT_DIR/resize-$label.txt" \
    || { record FAIL "$label: viewport could not be set"; return; }
  browser open "$PAGE_URL" > "$OUT_DIR/open-$label.txt" \
    || { record FAIL "$label: page could not be opened"; return; }
  # The page fills itself from its first snapshot poll and its history poll, so
  # give both a chance to land before reading it.
  sleep 4

  if ! browser_eval_json "$(build_probe_js)" "$probe"; then
    record FAIL "$label: the page could not be read at all" \
      "the probe returned nothing the browser could decode"
    return
  fi

  local title body_length client_width scroll_width background
  title=$(json_field "$probe" 'd.title')
  body_length=$(json_field "$probe" 'd.bodyTextLength')
  client_width=$(json_field "$probe" 'd.clientWidth')
  scroll_width=$(json_field "$probe" 'd.scrollWidth')
  background=$(json_field "$probe" 'd.stylesheetApplied')

  # Everything below reads numbers and text out of this probe. If the probe did
  # not yield them, the remaining assertions have nothing to judge, and an
  # assertion with nothing to judge must not report a pass - that is the exact
  # shape of a check that rubber-stamps a broken page.
  if ! is_number "$body_length" || ! is_number "$client_width" || ! is_number "$scroll_width"; then
    record FAIL "$label: the page could be measured" \
      "the probe returned no usable geometry, so nothing further at this width was checked"
    return
  fi

  if [ "$title" = "Firstmate Fleet" ]; then
    record ok "$label: the dashboard document loaded"
  else
    record FAIL "$label: the dashboard document loaded" "document title is [$title]"
  fi

  if [ "$body_length" -ge 200 ]; then
    record ok "$label: the page rendered text rather than an empty document" "$body_length characters"
  else
    record FAIL "$label: the page rendered text rather than an empty document" "only $body_length characters"
  fi

  # A stylesheet that 404s leaves the document readable and completely
  # unstyled, which is a real regression that every text assertion would
  # otherwise pass. The page sets its own surface colour, so an unpainted body
  # is the tell.
  case "$background" in
    ""|"rgba(0, 0, 0, 0)"|transparent)
      record FAIL "$label: the stylesheet was applied" "the body is unpainted [$background], so the page is rendering unstyled" ;;
    *)
      record ok "$label: the stylesheet was applied" "body surface $background" ;;
  esac

  if [ "$scroll_width" -le "$((client_width + 1))" ]; then
    record ok "$label: nothing is placed behind a horizontal swipe" "scrollWidth $scroll_width <= viewport $client_width"
  else
    record FAIL "$label: nothing is placed behind a horizontal swipe" \
      "the document scrolls sideways: scrollWidth $scroll_width > viewport $client_width"
  fi

  local all_leaks=""
  # The landmark list is read inside the page by build_probe_js, so this loop
  # only needs the id and the human name.
  while IFS='|' read -r id name _landmarks; do
    [ -n "$id" ] || continue
    local present height missing leaks
    present=$(json_field "$probe" "String((d.views['$id'] || {}).present === true)")
    if [ "$present" != true ]; then
      record FAIL "$label: the $name view is on the page"
      continue
    fi
    height=$(json_field "$probe" "String((d.views['$id'] || {}).height || 0)")
    missing=$(json_field "$probe" "((d.views['$id'] || {}).missing || []).join(', ')")
    leaks=$(json_field "$probe" "((d.views['$id'] || {}).leaks || []).join(', ')")
    capture_view_text "$label" "$id"

    # A section that exists but occupies almost nothing is exactly the "it
    # loaded" answer this check refuses to accept.
    if is_number "$height" && [ "$height" -ge 60 ]; then
      record ok "$label: the $name view rendered with real height" "${height}px"
    else
      record FAIL "$label: the $name view rendered with real height" "only ${height:-0}px tall"
    fi

    if [ -z "$missing" ]; then
      record ok "$label: the $name view is legible" "its own headings and controls are on the page"
    else
      record FAIL "$label: the $name view is legible" "missing: $missing"
    fi
    [ -n "$leaks" ] && all_leaks="${all_leaks}${all_leaks:+; }$name: $leaks"
  done <<EOF
$VIEWS
EOF

  if [ -z "$all_leaks" ]; then
    record ok "$label: no credential-shaped or path-shaped value on the page"
  else
    record FAIL "$label: no credential-shaped or path-shaped value on the page" "matched $all_leaks"
  fi

  browser screenshot "$OUT_DIR/screen-$label.png" > /dev/null 2>&1 \
    && note "screenshot: $OUT_DIR/screen-$label.png"

  check_navigation "$label"
}

# Following a nav link must put the reader at the top of the section they asked
# for. The bar is sticky, so a target scrolled to the top of the viewport is a
# target underneath it, and the reader lands part-way in with the heading hidden
# - which is what this dashboard did at every width until it was looked at.
check_navigation() {  # <label>
  local label=$1 id name landed
  while IFS='|' read -r id name _landmarks; do
    [ -n "$id" ] || continue
    browser eval "() => { const link = [...document.querySelectorAll('.nav-item')].find((a) => a.getAttribute('href') === '#$id'); if (!link) return 'no-link'; link.click(); return 'clicked'; }" > /dev/null 2>&1
    # The stylesheet asks for smooth scrolling, so the landing position is not
    # settled on the next line.
    sleep 2
    landed=$(browser_eval_text "() => {
      const bar = document.querySelector('.topbar');
      const section = document.getElementById('$id');
      if (!bar || !section) return 'missing';
      const barBottom = Math.round(bar.getBoundingClientRect().bottom);
      const sectionTop = Math.round(section.getBoundingClientRect().top);
      return sectionTop >= barBottom - 1 ? 'clear' : 'covered by ' + (barBottom - sectionTop) + 'px';
    }" "$WORK_DIR/nav.txt" >/dev/null 2>&1 && cat "$WORK_DIR/nav.txt")
    if [ "$landed" = clear ]; then
      record ok "$label: the $name link lands on that section's heading"
    else
      record FAIL "$label: the $name link lands on that section's heading" \
        "the sticky bar hides the top of the section: $landed"
    fi
  done <<EOF
$VIEWS
EOF
}

# --- live stream -------------------------------------------------------------
#
# Fixture mode only. Injecting events into a live dashboard would mean writing
# into the operator's own event store, which this command has no business doing.

# Asked and answered inside the page, for the same reason the main probe is: the
# rendered text is far larger than an eval result may be, so shipping it out to
# search here would be answering the question from a truncated copy.
page_contains() {  # <needle>
  local answer
  answer=$(browser_eval_text "() => String(document.body.innerText.includes($(json_string "$1")))" \
    "$WORK_DIR/contains.txt" >/dev/null 2>&1 && cat "$WORK_DIR/contains.txt")
  [ "$answer" = true ]
}

json_string() {  # <value>
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

wait_for_page_text() {  # <needle> <seconds>
  local needle=$1 deadline=$2
  for _ in $(seq 1 "$((deadline * 2))"); do
    page_contains "$needle" && return 0
    sleep 0.5
  done
  return 1
}

check_live_stream() {
  browser resize 1440 900 > /dev/null || true
  browser open "$PAGE_URL#activity" > /dev/null \
    || { record FAIL "a live event appears without a reload"; return; }
  sleep 3

  # 1. The page is open and has not been reloaded since. An event posted now
  #    must arrive on it by itself.
  post_event fixture-ship tool_started fmcheck-live-now \
    || { record FAIL "a live event appears without a reload" "the fixture dashboard refused the event"; return; }
  if wait_for_page_text "fmcheck-live-now" 20; then
    record ok "a live event appears without a reload" \
      "posted after the page was open, and it arrived on that same page"
  else
    record FAIL "a live event appears without a reload" "the posted event never reached the open page"
  fi

  # 2. Give one agent some earlier history, then push it out of the live tail
  #    with unrelated traffic. Without this the next assertion would be
  #    satisfied by the tail alone and would prove nothing about backfill.
  local index
  for index in 1 2 3; do
    post_event fixture-ship tool_started "fmcheck-backfill-$index" >/dev/null 2>&1
  done
  for index in $(seq 1 8); do
    post_event_batch fixture-filler "fmcheck-filler-$index" 30 >/dev/null 2>&1
    sleep 0.3
  done
  sleep 3

  if page_contains "fmcheck-backfill-1"; then
    record FAIL "the agent's earlier events really did leave the live stream" \
      "they are still in the fleet-wide tail, so the backfill assertion below would prove nothing"
    return
  fi
  record ok "the agent's earlier events really did leave the live stream" \
    "pushed out by later traffic, so selecting that agent has to fetch them back"

  # 3. Selecting that agent's own timeline is what fetches them back.
  local clicked
  # The nearest enclosing element that names the agent, not the first one found
  # walking up: every card shares a board container, so a generous walk matches
  # whichever card happens to come first and silently selects the wrong agent.
  clicked=$(browser eval '() => {
    const wanted = "fixture-ship";
    let best = null;
    for (const button of document.querySelectorAll("button")) {
      if (button.textContent.trim() !== "Timeline") continue;
      let node = button.parentElement;
      let depth = 1;
      while (node && depth < 8) {
        if (node.textContent.includes(wanted)) break;
        node = node.parentElement;
        depth += 1;
      }
      if (node && depth < 8 && (!best || depth < best.depth)) best = { button, depth };
    }
    if (!best) return "not-found";
    best.button.click();
    return "clicked";
  }' 2>&1)
  case "$clicked" in
    *clicked*) ;;
    *)
      record FAIL "backfilled history survives a subsequent event" \
        "the agent's own timeline control could not be found on the board, so nothing was backfilled"
      return ;;
  esac
  sleep 3

  if ! page_contains "fmcheck-backfill-1"; then
    record FAIL "backfilled history survives a subsequent event" \
      "selecting the agent did not bring its earlier events back, so there was nothing to survive"
    return
  fi

  # 4. The next accepted event replaces the live stream wholesale. The
  #    backfilled rows must survive that - which is exactly the failure the
  #    timeline's own design note says it is built to avoid.
  post_event fixture-scout turn_ended fmcheck-after-event >/dev/null 2>&1
  sleep 4
  if page_contains "fmcheck-backfill-1"; then
    record ok "backfilled history survives a subsequent event" \
      "the fetched earlier events are still on the page after a newer event replaced the stream"
  else
    record FAIL "backfilled history survives a subsequent event" \
      "the fetched earlier events were discarded when the stream was replaced"
  fi
}

# --- console -----------------------------------------------------------------

check_console() {
  local transcript="$OUT_DIR/console.txt" fresh
  browser console > "$transcript" 2>&1 || true
  # The browser session is shared and its console is cumulative, so only
  # messages newer than the watermark taken before this run are this page's.
  fresh=$(node -e '
    const fs = require("node:fs");
    const since = Number(process.argv[2] || 0);
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n")
      .filter((line) => /^msgid=\d+/.test(line))
      .filter((line) => Number(/^msgid=(\d+)/.exec(line)[1]) > since);
    process.stdout.write(lines.join("\n"));
  ' "$transcript" "$CONSOLE_WATERMARK" 2>/dev/null)

  if [ -z "$fresh" ]; then
    record ok "the browser console is clean" "nothing was printed while the page was driven"
    return
  fi
  printf '%s\n' "$fresh" > "$OUT_DIR/console-new.txt"
  record FAIL "the browser console is clean" "$(printf '%s' "$fresh" | wc -l | tr -d ' ') message(s), see $OUT_DIR/console-new.txt"
  printf '%s\n' "$fresh" | while IFS= read -r line; do note "console: $line"; done
}

console_watermark() {
  browser console 2>/dev/null | node -e '
    const chunks = [];
    process.stdin.on("data", (chunk) => chunks.push(chunk));
    process.stdin.on("end", () => {
      const ids = chunks.join("").split("\n")
        .map((line) => /^msgid=(\d+)/.exec(line))
        .filter(Boolean)
        .map((match) => Number(match[1]));
      process.stdout.write(String(ids.length ? Math.max(...ids) : 0));
    });
  ' 2>/dev/null || printf '0'
}

# --- negative proof ----------------------------------------------------------
#
# The property being proved is that these assertions can fail. A page that
# serves the dashboard's own document shell with no stylesheet, no module, and
# no content is the exact shape of the failure worth catching: it is a 200, it
# has a title, and it renders nothing.

start_negative_page() {
  NEGATIVE_PORT=$(free_port)
  cat > "$WORK_DIR/broken.mjs" <<'JS'
import http from "node:http";
const body = '<!doctype html><html><head><title>Firstmate Fleet</title></head><body></body></html>';
http.createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  response.end(body);
}).listen(Number(process.argv[2]), "127.0.0.1", () => process.stdout.write("ready\n"));
JS
  node "$WORK_DIR/broken.mjs" "$NEGATIVE_PORT" > "$WORK_DIR/broken.log" 2>&1 &
  NEGATIVE_PID=$!
  local _
  for _ in $(seq 1 40); do
    curl -fsS -o /dev/null "http://127.0.0.1:$NEGATIVE_PORT/" 2>/dev/null && return 0
    sleep 0.2
  done
  die "the deliberately broken page did not start"
}

# --- run ---------------------------------------------------------------------

CONSOLE_WATERMARK=$(console_watermark)

if [ "$NEGATIVE" = yes ]; then
  start_negative_page
  PAGE_URL="http://127.0.0.1:$NEGATIVE_PORT/"
  printf 'negative proof: the same assertions, against a page that renders nothing\n' | tee -a "$RESULT_FILE"
  for spec in $WIDTHS; do
    check_width "${spec%x*}" "${spec#*x}"
  done
  printf '\n%s passed, %s failed\n' "$PASSES" "$FAILURES" | tee -a "$RESULT_FILE"
  if [ "$FAILURES" -gt 0 ]; then
    printf 'negative proof PASSED: the check refuses a page that renders nothing (%s assertions failed, as required)\n' \
      "$FAILURES" | tee -a "$RESULT_FILE"
    exit 0
  fi
  printf 'negative proof FAILED: the check passed a page that renders nothing, so it proves nothing\n' \
    | tee -a "$RESULT_FILE"
  exit 1
fi

if [ "$MODE" = fixture ]; then
  FIXTURE_PORT=$(free_port)
  build_fixture
  PAGE_URL="http://127.0.0.1:$FIXTURE_PORT/"
  printf 'checking a fixture dashboard from this checkout at %s\n' "$PAGE_URL" | tee -a "$RESULT_FILE"
else
  if [ -n "$PASSWORD_FILE" ]; then
    [ -r "$PASSWORD_FILE" ] || die "cannot read the password file $PASSWORD_FILE"
    FRONT_PORT=$(free_port)
    node "$FRONT" --target "$TARGET_URL" --user "$AUTH_USER" \
      --password-file "$PASSWORD_FILE" --port "$FRONT_PORT" > "$WORK_DIR/front.log" 2>&1 &
    FRONT_PID=$!
    for _ in $(seq 1 40); do
      grep -q '^listening ' "$WORK_DIR/front.log" 2>/dev/null && break
      sleep 0.2
    done
    grep -q '^listening ' "$WORK_DIR/front.log" 2>/dev/null \
      || die "the authenticating front did not start: $(cat "$WORK_DIR/front.log")"
    PAGE_URL="http://127.0.0.1:$FRONT_PORT/"
    printf 'checking %s through a loopback authenticating front at %s\n' "$TARGET_URL" "$PAGE_URL" \
      | tee -a "$RESULT_FILE"
  else
    PAGE_URL="$TARGET_URL"
    printf 'checking %s\n' "$PAGE_URL" | tee -a "$RESULT_FILE"
  fi
fi

for spec in $WIDTHS; do
  printf '\n-- %s --\n' "$spec" | tee -a "$RESULT_FILE"
  check_width "${spec%x*}" "${spec#*x}"
done

printf '\n-- live stream --\n' | tee -a "$RESULT_FILE"
if [ "$MODE" = fixture ]; then
  check_live_stream
else
  note "live event and backfill: not checked against a dashboard this command does not own, because"
  note "proving them means writing events into that dashboard's own store. Run without --url for those two."
fi

printf '\n-- console --\n' | tee -a "$RESULT_FILE"
check_console

printf '\n%s passed, %s failed\n' "$PASSES" "$FAILURES" | tee -a "$RESULT_FILE"
printf 'evidence: %s\n' "$OUT_DIR"
[ "$KEEP" = yes ] && [ -n "${FIXTURE_PORT:-}" ] && printf 'fixture dashboard left running at %s\n' "$PAGE_URL"
[ "$FAILURES" -eq 0 ] || exit 1
exit 0
