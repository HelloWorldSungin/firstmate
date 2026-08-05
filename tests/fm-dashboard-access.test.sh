#!/usr/bin/env bash
# Behavior tests for how the fleet dashboard is served and who may reach it:
# the generated systemd unit, the exposure gate, and authentication.
#
# The unit assertions exist because a systemd unit fails in a way `status` calls
# green. systemd reads the argument of EnvironmentFile= and the members of
# ReadWritePaths= as paths, ignores the whole directive when it is quoted, and
# then runs the service on defaults it was never configured with. A test that
# only checked that a unit file was written would call that install a success,
# so these read the directives back and require literal absolute paths, plus the
# PATH without which every fleet snapshot runs to its deadline.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVER="$ROOT/bin/fm-dashboard-server.mjs"
INSTALLER="$ROOT/bin/fm-dashboard-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-access)
USER_EVENT_STORE_BEFORE=$(fm_user_event_store_snapshot)
SERVER_PID=
TEST_PORT=
PASSWORD='harbour-lantern-42'

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

install_into() {  # <case-root> [extra installer args...]
  local case_root=$1
  shift
  mkdir -p "$case_root/config" "$case_root/home"
  # tests/lib.sh exports neutral values for both of these so no suite can touch
  # the developer's own instrumentation or credentials. They are dropped here
  # precisely because this case is about where the installer puts them when it
  # is told nothing. --allow-worktree is passed because the repo under test may
  # itself be a linked worktree, and these cases are about the unit's contents
  # rather than about where a persistent service should live;
  # test_installing_from_a_worktree_is_refused owns that separately.
  env -u FM_DASHBOARD_EVENTS_CONFIG -u FM_DASHBOARD_AUTH_FILE \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
    FM_DASHBOARD_EVENT_DB="$case_root/store/events.db" \
    "$INSTALLER" --allow-worktree --fm-home "$case_root/fleet" --no-start "$@"
}

unit_directive() {  # <unit-file> <directive>
  sed -n "s/^$2=//p" "$1"
}

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
  fi
}

# A credentials document produced the way the installer produces one: the
# password crosses on standard input and only the digest is ever written.
write_credentials() {  # <path> <username> <password>
  local destination=$1 username=$2 password=$3
  printf '%s' "$password" | node "$SERVER" --hash-password --username "$username" > "$destination"
  chmod 600 "$destination"
}

start_authenticated_server() {  # <case-root>
  local case_root=$1
  TEST_PORT=$(free_port)
  mkdir -p "$case_root/home/data" "$case_root/home/state"
  FM_HOME="$case_root/home" \
    FM_DASHBOARD_PORT="$TEST_PORT" \
    FM_DASHBOARD_TIMEOUT_SECONDS=4 \
    FM_DASHBOARD_POLL_SECONDS=5 \
    FM_DASHBOARD_AUTH_FILE="$case_root/dashboard-auth.json" \
    node "$SERVER" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/snapshot")" != "000" ]; then
      return 0
    fi
    sleep 0.1
  done
  fail "authenticated dashboard did not listen: $(cat "$case_root/server.log")"
}

status_for() {  # <path> [curl args...]
  local target=$1
  shift
  curl -s -o /dev/null -w '%{http_code}' "$@" "http://127.0.0.1:$TEST_PORT$target"
}

test_generated_unit_carries_literal_paths() {
  local case_root unit env_file directive path_entry
  case_root="$TMP_ROOT/literal"
  install_into "$case_root" >/dev/null || fail "the installer did not complete"
  unit="$case_root/config/systemd/user/firstmate-dashboard.service"

  # Every path-valued directive, read back the way systemd reads it. A quoted
  # value here is the defect: systemd logs "path is not absolute" once and drops
  # the directive, so the environment file and the one write grant vanish while
  # the service still starts.
  for directive in EnvironmentFile ReadWritePaths ExecStart; do
    local value
    value=$(unit_directive "$unit" "$directive")
    [ -n "$value" ] || fail "the unit has no $directive directive"
    assert_not_contains "$value" '"' "$directive is quoted, which systemd ignores for a path"
    assert_not_contains "$value" "'" "$directive is quoted, which systemd ignores for a path"
  done

  env_file=$(unit_directive "$unit" EnvironmentFile)
  case "$env_file" in
    /*) ;;
    *) fail "EnvironmentFile is not an absolute path: [$env_file]" ;;
  esac
  [ -f "$env_file" ] || fail "EnvironmentFile names a file that was not written: [$env_file]"

  # ReadWritePaths carries systemd's optional "-" prefix; what follows it must
  # still be one absolute path and must be the directory the service will open.
  local granted pinned
  granted=$(unit_directive "$unit" ReadWritePaths)
  granted=${granted#-}
  case "$granted" in
    /*) ;;
    *) fail "ReadWritePaths is not an absolute path: [$granted]" ;;
  esac
  pinned=$(sed -n 's/^FM_DASHBOARD_EVENT_DB="\(.*\)"$/\1/p' "$env_file")
  [ "$granted" = "${pinned%/*}" ] \
    || fail "the unit grants [$granted] while the service opens a store in [${pinned%/*}]"
  [ -d "$granted" ] || fail "the granted event directory was not created: [$granted]"

  # ExecStart must name the interpreter and the server, both absolute.
  local exec_start interpreter program
  exec_start=$(unit_directive "$unit" ExecStart)
  interpreter=${exec_start%% *}
  program=${exec_start#* }
  [ -x "$interpreter" ] || fail "ExecStart does not name an executable interpreter: [$interpreter]"
  [ -f "$program" ] || fail "ExecStart does not name the dashboard server: [$program]"

  # Without a PATH the service finds none of the fleet tools the snapshot shells
  # out to, every refresh runs to its deadline, and the dashboard serves a
  # permanently empty view while reporting itself healthy.
  local service_path
  service_path=$(sed -n 's/^Environment=PATH=//p' "$unit")
  [ -n "$service_path" ] || fail "the unit provides the service no PATH"
  assert_not_contains "$service_path" '"' "the pinned PATH is quoted, which systemd would take literally"
  local found_node=0
  while IFS= read -r path_entry; do
    [ -n "$path_entry" ] || continue
    case "$path_entry" in
      /*) ;;
      *) fail "the pinned PATH carries a relative entry: [$path_entry]" ;;
    esac
    [ -x "$path_entry/node" ] && found_node=1
  done <<EOF
$(printf '%s' "$service_path" | tr ':' '\n')
EOF
  [ "$found_node" -eq 1 ] || fail "the pinned PATH does not reach the node the unit runs: [$service_path]"
  pass "the generated unit carries literal absolute paths and a PATH the service can use"
}

test_a_path_the_unit_cannot_carry_is_refused() {
  local case_root out rc
  case_root="$TMP_ROOT/unsafe"
  mkdir -p "$case_root/config" "$case_root/home"
  set +e
  out=$(env -u FM_DASHBOARD_EVENTS_CONFIG \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
    "$INSTALLER" --allow-worktree --fm-home "$case_root/a fleet home" --no-start 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a path a unit cannot carry literally"
  assert_contains "$out" "cannot be written into a systemd unit" "the refusal did not name the reason"
  [ ! -f "$case_root/config/systemd/user/firstmate-dashboard.service" ] \
    || fail "a unit was written for a path the installer cannot encode"
  pass "a path no systemd unit can carry literally is refused instead of encoded wrong"
}

# A boot-persistent unit names one dashboard server by absolute path forever.
# Installed from a linked git worktree it names a directory whoever created that
# worktree will reclaim, so the service works until the day it silently does
# not - which is exactly how this dashboard's own remote-access work was nearly
# handed over.
test_installing_from_a_worktree_is_refused() {
  local case_root out rc exec_start unit
  case_root="$TMP_ROOT/worktree"
  mkdir -p "$case_root/config" "$case_root/home"
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }

  fm_git_worktree "$case_root/checkout" "$case_root/scratch" dashboard-scratch
  local copy
  for copy in "$case_root/checkout" "$case_root/scratch"; do
    mkdir -p "$copy/bin"
    cp "$INSTALLER" "$SERVER" "$ROOT/bin/fm-event-store.mjs" "$ROOT/bin/fm-telemetry-store.mjs" "$copy/bin/"
  done

  set +e
  out=$(env -u FM_DASHBOARD_EVENTS_CONFIG -u FM_DASHBOARD_AUTH_FILE \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
    FM_DASHBOARD_EVENT_DB="$case_root/store/events.db" \
    "$case_root/scratch/bin/fm-dashboard-install.sh" --fm-home "$case_root/fleet" --no-start 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "installing a persistent service from a linked worktree"
  assert_contains "$out" "linked git worktree" "the refusal did not name what was wrong"
  [ ! -f "$case_root/config/systemd/user/firstmate-dashboard.service" ] \
    || fail "a unit pointing into a disposable worktree was written anyway"

  # Naming a permanent checkout is the way through, and the unit must then run
  # that checkout's server rather than the one the installer happens to be in.
  env -u FM_DASHBOARD_EVENTS_CONFIG -u FM_DASHBOARD_AUTH_FILE \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
    FM_DASHBOARD_EVENT_DB="$case_root/store/events.db" \
    "$case_root/scratch/bin/fm-dashboard-install.sh" \
    --checkout "$case_root/checkout" --fm-home "$case_root/fleet" --no-start >/dev/null \
    || fail "installing for a permanent checkout was refused"
  unit="$case_root/config/systemd/user/firstmate-dashboard.service"
  exec_start=$(unit_directive "$unit" ExecStart)
  assert_contains "$exec_start" "$case_root/checkout/bin/fm-dashboard-server.mjs" \
    "the unit does not run the checkout it was installed for"
  assert_not_contains "$exec_start" "$case_root/scratch/" \
    "the unit still points into the disposable worktree"

  # Trying a change from a worktree stays possible when that is what was meant.
  rm -f "$unit"
  env -u FM_DASHBOARD_EVENTS_CONFIG -u FM_DASHBOARD_AUTH_FILE \
    HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
    FM_DASHBOARD_EVENT_DB="$case_root/store/events.db" \
    "$case_root/scratch/bin/fm-dashboard-install.sh" \
    --allow-worktree --fm-home "$case_root/fleet" --no-start >/dev/null \
    || fail "an explicitly allowed worktree install was still refused"
  assert_contains "$(unit_directive "$unit" ExecStart)" "$case_root/scratch/bin/fm-dashboard-server.mjs" \
    "the allowed worktree install did not run the worktree's server"
  pass "a persistent service is never installed from a disposable worktree by accident"
}

test_exposure_requires_credentials() {
  local case_root out rc
  case_root="$TMP_ROOT/exposure"
  mkdir -p "$case_root/config" "$case_root/home"

  set +e
  out=$(install_into "$case_root" --address 192.0.2.7 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a non-loopback bind with no credentials"
  assert_contains "$out" "needs credentials first" "the installer did not say why the bind was refused"
  [ ! -f "$case_root/config/systemd/user/firstmate-dashboard.service" ] \
    || fail "the installer wrote an exposed unit with no credentials behind it"

  # The server refuses the same configuration independently, so an environment
  # edited by hand cannot reach past the installer's gate.
  set +e
  out=$(FM_DASHBOARD_ADDRESS=192.0.2.7 FM_DASHBOARD_AUTH_FILE="$case_root/absent.json" node "$SERVER" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the dashboard started on a non-loopback bind with no credentials"
  assert_contains "$out" "requires dashboard credentials" "the server's exposure refusal was not explicit"

  # Turning authentication off is a loopback-only choice, and saying both at
  # once must refuse rather than resolve to the open reading.
  set +e
  out=$(FM_DASHBOARD_ADDRESS=192.0.2.7 FM_DASHBOARD_AUTH=off node "$SERVER" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the dashboard started exposed with authentication disabled"
  assert_contains "$out" "only supported on a loopback bind" "disabling authentication while exposed was not refused"
  pass "a bind beyond loopback is refused by both the installer and the server until credentials exist"
}

test_loopback_stays_the_open_default() {
  local case_root env_file
  case_root="$TMP_ROOT/default"
  install_into "$case_root" >/dev/null || fail "the installer did not complete"
  env_file="$case_root/config/firstmate/dashboard.env"
  assert_contains "$(cat "$env_file")" 'FM_DASHBOARD_ADDRESS="127.0.0.1"' \
    "installing without asking for exposure did not stay on loopback"
  [ ! -f "$case_root/config/firstmate/dashboard-auth.json" ] \
    || fail "installing without --set-password invented credentials"
  pass "an install that did not ask for exposure stays loopback-only"
}

test_set_password_stores_only_a_digest() {
  local case_root auth_file mode
  case_root="$TMP_ROOT/password"
  mkdir -p "$case_root/config" "$case_root/home"
  printf '%s' "$PASSWORD" | install_into "$case_root" --set-password --username skipper >/dev/null \
    || fail "storing a dashboard password did not complete"
  auth_file="$case_root/config/firstmate/dashboard-auth.json"
  [ -f "$auth_file" ] || fail "no credentials file was written"
  mode=$(stat -c '%a' "$auth_file" 2>/dev/null || stat -f '%Lp' "$auth_file")
  [ "$mode" = "600" ] || fail "the credentials file is not private to its owner: mode $mode"
  assert_not_contains "$(cat "$auth_file")" "$PASSWORD" "the password itself was stored"
  [ "$(jq -r '.schema' "$auth_file")" = "fm-dashboard-auth.v1" ] || fail "the credentials file has no supported schema"
  [ "$(jq -r '.username' "$auth_file")" = "skipper" ] || fail "the stored username is not the requested one"
  [ "$(jq -r '.kdf' "$auth_file")" = "scrypt" ] || fail "the credentials file does not record a supported derivation"
  # Two stores of the same password must differ, or the salt is not doing its job.
  local first second
  first=$(jq -r '.hash' "$auth_file")
  printf '%s' "$PASSWORD" | install_into "$case_root" --set-password --username skipper >/dev/null
  second=$(jq -r '.hash' "$auth_file")
  [ "$first" != "$second" ] || fail "the stored digest is not salted per store"
  pass "a stored dashboard password leaves only a salted digest in an owner-only file"
}

test_a_short_password_is_refused() {
  local case_root out rc
  case_root="$TMP_ROOT/short"
  mkdir -p "$case_root/config" "$case_root/home"
  set +e
  out=$(printf 'short' | install_into "$case_root" --set-password 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a password too short to be one was accepted"
  assert_contains "$out" "at least" "the refusal did not say what was wrong"
  [ ! -f "$case_root/config/firstmate/dashboard-auth.json" ] || fail "a refused password still wrote credentials"
  pass "a password shorter than the supported minimum is refused and stores nothing"
}

test_authentication_accepts_and_rejects() {
  local case_root code body
  case_root="$TMP_ROOT/auth"
  mkdir -p "$case_root"
  write_credentials "$case_root/dashboard-auth.json" captain "$PASSWORD"
  start_authenticated_server "$case_root"

  # No credentials: refused, and told how to present them.
  body=$(curl -s -D "$case_root/headers" "http://127.0.0.1:$TEST_PORT/api/snapshot")
  assert_contains "$(cat "$case_root/headers")" "401" "an unauthenticated request was not refused"
  assert_contains "$(cat "$case_root/headers")" "WWW-Authenticate: Basic" "the refusal did not offer a way to authenticate"
  assert_contains "$body" "authentication_required" "the refusal did not name its reason"

  # Wrong password, and right password with the wrong user: both refused.
  code=$(status_for /api/snapshot -u "captain:$PASSWORD-wrong")
  expect_code 401 "$code" "a wrong password"
  code=$(status_for /api/snapshot -u "stowaway:$PASSWORD")
  expect_code 401 "$code" "a wrong username"

  # The right credentials reach every browser-facing route.
  local route
  for route in / /app.js /api/snapshot /api/history /api/timeline; do
    code=$(status_for "$route" -u "captain:$PASSWORD")
    expect_code 200 "$code" "an authenticated request to $route"
  done

  # An authenticated snapshot is the real envelope, not a stub.
  curl -s -u "captain:$PASSWORD" "http://127.0.0.1:$TEST_PORT/api/snapshot" > "$case_root/envelope.json"
  jq -e '.schema == "fm-dashboard-envelope.v1"' "$case_root/envelope.json" >/dev/null \
    || fail "the authenticated snapshot was not the dashboard envelope"
  stop_server
  pass "authentication admits the stored credential and refuses every other one"
}

test_repeated_wrong_passwords_are_rate_limited() {
  local case_root code attempt limited
  case_root="$TMP_ROOT/throttle"
  mkdir -p "$case_root"
  write_credentials "$case_root/dashboard-auth.json" captain "$PASSWORD"
  start_authenticated_server "$case_root"
  limited=0
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    code=$(status_for /api/snapshot -u "captain:wrong-$attempt-password")
    if [ "$code" = "429" ]; then limited=1; break; fi
    expect_code 401 "$code" "guess $attempt before the limit"
  done
  [ "$limited" -eq 1 ] || fail "twenty wrong passwords in a row were never throttled"
  # An absent Authorization header is how every browser opens the page, so it
  # must stay a plain refusal rather than spending the same budget.
  code=$(status_for /api/snapshot)
  expect_code 401 "$code" "an unauthenticated request while a guesser is throttled"
  stop_server
  pass "repeated wrong passwords are throttled while an unauthenticated first request is not"
}

test_credentials_losing_their_private_mode_close_the_dashboard() {
  local case_root code
  case_root="$TMP_ROOT/mode"
  mkdir -p "$case_root"
  write_credentials "$case_root/dashboard-auth.json" captain "$PASSWORD"
  start_authenticated_server "$case_root"
  code=$(status_for /api/snapshot -u "captain:$PASSWORD")
  expect_code 200 "$code" "an authenticated request before the credentials were exposed"

  # A credentials file other users can read is not a credential, and neither a
  # world-readable one nor a removed one may revert an authenticated dashboard
  # to an open one.
  chmod 644 "$case_root/dashboard-auth.json"
  sleep 1.1
  code=$(status_for /api/snapshot -u "captain:$PASSWORD")
  expect_code 503 "$code" "a request against credentials other users can read"
  code=$(status_for /api/snapshot)
  expect_code 503 "$code" "an unauthenticated request against exposed credentials"

  rm -f "$case_root/dashboard-auth.json"
  sleep 1.1
  code=$(status_for /api/snapshot)
  expect_code 503 "$code" "an unauthenticated request after the credentials were removed"
  stop_server
  pass "credentials that stop being usable close the dashboard instead of opening it"
}

test_ingest_keeps_its_own_boundary() {
  local case_root code
  case_root="$TMP_ROOT/ingest"
  mkdir -p "$case_root"
  write_credentials "$case_root/dashboard-auth.json" captain "$PASSWORD"
  start_authenticated_server "$case_root"

  # The reporting hooks hold the ingest token and no dashboard password, so the
  # ingest endpoint must not be behind the browser's authentication. With no
  # instrumentation configured here it refuses on its own terms rather than
  # asking for a password it was never given.
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'X-Firstmate-Source: some-task/claude' \
    --data '{"schema":"fm-dashboard-event.v1","events":[]}' \
    "http://127.0.0.1:$TEST_PORT/events")
  [ "$code" = "503" ] || fail "the ingest endpoint answered $code instead of its own refusal"

  # A page on another origin cannot make a browser attach this endpoint's token,
  # and the cross-origin attempt is refused before a body is read regardless.
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Origin: https://elsewhere.invalid' \
    -H 'X-Firstmate-Source: some-task/claude' \
    --data '{"schema":"fm-dashboard-event.v1","events":[]}' \
    "http://127.0.0.1:$TEST_PORT/events")
  expect_code 403 "$code" "a cross-origin post to the ingest endpoint"
  stop_server
  pass "the ingest endpoint keeps its own token boundary and refuses cross-origin posts"
}

# An exposed dashboard that dropped loopback would take the local reporting
# hooks and a browser on the host itself away in exchange for the outward
# address it added, and bin/fm-dashboard-instrument.sh will not aim a producer
# anywhere but loopback. The exposed listener must therefore be an addition.
test_an_exposed_bind_keeps_loopback() {
  local case_root address code
  case_root="$TMP_ROOT/companion"
  mkdir -p "$case_root/home/data" "$case_root/home/state"
  write_credentials "$case_root/dashboard-auth.json" captain "$PASSWORD"

  # A second address this host actually has. Without one there is nothing to
  # expose to and the case cannot run.
  address=$(node -e '
    const nets = require("os").networkInterfaces();
    for (const list of Object.values(nets)) {
      for (const entry of list || []) {
        if (entry.family === "IPv4" && !entry.internal) { console.log(entry.address); process.exit(0); }
      }
    }
  ')
  [ -n "$address" ] || { echo "skip: this host has no non-loopback IPv4 address"; return 0; }

  TEST_PORT=$(free_port)
  FM_HOME="$case_root/home" \
    FM_DASHBOARD_ADDRESS="$address" \
    FM_DASHBOARD_PORT="$TEST_PORT" \
    FM_DASHBOARD_TIMEOUT_SECONDS=4 \
    FM_DASHBOARD_POLL_SECONDS=5 \
    FM_DASHBOARD_AUTH_FILE="$case_root/dashboard-auth.json" \
    node "$SERVER" > "$case_root/server.log" 2>&1 &
  SERVER_PID=$!
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ "$(status_for /api/snapshot)" != "000" ] && break
    sleep 0.1
  done

  code=$(status_for /api/snapshot -u "captain:$PASSWORD")
  expect_code 200 "$code" "an authenticated request over loopback while exposed"
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "captain:$PASSWORD" "http://$address:$TEST_PORT/api/snapshot")
  expect_code 200 "$code" "an authenticated request over the exposed address"
  # Authentication is the boundary on every listener, not only the outward one.
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://$address:$TEST_PORT/api/snapshot")
  expect_code 401 "$code" "an unauthenticated request over the exposed address"
  code=$(status_for /api/snapshot)
  expect_code 401 "$code" "an unauthenticated request over loopback while exposed"
  stop_server
  pass "an exposed dashboard adds its outward address and keeps loopback, under the same authentication"
}

test_generated_unit_carries_literal_paths
test_a_path_the_unit_cannot_carry_is_refused
test_an_exposed_bind_keeps_loopback
test_installing_from_a_worktree_is_refused
test_exposure_requires_credentials
test_loopback_stays_the_open_default
test_set_password_stores_only_a_digest
test_a_short_password_is_refused
test_authentication_accepts_and_rejects
test_repeated_wrong_passwords_are_rate_limited
test_credentials_losing_their_private_mode_close_the_dashboard
test_ingest_keeps_its_own_boundary
fm_assert_no_user_event_store_leak "$USER_EVENT_STORE_BEFORE"
pass "no agent-event store was created outside this suite's own temp space"
